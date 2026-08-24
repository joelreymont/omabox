#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use std::error::Error as StdError;
use std::time::Duration;

use miette::Diagnostic;
use omabox::auth::{AuthError, CredentialLookup, OAuthClient, RefreshTokenStore, StoredCredential};
use omabox::config::{
    Config, ConfigError, InstanceLock, LockError, LoggingError, initialize_logging,
};
use omabox::dropbox::{
    AccountValidation, DropboxClient, DropboxError, DropboxRoot, LongPollWakeup,
};
use omabox::journal::{
    DropboxBinding, Journal, JournalError, LocalRootActivation, LocalRootBinding, RecordStatus,
};
use omabox::reconcile::{ReconcileError, ReconcileOutcome, reconcile_once};
use omabox::runtime_status::{DaemonPhase, RuntimeStatus};
use thiserror::Error;

const LONG_POLL_TIMEOUT: Duration = Duration::from_secs(30);

fn main() -> miette::Result<()> {
    if let Err(error) = initialize_logging() {
        return Err(miette::Report::new(DaemonError::Logging(error)));
    }
    let status = match RuntimeStatus::from_environment() {
        Ok(status) => Some(status),
        Err(error) => {
            tracing::warn!(error = %error, "runtime status is unavailable; syncing will continue");
            None
        }
    };
    match run(status.as_ref()) {
        Ok(()) => Ok(()),
        Err(error) => {
            if let Some(status) = &status {
                status.fatal_error(error.public_status());
            }
            Err(miette::Report::new(error))
        }
    }
}

fn run(status: Option<&RuntimeStatus>) -> Result<(), DaemonError> {
    let config = Config::load()?;
    config.prepare()?;
    let _instance_lock = InstanceLock::acquire(config.paths().lock_file())?;
    run_owned(&config, status)
}

fn run_owned(config: &Config, status: Option<&RuntimeStatus>) -> Result<(), DaemonError> {
    let mut journal =
        Journal::open(config.paths().journal_file()).map_err(|source| DaemonError::Journal {
            operation: "open the journal",
            source,
        })?;
    publish_current_queue(status, &journal);
    loop {
        match run_session(config, &mut journal, status) {
            Ok(()) => continue,
            Err(error) => {
                let Some(delay) = rate_limit_delay(&error) else {
                    return Err(error);
                };
                wait_for_rate_limit(delay, status);
            }
        }
    }
}

fn run_session(
    config: &Config,
    journal: &mut Journal,
    status: Option<&RuntimeStatus>,
) -> Result<(), DaemonError> {
    publish_phase(status, DaemonPhase::Starting);
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

    let refreshed = OAuthClient::new(config.dropbox_app_key())
        .refresh(&refresh_token)
        .map_err(|source| DaemonError::Auth {
            operation: "refresh Dropbox access",
            source,
        })?;
    let dropbox = DropboxClient::new(refreshed.access_token, root);
    let dropbox = match status {
        Some(status) => dropbox.with_transfer_observer(status.transfer_observer()),
        None => dropbox,
    };
    match dropbox
        .validate_account(journal)
        .map_err(|source| DaemonError::Dropbox {
            operation: "validate the Dropbox account and root",
            source,
        })? {
        AccountValidation::Valid => {}
        AccountValidation::AccountChanged => return Err(DaemonError::AccountChanged),
        AccountValidation::RootChanged => return Err(DaemonError::RootChanged),
        AccountValidation::JournalBindingChanged => {
            return Err(DaemonError::JournalBindingChanged);
        }
    }

    tracing::info!("Omabox daemon started");
    let mut long_poll_backoff: Option<Duration> = None;
    loop {
        publish_phase(status, DaemonPhase::Syncing);
        activate_configured_root(config, journal)?;
        let outcome = match reconcile_once(
            journal,
            &dropbox,
            config.sync_root(),
            config.paths().upload_staging_directory(),
            config.paths().recovery_directory(),
        )
        .map_err(|source| DaemonError::Reconcile { source })
        {
            Ok(outcome) => outcome,
            Err(error) => {
                let Some(delay) = rate_limit_delay(&error) else {
                    return Err(error);
                };
                wait_for_rate_limit(delay, status);
                continue;
            }
        };
        match outcome {
            ReconcileOutcome::Complete(report) => {
                tracing::info!(
                    replayed_operations = report.replayed_operations,
                    noops = report.noops,
                    planned = report.planned,
                    blocked = report.blocked,
                    conflicts = report.conflicts,
                    "reconciliation pass completed"
                );
                publish_success(status, journal);
            }
            ReconcileOutcome::FreshObservationRequired { .. } => {
                tracing::info!("local state changed during reconciliation");
                continue;
            }
            ReconcileOutcome::LocalRootChanged => {
                tracing::info!("configured local root changed during reconciliation");
                continue;
            }
        }

        if let Some(delay) = long_poll_backoff.take() {
            tracing::info!(seconds = delay.as_secs(), "honoring Dropbox backoff");
            wait_with_heartbeat(delay, status, DaemonPhase::Backoff);
        }
        let cursor = journal
            .remote_inventory()
            .map_err(|source| DaemonError::Journal {
                operation: "read the Dropbox cursor",
                source,
            })?
            .cursor
            .ok_or(DaemonError::MissingRemoteCursor)?;
        let wakeup = match dropbox
            .long_poll(&cursor, LONG_POLL_TIMEOUT)
            .map_err(|source| DaemonError::Dropbox {
                operation: "wait for Dropbox changes",
                source,
            }) {
            Ok(wakeup) => wakeup,
            Err(error) => {
                let Some(delay) = rate_limit_delay(&error) else {
                    return Err(error);
                };
                wait_for_rate_limit(delay, status);
                continue;
            }
        };
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
        LocalRootActivation::Busy => Err(DaemonError::LocalRootBusy),
    }
}

fn wait_for_rate_limit(delay: Duration, status: Option<&RuntimeStatus>) {
    tracing::warn!(
        seconds = delay.as_secs(),
        "Dropbox rate limited the daemon; retrying after its requested delay"
    );
    wait_with_heartbeat(delay, status, DaemonPhase::Backoff);
}

fn wait_with_heartbeat(delay: Duration, status: Option<&RuntimeStatus>, phase: DaemonPhase) {
    publish_phase(status, phase);
    let mut remaining = delay;
    while !remaining.is_zero() {
        let interval = remaining.min(LONG_POLL_TIMEOUT);
        std::thread::sleep(interval);
        remaining = remaining.saturating_sub(interval);
        publish_phase(status, phase);
    }
}

fn publish_phase(status: Option<&RuntimeStatus>, phase: DaemonPhase) {
    if let Some(status) = status {
        status.phase(phase);
    }
}

fn publish_current_queue(status: Option<&RuntimeStatus>, journal: &Journal) {
    let Some(status) = status else {
        return;
    };
    match current_status_queue(journal) {
        Ok(queued) => status.queued(queued),
        Err(source) => {
            tracing::warn!(
                error = %source,
                "could not read journal queue for runtime status"
            );
        }
    }
}

fn publish_success(status: Option<&RuntimeStatus>, journal: &Journal) {
    let Some(status) = status else {
        return;
    };
    let queued = match current_status_queue(journal) {
        Ok(queued) => Some(queued),
        Err(source) => {
            tracing::warn!(
                error = %source,
                "could not read journal queue for runtime status"
            );
            None
        }
    };
    status.successful_pass(queued);
}

fn current_status_queue(journal: &Journal) -> Result<u64, JournalError> {
    let queued = journal
        .pending_plans()?
        .iter()
        .flat_map(|plan| &plan.operations)
        .filter(|operation| operation.status == RecordStatus::Pending)
        .fold(0_u64, |count, _| count.saturating_add(1));
    Ok(queued)
}

fn rate_limit_delay(error: &DaemonError) -> Option<Duration> {
    let mut source: &(dyn StdError + 'static) = error;
    loop {
        if let Some(AuthError::RateLimited { retry_after, .. }) = source.downcast_ref::<AuthError>()
        {
            return *retry_after;
        }
        if let Some(DropboxError::RateLimited { retry_after, .. }) =
            source.downcast_ref::<DropboxError>()
        {
            return *retry_after;
        }
        source = source.source()?;
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

#[derive(Debug, Diagnostic, Error)]
enum DaemonError {
    #[error(transparent)]
    #[diagnostic(transparent)]
    Logging(#[from] LoggingError),

    #[error(transparent)]
    #[diagnostic(transparent)]
    Config(#[from] ConfigError),

    #[error(transparent)]
    #[diagnostic(transparent)]
    Lock(#[from] LockError),

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

    #[error("the configured sync root changed while prior sync work is unfinished")]
    #[diagnostic(
        code(omabox::daemon::local_root_busy),
        help(
            "Restore the previous sync root in settings and let Omabox finish before selecting the new directory."
        )
    )]
    LocalRootBusy,

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
    fn public_status(&self) -> &'static str {
        match self {
            Self::Logging(_) => "Logging could not start.",
            Self::Config(_) => "Omabox configuration is unavailable.",
            Self::Lock(_) => "The Omabox service could not acquire its instance lock.",
            Self::Journal { .. } => "The sync journal is unavailable.",
            Self::LocalRootBusy => "The sync folder changed while earlier work is unfinished.",
            Self::Auth { .. } | Self::CredentialsUnavailable { .. } => {
                "Dropbox authentication is unavailable."
            }
            Self::SetupRequired => "Omabox setup is incomplete.",
            Self::CredentialBindingChanged
            | Self::AccountChanged
            | Self::RootChanged
            | Self::JournalBindingChanged => {
                "The Dropbox account or sync root no longer matches setup."
            }
            Self::Dropbox { .. } => "Dropbox is unavailable.",
            Self::Reconcile { .. } => "A synchronization pass failed.",
            Self::MissingRemoteCursor => "The Dropbox inventory cursor is unavailable.",
        }
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::path::PathBuf;

    use omabox::recovery::RecoveryError;

    use super::*;

    fn binding(account: &str, namespace: &str, root: &str) -> DropboxBinding {
        DropboxBinding {
            account_id: String::from(account),
            root_namespace_id: String::from(namespace),
            remote_root: String::from(root),
        }
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
        let root = root_from_bindings(Some(expected.clone()), &expected)?;
        assert_eq!(root, DropboxRoot::from_binding(&expected)?);
        Ok(())
    }

    #[test]
    fn supplied_rate_limit_delays_cross_typed_error_boundaries() {
        let auth_delay = Duration::from_secs(11);
        let auth = DaemonError::Auth {
            operation: "refresh Dropbox access",
            source: AuthError::RateLimited {
                operation: "refresh access token",
                retry_after: Some(auth_delay),
            },
        };
        assert_eq!(rate_limit_delay(&auth), Some(auth_delay));

        let dropbox_delay = Duration::from_secs(13);
        let dropbox = DaemonError::Dropbox {
            operation: "wait for Dropbox changes",
            source: DropboxError::RateLimited {
                operation: "long poll",
                retry_after: Some(dropbox_delay),
            },
        };
        assert_eq!(rate_limit_delay(&dropbox), Some(dropbox_delay));

        let reconcile_delay = Duration::from_secs(17);
        let reconcile = DaemonError::Reconcile {
            source: ReconcileError::Dropbox {
                source: DropboxError::RateLimited {
                    operation: "list folder",
                    retry_after: Some(reconcile_delay),
                },
            },
        };
        assert_eq!(rate_limit_delay(&reconcile), Some(reconcile_delay));

        let recovery_delay = Duration::from_secs(19);
        let recovery = DaemonError::Reconcile {
            source: ReconcileError::Recovery {
                source: RecoveryError::Dropbox {
                    path: PathBuf::from("notes.txt"),
                    source: DropboxError::RateLimited {
                        operation: "replace file",
                        retry_after: Some(recovery_delay),
                    },
                },
            },
        };
        assert_eq!(rate_limit_delay(&recovery), Some(recovery_delay));
    }

    #[test]
    fn missing_delays_and_other_errors_remain_fatal() {
        let missing_delay = DaemonError::Auth {
            operation: "refresh Dropbox access",
            source: AuthError::RateLimited {
                operation: "refresh access token",
                retry_after: None,
            },
        };
        assert_eq!(rate_limit_delay(&missing_delay), None);

        let ordinary_dropbox = DaemonError::Dropbox {
            operation: "wait for Dropbox changes",
            source: DropboxError::HttpStatus {
                operation: "long poll",
                status: 503,
            },
        };
        assert_eq!(rate_limit_delay(&ordinary_dropbox), None);
        assert_eq!(rate_limit_delay(&DaemonError::SetupRequired), None);
    }
}
