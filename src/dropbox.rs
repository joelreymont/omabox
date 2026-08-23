//! Documented blocking Dropbox read operations.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::auth::AccessToken;
use crate::journal::{
    DropboxBinding, DropboxBindingWrite, Journal, JournalError, RemoteObservationRecord,
};
use crate::local::{LocalError, StageOutcome, stage_download};
use crate::model::{ContentIdentity, DropboxRevision, Observation, RemoteFile, UnknownReason};

const LONG_POLL_MINIMUM_SECONDS: u64 = 30;
const LONG_POLL_MAXIMUM_SECONDS: u64 = 480;
const JSON_REQUEST_SECONDS: u64 = 60;
const CONNECT_SECONDS: u64 = 15;
const DOWNLOAD_SECONDS: u64 = 60 * 60;
const LONG_POLL_GRACE_SECONDS: u64 = 15;

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

/// Result of one Dropbox long-poll request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LongPollWakeup {
    /// Whether the cursor has changes ready to list.
    pub changes: bool,
    /// Server-requested delay before the next long poll.
    pub backoff: Option<Duration>,
}

/// Direct blocking client for Dropbox read endpoints.
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
        require_success(response.status().as_u16(), "wait for Dropbox changes")?;
        let payload: LongPollResponse =
            response
                .body_mut()
                .read_json()
                .map_err(|source| DropboxError::Response {
                    operation: "decode Dropbox long-poll response",
                    source,
                })?;
        Ok(LongPollWakeup {
            changes: payload.changes,
            backoff: payload.backoff.map(Duration::from_secs),
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
        require_success(response.status().as_u16(), "validate Dropbox account")?;
        response
            .body_mut()
            .read_json()
            .map_err(|source| DropboxError::Response {
                operation: "decode Dropbox account response",
                source,
            })
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
        require_success(status, "continue complete Dropbox listing")?;
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
        require_success(response.status().as_u16(), operation)?;
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
        serde_json::to_string(&PathRootHeader {
            tag: "root",
            root: &self.root.namespace_id,
        })
        .map_err(|source| DropboxError::Json {
            operation: "encode Dropbox path root",
            source,
        })
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

/// Dropbox protocol, validation, or publication failure.
#[derive(Debug, Error)]
pub enum DropboxError {
    /// The configured Dropbox folder is not an API path.
    #[error("configured Dropbox root must be empty or a normalized absolute Dropbox path")]
    InvalidRootPath,
    /// A timeout outside Dropbox's documented range was requested.
    #[error("Dropbox long-poll timeout must be between 30 and 480 seconds")]
    InvalidLongPollTimeout,
    /// The live account, Secret Service record, and journal do not share one binding.
    #[error("Dropbox account or root binding no longer matches the journal")]
    AccountBindingChanged,
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
    /// A full listing unexpectedly contained deletion metadata.
    #[error("Dropbox full listing unexpectedly contained a deleted entry")]
    UnexpectedDeletedEntry,
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
    /// Verified bytes could not be written into local staging.
    #[error("could not stage an exact Dropbox download")]
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

fn require_success(status: u16, operation: &'static str) -> Result<(), DropboxError> {
    if (200..300).contains(&status) {
        Ok(())
    } else {
        Err(DropboxError::HttpStatus { operation, status })
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
        let observation = match entry.tag {
            EntryTag::Deleted => return Err(DropboxError::UnexpectedDeletedEntry),
            EntryTag::Folder => Observation::Unknown(UnknownReason::Unsupported),
            EntryTag::File if !entry.is_downloadable || entry.symlink_info.is_some() => {
                Observation::Unknown(UnknownReason::Unsupported)
            }
            EntryTag::File => {
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
        };
        records.insert(key, RemoteObservationRecord { path, observation });
    }
    Ok(())
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

    use super::{DropboxRoot, EntryTag, ListEntry, apply_entries};

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
                },
                ListEntry {
                    tag: EntryTag::File,
                    path_lower: Some(String::from("/paper")),
                    path_display: Some(String::from("/Paper")),
                    rev: Some(String::from("1")),
                    content_hash: None,
                    is_downloadable: false,
                    symlink_info: None,
                },
            ],
        )?;

        assert_eq!(records.len(), 2);
        assert!(records.values().all(|record| {
            record.observation == Observation::Unknown(UnknownReason::Unsupported)
        }));
        Ok(())
    }
}
