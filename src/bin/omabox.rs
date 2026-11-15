#![deny(clippy::expect_used, clippy::panic, clippy::unwrap_used)]

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, BufRead, Write};
use std::os::unix::fs::DirBuilderExt as _;
use std::path::{Path, PathBuf};

use miette::Diagnostic;
use omabox::auth::{AuthError, AuthorizationGrant, OAuthClient, RefreshToken, RefreshTokenStore};
use omabox::config::{
    Config, ConfigDocument, ConfigError, InstanceLock, LockError, Paths, XdgDirectories,
};
use omabox::dropbox::{DropboxClient, DropboxError, DropboxLink, DropboxRoot};
use omabox::install::{InstallAction, InstallError};
use omabox::journal::{
    DropboxBinding, DropboxBindingWrite, Journal, JournalError, LocalRootBinding,
};
use omabox::service::{ServiceAction, ServiceCommands, ServiceError, ServiceGoal};
use omabox::status::{self, StatusError};
use serde::Serialize;
use thiserror::Error;

const HELP: &str = "Omabox synchronizes a local directory with Dropbox.\n\n\
Usage:\n  omabox setup [REMOTE_ROOT]\n  omabox setup --app-key KEY [--sync-root PATH] [--remote-root ROOT]\n  omabox status\n  omabox pause|resume\n  omabox settings [--json]\n  omabox settings set-root PATH\n  omabox install|upgrade|uninstall\n  omabox service start|stop|restart|enable|disable|status\n  omabox logs\n  omabox --help\n  omabox --version\n\n\
Setup with --app-key syncs ~/Dropbox, creating it if missing, unless --sync-root\n\
names another existing directory. The Dropbox app key is public. Omabox never\n\
requests or stores an app secret.\n";
const USAGE: &str = "Run `omabox --help` for usage.";
const AUTHORIZATION_CODE_LIMIT: usize = 8192;
const DEFAULT_SYNC_ROOT: &str = "Dropbox";

fn main() -> miette::Result<()> {
    match run(env::args_os().skip(1)) {
        Ok(()) => Ok(()),
        Err(error) => Err(miette::Report::new(error)),
    }
}

fn run(arguments: impl IntoIterator<Item = OsString>) -> Result<(), CliError> {
    let command = parse(arguments)?;
    match command {
        Command::Help => write_to(io::stdout().lock(), HELP, "write command output"),
        Command::Version => write_to(
            io::stdout().lock(),
            concat!("omabox ", env!("CARGO_PKG_VERSION"), "\n"),
            "write command output",
        ),
        Command::Setup(options) => setup(options, &ServiceCommands::default()),
        Command::Status => show_status(),
        Command::Settings { json } => show_settings(json),
        Command::SetRoot(path) => set_sync_root_from_environment(&path),
        Command::Install(action) => {
            let report = omabox::install::execute(action).map_err(CliError::Install)?;
            write_to(io::stdout().lock(), &report, "write command output")
        }
        Command::Service(action) => run_service(action, &ServiceCommands::default()),
        Command::Logs => ServiceCommands::default().logs().map_err(CliError::Service),
    }
}

/// Run one service command. A start or restart first clears a failed state and the start limit,
/// so systemd never refuses a start the user asked for; a stop stops a running or stopping
/// service and leaves no failed state, so a paused service reads as inactive.
fn run_service(action: ServiceAction, services: &ServiceCommands) -> Result<(), CliError> {
    match action {
        ServiceAction::Start => {
            services.drive(ServiceGoal::Start)?;
        }
        ServiceAction::Restart => {
            services.drive(ServiceGoal::Restart)?;
        }
        ServiceAction::Stop => {
            services.drive(ServiceGoal::Halt)?;
        }
        ServiceAction::Enable => services.enable()?,
        ServiceAction::Disable => services.disable()?,
        ServiceAction::Status => services.status()?,
    }
    Ok(())
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
    /// `None` selects `~/Dropbox`.
    sync_root: Option<PathBuf>,
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
                remote_root: dropbox_root(remote_root)?,
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
                remote_root = dropbox_root(value()?)?;
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
    let Some(app_key) = app_key else {
        return Err(CliError::Usage("flag-driven setup requires --app-key"));
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

// Reject a malformed root here, before setup sends the user through the
// browser authorization that linking the root would otherwise follow.
fn dropbox_root(argument: &OsStr) -> Result<String, CliError> {
    let root = utf8(argument, "the Dropbox root must be valid UTF-8")?;
    if !DropboxRoot::is_valid_path(&root) {
        return Err(CliError::Usage(
            "the Dropbox root must be empty or an absolute folder path such as /Work, with no trailing slash and no empty, . or .. parts",
        ));
    }
    Ok(root)
}

fn utf8(argument: &OsStr, message: &'static str) -> Result<String, CliError> {
    argument
        .to_str()
        .map(String::from)
        .ok_or(CliError::Usage(message))
}

fn setup(options: SetupOptions, services: &ServiceCommands) -> Result<(), CliError> {
    let (config, write_initial_config) = match options.initial_config {
        Some(initial) => {
            let xdg =
                XdgDirectories::from_environment().map_err(config_error("resolve XDG paths"))?;
            // Refuse before authorizing, so setup on a configured machine
            // asks for no login and leaves no new, empty ~/Dropbox behind.
            refuse_existing_config(&xdg.config_file())?;
            let sync_root = match initial.sync_root {
                Some(path) => path,
                None => create_default_sync_root(env::var_os("HOME"))?,
            };
            let initial_config = Config::from_values(&xdg, sync_root, initial.app_key)
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

    // Authorization waits on the browser, so it runs while the service syncs.
    let authorized = authorize(&config, &options.remote_root)?;
    change_while_released(services, "setup", "Omabox setup is complete", || {
        complete_setup(&config, write_initial_config, || bind(&config, &authorized))
    })
}

fn refuse_existing_config(path: &Path) -> Result<(), CliError> {
    if path
        .try_exists()
        .map_err(|source| CliError::InspectConfig { source })?
    {
        return Err(CliError::InitialConfigExists);
    }
    Ok(())
}

// The default root is created when missing; a root named with --sync-root
// must already exist, so a mistyped path fails instead of becoming a new,
// empty root.
fn create_default_sync_root(home: Option<OsString>) -> Result<PathBuf, CliError> {
    let home = home
        .map(PathBuf::from)
        .filter(|home| home.is_absolute())
        .ok_or(CliError::DefaultSyncRootUnavailable)?;
    let root = home.join(DEFAULT_SYNC_ROOT);
    match fs::DirBuilder::new().mode(0o700).create(&root) {
        Ok(()) => Ok(root),
        Err(source) if source.kind() == io::ErrorKind::AlreadyExists => Ok(root),
        Err(source) => Err(CliError::CreateDefaultSyncRoot { path: root, source }),
    }
}

/// A Dropbox login validated against the account and root, not yet stored.
struct Authorized {
    binding: DropboxBinding,
    refresh_token: RefreshToken,
}

fn authorize(config: &Config, remote_root: &str) -> Result<Authorized, CliError> {
    let oauth = OAuthClient::new(config.dropbox_app_key());
    let pending = oauth.begin().map_err(|source| CliError::Auth {
        operation: "start Dropbox authorization",
        source,
    })?;
    write_to(
        io::stdout().lock(),
        &format!(
            "Open this URL in a browser:\n{}\n\nPaste the authorization code: ",
            pending.authorization_url()
        ),
        "write command output",
    )?;
    let code = read_authorization_code(io::stdin().lock())?;
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
    Ok(Authorized {
        binding: client.binding(),
        refresh_token,
    })
}

fn bind(config: &Config, authorized: &Authorized) -> Result<(), CliError> {
    let Authorized {
        binding,
        refresh_token,
    } = authorized;
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
        Some(existing) if existing != *binding => return Err(CliError::JournalBindingMismatch),
        Some(_) => false,
        None => true,
    };
    RefreshTokenStore::new()
        .store(binding, refresh_token)
        .map_err(|source| CliError::Auth {
            operation: "store the Dropbox refresh token",
            source,
        })?;
    if was_unbound {
        match journal
            .bind_dropbox_root(binding)
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

/// Under the instance lock, run `bind`, then write a new config when
/// `write_initial_config` is set and none appeared since setup began.
fn complete_setup<Bind>(
    config: &Config,
    write_initial_config: bool,
    bind: Bind,
) -> Result<(), CliError>
where
    Bind: FnOnce() -> Result<(), CliError>,
{
    let _lock = InstanceLock::acquire(config.paths().lock_file())
        .map_err(|source| CliError::Lock { source })?;
    if write_initial_config {
        refuse_existing_config(&config.paths().config_file())?;
    }
    bind()?;
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
    let xdg = XdgDirectories::from_environment().map_err(config_error("resolve XDG paths"))?;
    write_to(
        io::stdout().lock(),
        &status_output(&xdg)?,
        "write command output",
    )
}

/// Explain the journal's state; an unusable sync root is reported, not fatal.
fn status_output(xdg: &XdgDirectories) -> Result<String, CliError> {
    let document = ConfigDocument::load_from(xdg).map_err(config_error("load configuration"))?;
    let paths = Paths::resolve_private(xdg).map_err(config_error("resolve state paths"))?;
    let mut output = status::render(paths.journal_file()).map_err(CliError::Status)?;
    if let Some(line) = unusable_root_line(&document, xdg) {
        output.push_str(&line);
        output.push('\n');
    }
    Ok(output)
}

/// Why the stored sync root fails validation, with its whole cause chain.
fn unusable_root_line(document: &ConfigDocument, xdg: &XdgDirectories) -> Option<String> {
    let error = Config::validate(document, xdg).err()?;
    let mut line = format!("Sync root unusable: {error}");
    let mut reason: &(dyn std::error::Error + 'static) = &error;
    while let Some(source) = reason.source() {
        line.push_str(&format!(": {source}"));
        reason = source;
    }
    Some(line)
}

#[derive(Serialize)]
struct SettingsDocument<'config> {
    sync_root: &'config Path,
    dropbox_app_key: &'config str,
}

fn show_settings(json: bool) -> Result<(), CliError> {
    let xdg = XdgDirectories::from_environment().map_err(config_error("resolve XDG paths"))?;
    let (output, unusable) = settings_output(&xdg, json)?;
    write_to(io::stdout().lock(), &output, "write command output")?;
    match unusable {
        Some(line) => write_to(
            io::stderr().lock(),
            &format!("{line}\n"),
            "write command diagnostics",
        ),
        None => Ok(()),
    }
}

/// Show the stored settings; an unusable sync root is reported, not fatal.
///
/// Returns the stdout text and, in JSON mode, the unusable-root line for
/// stderr, so stdout stays exactly one JSON document. In text mode the line
/// follows the settings on stdout.
fn settings_output(xdg: &XdgDirectories, json: bool) -> Result<(String, Option<String>), CliError> {
    let document = ConfigDocument::load_from(xdg).map_err(config_error("load configuration"))?;
    let mut output = if json {
        let mut serialized = serde_json::to_string_pretty(&SettingsDocument {
            sync_root: document.sync_root(),
            dropbox_app_key: document.dropbox_app_key(),
        })
        .map_err(CliError::SerializeOutput)?;
        serialized.push('\n');
        serialized
    } else {
        format!(
            "Sync root: {}\nDropbox app key: {}\n",
            document.sync_root().display(),
            document.dropbox_app_key()
        )
    };
    let unusable = unusable_root_line(&document, xdg);
    if json {
        return Ok((output, unusable));
    }
    if let Some(line) = unusable {
        output.push_str(&line);
        output.push('\n');
    }
    Ok((output, None))
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
    let current = ConfigDocument::load_from(xdg)
        .map_err(config_error("load configuration for sync-root change"))?;
    let paths = Paths::resolve_private(xdg)
        .map_err(config_error("resolve state paths for sync-root change"))?;
    let replacement = Config::from_values(xdg, path, current.dropbox_app_key())
        .map_err(config_error("validate the new sync root"))?;

    let done = format!(
        "Omabox sync root is now {}",
        replacement.sync_root().display()
    );
    change_while_released(services, "the sync-root change", &done, || {
        change_sync_root_while_stopped(&paths, &replacement)
    })
}

/// Stop a service that can hold the instance lock, run `change`, then start
/// the service again if it was running, or start a failed one the change may
/// have fixed. `name` names the change, as in "setup"; `done` states the
/// finished change, as in "Omabox setup is complete".
fn change_while_released<Change>(
    services: &ServiceCommands,
    name: &'static str,
    done: &str,
    change: Change,
) -> Result<(), CliError>
where
    Change: FnOnce() -> Result<(), CliError>,
{
    let released = services
        .drive(ServiceGoal::Release)
        .map_err(CliError::Service)?;
    let change = change();
    let restored = services.drive(ServiceGoal::Restore(released.first));
    match (change, restored) {
        (Err(source), Err(restore)) => Err(CliError::ChangeAndRestore {
            change: name,
            source: Box::new(source),
            restore: [restore],
        }),
        (Err(source), Ok(_)) => Err(source),
        (Ok(()), Err(source)) => Err(CliError::StartAfterChange {
            change: done.into(),
            source,
        }),
        (Ok(()), Ok(restored)) => {
            // The change may fix the fatal cause of a unit Release left failed.
            let recovered = !restored.launched
                && services
                    .drive(ServiceGoal::Recover)
                    .map_err(|source| CliError::StartAfterChange {
                        change: done.into(),
                        source,
                    })?
                    .launched;
            let note = if recovered {
                " The stopped service has been started again."
            } else {
                ""
            };
            write_to(
                io::stdout().lock(),
                &format!("{done}.{note}\n"),
                "write command output",
            )
        }
    }
}

fn change_sync_root_while_stopped(paths: &Paths, replacement: &Config) -> Result<(), CliError> {
    let _lock =
        InstanceLock::acquire(paths.lock_file()).map_err(|source| CliError::Lock { source })?;
    let binding = LocalRootBinding::inspect(replacement.sync_root())
        .map_err(|source| CliError::SyncRoot { source })?;
    let journal_path = paths.journal_file();
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

/// Read one authorization code line of at most `AUTHORIZATION_CODE_LIMIT + 1`
/// bytes, terminator included, and trim its surrounding whitespace.
fn read_authorization_code(input: impl BufRead) -> Result<String, CliError> {
    let bound = AUTHORIZATION_CODE_LIMIT + 1;
    let mut line = Vec::new();
    input
        .take(bound as u64)
        .read_until(b'\n', &mut line)
        .map_err(|source| CliError::Io {
            operation: "read the authorization code",
            source,
        })?;
    if line.len() == bound && !line.ends_with(b"\n") {
        return Err(CliError::InvalidAuthorizationCode);
    }
    let Ok(line) = String::from_utf8(line) else {
        return Err(CliError::InvalidAuthorizationCode);
    };
    let code = line.trim();
    if code.is_empty() || code.len() > AUTHORIZATION_CODE_LIMIT {
        return Err(CliError::InvalidAuthorizationCode);
    }
    Ok(code.to_owned())
}

fn write_to(mut output: impl Write, value: &str, operation: &'static str) -> Result<(), CliError> {
    output
        .write_all(value.as_bytes())
        .and_then(|()| output.flush())
        .map_err(|source| CliError::Io { operation, source })
}

#[derive(Debug, Diagnostic, Error)]
enum CliError {
    #[error("{0}\n\n{USAGE}")]
    #[diagnostic(code(omabox::cli::usage))]
    Usage(&'static str),

    #[error("could not {operation}")]
    #[diagnostic(forward(source))]
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

    #[error("could not inspect the sync folder")]
    #[diagnostic(
        code(omabox::cli::sync_root),
        help(
            "Ensure the sync folder exists, is readable and is on a filesystem that records file creation times, or choose another folder."
        )
    )]
    SyncRoot {
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

    /// Renders the change's chain and help, then the restore failure as a
    /// related diagnostic with its own.
    #[error(
        "{change} failed, and the Omabox service could not be restarted; run `omabox resume` once the errors below are fixed"
    )]
    #[diagnostic(code(omabox::cli::change_and_restore), forward(source))]
    ChangeAndRestore {
        change: &'static str,
        #[source]
        source: Box<CliError>,
        #[related]
        restore: [ServiceError; 1],
    },

    #[error("{change}, but the Omabox service could not be started or checked")]
    #[diagnostic(
        code(omabox::cli::start_after_change),
        help(
            "The change is kept. Run `omabox status` and `omabox logs` to see why, then `omabox resume`."
        )
    )]
    StartAfterChange {
        change: String,
        #[source]
        source: ServiceError,
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

    #[error("HOME must be an absolute path to find the default sync root ~/Dropbox")]
    #[diagnostic(
        code(omabox::cli::default_sync_root),
        help("Set HOME, or pass --sync-root PATH.")
    )]
    DefaultSyncRootUnavailable,

    #[error("could not create the default sync root {}", path.display())]
    #[diagnostic(
        code(omabox::cli::create_default_sync_root),
        help("Create the directory, or pass --sync-root PATH.")
    )]
    CreateDefaultSyncRoot {
        path: PathBuf,
        #[source]
        source: io::Error,
    },

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
    use std::os::unix::fs::PermissionsExt as _;

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
        state: &str,
        log: &Path,
    ) -> Result<PathBuf, Box<dyn Error>> {
        let path = directory.join("systemctl");
        fs::write(
            &path,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\nif [ \"$2\" = show ]; then printf '%s\\n' {state}; fi\nexit 0\n",
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
    fn config_errors_show_their_own_help() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, _second) = fixture()?;
        let file = temporary.path().join("file");
        fs::write(&file, b"not a directory")?;
        let services = ServiceCommands::scripts("/unused/systemctl", "/unused/journalctl");

        let Err(error) = set_sync_root(&file, &xdg, &services) else {
            return Err("a regular file became the sync root".into());
        };

        assert!(matches!(error, CliError::Config { .. }), "{error:?}");
        let code = Diagnostic::code(&error).map(|code| code.to_string());
        assert_eq!(
            code.as_deref(),
            Some("omabox::config::sync_root_not_directory")
        );
        let help = Diagnostic::help(&error).map(|help| help.to_string());
        assert_eq!(
            help.as_deref(),
            Some("Set `sync_root` to an existing local directory.")
        );
        Ok(())
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
                    sync_root: Some(PathBuf::from("/tmp/Dropbox")),
                    app_key: String::from("key"),
                }),
            })
        );
        assert_eq!(
            parse(arguments(&["setup", "--app-key", "key"]))?,
            Command::Setup(SetupOptions {
                remote_root: String::new(),
                initial_config: Some(InitialConfig {
                    sync_root: None,
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
    fn default_sync_root_is_a_private_home_dropbox_created_once() -> Result<(), Box<dyn Error>> {
        let home = tempfile::TempDir::new()?;
        let root = home.path().join("Dropbox");
        for _ in 0..2 {
            assert_eq!(
                create_default_sync_root(Some(home.path().as_os_str().to_os_string()))?,
                root
            );
            assert_eq!(fs::metadata(&root)?.permissions().mode() & 0o777, 0o700);
        }
        for home in [None, Some(OsString::from("relative/home"))] {
            assert!(matches!(
                create_default_sync_root(home),
                Err(CliError::DefaultSyncRootUnavailable)
            ));
        }
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
        const ROOT_FAULT: &str = "the Dropbox root must be empty or an absolute folder path such as /Work, with no trailing slash and no empty, . or .. parts";
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
            (arguments(&["setup", "-h"]), ROOT_FAULT),
            (arguments(&["setup", "Work"]), ROOT_FAULT),
            (arguments(&["setup", "/Work/"]), ROOT_FAULT),
            (arguments(&["setup", "/Work/../Home"]), ROOT_FAULT),
            (
                arguments(&[
                    "setup",
                    "--sync-root",
                    "/tmp/Dropbox",
                    "--app-key",
                    "key",
                    "--remote-root",
                    "Work",
                ]),
                ROOT_FAULT,
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
            let sync_root = initial
                .sync_root
                .ok_or("documented flag setup lost its sync root")?;
            let config = Config::from_values(&xdg, sync_root, initial.app_key)?;
            config.prepare()?;
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
        let systemctl = fake_systemctl(temporary.path(), "active", &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        set_sync_root(&second, &xdg, &services)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), second);
        assert_eq!(
            fs::read_to_string(service_log)?,
            "show\nstop\nreset-failed\nstart\n"
        );
        let journal = Journal::open(config.paths().journal_file())?;
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.blocked_plans()?.is_empty());
        assert_eq!(fs::read(staged_payload)?, b"staged");
        assert_eq!(fs::read(recovery_payload)?, b"recovery");
        Ok(())
    }

    #[test]
    fn set_root_starts_a_failed_service_after_the_change() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, second) = fixture()?;
        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), "failed", &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");

        set_sync_root(&second, &xdg, &services)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), second);
        assert_eq!(
            fs::read_to_string(service_log)?,
            "show\nshow\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn set_root_restarts_a_starting_service() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, second) = fixture()?;
        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), "activating", &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");

        set_sync_root(&second, &xdg, &services)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), second);
        assert_eq!(
            fs::read_to_string(service_log)?,
            "show\nstop\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn set_root_waits_out_a_stopping_service() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, second) = fixture()?;
        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), "deactivating", &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");

        set_sync_root(&second, &xdg, &services)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), second);
        assert_eq!(
            fs::read_to_string(service_log)?,
            "show\nstop\nshow\nstop\nshow\n"
        );
        Ok(())
    }

    /// Write a `systemctl` stand-in that keeps the unit state in a file:
    /// `show` prints it, `stop` and `reset-failed` leave the unit inactive,
    /// and `start` makes it active, or exits with `start_exit` when nonzero.
    /// Every command is logged to `service.log` in `directory`.
    fn stateful_systemctl(
        directory: &Path,
        initial: &str,
        start_exit: i32,
    ) -> Result<ServiceCommands, Box<dyn Error>> {
        let state = directory.join("unit-state");
        fs::write(&state, format!("{initial}\n"))?;
        let systemctl = directory.join("systemctl");
        fs::write(
            &systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{log}'\n\
                 case \"$2\" in\n\
                 show) cat '{state}' ;;\n\
                 stop | reset-failed) printf '%s\\n' inactive > '{state}' ;;\n\
                 start) [ {start_exit} = 0 ] || exit {start_exit}; printf '%s\\n' active > '{state}' ;;\n\
                 esac\n\
                 exit 0\n",
                log = directory.join("service.log").display(),
                state = state.display(),
            ),
        )?;
        Ok(ServiceCommands::scripts(systemctl, "/unused/journalctl"))
    }

    /// The service log and unit state, read from `directory`.
    fn service_trace(directory: &Path) -> io::Result<(String, String)> {
        Ok((
            fs::read_to_string(directory.join("service.log"))?,
            fs::read_to_string(directory.join("unit-state"))?,
        ))
    }

    #[test]
    fn a_change_runs_while_the_service_is_released() -> Result<(), Box<dyn Error>> {
        for (initial, before, seen, after) in [
            (
                "active",
                "show\nstop\n",
                "inactive\n",
                "show\nstop\nreset-failed\nstart\n",
            ),
            (
                "failed",
                "show\n",
                "failed\n",
                "show\nshow\nreset-failed\nstart\n",
            ),
        ] {
            let temporary = tempfile::TempDir::new()?;
            let services = stateful_systemctl(temporary.path(), initial, 0)?;
            let mut during = None;

            change_while_released(&services, "setup", "Omabox setup is complete", || {
                during = Some(service_trace(temporary.path()));
                Ok(())
            })?;
            let Some(during) = during else {
                return Err(format!("{initial}: the change did not run").into());
            };
            assert_eq!(during?, (before.into(), seen.into()), "{initial}");
            assert_eq!(
                service_trace(temporary.path())?,
                (after.into(), "active\n".into()),
                "{initial}"
            );
        }
        Ok(())
    }

    #[test]
    fn a_failed_change_still_restores_the_service() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;
        let services = stateful_systemctl(temporary.path(), "active", 0)?;

        let result = change_while_released(&services, "setup", "Omabox setup is complete", || {
            Err(CliError::InvalidAuthorizationCode)
        });
        assert!(
            matches!(result, Err(CliError::InvalidAuthorizationCode)),
            "{result:?}"
        );
        assert_eq!(
            service_trace(temporary.path())?,
            (
                "show\nstop\nreset-failed\nstart\n".into(),
                "active\n".into()
            )
        );
        Ok(())
    }

    #[test]
    fn setup_reports_a_held_lock_and_restores_the_service() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, _second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let _held_lock = InstanceLock::acquire(config.paths().lock_file())?;
        let services = stateful_systemctl(temporary.path(), "active", 0)?;

        let result = change_while_released(&services, "setup", "Omabox setup is complete", || {
            complete_setup(&config, false, || Ok(()))
        });
        assert!(matches!(result, Err(CliError::Lock { .. })), "{result:?}");
        assert_eq!(
            service_trace(temporary.path())?,
            (
                "show\nstop\nreset-failed\nstart\n".into(),
                "active\n".into()
            )
        );
        Ok(())
    }

    #[test]
    fn a_failed_change_and_restore_render_both() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, _second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let _held_lock = InstanceLock::acquire(config.paths().lock_file())?;
        let services = stateful_systemctl(temporary.path(), "active", 1)?;

        let Err(error) =
            change_while_released(&services, "setup", "Omabox setup is complete", || {
                complete_setup(&config, false, || Ok(()))
            })
        else {
            return Err("setup succeeded under a held lock".into());
        };
        assert!(
            matches!(&error, CliError::ChangeAndRestore { source, .. }
                if matches!(**source, CliError::Lock { .. })),
            "{error:?}"
        );
        // The report wraps the message at the terminal width, so check the
        // whole message, with its `omabox resume` advice, unwrapped.
        assert_eq!(
            error.to_string(),
            "setup failed, and the Omabox service could not be restarted; \
             run `omabox resume` once the errors below are fixed"
        );
        let report = format!("{:?}", miette::Report::new(error));
        for expected in [
            "setup failed, and the Omabox service could not be restarted",
            "could not acquire the Omabox daemon lock",
            "Stop any manually started Omabox daemon, then retry.",
            "`systemctl` failed with status Some(1)",
            "Review the command output and `omabox logs`, then retry.",
        ] {
            assert!(
                report.contains(expected),
                "{expected:?} missing from {report}"
            );
        }
        Ok(())
    }

    #[test]
    fn setup_releases_the_lock_before_starting_a_failed_service() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, _second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let service_log = temporary.path().join("service.log");
        let systemctl = temporary.path().join("systemctl");
        fs::write(
            &systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n  show) printf '%s\\n' failed ;;\n  start) exec flock -n '{}' true ;;\nesac\nexit 0\n",
                service_log.display(),
                config.paths().lock_file().display()
            ),
        )?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");

        change_while_released(&services, "setup", "Omabox setup is complete", || {
            complete_setup(&config, false, || Ok(()))
        })?;
        assert_eq!(
            fs::read_to_string(service_log)?,
            "show\nshow\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn a_completed_change_reports_a_failed_start() -> Result<(), Box<dyn Error>> {
        fn failing_start(directory: &Path, state: &str) -> Result<ServiceCommands, Box<dyn Error>> {
            let systemctl = directory.join("systemctl");
            fs::write(
                &systemctl,
                format!(
                    "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n  show) printf '%s\\n' {state} ;;\n  start) exit 1 ;;\nesac\nexit 0\n",
                    directory.join("service.log").display()
                ),
            )?;
            Ok(ServiceCommands::scripts(systemctl, "/unused/journalctl"))
        }

        let (temporary, xdg, _first, _second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let services = failing_start(temporary.path(), "failed")?;
        assert!(matches!(
            change_while_released(&services, "setup", "Omabox setup is complete", || {
                complete_setup(&config, false, || Ok(()))
            }),
            Err(CliError::StartAfterChange { .. })
        ));

        for state in ["failed", "active"] {
            let (temporary, xdg, _first, second) = fixture()?;
            let services = failing_start(temporary.path(), state)?;
            let result = set_sync_root(&second, &xdg, &services);
            assert!(
                matches!(result, Err(CliError::StartAfterChange { .. })),
                "{state}: {result:?}"
            );
            assert_eq!(Config::load_from(&xdg)?.sync_root(), second, "{state}");
        }
        Ok(())
    }

    #[test]
    fn service_commands_reset_the_start_limit_before_a_start() -> Result<(), Box<dyn Error>> {
        for (action, state, log) in [
            (ServiceAction::Start, "failed", "reset-failed\nstart\n"),
            (ServiceAction::Start, "inactive", "reset-failed\nstart\n"),
            (ServiceAction::Restart, "active", "reset-failed\nrestart\n"),
            (ServiceAction::Stop, "failed", "show\nreset-failed\n"),
            (ServiceAction::Stop, "active", "show\nstop\nshow\n"),
            (ServiceAction::Stop, "inactive", "show\n"),
            (ServiceAction::Stop, "deactivating", "show\nstop\nshow\n"),
        ] {
            let temporary = tempfile::TempDir::new()?;
            let service_log = temporary.path().join("service.log");
            let systemctl = fake_systemctl(temporary.path(), state, &service_log)?;
            let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");

            run_service(action, &services)?;
            assert_eq!(fs::read_to_string(service_log)?, log, "{action:?} {state}");
        }
        Ok(())
    }

    #[test]
    fn set_root_requires_the_daemon_lock_before_writing_config() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, _first, second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let original_config = fs::read(config.paths().config_file())?;
        let _held_lock = InstanceLock::acquire(config.paths().lock_file())?;
        let service_log = temporary.path().join("service.log");
        let systemctl = fake_systemctl(temporary.path(), "inactive", &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");

        assert!(matches!(
            set_sync_root(&second, &xdg, &services),
            Err(CliError::Lock { .. })
        ));
        assert_eq!(fs::read(config.paths().config_file())?, original_config);
        assert_eq!(fs::read_to_string(service_log)?, "show\n");
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
                 if [ \"$2\" = show ]; then printf '%s\\n' active; fi\n\
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
            "show\nstop\nreset-failed\nstart\n"
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
    fn a_failed_change_and_restart_report_both() -> Result<(), Box<dyn Error>> {
        let (temporary, xdg, first, second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let config_directory = config.paths().config_directory();
        let saved_config_directory = temporary.path().join("saved-config");
        let service_log = temporary.path().join("service.log");
        let systemctl = temporary.path().join("systemctl-restore-failure");
        fs::write(
            &systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\n\
                 if [ \"$2\" = show ]; then printf '%s\\n' active; fi\n\
                 if [ \"$2\" = stop ]; then mv '{}' '{}'; : > '{}'; fi\n\
                 if [ \"$2\" = start ]; then exit 1; fi\n\
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
            Err(CliError::ChangeAndRestore { .. })
        ));

        fs::remove_file(config_directory)?;
        fs::rename(saved_config_directory, config_directory)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), first);
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
        let systemctl = fake_systemctl(temporary.path(), "inactive", &service_log)?;
        let services = ServiceCommands::scripts(systemctl, "/unused/journalctl");
        set_sync_root(&second, &xdg, &services)?;
        assert_eq!(Config::load_from(&xdg)?.sync_root(), second);
        assert_eq!(fs::read_to_string(service_log)?, "show\nshow\n");

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
        let systemctl = fake_systemctl(temporary.path(), "inactive", &service_log)?;
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
        assert_eq!(fs::read_to_string(service_log)?, "show\nshow\n");
        Ok(())
    }

    #[test]
    fn an_overlong_authorization_code_is_rejected_within_the_bound() {
        for extra in [1, 2, 4096] {
            let mut input = io::Cursor::new(vec![b'a'; AUTHORIZATION_CODE_LIMIT + extra]);
            assert!(matches!(
                read_authorization_code(&mut input),
                Err(CliError::InvalidAuthorizationCode)
            ));
            assert!(input.position() <= AUTHORIZATION_CODE_LIMIT as u64 + 1);
        }
    }

    #[test]
    fn an_authorization_code_at_the_limit_is_accepted() -> Result<(), Box<dyn Error>> {
        let mut line = vec![b'a'; AUTHORIZATION_CODE_LIMIT];
        line.push(b'\n');
        let code = read_authorization_code(io::Cursor::new(line))?;
        assert_eq!(code.len(), AUTHORIZATION_CODE_LIMIT);
        Ok(())
    }

    #[test]
    fn an_authorization_code_is_trimmed() -> Result<(), Box<dyn Error>> {
        assert_eq!(read_authorization_code(&b" \tcode \r\n"[..])?, "code");
        assert_eq!(read_authorization_code(&b"code"[..])?, "code");
        Ok(())
    }

    #[test]
    fn a_blank_or_non_utf8_authorization_code_is_rejected() {
        for input in [&b"  \n"[..], &b"\xff\n"[..]] {
            assert!(matches!(
                read_authorization_code(input),
                Err(CliError::InvalidAuthorizationCode)
            ));
        }
    }

    /// The line status and settings report when the stored root is missing.
    fn unavailable_line(root: &Path) -> String {
        format!(
            "Sync root unusable: could not resolve sync root `{}`: \
             No such file or directory (os error 2)",
            root.display()
        )
    }

    /// Check settings JSON is one document holding exactly the stored settings.
    fn assert_settings_json(json: &str, stored: &Path) -> Result<(), Box<dyn Error>> {
        let value = serde_json::from_str::<serde_json::Value>(json)?;
        let Some(object) = value.as_object() else {
            return Err("settings JSON was not an object".into());
        };
        let mut keys = object.keys().map(String::as_str).collect::<Vec<_>>();
        keys.sort_unstable();
        assert_eq!(keys, ["dropbox_app_key", "sync_root"]);
        assert_eq!(
            object.get("sync_root").and_then(serde_json::Value::as_str),
            stored.to_str()
        );
        assert_eq!(
            object
                .get("dropbox_app_key")
                .and_then(serde_json::Value::as_str),
            Some("public-app-key")
        );
        Ok(())
    }

    #[test]
    fn status_reports_the_journal_when_the_root_is_unavailable() -> Result<(), Box<dyn Error>> {
        let (_temporary, xdg, first, _second) = fixture()?;
        let config = Config::load_from(&xdg)?;
        let stored = ConfigDocument::load_from(&xdg)?.sync_root().to_path_buf();
        let mut journal = Journal::open(config.paths().journal_file())?;
        let _ = journal.bind_dropbox_root(&omabox::journal::DropboxBinding {
            account_id: String::from("account"),
            root_namespace_id: String::from("namespace"),
            remote_root: String::from("/remote"),
        })?;
        journal.publish_remote_inventory(
            "remote-cursor",
            &[omabox::journal::RemoteObservationRecord {
                canonical_path: CanonicalPath::from_display(Path::new("stale.txt")),
                path: PathBuf::from("stale.txt"),
                observation: Observation::Unknown(omabox::model::UnknownReason::Stale),
            }],
        )?;
        drop(journal);
        fs::remove_dir(&first)?;

        let journal_status = status::render(config.paths().journal_file())?;
        assert!(journal_status.contains("stale.txt"), "{journal_status}");
        let output = status_output(&xdg)?;
        assert_eq!(
            output,
            format!("{journal_status}{}\n", unavailable_line(&stored))
        );
        Ok(())
    }

    #[test]
    fn settings_show_the_stored_root_when_it_is_unavailable() -> Result<(), Box<dyn Error>> {
        let (_temporary, xdg, first, _second) = fixture()?;
        let stored = ConfigDocument::load_from(&xdg)?.sync_root().to_path_buf();
        fs::remove_dir(&first)?;
        let line = unavailable_line(&stored);

        let (text, text_line) = settings_output(&xdg, false)?;
        assert_eq!(
            text,
            format!(
                "Sync root: {}\nDropbox app key: public-app-key\n{line}\n",
                stored.display()
            )
        );
        assert_eq!(text_line, None);

        let (json, json_line) = settings_output(&xdg, true)?;
        assert_eq!(json_line.as_deref(), Some(line.as_str()));
        assert!(!json.contains(&line), "{json}");
        assert_settings_json(&json, &stored)
    }

    #[test]
    fn settings_json_is_one_document_when_the_root_is_available() -> Result<(), Box<dyn Error>> {
        let (_temporary, xdg, _first, _second) = fixture()?;
        let stored = ConfigDocument::load_from(&xdg)?.sync_root().to_path_buf();

        let (json, line) = settings_output(&xdg, true)?;
        assert_eq!(line, None);
        assert_settings_json(&json, &stored)
    }
}
