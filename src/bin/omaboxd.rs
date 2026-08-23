#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use std::time::Duration;

use miette::Diagnostic;
use omabox::auth::{AuthError, CredentialLookup, OAuthClient, RefreshTokenStore, StoredCredential};
use omabox::config::{
    Config, ConfigError, InstanceLock, LockError, LoggingError, initialize_logging,
};
use omabox::dropbox::{
    AccountValidation, DropboxClient, DropboxError, DropboxRoot, LongPollWakeup,
};
use omabox::journal::{DropboxBinding, Journal, JournalError};
use omabox::reconcile::{ReconcileError, ReconcileOutcome, reconcile_once};
use thiserror::Error;

const LONG_POLL_TIMEOUT: Duration = Duration::from_secs(30);

fn main() -> miette::Result<()> {
    run().map_err(miette::Report::new)
}

fn run() -> Result<(), DaemonError> {
    initialize_logging()?;
    let config = Config::load()?;
    config.prepare()?;
    let _instance_lock = InstanceLock::acquire(config.paths().lock_file())?;
    let mut journal =
        Journal::open(config.paths().journal_file()).map_err(|source| DaemonError::Journal {
            operation: "open the journal",
            source,
        })?;

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
    match dropbox
        .validate_account(&mut journal)
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
        match reconcile_once(
            &mut journal,
            &dropbox,
            config.sync_root(),
            config.paths().upload_staging_directory(),
            config.paths().recovery_directory(),
        )
        .map_err(|source| DaemonError::Reconcile { source })?
        {
            ReconcileOutcome::Complete(report) => tracing::info!(
                replayed_operations = report.replayed_operations,
                noops = report.noops,
                planned = report.planned,
                blocked = report.blocked,
                conflicts = report.conflicts,
                "reconciliation pass completed"
            ),
            ReconcileOutcome::FreshObservationRequired { .. } => {
                tracing::info!("local state changed during reconciliation");
                continue;
            }
        }

        if let Some(delay) = long_poll_backoff.take() {
            tracing::info!(seconds = delay.as_secs(), "honoring Dropbox backoff");
            std::thread::sleep(delay);
        }
        let cursor = journal
            .remote_inventory()
            .map_err(|source| DaemonError::Journal {
                operation: "read the Dropbox cursor",
                source,
            })?
            .cursor
            .ok_or(DaemonError::MissingRemoteCursor)?;
        let wakeup = dropbox
            .long_poll(&cursor, LONG_POLL_TIMEOUT)
            .map_err(|source| DaemonError::Dropbox {
                operation: "wait for Dropbox changes",
                source,
            })?;
        long_poll_backoff = match wakeup {
            LongPollWakeup::Changes { backoff } | LongPollWakeup::TimedOut { backoff } => backoff,
            LongPollWakeup::CursorReset => None,
        };
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

#[cfg(test)]
mod tests {
    use std::error::Error;

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
}
