//! Rootless installation of the Omabox binaries, service unit, and Omarchy plugin.

use std::env;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write as _};
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use miette::Diagnostic;
use rustix::fs::{CWD, RenameFlags, renameat_with};
use thiserror::Error;

use crate::config::resolve_config_home;
use crate::service::{ServiceCommands, ServiceError, ServiceGoal, UnitState};
use crate::spawn::Launch;
use crate::stale::{self, Leftover};

const UNIT: &[u8] = include_bytes!("../packaging/systemd/omabox.service");
// A concurrent child can briefly inherit the staged file's writable descriptor
// between fork and exec, even though the descriptor is close-on-exec.
const DAEMON_SELF_CHECK_ATTEMPTS: usize = 5;
const DAEMON_SELF_CHECK_RETRY_DELAY: Duration = Duration::from_millis(10);
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
    let layout = Layout::new(
        PathBuf::from(env::var_os("HOME").ok_or(InstallError::HomeUnavailable)?),
        env::var_os("XDG_CONFIG_HOME"),
    )?;
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
    /// Resolve install paths for an absolute `home`.
    ///
    /// systemd reads user units from the XDG config home, resolved from
    /// `xdg_config_home` as for the Omabox config. Omarchy reads plugins only
    /// from `~/.config/omarchy/plugins`, whatever `XDG_CONFIG_HOME` is.
    fn new(home: PathBuf, xdg_config_home: Option<OsString>) -> Result<Self, InstallError> {
        if !home.is_absolute() {
            return Err(InstallError::HomeNotAbsolute { path: home });
        }
        let omarchy_root = home.join(".config/omarchy");
        let config_home = resolve_config_home(&home, xdg_config_home);
        Ok(Self {
            omabox: home.join(".local/bin/omabox"),
            omaboxd: home.join(".local/bin/omaboxd"),
            unit: config_home.join("systemd/user/omabox.service"),
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
    unit: UnitState,
}

impl ServiceState {
    fn read(commands: &Commands) -> Result<Self, InstallError> {
        Ok(Self {
            enabled: commands.services.is_enabled()?,
            unit: commands.services.state()?,
        })
    }

    fn restore(self, commands: &Commands, restore_enabled: bool) -> Result<(), InstallError> {
        if restore_enabled && self.enabled {
            commands.services.enable()?;
        }
        commands
            .services
            .drive(ServiceGoal::Restore(Some(self.unit)))?;
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
    let done = if action == InstallAction::Install {
        "installed"
    } else {
        "upgraded"
    };
    let enabled = if state.enabled { "enabled" } else { "disabled" };

    let report = match state.unit {
        // A service that reached readiness shows the old build worked, so a failed restart rolls back to it.
        UnitState::Running => {
            if let Err(source) = commands.services.drive(ServiceGoal::Restart) {
                return Err(restore_after_failure(
                    InstallError::Service(source),
                    &mut transaction,
                    commands,
                    state,
                    false,
                    true,
                ));
            }
            if let Err(source) = transaction.finish() {
                return Err(InstallError::CleanupAfterChange {
                    done,
                    source: Box::new(source),
                });
            }
            format!("Omabox was {done}. The service remains {enabled} and running.\n")
        }
        // A starting service has not shown the old build works and may still run it, so the new build is kept and replaces it.
        UnitState::Starting => {
            transaction.finish()?;
            commands
                .services
                .drive(ServiceGoal::Restart)
                .map_err(|source| InstallError::StartAfterChange { done, source })?;
            format!("Omabox was {done}. The service remains {enabled} and running.\n")
        }
        // A failed unit usually stopped for a cause the old build shares, so the new build is kept before Recover starts it.
        UnitState::Failed | UnitState::Stopping | UnitState::Stopped => {
            transaction.finish()?;
            let driven = commands
                .services
                .drive(ServiceGoal::Recover)
                .map_err(|source| InstallError::StartAfterChange { done, source })?;
            if driven.launched {
                format!(
                    "Omabox was {done}. The service remains {enabled}. The stopped service has been started again.\n"
                )
            } else {
                format!("Omabox was {done}. The service remains {enabled} and stopped.\n")
            }
        }
    };
    Ok(report + &stale::report(&transaction.leftovers))
}

fn uninstall(layout: &Layout, commands: &Commands) -> Result<String, InstallError> {
    let mut transaction = Transaction::remove(layout)?;
    ensure_shell_unlocked(commands)?;
    let state = ServiceState::read(commands)?;
    // Leave no failed unit behind once its files are gone.
    let released = commands.services.drive(ServiceGoal::Halt).and_then(|_| {
        if state.enabled {
            commands.services.disable()
        } else {
            Ok(())
        }
    });
    if let Err(source) = released {
        let source = InstallError::Service(source);
        return Err(rollback_failure(source, state.restore(commands, true)));
    }
    publish(&mut transaction, commands, state, true)?;
    transaction.finish()?;
    Ok(String::from(
        "Omabox program, service, and plugin files were removed. Configuration, the journal, recovery data, Secret Service credentials, and synced files were retained.\n",
    ) + &stale::report(&transaction.leftovers))
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
            restore: Box::new([restore]),
        },
    }
}

fn cleanup_failure(source: InstallError, cleanup: Result<(), InstallError>) -> InstallError {
    match cleanup {
        Ok(()) => source,
        Err(cleanup) => InstallError::CleanupFailed {
            source: Box::new(source),
            cleanup: Box::new([cleanup]),
        },
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum ArtifactKind {
    File,
    Directory,
}

/// What `path_kind` found at a path, which may be a kind no artifact has.
#[derive(Clone, Copy, Eq, PartialEq)]
enum Observed {
    File,
    Directory,
    Symlink,
}

impl From<ArtifactKind> for Observed {
    fn from(kind: ArtifactKind) -> Self {
        match kind {
            ArtifactKind::File => Self::File,
            ArtifactKind::Directory => Self::Directory,
        }
    }
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

    /// Refuse a destination that is a symlink or another kind than this artifact, returning whether it exists.
    fn check_destination(&self) -> Result<bool, InstallError> {
        match path_kind(&self.destination)? {
            None => Ok(false),
            Some(Observed::Symlink) => Err(InstallError::DestinationSymlink {
                path: self.destination.clone(),
            }),
            Some(kind) if kind != Observed::from(self.kind) => Err(invalid(
                &self.destination,
                "an install destination has an unexpected file type",
            )),
            Some(_) => Ok(true),
        }
    }
}

struct Transaction {
    entries: Vec<Entry>,
    mode: TransactionMode,
    /// What the sweep before this transaction could not remove.
    leftovers: Vec<Leftover>,
}

impl Transaction {
    fn install(
        layout: &Layout,
        sources: &Sources,
        commands: &Commands,
    ) -> Result<Self, InstallError> {
        let token = temporary_token();
        let staged = staged_paths(layout, &token)?;
        let mut transaction =
            Self::new(layout, staged.clone(), TransactionMode::Replace, Vec::new());
        // Refuse before creating any directory or staged copy, and before the
        // sweep removes anything.
        refuse_self_install(&sources.omabox, &layout.omabox)?;
        refuse_self_install(&sources.omaboxd, &layout.omaboxd)?;
        transaction.check_destinations()?;
        prepare_parents(layout)?;
        transaction.leftovers = sweep_stale(layout)?;
        let [omabox, omaboxd, unit, plugin] = &staged;
        let result = (|| {
            copy_file(&sources.omabox, omabox, 0o755)?;
            copy_file(&sources.omaboxd, omaboxd, 0o755)?;
            write_file(unit, UNIT, 0o644)?;
            write_plugin(plugin)?;
            transaction.preflight()?;
            validate_daemon(omaboxd)?;
            validate_plugin(commands, plugin)
        })();
        if let Err(source) = result {
            return Err(cleanup_failure(source, transaction.cleanup_prepared()));
        }
        Ok(transaction)
    }

    fn remove(layout: &Layout) -> Result<Self, InstallError> {
        let leftovers = sweep_stale(layout)?;
        let token = temporary_token();
        let transaction = Self::new(
            layout,
            staged_paths(layout, &token)?,
            TransactionMode::Remove,
            leftovers,
        );
        transaction.preflight()?;
        Ok(transaction)
    }

    fn new(
        layout: &Layout,
        staged: [PathBuf; 4],
        mode: TransactionMode,
        leftovers: Vec<Leftover>,
    ) -> Self {
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
        Self {
            entries,
            mode,
            leftovers,
        }
    }

    fn check_destinations(&self) -> Result<(), InstallError> {
        for entry in &self.entries {
            entry.check_destination()?;
        }
        Ok(())
    }

    fn preflight(&self) -> Result<(), InstallError> {
        self.check_destinations()?;
        for entry in &self.entries {
            let staged_kind = path_kind(&entry.staged)?;
            if matches!(self.mode, TransactionMode::Replace)
                && staged_kind != Some(Observed::from(entry.kind))
            {
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
            if entry.kind == ArtifactKind::Directory {
                ensure_shell_unlocked(commands)?;
            }
            // Read after the lock check, which runs another program that may change the destination.
            let destination_exists = entry.check_destination()?;
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

/// Refuse a source that is its own destination, such as the installed `omabox` upgrading itself.
fn refuse_self_install(source: &Path, destination: &Path) -> Result<(), InstallError> {
    let installed = match fs::symlink_metadata(destination) {
        Ok(metadata) => metadata,
        Err(source) if source.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(source) => {
            return Err(fs_error("inspect an install destination", destination)(
                source,
            ));
        }
    };
    let running = fs::metadata(source).map_err(fs_error("inspect an executable source", source))?;
    if (running.dev(), running.ino()) == (installed.dev(), installed.ino()) {
        return Err(InstallError::SourceIsDestination {
            path: destination.to_path_buf(),
        });
    }
    Ok(())
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

fn validate_daemon(path: &Path) -> Result<(), InstallError> {
    validate_daemon_with(path, &mut std::thread::sleep)
}

fn validate_daemon_with(path: &Path, wait: &mut impl FnMut(Duration)) -> Result<(), InstallError> {
    let mut attempts_remaining = DAEMON_SELF_CHECK_ATTEMPTS;
    loop {
        let status = std::process::Command::new(path)
            .arg("--self-check")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        match status {
            Ok(status) => {
                return match status.code() {
                    Some(0) => Ok(()),
                    status => Err(InstallError::DaemonSelfCheckFailed { status }),
                };
            }
            Err(source)
                if source.raw_os_error() == Some(rustix::io::Errno::TXTBSY.raw_os_error())
                    && attempts_remaining > 1 =>
            {
                attempts_remaining -= 1;
                wait(DAEMON_SELF_CHECK_RETRY_DELAY);
            }
            Err(source) => return Err(InstallError::DaemonSelfCheckStart { source }),
        }
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

/// Remove the staged artifacts and backups that a killed or failed run left
/// behind, and return what could not be removed. Only a layout without an
/// artifact directory fails; the sweep itself never does.
fn sweep_stale(layout: &Layout) -> Result<Vec<Leftover>, InstallError> {
    let mut leftovers = Vec::new();
    // An empty token turns each staged path into the prefix its names share.
    for prefix in staged_paths(layout, "")? {
        let (Some(directory), Some(name)) = (prefix.parent(), prefix.file_name()) else {
            return Err(invalid(&prefix, "an artifact has no parent directory"));
        };
        leftovers.extend(stale::sweep(directory, name.as_bytes(), b""));
    }
    Ok(leftovers)
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

fn path_kind(path: &Path) -> Result<Option<Observed>, InstallError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => Ok(Some(Observed::Directory)),
        Ok(metadata) if metadata.file_type().is_symlink() => Ok(Some(Observed::Symlink)),
        Ok(_) => Ok(Some(Observed::File)),
        Err(source) if source.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(fs_error("inspect an artifact path", path)(source)),
    }
}

fn remove_if_present(path: &Path, expected: ArtifactKind) -> Result<(), InstallError> {
    let Some(actual) = path_kind(path)? else {
        return Ok(());
    };
    if actual != Observed::from(expected) {
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
    #[diagnostic(
        code(omabox::install::home_unavailable),
        help("Set HOME to your absolute home directory, then retry.")
    )]
    HomeUnavailable,
    #[error("HOME must be absolute, but was `{path}`")]
    #[diagnostic(
        code(omabox::install::home_not_absolute),
        help("Set HOME to your absolute home directory, then retry.")
    )]
    HomeNotAbsolute { path: PathBuf },
    #[error("invalid Omabox artifact `{path}`: {detail}")]
    #[diagnostic(
        code(omabox::install::invalid_artifact),
        help(
            "Rebuild Omabox if the path belongs to the new build; otherwise ensure only the file or directory Omabox installed is at that path. Then retry."
        )
    )]
    InvalidArtifact { path: PathBuf, detail: &'static str },
    #[error("the install destination `{path}` is a symbolic link")]
    #[diagnostic(
        code(omabox::install::destination_symlink),
        help(
            "Omabox installs real files at this path. Remove the link, or replace it with the file or directory it points to, then retry."
        )
    )]
    DestinationSymlink { path: PathBuf },
    #[error("the install source is the installed file `{path}`")]
    #[diagnostic(
        code(omabox::install::source_is_destination),
        help(
            "Run this command from the new build, such as `target/release/omabox`, rather than from the installed copy."
        )
    )]
    SourceIsDestination { path: PathBuf },
    #[error("could not {operation} at `{path}`")]
    #[diagnostic(
        code(omabox::install::filesystem),
        help("Ensure the path is accessible and its filesystem has free space, then retry.")
    )]
    Filesystem {
        operation: &'static str,
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("could not run `{command}`")]
    #[diagnostic(
        code(omabox::install::command_start),
        help("Ensure Omarchy is installed and its commands are on PATH, then retry.")
    )]
    CommandStart {
        command: &'static str,
        #[source]
        source: io::Error,
    },
    #[error("`{command}` failed with status {status:?}")]
    #[diagnostic(
        code(omabox::install::command_failed),
        help("Run the named command yourself to see its error, fix the cause, then retry.")
    )]
    CommandFailed {
        command: &'static str,
        status: Option<i32>,
    },
    #[error("could not start the staged Omabox daemon self-check")]
    #[diagnostic(
        code(omabox::install::daemon_self_check_start),
        help("Rebuild Omabox and retry the installation.")
    )]
    DaemonSelfCheckStart {
        #[source]
        source: io::Error,
    },
    #[error("the staged Omabox daemon self-check failed with status {status:?}")]
    #[diagnostic(
        code(omabox::install::daemon_self_check_failed),
        help("Rebuild Omabox and retry the installation.")
    )]
    DaemonSelfCheckFailed { status: Option<i32> },
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
    #[error("Omabox was {done}, but the Omabox service could not be started or checked")]
    #[diagnostic(
        code(omabox::install::start_after_change),
        help(
            "The new build is kept. Run `omabox status` and `omabox logs` to see why, then `omabox resume`."
        )
    )]
    StartAfterChange {
        done: &'static str,
        #[source]
        source: ServiceError,
    },
    #[error(
        "Omabox was {done} and the service runs the new build, but the replaced files could not be removed"
    )]
    #[diagnostic(
        code(omabox::install::cleanup_after_change),
        help("The next install, upgrade or uninstall removes the leftover files.")
    )]
    CleanupAfterChange {
        done: &'static str,
        #[source]
        source: Box<InstallError>,
    },
    #[error("the lifecycle operation failed and rollback also failed: {}", .restore[0])]
    #[diagnostic(
        code(omabox::install::rollback_failed),
        help(
            "Run `omabox status` and `omabox logs` to see the service state, then rerun the same install, upgrade, or uninstall command."
        )
    )]
    RollbackFailed {
        #[source]
        source: Box<InstallError>,
        /// The single rollback failure, rendered as a related diagnostic.
        #[related]
        restore: Box<[InstallError; 1]>,
    },
    #[error("the lifecycle operation failed and cleanup also failed: {}", .cleanup[0])]
    #[diagnostic(
        code(omabox::install::cleanup_failed),
        help("Address the first error, then run the install or upgrade again from the new build.")
    )]
    CleanupFailed {
        #[source]
        source: Box<InstallError>,
        /// The single cleanup failure, rendered as a related diagnostic.
        #[related]
        cleanup: Box<[InstallError; 1]>,
    },
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use super::*;
    use crate::config::{Config, XdgDirectories};

    const VALID_DAEMON: &[u8] = b"#!/bin/sh\nif [ \"$#\" -eq 1 ] && [ \"$1\" = --self-check ]; then printf 'omaboxd 0.1.0\\n'; exit 0; fi\nexit 64\n";

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
            active_state: &str,
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
            release_artifact(&sources.omaboxd, VALID_DAEMON)?;

            let systemctl_log = temporary.path().join("systemctl.log");
            let failed_reload = temporary.path().join("reload.failed");
            let failed_restart = temporary.path().join("restart.failed");
            let systemctl = temporary.path().join("systemctl");
            fs::write(
                &systemctl,
                format!(
                    "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n show) printf '%s\\n' '{}';;\n is-enabled) exit {};;\n daemon-reload) if [ {} -eq 1 ] && [ ! -e '{}' ]; then : > '{}'; exit 1; fi;;\n restart) if [ {} -eq 1 ] && [ ! -e '{}' ]; then : > '{}'; exit 1; fi;;\nesac\nexit 0\n",
                    systemctl_log.display(),
                    active_state,
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
                layout: Layout::new(home, None)?,
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
    fn unit_follows_xdg_config_home_but_plugin_stays_in_omarchy() -> Result<(), Box<dyn Error>> {
        let home = PathBuf::from("/home/user");
        let plugin = home.join(".config/omarchy/plugins").join(PLUGIN_ID);

        let layout = Layout::new(home.clone(), Some(OsString::from("/xdg/config")))?;
        assert_eq!(
            layout.unit,
            Path::new("/xdg/config/systemd/user/omabox.service")
        );
        assert_eq!(layout.plugin, plugin);
        assert_eq!(layout.omarchy_root, home.join(".config/omarchy"));

        for ignored in [OsString::new(), OsString::from("relative/config")] {
            let layout = Layout::new(home.clone(), Some(ignored))?;
            assert_eq!(
                layout.unit,
                home.join(".config/systemd/user/omabox.service")
            );
            assert_eq!(layout.plugin, plugin);
        }
        Ok(())
    }

    #[test]
    fn packaged_unit_runs_the_user_installed_daemon() {
        for directive in [
            b"After=graphical-session.target".as_slice(),
            b"StartLimitIntervalSec=10min".as_slice(),
            b"StartLimitBurst=5".as_slice(),
            b"Type=notify".as_slice(),
            b"ExecStartPre=-/usr/bin/rm -f %t/omabox/status.json".as_slice(),
            b"ExecStart=%h/.local/bin/omaboxd".as_slice(),
            br#"ExecStopPost=-/bin/sh -c 'if [ "$$SERVICE_RESULT" = success ]; then exec /usr/bin/rm -f "%t/omabox/status.json"; fi'"#.as_slice(),
            b"RestartPreventExitStatus=70 78".as_slice(),
            b"TimeoutStartSec=5min".as_slice(),
        ] {
            assert!(
                UNIT.windows(directive.len())
                    .any(|window| window == directive)
            );
        }
    }

    #[test]
    fn stop_post_keeps_the_status_only_after_a_failed_stop() -> Result<(), Box<dyn Error>> {
        let unit = std::str::from_utf8(UNIT)?;
        let Some(line) = unit
            .lines()
            .find_map(|line| line.strip_prefix("ExecStopPost=-/bin/sh -c "))
        else {
            return Err(io::Error::other("unit had no ExecStopPost=-/bin/sh -c line").into());
        };
        let (Some(first), Some(last)) = (line.find('\''), line.rfind('\'')) else {
            return Err(io::Error::other("ExecStopPost script was not quoted").into());
        };
        if first == last {
            return Err(io::Error::other("ExecStopPost script had one quote").into());
        }
        let runtime = tempfile::TempDir::new()?;
        let Some(runtime_path) = runtime.path().to_str() else {
            return Err(io::Error::other("runtime path was not UTF-8").into());
        };
        let script = line[first + 1..last]
            .replace("$$", "$")
            .replace("%t", runtime_path);
        let status = runtime.path().join("omabox").join("status.json");
        fs::create_dir(runtime.path().join("omabox"))?;
        fs::write(&status, b"{}")?;

        for (result, kept) in [("exit-code", true), ("success", false)] {
            let exit = std::process::Command::new("/bin/sh")
                .arg("-c")
                .arg(&script)
                .env("SERVICE_RESULT", result)
                .status()?;
            assert!(exit.success(), "ExecStopPost failed for {result}: {exit}");
            assert_eq!(status.exists(), kept, "status kept after {result}");
        }
        Ok(())
    }

    #[test]
    fn upgrade_validates_replaces_and_preserves_service_state() -> Result<(), Box<dyn Error>> {
        for state in ["active", "activating"] {
            let fixture = Fixture::new(state, true, false, false)?;
            fixture.old_install()?;
            let report = execute_with(
                InstallAction::Upgrade,
                &fixture.layout,
                &fixture.sources,
                &fixture.commands,
            )?;

            assert_eq!(
                report, "Omabox was upgraded. The service remains enabled and running.\n",
                "{state}"
            );
            assert_eq!(
                fs::read(&fixture.layout.omabox)?,
                b"#!/bin/sh\necho omabox\n",
                "{state}"
            );
            assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON, "{state}");
            assert_eq!(fs::read(&fixture.layout.unit)?, UNIT, "{state}");
            for (name, contents) in PLUGIN {
                assert_eq!(
                    fs::read(fixture.layout.plugin.join(name))?,
                    contents,
                    "{state}"
                );
            }
            assert_eq!(
                fs::read_to_string(&fixture.systemctl_log)?,
                "is-enabled\nshow\ndaemon-reload\nreset-failed\nrestart\n",
                "{state}"
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
                ),
                "{state}"
            );
        }
        Ok(())
    }

    #[test]
    fn restart_failure_restores_old_artifacts_and_running_service() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, true)?;
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
            "is-enabled\nshow\ndaemon-reload\nreset-failed\nrestart\ndaemon-reload\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn service_restore_failure_preserves_recovery_artifacts_and_both_errors()
    -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        fs::write(
            &fixture.systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-enabled) exit 0;;\n show) printf 'active\\n';;\n restart) exit 7;;\n start) exit 8;;\nesac\nexit 0\n",
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
                    restore[0],
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
            "is-enabled\nshow\ndaemon-reload\nreset-failed\nrestart\ndaemon-reload\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn rollback_failure_preserves_remaining_old_backups() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        let unit_parent = fixture
            .layout
            .unit
            .parent()
            .ok_or_else(|| io::Error::other("unit path had no parent"))?;
        fs::write(
            &fixture.systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-enabled) exit 0;;\n show) printf 'active\\n';;\n restart) for backup in '{}/.omabox.service.install.'*; do if [ -e \"$backup\" ]; then rm -f -- \"$backup\"; fi; done; exit 7;;\nesac\nexit 0\n",
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
                assert!(matches!(restore[0], InstallError::Filesystem { .. }));
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
    fn upgrade_and_config_write_sweep_only_dead_temporaries() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        let root = fixture._temporary.path();
        let pid_max: u32 = fs::read_to_string("/proc/sys/kernel/pid_max")?
            .trim()
            .parse()?;
        let dead = format!("{}.0", pid_max + 1);
        let live = format!("{}.999999999", std::process::id());
        let Some(bin) = fixture.layout.omabox.parent() else {
            return Err(io::Error::other("binary path had no parent").into());
        };
        let Some(unit) = fixture.layout.unit.parent() else {
            return Err(io::Error::other("unit path had no parent").into());
        };
        let omarchy = fixture.layout.omarchy_root.as_path();
        let xdg = XdgDirectories::new(root.join("xdg-config"), root.join("xdg-state"))?;
        let config_file = xdg.config_file();
        let Some(config) = config_file.parent() else {
            return Err(io::Error::other("config path had no parent").into());
        };
        fs::create_dir_all(config)?;
        let sync_root = root.join("Dropbox");
        fs::create_dir(&sync_root)?;

        let outside_directory = root.join("outside-directory");
        fs::create_dir(&outside_directory)?;
        fs::write(outside_directory.join("kept"), b"outside")?;
        let outside_file = root.join("outside-file");
        fs::write(&outside_file, b"outside")?;

        let stale_plugin = omarchy.join(format!(".local.omabox.install.{dead}"));
        fs::create_dir(&stale_plugin)?;
        fs::write(stale_plugin.join("Panel.qml"), b"old")?;
        std::os::unix::fs::symlink(&outside_directory, stale_plugin.join("link"))?;
        let removed = [
            bin.join(format!(".omabox.install.{dead}")),
            bin.join(format!(".omaboxd.install.{dead}")),
            unit.join(format!(".omabox.service.install.{dead}")),
            stale_plugin,
            config.join(format!(".config.toml.{dead}.tmp")),
            config.join(format!(".config.toml.{}.1.tmp", pid_max + 1)),
        ];
        let kept = [
            bin.join(format!(".omabox.install.{live}")),
            bin.join(format!(".omaboxd.install.{live}")),
            unit.join(format!(".omabox.service.install.{live}")),
            omarchy.join(format!(".local.omabox.install.{live}")),
            config.join(format!(".config.toml.{live}.tmp")),
            // Near misses with a dead PID do not match the exact pattern.
            bin.join(format!(".omabox.install.{dead}.1")),
            bin.join(format!(".omabox.install.{}", pid_max + 1)),
            bin.join(format!(".omabox.install.0{dead}")),
            config.join(format!(".config.toml.{dead}")),
        ];
        for path in [&removed[0], &removed[2], &removed[4]]
            .into_iter()
            .chain(&kept)
        {
            fs::write(path, b"stale")?;
        }
        for link in [&removed[1], &removed[5]] {
            std::os::unix::fs::symlink(&outside_file, link)?;
        }

        execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;
        Config::from_values(&xdg, &sync_root, "test-app-key")?.write()?;

        for path in &removed {
            assert!(fs::symlink_metadata(path).is_err(), "{}", path.display());
        }
        for path in &kept {
            assert_eq!(fs::read(path)?, b"stale", "{}", path.display());
        }
        assert_eq!(fs::read(outside_directory.join("kept"))?, b"outside");
        assert_eq!(fs::read_dir(&outside_directory)?.count(), 1);
        assert_eq!(fs::read(&outside_file)?, b"outside");
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        Ok(())
    }

    #[test]
    fn an_unremovable_stale_temporary_is_reported_and_left_in_place() -> Result<(), Box<dyn Error>>
    {
        // Root removes entries from a read-only directory, so nothing would stay.
        if rustix::process::geteuid().is_root() {
            return Ok(());
        }
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        let root = fixture._temporary.path();
        let pid_max: u32 = fs::read_to_string("/proc/sys/kernel/pid_max")?
            .trim()
            .parse()?;
        let dead = format!("{}.0", pid_max + 1);
        let xdg = XdgDirectories::new(root.join("xdg-config"), root.join("xdg-state"))?;
        let config_file = xdg.config_file();
        let Some(config) = config_file.parent() else {
            return Err(io::Error::other("config path had no parent").into());
        };
        fs::create_dir_all(config)?;
        let sync_root = root.join("Dropbox");
        fs::create_dir(&sync_root)?;

        // A file inside a directory without write permission cannot be removed.
        let stale_plugin = fixture
            .layout
            .omarchy_root
            .join(format!(".local.omabox.install.{dead}"));
        let stale_config = config.join(format!(".config.toml.{dead}.tmp"));
        let mut locked = Vec::new();
        for stale in [&stale_plugin, &stale_config] {
            let subdirectory = stale.join("locked");
            fs::create_dir_all(&subdirectory)?;
            fs::write(subdirectory.join("Panel.qml"), b"old")?;
            fs::set_permissions(&subdirectory, fs::Permissions::from_mode(0o500))?;
            locked.push(subdirectory);
        }

        let upgraded = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );
        let written = Config::from_values(&xdg, &sync_root, "test-app-key")?.write();
        let present = [&stale_plugin, &stale_config].map(|path| path.exists());
        // Let the temporary directory remove the fixture.
        for subdirectory in &locked {
            fs::set_permissions(subdirectory, fs::Permissions::from_mode(0o700))?;
        }

        let report = upgraded?;
        let leftover = |path: &Path| {
            format!(
                "Left a stale temporary in place: could not remove a stale temporary `{}`: ",
                path.display()
            )
        };
        let Some((summary, left)) = report.split_once('\n') else {
            return Err(io::Error::other(format!("unexpected report: {report}")).into());
        };
        assert_eq!(
            summary,
            "Omabox was upgraded. The service remains enabled and running."
        );
        assert!(left.starts_with(&leftover(&stale_plugin)), "{report}");
        assert_eq!(left.lines().count(), 1, "{report}");
        let leftovers = written?;
        assert_eq!(leftovers.len(), 1, "{leftovers:?}");
        assert_eq!(leftovers[0].path, stale_config);
        assert_eq!(leftovers[0].operation, "remove a stale temporary");
        assert_eq!(leftovers[0].source.kind(), io::ErrorKind::PermissionDenied);
        assert!(
            format!("Left a stale temporary in place: {}\n", leftovers[0])
                .starts_with(&leftover(&stale_config))
        );
        assert_eq!(present, [true, true]);
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        assert_eq!(Config::load_from(&xdg)?.sync_root(), sync_root);
        Ok(())
    }

    #[test]
    fn finish_failure_after_restart_reports_the_completed_upgrade() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        let Some(bin) = fixture.layout.omabox.parent() else {
            return Err(io::Error::other("binary path had no parent").into());
        };
        // The restart succeeds after turning the old build's backup into a
        // directory, so finish() cannot remove it as the file it staged.
        fs::write(
            &fixture.systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-enabled) exit 0;;\n show) printf 'active\\n';;\n restart) for backup in '{}/.omabox.install.'*; do rm -f -- \"$backup\"; mkdir -- \"$backup\"; done;;\nesac\nexit 0\n",
                fixture.systemctl_log.display(),
                bin.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        let error = match result {
            Err(error @ InstallError::CleanupAfterChange { .. }) => error,
            other => return Err(io::Error::other(format!("unexpected result: {other:?}")).into()),
        };
        let InstallError::CleanupAfterChange { done, source } = &error else {
            return Err(io::Error::other("the error changed variant").into());
        };
        assert_eq!(*done, "upgraded");
        assert!(matches!(**source, InstallError::InvalidArtifact { .. }));
        assert_eq!(
            error.to_string(),
            "Omabox was upgraded and the service runs the new build, but the replaced files could not be removed"
        );
        assert_eq!(
            error.help().map(|help| help.to_string()).as_deref(),
            Some("The next install, upgrade or uninstall removes the leftover files.")
        );
        assert_eq!(
            fs::read(&fixture.layout.omabox)?,
            b"#!/bin/sh\necho omabox\n"
        );
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\ndaemon-reload\nreset-failed\nrestart\n"
        );
        Ok(())
    }

    #[test]
    fn lock_transition_during_rollback_preserves_live_and_backup_plugins()
    -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, true)?;
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
                assert!(matches!(restore[0], InstallError::ShellLocked));
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

    fn primary_failure() -> InstallError {
        InstallError::Filesystem {
            operation: "replace",
            path: PathBuf::from("/primary"),
            source: io::Error::other("primary-inner-cause"),
        }
    }

    fn assert_renders(error: InstallError, expected: &[&str]) {
        // miette wraps help at the terminal width; compare word sequences.
        let rendered = format!("{:?}", miette::Report::new(error));
        let report = rendered.split_whitespace().collect::<Vec<_>>().join(" ");
        for text in expected {
            assert!(report.contains(text), "missing {text:?} in:\n{report}");
        }
    }

    #[test]
    fn rollback_failure_renders_both_chains_and_restore_help() {
        let restore = InstallError::DaemonSelfCheckStart {
            source: io::Error::other("restore-inner-cause"),
        };
        assert_renders(
            rollback_failure(primary_failure(), Err(restore)),
            &[
                "primary-inner-cause",
                "restore-inner-cause",
                "Rebuild Omabox and retry the installation.",
            ],
        );
    }

    #[test]
    fn cleanup_failure_renders_both_chains_and_cleanup_help() {
        let cleanup = InstallError::DaemonSelfCheckStart {
            source: io::Error::other("cleanup-inner-cause"),
        };
        assert_renders(
            cleanup_failure(primary_failure(), Err(cleanup)),
            &[
                "primary-inner-cause",
                "cleanup-inner-cause",
                "Rebuild Omabox and retry the installation.",
            ],
        );
    }

    #[test]
    fn fresh_install_publishes_missing_artifacts_and_stays_stopped() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("inactive", false, false, false)?;
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
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        assert_eq!(fs::read(&fixture.layout.unit)?, UNIT);
        assert!(fixture.layout.plugin.join("Panel.qml").is_file());
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\ndaemon-reload\nshow\n"
        );
        Ok(())
    }

    #[test]
    fn reload_failure_restores_old_artifacts_before_restart() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, true, false)?;
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
            "is-enabled\nshow\ndaemon-reload\ndaemon-reload\n"
        );
        Ok(())
    }

    #[test]
    fn validation_failure_changes_nothing_live() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
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
    fn staged_daemon_self_check_failure_preserves_published_artifacts() -> Result<(), Box<dyn Error>>
    {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        release_artifact(&fixture.sources.omaboxd, b"#!/bin/sh\nexit 9\n")?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(matches!(
            result,
            Err(InstallError::DaemonSelfCheckFailed { status: Some(9) })
        ));
        for path in [
            &fixture.layout.omabox,
            &fixture.layout.omaboxd,
            &fixture.layout.unit,
        ] {
            assert_eq!(fs::read(path)?, b"old");
        }
        assert_eq!(fs::read(fixture.layout.plugin.join("old.qml"))?, b"old");
        assert!(!fixture.systemctl_log.exists());
        assert!(!fixture.omarchy_log.exists());
        Ok(())
    }

    #[test]
    fn staged_daemon_self_check_retries_a_transient_text_busy_spawn() -> Result<(), Box<dyn Error>>
    {
        let directory = tempfile::TempDir::new()?;
        let daemon = directory.path().join("omaboxd");
        release_artifact(&daemon, VALID_DAEMON)?;
        let writer = OpenOptions::new().write(true).open(&daemon)?;
        let mut writer = Some(writer);
        let mut waits = Vec::new();

        validate_daemon_with(&daemon, &mut |delay| {
            waits.push(delay);
            drop(writer.take());
            // Match production: concurrent fork/exec children may briefly retain the descriptor.
            std::thread::sleep(delay);
        })?;

        assert!(!waits.is_empty());
        assert!(waits.len() < DAEMON_SELF_CHECK_ATTEMPTS);
        assert!(
            waits
                .iter()
                .all(|delay| *delay == DAEMON_SELF_CHECK_RETRY_DELAY)
        );
        Ok(())
    }

    #[test]
    fn staged_daemon_self_check_bounds_text_busy_and_preserves_other_spawn_errors()
    -> Result<(), Box<dyn Error>> {
        let directory = tempfile::TempDir::new()?;
        let daemon = directory.path().join("omaboxd");
        release_artifact(&daemon, VALID_DAEMON)?;
        let _writer = OpenOptions::new().write(true).open(&daemon)?;
        let mut waits = Vec::new();

        let busy = validate_daemon_with(&daemon, &mut |delay| waits.push(delay));
        match busy {
            Err(InstallError::DaemonSelfCheckStart { source }) => assert_eq!(
                source.raw_os_error(),
                Some(rustix::io::Errno::TXTBSY.raw_os_error())
            ),
            other => return Err(io::Error::other(format!("unexpected result: {other:?}")).into()),
        }
        assert_eq!(waits.len(), DAEMON_SELF_CHECK_ATTEMPTS - 1);

        let missing = directory.path().join("missing");
        let mut unrelated_waits = 0;
        let missing = validate_daemon_with(&missing, &mut |_| unrelated_waits += 1);
        match missing {
            Err(InstallError::DaemonSelfCheckStart { source }) => {
                assert_eq!(source.kind(), io::ErrorKind::NotFound);
            }
            other => return Err(io::Error::other(format!("unexpected result: {other:?}")).into()),
        }
        assert_eq!(unrelated_waits, 0);
        Ok(())
    }

    #[test]
    fn empty_daemon_is_rejected_before_any_live_change() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("inactive", false, false, false)?;
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
        let fixture = Fixture::new("active", true, false, false)?;
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
    fn symlinked_destinations_are_refused_and_kept() -> Result<(), Box<dyn Error>> {
        for action in [InstallAction::Upgrade, InstallAction::Uninstall] {
            for plugin in [false, true] {
                let case = format!("{action:?} plugin={plugin}");
                let fixture = Fixture::new("active", true, false, false)?;
                fixture.old_install()?;
                let shell_log = fixture.layout.home.join("omarchy-shell.log");
                fs::write(
                    fixture.commands.omarchy_shell.path(),
                    format!(
                        "printf '%s\\n' \"$*\" >> '{}'\nprintf 'false\\n'\n",
                        shell_log.display()
                    ),
                )?;
                let dotfiles = fixture.layout.home.join("dotfiles");
                fs::create_dir(&dotfiles)?;
                let (link, target) = if plugin {
                    let target = dotfiles.join(PLUGIN_ID);
                    fs::rename(&fixture.layout.plugin, &target)?;
                    (&fixture.layout.plugin, target)
                } else {
                    let target = dotfiles.join("omabox");
                    fs::rename(&fixture.layout.omabox, &target)?;
                    (&fixture.layout.omabox, target)
                };
                std::os::unix::fs::symlink(&target, link)?;

                let result =
                    execute_with(action, &fixture.layout, &fixture.sources, &fixture.commands);

                let Err(error) = result else {
                    return Err(io::Error::other(format!("{case}: symlink accepted")).into());
                };
                assert!(
                    matches!(&error, InstallError::DestinationSymlink { path } if path == link),
                    "{case}: {error:?}"
                );
                let Some(help) = error.help() else {
                    return Err(io::Error::other(format!("{case}: no help")).into());
                };
                assert!(help.to_string().contains("real files"), "{case}");
                assert_eq!(fs::read_link(link)?, target, "{case}");
                if plugin {
                    assert_eq!(fs::read(target.join("old.qml"))?, b"old", "{case}");
                } else {
                    assert_eq!(fs::read(&target)?, b"old", "{case}");
                }
                assert!(!fixture.systemctl_log.exists(), "{case}");
                assert!(!shell_log.exists(), "{case}");
                let Some(bin) = fixture.layout.omabox.parent() else {
                    return Err(io::Error::other("test path had no parent").into());
                };
                assert!(transaction_artifacts(bin, ".omabox")?.is_empty(), "{case}");
                assert!(
                    transaction_artifacts(&fixture.layout.omarchy_root, ".")?.is_empty(),
                    "{case}"
                );
            }
        }
        Ok(())
    }

    #[test]
    fn plugin_installs_through_a_symlinked_omarchy_root() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("inactive", false, false, false)?;
        let dotfiles = fixture.layout.home.join("dotfiles/omarchy");
        fs::create_dir_all(&dotfiles)?;
        fs::create_dir(fixture.layout.home.join(".config"))?;
        std::os::unix::fs::symlink(&dotfiles, &fixture.layout.omarchy_root)?;

        execute_with(
            InstallAction::Install,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        assert_eq!(fs::read_link(&fixture.layout.omarchy_root)?, dotfiles);
        for (name, contents) in PLUGIN {
            assert_eq!(
                fs::read(dotfiles.join("plugins").join(PLUGIN_ID).join(name))?,
                contents
            );
        }
        Ok(())
    }

    #[test]
    fn installing_from_the_installed_copy_is_refused() -> Result<(), Box<dyn Error>> {
        for daemon in [false, true] {
            for hard_link in [false, true] {
                let case = format!("daemon={daemon} hard_link={hard_link}");
                let fixture = Fixture::new("active", true, false, false)?;
                fixture.old_install()?;
                let installed = if daemon {
                    &fixture.layout.omaboxd
                } else {
                    &fixture.layout.omabox
                };
                let source = if hard_link {
                    let source = fixture.layout.home.join("linked");
                    fs::hard_link(installed, &source)?;
                    source
                } else {
                    installed.clone()
                };
                let sources = if daemon {
                    Sources {
                        omabox: fixture.sources.omabox.clone(),
                        omaboxd: source,
                    }
                } else {
                    Sources {
                        omabox: source,
                        omaboxd: fixture.sources.omaboxd.clone(),
                    }
                };

                let result = execute_with(
                    InstallAction::Upgrade,
                    &fixture.layout,
                    &sources,
                    &fixture.commands,
                );

                let Err(error) = result else {
                    return Err(io::Error::other(format!("{case}: self install accepted")).into());
                };
                assert!(
                    matches!(&error, InstallError::SourceIsDestination { path } if path == installed),
                    "{case}: {error:?}"
                );
                let Some(help) = error.help() else {
                    return Err(io::Error::other(format!("{case}: no help")).into());
                };
                assert!(help.to_string().contains("new build"), "{case}");
                for path in [
                    &fixture.layout.omabox,
                    &fixture.layout.omaboxd,
                    &fixture.layout.unit,
                ] {
                    assert_eq!(fs::read(path)?, b"old", "{case}");
                }
                assert_eq!(
                    fs::read(fixture.layout.plugin.join("old.qml"))?,
                    b"old",
                    "{case}"
                );
                assert!(!fixture.systemctl_log.exists(), "{case}");
            }
        }
        Ok(())
    }

    #[test]
    fn symlink_refusal_precedes_any_directory_or_staged_copy() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("inactive", false, false, false)?;
        let Some(bin) = fixture.layout.omabox.parent() else {
            return Err(io::Error::other("test path had no parent").into());
        };
        fs::create_dir_all(bin)?;
        let target = fixture.layout.home.join("omabox-elsewhere");
        fs::write(&target, b"old")?;
        std::os::unix::fs::symlink(&target, &fixture.layout.omabox)?;
        let Some(unit_dir) = fixture.layout.unit.parent() else {
            return Err(io::Error::other("test path had no parent").into());
        };
        assert!(!unit_dir.exists());
        assert!(!fixture.layout.omarchy_root.exists());

        let result = execute_with(
            InstallAction::Install,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(
            matches!(&result, Err(InstallError::DestinationSymlink { path }) if *path == fixture.layout.omabox),
            "{result:?}"
        );
        assert!(!unit_dir.exists());
        assert!(!fixture.layout.omarchy_root.exists());
        assert!(transaction_artifacts(bin, ".omabox")?.is_empty());
        assert_eq!(fs::read_link(&fixture.layout.omabox)?, target);
        assert_eq!(fs::read(&target)?, b"old");
        assert!(!fixture.systemctl_log.exists());
        Ok(())
    }

    #[test]
    fn plugin_symlinked_during_the_lock_check_rolls_back() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        let lock_checks = fixture._temporary.path().join("lock-checks");
        let target = fixture.layout.home.join("dotfiles-plugin");
        // The third lock check is the one apply runs before the plugin entry.
        fs::write(
            fixture.commands.omarchy_shell.path(),
            format!(
                "count=0\nif [ -f '{checks}' ]; then read count < '{checks}'; fi\ncount=$((count + 1))\nprintf '%s\\n' \"$count\" > '{checks}'\nif [ \"$count\" -eq 3 ]; then mv '{plugin}' '{target}' && ln -s '{target}' '{plugin}'; fi\nprintf 'false\\n'\n",
                checks = lock_checks.display(),
                plugin = fixture.layout.plugin.display(),
                target = target.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(
            matches!(&result, Err(InstallError::DestinationSymlink { path }) if *path == fixture.layout.plugin),
            "{result:?}"
        );
        assert_eq!(fs::read_to_string(&lock_checks)?, "3\n");
        assert_eq!(fs::read_link(&fixture.layout.plugin)?, target);
        assert_eq!(fs::read(target.join("old.qml"))?, b"old");
        assert_eq!(fs::read_dir(&target)?.count(), 1);
        for path in [
            &fixture.layout.omabox,
            &fixture.layout.omaboxd,
            &fixture.layout.unit,
        ] {
            assert_eq!(fs::read(path)?, b"old");
        }
        let Some(bin) = fixture.layout.omabox.parent() else {
            return Err(io::Error::other("test path had no parent").into());
        };
        let Some(unit_dir) = fixture.layout.unit.parent() else {
            return Err(io::Error::other("test path had no parent").into());
        };
        assert!(transaction_artifacts(bin, ".omabox")?.is_empty());
        assert!(transaction_artifacts(unit_dir, ".")?.is_empty());
        assert!(transaction_artifacts(&fixture.layout.omarchy_root, ".")?.is_empty());
        Ok(())
    }

    #[test]
    fn lock_before_plugin_restores_earlier_artifacts_and_service() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
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
            "is-enabled\nshow\nshow\nstop\nshow\ndisable\ndaemon-reload\nenable\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn uninstall_removes_only_artifacts_and_retains_user_data() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("active", true, false, false)?;
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
            "is-enabled\nshow\nshow\nstop\nshow\ndisable\ndaemon-reload\n"
        );
        Ok(())
    }

    #[test]
    fn upgrade_starts_a_failed_service_after_clearing_it() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("failed", true, false, false)?;
        fixture.old_install()?;
        let report = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        assert_eq!(
            report,
            "Omabox was upgraded. The service remains enabled. The stopped service has been started again.\n"
        );
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\ndaemon-reload\nshow\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn upgrade_keeps_the_new_build_when_a_failed_service_still_fails() -> Result<(), Box<dyn Error>>
    {
        let fixture = Fixture::new("failed", true, false, false)?;
        fixture.old_install()?;
        fs::write(
            &fixture.systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-enabled) exit 0;;\n show) printf 'failed\\n';;\n start) exit 1;;\nesac\nexit 0\n",
                fixture.systemctl_log.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(
            matches!(
                result,
                Err(InstallError::StartAfterChange {
                    done: "upgraded",
                    ..
                })
            ),
            "upgrade reported {result:?}"
        );
        assert_eq!(
            fs::read(&fixture.layout.omabox)?,
            b"#!/bin/sh\necho omabox\n"
        );
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        assert_eq!(fs::read(&fixture.layout.unit)?, UNIT);
        assert!(!fixture.layout.plugin.join("old.qml").exists());
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\ndaemon-reload\nshow\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn upgrade_keeps_the_new_build_when_a_starting_service_fails_to_restart()
    -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("activating", true, false, true)?;
        fixture.old_install()?;

        let result = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(
            matches!(
                result,
                Err(InstallError::StartAfterChange {
                    done: "upgraded",
                    ..
                })
            ),
            "upgrade reported {result:?}"
        );
        assert_eq!(
            fs::read(&fixture.layout.omabox)?,
            b"#!/bin/sh\necho omabox\n"
        );
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        assert_eq!(fs::read(&fixture.layout.unit)?, UNIT);
        assert!(!fixture.layout.plugin.join("old.qml").exists());
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\ndaemon-reload\nreset-failed\nrestart\n"
        );
        Ok(())
    }

    #[test]
    fn upgrade_settles_a_stopping_service() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("deactivating", true, false, false)?;
        fixture.old_install()?;
        let report = execute_with(
            InstallAction::Upgrade,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        assert_eq!(
            report,
            "Omabox was upgraded. The service remains enabled and stopped.\n"
        );
        assert_eq!(fs::read(&fixture.layout.omaboxd)?, VALID_DAEMON);
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\ndaemon-reload\nshow\nstop\nshow\n"
        );
        Ok(())
    }

    #[test]
    fn uninstall_sweeps_dead_temporaries_from_every_install_directory() -> Result<(), Box<dyn Error>>
    {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        let pid_max: u32 = fs::read_to_string("/proc/sys/kernel/pid_max")?
            .trim()
            .parse()?;
        let dead = format!("{}.0", pid_max + 1);
        let stale = staged_paths(&fixture.layout, &dead)?;
        let [omabox, omaboxd, unit, plugin] = &stale;
        for file in [omabox, omaboxd, unit] {
            fs::write(file, b"stale")?;
        }
        fs::create_dir(plugin)?;
        fs::write(plugin.join("Panel.qml"), b"stale")?;

        let report = execute_with(
            InstallAction::Uninstall,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        for path in &stale {
            assert!(fs::symlink_metadata(path).is_err(), "{}", path.display());
        }
        assert!(!fixture.layout.plugin.exists());
        assert!(!report.contains("Left a stale temporary"), "{report}");
        Ok(())
    }

    #[test]
    fn uninstall_stops_a_starting_or_stopping_service() -> Result<(), Box<dyn Error>> {
        for active_state in ["activating", "deactivating"] {
            let fixture = Fixture::new(active_state, true, false, false)?;
            fixture.old_install()?;
            execute_with(
                InstallAction::Uninstall,
                &fixture.layout,
                &fixture.sources,
                &fixture.commands,
            )?;

            assert!(!fixture.layout.omaboxd.exists(), "{active_state}");
            assert_eq!(
                fs::read_to_string(&fixture.systemctl_log)?,
                "is-enabled\nshow\nshow\nstop\nshow\ndisable\ndaemon-reload\n",
                "{active_state}"
            );
        }
        Ok(())
    }

    #[test]
    fn uninstall_restores_the_service_when_the_state_after_stop_fails() -> Result<(), Box<dyn Error>>
    {
        let fixture = Fixture::new("active", true, false, false)?;
        fixture.old_install()?;
        let shown = fixture._temporary.path().join("shown");
        fs::write(
            &fixture.systemctl,
            format!(
                "printf '%s\\n' \"$2\" >> '{}'\ncase \"$2\" in\n is-enabled) exit 0;;\n show) count=0; if [ -f '{}' ]; then read count < '{}'; fi; count=$((count + 1)); printf '%s\\n' \"$count\" > '{}'; if [ \"$count\" -ge 3 ]; then exit 1; fi; printf 'active\\n';;\nesac\nexit 0\n",
                fixture.systemctl_log.display(),
                shown.display(),
                shown.display(),
                shown.display(),
            ),
        )?;

        let result = execute_with(
            InstallAction::Uninstall,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        );

        assert!(matches!(
            result,
            Err(InstallError::Service(ServiceError::Unsuccessful {
                command: "systemctl show",
                ..
            }))
        ));
        assert!(fixture.layout.omaboxd.exists());
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\nshow\nstop\nshow\nenable\nreset-failed\nstart\n"
        );
        Ok(())
    }

    #[test]
    fn uninstall_clears_a_failed_service() -> Result<(), Box<dyn Error>> {
        let fixture = Fixture::new("failed", true, false, false)?;
        fixture.old_install()?;
        execute_with(
            InstallAction::Uninstall,
            &fixture.layout,
            &fixture.sources,
            &fixture.commands,
        )?;

        assert!(!fixture.layout.omaboxd.exists());
        assert_eq!(
            fs::read_to_string(&fixture.systemctl_log)?,
            "is-enabled\nshow\nshow\nreset-failed\ndisable\ndaemon-reload\n"
        );
        Ok(())
    }

    #[test]
    fn every_install_error_has_help() -> Result<(), Box<dyn Error>> {
        let io = || io::Error::other("cause");
        let inner = || Box::new(InstallError::HomeUnavailable);
        let errors = [
            InstallError::HomeUnavailable,
            InstallError::HomeNotAbsolute {
                path: PathBuf::from("home"),
            },
            InstallError::InvalidArtifact {
                path: PathBuf::from("/artifact"),
                detail: "detail",
            },
            InstallError::DestinationSymlink {
                path: PathBuf::from("/artifact"),
            },
            InstallError::SourceIsDestination {
                path: PathBuf::from("/artifact"),
            },
            InstallError::Filesystem {
                operation: "read",
                path: PathBuf::from("/artifact"),
                source: io(),
            },
            InstallError::CommandStart {
                command: "command",
                source: io(),
            },
            InstallError::CommandFailed {
                command: "command",
                status: Some(1),
            },
            InstallError::DaemonSelfCheckStart { source: io() },
            InstallError::DaemonSelfCheckFailed { status: Some(1) },
            InstallError::ShellLocked,
            InstallError::InvalidLockState,
            InstallError::Service(ServiceError::Terminated { command: "command" }),
            InstallError::StartAfterChange {
                done: "upgraded",
                source: ServiceError::Terminated { command: "command" },
            },
            InstallError::CleanupAfterChange {
                done: "upgraded",
                source: inner(),
            },
            InstallError::RollbackFailed {
                source: inner(),
                restore: Box::new([*inner()]),
            },
            InstallError::CleanupFailed {
                source: inner(),
                cleanup: Box::new([*inner()]),
            },
        ];
        // A new variant fails to compile here until it gets an arm, but nothing forces it
        // into `errors`: add it there with its arm. Equal lengths mean no variant is listed twice.
        let names: std::collections::BTreeSet<&str> = errors
            .iter()
            .map(|error| match error {
                InstallError::HomeUnavailable => "HomeUnavailable",
                InstallError::HomeNotAbsolute { .. } => "HomeNotAbsolute",
                InstallError::InvalidArtifact { .. } => "InvalidArtifact",
                InstallError::DestinationSymlink { .. } => "DestinationSymlink",
                InstallError::SourceIsDestination { .. } => "SourceIsDestination",
                InstallError::Filesystem { .. } => "Filesystem",
                InstallError::CommandStart { .. } => "CommandStart",
                InstallError::CommandFailed { .. } => "CommandFailed",
                InstallError::DaemonSelfCheckStart { .. } => "DaemonSelfCheckStart",
                InstallError::DaemonSelfCheckFailed { .. } => "DaemonSelfCheckFailed",
                InstallError::ShellLocked => "ShellLocked",
                InstallError::InvalidLockState => "InvalidLockState",
                InstallError::Service(_) => "Service",
                InstallError::StartAfterChange { .. } => "StartAfterChange",
                InstallError::CleanupAfterChange { .. } => "CleanupAfterChange",
                InstallError::RollbackFailed { .. } => "RollbackFailed",
                InstallError::CleanupFailed { .. } => "CleanupFailed",
            })
            .collect();
        assert_eq!(names.len(), errors.len());

        for error in &errors {
            let Some(help) = Diagnostic::help(error).map(|help| help.to_string()) else {
                return Err(format!("{error:?} has no help").into());
            };
            assert!(!help.trim().is_empty(), "{error:?} has empty help");
        }
        Ok(())
    }
}
