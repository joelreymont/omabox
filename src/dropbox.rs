//! Documented blocking Dropbox operations.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::transport::{Bases, Outcome as TransportOutcome, TokenState, Transport, TransportError};
use dropbox_sdk::client_trait::{HttpClient, HttpRequestResult};
use dropbox_sdk::sync_routes::{files, users};
use dropbox_sdk::types::{
    auth::AuthError as SdkAuthError,
    common::{PathRoot, RootInfo},
};
use dropbox_sdk::{Error as SdkError, NoError};
use rustix::fd::OwnedFd;
use thiserror::Error;

use crate::auth::{AccessToken, RefreshTokenStore, StoredCredential};
use crate::journal::{
    DropboxBinding, DropboxBindingWrite, Journal, JournalError, RemoteInventoryChange,
    RemoteObservationRecord,
};
use crate::local::{
    DownloadPreparation, DownloadSlotLease, LocalError, StageIoError, StageOutcome, StagedUpload,
    SyncRootAccess, existing_download_stage_at, open_root,
    prepare_disposable_download_with_access_at, prepare_download_slot_with_access_at,
    stage_download_at,
};
use crate::model::{
    CanonicalPath, ContentIdentity, DropboxRevision, Observation, RemoteFile, UnknownReason,
};
use crate::runtime_status::{TransferDirection, TransferEvent, TransferObserver, TransferProgress};

const LONG_POLL_MINIMUM_SECONDS: u64 = 30;
const LONG_POLL_MAXIMUM_SECONDS: u64 = 480;
const UPLOAD_SESSION_CHUNK_BYTES: u64 = 32 * 1024 * 1024;
const UPLOAD_SESSION_MAX_BYTES: u64 = 350_000_000_000;
const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

pub(crate) struct DownloadAccess<'a> {
    pub(crate) lease: Option<&'a DownloadSlotLease>,
    pub(crate) staging_directory: Option<&'a Path>,
    pub(crate) root_access: &'a Arc<SyncRootAccess>,
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

    fn complete(&mut self, done: u64) {
        self.done = done;
        self.emit();
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

    pub(crate) fn bases(&self) -> Bases {
        Bases::new(
            format!("{}/", self.api.trim_end_matches('/')),
            format!("{}/", self.content.trim_end_matches('/')),
            format!("{}/", self.notify.trim_end_matches('/')),
            self.token
                .strip_suffix("oauth2/token")
                .map_or(self.token.as_str(), |base| base),
        )
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
    /// Dropbox permanently rejected this path or payload without applying it.
    Rejected(MutationRejection),
}

/// A permanent per-path rejection that does not invalidate unrelated sync work.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum MutationRejection {
    /// The local path cannot be represented by Dropbox's UTF-8 path API.
    #[error("the local path is not a valid Dropbox UTF-8 path")]
    InvalidPath,
    /// The file exceeds the supported upload limit.
    #[error("the file exceeds Dropbox’s supported upload size")]
    UnsupportedFileSize,
    /// Dropbox does not permit this file or folder name.
    #[error("Dropbox does not permit this file or folder name")]
    DisallowedName,
    /// Dropbox cannot transfer this content because it is restricted.
    #[error("Dropbox does not permit this content to be transferred")]
    RestrictedContent,
    /// The account cannot write at this Dropbox path.
    #[error("the Dropbox account cannot write at this path")]
    PermissionDenied,
    /// The Dropbox account has no space for this mutation.
    #[error("the Dropbox account has insufficient space")]
    InsufficientSpace,
    /// Dropbox does not allow this operation at the selected path.
    #[error("Dropbox does not allow this operation at this path")]
    OperationNotAllowed,
    /// Dropbox rejected the path for a reason this client cannot classify more narrowly.
    #[error("Dropbox rejected this path")]
    RejectedByDropbox,
}

/// Direct blocking client for Dropbox endpoints.
pub struct DropboxClient {
    root: DropboxRoot,
    transport: Transport,
    transfer_observer: Option<TransferObserver>,
    account_validated: AtomicBool,
}

impl DropboxClient {
    /// Construct a client using Dropbox's production endpoints.
    pub fn new(access_token: AccessToken, root: DropboxRoot) -> Result<Self, DropboxError> {
        Self::with_endpoints(access_token, root, DropboxEndpoints::production())
    }

    /// Construct a client with explicit protocol-test endpoints.
    pub fn with_endpoints(
        access_token: AccessToken,
        root: DropboxRoot,
        endpoints: DropboxEndpoints,
    ) -> Result<Self, DropboxError> {
        let transport = Transport::with_access_token(
            endpoints.bases(),
            &PathRoot::Root(root.namespace_id.clone()),
            &access_token,
        )
        .map_err(DropboxError::transport)?;
        Ok(Self {
            root,
            transport,
            transfer_observer: None,
            account_validated: AtomicBool::new(false),
        })
    }

    /// Retain refresh and connection ownership for the lifetime of the daemon session.
    pub fn from_credentials(
        app_key: &str,
        credential: StoredCredential,
        root: DropboxRoot,
    ) -> Result<Self, DropboxError> {
        Self::from_credentials_with_endpoints(
            app_key,
            credential,
            root,
            DropboxEndpoints::production(),
        )
    }

    /// Construct retained credentials against a protocol-test server.
    pub fn from_credentials_with_endpoints(
        app_key: &str,
        credential: StoredCredential,
        root: DropboxRoot,
        endpoints: DropboxEndpoints,
    ) -> Result<Self, DropboxError> {
        if credential.binding != root.binding() {
            return Err(DropboxError::AccountBindingChanged);
        }
        let tokens = Arc::new(
            TokenState::new(
                app_key.to_owned(),
                &credential.refresh_token,
                credential.binding,
                Arc::new(RefreshTokenStore::new()),
            )
            .map_err(DropboxError::transport)?,
        );
        let transport = Transport::new(
            endpoints.bases(),
            &PathRoot::Root(root.namespace_id.clone()),
            tokens,
        )
        .map_err(DropboxError::transport)?;
        Ok(Self {
            root,
            transport,
            transfer_observer: None,
            account_validated: AtomicBool::new(false),
        })
    }

    fn call<T, E: std::error::Error + Send + Sync + 'static>(
        &self,
        mut request: impl FnMut() -> Result<T, SdkError<E>>,
    ) -> Result<T, SdkError<E>> {
        self.transport
            .retry_persistence()
            .map_err(|e| SdkError::HttpClient(Box::new(e)))?;
        let token = self.transport.token();
        let result = request();
        if matches!(
            &result,
            Err(SdkError::Authentication(SdkAuthError::InvalidAccessToken))
        ) {
            if self.transport.tokens().refreshed() {
                self.transport
                    .tokens()
                    .reject(crate::transport::RejectCause::InvalidAccessToken);
                return result;
            }
            let rejected = match token {
                Some(token) => token,
                None => Arc::new(String::new()),
            };
            if self
                .transport
                .refresh_access(rejected)
                .map_err(|e| SdkError::HttpClient(Box::new(e)))?
            {
                let retried = request();
                if matches!(
                    &retried,
                    Err(SdkError::Authentication(SdkAuthError::InvalidAccessToken))
                ) {
                    self.transport
                        .tokens()
                        .reject(crate::transport::RejectCause::InvalidAccessToken);
                }
                return retried;
            }
        }
        result
    }

    /// Bind a new authorization using the generated account lookup.
    pub fn link_authorized(
        access_token: AccessToken,
        remote_root: impl Into<String>,
    ) -> Result<DropboxLink, DropboxError> {
        Self::link_inner(
            access_token,
            None,
            remote_root.into(),
            DropboxEndpoints::production(),
        )
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
        Self::link_inner(
            access_token,
            Some(authorized_account_id.into()),
            remote_root.into(),
            endpoints,
        )
    }

    fn link_inner(
        access_token: AccessToken,
        expected_account: Option<String>,
        remote_root: String,
        endpoints: DropboxEndpoints,
    ) -> Result<DropboxLink, DropboxError> {
        // Home is an explicit preactivation mode; no empty namespace is activated.
        let transport =
            Transport::with_access_token(endpoints.bases(), &PathRoot::Home, &access_token)
                .map_err(DropboxError::transport)?;
        let account = users::get_current_account(&transport.account())
            .map_err(|e| DropboxError::sdk("inspect authorized Dropbox account", e))?;
        if expected_account
            .as_ref()
            .is_some_and(|id| id != &account.account_id)
        {
            return Ok(DropboxLink::AccountChanged);
        }
        let namespace = namespace_id(&account.root_info)?;
        let root = DropboxRoot::new(account.account_id, namespace, remote_root)?;
        let client = Self::with_endpoints(access_token, root, endpoints)?;
        client.validate_remote_root()?;
        client.account_validated.store(true, Ordering::Relaxed);
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
        if !self.account_validated.load(Ordering::Relaxed) {
            let response = self.current_account()?;
            if response.account_id != self.root.account_id {
                return Ok(AccountValidation::AccountChanged);
            }
            if namespace_id(&response.root_info)? != self.root.namespace_id {
                return Ok(AccountValidation::RootChanged);
            }
            self.validate_remote_root()?;
        }
        match journal
            .bind_dropbox_root(&self.root.binding())
            .map_err(|source| DropboxError::Journal { source })?
        {
            DropboxBindingWrite::Bound | DropboxBindingWrite::AlreadyBound => {
                self.account_validated.store(true, Ordering::Relaxed);
                Ok(AccountValidation::Valid)
            }
            DropboxBindingWrite::Mismatch { .. } => Ok(AccountValidation::JournalBindingChanged),
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
        let current_cursor = journal
            .remote_cursor()
            .map_err(|source| DropboxError::Journal { source })?;
        if let Some(cursor) = current_cursor {
            let directories = journal
                .remote_directory_paths()
                .map_err(|source| DropboxError::Journal { source })?;
            match self.cursor_delta(&cursor, &directories)? {
                CursorDelta::Changes { changes, cursor } => {
                    journal
                        .apply_remote_inventory_delta(&cursor, &changes)
                        .map_err(|source| DropboxError::Journal { source })?;
                    Ok(InventoryRefresh::Published)
                }
                CursorDelta::Reset => {
                    let (records, cursor) = self.full_inventory()?;
                    journal
                        .publish_remote_inventory(&cursor, &records)
                        .map_err(|source| DropboxError::Journal { source })?;
                    Ok(InventoryRefresh::RebuiltAfterCursorReset)
                }
            }
        } else {
            let (records, cursor) = self.full_inventory()?;
            journal
                .publish_remote_inventory(&cursor, &records)
                .map_err(|source| DropboxError::Journal { source })?;
            Ok(InventoryRefresh::Published)
        }
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
        let argument = files::ListFolderLongpollArg::new(cursor.to_owned()).with_timeout(seconds);
        let payload = match files::list_folder_longpoll(&self.transport.noauth(), &argument) {
            Ok(payload) => payload,
            Err(SdkError::Api(files::ListFolderLongpollError::Reset)) => {
                return Ok(LongPollWakeup::CursorReset);
            }
            Err(error) => return Err(DropboxError::sdk("wait for Dropbox changes", error)),
        };
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
        let root_access = Arc::new(SyncRootAccess::default());
        self.stage_exact_download_for_access_at(
            root,
            root_path,
            target,
            synchronized_path,
            remote,
            DownloadAccess {
                lease,
                staging_directory: None,
                root_access: &root_access,
            },
        )
    }

    pub(crate) fn stage_worker_download_at(
        &self,
        root: &OwnedFd,
        root_path: &Path,
        path: &Path,
        remote: &RemoteFile,
        access: DownloadAccess<'_>,
    ) -> Result<StageOutcome<()>, DropboxError> {
        self.stage_exact_download_for_access_at(root, root_path, path, path, remote, access)
    }

    fn stage_exact_download_for_access_at(
        &self,
        root: &OwnedFd,
        root_path: &Path,
        target: &Path,
        synchronized_path: &Path,
        remote: &RemoteFile,
        access: DownloadAccess<'_>,
    ) -> Result<StageOutcome<()>, DropboxError> {
        let mut partial = if let Some(lease) = access.lease {
            match prepare_download_slot_with_access_at(
                root,
                root_path,
                target,
                &remote.content,
                lease,
                access.root_access,
            )
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
            && let Some(staging_directory) = access.staging_directory
        {
            match prepare_disposable_download_with_access_at(
                root,
                root_path,
                target,
                &remote.content,
                staging_directory,
                access.root_access,
            )
            .map_err(|source| DropboxError::LocalStage { source })?
            {
                DownloadPreparation::Ready(disposable) => partial = Some(disposable),
                DownloadPreparation::Complete(outcome) => return Ok(outcome),
                DownloadPreparation::Ephemeral => {}
            }
        }
        if partial.is_none()
            && let Some(outcome) =
                existing_download_stage_at(root, root_path, target, &remote.content)
                    .map_err(|source| DropboxError::LocalStage { source })?
        {
            return Ok(outcome);
        }
        let mut offset = partial.as_ref().map_or(0, |partial| partial.offset());
        let path = format!("rev:{}", remote.revision.as_str());
        #[allow(deprecated)] // Explicit revision pin is part of the download contract.
        let argument = files::DownloadArg::new(path).with_rev(remote.revision.as_str().to_owned());
        let response = match self.call(|| {
            files::download(
                &self.transport,
                &argument,
                (offset != 0).then_some(offset),
                None,
            )
        }) {
            Ok(response) => response,
            Err(error)
                if offset != 0
                    && matches!(
                        error.downcast_ref_inner::<TransportError>(),
                        Some(TransportError::RangeUnsatisfiable { .. })
                    ) =>
            {
                let length = match error.downcast_ref_inner::<TransportError>() {
                    Some(TransportError::RangeUnsatisfiable { length }) => *length,
                    _ => None,
                };
                if let Some(retained) = partial.take() {
                    if length == Some(offset) {
                        // Completion remains gated by the full expected Dropbox hash.
                        return retained
                            .append(offset, &mut io::empty())
                            .map_err(download_stage_error);
                    }
                    match retained
                        .restart()
                        .map_err(|source| DropboxError::LocalStage { source })?
                    {
                        DownloadPreparation::Ready(restarted) => partial = Some(restarted),
                        DownloadPreparation::Complete(outcome) => return Ok(outcome),
                        DownloadPreparation::Ephemeral => {}
                    }
                }
                offset = 0;
                self.call(|| files::download(&self.transport, &argument, None, None))
                    .map_err(|e| DropboxError::sdk("restart exact Dropbox download", e))?
            }
            Err(error) => return Err(DropboxError::sdk("download exact Dropbox revision", error)),
        };
        let HttpRequestResult {
            result: metadata,
            content_length,
            body,
        } = response;
        if metadata.rev != remote.revision.as_str() {
            return Err(DropboxError::DownloadedRevisionChanged);
        }
        if metadata.content_hash.as_deref() != Some(remote.content.as_str()) {
            return Err(DropboxError::DownloadedIdentityChanged);
        }
        if offset > metadata.size {
            return Err(DropboxError::DownloadedSizeChanged);
        }
        let remaining = metadata
            .size
            .checked_sub(offset)
            .ok_or(DropboxError::DownloadedSizeChanged)?;
        if content_length.is_some_and(|length| length != remaining) {
            return Err(DropboxError::DownloadedLengthChanged);
        }
        let body = body.ok_or(DropboxError::MissingDownloadMetadata)?;
        let mut reader = ProgressReader::new_at(
            body,
            self.transfer_observer.as_ref(),
            TransferDirection::Download,
            synchronized_path,
            offset,
            Some(metadata.size),
        );
        if let Some(partial) = partial {
            partial
                .append(metadata.size, &mut reader)
                .map_err(download_stage_error)
        } else {
            let staged = access
                .root_access
                .with_shared(|| {
                    stage_download_at(root, root_path, target, &remote.content, &mut reader)
                })
                .map_err(download_stage_error)?;
            if matches!(
                &staged,
                StageOutcome::AlreadyStaged(()) | StageOutcome::DestinationOccupied { .. }
            ) {
                return Ok(staged);
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
        let target = match self.mutation_target(relative) {
            Ok(target) => target,
            Err(rejection) => return Ok(MutationOutcome::Rejected(rejection)),
        };
        let expectation = MutationExpectation::CreateFile {
            desired: staged.content().clone(),
        };
        self.upload_file(
            &target,
            relative,
            files::WriteMode::Add,
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
        let target = match self.mutation_target(relative) {
            Ok(target) => target,
            Err(rejection) => return Ok(MutationOutcome::Rejected(rejection)),
        };
        let expectation = MutationExpectation::ReplaceFile {
            expected: expected.clone(),
            desired: staged.content().clone(),
        };
        self.upload_file(
            &target,
            relative,
            files::WriteMode::Update(expected.as_str().to_owned()),
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
        let target = match self.mutation_target(relative.as_ref()) {
            Ok(target) => target,
            Err(rejection) => return Ok(MutationOutcome::Rejected(rejection)),
        };
        let expectation = MutationExpectation::DeleteFile {
            expected: expected.clone(),
        };
        let argument =
            files::DeleteArg::new(target.clone()).with_parent_rev(expected.as_str().to_owned());
        let operation = "conditionally delete Dropbox file";
        match self.call(|| files::delete_v2(&self.transport, &argument)) {
            Ok(payload) => match validate_deleted_file(&target, payload.metadata, expected) {
                Ok(()) => Ok(MutationOutcome::Applied(RemotePathState::Absent)),
                Err(failure) => self.resolve_ambiguous(&target, &expectation, failure),
            },
            Err(error) => self.resolve_mutation_error(
                &target,
                &expectation,
                DropboxError::sdk(operation, error),
            ),
        }
    }

    /// Strictly create one Dropbox folder for a future directory intent.
    pub fn create_folder(
        &self,
        relative: impl AsRef<Path>,
    ) -> Result<MutationOutcome, DropboxError> {
        let target = match self.mutation_target(relative.as_ref()) {
            Ok(target) => target,
            Err(rejection) => return Ok(MutationOutcome::Rejected(rejection)),
        };
        let expectation = MutationExpectation::CreateFolder;
        let argument = files::CreateFolderArg::new(target.clone()).with_autorename(false);
        let operation = "strictly create Dropbox folder";
        match self.call(|| files::create_folder_v2(&self.transport, &argument)) {
            Ok(payload) => {
                match validate_mutation_path(&target, payload.metadata.path_lower.as_deref()) {
                    Ok(()) => Ok(MutationOutcome::Applied(RemotePathState::Folder)),
                    Err(failure) => self.resolve_ambiguous(&target, &expectation, failure),
                }
            }
            Err(error) => self.resolve_mutation_error(
                &target,
                &expectation,
                DropboxError::sdk(operation, error),
            ),
        }
    }

    fn upload_file(
        &self,
        target: &str,
        synchronized_path: &Path,
        mode: files::WriteMode,
        staged: &StagedUpload,
        expectation: MutationExpectation,
        operation: &'static str,
    ) -> Result<MutationOutcome, DropboxError> {
        let mut bytes = staged
            .open_verified()
            .map_err(|source| DropboxError::LocalStage { source })?;
        let size = bytes
            .metadata()
            .map_err(|source| DropboxError::UploadStageMetadata { source })?
            .len();
        if validate_upload_size(size).is_err() {
            return Ok(MutationOutcome::Rejected(
                MutationRejection::UnsupportedFileSize,
            ));
        }
        let capacity = usize::try_from(size.min(UPLOAD_SESSION_CHUNK_BYTES))
            .map_err(|_| DropboxError::UploadSessionOffsetOverflow)?;
        let mut buffer = vec![0; capacity];
        let mut progress = ProgressReader::new(
            io::empty(),
            self.transfer_observer.as_ref(),
            TransferDirection::Upload,
            synchronized_path,
            Some(size),
        );
        let result = if size <= UPLOAD_SESSION_CHUNK_BYTES {
            bytes
                .read_exact(&mut buffer)
                .map_err(|source| DropboxError::UploadStageRead { source })?;
            let argument = files::UploadArg::new(target.to_owned())
                .with_mode(mode)
                .with_autorename(false)
                .with_strict_conflict(true)
                .with_content_hash(staged.content().as_str().to_owned());
            self.call(|| files::upload(&self.transport, &argument, &buffer))
                .map_err(|e| DropboxError::sdk(operation, e))
        } else {
            let session = self
                .call(|| {
                    files::upload_session_start(
                        &self.transport,
                        &files::UploadSessionStartArg::default(),
                        &[],
                    )
                })
                .map_err(|e| DropboxError::sdk("start Dropbox upload session", e))?;
            let mut offset = 0;
            while offset < size {
                let length = usize::try_from((size - offset).min(UPLOAD_SESSION_CHUNK_BYTES))
                    .map_err(|_| DropboxError::UploadSessionOffsetOverflow)?;
                bytes
                    .read_exact(&mut buffer[..length])
                    .map_err(|source| DropboxError::UploadStageRead { source })?;
                self.append_upload_session_chunk(&session.session_id, &buffer[..length], offset)?;
                offset += length as u64;
                progress.complete(offset);
            }
            let commit = files::CommitInfo::new(target.to_owned())
                .with_mode(mode)
                .with_autorename(false)
                .with_strict_conflict(true);
            let argument = files::UploadSessionFinishArg::new(
                files::UploadSessionCursor::new(session.session_id, size),
                commit,
            )
            .with_content_hash(staged.content().as_str().to_owned());
            self.call(|| files::upload_session_finish(&self.transport, &argument, &[]))
                .map_err(|e| DropboxError::sdk(operation, e))
        };
        match result {
            Ok(metadata) => {
                progress.complete(size);
                match validate_uploaded_file(target, metadata, staged.content()) {
                    Ok(remote) => Ok(MutationOutcome::Applied(RemotePathState::File(remote))),
                    Err(error) => self.resolve_ambiguous(target, &expectation, error),
                }
            }
            Err(error) => self.resolve_mutation_error(target, &expectation, error),
        }
    }

    fn append_upload_session_chunk(
        &self,
        session_id: &str,
        buffer: &[u8],
        offset: u64,
    ) -> Result<(), DropboxError> {
        let next = offset
            .checked_add(buffer.len() as u64)
            .ok_or(DropboxError::UploadSessionOffsetOverflow)?;
        let mut requested = offset;
        let mut transport_failure = None;
        let mut correction_available = true;
        loop {
            let start = usize::try_from(requested - offset)
                .map_err(|_| DropboxError::UploadSessionOffsetOverflow)?;
            let argument = files::UploadSessionAppendArg::new(files::UploadSessionCursor::new(
                session_id.to_owned(),
                requested,
            ));
            let result = self.call(|| {
                files::upload_session_append_v2(&self.transport, &argument, &buffer[start..])
            });
            match result {
                Ok(()) => return Ok(()),
                Err(SdkError::Api(files::UploadSessionAppendError::IncorrectOffset(error))) => {
                    if error.correct_offset == next {
                        return Ok(());
                    }
                    if correction_available
                        && error.correct_offset != requested
                        && (offset..next).contains(&error.correct_offset)
                    {
                        requested = error.correct_offset;
                        correction_available = false;
                        continue;
                    }
                    return Err(DropboxError::IncorrectUploadSessionOffset {
                        requested_offset: requested,
                        chunk_bytes: next - requested,
                        correct_offset: error.correct_offset,
                    });
                }
                Err(error) => {
                    let error = DropboxError::sdk("append Dropbox upload session", error);
                    if error.is_transport_retry() && transport_failure.is_none() {
                        transport_failure = Some(error);
                        continue;
                    }
                    return match transport_failure {
                        Some(original) => Err(DropboxError::RetriedTransport {
                            original: Box::new(original),
                            retry: Box::new(error),
                        }),
                        None => Err(error),
                    };
                }
            }
        }
    }

    fn resolve_mutation_error(
        &self,
        target: &str,
        expectation: &MutationExpectation,
        error: DropboxError,
    ) -> Result<MutationOutcome, DropboxError> {
        match error.api_outcome() {
            ApiOutcome::Rejected(reason) => Ok(MutationOutcome::Rejected(reason)),
            ApiOutcome::Unknown | ApiOutcome::Unavailable | ApiOutcome::Environmental => Ok(
                MutationOutcome::Rejected(MutationRejection::RejectedByDropbox),
            ),
            ApiOutcome::Conflict => self.resolve_explicit_conflict(target, expectation),
            ApiOutcome::Absent => Ok(MutationOutcome::Applied(RemotePathState::Absent)),
            _ if error.mutation_may_have_applied() => {
                if let Some(TransportOutcome::Retry { delay: Some(delay) }) =
                    error.transport_outcome()
                {
                    std::thread::sleep(delay);
                }
                self.resolve_ambiguous(target, expectation, error)
            }
            _ => Err(error),
        }
    }

    fn resolve_explicit_conflict(
        &self,
        target: &str,
        expectation: &MutationExpectation,
    ) -> Result<MutationOutcome, DropboxError> {
        match self.metadata_state(target) {
            Ok(state) => Ok(expectation.classify(state)),
            Err(error) if matches!(error.api_outcome(), ApiOutcome::Unavailable) => Ok(
                MutationOutcome::Rejected(MutationRejection::RejectedByDropbox),
            ),
            Err(error) => Err(error),
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
            Err(source) => Err(DropboxError::UnverifiedMutation {
                original: Box::new(original),
                verification: Box::new(source),
            }),
        }
    }

    fn metadata_state(&self, target: &str) -> Result<RemotePathState, DropboxError> {
        let argument = files::GetMetadataArg::new(target.to_owned()).with_include_deleted(true);
        match self.call(|| files::get_metadata(&self.transport, &argument)) {
            Ok(metadata) => metadata_remote_state(target, metadata),
            Err(SdkError::Api(files::GetMetadataError::Path(files::LookupError::NotFound))) => {
                Ok(RemotePathState::Absent)
            }
            Err(error) => Err(DropboxError::sdk("verify Dropbox mutation", error)),
        }
    }

    fn mutation_target(&self, relative: &Path) -> Result<String, MutationRejection> {
        let mut suffix = String::new();
        for component in relative.components() {
            let Component::Normal(component) = component else {
                return Err(MutationRejection::InvalidPath);
            };
            let component = component.to_str().ok_or(MutationRejection::InvalidPath)?;
            if invalid_dropbox_component(component) {
                return Err(MutationRejection::InvalidPath);
            }
            suffix.push('/');
            suffix.push_str(component);
        }
        if suffix.is_empty() {
            return Err(MutationRejection::InvalidPath);
        }
        Ok(format!("{}{}", self.root.path, suffix))
    }

    fn current_account(&self) -> Result<dropbox_sdk::types::users::FullAccount, DropboxError> {
        self.call(|| users::get_current_account(&self.transport.account()))
            .map_err(|e| DropboxError::sdk("validate Dropbox account", e))
    }

    fn validate_remote_root(&self) -> Result<(), DropboxError> {
        if self.root.path.is_empty() {
            return Ok(());
        }
        let argument = files::GetMetadataArg::new(self.root.path.clone());
        let metadata = self
            .call(|| files::get_metadata(&self.transport, &argument))
            .map_err(|e| DropboxError::sdk("validate configured Dropbox root", e))?;
        if metadata_paths(&metadata).0 != Some(self.root.lower_path.as_str()) {
            return Err(DropboxError::RemoteRootUnavailable);
        }
        let files::Metadata::Folder(folder) = metadata else {
            return Err(DropboxError::RemoteRootNotFolder);
        };
        if folder_restricted(&folder) {
            return Err(DropboxError::RemoteRootRestricted);
        }
        Ok(())
    }

    fn full_inventory(&self) -> Result<(Vec<RemoteObservationRecord>, String), DropboxError> {
        let argument = files::ListFolderArg::new(self.root.path.clone())
            .with_recursive(true)
            .with_include_deleted(false);
        let first = self
            .call(|| files::list_folder(&self.transport, &argument))
            .map_err(|e| DropboxError::sdk("start complete Dropbox listing", e))?;
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

    fn cursor_delta(
        &self,
        initial_cursor: &str,
        directories: &[(CanonicalPath, PathBuf)],
    ) -> Result<CursorDelta, DropboxError> {
        let mut changes = Vec::new();
        let mut previous = initial_cursor.to_owned();
        loop {
            let page = match self.list_continue(&previous)? {
                ContinuePage::Reset => return Ok(CursorDelta::Reset),
                ContinuePage::Page(page) => page,
            };
            append_entry_changes(&self.root, &mut changes, page.entries)?;
            if !page.has_more {
                normalize_inventory_changes(&mut changes, directories)?;
                return Ok(CursorDelta::Changes {
                    changes,
                    cursor: page.cursor,
                });
            }
            if page.cursor == previous {
                return Err(DropboxError::CursorDidNotAdvance);
            }
            previous = page.cursor;
        }
    }

    fn list_continue(&self, cursor: &str) -> Result<ContinuePage, DropboxError> {
        let argument = files::ListFolderContinueArg::new(cursor.to_owned());
        match self.call(|| files::list_folder_continue(&self.transport, &argument)) {
            Ok(page) => Ok(ContinuePage::Page(page)),
            Err(SdkError::Api(files::ListFolderContinueError::Reset)) => Ok(ContinuePage::Reset),
            Err(error) => Err(DropboxError::sdk(
                "continue complete Dropbox listing",
                error,
            )),
        }
    }
}

fn download_stage_error(error: StageIoError) -> DropboxError {
    match error {
        StageIoError::Read { source, .. } => DropboxError::DownloadBody { source },
        StageIoError::Local { source } => DropboxError::LocalStage { source },
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

enum CursorDelta {
    Changes {
        changes: Vec<RemoteInventoryChange>,
        cursor: String,
    },
    Reset,
}

enum ContinuePage {
    Page(files::ListFolderResult),
    Reset,
}

fn metadata_paths(metadata: &files::Metadata) -> (Option<&str>, Option<&str>) {
    let (lower, display) = match metadata {
        files::Metadata::File(file) => (&file.path_lower, &file.path_display),
        files::Metadata::Folder(folder) => (&folder.path_lower, &folder.path_display),
        files::Metadata::Deleted(deleted) => (&deleted.path_lower, &deleted.path_display),
    };
    (lower.as_deref(), display.as_deref())
}

fn folder_restricted(folder: &files::FolderMetadata) -> bool {
    folder
        .sharing_info
        .as_ref()
        .is_some_and(|sharing| sharing.no_access || sharing.traverse_only)
}

fn namespace_id(root: &RootInfo) -> Result<String, DropboxError> {
    match root {
        RootInfo::User(root) => Ok(root.root_namespace_id.clone()),
        RootInfo::Team(root) => Ok(root.root_namespace_id.clone()),
        _ => Err(DropboxError::AccountBindingChanged),
    }
}

/// Dropbox protocol, validation, or publication failure.
#[derive(Debug, Error)]
pub enum DropboxError {
    /// Generated route failure, with its typed policy and original source.
    #[error("Dropbox operation `{operation}` failed")]
    Sdk {
        operation: &'static str,
        outcome: ApiOutcome,
        #[source]
        source: Box<SdkError<RouteError>>,
    },
    /// Both a mutation response and its verification failed.
    #[error("could not verify the outcome of a Dropbox mutation: {original}")]
    UnverifiedMutation {
        #[source]
        original: Box<DropboxError>,
        verification: Box<DropboxError>,
    },
    /// A bounded append retry failed as well as the initial attempt.
    #[error("Dropbox append retry failed after {original}")]
    RetriedTransport {
        #[source]
        original: Box<DropboxError>,
        retry: Box<DropboxError>,
    },
    /// Immutable source bytes could not be loaded into the bounded upload buffer.
    #[error("could not read immutable upload staging")]
    UploadStageRead {
        #[source]
        source: io::Error,
    },

    /// The configured Dropbox folder is not an API path.
    #[error("configured Dropbox root must be empty or a normalized absolute Dropbox path")]
    InvalidRootPath,
    /// A timeout outside Dropbox's documented range was requested.
    #[error("Dropbox long-poll timeout must be between 30 and 480 seconds")]
    InvalidLongPollTimeout,
    /// The immutable stage exceeds Dropbox's documented upload-session limit.
    #[error(
        "immutable upload stage is {bytes} bytes; Dropbox upload sessions allow at most 350000000000 bytes"
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
    /// A returned upload hash differs from the verified immutable source.
    #[error("Dropbox upload response returned a different content identity")]
    UploadedContentMismatch,
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

fn validate_upload_size(bytes: u64) -> Result<(), DropboxError> {
    if bytes > UPLOAD_SESSION_MAX_BYTES {
        Err(DropboxError::UploadTooLarge { bytes })
    } else {
        Ok(())
    }
}

fn validate_uploaded_file(
    target: &str,
    metadata: files::FileMetadata,
    expected: &ContentIdentity,
) -> Result<RemoteFile, DropboxError> {
    validate_mutation_path(target, metadata.path_lower.as_deref())?;
    let remote = complete_remote_file(metadata).ok_or(DropboxError::InvalidMutationMetadata)?;
    if &remote.content != expected {
        return Err(DropboxError::UploadedContentMismatch);
    }
    Ok(remote)
}

fn validate_deleted_file(
    target: &str,
    metadata: files::Metadata,
    expected: &DropboxRevision,
) -> Result<(), DropboxError> {
    validate_mutation_path(target, metadata_paths(&metadata).0)?;
    let files::Metadata::File(metadata) = metadata else {
        return Err(DropboxError::InvalidMutationMetadata);
    };
    let remote = complete_remote_file(metadata).ok_or(DropboxError::InvalidMutationMetadata)?;
    if &remote.revision != expected {
        return Err(DropboxError::InvalidMutationMetadata);
    }
    Ok(())
}

fn metadata_remote_state(
    target: &str,
    metadata: files::Metadata,
) -> Result<RemotePathState, DropboxError> {
    validate_mutation_path(target, metadata_paths(&metadata).0)?;
    match metadata {
        files::Metadata::Deleted(_) => Ok(RemotePathState::Absent),
        files::Metadata::Folder(_) => Ok(RemotePathState::Folder),
        files::Metadata::File(file) if !file.is_downloadable || file.symlink_info.is_some() => {
            Ok(RemotePathState::Unsupported)
        }
        files::Metadata::File(file) => complete_remote_file(file)
            .map(RemotePathState::File)
            .ok_or(DropboxError::InvalidMutationMetadata),
    }
}

fn complete_remote_file(metadata: files::FileMetadata) -> Option<RemoteFile> {
    if !metadata.is_downloadable || metadata.symlink_info.is_some() {
        return None;
    }
    let content = metadata.content_hash?;
    let revision = metadata.rev;
    if !valid_content_hash(&content) || revision.is_empty() {
        return None;
    }
    Some(RemoteFile::new(
        ContentIdentity::new(content),
        DropboxRevision::new(revision),
    ))
}

fn validate_mutation_path(target: &str, path_lower: Option<&str>) -> Result<(), DropboxError> {
    if path_lower == Some(target.to_lowercase().as_str()) {
        Ok(())
    } else {
        Err(DropboxError::InvalidMutationMetadata)
    }
}

fn invalid_dropbox_component(component: &str) -> bool {
    component.is_empty() || component == "." || component == ".." || component.contains('\0')
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
    entries: Vec<files::Metadata>,
) -> Result<(), DropboxError> {
    let mut changes = Vec::new();
    append_entry_changes(root, &mut changes, entries)?;
    for change in changes {
        match change {
            RemoteInventoryChange::Upsert(record) => {
                let key = canonical_key(&record.canonical_path)?.to_owned();
                records.insert(key, record);
            }
            RemoteInventoryChange::EnsureDirectory(record) => {
                let key = canonical_key(&record.canonical_path)?.to_owned();
                if let Some(existing) = records.get_mut(&key) {
                    existing.observation = Observation::Directory;
                } else {
                    records.insert(key, record);
                }
            }
            RemoteInventoryChange::DeleteSubtree { canonical_path } => {
                remove_subtree(records, canonical_key(&canonical_path)?);
            }
        }
    }
    normalize_inventory_records(records)
}

fn append_entry_changes(
    root: &DropboxRoot,
    changes: &mut Vec<RemoteInventoryChange>,
    entries: Vec<files::Metadata>,
) -> Result<(), DropboxError> {
    for entry in entries {
        let (lower, display) = metadata_paths(&entry);
        let lower = lower.ok_or(DropboxError::InvalidEntryPath)?;
        let display = display.ok_or(DropboxError::InvalidEntryPath)?;
        let (key, path) = relative_paths(root, lower, display)?;
        let observation = match entry {
            files::Metadata::Deleted(_) => {
                changes.push(RemoteInventoryChange::DeleteSubtree {
                    canonical_path: CanonicalPath::from_bytes(key.into_bytes()),
                });
                continue;
            }
            files::Metadata::Folder(folder) if folder_restricted(&folder) => {
                return Err(DropboxError::RestrictedRemoteInventory);
            }
            files::Metadata::Folder(_) => Observation::Directory,
            files::Metadata::File(file) => {
                changes.push(RemoteInventoryChange::DeleteSubtree {
                    canonical_path: CanonicalPath::from_bytes(key.clone().into_bytes()),
                });
                if !file.is_downloadable || file.symlink_info.is_some() {
                    Observation::Unknown(UnknownReason::Unsupported)
                } else {
                    Observation::Present(
                        complete_remote_file(file).ok_or(DropboxError::IncompleteFileMetadata)?,
                    )
                }
            }
        };
        append_parent_folders(changes, &key, &path);
        changes.push(RemoteInventoryChange::Upsert(RemoteObservationRecord {
            canonical_path: CanonicalPath::from_bytes(key.into_bytes()),
            path,
            observation,
        }));
    }
    Ok(())
}

fn append_parent_folders(changes: &mut Vec<RemoteInventoryChange>, key: &str, path: &Path) {
    let lower = key.split('/').collect::<Vec<_>>();
    let display = path.iter().collect::<Vec<_>>();
    for depth in 1..lower.len() {
        let parent_key = lower[..depth].join("/");
        changes.push(RemoteInventoryChange::EnsureDirectory(
            RemoteObservationRecord {
                canonical_path: CanonicalPath::from_bytes(parent_key.into_bytes()),
                path: display[..depth].iter().copied().collect(),
                observation: Observation::Directory,
            },
        ));
    }
}

fn normalize_inventory_records(
    records: &mut BTreeMap<String, RemoteObservationRecord>,
) -> Result<(), DropboxError> {
    let directories = directory_casing(records.values().filter_map(|record| {
        (record.observation == Observation::Directory)
            .then_some((&record.canonical_path, &record.path))
    }))?;
    for record in records.values_mut() {
        record.path = normalized_remote_path(&record.canonical_path, &record.path, &directories)?;
    }
    Ok(())
}

fn normalize_inventory_changes(
    changes: &mut [RemoteInventoryChange],
    existing_directories: &[(CanonicalPath, PathBuf)],
) -> Result<(), DropboxError> {
    let mut directories = directory_casing(
        existing_directories
            .iter()
            .map(|(canonical, path)| (canonical, path)),
    )?;
    for change in changes.iter() {
        match change {
            RemoteInventoryChange::Upsert(record) => {
                if record.observation == Observation::Directory {
                    insert_directory_casing(
                        &mut directories,
                        &record.canonical_path,
                        &record.path,
                    )?;
                }
            }
            RemoteInventoryChange::EnsureDirectory(record) => {
                if !directories.contains_key(&record.canonical_path) {
                    insert_directory_casing(
                        &mut directories,
                        &record.canonical_path,
                        &record.path,
                    )?;
                }
            }
            RemoteInventoryChange::DeleteSubtree { canonical_path } => {
                directories.retain(|candidate, _| {
                    candidate != canonical_path && !candidate.is_beneath(canonical_path)
                });
            }
        }
    }
    for change in changes {
        match change {
            RemoteInventoryChange::Upsert(record)
            | RemoteInventoryChange::EnsureDirectory(record) => {
                record.path =
                    normalized_remote_path(&record.canonical_path, &record.path, &directories)?;
            }
            RemoteInventoryChange::DeleteSubtree { .. } => {}
        }
    }
    Ok(())
}

fn directory_casing<'a>(
    paths: impl IntoIterator<Item = (&'a CanonicalPath, &'a PathBuf)>,
) -> Result<BTreeMap<CanonicalPath, OsString>, DropboxError> {
    let mut directories = BTreeMap::new();
    for (canonical, path) in paths {
        insert_directory_casing(&mut directories, canonical, path)?;
    }
    Ok(directories)
}

fn insert_directory_casing(
    directories: &mut BTreeMap<CanonicalPath, OsString>,
    canonical: &CanonicalPath,
    path: &Path,
) -> Result<(), DropboxError> {
    let component = path
        .file_name()
        .ok_or(DropboxError::InvalidEntryPath)?
        .to_os_string();
    directories.insert(canonical.clone(), component);
    Ok(())
}

fn normalized_remote_path(
    canonical: &CanonicalPath,
    path: &Path,
    directories: &BTreeMap<CanonicalPath, OsString>,
) -> Result<PathBuf, DropboxError> {
    let canonical_components = canonical.as_path().iter().collect::<Vec<_>>();
    let display_components = path.iter().collect::<Vec<_>>();
    if canonical_components.len() != display_components.len() {
        return Err(DropboxError::InvalidEntryPath);
    }
    let mut prefix = PathBuf::new();
    let mut normalized = PathBuf::new();
    for (canonical_component, display_component) in
        canonical_components.into_iter().zip(display_components)
    {
        prefix.push(canonical_component);
        normalized.push(
            directories
                .get(prefix.as_os_str().as_bytes())
                .map_or(display_component, OsString::as_os_str),
        );
    }
    Ok(normalized)
}

/// Borrow one canonical path as the UTF-8 key used by the listing accumulator.
fn canonical_key(canonical: &CanonicalPath) -> Result<&str, DropboxError> {
    canonical
        .as_path()
        .to_str()
        .ok_or(DropboxError::InvalidEntryPath)
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

/// Policy extracted from a generated route error before retaining its source.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApiOutcome {
    Retry,
    Environmental,
    UserAction,
    Invariant,
    Unknown,
    Conflict,
    Rejected(MutationRejection),
    Absent,
    Unavailable,
    HashMismatch,
}

pub(crate) trait ApiError:
    std::error::Error + Send + Sync + Into<RouteError> + 'static
{
    fn outcome(&self) -> ApiOutcome;
}

impl ApiError for NoError {
    fn outcome(&self) -> ApiOutcome {
        match *self {}
    }
}

fn write_outcome(error: &files::WriteError) -> ApiOutcome {
    use files::WriteError as E;
    match error {
        E::Conflict(_) => ApiOutcome::Conflict,
        E::MalformedPath(_) => ApiOutcome::Rejected(MutationRejection::InvalidPath),
        E::NoWritePermission | E::AccessRestricted => {
            ApiOutcome::Rejected(MutationRejection::PermissionDenied)
        }
        E::InsufficientSpace => ApiOutcome::Rejected(MutationRejection::InsufficientSpace),
        E::DisallowedName => ApiOutcome::Rejected(MutationRejection::DisallowedName),
        E::TeamFolder | E::OperationSuppressed => {
            ApiOutcome::Rejected(MutationRejection::OperationNotAllowed)
        }
        E::TooManyWriteOperations => ApiOutcome::Retry,
        E::Other => ApiOutcome::Unknown,
        _ => ApiOutcome::Unknown, // SDK enums are non-exhaustive.
    }
}

fn lookup_outcome(error: &files::LookupError) -> ApiOutcome {
    use files::LookupError as E;
    match error {
        E::MalformedPath(_)
        | E::NotFound
        | E::NotFile
        | E::NotFolder
        | E::RestrictedContent
        | E::UnsupportedContentType => ApiOutcome::Unavailable,
        E::Locked => ApiOutcome::Environmental,
        E::Other => ApiOutcome::Unknown,
        _ => ApiOutcome::Unknown,
    }
}

impl ApiError for files::UploadError {
    fn outcome(&self) -> ApiOutcome {
        use files::UploadError as E;
        match self {
            E::Path(error) => write_outcome(&error.reason),
            E::PropertiesError(_) => ApiOutcome::Invariant,
            E::PayloadTooLarge => ApiOutcome::Retry,
            E::ContentHashMismatch => ApiOutcome::HashMismatch,
            E::EncryptionNotSupported => {
                ApiOutcome::Rejected(MutationRejection::OperationNotAllowed)
            }
            E::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}

impl ApiError for files::UploadSessionFinishError {
    #[allow(deprecated)]
    fn outcome(&self) -> ApiOutcome {
        use files::UploadSessionFinishError as E;
        match self {
            E::Path(error) => write_outcome(error),
            E::LookupFailed(error) => session_lookup_outcome(error),
            E::PropertiesError(_)
            | E::TooManySharedFolderTargets
            | E::ConcurrentSessionDataNotAllowed
            | E::ConcurrentSessionNotClosed
            | E::ConcurrentSessionMissingData => ApiOutcome::Invariant,
            E::TooManyWriteOperations | E::PayloadTooLarge => ApiOutcome::Retry,
            E::ContentHashMismatch => ApiOutcome::HashMismatch,
            E::EncryptionNotSupported => {
                ApiOutcome::Rejected(MutationRejection::OperationNotAllowed)
            }
            E::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}

fn session_lookup_outcome(error: &files::UploadSessionLookupError) -> ApiOutcome {
    use files::UploadSessionLookupError as E;
    match error {
        E::NotFound | E::Closed | E::TooLarge | E::IncorrectOffset(_) | E::PayloadTooLarge => {
            ApiOutcome::Retry
        }
        E::NotClosed | E::ConcurrentSessionInvalidOffset | E::ConcurrentSessionInvalidDataSize => {
            ApiOutcome::Invariant
        }
        E::Other => ApiOutcome::Unknown,
        _ => ApiOutcome::Unknown,
    }
}

impl ApiError for files::UploadSessionAppendError {
    fn outcome(&self) -> ApiOutcome {
        use files::UploadSessionAppendError as E;
        match self {
            E::NotFound | E::Closed | E::TooLarge | E::IncorrectOffset(_) | E::PayloadTooLarge => {
                ApiOutcome::Retry
            }
            E::ContentHashMismatch => ApiOutcome::HashMismatch,
            E::ConcurrentSessionInvalidOffset | E::ConcurrentSessionInvalidDataSize => {
                ApiOutcome::Invariant
            }
            E::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}

impl ApiError for files::UploadSessionStartError {
    fn outcome(&self) -> ApiOutcome {
        use files::UploadSessionStartError as E;
        match self {
            E::PayloadTooLarge => ApiOutcome::Retry,
            E::ContentHashMismatch => ApiOutcome::HashMismatch,
            E::ConcurrentSessionDataNotAllowed | E::ConcurrentSessionCloseNotAllowed => {
                ApiOutcome::Invariant
            }
            E::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}

impl ApiError for files::DeleteError {
    fn outcome(&self) -> ApiOutcome {
        use files::DeleteError as E;
        match self {
            E::PathLookup(files::LookupError::NotFound) => ApiOutcome::Absent,
            E::PathLookup(error) => lookup_outcome(error),
            E::PathWrite(error) => write_outcome(error),
            E::TooManyWriteOperations => ApiOutcome::Retry,
            E::TooManyFiles => ApiOutcome::Invariant,
            E::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}

impl ApiError for files::CreateFolderError {
    fn outcome(&self) -> ApiOutcome {
        match self {
            Self::Path(error) => write_outcome(error),
        }
    }
}
impl ApiError for files::GetMetadataError {
    fn outcome(&self) -> ApiOutcome {
        match self {
            Self::Path(error) => lookup_outcome(error),
        }
    }
}
impl ApiError for files::DownloadError {
    fn outcome(&self) -> ApiOutcome {
        match self {
            Self::Path(error) => lookup_outcome(error),
            Self::UnsupportedFile => ApiOutcome::Unavailable,
            Self::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}
impl ApiError for files::ListFolderError {
    fn outcome(&self) -> ApiOutcome {
        match self {
            Self::Path(_) => ApiOutcome::Environmental,
            Self::TemplateError(_) => ApiOutcome::Invariant,
            Self::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}
impl ApiError for files::ListFolderContinueError {
    fn outcome(&self) -> ApiOutcome {
        match self {
            Self::Path(_) => ApiOutcome::Environmental,
            Self::Reset => ApiOutcome::Retry,
            Self::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}
impl ApiError for files::ListFolderLongpollError {
    fn outcome(&self) -> ApiOutcome {
        match self {
            Self::Reset => ApiOutcome::Retry,
            Self::Other => ApiOutcome::Unknown,
            _ => ApiOutcome::Unknown,
        }
    }
}

impl DropboxError {
    pub(crate) fn sdk<E: ApiError>(operation: &'static str, error: SdkError<E>) -> Self {
        let outcome = match &error {
            SdkError::Api(error) => error.outcome(),
            SdkError::HttpClient(_) | SdkError::ServerError(_) | SdkError::RateLimited { .. } => {
                ApiOutcome::Retry
            }
            SdkError::Authentication(_) | SdkError::AccessDenied(_) => ApiOutcome::UserAction,
            SdkError::BadRequest(_)
            | SdkError::UnexpectedResponse(_)
            | SdkError::UnexpectedHttpError { .. }
            | SdkError::Json(_) => ApiOutcome::Invariant,
        };
        let mut source = match error {
            SdkError::Api(error) => SdkError::Api(error.into()),
            SdkError::HttpClient(error) => SdkError::HttpClient(error),
            SdkError::Json(error) => SdkError::Json(error),
            SdkError::UnexpectedResponse(body) => SdkError::UnexpectedResponse(body),
            SdkError::BadRequest(body) => SdkError::BadRequest(body),
            SdkError::Authentication(error) => SdkError::Authentication(error),
            SdkError::RateLimited {
                reason,
                retry_after_seconds,
            } => SdkError::RateLimited {
                reason,
                retry_after_seconds,
            },
            SdkError::AccessDenied(error) => SdkError::AccessDenied(error),
            SdkError::ServerError(body) => SdkError::ServerError(body),
            SdkError::UnexpectedHttpError { code, response } => {
                SdkError::UnexpectedHttpError { code, response }
            }
        };
        // Body strings may echo request input; retain the typed error and safe causes.
        match &mut source {
            SdkError::BadRequest(body)
            | SdkError::UnexpectedResponse(body)
            | SdkError::ServerError(body) => body.clear(),
            SdkError::UnexpectedHttpError { response, .. } => response.clear(),
            SdkError::Json(error) if error.is_data() => {
                *error = <serde_json::Error as serde::de::Error>::custom(
                    "invalid Dropbox response field",
                );
            }
            _ => {}
        }
        Self::Sdk {
            operation,
            outcome,
            source: Box::new(source),
        }
    }

    fn transport(source: TransportError) -> Self {
        Self::Sdk {
            operation: "prepare Dropbox transport",
            outcome: ApiOutcome::Retry,
            source: Box::new(SdkError::HttpClient(Box::new(source))),
        }
    }

    pub(crate) fn api_outcome(&self) -> ApiOutcome {
        match self {
            Self::Sdk { outcome, .. } => *outcome,
            _ => ApiOutcome::Unknown,
        }
    }

    pub(crate) fn transport_outcome(&self) -> Option<TransportOutcome> {
        match self {
            Self::Sdk { source, .. } => source
                .downcast_ref_inner::<TransportError>()
                .map(TransportError::outcome),
            _ => None,
        }
    }

    fn is_transport_retry(&self) -> bool {
        matches!(self, Self::Sdk { source, .. } if matches!(source.as_ref(), SdkError::HttpClient(_)))
            && matches!(
                self.transport_outcome(),
                None | Some(TransportOutcome::Retry { delay: None })
            )
    }

    fn mutation_may_have_applied(&self) -> bool {
        match self {
            Self::Sdk { source, .. } => match source.as_ref() {
                SdkError::HttpClient(_) => match source.downcast_ref_inner::<TransportError>() {
                    Some(TransportError::RateLimitFailure { .. }) => false,
                    Some(TransportError::DelayedBodyFailure { status, .. }) => *status >= 500,
                    Some(TransportError::ServerBusy { .. }) => true,
                    _ => self.is_transport_retry(),
                },
                SdkError::ServerError(_) | SdkError::Json(_) | SdkError::UnexpectedResponse(_) => {
                    true
                }
                _ => false,
            },
            _ => false,
        }
    }
}

/// Generated route sources retained without erasing their concrete types.
#[derive(Debug, Error)]
pub enum RouteError {
    #[error(transparent)]
    UploadError(#[from] files::UploadError),
    #[error(transparent)]
    UploadSessionFinishError(#[from] files::UploadSessionFinishError),
    #[error(transparent)]
    UploadSessionAppendError(#[from] files::UploadSessionAppendError),
    #[error(transparent)]
    UploadSessionStartError(#[from] files::UploadSessionStartError),
    #[error(transparent)]
    DeleteError(#[from] files::DeleteError),
    #[error(transparent)]
    CreateFolderError(#[from] files::CreateFolderError),
    #[error(transparent)]
    GetMetadataError(#[from] files::GetMetadataError),
    #[error(transparent)]
    DownloadError(#[from] files::DownloadError),
    #[error(transparent)]
    ListFolderError(#[from] files::ListFolderError),
    #[error(transparent)]
    ListFolderContinueError(#[from] files::ListFolderContinueError),
    #[error(transparent)]
    ListFolderLongpollError(#[from] files::ListFolderLongpollError),
}
impl From<NoError> for RouteError {
    fn from(error: NoError) -> Self {
        match error {}
    }
}
#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::error::Error;
    use std::io::{self, Cursor, Read};
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    use proptest::prelude::*;

    use crate::journal::RemoteObservationRecord;
    use crate::model::{
        CanonicalPath, ContentIdentity, DropboxRevision, Observation, RemoteFile, UnknownReason,
    };
    use crate::runtime_status::{
        TransferDirection, TransferEvent, TransferObserver, TransferProgress,
    };

    use super::{
        ApiOutcome, DropboxError, DropboxRoot, MutationRejection, PROGRESS_INTERVAL,
        ProgressReader, UPLOAD_SESSION_MAX_BYTES, apply_entries, files, lookup_outcome,
        validate_upload_size, write_outcome,
    };

    #[test]
    fn permanent_mutation_tags_have_stable_dispositions() -> Result<(), Box<dyn Error>> {
        for (tag, expected) in [
            ("disallowed_name", MutationRejection::DisallowedName),
            ("no_write_permission", MutationRejection::PermissionDenied),
            ("access_restricted", MutationRejection::PermissionDenied),
            ("insufficient_space", MutationRejection::InsufficientSpace),
            (
                "operation_suppressed",
                MutationRejection::OperationNotAllowed,
            ),
            ("team_folder", MutationRejection::OperationNotAllowed),
        ] {
            let error: files::WriteError =
                serde_json::from_str(&serde_json::json!({".tag": tag}).to_string())?;
            assert_eq!(write_outcome(&error), ApiOutcome::Rejected(expected));
        }
        assert_eq!(
            write_outcome(&files::WriteError::TooManyWriteOperations),
            ApiOutcome::Retry
        );
        assert_eq!(
            lookup_outcome(&files::LookupError::RestrictedContent),
            ApiOutcome::Unavailable
        );
        Ok(())
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

    fn file_metadata(lower: &str, display: &str) -> files::FileMetadata {
        files::FileMetadata::new(
            String::from("file"),
            String::from("id:file"),
            String::from("2024-01-02T03:04:05Z"),
            String::from("2024-01-02T03:04:05Z"),
            String::from(TEST_REVISION),
            0,
        )
        .with_path_lower(lower.to_owned())
        .with_path_display(display.to_owned())
        .with_content_hash(String::from(TEST_CONTENT_HASH))
    }

    fn folder_metadata(lower: &str, display: &str) -> files::FolderMetadata {
        files::FolderMetadata::new(String::from("folder"), String::from("id:folder"))
            .with_path_lower(lower.to_owned())
            .with_path_display(display.to_owned())
    }

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

        fn entry(self) -> files::Metadata {
            let path = self.path().dropbox_path();
            match self {
                Self::File(_) => files::Metadata::File(file_metadata(path, path)),
                Self::Folder(_) => files::Metadata::Folder(folder_metadata(path, path)),
                Self::Delete(_) => files::Metadata::Deleted(
                    files::DeletedMetadata::new(String::from("deleted"))
                        .with_path_lower(path.to_owned())
                        .with_path_display(path.to_owned()),
                ),
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
                    OracleNode::Folder => Observation::Directory,
                };
                (
                    key.clone(),
                    RemoteObservationRecord {
                        canonical_path: CanonicalPath::from_bytes(key.clone().into_bytes()),
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
    fn folders_are_directories_and_non_downloadable_files_are_unknown() -> Result<(), Box<dyn Error>>
    {
        let root = DropboxRoot::new("account", "namespace", "")?;
        let mut records = BTreeMap::new();
        let mut paper = file_metadata("/paper", "/Paper").with_is_downloadable(false);
        paper.content_hash = None;
        apply_entries(
            &root,
            &mut records,
            vec![
                files::Metadata::Folder(folder_metadata("/folder", "/Folder")),
                files::Metadata::File(paper),
            ],
        )?;

        assert_eq!(records.len(), 2);
        assert_eq!(records["folder"].observation, Observation::Directory);
        assert_eq!(
            records["paper"].observation,
            Observation::Unknown(UnknownReason::Unsupported)
        );
        Ok(())
    }

    #[test]
    fn directory_records_normalize_inconsistent_child_ancestor_casing() -> Result<(), Box<dyn Error>>
    {
        let root = DropboxRoot::new("account", "namespace", "")?;
        let mut records = BTreeMap::new();
        apply_entries(
            &root,
            &mut records,
            vec![files::Metadata::Folder(folder_metadata("/apps", "/apps"))],
        )?;
        apply_entries(
            &root,
            &mut records,
            vec![
                files::Metadata::File(file_metadata(
                    "/apps/day one/entry.doentry",
                    "/Apps/day one/Entry.doentry",
                )),
                files::Metadata::Folder(folder_metadata("/apps/day one", "/Apps/Day One")),
            ],
        )?;

        assert_eq!(records["apps"].path, Path::new("apps"));
        assert_eq!(records["apps/day one"].path, Path::new("apps/Day One"));
        assert_eq!(
            records["apps/day one/entry.doentry"].path,
            Path::new("apps/Day One/Entry.doentry")
        );
        Ok(())
    }

    #[test]
    fn listing_rejects_mismatched_canonical_and_display_paths() -> Result<(), Box<dyn Error>> {
        let root = DropboxRoot::new("account", "namespace", "")?;
        let mut records = BTreeMap::new();
        let result = apply_entries(
            &root,
            &mut records,
            vec![files::Metadata::File(file_metadata(
                "/report.txt",
                "/Different.txt",
            ))],
        );

        assert!(matches!(result, Err(DropboxError::InvalidEntryPath)));
        assert!(records.is_empty());
        Ok(())
    }

    #[test]
    fn direct_upload_limit_is_checked_before_network_io() {
        assert!(validate_upload_size(UPLOAD_SESSION_MAX_BYTES).is_ok());
        assert!(matches!(
            validate_upload_size(UPLOAD_SESSION_MAX_BYTES + 1),
            Err(DropboxError::UploadTooLarge { bytes })
                if bytes == UPLOAD_SESSION_MAX_BYTES + 1
        ));
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
