//! Documented blocking Dropbox operations.

use std::collections::BTreeMap;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::auth::AccessToken;
use crate::journal::{
    DropboxBinding, DropboxBindingWrite, Journal, JournalError, RemoteObservationRecord,
};
use crate::local::{LocalError, StageOutcome, StagedUpload, stage_download};
use crate::model::{ContentIdentity, DropboxRevision, Observation, RemoteFile, UnknownReason};

const LONG_POLL_MINIMUM_SECONDS: u64 = 30;
const LONG_POLL_MAXIMUM_SECONDS: u64 = 480;
const JSON_REQUEST_SECONDS: u64 = 60;
const CONNECT_SECONDS: u64 = 15;
const DOWNLOAD_SECONDS: u64 = 60 * 60;
const LONG_POLL_GRACE_SECONDS: u64 = 105;
const DIRECT_UPLOAD_MAX_BYTES: u64 = 150 * 1024 * 1024;

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
        }
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
        let config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(DOWNLOAD_SECONDS)))
            .timeout_connect(Some(Duration::from_secs(CONNECT_SECONDS)))
            .build();
        let response = ureq::Agent::new_with_config(config)
            .post(&url)
            .header("Authorization", &authorization)
            .header("Dropbox-API-Path-Root", &path_root)
            .header("Dropbox-API-Arg", &argument)
            .send_empty()
            .map_err(|source| DropboxError::Transport {
                operation: "download exact Dropbox revision",
                source,
            })?;
        require_success(
            response.status().as_u16(),
            response.headers().get("Retry-After"),
            "download exact Dropbox revision",
        )?;
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
        let (_, body) = response.into_parts();
        stage_download(sync_root, target, &remote.content, body.into_reader())
            .map_err(|source| DropboxError::LocalStage { source })
    }

    /// Strictly create one Dropbox file from verified immutable staging.
    pub fn create_file(
        &self,
        relative: impl AsRef<Path>,
        staged: &StagedUpload,
    ) -> Result<MutationOutcome, DropboxError> {
        let target = self.mutation_target(relative.as_ref())?;
        let expectation = MutationExpectation::CreateFile {
            desired: staged.content().clone(),
        };
        self.upload_file(
            &target,
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
        let target = self.mutation_target(relative.as_ref())?;
        let expectation = MutationExpectation::ReplaceFile {
            expected: expected.clone(),
            desired: staged.content().clone(),
        };
        self.upload_file(
            &target,
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
        let response = ureq::Agent::new_with_config(config)
            .post(&url)
            .header("Authorization", authorization)
            .header("Dropbox-API-Path-Root", path_root)
            .header("Dropbox-API-Arg", argument)
            .header("Content-Type", "application/octet-stream")
            .send(bytes);
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
        records.insert(key, RemoteObservationRecord { path, observation });
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
            parent_key,
            RemoteObservationRecord {
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

    use crate::model::{Observation, UnknownReason};

    use super::{
        DIRECT_UPLOAD_MAX_BYTES, DropboxError, DropboxRoot, EntryTag, ListEntry, apply_entries,
        ascii_json, validate_direct_upload_size,
    };

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
    fn direct_upload_limit_is_checked_before_network_io() {
        assert!(validate_direct_upload_size(DIRECT_UPLOAD_MAX_BYTES).is_ok());
        assert!(matches!(
            validate_direct_upload_size(DIRECT_UPLOAD_MAX_BYTES + 1),
            Err(DropboxError::DirectUploadTooLarge { bytes })
                if bytes == DIRECT_UPLOAD_MAX_BYTES + 1
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
}
