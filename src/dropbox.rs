//! Documented blocking Dropbox operations.

use std::collections::BTreeMap;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

use rustix::fd::OwnedFd;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::auth::AccessToken;
use crate::journal::{
    DropboxBinding, DropboxBindingWrite, Journal, JournalError, RemoteObservationRecord,
};
use crate::local::{
    DownloadPreparation, DownloadSlotLease, LocalError, StageOutcome, StagedUpload,
    existing_download_stage_at, open_root, prepare_download_slot_at, stage_download_at,
};
use crate::model::{ContentIdentity, DropboxRevision, Observation, RemoteFile, UnknownReason};
use crate::runtime_status::{TransferDirection, TransferEvent, TransferObserver, TransferProgress};

const LONG_POLL_MINIMUM_SECONDS: u64 = 30;
const LONG_POLL_MAXIMUM_SECONDS: u64 = 480;
const JSON_REQUEST_SECONDS: u64 = 60;
const CONNECT_SECONDS: u64 = 15;
const DOWNLOAD_SECONDS: u64 = 60 * 60;
const LONG_POLL_GRACE_SECONDS: u64 = 105;
const DIRECT_UPLOAD_MAX_BYTES: u64 = 150 * 1024 * 1024;
const UPLOAD_SESSION_CHUNK_BYTES: u64 = 32 * 1024 * 1024;
const UPLOAD_SESSION_MAX_BYTES: u64 = (1_u64 << 41) - (1_u64 << 22);
const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

fn exact_download_agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(CONNECT_SECONDS)))
        .timeout_recv_body(Some(Duration::from_secs(DOWNLOAD_SECONDS)))
        .max_idle_connections(4)
        .max_idle_connections_per_host(4)
        .build();
    ureq::Agent::new_with_config(config)
}

struct ProgressReader<'a, R> {
    inner: R,
    observer: Option<&'a TransferObserver>,
    direction: TransferDirection,
    path: PathBuf,
    done: u64,
    total: Option<u64>,
    last_sample: Instant,
    last_emitted: u64,
}

impl<'a, R> ProgressReader<'a, R> {
    fn new(
        inner: R,
        observer: Option<&'a TransferObserver>,
        direction: TransferDirection,
        path: &Path,
        total: Option<u64>,
    ) -> Self {
        Self::new_at(inner, observer, direction, path, 0, total)
    }

    fn new_at(
        inner: R,
        observer: Option<&'a TransferObserver>,
        direction: TransferDirection,
        path: &Path,
        done: u64,
        total: Option<u64>,
    ) -> Self {
        let mut reader = Self {
            inner,
            observer,
            direction,
            path: path.to_path_buf(),
            done,
            total,
            last_sample: Instant::now(),
            last_emitted: done,
        };
        reader.emit();
        reader
    }

    fn emit(&mut self) {
        if let Some(observer) = self.observer {
            observer(TransferEvent::Progress(TransferProgress::new(
                self.direction,
                &self.path,
                self.done,
                self.total,
            )));
        }
        self.last_emitted = self.done;
    }

    fn done(&self) -> u64 {
        self.done
    }
}

impl<R: Read> Read for ProgressReader<'_, R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = self.inner.read(buffer)?;
        let read_u64 = u64::try_from(read)
            .map_err(|_| io::Error::other("transfer read length cannot be represented"))?;
        self.done = self
            .done
            .checked_add(read_u64)
            .ok_or_else(|| io::Error::other("transfer byte count overflowed"))?;
        let now = Instant::now();
        let sample_due = read == 0
            || self.total.is_some_and(|total| self.done >= total)
            || now.duration_since(self.last_sample) >= PROGRESS_INTERVAL;
        if sample_due && self.done != self.last_emitted {
            self.emit();
            self.last_sample = now;
        }
        Ok(read)
    }
}

impl<R: Seek> Seek for ProgressReader<'_, R> {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let offset = self.inner.seek(position)?;
        self.done = offset;
        self.last_emitted = offset;
        self.last_sample = Instant::now();
        Ok(offset)
    }
}

impl<R> Drop for ProgressReader<'_, R> {
    fn drop(&mut self) {
        if let Some(observer) = self.observer {
            observer(TransferEvent::Finished(TransferProgress::new(
                self.direction,
                &self.path,
                self.done,
                self.total,
            )));
        }
    }
}

/// Dropbox HTTP endpoint locations.
///
/// Production callers should use [`DropboxEndpoints::production`]. Explicit
/// endpoints allow protocol tests to exercise the real blocking HTTP path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DropboxEndpoints {
    authorize: String,
    token: String,
    api: String,
    content: String,
    notify: String,
}

impl DropboxEndpoints {
    /// Dropbox's documented production endpoints.
    #[must_use]
    pub fn production() -> Self {
        Self {
            authorize: String::from("https://www.dropbox.com/oauth2/authorize"),
            token: String::from("https://api.dropboxapi.com/oauth2/token"),
            api: String::from("https://api.dropboxapi.com/2"),
            content: String::from("https://content.dropboxapi.com/2"),
            notify: String::from("https://notify.dropboxapi.com/2"),
        }
    }

    /// Explicit endpoint URLs for a local protocol server.
    #[must_use]
    pub fn new(
        authorize: impl Into<String>,
        token: impl Into<String>,
        api: impl Into<String>,
        content: impl Into<String>,
        notify: impl Into<String>,
    ) -> Self {
        Self {
            authorize: authorize.into(),
            token: token.into(),
            api: api.into(),
            content: content.into(),
            notify: notify.into(),
        }
    }

    pub(crate) fn authorize(&self) -> &str {
        &self.authorize
    }

    pub(crate) fn token(&self) -> &str {
        &self.token
    }

    fn api(&self, route: &str) -> String {
        format!("{}{route}", self.api.trim_end_matches('/'))
    }

    fn content(&self, route: &str) -> String {
        format!("{}{route}", self.content.trim_end_matches('/'))
    }

    fn notify(&self, route: &str) -> String {
        format!("{}{route}", self.notify.trim_end_matches('/'))
    }
}

impl Default for DropboxEndpoints {
    fn default() -> Self {
        Self::production()
    }
}

/// Account, namespace, and Dropbox folder this client is confined to.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DropboxRoot {
    account_id: String,
    namespace_id: String,
    path: String,
    lower_path: String,
    depth: usize,
}

impl DropboxRoot {
    /// Bind Dropbox operations to one known account and namespace root.
    pub fn new(
        account_id: impl Into<String>,
        namespace_id: impl Into<String>,
        path: impl Into<String>,
    ) -> Result<Self, DropboxError> {
        let path = path.into();
        if !path.is_empty()
            && (!path.starts_with('/')
                || path.ends_with('/')
                || path.split('/').skip(1).any(invalid_dropbox_component))
        {
            return Err(DropboxError::InvalidRootPath);
        }
        let depth = path.split('/').skip(1).count();
        let lower_path = path.to_lowercase();
        Ok(Self {
            account_id: account_id.into(),
            namespace_id: namespace_id.into(),
            path,
            lower_path,
            depth,
        })
    }

    /// Reconstruct a root from the protected credential binding.
    pub fn from_binding(binding: &DropboxBinding) -> Result<Self, DropboxError> {
        Self::new(
            binding.account_id.clone(),
            binding.root_namespace_id.clone(),
            binding.remote_root.clone(),
        )
    }

    fn binding(&self) -> DropboxBinding {
        DropboxBinding {
            account_id: self.account_id.clone(),
            root_namespace_id: self.namespace_id.clone(),
            remote_root: self.path.clone(),
        }
    }
}

/// Result of checking the token against its durable account binding.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AccountValidation {
    /// Account and root namespace still match.
    Valid,
    /// The token belongs to a different Dropbox account.
    AccountChanged,
    /// Dropbox reports a different root namespace.
    RootChanged,
    /// This journal is permanently bound to a different Dropbox identity.
    JournalBindingChanged,
}

/// Result of binding a freshly authorized token to its current Dropbox root.
pub enum DropboxLink {
    /// Account inspection succeeded and produced a root-confined client.
    Linked(Box<DropboxClient>),
    /// The token endpoint and account endpoint reported different accounts.
    AccountChanged,
}

/// How a complete remote inventory was obtained.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InventoryRefresh {
    /// Initial listing or cursor continuation completed and was published.
    Published,
    /// Dropbox reset the old cursor, so a complete rebuild was published.
    RebuiltAfterCursorReset,
}

/// Expected result of one Dropbox long-poll request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LongPollWakeup {
    /// The cursor has changes ready to list.
    Changes {
        /// Server-requested delay before the next long poll.
        backoff: Option<Duration>,
    },
    /// The request completed without a change.
    TimedOut {
        /// Server-requested delay before the next long poll.
        backoff: Option<Duration>,
    },
    /// Dropbox invalidated the cursor and requires a complete rebuild.
    CursorReset,
}

/// Confirmed state of one Dropbox path after a mutation or verification read.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RemotePathState {
    /// Dropbox explicitly reports that the path is absent.
    Absent,
    /// A downloadable regular file is present.
    File(RemoteFile),
    /// A folder is present.
    Folder,
    /// A present object cannot be represented as a regular file or folder.
    Unsupported,
}

/// Durable outcome of one conditional Dropbox mutation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MutationOutcome {
    /// The desired state is confirmed at the path.
    Applied(RemotePathState),
    /// The original precondition is unchanged, so the journaled mutation remains retry-safe.
    Pending,
    /// A different confirmed state replaced the mutation's precondition.
    PreconditionChanged(RemotePathState),
}

/// Direct blocking client for Dropbox endpoints.
pub struct DropboxClient {
    access_token: AccessToken,
    root: DropboxRoot,
    endpoints: DropboxEndpoints,
    agent: ureq::Agent,
    download_agent: ureq::Agent,
    transfer_observer: Option<TransferObserver>,
}

impl DropboxClient {
    /// Construct a client using Dropbox's production endpoints.
    #[must_use]
    pub fn new(access_token: AccessToken, root: DropboxRoot) -> Self {
        Self::with_endpoints(access_token, root, DropboxEndpoints::production())
    }

    /// Construct a client with explicit endpoints for a local protocol server.
    #[must_use]
    pub fn with_endpoints(
        access_token: AccessToken,
        root: DropboxRoot,
        endpoints: DropboxEndpoints,
    ) -> Self {
        let config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(JSON_REQUEST_SECONDS)))
            .timeout_connect(Some(Duration::from_secs(CONNECT_SECONDS)))
            .build();
        Self {
            access_token,
            root,
            endpoints,
            agent: ureq::Agent::new_with_config(config),
            download_agent: exact_download_agent(),
            transfer_observer: None,
        }
    }

    /// Publish throttled samples while blocking file transfers are active.
    #[must_use]
    pub fn with_transfer_observer(mut self, observer: TransferObserver) -> Self {
        self.transfer_observer = Some(observer);
        self
    }

    /// Inspect a newly authorized token and bind it to Dropbox's current namespace.
    pub fn link(
        access_token: AccessToken,
        authorized_account_id: impl Into<String>,
        remote_root: impl Into<String>,
    ) -> Result<DropboxLink, DropboxError> {
        Self::link_with_endpoints(
            access_token,
            authorized_account_id,
            remote_root,
            DropboxEndpoints::production(),
        )
    }

    /// Inspect a new token through explicit local protocol endpoints.
    pub fn link_with_endpoints(
        access_token: AccessToken,
        authorized_account_id: impl Into<String>,
        remote_root: impl Into<String>,
        endpoints: DropboxEndpoints,
    ) -> Result<DropboxLink, DropboxError> {
        let authorized_account_id = authorized_account_id.into();
        let root = DropboxRoot::new(&authorized_account_id, "", remote_root)?;
        let mut client = Self::with_endpoints(access_token, root, endpoints);
        let account = client.current_account()?;
        if account.account_id != authorized_account_id {
            return Ok(DropboxLink::AccountChanged);
        }
        client.root.namespace_id = account.root_info.root_namespace_id;
        client.validate_remote_root()?;
        Ok(DropboxLink::Linked(Box::new(client)))
    }

    /// Return the non-secret identity stored beside this client's token.
    #[must_use]
    pub fn binding(&self) -> DropboxBinding {
        self.root.binding()
    }

    /// Verify that the token still belongs to the configured account and root.
    pub fn validate_account(
        &self,
        journal: &mut Journal,
    ) -> Result<AccountValidation, DropboxError> {
        let response = self.current_account()?;
        if response.account_id != self.root.account_id {
            Ok(AccountValidation::AccountChanged)
        } else if response.root_info.root_namespace_id != self.root.namespace_id {
            Ok(AccountValidation::RootChanged)
        } else {
            self.validate_remote_root()?;
            match journal
                .bind_dropbox_root(&self.root.binding())
                .map_err(|source| DropboxError::Journal { source })?
            {
                DropboxBindingWrite::Bound | DropboxBindingWrite::AlreadyBound => {
                    Ok(AccountValidation::Valid)
                }
                DropboxBindingWrite::Mismatch { .. } => {
                    Ok(AccountValidation::JournalBindingChanged)
                }
            }
        }
    }

    /// Fetch every required page and atomically publish one complete inventory.
    ///
    /// An API or decoding failure leaves the previous journal snapshot intact.
    /// A reset cursor is rebuilt from a new recursive listing before publication.
    pub fn refresh_inventory(
        &self,
        journal: &mut Journal,
    ) -> Result<InventoryRefresh, DropboxError> {
        if self.validate_account(journal)? != AccountValidation::Valid {
            return Err(DropboxError::AccountBindingChanged);
        }
        let current = journal
            .remote_inventory()
            .map_err(|source| DropboxError::Journal { source })?;
        let (records, cursor, outcome) = if let Some(cursor) = current.cursor {
            match self.probe_cursor(&cursor)? {
                CursorProbe::Unchanged { cursor } => {
                    (current.observations, cursor, InventoryRefresh::Published)
                }
                CursorProbe::Changed => {
                    let (records, cursor) = self.full_inventory()?;
                    (records, cursor, InventoryRefresh::Published)
                }
                CursorProbe::Reset => {
                    let (records, cursor) = self.full_inventory()?;
                    (records, cursor, InventoryRefresh::RebuiltAfterCursorReset)
                }
            }
        } else {
            let (records, cursor) = self.full_inventory()?;
            (records, cursor, InventoryRefresh::Published)
        };
        journal
            .publish_remote_inventory(&cursor, &records)
            .map_err(|source| DropboxError::Journal { source })?;
        Ok(outcome)
    }

    /// Block until Dropbox reports cursor changes or the request times out.
    pub fn long_poll(
        &self,
        cursor: &str,
        timeout: Duration,
    ) -> Result<LongPollWakeup, DropboxError> {
        let seconds = timeout.as_secs();
        if !(LONG_POLL_MINIMUM_SECONDS..=LONG_POLL_MAXIMUM_SECONDS).contains(&seconds) {
            return Err(DropboxError::InvalidLongPollTimeout);
        }
        let url = self.endpoints.notify("/files/list_folder/longpoll");
        let config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(
                timeout.saturating_add(Duration::from_secs(LONG_POLL_GRACE_SECONDS)),
            ))
            .timeout_connect(Some(Duration::from_secs(CONNECT_SECONDS)))
            .build();
        let mut response = ureq::Agent::new_with_config(config)
            .post(&url)
            .send_json(LongPollRequest {
                cursor,
                timeout: seconds,
            })
            .map_err(|source| DropboxError::Transport {
                operation: "wait for Dropbox changes",
                source,
            })?;
        let status = response.status().as_u16();
        if status == 409 {
            let error: TaggedError =
                response
                    .body_mut()
                    .read_json()
                    .map_err(|source| DropboxError::Response {
                        operation: "decode Dropbox long-poll error",
                        source,
                    })?;
            if error.error.tag == "reset" {
                return Ok(LongPollWakeup::CursorReset);
            }
        }
        require_success(
            status,
            response.headers().get("Retry-After"),
            "wait for Dropbox changes",
        )?;
        let payload: LongPollResponse =
            response
                .body_mut()
                .read_json()
                .map_err(|source| DropboxError::Response {
                    operation: "decode Dropbox long-poll response",
                    source,
                })?;
        let backoff = payload.backoff.map(Duration::from_secs);
        Ok(if payload.changes {
            LongPollWakeup::Changes { backoff }
        } else {
            LongPollWakeup::TimedOut { backoff }
        })
    }

    /// Download one exact Dropbox revision directly into verified local staging.
    pub fn stage_exact_download(
        &self,
        sync_root: impl AsRef<Path>,
        target: impl AsRef<Path>,
        remote: &RemoteFile,
    ) -> Result<StageOutcome<()>, DropboxError> {
        let target = target.as_ref();
        self.stage_exact_download_for(sync_root, target, target, remote)
    }

    pub(crate) fn stage_exact_download_for(
        &self,
        sync_root: impl AsRef<Path>,
        target: impl AsRef<Path>,
        synchronized_path: &Path,
        remote: &RemoteFile,
    ) -> Result<StageOutcome<()>, DropboxError> {
        let sync_root = sync_root.as_ref();
        let root = open_root(sync_root, "open sync root for exact Dropbox download")
            .map_err(|source| DropboxError::LocalStage { source })?;
        self.stage_exact_download_for_at(
            &root,
            sync_root,
            target.as_ref(),
            synchronized_path,
            remote,
            None,
        )
    }

    pub(crate) fn stage_exact_download_for_at(
        &self,
        root: &OwnedFd,
        root_path: &Path,
        target: &Path,
        synchronized_path: &Path,
        remote: &RemoteFile,
        lease: Option<&DownloadSlotLease>,
    ) -> Result<StageOutcome<()>, DropboxError> {
        let partial = if let Some(lease) = lease {
            match prepare_download_slot_at(root, root_path, target, &remote.content, lease)
                .map_err(|source| DropboxError::LocalStage { source })?
            {
                DownloadPreparation::Ready(partial) => Some(partial),
                DownloadPreparation::Complete(outcome) => return Ok(outcome),
                DownloadPreparation::Ephemeral => None,
            }
        } else {
            None
        };
        if partial.is_none()
            && let Some(outcome) =
                existing_download_stage_at(root, root_path, target, &remote.content)
                    .map_err(|source| DropboxError::LocalStage { source })?
        {
            return Ok(outcome);
        }
        let offset = partial.as_ref().map_or(0, |partial| partial.offset());
        let argument = serde_json::to_string(&DownloadRequest {
            path: format!("rev:{}", remote.revision.as_str()),
        })
        .map_err(|source| DropboxError::Json {
            operation: "encode exact-revision download request",
            source,
        })?;
        let authorization = format!("Bearer {}", self.access_token.expose());
        let path_root = self.path_root_header()?;
        let url = self.endpoints.content("/files/download");
        let request = self
            .download_agent
            .post(&url)
            .header("Authorization", &authorization)
            .header("Dropbox-API-Path-Root", &path_root)
            .header("Dropbox-API-Arg", &argument);
        let range = format!("bytes={offset}-");
        let request = if offset == 0 {
            request
        } else {
            request.header("Range", &range)
        };
        let response = request
            .send_empty()
            .map_err(|source| DropboxError::Transport {
                operation: "download exact Dropbox revision",
                source,
            })?;
        let status = response.status().as_u16();
        require_success(
            status,
            response.headers().get("Retry-After"),
            "download exact Dropbox revision",
        )?;
        if (offset == 0 && status != 200) || (offset != 0 && status != 206) {
            return Err(DropboxError::InvalidDownloadRange);
        }
        let metadata_header = response
            .headers()
            .get("Dropbox-API-Result")
            .ok_or(DropboxError::MissingDownloadMetadata)?
            .to_str()
            .map_err(|source| DropboxError::Header {
                operation: "decode Dropbox download metadata header",
                source,
            })?;
        let metadata: DownloadMetadata =
            serde_json::from_str(metadata_header).map_err(|source| DropboxError::Json {
                operation: "decode Dropbox download metadata",
                source,
            })?;
        if metadata.rev != remote.revision.as_str() {
            return Err(DropboxError::DownloadedRevisionChanged);
        }
        if metadata.content_hash != remote.content.as_str() {
            return Err(DropboxError::DownloadedIdentityChanged);
        }
        if offset > metadata.size {
            return Err(DropboxError::DownloadedSizeChanged);
        }
        let remaining = metadata
            .size
            .checked_sub(offset)
            .ok_or(DropboxError::DownloadedSizeChanged)?;
        if offset != 0 {
            let content_range = response
                .headers()
                .get("Content-Range")
                .ok_or(DropboxError::InvalidDownloadRange)?
                .to_str()
                .map_err(|source| DropboxError::Header {
                    operation: "decode Dropbox download range header",
                    source,
                })?;
            validate_content_range(content_range, offset, metadata.size)?;
        }
        if let Some(length) = response.headers().get("Content-Length") {
            let length = length
                .to_str()
                .ok()
                .and_then(|value| value.parse::<u64>().ok());
            if length != Some(remaining) {
                return Err(DropboxError::DownloadedLengthChanged);
            }
        }
        let (_, body) = response.into_parts();
        let mut reader = ProgressReader::new_at(
            body.into_reader(),
            self.transfer_observer.as_ref(),
            TransferDirection::Download,
            synchronized_path,
            offset,
            Some(metadata.size),
        );
        if let Some(partial) = partial {
            partial
                .append(metadata.size, &mut reader)
                .map_err(|source| DropboxError::LocalStage { source })
        } else {
            let staged = stage_download_at(root, root_path, target, &remote.content, &mut reader)
                .map_err(|source| DropboxError::LocalStage { source })?;
            if matches!(
                &staged,
                StageOutcome::AlreadyStaged(()) | StageOutcome::DestinationOccupied { .. }
            ) {
                io::copy(&mut reader, &mut io::sink())
                    .map_err(|source| DropboxError::DownloadBody { source })?;
            }
            if reader.done() != metadata.size {
                return Err(DropboxError::DownloadedLengthChanged);
            }
            Ok(staged)
        }
    }

    /// Strictly create one Dropbox file from verified immutable staging.
    pub fn create_file(
        &self,
        relative: impl AsRef<Path>,
        staged: &StagedUpload,
    ) -> Result<MutationOutcome, DropboxError> {
        let relative = relative.as_ref();
        let target = self.mutation_target(relative)?;
        let expectation = MutationExpectation::CreateFile {
            desired: staged.content().clone(),
        };
        self.upload_file(
            &target,
            relative,
            UploadMode::Add("add"),
            staged,
            expectation,
            "strictly create Dropbox file",
        )
    }

    /// Replace one Dropbox file only while its exact revision is current.
    pub fn replace_file(
        &self,
        relative: impl AsRef<Path>,
        expected: &DropboxRevision,
        staged: &StagedUpload,
    ) -> Result<MutationOutcome, DropboxError> {
        let relative = relative.as_ref();
        let target = self.mutation_target(relative)?;
        let expectation = MutationExpectation::ReplaceFile {
            expected: expected.clone(),
            desired: staged.content().clone(),
        };
        self.upload_file(
            &target,
            relative,
            UploadMode::Update(UpdateMode {
                tag: "update",
                update: expected.as_str(),
            }),
            staged,
            expectation,
            "conditionally replace Dropbox file",
        )
    }

    /// Delete one Dropbox file only while its exact revision is current.
    pub fn delete_file(
        &self,
        relative: impl AsRef<Path>,
        expected: &DropboxRevision,
    ) -> Result<MutationOutcome, DropboxError> {
        let target = self.mutation_target(relative.as_ref())?;
        let expectation = MutationExpectation::DeleteFile {
            expected: expected.clone(),
        };
        let url = self.endpoints.api("/files/delete_v2");
        let response = self.authorized_post(&url)?.send_json(DeleteRequest {
            path: &target,
            parent_rev: expected.as_str(),
        });
        let operation = "conditionally delete Dropbox file";
        match response {
            Err(source) => self.resolve_ambiguous(
                &target,
                &expectation,
                DropboxError::Transport { operation, source },
            ),
            Ok(mut response) => {
                let status = response.status().as_u16();
                if (200..300).contains(&status) {
                    let confirmation = response
                        .body_mut()
                        .read_json::<MetadataResponse>()
                        .map_err(|source| DropboxError::Response { operation, source })
                        .and_then(|payload| {
                            validate_deleted_file(&target, payload.metadata, expected)
                        });
                    match confirmation {
                        Ok(()) => Ok(MutationOutcome::Applied(RemotePathState::Absent)),
                        Err(failure) => self.resolve_ambiguous(&target, &expectation, failure),
                    }
                } else {
                    self.resolve_mutation_status(&target, &expectation, &response, operation)
                }
            }
        }
    }

    /// Strictly create one Dropbox folder for a future directory intent.
    pub fn create_folder(
        &self,
        relative: impl AsRef<Path>,
    ) -> Result<MutationOutcome, DropboxError> {
        let target = self.mutation_target(relative.as_ref())?;
        let expectation = MutationExpectation::CreateFolder;
        let url = self.endpoints.api("/files/create_folder_v2");
        let response = self.authorized_post(&url)?.send_json(CreateFolderRequest {
            path: &target,
            autorename: false,
        });
        let operation = "strictly create Dropbox folder";
        match response {
            Err(source) => self.resolve_ambiguous(
                &target,
                &expectation,
                DropboxError::Transport { operation, source },
            ),
            Ok(mut response) => {
                let status = response.status().as_u16();
                if (200..300).contains(&status) {
                    let confirmation = response
                        .body_mut()
                        .read_json::<MetadataResponse>()
                        .map_err(|source| DropboxError::Response { operation, source })
                        .and_then(|payload| validate_created_folder(&target, payload.metadata));
                    match confirmation {
                        Ok(()) => Ok(MutationOutcome::Applied(RemotePathState::Folder)),
                        Err(failure) => self.resolve_ambiguous(&target, &expectation, failure),
                    }
                } else {
                    self.resolve_mutation_status(&target, &expectation, &response, operation)
                }
            }
        }
    }

    fn upload_file(
        &self,
        target: &str,
        synchronized_path: &Path,
        mode: UploadMode<'_>,
        staged: &StagedUpload,
        expectation: MutationExpectation,
        operation: &'static str,
    ) -> Result<MutationOutcome, DropboxError> {
        let bytes = staged
            .open_verified()
            .map_err(|source| DropboxError::LocalStage { source })?;
        let size = bytes
            .metadata()
            .map_err(|source| DropboxError::UploadStageMetadata { source })?
            .len();
        validate_upload_size(size)?;
        if size > DIRECT_UPLOAD_MAX_BYTES {
            return self.upload_session_file(
                target,
                synchronized_path,
                mode,
                staged,
                expectation,
                operation,
                bytes,
                size,
            );
        }
        validate_direct_upload_size(size)?;
        let argument = ascii_json(&UploadRequest {
            path: target,
            mode,
            autorename: false,
            strict_conflict: true,
            content_hash: staged.content().as_str(),
        })?;
        let authorization = format!("Bearer {}", self.access_token.expose());
        let path_root = self.path_root_header()?;
        let url = self.endpoints.content("/files/upload");
        let config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(DOWNLOAD_SECONDS)))
            .timeout_connect(Some(Duration::from_secs(CONNECT_SECONDS)))
            .build();
        let mut reader = ProgressReader::new(
            bytes,
            self.transfer_observer.as_ref(),
            TransferDirection::Upload,
            synchronized_path,
            Some(size),
        );
        let response = ureq::Agent::new_with_config(config)
            .post(&url)
            .header("Authorization", authorization)
            .header("Dropbox-API-Path-Root", path_root)
            .header("Dropbox-API-Arg", argument)
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", size.to_string())
            .send(ureq::SendBody::from_reader(&mut reader));
        match response {
            Err(source) => self.resolve_ambiguous(
                target,
                &expectation,
                DropboxError::Transport { operation, source },
            ),
            Ok(mut response) => {
                let status = response.status().as_u16();
                if (200..300).contains(&status) {
                    let confirmation = response
                        .body_mut()
                        .read_json::<ListEntry>()
                        .map_err(|source| DropboxError::Response { operation, source })
                        .and_then(|metadata| {
                            validate_uploaded_file(target, metadata, staged.content())
                        });
                    match confirmation {
                        Ok(remote) => Ok(MutationOutcome::Applied(RemotePathState::File(remote))),
                        Err(failure) => self.resolve_ambiguous(target, &expectation, failure),
                    }
                } else {
                    self.resolve_mutation_status(target, &expectation, &response, operation)
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn upload_session_file(
        &self,
        target: &str,
        synchronized_path: &Path,
        mode: UploadMode<'_>,
        staged: &StagedUpload,
        expectation: MutationExpectation,
        operation: &'static str,
        bytes: std::fs::File,
        size: u64,
    ) -> Result<MutationOutcome, DropboxError> {
        let authorization = format!("Bearer {}", self.access_token.expose());
        let path_root = self.path_root_header()?;
        let config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(DOWNLOAD_SECONDS)))
            .timeout_connect(Some(Duration::from_secs(CONNECT_SECONDS)))
            .build();
        let agent = ureq::Agent::new_with_config(config);
        let mut reader = ProgressReader::new(
            bytes,
            self.transfer_observer.as_ref(),
            TransferDirection::Upload,
            synchronized_path,
            Some(size),
        );

        let start_argument = ascii_json(&UploadSessionStartRequest { close: false })?;
        let start_url = self.endpoints.content("/files/upload_session/start");
        let mut start_response = agent
            .post(&start_url)
            .header("Authorization", &authorization)
            .header("Dropbox-API-Path-Root", &path_root)
            .header("Dropbox-API-Arg", start_argument)
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", "0")
            .send_empty()
            .map_err(|source| DropboxError::Transport {
                operation: "start Dropbox upload session",
                source,
            })?;
        require_success(
            start_response.status().as_u16(),
            start_response.headers().get("Retry-After"),
            "start Dropbox upload session",
        )?;
        let session = start_response
            .body_mut()
            .read_json::<UploadSessionStartResponse>()
            .map_err(|source| DropboxError::Response {
                operation: "decode Dropbox upload-session start response",
                source,
            })?;

        let mut offset = 0;
        while offset < size {
            let next = offset
                .checked_add(UPLOAD_SESSION_CHUNK_BYTES.min(size.saturating_sub(offset)))
                .ok_or(DropboxError::UploadSessionOffsetOverflow)?;
            self.append_upload_session_chunk(
                &agent,
                &authorization,
                &path_root,
                &session.session_id,
                &mut reader,
                offset,
                next,
            )?;
            offset = next;
        }

        let finish_argument = ascii_json(&UploadSessionFinishRequest {
            cursor: UploadSessionCursor {
                session_id: &session.session_id,
                offset,
            },
            commit: UploadSessionCommit {
                path: target,
                mode,
                autorename: false,
                strict_conflict: true,
            },
        })?;
        let finish_url = self.endpoints.content("/files/upload_session/finish");
        let response = agent
            .post(&finish_url)
            .header("Authorization", authorization)
            .header("Dropbox-API-Path-Root", path_root)
            .header("Dropbox-API-Arg", finish_argument)
            .header("Content-Type", "application/octet-stream")
            .header("Content-Length", "0")
            .send_empty();
        match response {
            Err(source) => self.resolve_ambiguous(
                target,
                &expectation,
                DropboxError::Transport { operation, source },
            ),
            Ok(mut response) => {
                let status = response.status().as_u16();
                if (200..300).contains(&status) {
                    let confirmation = response
                        .body_mut()
                        .read_json::<ListEntry>()
                        .map_err(|source| DropboxError::Response { operation, source })
                        .and_then(|metadata| {
                            validate_uploaded_file(target, metadata, staged.content())
                        });
                    match confirmation {
                        Ok(remote) => Ok(MutationOutcome::Applied(RemotePathState::File(remote))),
                        Err(failure) => self.resolve_ambiguous(target, &expectation, failure),
                    }
                } else {
                    self.resolve_mutation_status(target, &expectation, &response, operation)
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn append_upload_session_chunk<R: Read + Seek>(
        &self,
        agent: &ureq::Agent,
        authorization: &str,
        path_root: &str,
        session_id: &str,
        reader: &mut R,
        offset: u64,
        next: u64,
    ) -> Result<(), DropboxError> {
        let length = next
            .checked_sub(offset)
            .ok_or(DropboxError::UploadSessionOffsetOverflow)?;
        let argument = ascii_json(&UploadSessionAppendRequest {
            cursor: UploadSessionCursor { session_id, offset },
            close: false,
        })?;
        let url = self.endpoints.content("/files/upload_session/append_v2");
        for attempt in 0..=1 {
            reader
                .seek(SeekFrom::Start(offset))
                .map_err(|source| DropboxError::UploadStageSeek { source })?;
            let mut body = reader.take(length);
            let response = agent
                .post(&url)
                .header("Authorization", authorization)
                .header("Dropbox-API-Path-Root", path_root)
                .header("Dropbox-API-Arg", &argument)
                .header("Content-Type", "application/octet-stream")
                .header("Content-Length", length.to_string())
                .send(ureq::SendBody::from_reader(&mut body));
            match response {
                Err(_) if attempt == 0 => continue,
                Err(source) => {
                    return Err(DropboxError::Transport {
                        operation: "append Dropbox upload session",
                        source,
                    });
                }
                Ok(mut response) => {
                    let status = response.status().as_u16();
                    if (200..300).contains(&status) {
                        return Ok(());
                    }
                    if status == 409 {
                        let offset_error = response
                            .body_mut()
                            .read_json::<UploadSessionAppendErrorResponse>()
                            .map_err(|source| DropboxError::Response {
                                operation: "decode Dropbox upload-session append error",
                                source,
                            })?
                            .incorrect_offset();
                        if let Some(correct_offset) = offset_error {
                            return if correct_offset == next {
                                Ok(())
                            } else {
                                Err(DropboxError::IncorrectUploadSessionOffset {
                                    requested_offset: offset,
                                    chunk_bytes: length,
                                    correct_offset,
                                })
                            };
                        }
                    }
                    return Err(status_failure(
                        status,
                        response.headers().get("Retry-After"),
                        "append Dropbox upload session",
                    ));
                }
            }
        }
        Err(DropboxError::UploadSessionOffsetOverflow)
    }

    fn resolve_mutation_status(
        &self,
        target: &str,
        expectation: &MutationExpectation,
        response: &ureq::http::Response<ureq::Body>,
        operation: &'static str,
    ) -> Result<MutationOutcome, DropboxError> {
        let status = response.status().as_u16();
        let failure = status_failure(status, response.headers().get("Retry-After"), operation);
        if status == 409 {
            self.resolve_explicit_conflict(target, expectation, failure)
        } else if (500..600).contains(&status) {
            self.resolve_ambiguous(target, expectation, failure)
        } else {
            Err(failure)
        }
    }

    fn resolve_explicit_conflict(
        &self,
        target: &str,
        expectation: &MutationExpectation,
        original: DropboxError,
    ) -> Result<MutationOutcome, DropboxError> {
        match self.metadata_state(target) {
            Ok(state) => match expectation.classify(state) {
                MutationOutcome::Applied(state) => Ok(MutationOutcome::Applied(state)),
                MutationOutcome::PreconditionChanged(state) => {
                    Ok(MutationOutcome::PreconditionChanged(state))
                }
                MutationOutcome::Pending => Err(original),
            },
            Err(_) => Err(original),
        }
    }

    fn resolve_ambiguous(
        &self,
        target: &str,
        expectation: &MutationExpectation,
        original: DropboxError,
    ) -> Result<MutationOutcome, DropboxError> {
        match self.metadata_state(target) {
            Ok(state) => Ok(expectation.classify(state)),
            Err(_) => Err(original),
        }
    }

    fn metadata_state(&self, target: &str) -> Result<RemotePathState, DropboxError> {
        let operation = "verify Dropbox mutation";
        let url = self.endpoints.api("/files/get_metadata");
        let mut response = self
            .authorized_post(&url)?
            .send_json(MetadataRequest {
                path: target,
                include_deleted: true,
            })
            .map_err(|source| DropboxError::Transport { operation, source })?;
        let status = response.status().as_u16();
        if status == 409 {
            let missing = response
                .body_mut()
                .read_json::<MetadataError>()
                .map_err(|source| DropboxError::Response { operation, source })?;
            if missing.explicitly_not_found() {
                return Ok(RemotePathState::Absent);
            }
            return Err(DropboxError::HttpStatus { operation, status });
        }
        require_success(status, response.headers().get("Retry-After"), operation)?;
        let metadata = response
            .body_mut()
            .read_json::<ListEntry>()
            .map_err(|source| DropboxError::Response { operation, source })?;
        metadata_remote_state(target, metadata)
    }

    fn mutation_target(&self, relative: &Path) -> Result<String, DropboxError> {
        let mut suffix = String::new();
        for component in relative.components() {
            let Component::Normal(component) = component else {
                return Err(DropboxError::InvalidMutationPath);
            };
            let component = component
                .to_str()
                .ok_or(DropboxError::InvalidMutationPath)?;
            if invalid_dropbox_component(component) {
                return Err(DropboxError::InvalidMutationPath);
            }
            suffix.push('/');
            suffix.push_str(component);
        }
        if suffix.is_empty() {
            return Err(DropboxError::InvalidMutationPath);
        }
        Ok(format!("{}{}", self.root.path, suffix))
    }

    fn current_account(&self) -> Result<CurrentAccount, DropboxError> {
        let url = self.endpoints.api("/users/get_current_account");
        let authorization = format!("Bearer {}", self.access_token.expose());
        let mut response = self
            .agent
            .post(&url)
            .header("Authorization", authorization)
            .send_json(EmptyRequest {})
            .map_err(|source| DropboxError::Transport {
                operation: "validate Dropbox account",
                source,
            })?;
        require_success(
            response.status().as_u16(),
            response.headers().get("Retry-After"),
            "validate Dropbox account",
        )?;
        response
            .body_mut()
            .read_json()
            .map_err(|source| DropboxError::Response {
                operation: "decode Dropbox account response",
                source,
            })
    }

    fn validate_remote_root(&self) -> Result<(), DropboxError> {
        if self.root.path.is_empty() {
            return Ok(());
        }
        let url = self.endpoints.api("/files/get_metadata");
        let mut response = self
            .authorized_post(&url)?
            .send_json(MetadataRequest {
                path: &self.root.path,
                include_deleted: false,
            })
            .map_err(|source| DropboxError::Transport {
                operation: "validate configured Dropbox root",
                source,
            })?;
        let status = response.status().as_u16();
        if status == 409 {
            return Err(DropboxError::RemoteRootUnavailable);
        }
        require_success(
            status,
            response.headers().get("Retry-After"),
            "validate configured Dropbox root",
        )?;
        let metadata: ListEntry =
            response
                .body_mut()
                .read_json()
                .map_err(|source| DropboxError::Response {
                    operation: "decode configured Dropbox root metadata",
                    source,
                })?;
        if metadata.path_lower.as_deref() != Some(self.root.lower_path.as_str()) {
            return Err(DropboxError::RemoteRootUnavailable);
        }
        if !matches!(metadata.tag, EntryTag::Folder) {
            return Err(DropboxError::RemoteRootNotFolder);
        }
        if metadata.restricted() {
            return Err(DropboxError::RemoteRootRestricted);
        }
        Ok(())
    }

    fn full_inventory(&self) -> Result<(Vec<RemoteObservationRecord>, String), DropboxError> {
        let first: ListFolderResponse = self.post_api(
            "/files/list_folder",
            &ListFolderRequest {
                path: &self.root.path,
                recursive: true,
                include_deleted: false,
            },
            "start complete Dropbox listing",
        )?;
        let mut records = BTreeMap::new();
        let mut page = first;
        loop {
            apply_entries(&self.root, &mut records, page.entries)?;
            if !page.has_more {
                return Ok((records.into_values().collect(), page.cursor));
            }
            let previous = page.cursor;
            page = match self.list_continue(&previous)? {
                ContinuePage::Page(next) if next.cursor != previous => next,
                ContinuePage::Page(_) => return Err(DropboxError::CursorDidNotAdvance),
                ContinuePage::Reset => return Err(DropboxError::ResetDuringFreshListing),
            };
        }
    }

    fn probe_cursor(&self, cursor: &str) -> Result<CursorProbe, DropboxError> {
        match self.list_continue(cursor)? {
            ContinuePage::Reset => Ok(CursorProbe::Reset),
            ContinuePage::Page(page) if page.entries.is_empty() && !page.has_more => {
                Ok(CursorProbe::Unchanged {
                    cursor: page.cursor,
                })
            }
            ContinuePage::Page(_) => Ok(CursorProbe::Changed),
        }
    }

    fn list_continue(&self, cursor: &str) -> Result<ContinuePage, DropboxError> {
        let url = self.endpoints.api("/files/list_folder/continue");
        let mut response = self
            .authorized_post(&url)?
            .send_json(CursorRequest { cursor })
            .map_err(|source| DropboxError::Transport {
                operation: "continue complete Dropbox listing",
                source,
            })?;
        let status = response.status().as_u16();
        if status == 409 {
            let error: TaggedError =
                response
                    .body_mut()
                    .read_json()
                    .map_err(|source| DropboxError::Response {
                        operation: "decode Dropbox cursor error",
                        source,
                    })?;
            if error.error.tag == "reset" {
                return Ok(ContinuePage::Reset);
            }
        }
        require_success(
            status,
            response.headers().get("Retry-After"),
            "continue complete Dropbox listing",
        )?;
        let page = response
            .body_mut()
            .read_json()
            .map_err(|source| DropboxError::Response {
                operation: "decode Dropbox listing page",
                source,
            })?;
        Ok(ContinuePage::Page(page))
    }

    fn post_api<Body, Response>(
        &self,
        route: &str,
        body: &Body,
        operation: &'static str,
    ) -> Result<Response, DropboxError>
    where
        Body: Serialize,
        Response: for<'de> Deserialize<'de>,
    {
        let url = self.endpoints.api(route);
        let mut response = self
            .authorized_post(&url)?
            .send_json(body)
            .map_err(|source| DropboxError::Transport { operation, source })?;
        require_success(
            response.status().as_u16(),
            response.headers().get("Retry-After"),
            operation,
        )?;
        response
            .body_mut()
            .read_json()
            .map_err(|source| DropboxError::Response { operation, source })
    }

    fn authorized_post(
        &self,
        url: &str,
    ) -> Result<ureq::RequestBuilder<ureq::typestate::WithBody>, DropboxError> {
        let authorization = format!("Bearer {}", self.access_token.expose());
        let path_root = self.path_root_header()?;
        Ok(self
            .agent
            .post(url)
            .header("Authorization", authorization)
            .header("Dropbox-API-Path-Root", path_root))
    }

    fn path_root_header(&self) -> Result<String, DropboxError> {
        ascii_json(&PathRootHeader {
            tag: "root",
            root: &self.root.namespace_id,
        })
    }
}

enum MutationExpectation {
    CreateFile {
        desired: ContentIdentity,
    },
    ReplaceFile {
        expected: DropboxRevision,
        desired: ContentIdentity,
    },
    DeleteFile {
        expected: DropboxRevision,
    },
    CreateFolder,
}

impl MutationExpectation {
    fn classify(&self, state: RemotePathState) -> MutationOutcome {
        let unchanged = match (self, &state) {
            (Self::CreateFile { .. } | Self::CreateFolder, RemotePathState::Absent) => true,
            (
                Self::ReplaceFile { expected, .. } | Self::DeleteFile { expected },
                RemotePathState::File(remote),
            ) => &remote.revision == expected,
            _ => false,
        };
        if unchanged {
            return MutationOutcome::Pending;
        }
        let applied = match (self, &state) {
            (Self::CreateFile { desired }, RemotePathState::File(remote))
            | (Self::ReplaceFile { desired, .. }, RemotePathState::File(remote)) => {
                &remote.content == desired
            }
            (Self::DeleteFile { .. }, RemotePathState::Absent)
            | (Self::CreateFolder, RemotePathState::Folder) => true,
            _ => false,
        };
        if applied {
            MutationOutcome::Applied(state)
        } else {
            MutationOutcome::PreconditionChanged(state)
        }
    }
}

enum CursorProbe {
    Unchanged { cursor: String },
    Changed,
    Reset,
}

enum ContinuePage {
    Page(ListFolderResponse),
    Reset,
}

#[derive(Serialize)]
struct EmptyRequest {}

#[derive(Serialize)]
struct PathRootHeader<'a> {
    #[serde(rename = ".tag")]
    tag: &'static str,
    root: &'a str,
}

#[derive(Deserialize)]
struct CurrentAccount {
    account_id: String,
    root_info: RootInfo,
}

#[derive(Deserialize)]
struct RootInfo {
    root_namespace_id: String,
}

#[derive(Serialize)]
struct ListFolderRequest<'a> {
    path: &'a str,
    recursive: bool,
    include_deleted: bool,
}

#[derive(Serialize)]
struct MetadataRequest<'a> {
    path: &'a str,
    include_deleted: bool,
}

#[derive(Serialize)]
struct CursorRequest<'a> {
    cursor: &'a str,
}

#[derive(Deserialize)]
struct ListFolderResponse {
    entries: Vec<ListEntry>,
    cursor: String,
    has_more: bool,
}

#[derive(Deserialize)]
struct ListEntry {
    #[serde(rename = ".tag")]
    tag: EntryTag,
    path_lower: Option<String>,
    path_display: Option<String>,
    rev: Option<String>,
    content_hash: Option<String>,
    #[serde(default = "default_true")]
    is_downloadable: bool,
    symlink_info: Option<serde_json::Value>,
    sharing_info: Option<FolderSharingInfo>,
}

impl ListEntry {
    fn restricted(&self) -> bool {
        self.sharing_info
            .as_ref()
            .is_some_and(|sharing| sharing.no_access || sharing.traverse_only)
    }
}

#[derive(Deserialize)]
struct FolderSharingInfo {
    #[serde(default)]
    no_access: bool,
    #[serde(default)]
    traverse_only: bool,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum EntryTag {
    File,
    Folder,
    Deleted,
}

#[derive(Deserialize)]
struct TaggedError {
    error: ErrorTag,
}

#[derive(Deserialize)]
struct ErrorTag {
    #[serde(rename = ".tag")]
    tag: String,
}

#[derive(Serialize)]
struct LongPollRequest<'a> {
    cursor: &'a str,
    timeout: u64,
}

#[derive(Deserialize)]
struct LongPollResponse {
    changes: bool,
    backoff: Option<u64>,
}

#[derive(Serialize)]
struct DownloadRequest {
    path: String,
}

#[derive(Deserialize)]
struct DownloadMetadata {
    rev: String,
    content_hash: String,
    size: u64,
}

#[derive(Serialize)]
struct UploadRequest<'a> {
    path: &'a str,
    mode: UploadMode<'a>,
    autorename: bool,
    strict_conflict: bool,
    content_hash: &'a str,
}

#[derive(Serialize)]
struct UploadSessionStartRequest {
    close: bool,
}

#[derive(Deserialize)]
struct UploadSessionStartResponse {
    session_id: String,
}

#[derive(Serialize)]
struct UploadSessionCursor<'a> {
    session_id: &'a str,
    offset: u64,
}

#[derive(Serialize)]
struct UploadSessionAppendRequest<'a> {
    cursor: UploadSessionCursor<'a>,
    close: bool,
}

#[derive(Serialize)]
struct UploadSessionFinishRequest<'a> {
    cursor: UploadSessionCursor<'a>,
    commit: UploadSessionCommit<'a>,
}

#[derive(Serialize)]
struct UploadSessionCommit<'a> {
    path: &'a str,
    mode: UploadMode<'a>,
    autorename: bool,
    strict_conflict: bool,
}

#[derive(Deserialize)]
struct UploadSessionAppendErrorResponse {
    error: UploadSessionAppendError,
}

impl UploadSessionAppendErrorResponse {
    fn incorrect_offset(self) -> Option<u64> {
        match self.error {
            UploadSessionAppendError::IncorrectOffset { correct_offset } => Some(correct_offset),
            UploadSessionAppendError::Other => None,
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = ".tag", rename_all = "snake_case")]
enum UploadSessionAppendError {
    IncorrectOffset {
        correct_offset: u64,
    },
    #[serde(other)]
    Other,
}

#[derive(Serialize)]
#[serde(untagged)]
enum UploadMode<'a> {
    Add(&'static str),
    Update(UpdateMode<'a>),
}

#[derive(Serialize)]
struct UpdateMode<'a> {
    #[serde(rename = ".tag")]
    tag: &'static str,
    update: &'a str,
}

#[derive(Serialize)]
struct DeleteRequest<'a> {
    path: &'a str,
    parent_rev: &'a str,
}

#[derive(Deserialize)]
struct MetadataResponse {
    metadata: ListEntry,
}

#[derive(Serialize)]
struct CreateFolderRequest<'a> {
    path: &'a str,
    autorename: bool,
}

#[derive(Deserialize)]
struct MetadataError {
    error: serde_json::Value,
}

impl MetadataError {
    fn explicitly_not_found(&self) -> bool {
        self.error
            .pointer("/.tag")
            .and_then(serde_json::Value::as_str)
            == Some("path")
            && self
                .error
                .pointer("/path/.tag")
                .and_then(serde_json::Value::as_str)
                == Some("not_found")
    }
}

/// Dropbox protocol, validation, or publication failure.
#[derive(Debug, Error)]
pub enum DropboxError {
    /// The configured Dropbox folder is not an API path.
    #[error("configured Dropbox root must be empty or a normalized absolute Dropbox path")]
    InvalidRootPath,
    /// A timeout outside Dropbox's documented range was requested.
    #[error("Dropbox long-poll timeout must be between 30 and 480 seconds")]
    InvalidLongPollTimeout,
    /// A mutating operation was given an empty, absolute, parent-relative, or non-UTF-8 path.
    #[error("Dropbox mutation path must be a nonempty safe relative UTF-8 path")]
    InvalidMutationPath,
    /// The immutable stage exceeds Dropbox's direct-upload endpoint limit.
    #[error(
        "immutable upload stage is {bytes} bytes; direct Dropbox uploads allow at most 157286400 bytes"
    )]
    DirectUploadTooLarge {
        /// Verified stage length.
        bytes: u64,
    },
    /// The immutable stage exceeds Dropbox's documented upload-session limit.
    #[error(
        "immutable upload stage is {bytes} bytes; Dropbox upload sessions allow at most 2199019061248 bytes"
    )]
    UploadTooLarge {
        /// Verified stage length.
        bytes: u64,
    },
    /// Dropbox reported an offset that cannot confirm the attempted sequential chunk.
    #[error(
        "Dropbox upload session reported offset {correct_offset} after a {chunk_bytes}-byte chunk at {requested_offset}"
    )]
    IncorrectUploadSessionOffset {
        /// Offset sent with the request.
        requested_offset: u64,
        /// Bytes sent with the request.
        chunk_bytes: u64,
        /// Offset Dropbox reports having stored.
        correct_offset: u64,
    },
    /// Upload-session offset arithmetic exceeded the supported integer range.
    #[error("Dropbox upload-session offset overflowed")]
    UploadSessionOffsetOverflow,
    /// The live account, Secret Service record, and journal do not share one binding.
    #[error("Dropbox account or root binding no longer matches the journal")]
    AccountBindingChanged,
    /// The configured nonempty Dropbox root could not be found.
    #[error("configured Dropbox root is unavailable")]
    RemoteRootUnavailable,
    /// The configured Dropbox root names a file rather than a folder.
    #[error("configured Dropbox root is not a folder")]
    RemoteRootNotFolder,
    /// Dropbox does not permit complete traversal of the configured root.
    #[error("configured Dropbox root cannot be traversed completely")]
    RemoteRootRestricted,
    /// A folder inside the listing cannot be traversed completely.
    #[error("Dropbox listing contains a folder that cannot be traversed completely")]
    RestrictedRemoteInventory,
    /// Dropbox rate-limited a request.
    #[error("Dropbox operation `{operation}` was rate limited")]
    RateLimited {
        /// Safe operation name.
        operation: &'static str,
        /// Server-requested delay when Dropbox returned valid delta seconds.
        retry_after: Option<Duration>,
    },
    /// Dropbox returned a non-success status.
    #[error("Dropbox operation `{operation}` returned HTTP status {status}")]
    HttpStatus {
        /// Safe operation name.
        operation: &'static str,
        /// HTTP status code.
        status: u16,
    },
    /// The request could not be completed.
    #[error("Dropbox operation `{operation}` could not reach the service")]
    Transport {
        /// Safe operation name.
        operation: &'static str,
        /// Original transport error, which does not contain request headers or bodies.
        #[source]
        source: ureq::Error,
    },
    /// A successful response did not match Dropbox's documented schema.
    #[error("Dropbox operation `{operation}` returned an invalid response")]
    Response {
        /// Safe operation name.
        operation: &'static str,
        /// Original JSON body decoding error.
        #[source]
        source: ureq::Error,
    },
    /// A locally built or header JSON value was invalid.
    #[error("Dropbox operation `{operation}` could not process protocol JSON")]
    Json {
        /// Safe operation name.
        operation: &'static str,
        /// Original JSON error.
        #[source]
        source: serde_json::Error,
    },
    /// A Dropbox response header was not valid text.
    #[error("Dropbox operation `{operation}` returned an invalid header")]
    Header {
        /// Safe operation name.
        operation: &'static str,
        /// Original header decoding error.
        #[source]
        source: ureq::http::header::ToStrError,
    },
    /// An entry did not carry a path confined to the configured Dropbox root.
    #[error("Dropbox listing contained an invalid or out-of-root path")]
    InvalidEntryPath,
    /// A downloadable file omitted required revision or content-hash metadata.
    #[error("Dropbox listing returned incomplete metadata for a downloadable file")]
    IncompleteFileMetadata,
    /// Dropbox claimed more pages without advancing its cursor.
    #[error("Dropbox listing cursor did not advance while more pages remained")]
    CursorDidNotAdvance,
    /// A brand-new listing was reset and cannot be published as complete.
    #[error("Dropbox reset a new recursive listing before it completed")]
    ResetDuringFreshListing,
    /// An exact download omitted its metadata response header.
    #[error("Dropbox exact-revision download omitted result metadata")]
    MissingDownloadMetadata,
    /// Dropbox returned a different revision than requested.
    #[error("Dropbox exact-revision download returned a different revision")]
    DownloadedRevisionChanged,
    /// Dropbox returned an identity different from the listed content hash.
    #[error("Dropbox exact-revision download returned a different content identity")]
    DownloadedIdentityChanged,
    /// Dropbox returned a size different from the durable partial metadata.
    #[error("Dropbox exact-revision download returned a different file size")]
    DownloadedSizeChanged,
    /// Dropbox did not honor an exact resume range.
    #[error("Dropbox exact-revision download returned an invalid byte range")]
    InvalidDownloadRange,
    /// Dropbox's response body length did not match its file metadata.
    #[error("Dropbox exact-revision download returned a different body length")]
    DownloadedLengthChanged,
    /// Dropbox's exact-revision response body could not be read completely.
    #[error("could not read Dropbox exact-revision download body")]
    DownloadBody {
        /// Original response-body read error.
        #[source]
        source: io::Error,
    },
    /// A successful mutation response did not describe the requested path and content.
    #[error("Dropbox returned inconsistent mutation metadata")]
    InvalidMutationMetadata,
    /// The verified upload-stage descriptor could not be inspected.
    #[error("could not inspect immutable upload staging")]
    UploadStageMetadata {
        /// Original descriptor metadata error.
        #[source]
        source: io::Error,
    },
    /// The immutable upload stage could not be repositioned after an ambiguous append.
    #[error("could not reposition immutable upload staging")]
    UploadStageSeek {
        /// Original descriptor seek error.
        #[source]
        source: io::Error,
    },
    /// Verified local staging could not be accessed.
    #[error("could not access verified local staging")]
    LocalStage {
        /// Original local staging error.
        #[source]
        source: LocalError,
    },
    /// The complete inventory could not be read or published transactionally.
    #[error("could not access the durable Dropbox inventory")]
    Journal {
        /// Original journal error.
        #[source]
        source: JournalError,
    },
}

fn require_success(
    status: u16,
    retry_after: Option<&ureq::http::HeaderValue>,
    operation: &'static str,
) -> Result<(), DropboxError> {
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(status_failure(status, retry_after, operation))
    }
}

fn validate_content_range(value: &str, offset: u64, total: u64) -> Result<(), DropboxError> {
    let Some(value) = value.strip_prefix("bytes ") else {
        return Err(DropboxError::InvalidDownloadRange);
    };
    let Some((range, reported_total)) = value.split_once('/') else {
        return Err(DropboxError::InvalidDownloadRange);
    };
    let Some((start, end)) = range.split_once('-') else {
        return Err(DropboxError::InvalidDownloadRange);
    };
    let start = start
        .parse::<u64>()
        .map_err(|_| DropboxError::InvalidDownloadRange)?;
    let end = end
        .parse::<u64>()
        .map_err(|_| DropboxError::InvalidDownloadRange)?;
    let reported_total = reported_total
        .parse::<u64>()
        .map_err(|_| DropboxError::InvalidDownloadRange)?;
    if start == offset && reported_total == total && end.checked_add(1) == Some(total) {
        Ok(())
    } else {
        Err(DropboxError::InvalidDownloadRange)
    }
}

fn status_failure(
    status: u16,
    retry_after: Option<&ureq::http::HeaderValue>,
    operation: &'static str,
) -> DropboxError {
    if status == 429 {
        let retry_after = retry_after
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok())
            .map(Duration::from_secs);
        DropboxError::RateLimited {
            operation,
            retry_after,
        }
    } else {
        DropboxError::HttpStatus { operation, status }
    }
}

fn validate_direct_upload_size(bytes: u64) -> Result<(), DropboxError> {
    if bytes > DIRECT_UPLOAD_MAX_BYTES {
        Err(DropboxError::DirectUploadTooLarge { bytes })
    } else {
        Ok(())
    }
}

fn validate_upload_size(bytes: u64) -> Result<(), DropboxError> {
    if bytes > UPLOAD_SESSION_MAX_BYTES {
        Err(DropboxError::UploadTooLarge { bytes })
    } else {
        Ok(())
    }
}

fn ascii_json(value: &impl Serialize) -> Result<String, DropboxError> {
    let json = serde_json::to_string(value).map_err(|source| DropboxError::Json {
        operation: "encode Dropbox request header",
        source,
    })?;
    let mut ascii = String::with_capacity(json.len());
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for character in json.chars() {
        if character.is_ascii() {
            ascii.push(character);
        } else {
            let mut units = [0_u16; 2];
            for unit in character.encode_utf16(&mut units) {
                ascii.push('\\');
                ascii.push('u');
                for shift in [12_u32, 8, 4, 0] {
                    let digit = usize::from((*unit >> shift) & 0x0f);
                    ascii.push(char::from(HEX[digit]));
                }
            }
        }
    }
    Ok(ascii)
}

fn validate_uploaded_file(
    target: &str,
    metadata: ListEntry,
    expected: &ContentIdentity,
) -> Result<RemoteFile, DropboxError> {
    validate_mutation_path(target, &metadata)?;
    let remote = complete_remote_file(metadata).ok_or(DropboxError::InvalidMutationMetadata)?;
    if &remote.content != expected {
        return Err(DropboxError::InvalidMutationMetadata);
    }
    Ok(remote)
}

fn validate_deleted_file(
    target: &str,
    metadata: ListEntry,
    expected: &DropboxRevision,
) -> Result<(), DropboxError> {
    validate_mutation_path(target, &metadata)?;
    let remote = complete_remote_file(metadata).ok_or(DropboxError::InvalidMutationMetadata)?;
    if &remote.revision != expected {
        return Err(DropboxError::InvalidMutationMetadata);
    }
    Ok(())
}

fn validate_created_folder(target: &str, metadata: ListEntry) -> Result<(), DropboxError> {
    validate_mutation_path(target, &metadata)?;
    if !matches!(metadata.tag, EntryTag::Folder) {
        return Err(DropboxError::InvalidMutationMetadata);
    }
    Ok(())
}

fn metadata_remote_state(
    target: &str,
    metadata: ListEntry,
) -> Result<RemotePathState, DropboxError> {
    validate_mutation_path(target, &metadata)?;
    match metadata.tag {
        EntryTag::Deleted => Ok(RemotePathState::Absent),
        EntryTag::Folder => Ok(RemotePathState::Folder),
        EntryTag::File if !metadata.is_downloadable || metadata.symlink_info.is_some() => {
            Ok(RemotePathState::Unsupported)
        }
        EntryTag::File => complete_remote_file(metadata)
            .map(RemotePathState::File)
            .ok_or(DropboxError::InvalidMutationMetadata),
    }
}

fn complete_remote_file(metadata: ListEntry) -> Option<RemoteFile> {
    if !matches!(metadata.tag, EntryTag::File)
        || !metadata.is_downloadable
        || metadata.symlink_info.is_some()
    {
        return None;
    }
    let content = metadata.content_hash?;
    let revision = metadata.rev?;
    if !valid_content_hash(&content) || revision.is_empty() {
        return None;
    }
    Some(RemoteFile::new(
        ContentIdentity::new(content),
        DropboxRevision::new(revision),
    ))
}

fn validate_mutation_path(target: &str, metadata: &ListEntry) -> Result<(), DropboxError> {
    if metadata.path_lower.as_deref() == Some(target.to_lowercase().as_str()) {
        Ok(())
    } else {
        Err(DropboxError::InvalidMutationMetadata)
    }
}

fn invalid_dropbox_component(component: &str) -> bool {
    component.is_empty() || component == "." || component == ".." || component.contains('\0')
}

fn default_true() -> bool {
    true
}

fn valid_content_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn apply_entries(
    root: &DropboxRoot,
    records: &mut BTreeMap<String, RemoteObservationRecord>,
    entries: Vec<ListEntry>,
) -> Result<(), DropboxError> {
    for entry in entries {
        let lower = entry
            .path_lower
            .as_deref()
            .ok_or(DropboxError::InvalidEntryPath)?;
        let display = entry
            .path_display
            .as_deref()
            .ok_or(DropboxError::InvalidEntryPath)?;
        let (key, path) = relative_paths(root, lower, display)?;
        if matches!(entry.tag, EntryTag::Deleted) {
            remove_subtree(records, &key);
            continue;
        }
        ensure_parent_folders(records, &key, &path);
        let observation = match entry.tag {
            EntryTag::Deleted => continue,
            EntryTag::Folder if entry.restricted() => {
                return Err(DropboxError::RestrictedRemoteInventory);
            }
            EntryTag::Folder => Observation::Unknown(UnknownReason::Unsupported),
            EntryTag::File => {
                remove_subtree(records, &key);
                if !entry.is_downloadable || entry.symlink_info.is_some() {
                    Observation::Unknown(UnknownReason::Unsupported)
                } else {
                    let content = entry
                        .content_hash
                        .ok_or(DropboxError::IncompleteFileMetadata)?;
                    let revision = entry.rev.ok_or(DropboxError::IncompleteFileMetadata)?;
                    if !valid_content_hash(&content) || revision.is_empty() {
                        return Err(DropboxError::IncompleteFileMetadata);
                    }
                    Observation::Present(RemoteFile::new(
                        ContentIdentity::new(content),
                        DropboxRevision::new(revision),
                    ))
                }
            }
        };
        records.insert(
            key.clone(),
            RemoteObservationRecord {
                canonical_path: PathBuf::from(key),
                path,
                observation,
            },
        );
    }
    Ok(())
}

fn ensure_parent_folders(
    records: &mut BTreeMap<String, RemoteObservationRecord>,
    key: &str,
    path: &Path,
) {
    let lower = key.split('/').collect::<Vec<_>>();
    let display = path.iter().collect::<Vec<_>>();
    for depth in 1..lower.len() {
        let parent_key = lower[..depth].join("/");
        records.insert(
            parent_key.clone(),
            RemoteObservationRecord {
                canonical_path: PathBuf::from(&parent_key),
                path: display[..depth].iter().copied().collect(),
                observation: Observation::Unknown(UnknownReason::Unsupported),
            },
        );
    }
}

fn remove_subtree(records: &mut BTreeMap<String, RemoteObservationRecord>, key: &str) {
    records.retain(|candidate, _| {
        candidate != key
            && !candidate
                .strip_prefix(key)
                .is_some_and(|remainder| remainder.starts_with('/'))
    });
}

fn relative_paths(
    root: &DropboxRoot,
    lower: &str,
    display: &str,
) -> Result<(String, PathBuf), DropboxError> {
    if display.to_lowercase() != lower {
        return Err(DropboxError::InvalidEntryPath);
    }
    let remainder = lower
        .strip_prefix(&root.lower_path)
        .ok_or(DropboxError::InvalidEntryPath)?;
    if remainder.is_empty() || !remainder.starts_with('/') {
        return Err(DropboxError::InvalidEntryPath);
    }
    let lower_components = remainder.split('/').skip(1).collect::<Vec<_>>();
    let display_components = display.split('/').skip(1 + root.depth).collect::<Vec<_>>();
    if lower_components.len() != display_components.len()
        || lower_components
            .iter()
            .any(|part| invalid_dropbox_component(part))
        || display_components
            .iter()
            .any(|part| invalid_dropbox_component(part))
    {
        return Err(DropboxError::InvalidEntryPath);
    }
    Ok((
        lower_components.join("/"),
        display_components.iter().collect(),
    ))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::error::Error;
    use std::io::{self, Cursor, Read};
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use proptest::prelude::*;

    use crate::journal::RemoteObservationRecord;
    use crate::model::{ContentIdentity, DropboxRevision, Observation, RemoteFile, UnknownReason};
    use crate::runtime_status::{
        TransferDirection, TransferEvent, TransferObserver, TransferProgress,
    };

    use super::{
        CONNECT_SECONDS, DIRECT_UPLOAD_MAX_BYTES, DOWNLOAD_SECONDS, DropboxError, DropboxRoot,
        EntryTag, ListEntry, PROGRESS_INTERVAL, ProgressReader, UPLOAD_SESSION_MAX_BYTES,
        apply_entries, ascii_json, exact_download_agent, validate_direct_upload_size,
        validate_upload_size,
    };

    #[test]
    fn exact_download_times_out_only_when_body_progress_stops() {
        let agent = exact_download_agent();
        let timeouts = agent.config().timeouts();

        assert_eq!(timeouts.global, None);
        assert_eq!(timeouts.connect, Some(Duration::from_secs(CONNECT_SECONDS)));
        assert_eq!(
            timeouts.recv_body,
            Some(Duration::from_secs(DOWNLOAD_SECONDS))
        );
        assert_eq!(agent.config().max_idle_connections(), 4);
        assert_eq!(agent.config().max_idle_connections_per_host(), 4);
    }

    struct ByteAtATime(Cursor<Vec<u8>>);

    impl Read for ByteAtATime {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            self.0.read(&mut buffer[..1])
        }
    }

    type RecordedTransfers = Arc<Mutex<Vec<TransferEvent>>>;

    const TEST_CONTENT_HASH: &str =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const TEST_REVISION: &str = "test-revision";

    #[derive(Clone, Copy, Debug)]
    enum TinyPath {
        A,
        AChild,
        Ab,
        AbChild,
    }

    impl TinyPath {
        fn key(self) -> &'static str {
            match self {
                Self::A => "a",
                Self::AChild => "a/x",
                Self::Ab => "ab",
                Self::AbChild => "ab/y",
            }
        }

        fn dropbox_path(self) -> &'static str {
            match self {
                Self::A => "/a",
                Self::AChild => "/a/x",
                Self::Ab => "/ab",
                Self::AbChild => "/ab/y",
            }
        }
    }

    #[derive(Clone, Copy, Debug)]
    enum TreeMutation {
        File(TinyPath),
        Folder(TinyPath),
        Delete(TinyPath),
    }

    impl TreeMutation {
        fn path(self) -> TinyPath {
            match self {
                Self::File(path) | Self::Folder(path) | Self::Delete(path) => path,
            }
        }

        fn entry(self) -> ListEntry {
            let (tag, rev, content_hash) = match self {
                Self::File(_) => (
                    EntryTag::File,
                    Some(String::from(TEST_REVISION)),
                    Some(String::from(TEST_CONTENT_HASH)),
                ),
                Self::Folder(_) => (EntryTag::Folder, None, None),
                Self::Delete(_) => (EntryTag::Deleted, None, None),
            };
            ListEntry {
                tag,
                path_lower: Some(String::from(self.path().dropbox_path())),
                path_display: Some(String::from(self.path().dropbox_path())),
                rev,
                content_hash,
                is_downloadable: true,
                symlink_info: None,
                sharing_info: None,
            }
        }
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum OracleNode {
        File,
        Folder,
    }

    fn tree_mutation_strategy() -> impl Strategy<Value = TreeMutation> {
        let path = prop_oneof![
            Just(TinyPath::A),
            Just(TinyPath::AChild),
            Just(TinyPath::Ab),
            Just(TinyPath::AbChild),
        ];
        (path, 0_u8..3).prop_map(|(path, kind)| match kind {
            0 => TreeMutation::File(path),
            1 => TreeMutation::Folder(path),
            _ => TreeMutation::Delete(path),
        })
    }

    fn tree_regression_prefix() -> Vec<TreeMutation> {
        vec![
            TreeMutation::Folder(TinyPath::A),
            TreeMutation::File(TinyPath::AChild),
            TreeMutation::File(TinyPath::AbChild),
            TreeMutation::Delete(TinyPath::A),
            TreeMutation::File(TinyPath::AChild),
            TreeMutation::File(TinyPath::A),
            TreeMutation::Delete(TinyPath::AbChild),
            TreeMutation::Delete(TinyPath::AChild),
        ]
    }

    fn apply_oracle(records: &mut BTreeMap<String, OracleNode>, mutation: TreeMutation) {
        let key = mutation.path().key();
        if matches!(mutation, TreeMutation::Delete(_)) {
            records.retain(|candidate, _| !Path::new(candidate).starts_with(key));
            return;
        }

        let components = key.split('/').collect::<Vec<_>>();
        for depth in 1..components.len() {
            records.insert(components[..depth].join("/"), OracleNode::Folder);
        }
        let node = match mutation {
            TreeMutation::File(_) => {
                records.retain(|candidate, _| !Path::new(candidate).starts_with(key));
                OracleNode::File
            }
            TreeMutation::Folder(_) => OracleNode::Folder,
            TreeMutation::Delete(_) => return,
        };
        records.insert(String::from(key), node);
    }

    fn oracle_records(
        nodes: &BTreeMap<String, OracleNode>,
    ) -> BTreeMap<String, RemoteObservationRecord> {
        nodes
            .iter()
            .map(|(key, node)| {
                let observation = match node {
                    OracleNode::File => Observation::Present(RemoteFile::new(
                        ContentIdentity::new(TEST_CONTENT_HASH),
                        DropboxRevision::new(TEST_REVISION),
                    )),
                    OracleNode::Folder => Observation::Unknown(UnknownReason::Unsupported),
                };
                (
                    key.clone(),
                    RemoteObservationRecord {
                        canonical_path: PathBuf::from(key),
                        path: PathBuf::from(key),
                        observation,
                    },
                )
            })
            .collect()
    }

    fn recording_observer() -> (TransferObserver, RecordedTransfers) {
        let recorded = Arc::new(Mutex::new(Vec::new()));
        let captured = Arc::clone(&recorded);
        let observer: TransferObserver = Arc::new(move |sample| {
            if let Ok(mut samples) = captured.lock() {
                samples.push(sample);
            }
        });
        (observer, recorded)
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(64))]

        #[test]
        fn entry_sequences_match_a_declarative_tree_model(
            generated in prop::collection::vec(tree_mutation_strategy(), 0..16),
            split_seed in 0_usize..32,
        ) {
            let mut mutations = tree_regression_prefix();
            mutations.extend(generated);
            let root = DropboxRoot::new("account", "namespace", "")
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            let mut actual = BTreeMap::new();
            let mut oracle = BTreeMap::new();

            for mutation in &mutations {
                apply_entries(&root, &mut actual, vec![mutation.entry()])
                    .map_err(|error| TestCaseError::fail(error.to_string()))?;
                apply_oracle(&mut oracle, *mutation);
                prop_assert_eq!(&actual, &oracle_records(&oracle));
            }

            let all_entries = mutations.iter().map(|mutation| mutation.entry()).collect();
            let mut single_page = BTreeMap::new();
            apply_entries(&root, &mut single_page, all_entries)
                .map_err(|error| TestCaseError::fail(error.to_string()))?;

            let split = split_seed % (mutations.len() + 1);
            let first_page = mutations[..split]
                .iter()
                .map(|mutation| mutation.entry())
                .collect();
            let second_page = mutations[split..]
                .iter()
                .map(|mutation| mutation.entry())
                .collect();
            let mut split_pages = BTreeMap::new();
            apply_entries(&root, &mut split_pages, first_page)
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            apply_entries(&root, &mut split_pages, second_page)
                .map_err(|error| TestCaseError::fail(error.to_string()))?;

            prop_assert_eq!(&single_page, &oracle_records(&oracle));
            prop_assert_eq!(single_page, split_pages);
        }
    }

    #[test]
    fn folders_and_non_downloadable_files_are_unknown() -> Result<(), Box<dyn Error>> {
        let root = DropboxRoot::new("account", "namespace", "")?;
        let mut records = BTreeMap::new();
        apply_entries(
            &root,
            &mut records,
            vec![
                ListEntry {
                    tag: EntryTag::Folder,
                    path_lower: Some(String::from("/folder")),
                    path_display: Some(String::from("/Folder")),
                    rev: None,
                    content_hash: None,
                    is_downloadable: true,
                    symlink_info: None,
                    sharing_info: None,
                },
                ListEntry {
                    tag: EntryTag::File,
                    path_lower: Some(String::from("/paper")),
                    path_display: Some(String::from("/Paper")),
                    rev: Some(String::from("1")),
                    content_hash: None,
                    is_downloadable: false,
                    symlink_info: None,
                    sharing_info: None,
                },
            ],
        )?;

        assert_eq!(records.len(), 2);
        assert!(records.values().all(|record| {
            record.observation == Observation::Unknown(UnknownReason::Unsupported)
        }));
        Ok(())
    }

    #[test]
    fn listing_rejects_mismatched_canonical_and_display_paths() -> Result<(), Box<dyn Error>> {
        let root = DropboxRoot::new("account", "namespace", "")?;
        let mut records = BTreeMap::new();
        let result = apply_entries(
            &root,
            &mut records,
            vec![ListEntry {
                tag: EntryTag::File,
                path_lower: Some(String::from("/report.txt")),
                path_display: Some(String::from("/Different.txt")),
                rev: Some(String::from("revision")),
                content_hash: Some(String::from(TEST_CONTENT_HASH)),
                is_downloadable: true,
                symlink_info: None,
                sharing_info: None,
            }],
        );

        assert!(matches!(result, Err(DropboxError::InvalidEntryPath)));
        assert!(records.is_empty());
        Ok(())
    }

    #[test]
    fn direct_upload_limit_is_checked_before_network_io() {
        assert!(validate_direct_upload_size(DIRECT_UPLOAD_MAX_BYTES).is_ok());
        assert!(matches!(
            validate_direct_upload_size(DIRECT_UPLOAD_MAX_BYTES + 1),
            Err(DropboxError::DirectUploadTooLarge { bytes })
                if bytes == DIRECT_UPLOAD_MAX_BYTES + 1
        ));
        assert!(validate_upload_size(UPLOAD_SESSION_MAX_BYTES).is_ok());
        assert!(matches!(
            validate_upload_size(UPLOAD_SESSION_MAX_BYTES + 1),
            Err(DropboxError::UploadTooLarge { bytes })
                if bytes == UPLOAD_SESSION_MAX_BYTES + 1
        ));
    }

    #[test]
    fn dropbox_header_json_is_ascii_safe() -> Result<(), Box<dyn Error>> {
        let value = serde_json::json!({"path": "/Café/雪.txt"});
        let encoded = ascii_json(&value)?;

        assert!(encoded.is_ascii());
        assert!(encoded.contains(r#"\u00e9"#));
        assert!(encoded.contains(r#"\u96ea"#));
        assert_eq!(serde_json::from_str::<serde_json::Value>(&encoded)?, value);
        Ok(())
    }

    #[test]
    fn progress_reader_throttles_fast_reads_but_reports_completion() -> Result<(), Box<dyn Error>> {
        let (observer, recorded) = recording_observer();
        let bytes = b"four";
        let mut reader = ProgressReader::new(
            ByteAtATime(Cursor::new(bytes.to_vec())),
            Some(&observer),
            TransferDirection::Upload,
            Path::new("folder/file.txt"),
            Some(u64::try_from(bytes.len())?),
        );
        let mut output = Vec::new();
        reader.read_to_end(&mut output)?;
        assert_eq!(output, bytes);
        drop(reader);

        let samples = recorded
            .lock()
            .map_err(|_| io::Error::other("recorded transfer lock was poisoned"))?;
        assert_eq!(
            samples.as_slice(),
            [
                TransferEvent::Progress(TransferProgress::new(
                    TransferDirection::Upload,
                    Path::new("folder/file.txt"),
                    0,
                    Some(4),
                )),
                TransferEvent::Progress(TransferProgress::new(
                    TransferDirection::Upload,
                    Path::new("folder/file.txt"),
                    4,
                    Some(4),
                )),
                TransferEvent::Finished(TransferProgress::new(
                    TransferDirection::Upload,
                    Path::new("folder/file.txt"),
                    4,
                    Some(4),
                )),
            ]
        );
        Ok(())
    }

    #[test]
    fn progress_reader_emits_due_sample_before_final_sample() -> Result<(), Box<dyn Error>> {
        let (observer, recorded) = recording_observer();
        let mut reader = ProgressReader::new(
            ByteAtATime(Cursor::new(b"abc".to_vec())),
            Some(&observer),
            TransferDirection::Download,
            Path::new("visible.txt"),
            Some(3),
        );
        reader.last_sample = Instant::now()
            .checked_sub(PROGRESS_INTERVAL)
            .ok_or_else(|| io::Error::other("test clock could not move backward"))?;
        let mut first = [0_u8; 1];
        reader.read_exact(&mut first)?;
        let mut remainder = Vec::new();
        reader.read_to_end(&mut remainder)?;

        let samples = recorded
            .lock()
            .map_err(|_| io::Error::other("recorded transfer lock was poisoned"))?;
        assert_eq!(samples.len(), 3);
        assert_eq!(
            samples.get(1),
            Some(&TransferEvent::Progress(TransferProgress::new(
                TransferDirection::Download,
                Path::new("visible.txt"),
                1,
                Some(3),
            )))
        );
        assert_eq!(
            samples.get(2),
            Some(&TransferEvent::Progress(TransferProgress::new(
                TransferDirection::Download,
                Path::new("visible.txt"),
                3,
                Some(3),
            )))
        );
        Ok(())
    }
}
