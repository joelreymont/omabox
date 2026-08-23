#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use std::env;
use std::ffi::OsString;
use std::io::{self, BufRead as _, Write as _};

use miette::Diagnostic;
use omabox::auth::{AuthError, AuthorizationGrant, OAuthClient, RefreshTokenStore};
use omabox::config::{Config, ConfigError, InstanceLock, LockError};
use omabox::dropbox::{DropboxClient, DropboxError, DropboxLink};
use omabox::journal::{DropboxBindingWrite, Journal, JournalError};
use omabox::status::{self, StatusError};
use thiserror::Error;

const USAGE: &str = "Usage: omabox setup [REMOTE_ROOT]\n       omabox status";
const AUTHORIZATION_CODE_LIMIT: usize = 8192;

fn main() -> miette::Result<()> {
    match run(env::args_os().skip(1)) {
        Ok(()) => Ok(()),
        Err(error) => Err(miette::Report::new(error)),
    }
}

fn run(arguments: impl IntoIterator<Item = OsString>) -> Result<(), CliError> {
    let command = parse(arguments)?;
    match command {
        Command::Setup { remote_root } => setup(&remote_root),
        Command::Status => show_status(),
    }
}

#[derive(Debug, Eq, PartialEq)]
enum Command {
    Setup { remote_root: String },
    Status,
}

fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Command, CliError> {
    let arguments = arguments
        .into_iter()
        .map(|argument| {
            argument
                .into_string()
                .map_err(|_| CliError::Usage("arguments must be valid UTF-8"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    match arguments.as_slice() {
        [command] if command == "status" => Ok(Command::Status),
        [command] if command == "setup" => Ok(Command::Setup {
            remote_root: String::new(),
        }),
        [command, remote_root] if command == "setup" => Ok(Command::Setup {
            remote_root: remote_root.clone(),
        }),
        [] => Err(CliError::Usage("a command is required")),
        [command, ..] if command == "status" || command == "setup" => {
            Err(CliError::Usage("too many arguments"))
        }
        _ => Err(CliError::Usage("unknown command")),
    }
}

fn setup(remote_root: &str) -> Result<(), CliError> {
    let config = Config::load().map_err(|source| CliError::Config {
        operation: "load configuration",
        source: Box::new(source),
    })?;
    config.prepare().map_err(|source| CliError::Config {
        operation: "prepare state directories",
        source: Box::new(source),
    })?;
    let _lock = InstanceLock::acquire(config.paths().lock_file())
        .map_err(|source| CliError::Lock { source })?;

    let oauth = OAuthClient::new(config.dropbox_app_key());
    let pending = oauth.begin().map_err(|source| CliError::Auth {
        operation: "start Dropbox authorization",
        source,
    })?;
    write_stdout(&format!(
        "Open this URL in a browser:\n{}\n\nPaste the authorization code: ",
        pending.authorization_url()
    ))?;
    let code = read_authorization_code()?;
    let AuthorizationGrant {
        account_id,
        access_token,
        refresh_token,
        ..
    } = oauth
        .exchange(pending, &code)
        .map_err(|source| CliError::Auth {
            operation: "exchange the Dropbox authorization code",
            source,
        })?;
    drop(code);

    let client = match DropboxClient::link(access_token, account_id, remote_root) {
        Ok(DropboxLink::Linked(client)) => client,
        Ok(DropboxLink::AccountChanged) => return Err(CliError::AuthorizedAccountChanged),
        Err(source) => {
            return Err(CliError::Dropbox {
                operation: "validate the Dropbox account and root",
                source,
            });
        }
    };
    let binding = client.binding();
    let mut journal =
        Journal::open(config.paths().journal_file()).map_err(|source| CliError::Journal {
            operation: "open the journal",
            source,
        })?;
    let was_unbound = match journal
        .dropbox_binding()
        .map_err(|source| CliError::Journal {
            operation: "read the Dropbox journal binding",
            source,
        })? {
        Some(existing) if existing != binding => return Err(CliError::JournalBindingMismatch),
        Some(_) => false,
        None => true,
    };
    RefreshTokenStore::new()
        .store(&binding, &refresh_token)
        .map_err(|source| CliError::Auth {
            operation: "store the Dropbox refresh token",
            source,
        })?;
    if was_unbound {
        match journal
            .bind_dropbox_root(&binding)
            .map_err(|source| CliError::Journal {
                operation: "bind the journal to Dropbox",
                source,
            })? {
            DropboxBindingWrite::Bound | DropboxBindingWrite::AlreadyBound => {}
            DropboxBindingWrite::Mismatch { .. } => return Err(CliError::JournalBindingMismatch),
        }
    }
    write_stdout("\nOmabox setup is complete.\n")
}

fn show_status() -> Result<(), CliError> {
    let config = Config::load().map_err(|source| CliError::Config {
        operation: "load configuration",
        source: Box::new(source),
    })?;
    let output = status::render(config.paths().journal_file()).map_err(CliError::Status)?;
    write_stdout(&output)
}

fn read_authorization_code() -> Result<String, CliError> {
    let mut code = String::new();
    io::stdin()
        .lock()
        .read_line(&mut code)
        .map_err(|source| CliError::Io {
            operation: "read the authorization code",
            source,
        })?;
    let length = code.trim_end_matches(['\r', '\n']).len();
    code.truncate(length);
    if code.is_empty() || code.len() > AUTHORIZATION_CODE_LIMIT {
        return Err(CliError::InvalidAuthorizationCode);
    }
    Ok(code)
}

fn write_stdout(value: &str) -> Result<(), CliError> {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    output
        .write_all(value.as_bytes())
        .and_then(|()| output.flush())
        .map_err(|source| CliError::Io {
            operation: "write command output",
            source,
        })
}

#[derive(Debug, Diagnostic, Error)]
enum CliError {
    #[error("{0}\n\n{USAGE}")]
    #[diagnostic(code(omabox::cli::usage))]
    Usage(&'static str),

    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::cli::config),
        help("Check the Omabox configuration and retry.")
    )]
    Config {
        operation: &'static str,
        #[source]
        source: Box<ConfigError>,
    },

    #[error("could not acquire the Omabox daemon lock")]
    #[diagnostic(
        code(omabox::cli::lock),
        help("Stop the running Omabox daemon before setup, then retry.")
    )]
    Lock {
        #[source]
        source: LockError,
    },

    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::cli::journal),
        help("Ensure the Omabox state directory is writable and retry.")
    )]
    Journal {
        operation: &'static str,
        #[source]
        source: JournalError,
    },

    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::cli::oauth),
        help("Check the network connection and Dropbox app key, then retry setup.")
    )]
    Auth {
        operation: &'static str,
        #[source]
        source: AuthError,
    },

    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::cli::dropbox),
        help("Check the selected Dropbox root and account permissions, then retry setup.")
    )]
    Dropbox {
        operation: &'static str,
        #[source]
        source: DropboxError,
    },

    #[error("Dropbox authorization returned a different account")]
    #[diagnostic(
        code(omabox::cli::authorized_account_changed),
        help("Restart setup and authorize one Dropbox account for the entire flow.")
    )]
    AuthorizedAccountChanged,

    #[error("this Omabox journal is already bound to a different Dropbox account or root")]
    #[diagnostic(
        code(omabox::cli::journal_binding_mismatch),
        help("Use the Dropbox account and remote root originally selected for this sync root.")
    )]
    JournalBindingMismatch,

    #[error("the Dropbox authorization code was empty or too long")]
    #[diagnostic(
        code(omabox::cli::invalid_authorization_code),
        help("Paste the short-lived code shown by Dropbox and retry setup.")
    )]
    InvalidAuthorizationCode,

    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::cli::io),
        help("Check the terminal input and output, then retry.")
    )]
    Io {
        operation: &'static str,
        #[source]
        source: io::Error,
    },

    #[error(transparent)]
    #[diagnostic(transparent)]
    Status(#[from] StatusError),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn parser_accepts_only_documented_forms() -> Result<(), Box<dyn std::error::Error>> {
        assert_eq!(
            parse(arguments(&["setup"]))?,
            Command::Setup {
                remote_root: String::new()
            }
        );
        assert_eq!(
            parse(arguments(&["setup", "/Work"]))?,
            Command::Setup {
                remote_root: String::from("/Work")
            }
        );
        assert_eq!(parse(arguments(&["status"]))?, Command::Status);

        for rejected in [
            Vec::<OsString>::new(),
            arguments(&["unknown"]),
            arguments(&["status", "extra"]),
            arguments(&["setup", "/one", "/two"]),
        ] {
            assert!(matches!(parse(rejected), Err(CliError::Usage(_))));
        }
        Ok(())
    }
}
