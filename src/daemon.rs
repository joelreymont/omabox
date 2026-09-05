//! Long-running daemon control, recovery policy, and synchronization sessions.

use std::env;
use std::error::Error as StdError;
use std::ffi::OsStr;
use std::io;
use std::os::linux::net::SocketAddrExt as _;
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::net::{SocketAddr, UnixDatagram};
use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use miette::Diagnostic;
use thiserror::Error;

use crate::auth::{AuthError, CredentialLookup, RefreshTokenStore, StoredCredential};
use crate::config::{
    Config, ConfigError, InstanceLock, LockError, LoggingError, initialize_logging,
};
use crate::dropbox::{AccountValidation, DropboxClient, DropboxError, DropboxRoot, LongPollWakeup};
use crate::journal::{
    DropboxBinding, Journal, JournalError, LocalRootActivation, LocalRootBinding,
};
use crate::local::LocalError;
use crate::reconcile::{ExactDownloadPool, ReconcileError, ReconcileOutcome, reconcile_once};
use crate::recovery::RecoveryError;
use crate::runtime_status::{DaemonPhase, RuntimeStatus};

const LONG_POLL_TIMEOUT: Duration = Duration::from_secs(30);
const STATUS_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(20);
const FRESH_OBSERVATION_DELAY: Duration = Duration::from_secs(1);
const RETRY_BASE: Duration = Duration::from_secs(5);
const RETRY_CEILING: Duration = Duration::from_secs(5 * 60);
const MAX_RETRY_AFTER: Duration = Duration::from_secs(15 * 60);
const EXIT_USER_ACTION: u8 = 78;
const EXIT_INVARIANT: u8 = 70;

const SETUP: &str = "Omabox setup is incomplete.";
const CONFIGURATION: &str = "Omabox configuration is unavailable.";
const CONFIGURATION_INVALID: &str = "Omabox configuration needs attention.";
const STATE: &str = "Omabox state storage is unavailable.";
const DISK_FULL: &str = "Local storage is full.";
const JOURNAL: &str = "The sync journal is temporarily unavailable.";
const JOURNAL_INVALID: &str = "The sync journal needs attention.";
const CREDENTIALS: &str = "Dropbox credentials are temporarily unavailable.";
const CREDENTIAL_INVALID: &str = "Dropbox credentials need to be renewed.";
const DROPBOX: &str = "Dropbox is temporarily unavailable.";
const BINDING: &str = "The Dropbox account or sync root no longer matches setup.";
const SYNC_ROOT: &str = "The configured sync folder is temporarily unavailable.";
const SYNC_ERRORS: &str = "One or more files could not be synchronized.";
const CURSOR: &str = "The Dropbox inventory cursor is temporarily unavailable.";
const RUNNING: &str = "Another Omabox daemon is already running.";
const READINESS: &str = "Omabox could not notify the service manager that startup completed.";
const INTERNAL: &str = "Omabox stopped after detecting invalid internal state.";
const LOGGING: &str = "Omabox logging could not start.";

/// The single recovery decision attached to every daemon failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Disposition {
    /// Retry a transient remote failure after at least this server-requested delay.
    Retry(Duration),
    /// Wait with escalating backoff for the local environment to recover.
    Environmental,
    /// Exit because setup or another explicit user action is required.
    UserAction,
    /// Exit because durable or in-process state violated an invariant.
    Invariant,
}

#[derive(Clone, Copy)]
struct FailurePolicy {
    disposition: Disposition,
    status: &'static str,
}

impl FailurePolicy {
    const fn new(disposition: Disposition, status: &'static str) -> Self {
        Self {
            disposition,
            status,
        }
    }
}

/// Run the daemon entry point and return its systemd-visible exit status.
#[must_use]
pub fn entry() -> ExitCode {
    let result = initialize_logging()
        .map_err(DaemonError::Logging)
        .and_then(|()| run());
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let code = error.exit_code();
            eprintln!("{:?}", miette::Report::new(error));
            ExitCode::from(code)
        }
    }
}

fn run() -> Result<(), DaemonError> {
    let status = match RuntimeStatus::from_environment() {
        Ok(status) => Some(status),
        Err(error) => {
            tracing::warn!(error = %error, "runtime status is unavailable; syncing will continue");
            None
        }
    };
    start_status_heartbeat(status.as_ref());
    let mut recovery = RecoveryControl::new(status.as_ref());
    let mut wait = |delay| thread::sleep(delay);

    let config = recovery.recover_with(
        || {
            let config = Config::load().map_err(DaemonError::Config)?;
            config.prepare().map_err(DaemonError::Config)?;
            Ok(config)
        },
        &mut wait,
    )?;
    let _instance_lock = recovery.recover_with(
        || InstanceLock::acquire(config.paths().lock_file()).map_err(DaemonError::Lock),
        &mut wait,
    )?;
    let mut journal = recovery.recover_with(
        || {
            Journal::open(config.paths().journal_file()).map_err(|source| DaemonError::Journal {
                operation: "open the journal",
                source,
            })
        },
        &mut wait,
    )?;
    recovery.recover_with(notify_ready, &mut wait)?;

    run_owned(&config, &mut journal, &mut recovery, &mut wait)
}

fn notify_ready() -> Result<(), DaemonError> {
    let target = env::var_os("NOTIFY_SOCKET");
    send_readiness(target.as_deref()).map_err(|source| DaemonError::Notify { source })
}

fn send_readiness(target: Option<&OsStr>) -> io::Result<()> {
    let Some(target) = target else {
        return Ok(());
    };
    let bytes = target.as_bytes();
    let address = match bytes.strip_prefix(b"@") {
        Some(name) => SocketAddr::from_abstract_name(name)?,
        None => SocketAddr::from_pathname(Path::new(target))?,
    };
    let socket = UnixDatagram::unbound()?;
    let sent = socket.send_to_addr(b"READY=1", &address)?;
    if sent == b"READY=1".len() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "systemd readiness datagram was truncated",
        ))
    }
}

fn run_owned(
    config: &Config,
    journal: &mut Journal,
    recovery: &mut RecoveryControl<'_>,
    wait: &mut impl FnMut(Duration),
) -> Result<(), DaemonError> {
    loop {
        match run_session(config, journal, recovery, wait) {
            Ok(()) => return Ok(()),
            Err(error) => recovery.wait_for_failure(error, wait)?,
        }
    }
}

fn run_session(
    config: &Config,
    journal: &mut Journal,
    recovery: &mut RecoveryControl<'_>,
    wait: &mut impl FnMut(Duration),
) -> Result<(), DaemonError> {
    publish_phase(recovery.status, DaemonPhase::Starting);
    let StoredCredential {
        binding: credential_binding,
        refresh_token,
    } = match RefreshTokenStore::new()
        .load()
        .map_err(|source| DaemonError::Auth {
            operation: "load the Dropbox credential",
            source,
        })? {
        CredentialLookup::Found(credential) => credential,
        CredentialLookup::CredentialsUnavailable { status } => {
            return Err(DaemonError::CredentialsUnavailable { status });
        }
    };
    let durable_binding = journal
        .dropbox_binding()
        .map_err(|source| DaemonError::Journal {
            operation: "read the Dropbox binding",
            source,
        })?;
    let root = root_from_bindings(durable_binding, &credential_binding)?;
    let dropbox = DropboxClient::from_credentials(
        config.dropbox_app_key(),
        StoredCredential {
            binding: credential_binding,
            refresh_token,
        },
        root,
    )
    .map_err(|source| DaemonError::Dropbox {
        operation: "prepare Dropbox access",
        source,
    })?;
    let dropbox = match recovery.status {
        Some(status) => dropbox.with_transfer_observer(status.transfer_observer()),
        None => dropbox,
    };
    let dropbox = Arc::new(dropbox);
    loop {
        let validation = dropbox
            .validate_account(journal)
            .map_err(|source| DaemonError::Dropbox {
                operation: "validate the Dropbox account and root",
                source,
            });
        let Some(validation) = recovery.retain_session(validation, wait)? else {
            continue;
        };
        match validation {
            AccountValidation::Valid => break,
            AccountValidation::AccountChanged => return Err(DaemonError::AccountChanged),
            AccountValidation::RootChanged => return Err(DaemonError::RootChanged),
            AccountValidation::JournalBindingChanged => {
                return Err(DaemonError::JournalBindingChanged);
            }
        }
    }
    let mut downloads = ExactDownloadPool::new(Arc::clone(&dropbox))
        .map_err(|source| DaemonError::Reconcile { source })?;
    tracing::info!("Omabox daemon session started");

    let mut long_poll_backoff: Option<Duration> = None;
    loop {
        publish_phase(recovery.status, DaemonPhase::Syncing);
        if recovery
            .retain_session(activate_configured_root(config, journal), wait)?
            .is_none()
        {
            continue;
        }
        let reconciliation = reconcile_once(
            journal,
            &dropbox,
            &mut downloads,
            config.sync_root(),
            config.paths().upload_staging_directory(),
            config.paths().recovery_directory(),
        )
        .map_err(|source| DaemonError::Reconcile { source });
        if matches!(&reconciliation, Err(error) if error.session_must_rebuild()) {
            if let Err(error) = reconciliation {
                recovery.wait_for_failure(error, wait)?;
            }
            downloads = ExactDownloadPool::new(Arc::clone(&dropbox))
                .map_err(|source| DaemonError::Reconcile { source })?;
            continue;
        }
        let Some(reconciliation) = recovery.retain_session(reconciliation, wait)? else {
            continue;
        };
        match reconciliation {
            ReconcileOutcome::Complete(report) => {
                tracing::info!(
                    replayed_operations = report.replayed_operations,
                    noops = report.noops,
                    planned = report.planned,
                    blocked = report.blocked,
                    sync_errors = report.sync_errors,
                    downloads_in_progress = report.downloads_in_progress,
                    conflicts = report.conflicts,
                    "reconciliation pass completed"
                );
                if report.sync_errors == 0 {
                    recovery.clean_sync_pass();
                    if !report.downloads_in_progress {
                        publish_phase(recovery.status, DaemonPhase::Waiting);
                    }
                } else if let Some(status) = recovery.status {
                    status.sync_error();
                }
            }
            ReconcileOutcome::FreshObservationRequired { .. } => {
                tracing::info!("local state changed during reconciliation");
                wait_in_phase(
                    FRESH_OBSERVATION_DELAY,
                    recovery.status,
                    DaemonPhase::Syncing,
                    wait,
                );
                continue;
            }
            ReconcileOutcome::LocalRootChanged => {
                let error = DaemonError::Reconcile {
                    source: ReconcileError::LocalRootChanged,
                };
                let _ = recovery.retain_session::<()>(Err(error), wait)?;
                continue;
            }
        }

        if let Some(delay) = long_poll_backoff.take() {
            tracing::info!(seconds = delay.as_secs(), "honoring Dropbox backoff");
            wait_in_phase(delay, recovery.status, DaemonPhase::Backoff, wait);
        }
        let cursor = journal
            .remote_cursor()
            .map_err(|source| DaemonError::Journal {
                operation: "read the Dropbox cursor",
                source,
            })
            .and_then(|cursor| cursor.ok_or(DaemonError::MissingRemoteCursor));
        let Some(cursor) = recovery.retain_session(cursor, wait)? else {
            continue;
        };
        let wakeup = dropbox
            .long_poll(&cursor, LONG_POLL_TIMEOUT)
            .map_err(|source| DaemonError::Dropbox {
                operation: "wait for Dropbox changes",
                source,
            });
        let Some(wakeup) = recovery.retain_session(wakeup, wait)? else {
            continue;
        };
        recovery.cycle_completed();
        long_poll_backoff = match wakeup {
            LongPollWakeup::Changes { backoff } | LongPollWakeup::TimedOut { backoff } => backoff,
            LongPollWakeup::CursorReset => None,
        };
    }
}

fn activate_configured_root(config: &Config, journal: &mut Journal) -> Result<(), DaemonError> {
    let binding =
        LocalRootBinding::inspect(config.sync_root()).map_err(|source| DaemonError::Journal {
            operation: "inspect the configured local root",
            source,
        })?;
    match journal
        .activate_local_root(&binding)
        .map_err(|source| DaemonError::Journal {
            operation: "activate the configured local root",
            source,
        })? {
        LocalRootActivation::Current(_) => Ok(()),
        LocalRootActivation::Activated(record) => {
            tracing::info!(
                generation = record.generation,
                "initialized a new local sync-root generation"
            );
            Ok(())
        }
        LocalRootActivation::Unavailable { recorded, actual } => {
            Err(DaemonError::LocalRootUnavailable { recorded, actual })
        }
    }
}

struct RecoveryControl<'status> {
    schedule: RetrySchedule,
    status: Option<&'status RuntimeStatus>,
}

impl<'status> RecoveryControl<'status> {
    fn new(status: Option<&'status RuntimeStatus>) -> Self {
        Self {
            schedule: RetrySchedule::new(),
            status,
        }
    }

    fn recover_with<T>(
        &mut self,
        mut operation: impl FnMut() -> Result<T, DaemonError>,
        wait: &mut impl FnMut(Duration),
    ) -> Result<T, DaemonError> {
        loop {
            match operation() {
                Ok(value) => return Ok(value),
                Err(error) => self.wait_for_failure(error, wait)?,
            }
        }
    }

    fn wait_for_failure(
        &mut self,
        error: DaemonError,
        wait: &mut impl FnMut(Duration),
    ) -> Result<(), DaemonError> {
        let policy = error.policy();
        if let Some(status) = self.status {
            status.error(policy.status);
        }
        let (minimum, phase) = match policy.disposition {
            Disposition::Retry(minimum) => (minimum, Some(DaemonPhase::Backoff)),
            Disposition::Environmental => (Duration::ZERO, None),
            Disposition::UserAction | Disposition::Invariant => return Err(error),
        };
        let delay = self.schedule.advance(minimum);
        let mut reason: &(dyn StdError + 'static) = &error;
        while let Some(source) = reason.source() {
            reason = source;
        }
        tracing::warn!(
            error = %error,
            reason = %reason,
            seconds = delay.as_secs(),
            "daemon operation failed; retrying in process"
        );
        if let Some(phase) = phase {
            publish_phase(self.status, phase);
        }
        wait(delay);
        Ok(())
    }

    fn retain_session<T>(
        &mut self,
        result: Result<T, DaemonError>,
        wait: &mut impl FnMut(Duration),
    ) -> Result<Option<T>, DaemonError> {
        match result {
            Ok(value) => Ok(Some(value)),
            Err(error) if error.session_must_rebuild() => Err(error),
            Err(error) => {
                self.wait_for_failure(error, wait)?;
                Ok(None)
            }
        }
    }

    fn clean_sync_pass(&self) {
        if let Some(status) = self.status {
            status.clear_error();
        }
    }

    fn cycle_completed(&mut self) {
        self.schedule.reset();
    }
}

struct RetrySchedule {
    next: Duration,
}

impl RetrySchedule {
    const fn new() -> Self {
        Self { next: RETRY_BASE }
    }

    fn advance(&mut self, minimum: Duration) -> Duration {
        let delay = self.next.max(minimum.min(MAX_RETRY_AFTER));
        self.next = self.next.saturating_mul(2).min(RETRY_CEILING);
        delay
    }

    fn reset(&mut self) {
        self.next = RETRY_BASE;
    }
}

fn wait_in_phase(
    delay: Duration,
    status: Option<&RuntimeStatus>,
    phase: DaemonPhase,
    wait: &mut impl FnMut(Duration),
) {
    publish_phase(status, phase);
    wait(delay);
}

fn publish_phase(status: Option<&RuntimeStatus>, phase: DaemonPhase) {
    if let Some(status) = status {
        status.phase(phase);
    }
}

fn start_status_heartbeat(status: Option<&RuntimeStatus>) {
    let Some(status) = status else {
        return;
    };
    let status = status.clone();
    match thread::Builder::new()
        .name(String::from("omabox-status"))
        .spawn(move || {
            loop {
                thread::sleep(STATUS_HEARTBEAT_INTERVAL);
                status.heartbeat();
            }
        }) {
        Ok(handle) => drop(handle),
        Err(source) => {
            tracing::warn!(error = %source, "could not start the runtime status heartbeat");
        }
    }
}

fn root_from_bindings(
    durable_binding: Option<DropboxBinding>,
    credential_binding: &DropboxBinding,
) -> Result<DropboxRoot, DaemonError> {
    let Some(durable_binding) = durable_binding else {
        return Err(DaemonError::SetupRequired);
    };
    if durable_binding != *credential_binding {
        return Err(DaemonError::CredentialBindingChanged);
    }
    DropboxRoot::from_binding(&durable_binding).map_err(|source| DaemonError::Dropbox {
        operation: "restore the durable Dropbox root",
        source,
    })
}

/// A typed daemon initialization, session, or recovery failure.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum DaemonError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    Logging(#[from] LoggingError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    Config(#[from] ConfigError),
    #[error(transparent)]
    #[diagnostic(transparent)]
    Lock(#[from] LockError),
    #[error("could not send the systemd readiness notification")]
    #[diagnostic(
        code(omabox::daemon::readiness),
        help("Ensure the systemd notification socket is available, then retry.")
    )]
    Notify {
        #[source]
        source: io::Error,
    },
    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::daemon::journal),
        help("Ensure the Omabox state directory is writable and retry.")
    )]
    Journal {
        operation: &'static str,
        #[source]
        source: JournalError,
    },
    #[error("the configured sync root path now names a different filesystem object")]
    #[diagnostic(
        code(omabox::daemon::local_root_unavailable),
        help("Restore the previous sync root, or select this directory again in Omabox settings.")
    )]
    LocalRootUnavailable {
        recorded: LocalRootBinding,
        actual: LocalRootBinding,
    },
    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::daemon::oauth),
        help("Check the network connection, Dropbox app key, and Secret Service, then retry.")
    )]
    Auth {
        operation: &'static str,
        #[source]
        source: AuthError,
    },
    #[error("Dropbox credentials are unavailable (credential helper status: {status:?})")]
    #[diagnostic(
        code(omabox::daemon::credentials_unavailable),
        help(
            "Unlock Secret Service, or run `omabox setup [REMOTE_ROOT]` once, then restart Omabox."
        )
    )]
    CredentialsUnavailable { status: Option<i32> },
    #[error("Omabox setup has not completed")]
    #[diagnostic(
        code(omabox::daemon::setup_required),
        help("Run `omabox setup [REMOTE_ROOT]` once, then restart Omabox.")
    )]
    SetupRequired,
    #[error("the stored Dropbox credential does not match this journal")]
    #[diagnostic(
        code(omabox::daemon::credential_binding_changed),
        help(
            "Run `omabox setup` with the Dropbox account and root already bound to this journal."
        )
    )]
    CredentialBindingChanged,
    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::daemon::dropbox),
        help("Check the network connection and Dropbox account, then retry.")
    )]
    Dropbox {
        operation: &'static str,
        #[source]
        source: DropboxError,
    },
    #[error("the Dropbox credential belongs to a different account")]
    #[diagnostic(
        code(omabox::daemon::account_changed),
        help("Run `omabox setup` with the Dropbox account already bound to this journal.")
    )]
    AccountChanged,
    #[error("the Dropbox account root namespace changed")]
    #[diagnostic(
        code(omabox::daemon::root_changed),
        help("Restore access to the Dropbox namespace already bound to this journal.")
    )]
    RootChanged,
    #[error("the journal Dropbox binding changed during startup")]
    #[diagnostic(
        code(omabox::daemon::journal_binding_changed),
        help("Stop other Omabox processes and restart the service.")
    )]
    JournalBindingChanged,
    #[error("could not reconcile local files with Dropbox")]
    #[diagnostic(
        code(omabox::daemon::reconcile),
        help("The durable journal will resume safe work when the service restarts.")
    )]
    Reconcile {
        #[source]
        source: ReconcileError,
    },
    #[error("the completed Dropbox inventory has no durable cursor")]
    #[diagnostic(
        code(omabox::daemon::missing_remote_cursor),
        help("Restart Omabox so it can rebuild the Dropbox inventory.")
    )]
    MissingRemoteCursor,
}

impl DaemonError {
    /// Return the retry or exit disposition assigned to this exact failure.
    #[must_use]
    pub fn disposition(&self) -> Disposition {
        self.policy().disposition
    }

    fn policy(&self) -> FailurePolicy {
        match self {
            Self::Logging(_) => FailurePolicy::new(Disposition::Invariant, LOGGING),
            Self::Config(source) => config_policy(source),
            Self::Lock(source) => lock_policy(source),
            Self::Notify { .. } => FailurePolicy::new(Disposition::Environmental, READINESS),
            Self::Journal { source, .. } => journal_policy(source),
            Self::LocalRootUnavailable { .. } => {
                FailurePolicy::new(Disposition::Environmental, SYNC_ROOT)
            }
            Self::Auth { source, .. } => auth_policy(source),
            Self::CredentialsUnavailable { .. } => {
                FailurePolicy::new(Disposition::Environmental, CREDENTIALS)
            }
            Self::SetupRequired => FailurePolicy::new(Disposition::UserAction, SETUP),
            Self::CredentialBindingChanged
            | Self::AccountChanged
            | Self::RootChanged
            | Self::JournalBindingChanged => FailurePolicy::new(Disposition::UserAction, BINDING),
            Self::Dropbox { source, .. } => dropbox_policy(source),
            Self::Reconcile { source } => reconcile_policy(source),
            Self::MissingRemoteCursor => FailurePolicy::new(Disposition::Environmental, CURSOR),
        }
    }

    /// Return the fixed, non-secret runtime status for this failure.
    #[must_use]
    pub fn public_status(&self) -> &'static str {
        self.policy().status
    }

    fn exit_code(&self) -> u8 {
        match self.disposition() {
            Disposition::UserAction => EXIT_USER_ACTION,
            Disposition::Invariant => EXIT_INVARIANT,
            Disposition::Retry(_) | Disposition::Environmental => EXIT_INVARIANT,
        }
    }

    fn session_must_rebuild(&self) -> bool {
        matches!(
            self,
            Self::Reconcile {
                source: ReconcileError::DownloadWorkerStopped
            }
        )
    }
}

fn config_policy(error: &ConfigError) -> FailurePolicy {
    match error {
        ConfigError::HomeDirectoryUnavailable
        | ConfigError::PathNotAbsolute { .. }
        | ConfigError::Parse { .. }
        | ConfigError::EmptyDropboxAppKey
        | ConfigError::AlreadyExists { .. }
        | ConfigError::ProtectedPathInsideSyncRoot { .. } => {
            FailurePolicy::new(Disposition::UserAction, CONFIGURATION_INVALID)
        }
        ConfigError::Read { source, .. } if source.kind() == std::io::ErrorKind::NotFound => {
            FailurePolicy::new(Disposition::UserAction, SETUP)
        }
        ConfigError::Read { .. }
        | ConfigError::PrepareConfigurationDirectory { .. }
        | ConfigError::Write { .. }
        | ConfigError::CleanupAfterWrite { .. } => {
            FailurePolicy::new(Disposition::Environmental, CONFIGURATION)
        }
        ConfigError::ResolveSyncRoot { .. }
        | ConfigError::SyncRootNotDirectory { .. }
        | ConfigError::InspectPath { .. } => {
            FailurePolicy::new(Disposition::Environmental, SYNC_ROOT)
        }
        ConfigError::CreateDirectory { source, .. }
        | ConfigError::SetDirectoryPermissions { source, .. } => {
            if disk_full(source) {
                FailurePolicy::new(Disposition::Environmental, DISK_FULL)
            } else {
                FailurePolicy::new(Disposition::Environmental, STATE)
            }
        }
        ConfigError::Serialize(_) => FailurePolicy::new(Disposition::Invariant, INTERNAL),
    }
}

fn lock_policy(error: &LockError) -> FailurePolicy {
    match error {
        LockError::AlreadyRunning { .. } => FailurePolicy::new(Disposition::UserAction, RUNNING),
        LockError::Open { source, .. } | LockError::Acquire { source, .. } => {
            if disk_full(source) {
                FailurePolicy::new(Disposition::Environmental, DISK_FULL)
            } else {
                FailurePolicy::new(Disposition::Environmental, STATE)
            }
        }
    }
}

fn journal_policy(error: &JournalError) -> FailurePolicy {
    match error {
        JournalError::File { source, .. } => {
            if disk_full(source) {
                FailurePolicy::new(Disposition::Environmental, DISK_FULL)
            } else {
                FailurePolicy::new(Disposition::Environmental, JOURNAL)
            }
        }
        JournalError::Sqlite { source, .. } if sqlite_corrupt(source) => {
            FailurePolicy::new(Disposition::UserAction, JOURNAL_INVALID)
        }
        JournalError::Sqlite { source, .. } => {
            if sqlite_full(source) {
                FailurePolicy::new(Disposition::Environmental, DISK_FULL)
            } else {
                FailurePolicy::new(Disposition::Environmental, JOURNAL)
            }
        }
        JournalError::Json { .. } | JournalError::InvalidState { .. } => {
            FailurePolicy::new(Disposition::Invariant, JOURNAL_INVALID)
        }
        JournalError::UnsupportedVersion { .. } => {
            FailurePolicy::new(Disposition::UserAction, JOURNAL_INVALID)
        }
    }
}

fn auth_policy(error: &AuthError) -> FailurePolicy {
    match error {
        AuthError::Sdk { source } => transport_policy(source.outcome()),
        AuthError::MissingRefreshToken
        | AuthError::CredentialJson { .. }
        | AuthError::CredentialUtf8 { .. }
        | AuthError::CredentialTooLarge
        | AuthError::StoredCredentialVersion { .. } => {
            FailurePolicy::new(Disposition::UserAction, CREDENTIAL_INVALID)
        }
        AuthError::Random { .. } => FailurePolicy::new(Disposition::Environmental, STATE),
        AuthError::CredentialSpawn { .. }
        | AuthError::CredentialPipeUnavailable { .. }
        | AuthError::CredentialWrite { .. }
        | AuthError::CredentialRead { .. }
        | AuthError::CredentialWait { .. }
        | AuthError::CredentialStatus { .. }
        | AuthError::CredentialCleanup { .. } => {
            FailurePolicy::new(Disposition::Environmental, CREDENTIALS)
        }
    }
}

fn dropbox_policy(error: &DropboxError) -> FailurePolicy {
    match error {
        DropboxError::Sdk {
            outcome, source, ..
        } => {
            if let Some(outcome) = error.transport_outcome() {
                return transport_policy(outcome);
            }
            if let dropbox_sdk::Error::RateLimited {
                retry_after_seconds,
                ..
            } = source.as_ref()
            {
                return retry_policy(Some(Duration::from_secs(u64::from(*retry_after_seconds))));
            }
            use crate::dropbox::ApiOutcome as O;
            match outcome {
                O::Retry | O::HashMismatch => retry_policy(None),
                O::UserAction => FailurePolicy::new(Disposition::UserAction, BINDING),
                O::Invariant => FailurePolicy::new(Disposition::Invariant, INTERNAL),
                O::Environmental
                | O::Unknown
                | O::Conflict
                | O::Rejected(_)
                | O::Absent
                | O::Unavailable => FailurePolicy::new(Disposition::Environmental, DROPBOX),
            }
        }
        DropboxError::UnverifiedMutation { verification, .. } => dropbox_policy(verification),
        DropboxError::RetriedTransport { retry, .. } => dropbox_policy(retry),
        DropboxError::UploadedContentMismatch => retry_policy(None),

        DropboxError::DownloadBody { .. } => retry_policy(None),
        DropboxError::AccountBindingChanged => FailurePolicy::new(Disposition::UserAction, BINDING),
        DropboxError::InvalidRootPath
        | DropboxError::InvalidLongPollTimeout
        | DropboxError::UploadSessionOffsetOverflow => {
            FailurePolicy::new(Disposition::Invariant, INTERNAL)
        }
        DropboxError::LocalStage { source } => local_policy(source),
        DropboxError::Journal { source } => journal_policy(source),
        DropboxError::RemoteRootUnavailable
        | DropboxError::RemoteRootNotFolder
        | DropboxError::RemoteRootRestricted
        | DropboxError::RestrictedRemoteInventory
        | DropboxError::IncorrectUploadSessionOffset { .. }
        | DropboxError::InvalidEntryPath
        | DropboxError::IncompleteFileMetadata
        | DropboxError::CursorDidNotAdvance
        | DropboxError::ResetDuringFreshListing
        | DropboxError::MissingDownloadMetadata
        | DropboxError::DownloadedRevisionChanged
        | DropboxError::DownloadedIdentityChanged
        | DropboxError::DownloadedSizeChanged
        | DropboxError::InvalidDownloadRange
        | DropboxError::DownloadedLengthChanged
        | DropboxError::InvalidMutationMetadata => {
            FailurePolicy::new(Disposition::Environmental, DROPBOX)
        }
        DropboxError::UploadTooLarge { .. } => {
            FailurePolicy::new(Disposition::Environmental, SYNC_ERRORS)
        }
        DropboxError::UploadStageMetadata { source }
        | DropboxError::UploadStageSeek { source }
        | DropboxError::UploadStageRead { source } => {
            if disk_full(source) {
                FailurePolicy::new(Disposition::Environmental, DISK_FULL)
            } else {
                FailurePolicy::new(Disposition::Environmental, STATE)
            }
        }
    }
}

fn local_policy(error: &LocalError) -> FailurePolicy {
    match error {
        LocalError::UnsafeRelativePath { .. } | LocalError::InvalidContentIdentity { .. } => {
            FailurePolicy::new(Disposition::Invariant, INTERNAL)
        }
        LocalError::Journal { source } => journal_policy(source),
        LocalError::Io { source, .. } | LocalError::HashWorkerSpawn { source, .. } => {
            if disk_full(source) {
                FailurePolicy::new(Disposition::Environmental, DISK_FULL)
            } else {
                FailurePolicy::new(Disposition::Environmental, SYNC_ROOT)
            }
        }
        LocalError::UnsupportedObject { .. }
        | LocalError::ChangedDuringRead { .. }
        | LocalError::CorruptPrivateFile { .. }
        | LocalError::DestinationOccupied { .. }
        | LocalError::HashWorkerTerminated { .. } => {
            FailurePolicy::new(Disposition::Environmental, SYNC_ERRORS)
        }
    }
}

fn recovery_policy(error: &RecoveryError) -> FailurePolicy {
    match error {
        RecoveryError::Local { source } => local_policy(source),
        RecoveryError::Journal { source } => journal_policy(source),
        RecoveryError::Dropbox { source, .. } => dropbox_policy(source),
        RecoveryError::Clock { .. } => FailurePolicy::new(Disposition::Environmental, SYNC_ERRORS),
        RecoveryError::InvalidJournalState { .. } => {
            FailurePolicy::new(Disposition::Invariant, JOURNAL_INVALID)
        }
    }
}

fn reconcile_policy(error: &ReconcileError) -> FailurePolicy {
    match error {
        ReconcileError::Local { source } => local_policy(source),
        ReconcileError::Dropbox { source } | ReconcileError::RemoteDownload { source, .. } => {
            dropbox_policy(source)
        }
        ReconcileError::Journal { source } => journal_policy(source),
        ReconcileError::Recovery { source } => recovery_policy(source),
        ReconcileError::DownloadSlotCoordinatorUnavailable
        | ReconcileError::InvalidJournalState { .. } => {
            FailurePolicy::new(Disposition::Invariant, INTERNAL)
        }
        ReconcileError::RemoteContentChanged { .. }
        | ReconcileError::StageDestinationOccupied { .. }
        | ReconcileError::LocalCaseCollision { .. } => {
            FailurePolicy::new(Disposition::Environmental, SYNC_ERRORS)
        }
        ReconcileError::DownloadWorkerSpawn { source } => {
            if disk_full(source) {
                FailurePolicy::new(Disposition::Environmental, DISK_FULL)
            } else {
                FailurePolicy::new(Disposition::Environmental, STATE)
            }
        }
        ReconcileError::DownloadWorkerStopped
        | ReconcileError::Clock { .. }
        | ReconcileError::LocalRootChanged => {
            FailurePolicy::new(Disposition::Environmental, SYNC_ROOT)
        }
    }
}

fn retry_policy(retry_after: Option<Duration>) -> FailurePolicy {
    FailurePolicy::new(
        Disposition::Retry(retry_after.map_or(RETRY_BASE, |delay| delay.min(MAX_RETRY_AFTER))),
        DROPBOX,
    )
}

fn disk_full(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(rustix::io::Errno::NOSPC.raw_os_error())
}

fn sqlite_primary_code(error: &rusqlite::Error) -> Option<i32> {
    match error {
        rusqlite::Error::SqliteFailure(source, _) => Some(source.extended_code & 0xff),
        _ => None,
    }
}

fn sqlite_corrupt(error: &rusqlite::Error) -> bool {
    matches!(
        sqlite_primary_code(error),
        Some(rusqlite::ffi::SQLITE_CORRUPT | rusqlite::ffi::SQLITE_NOTADB)
    )
}

fn sqlite_full(error: &rusqlite::Error) -> bool {
    sqlite_primary_code(error) == Some(rusqlite::ffi::SQLITE_FULL)
}

fn transport_policy(outcome: crate::transport::Outcome) -> FailurePolicy {
    use crate::transport::Outcome;
    match outcome {
        Outcome::Retry { delay } => retry_policy(delay),
        Outcome::Environmental => FailurePolicy::new(Disposition::Environmental, CREDENTIALS),
        Outcome::UserAction => FailurePolicy::new(Disposition::UserAction, BINDING),
        Outcome::Invariant => FailurePolicy::new(Disposition::Invariant, INTERNAL),
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::error::Error;
    use std::ffi::OsString;
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};
    use std::rc::Rc;
    use std::sync::atomic::{AtomicU64, Ordering};

    use serde_json::Value;
    use tempfile::TempDir;

    use super::*;

    static SOCKET_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn binding(account: &str, namespace: &str, root: &str) -> DropboxBinding {
        DropboxBinding {
            account_id: String::from(account),
            root_namespace_id: String::from(namespace),
            remote_root: String::from(root),
        }
    }

    fn sqlite(code: i32) -> rusqlite::Error {
        rusqlite::Error::SqliteFailure(rusqlite::ffi::Error::new(code), None)
    }

    fn journal_error(code: i32) -> DaemonError {
        DaemonError::Journal {
            operation: "open the journal",
            source: JournalError::Sqlite {
                operation: "open SQLite",
                path: PathBuf::from("journal.sqlite3"),
                source: sqlite(code),
            },
        }
    }

    fn long_poll_failure(status: u16) -> DaemonError {
        DaemonError::Dropbox {
            operation: "wait for Dropbox changes",
            source: DropboxError::sdk(
                "long poll",
                dropbox_sdk::Error::<dropbox_sdk::NoError>::ServerError(format!("HTTP {status}")),
            ),
        }
    }

    struct SessionGuard(Rc<Cell<bool>>);

    impl Drop for SessionGuard {
        fn drop(&mut self) {
            self.0.set(true);
        }
    }

    fn status_value(runtime: &Path) -> Result<Value, Box<dyn Error>> {
        Ok(serde_json::from_slice(&fs::read(
            runtime.join("omabox/status.json"),
        )?)?)
    }

    fn receive_readiness(socket: &UnixDatagram) -> Result<Vec<u8>, Box<dyn Error>> {
        socket.set_read_timeout(Some(Duration::from_secs(1)))?;
        let mut buffer = [0_u8; 32];
        let length = socket.recv(&mut buffer)?;
        Ok(buffer[..length].to_vec())
    }

    #[test]
    fn readiness_is_optional_without_a_notification_socket() -> Result<(), Box<dyn Error>> {
        send_readiness(None)?;
        Ok(())
    }

    #[test]
    fn readiness_sends_exact_bytes_to_a_path_socket() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let path = directory.path().join("notify.sock");
        let receiver = UnixDatagram::bind(&path)?;
        send_readiness(Some(path.as_os_str()))?;
        assert_eq!(receive_readiness(&receiver)?, b"READY=1");
        Ok(())
    }

    #[test]
    fn readiness_sends_exact_bytes_to_an_abstract_socket() -> Result<(), Box<dyn Error>> {
        let name = format!(
            "omabox-ready-{}-{}",
            std::process::id(),
            SOCKET_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        );
        let address = SocketAddr::from_abstract_name(name.as_bytes())?;
        let receiver = UnixDatagram::bind_addr(&address)?;
        let mut target = OsString::from("@");
        target.push(&name);
        send_readiness(Some(&target))?;
        assert_eq!(receive_readiness(&receiver)?, b"READY=1");
        Ok(())
    }

    #[test]
    fn durable_binding_is_required_and_authoritative() -> Result<(), Box<dyn Error>> {
        let expected = binding("dbid:account", "namespace", "/root");
        let different = binding("dbid:other", "namespace", "/root");
        assert!(matches!(
            root_from_bindings(None, &expected),
            Err(DaemonError::SetupRequired)
        ));
        assert!(matches!(
            root_from_bindings(Some(expected.clone()), &different),
            Err(DaemonError::CredentialBindingChanged)
        ));
        assert_eq!(
            root_from_bindings(Some(expected.clone()), &expected)?,
            DropboxRoot::from_binding(&expected)?
        );
        Ok(())
    }

    #[test]
    fn recovery_control_retries_under_a_held_lock_and_clears_only_after_a_clean_pass()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let status = RuntimeStatus::new(directory.path())?;
        let lock_path = directory.path().join("daemon.lock");
        let held = InstanceLock::acquire(&lock_path)?;
        let mut recovery = RecoveryControl::new(Some(&status));
        let mut attempts = 0;
        let mut waits = Vec::new();
        let result = recovery.recover_with(
            || {
                attempts += 1;
                if attempts <= 2 {
                    Err(journal_error(rusqlite::ffi::SQLITE_BUSY))
                } else {
                    Ok("opened")
                }
            },
            &mut |delay| {
                waits.push(delay);
                assert!(matches!(
                    InstanceLock::acquire(&lock_path),
                    Err(LockError::AlreadyRunning { .. })
                ));
            },
        )?;
        assert_eq!(result, "opened");
        assert_eq!(waits, [Duration::from_secs(5), Duration::from_secs(10)]);
        let failed = status_value(directory.path())?;
        assert_eq!(failed["phase"], "error");
        assert_eq!(failed["last_error"], JOURNAL);

        status.phase(DaemonPhase::Syncing);
        assert_eq!(status_value(directory.path())?["last_error"], JOURNAL);
        recovery.clean_sync_pass();
        assert_eq!(status_value(directory.path())?["last_error"], Value::Null);
        drop(held);
        Ok(())
    }

    #[test]
    fn repeated_long_poll_retries_retain_the_session_and_escalate_after_clean_sync_passes()
    -> Result<(), Box<dyn Error>> {
        let dropped = Rc::new(Cell::new(false));
        let session = SessionGuard(Rc::clone(&dropped));
        let mut recovery = RecoveryControl::new(None);
        let mut waits = Vec::new();

        for _ in 0..2 {
            recovery.clean_sync_pass();
            let outcome = recovery
                .retain_session::<()>(Err(long_poll_failure(503)), &mut |delay| {
                    waits.push(delay)
                })?;
            assert!(outcome.is_none());
            assert!(!dropped.get());
        }

        assert_eq!(waits, [Duration::from_secs(5), Duration::from_secs(10)]);
        recovery.cycle_completed();
        assert_eq!(recovery.schedule.next, RETRY_BASE);
        drop(session);
        assert!(dropped.get());
        Ok(())
    }

    #[test]
    fn stopped_download_pool_escapes_retained_session_for_reconstruction()
    -> Result<(), Box<dyn Error>> {
        let mut recovery = RecoveryControl::new(None);
        let mut waited = false;
        let result = recovery.retain_session::<()>(
            Err(DaemonError::Reconcile {
                source: ReconcileError::DownloadWorkerStopped,
            }),
            &mut |_| waited = true,
        );
        assert!(matches!(
            result,
            Err(DaemonError::Reconcile {
                source: ReconcileError::DownloadWorkerStopped
            })
        ));
        assert!(!waited);
        Ok(())
    }

    #[test]
    fn retry_schedule_doubles_caps_and_honors_bounded_server_delays() {
        let mut schedule = RetrySchedule::new();
        assert_eq!(schedule.advance(Duration::ZERO), Duration::from_secs(5));
        assert_eq!(schedule.advance(Duration::ZERO), Duration::from_secs(10));
        for _ in 0..8 {
            let _ = schedule.advance(Duration::ZERO);
        }
        assert_eq!(schedule.advance(Duration::ZERO), RETRY_CEILING);
        assert_eq!(
            schedule.advance(Duration::from_secs(24 * 60 * 60)),
            MAX_RETRY_AFTER
        );
        schedule.reset();
        assert_eq!(schedule.advance(Duration::ZERO), RETRY_BASE);
    }

    #[test]
    fn dispositions_cover_retry_environment_user_action_and_invariant() {
        let retry = DaemonError::Dropbox {
            operation: "long poll",
            source: DropboxError::sdk(
                "long poll",
                dropbox_sdk::Error::<dropbox_sdk::NoError>::RateLimited {
                    reason: dropbox_sdk::types::auth::RateLimitReason::Other,
                    retry_after_seconds: 24 * 60 * 60,
                },
            ),
        };
        assert_eq!(retry.disposition(), Disposition::Retry(MAX_RETRY_AFTER));
        assert_eq!(
            journal_error(rusqlite::ffi::SQLITE_FULL).disposition(),
            Disposition::Environmental
        );
        assert_eq!(
            journal_error(rusqlite::ffi::SQLITE_CORRUPT).disposition(),
            Disposition::UserAction
        );
        assert_eq!(
            DaemonError::Reconcile {
                source: ReconcileError::InvalidJournalState {
                    path: PathBuf::from("item"),
                    detail: "invalid operation",
                },
            }
            .disposition(),
            Disposition::Invariant
        );
    }

    #[test]
    fn rejected_token_exits_without_rebuilding_the_download_pool() {
        let rejected = DaemonError::Auth {
            operation: "refresh Dropbox access",
            source: AuthError::Sdk {
                source: Box::new(crate::transport::TransportError::RefreshRejected(
                    crate::transport::RejectCause::InvalidAccessToken,
                )),
            },
        };
        assert!(!rejected.session_must_rebuild());
        assert_eq!(rejected.disposition(), Disposition::UserAction);
    }

    #[test]
    fn refresh_rejection_and_binding_rejection_exit_for_user_action() {
        let refresh = DaemonError::Auth {
            operation: "refresh Dropbox access",
            source: AuthError::Sdk {
                source: Box::new(crate::transport::TransportError::RefreshRejected(
                    crate::transport::RejectCause::InvalidGrant,
                )),
            },
        };
        assert_eq!(refresh.disposition(), Disposition::UserAction);
        assert_eq!(refresh.exit_code(), EXIT_USER_ACTION);
        assert_eq!(DaemonError::AccountChanged.exit_code(), EXIT_USER_ACTION);
        assert_eq!(
            DaemonError::Reconcile {
                source: ReconcileError::DownloadSlotCoordinatorUnavailable,
            }
            .exit_code(),
            EXIT_INVARIANT
        );
    }

    #[test]
    fn local_and_nested_failures_keep_their_intended_policy() {
        let disk = DaemonError::Reconcile {
            source: ReconcileError::Recovery {
                source: RecoveryError::Local {
                    source: LocalError::Io {
                        operation: "write stage",
                        path: PathBuf::from("item"),
                        source: io::Error::from_raw_os_error(
                            rustix::io::Errno::NOSPC.raw_os_error(),
                        ),
                    },
                },
            },
        };
        assert_eq!(disk.disposition(), Disposition::Environmental);
        assert_eq!(disk.public_status(), DISK_FULL);
        let invariant = DaemonError::Reconcile {
            source: ReconcileError::Local {
                source: LocalError::UnsafeRelativePath {
                    path: PathBuf::from("../escape"),
                },
            },
        };
        assert_eq!(invariant.disposition(), Disposition::Invariant);
    }
}
