//! Rootless installation of the Omabox binaries, service unit, and Omarchy plugin.

use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write as _};
use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};

use miette::Diagnostic;
use rustix::fs::{CWD, RenameFlags, renameat_with};
use thiserror::Error;

use crate::service::{ServiceAction, ServiceCommands, ServiceError};
use crate::spawn::Launch;

const UNIT: &[u8] = include_bytes!("../packaging/systemd/omabox.service");
const PLUGIN: [(&str, &[u8]); 4] = [
    (
        "manifest.json",
        include_bytes!("../packaging/omarchy/plugins/local.omabox/manifest.json"),
    ),
    (
        "Panel.qml",
        include_bytes!("../packaging/omarchy/plugins/local.omabox/Panel.qml"),
    ),
    (
        "Status.qml",
        include_bytes!("../packaging/omarchy/plugins/local.omabox/Status.qml"),
    ),
    (
        "README.md",
        include_bytes!("../packaging/omarchy/plugins/local.omabox/README.md"),
    ),
];
const PLUGIN_ID: &str = "local.omabox";
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// A user-requested artifact lifecycle operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InstallAction {
    /// Install the invoking build.
    Install,
    /// Replace installed artifacts with the invoking build.
    Upgrade,
    /// Remove installed artifacts while retaining user data.
    Uninstall,
}

/// Apply a lifecycle operation to the current user's documented install paths.
pub fn execute(action: InstallAction) -> Result<String, InstallError> {
    let layout = Layout::new(PathBuf::from(
        env::var_os("HOME").ok_or(InstallError::HomeUnavailable)?,
    ))?;
    let omabox = env::current_exe().map_err(fs_error(
        "locate the running executable",
        Path::new("omabox"),
    ))?;
    let omaboxd = omabox
        .parent()
        .ok_or_else(|| invalid(&omabox, "the executable has no parent directory"))?
        .join("omaboxd");
    execute_with(
        action,
        &layout,
        &Sources { omabox, omaboxd },
        &Commands::default(),
    )
}

struct Layout {
    home: PathBuf,
    omabox: PathBuf,
    omaboxd: PathBuf,
    unit: PathBuf,
    plugin: PathBuf,
    omarchy_root: PathBuf,
}

impl Layout {
    fn new(home: PathBuf) -> Result<Self, InstallError> {
        if !home.is_absolute() {
            return Err(InstallError::HomeNotAbsolute { path: home });
        }
        let omarchy_root = home.join(".config/omarchy");
        Ok(Self {
            omabox: home.join(".local/bin/omabox"),
            omaboxd: home.join(".local/bin/omaboxd"),
            unit: home.join(".config/systemd/user/omabox.service"),
            plugin: omarchy_root.join("plugins").join(PLUGIN_ID),
            home,
            omarchy_root,
        })
    }
}

struct Sources {
    omabox: PathBuf,
    omaboxd: PathBuf,
}

struct Commands {
    services: ServiceCommands,
    omarchy: Launch,
    omarchy_shell: Launch,
}

impl Default for Commands {
    fn default() -> Self {
        Self {
            services: ServiceCommands::default(),
            omarchy: Launch::Program(PathBuf::from("omarchy")),
            omarchy_shell: Launch::Program(PathBuf::from("omarchy-shell")),
        }
    }
}

#[derive(Clone, Copy)]
struct ServiceState {
    enabled: bool,
    running: bool,
}

impl ServiceState {
    fn read(commands: &Commands) -> Result<Self, InstallError> {
        Ok(Self {
            enabled: commands.services.is_enabled()?,
            running: commands.services.is_active()?,
        })
    }

    fn restore(self, commands: &Commands, restore_enabled: bool) -> Result<(), InstallError> {
        if restore_enabled && self.enabled {
            commands.services.control(ServiceAction::Enable)?;
        }
        if self.running {
            commands.services.control(ServiceAction::Start)?;
        }
        Ok(())
    }
}

fn execute_with(
    action: InstallAction,
    layout: &Layout,
    sources: &Sources,
    commands: &Commands,
) -> Result<String, InstallError> {
    match action {
        InstallAction::Install | InstallAction::Upgrade => {
            install(action, layout, sources, commands)
        }
        InstallAction::Uninstall => uninstall(layout, commands),
    }
}

fn install(
    action: InstallAction,
    layout: &Layout,
    sources: &Sources,
    commands: &Commands,
) -> Result<String, InstallError> {
    let mut transaction = Transaction::install(layout, sources, commands)?;
    if let Err(source) = ensure_shell_unlocked(commands) {
        return Err(cleanup_failure(source, transaction.cleanup_prepared()));
    }
    let state = match ServiceState::read(commands) {
        Ok(state) => state,
        Err(source) => return Err(cleanup_failure(source, transaction.cleanup_prepared())),
    };
    publish(&mut transaction, commands, state, false)?;

    let launch = if state.running {
        commands
            .services
            .control(ServiceAction::Restart)
            .map_err(InstallError::Service)
    } else {
        Ok(())
    };
    if let Err(source) = launch {
        return Err(restore_after_failure(
            source,
            &mut transaction,
            commands,
            state,
            false,
            true,
        ));
    }
    transaction.finish()?;
    Ok(format!(
        "Omabox was {}. The service remains {} and {}.\n",
        if action == InstallAction::Install {
            "installed"
        } else {
            "upgraded"
        },
        if state.enabled { "enabled" } else { "disabled" },
        if state.running { "running" } else { "stopped" }
    ))
}

fn uninstall(layout: &Layout, commands: &Commands) -> Result<String, InstallError> {
    let mut transaction = Transaction::remove(layout)?;
    ensure_shell_unlocked(commands)?;
    let state = ServiceState::read(commands)?;
    if state.running {
        commands.services.control(ServiceAction::Stop)?;
    }
    if state.enabled
        && let Err(source) = commands.services.control(ServiceAction::Disable)
    {
        let source = InstallError::Service(source);
        return Err(rollback_failure(source, state.restore(commands, true)));
    }
    publish(&mut transaction, commands, state, true)?;
    transaction.finish()?;
    Ok(String::from(
        "Omabox program, service, and plugin files were removed. Configuration, the journal, recovery data, Secret Service credentials, and synced files were retained.\n",
    ))
}

fn publish(
    transaction: &mut Transaction,
    commands: &Commands,
    state: ServiceState,
    restore_enabled: bool,
) -> Result<(), InstallError> {
    if let Err(source) = ensure_shell_unlocked(commands) {
        let restored = if restore_enabled {
            state.restore(commands, true)
        } else {
            Ok(())
        }
        .and_then(|()| transaction.cleanup_prepared());
        return Err(rollback_failure(source, restored));
    }
    let result = transaction.apply(commands).and_then(|()| {
        commands
            .services
            .daemon_reload()
            .map_err(InstallError::Service)
    });
    match result {
        Ok(()) => Ok(()),
        Err(source) => Err(restore_after_failure(
            source,
            transaction,
            commands,
            state,
            restore_enabled,
            restore_enabled,
        )),
    }
}

fn ensure_shell_unlocked(commands: &Commands) -> Result<(), InstallError> {
    let output = commands
        .omarchy_shell
        .command()
        .args(["lock", "isLocked"])
        .stdin(Stdio::null())
        .output()
        .map_err(|source| InstallError::CommandStart {
            command: "omarchy-shell lock isLocked",
            source,
        })?;
    match (output.status.code(), output.stdout.as_slice()) {
        (Some(0), b"false\n" | b"false") => Ok(()),
        (Some(0), b"true\n" | b"true") => Err(InstallError::ShellLocked),
        (Some(0), _) => Err(InstallError::InvalidLockState),
        (status, _) => Err(InstallError::CommandFailed {
            command: "omarchy-shell lock isLocked",
            status,
        }),
    }
}

fn restore_after_failure(
    source: InstallError,
    transaction: &mut Transaction,
    commands: &Commands,
    state: ServiceState,
    restore_enabled: bool,
    restore_service_state: bool,
) -> InstallError {
    let restored = transaction
        .rollback(commands)
        .and_then(|()| {
            commands
                .services
                .daemon_reload()
                .map_err(InstallError::Service)
        })
        .and_then(|()| {
            if restore_service_state {
                state.restore(commands, restore_enabled)
            } else {
                Ok(())
            }
        })
        .and_then(|()| transaction.cleanup_prepared());
    rollback_failure(source, restored)
}

fn rollback_failure(source: InstallError, restored: Result<(), InstallError>) -> InstallError {
    match restored {
        Ok(()) => source,
        Err(restore) => InstallError::RollbackFailed {
            source: Box::new(source),
            restore: Box::new(restore),
        },
    }
}

fn cleanup_failure(source: InstallError, cleanup: Result<(), InstallError>) -> InstallError {
    match cleanup {
        Ok(()) => source,
        Err(cleanup) => InstallError::CleanupFailed {
            source: Box::new(source),
            cleanup: Box::new(cleanup),
        },
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum ArtifactKind {
    File,
    Directory,
}

#[derive(Clone, Copy)]
enum TransactionMode {
    Replace,
    Remove,
}

#[derive(Clone, Copy)]
enum EntryState {
    Ready,
    Installed,
    Swapped,
    Removed,
}

struct Entry {
    destination: PathBuf,
    staged: PathBuf,
    kind: ArtifactKind,
    state: EntryState,
}

impl Entry {
    fn transition(&mut self, next: EntryState) -> Result<(), InstallError> {
        let (source, destination, exchange) = match (self.state, next) {
            (EntryState::Ready, EntryState::Installed)
            | (EntryState::Removed, EntryState::Ready) => {
                (self.staged.clone(), self.destination.clone(), false)
            }
            (EntryState::Ready, EntryState::Removed)
            | (EntryState::Installed, EntryState::Ready) => {
                (self.destination.clone(), self.staged.clone(), false)
            }
            (EntryState::Ready, EntryState::Swapped) | (EntryState::Swapped, EntryState::Ready) => {
                (self.staged.clone(), self.destination.clone(), true)
            }
            _ => {
                return Err(invalid(
                    &self.destination,
                    "the artifact transaction entered an invalid state",
                ));
            }
        };
        if exchange {
            exchange_paths(&source, &destination)?;
        } else {
            fs::rename(&source, &destination)
                .map_err(fs_error("rename an artifact", &destination))?;
        }
        self.state = next;
        sync_rename(&source, &destination)
    }
}

struct Transaction {
    entries: Vec<Entry>,
    mode: TransactionMode,
}

impl Transaction {
    fn install(
        layout: &Layout,
        sources: &Sources,
        commands: &Commands,
    ) -> Result<Self, InstallError> {
        prepare_parents(layout)?;
        let token = temporary_token();
        let staged = staged_paths(layout, &token)?;
        let transaction = Self::new(layout, staged.clone(), TransactionMode::Replace);
        let [omabox, omaboxd, unit, plugin] = &staged;
        let result = (|| {
            copy_file(&sources.omabox, omabox, 0o755)?;
            copy_file(&sources.omaboxd, omaboxd, 0o755)?;
            write_file(unit, UNIT, 0o644)?;
            write_plugin(plugin)?;
            transaction.preflight()?;
            validate_plugin(commands, plugin)
        })();
        if let Err(source) = result {
            return Err(cleanup_failure(source, transaction.cleanup_prepared()));
        }
        Ok(transaction)
    }

    fn remove(layout: &Layout) -> Result<Self, InstallError> {
        let token = temporary_token();
        let transaction = Self::new(
            layout,
            staged_paths(layout, &token)?,
            TransactionMode::Remove,
        );
        transaction.preflight()?;
        Ok(transaction)
    }

    fn new(layout: &Layout, staged: [PathBuf; 4], mode: TransactionMode) -> Self {
        let destinations = [
            layout.omabox.clone(),
            layout.omaboxd.clone(),
            layout.unit.clone(),
            layout.plugin.clone(),
        ];
        let kinds = [
            ArtifactKind::File,
            ArtifactKind::File,
            ArtifactKind::File,
            ArtifactKind::Directory,
        ];
        let entries = destinations
            .into_iter()
            .zip(staged)
            .zip(kinds)
            .map(|((destination, staged), kind)| Entry {
                destination,
                staged,
                kind,
                state: EntryState::Ready,
            })
            .collect();
        Self { entries, mode }
    }

    fn preflight(&self) -> Result<(), InstallError> {
        for entry in &self.entries {
            if let Some(kind) = path_kind(&entry.destination)?
                && kind != entry.kind
            {
                return Err(invalid(
                    &entry.destination,
                    "an install destination has an unexpected file type",
                ));
            }
            let staged_kind = path_kind(&entry.staged)?;
            if matches!(self.mode, TransactionMode::Replace) && staged_kind != Some(entry.kind) {
                return Err(invalid(
                    &entry.staged,
                    "a prepared artifact has an unexpected file type",
                ));
            }
            if matches!(self.mode, TransactionMode::Remove) && staged_kind.is_some() {
                return Err(invalid(
                    &entry.staged,
                    "an uninstall staging path already exists",
                ));
            }
        }
        Ok(())
    }

    fn apply(&mut self, commands: &Commands) -> Result<(), InstallError> {
        self.preflight()?;
        for entry in &mut self.entries {
            let destination_exists = path_kind(&entry.destination)?.is_some();
            if entry.kind == ArtifactKind::Directory {
                ensure_shell_unlocked(commands)?;
            }
            match (self.mode, destination_exists) {
                (TransactionMode::Replace, true) => {
                    entry.transition(EntryState::Swapped)?;
                }
                (TransactionMode::Replace, false) => {
                    entry.transition(EntryState::Installed)?;
                }
                (TransactionMode::Remove, true) => {
                    entry.transition(EntryState::Removed)?;
                }
                (TransactionMode::Remove, false) => {}
            }
        }
        Ok(())
    }

    fn rollback(&mut self, commands: &Commands) -> Result<(), InstallError> {
        for entry in self.entries.iter_mut().rev() {
            match entry.state {
                EntryState::Ready => continue,
                EntryState::Installed | EntryState::Swapped | EntryState::Removed => {
                    if entry.kind == ArtifactKind::Directory {
                        ensure_shell_unlocked(commands)?;
                    }
                    entry.transition(EntryState::Ready)?;
                }
            }
        }
        Ok(())
    }

    fn cleanup_prepared(&self) -> Result<(), InstallError> {
        for entry in &self.entries {
            remove_if_present(&entry.staged, entry.kind)?;
        }
        Ok(())
    }

    fn finish(&mut self) -> Result<(), InstallError> {
        for entry in &mut self.entries {
            if matches!(entry.state, EntryState::Swapped | EntryState::Removed) {
                remove_if_present(&entry.staged, entry.kind)?;
                sync_parent(&entry.staged)?;
            }
            entry.state = EntryState::Ready;
        }
        Ok(())
    }
}

fn prepare_parents(layout: &Layout) -> Result<(), InstallError> {
    for parent in [
        layout.omabox.parent(),
        layout.unit.parent(),
        layout.plugin.parent(),
        Some(layout.omarchy_root.as_path()),
    ] {
        let Some(path) = parent else {
            return Err(invalid(
                &layout.home,
                "an install path has no parent directory",
            ));
        };
        fs::create_dir_all(path).map_err(fs_error("create an install directory", path))?;
    }
    Ok(())
}

fn write_plugin(path: &Path) -> Result<(), InstallError> {
    fs::create_dir(path).map_err(fs_error("create the prepared plugin directory", path))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o755))
        .map_err(fs_error("set prepared plugin permissions", path))?;
    for (name, contents) in PLUGIN {
        write_file(&path.join(name), contents, 0o644)?;
    }
    sync_directory(path)
}

fn validate_plugin(commands: &Commands, path: &Path) -> Result<(), InstallError> {
    let status = commands
        .omarchy
        .command()
        .args(["plugin", "validate"])
        .arg(path)
        .stdin(Stdio::null())
        .status()
        .map_err(|source| InstallError::CommandStart {
            command: "omarchy plugin validate",
            source,
        })?;
    match status.code() {
        Some(0) => Ok(()),
        Some(code) => Err(InstallError::CommandFailed {
            command: "omarchy plugin validate",
            status: Some(code),
        }),
        None => Err(InstallError::CommandFailed {
            command: "omarchy plugin validate",
            status: None,
        }),
    }
}

fn copy_file(source: &Path, path: &Path, mode: u32) -> Result<(), InstallError> {
    let mut source_file =
        File::open(source).map_err(fs_error("open an executable source", source))?;
    let mut staged = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(mode)
        .open(path)
        .map_err(fs_error("create a prepared artifact", path))?;
    let bytes = io::copy(&mut source_file, &mut staged)
        .and_then(|bytes| staged.sync_all().map(|()| bytes))
        .map_err(fs_error("copy and sync a prepared artifact", path))?;
    if bytes == 0 {
        return Err(invalid(source, "an executable source is empty"));
    }
    Ok(())
}

fn write_file(path: &Path, contents: &[u8], mode: u32) -> Result<(), InstallError> {
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(mode)
        .open(path)
        .map_err(fs_error("create a prepared artifact", path))?;
    file.write_all(contents)
        .and_then(|()| file.sync_all())
        .map_err(fs_error("write and sync a prepared artifact", path))
}

fn temporary_token() -> String {
    format!(
        "{}.{}",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    )
}

fn staged_paths(layout: &Layout, token: &str) -> Result<[PathBuf; 4], InstallError> {
    Ok([
        temporary_sibling(&layout.omabox, "install", token)?,
        temporary_sibling(&layout.omaboxd, "install", token)?,
        temporary_sibling(&layout.unit, "install", token)?,
        layout
            .omarchy_root
            .join(format!(".{PLUGIN_ID}.install.{token}")),
    ])
}

fn temporary_sibling(path: &Path, role: &str, token: &str) -> Result<PathBuf, InstallError> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid(path, "an artifact has no parent directory"))?;
    let name = path
        .file_name()
        .ok_or_else(|| invalid(path, "an artifact has no file name"))?;
    let mut temporary = OsString::from(".");
    temporary.push(name);
    temporary.push(format!(".{role}.{token}"));
    Ok(parent.join(temporary))
}

fn exchange_paths(source: &Path, destination: &Path) -> Result<(), InstallError> {
    renameat_with(CWD, source, CWD, destination, RenameFlags::EXCHANGE)
        .map_err(|source| fs_error("exchange installed artifacts", destination)(source.into()))
}

fn sync_rename(source: &Path, destination: &Path) -> Result<(), InstallError> {
    sync_parent(source)?;
    if source.parent() != destination.parent() {
        sync_parent(destination)?;
    }
    Ok(())
}

fn path_kind(path: &Path) -> Result<Option<ArtifactKind>, InstallError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => Ok(Some(ArtifactKind::Directory)),
        Ok(_) => Ok(Some(ArtifactKind::File)),
        Err(source) if source.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(fs_error("inspect an artifact path", path)(source)),
    }
}

fn remove_if_present(path: &Path, expected: ArtifactKind) -> Result<(), InstallError> {
    let Some(actual) = path_kind(path)? else {
        return Ok(());
    };
    if actual != expected {
        return Err(invalid(path, "a transaction artifact changed file type"));
    }
    match expected {
        ArtifactKind::File => fs::remove_file(path),
        ArtifactKind::Directory => fs::remove_dir_all(path),
    }
    .map_err(fs_error("remove a transaction artifact", path))
}

fn sync_parent(path: &Path) -> Result<(), InstallError> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid(path, "an artifact has no parent directory"))?;
    sync_directory(parent)
}

fn sync_directory(path: &Path) -> Result<(), InstallError> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(fs_error("sync an artifact directory", path))
}

fn fs_error<'path>(
    operation: &'static str,
    path: &'path Path,
) -> impl FnOnce(io::Error) -> InstallError + 'path {
    move |source| InstallError::Filesystem {
        operation,
        path: path.to_path_buf(),
        source,
    }
}

fn invalid(path: &Path, detail: &'static str) -> InstallError {
    InstallError::InvalidArtifact {
        path: path.to_path_buf(),
        detail,
    }
}

/// A typed install, upgrade, or uninstall failure.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum InstallError {
    #[error("HOME is not set")]
    #[diagnostic(code(omabox::install::home_unavailable))]
    HomeUnavailable,
    #[error("HOME must be absolute, but was `{path}`")]
    #[diagnostic(code(omabox::install::home_not_absolute))]
    HomeNotAbsolute { path: PathBuf },
    #[error("invalid Omabox artifact `{path}`: {detail}")]
    #[diagnostic(code(omabox::install::invalid_artifact))]
    InvalidArtifact { path: PathBuf, detail: &'static str },
    #[error("could not {operation} at `{path}`")]
    #[diagnostic(code(omabox::install::filesystem))]
    Filesystem {
        operation: &'static str,
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("could not run `{command}`")]
    #[diagnostic(code(omabox::install::command_start))]
    CommandStart {
        command: &'static str,
        #[source]
        source: io::Error,
    },
    #[error("`{command}` failed with status {status:?}")]
    #[diagnostic(code(omabox::install::command_failed))]
    CommandFailed {
        command: &'static str,
        status: Option<i32>,
    },
    #[error("the Omarchy shell is locked")]
    #[diagnostic(
        code(omabox::install::shell_locked),
        help("Unlock the session before installing, upgrading, or uninstalling the widget.")
    )]
    ShellLocked,
    #[error("Omarchy returned an unreadable shell lock state")]
    #[diagnostic(
        code(omabox::install::invalid_lock_state),
        help("Run `omarchy-shell lock isLocked`; it must print exactly true or false.")
    )]
    InvalidLockState,
    #[error(transparent)]
    #[diagnostic(transparent)]
    Service(#[from] ServiceError),
    #[error("the lifecycle operation failed and rollback also failed: {restore}")]
    #[diagnostic(code(omabox::install::rollback_failed))]
    RollbackFailed {
        #[source]
        source: Box<InstallError>,
        restore: Box<InstallError>,
    },
    #[error("the lifecycle operation failed and cleanup also failed: {cleanup}")]
    #[diagnostic(code(omabox::install::cleanup_failed))]
    CleanupFailed {
        #[source]
        source: Box<InstallError>,
        cleanup: Box<InstallError>,
    },
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use super::*;

    struct Fixture {
        _temporary: tempfile::TempDir,
        layout: Layout,
        sources: Sources,
        commands: Commands,
        systemctl: PathBuf,
        systemctl_log: PathBuf,
        omarchy_log: PathBuf,
    }

    impl Fixture {
        fn new(
            active: bool,
            enabled: bool,
            fail_reload_once: bool,
            fail_restart_once: bool,
        ) -> Result<Self, Box<dyn Error>> {
            let temporary = tempfile::TempDir::new()?;
            let home = temporary.path().join("home");
            let release = temporary.path().join("release");
            fs::create_dir(&home)?;
            fs::create_dir(&release)?;
            let sources = Sources {
                omabox: release.join("omabox"),
                omaboxd: release.join("omaboxd"),
            };
            release_artifact(&sources.omabox, b"#!/bin/sh\necho omabox\n")?;
            release_artifact(&sources.omaboxd, b"#!/bin/sh\necho omaboxd\n")?;

            let systemctl_log = temporary.path().join("systemctl.log");
            let failed_reload = temporary.path().join("reload.failed");
            let failed_restart = temporary.path().join("restart.failed");
            let systemctl = temporary.path().join("systemctl");
            fs::write(
                &systemctl,
                format!(
                    "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-active) exit {};;\n is-enabled) exit {};;\n daemon-reload) if [ {} -eq 1 ] && [ ! -e '{}' ]; then : > '{}'; exit 1; fi;;\n restart) if [ {} -eq 1 ] && [ ! -e '{}' ]; then : > '{}'; exit 1; fi;;\nesac\nexit 0\n",
                    systemctl_log.display(),
                    if active { 0 } else { 3 },
                    if enabled { 0 } else { 1 },
                    if fail_reload_once { 1 } else { 0 },
                    failed_reload.display(),
                    failed_reload.display(),
                    if fail_restart_once { 1 } else { 0 },
                    failed_restart.display(),
                    failed_restart.display(),
                ),
            )?;

            let omarchy_log = temporary.path().join("omarchy.log");
            let omarchy = temporary.path().join("omarchy");
            fs::write(
                &omarchy,
                format!("printf '%s\\n' \"$@\" > '{}'\n", omarchy_log.display()),
            )?;
            let omarchy_shell = temporary.path().join("omarchy-shell");
            fs::write(&omarchy_shell, "printf 'false\\n'\n")?;
            Ok(Self {
                layout: Layout::new(home)?,
                sources,
                commands: Commands {
                    services: ServiceCommands::scripts(&systemctl, "/unused/journalctl"),
                    omarchy: Launch::Script(omarchy),
                    omarchy_shell: Launch::Script(omarchy_shell),
                },
                systemctl,
                systemctl_log,
                omarchy_log,
                _temporary: temporary,
            })
        }

        fn old_install(&self) -> Result<(), Box<dyn Error>> {
            for path in [&self.layout.omabox, &self.layout.omaboxd, &self.layout.unit] {
                let Some(parent) = path.parent() else {
                    return Err(io::Error::other("test path had no parent").into());
                };
                fs::create_dir_all(parent)?;
                fs::write(path, b"old")?;
            }
            fs::create_dir_all(&self.layout.plugin)?;
            fs::write(self.layout.plugin.join("old.qml"), b"old")?;
            Ok(())
        }
    }

    /// Write a release artifact the installer copies but never runs.
    fn release_artifact(path: &Path, contents: &[u8]) -> Result<(), Box<dyn Error>> {
        fs::write(path, contents)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
        Ok(())
    }

    fn transaction_artifacts(
        directory: &Path,
        prefix: &str,
    ) -> Result<Vec<PathBuf>, Box<dyn Error>> {
        let mut artifacts = Vec::new();
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            if entry.file_name().to_string_lossy().starts_with(prefix) {
                artifacts.push(entry.path());
            }
        }
        Ok(artifacts)
    }

    #[test]
    fn packaged_unit_runs_the_user_installed_daemon() {
        assert!(
            UNIT.windows(b"ExecStart=%h/.local/bin/omaboxd".len())
                .any(|window| window == b"ExecStart=%h/.local/bin/omaboxd")
        );
    }

    #[test]
    fn upgrade_validates_replaces_and_preserves_service_state() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, false)?;
        fixture.old_install()?;
        let report = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        assert_eq!(
            report,
            "Omabox was upgraded. The service remains enabled and running.\n"
        );
        assert_eq!(
            fs::read(&fixture.layout.omabox)?,
            b"#!/bin/sh\necho omabox\n"
        );
        assert_eq!(
            fs::read(&fixture.layout.omaboxd)?,
            b"#!/bin/sh\necho omaboxd\n"
        );
        assert_eq!(fs::read(&fixture.layout.unit)?, UNIT);
        for (name, contents) in PLUGIN {
            assert_eq!(fs::read(fixture.layout.plugin.join(name))?, contents);
        }
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nis-active\ndaemon-reload\nrestart\n"
        );
        let validator = fs::read_to_string(&fixture.omarchy_log)?;
        let Some(staged_plugin) = validator.lines().nth(2) else {
            return Err(io::Error::other("validator did not receive a plugin path").into());
        };
        assert!(
            !Path::new(staged_plugin).starts_with(
                fixture
                    .layout
                    .plugin
                    .parent()
                    .ok_or_else(|| io::Error::other("plugin path had no parent"))?
            )
        );
        Ok(())
    }

    #[test]
    fn restart_failure_restores_old_artifacts_and_running_service() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, true)?;
        fixture.old_install()?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(matches!(result, Err(InstallError::Service(_))));
        for path in [
            &fixture.layout.omabox,
            &fixture.layout.omaboxd,
            &fixture.layout.unit,
        ] {
            assert_eq!(fs::read(path)?, b"old");
        }
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nis-active\ndaemon-reload\nrestart\ndaemon-reload\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn service_restore_failure_preserves_recovery_artifacts_and_both_errors()
    -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, false)?;
        fixture.old_install()?;
        fs::write(
            &fixture.systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-active|is-enabled) exit 0;;\n restart) exit 7;;\n start) exit 8;;\nesac\nexit 0\n",
                fixture.systemctl_log.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        match result {
            Err(InstallError::RollbackFailed { source, restore }) => {
                assert!(matches!(
                    *source,
                    InstallError::Service(ServiceError::Unsuccessful {
                        status: Some(7),
                        ..
                    })
                ));
                assert!(matches!(
                    *restore,
                    InstallError::Service(ServiceError::Unsuccessful {
                        status: Some(8),
                        ..
                    })
                ));
            }
            other => return Err(io::Error::other(format!("unexpected result: {other:?}")).into()),
        }
        for path in [
            &fixture.layout.omabox,
            &fixture.layout.omaboxd,
            &fixture.layout.unit,
        ] {
            assert_eq!(fs::read(path)?, b"old");
        }
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        let bin_parent = fixture
            .layout
            .omabox
            .parent()
            .ok_or_else(|| io::Error::other("binary path had no parent"))?;
        let recovery = transaction_artifacts(bin_parent, ".omabox.install.")?;
        assert_eq!(recovery.len(), 1);
        assert_eq!(fs::read(&recovery[0])?, b"#!/bin/sh\necho omabox\n");
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nis-active\ndaemon-reload\nrestart\ndaemon-reload\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn rollback_failure_preserves_remaining_old_backups() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, false)?;
        fixture.old_install()?;
        let unit_parent = fixture
            .layout
            .unit
            .parent()
            .ok_or_else(|| io::Error::other("unit path had no parent"))?;
        fs::write(
            &fixture.systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-active|is-enabled) exit 0;;\n restart) for backup in '{}/.omabox.service.install.'*; do if [ -e \"$backup\" ]; then rm -f -- \"$backup\"; fi; done; exit 7;;\nesac\nexit 0\n",
                fixture.systemctl_log.display(),
                unit_parent.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        match result {
            Err(InstallError::RollbackFailed { source, restore }) => {
                assert!(matches!(
                    *source,
                    InstallError::Service(ServiceError::Unsuccessful {
                        status: Some(7),
                        ..
                    })
                ));
                assert!(matches!(*restore, InstallError::Filesystem { .. }));
            }
            other => return Err(io::Error::other(format!("unexpected result: {other:?}")).into()),
        }
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        let bin_parent = fixture
            .layout
            .omabox
            .parent()
            .ok_or_else(|| io::Error::other("binary path had no parent"))?;
        let omabox_backup = transaction_artifacts(bin_parent, ".omabox.install.")?;
        let daemon_backup = transaction_artifacts(bin_parent, ".omaboxd.install.")?;
        assert_eq!(omabox_backup.len(), 1);
        assert_eq!(daemon_backup.len(), 1);
        assert_eq!(fs::read(&omabox_backup[0])?, b"old");
        assert_eq!(fs::read(&daemon_backup[0])?, b"old");
        Ok(())
    }

    #[test]
    fn lock_transition_during_rollback_preserves_live_and_backup_plugins()
    -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, true)?;
        fixture.old_install()?;
        let lock_checks = fixture._temporary.path().join("rollback-lock-checks");
        fs::write(
            fixture.commands.omarchy_shell.path(),
            format!(
                "count=0\nif [ -f '{}' ]; then read count < '{}'; fi\ncount=$((count + 1))\nprintf '%s\\n' \"$count\" > '{}'\nif [ \"$count\" -lt 4 ]; then printf 'false\\n'; else printf 'true\\n'; fi\n",
                lock_checks.display(),
                lock_checks.display(),
                lock_checks.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        match result {
            Err(InstallError::RollbackFailed { source, restore }) => {
                assert!(matches!(*source, InstallError::Service(_)));
                assert!(matches!(*restore, InstallError::ShellLocked));
            }
            other => return Err(io::Error::other(format!("unexpected result: {other:?}")).into()),
        }
        assert!(!fixture.layout.plugin.join("old.qml").exists());
        for (name, contents) in PLUGIN {
            assert_eq!(fs::read(fixture.layout.plugin.join(name))?, contents);
        }
        let plugin_backup =
            transaction_artifacts(&fixture.layout.omarchy_root, ".local.omabox.install.")?;
        assert_eq!(plugin_backup.len(), 1);
        assert_eq!(fs::read(plugin_backup[0].join("old.qml"))?, b"old");
        assert_eq!(fs::read_to_string(lock_checks)?, "4\n");
        Ok(())
    }

    #[test]
    fn fresh_install_publishes_missing_artifacts_and_stays_stopped() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(false, false, false, false)?;
        let report = execute_with(
            InstallAction::Install,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        assert_eq!(
            report,
            "Omabox was installed. The service remains disabled and stopped.\n"
        );
        assert_eq!(
            fs::read(&fixture.layout.omabox)?,
            b"#!/bin/sh\necho omabox\n"
        );
        assert_eq!(
            fs::read(&fixture.layout.omaboxd)?,
            b"#!/bin/sh\necho omaboxd\n"
        );
        assert_eq!(fs::read(&fixture.layout.unit)?, UNIT);
        assert!(fixture.layout.plugin.join("Panel.qml").is_file());
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nis-active\ndaemon-reload\n"
        );
        Ok(())
    }

    #[test]
    fn reload_failure_restores_old_artifacts_before_restart() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, true, false)?;
        fixture.old_install()?;
        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(matches!(result, Err(InstallError::Service(_))));
        for path in [
            &fixture.layout.omabox,
            &fixture.layout.omaboxd,
            &fixture.layout.unit,
        ] {
            assert_eq!(fs::read(path)?, b"old");
        }
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nis-active\ndaemon-reload\ndaemon-reload\n"
        );
        Ok(())
    }

    #[test]
    fn validation_failure_changes_nothing_live() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, false)?;
        fixture.old_install()?;
        fs::write(fixture.commands.omarchy.path(), "exit 9\n")?;
        let result = execute_with(
            InstallAction::Install,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(
            matches!(
                result,
                Err(InstallError::CommandFailed {
                    status: Some(9),
                    ..
                })
            ),
            "plugin validation reported {result:?}"
        );
        assert_eq!(fs::read(&fixture.layout.omabox)?, b"old");
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        assert!(!fixture.systemctl_log.exists());
        Ok(())
    }

    #[test]
    fn empty_daemon_is_rejected_before_any_live_change() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(false, false, false, false)?;
        fs::write(&fixture.sources.omaboxd, [])?;
        let result = execute_with(
            InstallAction::Install,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(matches!(result, Err(InstallError::InvalidArtifact { .. })));
        assert!(!fixture.layout.omabox.exists());
        assert!(!fixture.layout.plugin.exists());
        assert!(!fixture.systemctl_log.exists());
        Ok(())
    }

    #[test]
    fn locked_shell_prevents_any_live_artifact_change() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, false)?;
        fixture.old_install()?;
        fs::write(fixture.commands.omarchy_shell.path(), "printf 'true\\n'\n")?;
        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(matches!(result, Err(InstallError::ShellLocked)));
        assert_eq!(fs::read(&fixture.layout.omabox)?, b"old");
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        assert!(!fixture.systemctl_log.exists());
        Ok(())
    }

    #[test]
    fn lock_before_plugin_restores_earlier_artifacts_and_service() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, false)?;
        fixture.old_install()?;
        let lock_checks = fixture._temporary.path().join("lock-checks");
        fs::write(
            fixture.commands.omarchy_shell.path(),
            format!(
                "count=0\nif [ -f '{}' ]; then read count < '{}'; fi\ncount=$((count + 1))\nprintf '%s\\n' \"$count\" > '{}'\nif [ \"$count\" -lt 3 ]; then printf 'false\\n'; else printf 'true\\n'; fi\n",
                lock_checks.display(),
                lock_checks.display(),
                lock_checks.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Uninstall,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(matches!(result, Err(InstallError::ShellLocked)));
        for path in [
            &fixture.layout.omabox,
            &fixture.layout.omaboxd,
            &fixture.layout.unit,
        ] {
            assert_eq!(fs::read(path)?, b"old");
        }
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        assert_eq!(fs::read_to_string(lock_checks)?, "3\n");
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nis-active\nstop\ndisable\ndaemon-reload\nenable\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn uninstall_removes_only_artifacts_and_retains_user_data() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new(true, true, false, false)?;
        fixture.old_install()?;
        let retained = [
            fixture.layout.home.join(".config/omabox/config.toml"),
            fixture
                .layout
                .home
                .join(".local/state/omabox/journal.sqlite3"),
            fixture
                .layout
                .home
                .join(".local/state/omabox/recovery/copy"),
            fixture.layout.home.join("Dropbox/file.txt"),
        ];
        for path in &retained {
            let Some(parent) = path.parent() else {
                return Err(io::Error::other("retained path had no parent").into());
            };
            fs::create_dir_all(parent)?;
            fs::write(path, b"retained")?;
        }
        let report = execute_with(
            InstallAction::Uninstall,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        for path in [
            &fixture.layout.omabox,
            &fixture.layout.omaboxd,
            &fixture.layout.unit,
            &fixture.layout.plugin,
        ] {
            assert!(!path.exists());
        }
        for path in &retained {
            assert_eq!(fs::read(path)?, b"retained");
        }
        assert!(report.contains("Secret Service credentials"));
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nis-active\nstop\ndisable\ndaemon-reload\n"
        );
        Ok(())
    }
}
