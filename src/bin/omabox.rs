#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use std::env;
use std::ffi::{OsStr, OsString};
use std::io::{self, BufRead as _, Write as _};
use std::path::{Path, PathBuf};

use miette::Diagnostic;
use omabox::auth::{AuthError, AuthorizationGrant, OAuthClient, RefreshTokenStore};
use omabox::config::{Config, ConfigError, InstanceLock, LockError, XdgDirectories};
use omabox::dropbox::{DropboxClient, DropboxError, DropboxLink};
use omabox::install::{InstallAction, InstallError};
use omabox::journal::{DropboxBindingWrite, Journal, JournalError, LocalRootBinding};
use omabox::service::{ServiceAction, ServiceCommands, ServiceError};
use omabox::status::{self, StatusError};
use serde::Serialize;
use thiserror::Error;

const HELP: &str = "Omabox synchronizes a local directory with Dropbox.\n\n\
Usage:\n  omabox setup [REMOTE_ROOT]\n  omabox setup --sync-root PATH --app-key KEY [--remote-root ROOT]\n  omabox status\n  omabox pause|resume\n  omabox settings [--json]\n  omabox settings set-root PATH\n  omabox install|upgrade|uninstall\n  omabox service start|stop|restart|enable|disable|status\n  omabox logs\n  omabox --help\n  omabox --version\n\n\
The Dropbox app key is public. Omabox never requests or stores an app secret.\n";
const USAGE: &str = "Run `omabox --help` for usage.";
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
        Command::Help => write_stdout(HELP),
        Command::Version => write_stdout(concat!("omabox ", env!("CARGO_PKG_VERSION"), "\n")),
        Command::Setup(options) => setup(options),
        Command::Status => show_status(),
        Command::Settings { json } => show_settings(json),
        Command::SetRoot(path) => set_sync_root_from_environment(&path),
        Command::Install(action) => {
            let report = omabox::install::execute(action).map_err(CliError::Install)?;
            write_stdout(&report)
        }
        Command::Service(action) => ServiceCommands::default()
            .control(action)
            .map_err(CliError::Service),
        Command::Logs => ServiceCommands::default().logs().map_err(CliError::Service),
    }
}

#[derive(Debug, Eq, PartialEq)]
enum Command {
    Help,
    Version,
    Setup(SetupOptions),
    Status,
    Settings { json: bool },
    SetRoot(PathBuf),
    Install(InstallAction),
    Service(ServiceAction),
    Logs,
}

#[derive(Debug, Eq, PartialEq)]
struct SetupOptions {
    remote_root: String,
    initial_config: Option<InitialConfig>,
}

#[derive(Debug, Eq, PartialEq)]
struct InitialConfig {
    sync_root: PathBuf,
    app_key: String,
}

fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Command, CliError> {
    let arguments = arguments.into_iter().collect::<Vec<_>>();
    let Some((command, rest)) = arguments.split_first() else {
        return Err(CliError::Usage("a command is required"));
    };
    match command.to_str() {
        Some("--help" | "-h" | "help") if rest.is_empty() => Ok(Command::Help),
        Some("--version" | "-V") if rest.is_empty() => Ok(Command::Version),
        Some("setup") => parse_setup(rest).map(Command::Setup),
        Some("status") if rest.is_empty() => Ok(Command::Status),
        Some("pause") if rest.is_empty() => Ok(Command::Service(ServiceAction::Stop)),
        Some("resume") if rest.is_empty() => Ok(Command::Service(ServiceAction::Start)),
        Some("settings") => parse_settings(rest),
        Some("install") if rest.is_empty() => Ok(Command::Install(InstallAction::Install)),
        Some("upgrade") if rest.is_empty() => Ok(Command::Install(InstallAction::Upgrade)),
        Some("uninstall") if rest.is_empty() => Ok(Command::Install(InstallAction::Uninstall)),
        Some("service") => parse_service(rest),
        Some("logs") if rest.is_empty() => Ok(Command::Logs),
        Some(
            "status" | "pause" | "resume" | "logs" | "install" | "upgrade" | "uninstall" | "--help"
            | "-h" | "help" | "--version" | "-V",
        ) => Err(CliError::Usage("too many arguments")),
        Some(_) => Err(CliError::Usage("unknown command")),
        None => Err(CliError::Usage("the command must be valid UTF-8")),
    }
}

fn parse_setup(arguments: &[OsString]) -> Result<SetupOptions, CliError> {
    match arguments {
        [] => {
            return Ok(SetupOptions {
                remote_root: String::new(),
                initial_config: None,
            });
        }
        [remote_root] if !is_option(remote_root) => {
            return Ok(SetupOptions {
                remote_root: utf8(remote_root, "the Dropbox root must be valid UTF-8")?,
                initial_config: None,
            });
        }
        _ => {}
    }

    let mut sync_root = None;
    let mut app_key = None;
    let mut remote_root = String::new();
    let mut remote_root_set = false;
    let mut index = 0;
    while index < arguments.len() {
        let option = arguments[index]
            .to_str()
            .ok_or(CliError::Usage("setup options must be valid UTF-8"))?;
        // Take the value only after the option is known and not repeated, so
        // a trailing unknown or repeated option is reported as such.
        let value = || {
            arguments
                .get(index + 1)
                .ok_or(CliError::Usage("a setup option is missing its value"))
        };
        match option {
            "--sync-root" if sync_root.is_none() => sync_root = Some(PathBuf::from(value()?)),
            "--app-key" if app_key.is_none() => {
                app_key = Some(utf8(value()?, "the Dropbox app key must be valid UTF-8")?)
            }
            "--remote-root" if !remote_root_set => {
                remote_root = utf8(value()?, "the Dropbox root must be valid UTF-8")?;
                remote_root_set = true;
            }
            "--sync-root" | "--app-key" | "--remote-root" => {
                return Err(CliError::Usage(
                    "a setup option was provided more than once",
                ));
            }
            _ => return Err(CliError::Usage("unknown setup option")),
        }
        index += 2;
    }
    let (Some(sync_root), Some(app_key)) = (sync_root, app_key) else {
        return Err(CliError::Usage(
            "flag-driven setup requires --sync-root and --app-key",
        ));
    };
    Ok(SetupOptions {
        remote_root,
        initial_config: Some(InitialConfig { sync_root, app_key }),
    })
}

fn parse_settings(arguments: &[OsString]) -> Result<Command, CliError> {
    match arguments {
        [] => Ok(Command::Settings { json: false }),
        [option] if option == "--json" => Ok(Command::Settings { json: true }),
        [command, path] if command == "set-root" => Ok(Command::SetRoot(PathBuf::from(path))),
        _ => Err(CliError::Usage("invalid settings command")),
    }
}

fn parse_service(arguments: &[OsString]) -> Result<Command, CliError> {
    let [action] = arguments else {
        return Err(CliError::Usage("service requires exactly one action"));
    };
    let action = match action.to_str() {
        Some("start") => ServiceAction::Start,
        Some("stop") => ServiceAction::Stop,
        Some("restart") => ServiceAction::Restart,
        Some("enable") => ServiceAction::Enable,
        Some("disable") => ServiceAction::Disable,
        Some("status") => ServiceAction::Status,
        _ => return Err(CliError::Usage("unknown service action")),
    };
    Ok(Command::Service(action))
}

fn is_option(argument: &OsStr) -> bool {
    argument.as_encoded_bytes().starts_with(b"--")
}

fn utf8(argument: &OsStr, message: &'static str) -> Result<String, CliError> {
    argument
        .to_str()
        .map(String::from)
        .ok_or(CliError::Usage(message))
}

fn setup(options: SetupOptions) -> Result<(), CliError> {
    let (config, write_initial_config) = match options.initial_config {
        Some(initial) => {
            let xdg =
                XdgDirectories::from_environment().map_err(config_error("resolve XDG paths"))?;
            let initial_config = Config::from_values(&xdg, initial.sync_root, initial.app_key)
                .map_err(config_error("validate initial configuration"))?;
            (initial_config, true)
        }
        None => (
            Config::load().map_err(config_error("load configuration"))?,
            false,
        ),
    };
    config
        .prepare()
        .map_err(config_error("prepare state directories"))?;
    let _lock = InstanceLock::acquire(config.paths().lock_file())
        .map_err(|source| CliError::Lock { source })?;
    if write_initial_config
        && config
            .paths()
            .config_file()
            .try_exists()
            .map_err(|source| CliError::InspectConfig { source })?
    {
        return Err(CliError::InitialConfigExists);
    }

    complete_setup(&config, write_initial_config, || {
        authorize_and_bind(&config, &options.remote_root)
    })?;
    write_stdout("\nOmabox setup is complete.\n")
}

fn authorize_and_bind(config: &Config, remote_root: &str) -> Result<(), CliError> {
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

    let client = match DropboxClient::link_authorized(access_token, remote_root) {
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
    Ok(())
}

fn complete_setup<Operation>(
    config: &Config,
    write_initial_config: bool,
    operation: Operation,
) -> Result<(), CliError>
where
    Operation: FnOnce() -> Result<(), CliError>,
{
    operation()?;
    if write_initial_config {
        match config.write_new() {
            Ok(()) => {}
            Err(ConfigError::AlreadyExists { .. }) => return Err(CliError::InitialConfigExists),
            Err(source) => return Err(config_error("write initial configuration")(source)),
        }
    }
    Ok(())
}

fn show_status() -> Result<(), CliError> {
    let config = Config::load().map_err(config_error("load configuration"))?;
    let output = status::render(config.paths().journal_file()).map_err(CliError::Status)?;
    write_stdout(&output)
}

#[derive(Serialize)]
struct SettingsDocument<'config> {
    sync_root: &'config Path,
    dropbox_app_key: &'config str,
}

fn show_settings(json: bool) -> Result<(), CliError> {
    let config = Config::load().map_err(config_error("load configuration"))?;
    let output = if json {
        let mut serialized = serde_json::to_string_pretty(&SettingsDocument {
            sync_root: config.sync_root(),
            dropbox_app_key: config.dropbox_app_key(),
        })
        .map_err(CliError::SerializeOutput)?;
        serialized.push('\n');
        serialized
    } else {
        format!(
            "Sync root: {}\nDropbox app key: {}\n",
            config.sync_root().display(),
            config.dropbox_app_key()
        )
    };
    write_stdout(&output)
}

fn set_sync_root_from_environment(path: &Path) -> Result<(), CliError> {
    let xdg = XdgDirectories::from_environment().map_err(config_error("resolve XDG paths"))?;
    set_sync_root(path, &xdg, &ServiceCommands::default())
}

fn set_sync_root(
    path: &Path,
    xdg: &XdgDirectories,
    services: &ServiceCommands,
) -> Result<(), CliError> {
    let current = Config::load_for_root_change_from(xdg)
        .map_err(config_error("load configuration for sync-root change"))?;
    let replacement = Config::from_values(xdg, path, current.dropbox_app_key())
        .map_err(config_error("validate the new sync root"))?;

    let was_active = services.is_active().map_err(CliError::Service)?;
    if was_active {
        services
            .control(ServiceAction::Stop)
            .map_err(CliError::Service)?;
    }
    let change = change_sync_root_while_stopped(&current, &replacement);
    if was_active && let Err(restore) = services.control(ServiceAction::Start) {
        return match change {
            Ok(()) => Err(CliError::Service(restore)),
            Err(source) => Err(CliError::RootChangeAndRestore {
                source: Box::new(source),
                restore,
            }),
        };
    }
    change?;
    write_stdout(&format!(
        "Omabox sync root is now {}.\n",
        replacement.sync_root().display()
    ))
}

fn change_sync_root_while_stopped(current: &Config, replacement: &Config) -> Result<(), CliError> {
    let _lock = InstanceLock::acquire(current.paths().lock_file())
        .map_err(|source| CliError::Lock { source })?;
    let binding =
        LocalRootBinding::inspect(replacement.sync_root()).map_err(|source| CliError::Journal {
            operation: "inspect the selected sync root",
            source,
        })?;
    let journal_path = current.paths().journal_file();
    let mut journal = if journal_path
        .try_exists()
        .map_err(|source| CliError::InspectJournal { source })?
    {
        Some(
            Journal::open(journal_path).map_err(|source| CliError::Journal {
                operation: "open the sync journal before changing the sync root",
                source,
            })?,
        )
    } else {
        None
    };
    replacement
        .write()
        .map_err(config_error("write the new sync root"))?;
    if let Some(journal) = &mut journal {
        let _ = journal
            .adopt_local_root(&binding)
            .map_err(|source| CliError::Journal {
                operation: "adopt the selected sync root",
                source,
            })?;
    }
    Ok(())
}

fn config_error(operation: &'static str) -> impl FnOnce(ConfigError) -> CliError {
    move |source| CliError::Config {
        operation,
        source: Box::new(source),
    }
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

    #[error("could not inspect the Omabox configuration path")]
    #[diagnostic(
        code(omabox::cli::inspect_config),
        help("Ensure the XDG configuration location is accessible and retry.")
    )]
    InspectConfig {
        #[source]
        source: io::Error,
    },

    #[error("Omabox configuration already exists")]
    #[diagnostic(
        code(omabox::cli::initial_config_exists),
        help("Use `omabox settings` or `omabox settings set-root PATH` to change configuration.")
    )]
    InitialConfigExists,

    #[error("could not acquire the Omabox daemon lock")]
    #[diagnostic(
        code(omabox::cli::lock),
        help("Stop any manually started Omabox daemon, then retry.")
    )]
    Lock {
        #[source]
        source: LockError,
    },

    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::cli::journal),
        help("Ensure the Omabox state directory is accessible and retry.")
    )]
    Journal {
        operation: &'static str,
        #[source]
        source: JournalError,
    },

    #[error("could not inspect the Omabox journal before changing the sync root")]
    #[diagnostic(
        code(omabox::cli::inspect_journal),
        help("Ensure the Omabox state directory is accessible and retry.")
    )]
    InspectJournal {
        #[source]
        source: io::Error,
    },

    #[error("the sync-root change failed and the Omabox service could not be restarted: {restore}")]
    #[diagnostic(
        code(omabox::cli::root_change_and_restore),
        help("Start the service with `omabox service start`, then address the original error.")
    )]
    RootChangeAndRestore {
        #[source]
        source: Box<CliError>,
        restore: ServiceError,
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

    #[error("could not serialize settings output")]
    #[diagnostic(
        code(omabox::cli::serialize_output),
        help("Use `omabox settings` for human-readable output.")
    )]
    SerializeOutput(#[source] serde_json::Error),

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
    Service(#[from] ServiceError),

    #[error(transparent)]
    #[diagnostic(transparent)]
    Status(#[from] StatusError),

    #[error(transparent)]
    #[diagnostic(transparent)]
    Install(#[from] InstallError),
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;

    use omabox::journal::{
        BlockReason, LocalRootActivation, LocalRootBinding, PlanBlock, PlanWrite,
    };
    use omabox::model::{
        Baseline, CanonicalPath, ContentIdentity, Decision, LocalFile, Observation, RemoteSubtree,
    };

    use super::*;

    fn arguments(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    /// Write a `systemctl` stand-in without the executable bit.
    ///
    /// `ServiceCommands::scripts` reads it through `/bin/sh`, so writing one
    /// can never collide with a concurrent spawn in the test binary.
    fn fake_systemctl(
        directory: &Path,
        active: bool,
        log: &Path,
    ) -> Result<PathBuf, Box<dyn Error>> {
        let path = directory.join("systemctl");
        let active_status = if active { 0 } else { 3 };
        fs::write(
            &path,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\nif [ \"$2\" = is-active ]; then exit {active_status}; fi\nexit 0\n",
                log.display()
            ),
        )?;
        Ok(path)
    }

    fn fixture() -> Result<(tempfile::TempDir, XdgDirectories, PathBuf, PathBuf), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let first = temporary.path().join("first");
        let second = temporary.path().join("second");
        fs::create_dir(&first)?;
        fs::create_dir(&second)?;
        let xdg = XdgDirectories::new(
            temporary.path().join("config"),
            temporary.path().join("state"),
        )?;
        let config = Config::from_values(&xdg, &first, "public-app-key")?;
        config.prepare()?;
        config.write()?;
        Ok((temporary, xdg, first, second))
    }

    #[test]
    fn parser_accepts_documented_forms() -> Result<(), Box<dyn Error>> {
        assert_eq!(parse(arguments(&["--help"]))?, Command::Help);
        assert_eq!(parse(arguments(&["--version"]))?, Command::Version);
        assert_eq!(
            parse(arguments(&["pause"]))?,
            Command::Service(ServiceAction::Stop)
        );
        assert_eq!(
            parse(arguments(&["resume"]))?,
            Command::Service(ServiceAction::Start)
        );
        assert_eq!(
            parse(arguments(&["setup"]))?,
            Command::Setup(SetupOptions {
                remote_root: String::new(),
                initial_config: None,
            })
        );
        assert_eq!(
            parse(arguments(&["setup", "/Work"]))?,
            Command::Setup(SetupOptions {
                remote_root: String::from("/Work"),
                initial_config: None,
            })
        );
        assert_eq!(
            parse(arguments(&[
                "setup",
                "--remote-root",
                "/Work",
                "--app-key",
                "key",
                "--sync-root",
                "/tmp/Dropbox",
            ]))?,
            Command::Setup(SetupOptions {
                remote_root: String::from("/Work"),
                initial_config: Some(InitialConfig {
                    sync_root: PathBuf::from("/tmp/Dropbox"),
                    app_key: String::from("key"),
                }),
            })
        );
        assert_eq!(
            parse(arguments(&["settings", "--json"]))?,
            Command::Settings { json: true }
        );
        assert_eq!(
            parse(arguments(&["settings", "set-root", "/tmp/new"]))?,
            Command::SetRoot(PathBuf::from("/tmp/new"))
        );
        assert_eq!(
            parse(arguments(&["service", "restart"]))?,
            Command::Service(ServiceAction::Restart)
        );
        assert_eq!(parse(arguments(&["logs"]))?, Command::Logs);
        assert_eq!(
            parse(arguments(&["install"]))?,
            Command::Install(InstallAction::Install)
        );
        assert_eq!(
            parse(arguments(&["upgrade"]))?,
            Command::Install(InstallAction::Upgrade)
        );
        assert_eq!(
            parse(arguments(&["uninstall"]))?,
            Command::Install(InstallAction::Uninstall)
        );
        Ok(())
    }

    #[test]
    fn parser_rejects_incomplete_or_secret_bearing_forms() {
        for rejected in [
            Vec::<OsString>::new(),
            arguments(&["unknown"]),
            arguments(&["status", "extra"]),
            arguments(&["pause", "extra"]),
            arguments(&["resume", "extra"]),
            arguments(&["install", "extra"]),
            arguments(&["setup", "--sync-root", "/tmp/Dropbox"]),
            arguments(&[
                "setup",
                "--sync-root",
                "/tmp/Dropbox",
                "--app-key",
                "key",
                "--app-secret",
                "secret",
            ]),
            arguments(&["settings", "set-root"]),
            arguments(&["service", "unknown"]),
        ] {
            assert!(matches!(parse(rejected), Err(CliError::Usage(_))));
        }
    }

    #[test]
    fn parser_names_the_setup_option_fault() {
        for (rejected, message) in [
            (arguments(&["setup", "--help"]), "unknown setup option"),
            (
                arguments(&["setup", "--sync-root", "/tmp/Dropbox", "--bogus"]),
                "unknown setup option",
            ),
            (
                arguments(&["setup", "--app-key"]),
                "a setup option is missing its value",
            ),
            (
                arguments(&["setup", "--app-key", "key", "--app-key"]),
                "a setup option was provided more than once",
            ),
        ] {
            assert!(
                matches!(parse(rejected.clone()), Err(CliError::Usage(found)) if found == message),
                "{rejected:?} must be rejected with {message:?}"
            );
        }
    }

    #[test]
    fn failed_initial_setup_leaves_no_config_and_same_command_can_retry()
    -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let sync_root = temporary.path().join("Dropbox");
        fs::create_dir(&sync_root)?;
        let xdg = XdgDirectories::new(
            temporary.path().join("config"),
            temporary.path().join("state"),
        )?;
        let command = || {
            parse(vec![
                OsString::from("setup"),
                OsString::from("--sync-root"),
                sync_root.as_os_str().to_os_string(),
                OsString::from("--app-key"),
                OsString::from("public-app-key"),
            ])
        };

        for should_succeed in [false, true] {
            let Command::Setup(options) = command()? else {
                return Err("documented setup form parsed as another command".into());
            };
            let Some(initial) = options.initial_config else {
                return Err("documented flag setup did not contain initial config".into());
            };
            let config = Config::from_values(&xdg, initial.sync_root, initial.app_key)?;
            config.prepare()?;
            let _lock = InstanceLock::acquire(config.paths().lock_file())?;
            let result = complete_setup(&config, true, || {
                if should_succeed {
                    Ok(())
                } else {
                    Err(CliError::InvalidAuthorizationCode)
                }
            });
            if should_succeed {
                result?;
            } else {
                assert!(matches!(result, Err(CliError::InvalidAuthorizationCode)));
                assert!(!xdg.config_file().exists());
            }
        }

        assert_eq!(Config::load_from(&xdg)?.dropbox_app_key(), "public-app-key");
        Ok(())
    }

    #[test]
    fn set_root_retires_live_intent_and_preserves_payloads() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, first, second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let mut journal = Journal::open(config.paths().journal_file())?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&first)?)?;
        let Decision::Operations(plan) = omabox::planner::plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(ContentIdentity::new("pending-content"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ) else {
            return Err("planner did not produce the pending operation".into());
        };
        assert!(matches!(
            journal.record_plan(Path::new("pending.txt"), &plan)?,
            PlanWrite::Recorded(_)
        ));
        let Decision::Operations(blocked_plan) = omabox::planner::plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(ContentIdentity::new("blocked-content"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ) else {
            return Err("planner did not produce the blocked operation".into());
        };
        let PlanWrite::Recorded(blocked) =
            journal.record_plan(Path::new("blocked.txt"), &blocked_plan)?
        else {
            return Err("journal did not record the blocked operation".into());
        };
        assert_eq!(
            journal.block_plan(blocked.id, &BlockReason::StageOccupied, 1_700_000_000)?,
            PlanBlock::Blocked
        );
        drop(journal);
        let staged_payload = config.paths().upload_staging_directory().join("payload");
        let recovery_payload = config.paths().recovery_directory().join("payload");
        fs::write(&staged_payload, b"staged")?;
        fs::write(&recovery_payload, b"recovery")?;

        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), true, &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        set_sync_root(&second, &xdg, &services)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), second);
        assert_eq!(fs::read_to_string(service_log)?, "is-active\nstop\nstart\n");
        let journal = Journal::open(config.paths().journal_file())?;
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.blocked_plans()?.is_empty());
        assert_eq!(fs::read(staged_payload)?, b"staged");
        assert_eq!(fs::read(recovery_payload)?, b"recovery");
        Ok(())
    }

    #[test]
    fn set_root_requires_the_daemon_lock_before_writing_config() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let original_config = fs::read(config.paths().config_file())?;
        let _held_lock = InstanceLock::acquire(config.paths().lock_file())?;
        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), false, &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");

        assert!(matches!(
            set_sync_root(&second, &xdg, &services),
            Err(CliError::Lock { .. })
        ));
        assert_eq!(fs::read(config.paths().config_file())?, original_config);
        assert_eq!(fs::read_to_string(service_log)?, "is-active\n");
        Ok(())
    }

    #[test]
    fn config_write_failure_preserves_root_generation_and_live_intent() -> Result<(), Box<dyn Error>>
    {
        let (temporary, xdg, first, second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let mut journal = Journal::open(config.paths().journal_file())?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&first)?)?;
        let Decision::Operations(plan) = omabox::planner::plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(ContentIdentity::new("pending-content"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ) else {
            return Err("planner did not produce the pending operation".into());
        };
        let _ = journal.record_plan(Path::new("pending.txt"), &plan)?;
        let binding_before = journal.local_root_binding()?;
        let pending_before = journal.pending_plans()?;
        drop(journal);

        let config_directory = config.paths().config_directory();
        let saved_config_directory = temporary.path().join("saved-config");
        let service_log = temporary.path().join("service.log");
        let systemctl = temporary.path().join("systemctl-write-failure");
        fs::write(
            &systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\n\
                 if [ \"$2\" = is-active ]; then exit 0; fi\n\
                 if [ \"$2\" = stop ]; then mv '{}' '{}'; : > '{}'; fi\n\
                 exit 0\n",
                service_log.display(),
                config_directory.display(),
                saved_config_directory.display(),
                config_directory.display(),
            ),
        )?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        assert!(matches!(
            set_sync_root(&second, &xdg, &services),
            Err(CliError::Config { .. })
        ));
        assert_eq!(
            fs::read_to_string(&service_log)?,
            "is-active\nstop\nstart\n"
        );

        fs::remove_file(config_directory)?;
        fs::rename(saved_config_directory, config_directory)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), first);
        let journal = Journal::open(config.paths().journal_file())?;
        assert_eq!(journal.local_root_binding()?, binding_before);
        assert_eq!(journal.pending_plans()?, pending_before);
        Ok(())
    }

    #[test]
    fn set_root_works_when_the_prior_root_is_unavailable() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, first, second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let mut journal = Journal::open(config.paths().journal_file())?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&first)?)?;
        let remote = omabox::model::RemoteFile::new(
            ContentIdentity::new("remote-content"),
            omabox::model::DropboxRevision::new("remote-revision"),
        );
        journal.publish_remote_inventory(
            "remote-cursor",
            &[omabox::journal::RemoteObservationRecord {
                canonical_path: CanonicalPath::from_display(Path::new("remote.txt")),
                path: PathBuf::from("remote.txt"),
                observation: Observation::Present(remote.clone()),
            }],
        )?;
        let Decision::NoOp(agreement) = omabox::planner::plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(remote.content.clone())),
            &Observation::Present(remote),
            RemoteSubtree::Empty,
        ) else {
            return Err("planner did not produce the initial agreement".into());
        };
        let _ = journal.record_noop(Path::new("remote.txt"), &agreement)?;
        assert_eq!(journal.baseline_paths()?, vec![PathBuf::from("remote.txt")]);
        drop(journal);
        fs::rename(&first, temporary.path().join("unavailable-first"))?;

        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), false, &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        set_sync_root(&second, &xdg, &services)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), second);
        assert_eq!(fs::read_to_string(service_log)?, "is-active\n");

        let mut journal = Journal::open(config.paths().journal_file())?;
        assert!(journal.baseline_paths()?.is_empty());
        assert_eq!(
            journal.remote_inventory()?.cursor,
            Some(String::from("remote-cursor"))
        );
        Ok(())
    }

    #[test]
    fn set_root_explicitly_adopts_a_replacement_at_the_same_path() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, first, _second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let recorded = LocalRootBinding::inspect(&first)?;
        let mut journal = Journal::open(config.paths().journal_file())?;
        let _ = journal.activate_local_root(&recorded)?;
        let remote = omabox::model::RemoteFile::new(
            ContentIdentity::new("same-content"),
            omabox::model::DropboxRevision::new("same-revision"),
        );
        let Decision::NoOp(agreement) = omabox::planner::plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(remote.content.clone())),
            &Observation::Present(remote),
            RemoteSubtree::Empty,
        ) else {
            return Err("planner did not produce the initial agreement".into());
        };
        let _ = journal.record_noop(Path::new("tracked.txt"), &agreement)?;
        drop(journal);

        fs::rename(&first, temporary.path().join("moved-first"))?;
        fs::create_dir(&first)?;
        let actual = LocalRootBinding::inspect(&first)?;
        assert_ne!(recorded, actual);
        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), false, &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        set_sync_root(&first, &xdg, &services)?;

        let journal = Journal::open(config.paths().journal_file())?;
        assert_eq!(
            journal.local_root_binding()?,
            Some(omabox::journal::LocalRootRecord {
                binding: actual.clone(),
                generation: 2,
            })
        );
        assert!(journal.baseline_paths()?.is_empty());
        let mut journal = journal;
        assert!(matches!(
            journal.activate_local_root(&actual)?,
            LocalRootActivation::Current(_)
        ));
        assert_eq!(fs::read_to_string(service_log)?, "is-active\n");
        Ok(())
    }
}
