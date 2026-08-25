//! Non-secret configuration, XDG paths, daemon locking, and safe log fields.

use std::env;
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write as _};
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use miette::Diagnostic;
use serde::{Deserialize, Serialize};
use thiserror::Error;

const APPLICATION_DIRECTORY: &str = "omabox";
const CONFIG_FILE: &str = "config.toml";
const JOURNAL_FILE: &str = "journal.sqlite3";
const UPLOAD_STAGING_DIRECTORY: &str = "upload-staging";
const RECOVERY_DIRECTORY: &str = "recovery";
const LOCK_FILE: &str = "daemon.lock";
static CONFIG_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// XDG base directories used by Omabox.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct XdgDirectories {
    config_home: PathBuf,
    state_home: PathBuf,
}

impl XdgDirectories {
    /// Resolve XDG base directories from the process environment.
    pub fn from_environment() -> Result<Self, ConfigError> {
        resolve_xdg_directories(
            env::var_os("HOME"),
            env::var_os("XDG_CONFIG_HOME"),
            env::var_os("XDG_STATE_HOME"),
        )
    }

    /// Construct explicitly supplied XDG base directories.
    ///
    /// This is useful to embed Omabox without changing process-global
    /// environment variables and keeps path behavior deterministic in tests.
    pub fn new(
        config_home: impl Into<PathBuf>,
        state_home: impl Into<PathBuf>,
    ) -> Result<Self, ConfigError> {
        Ok(Self {
            config_home: require_absolute("XDG_CONFIG_HOME", config_home.into())?,
            state_home: require_absolute("XDG_STATE_HOME", state_home.into())?,
        })
    }

    /// Path to the non-secret Omabox configuration file.
    #[must_use]
    pub fn config_file(&self) -> PathBuf {
        self.config_home
            .join(APPLICATION_DIRECTORY)
            .join(CONFIG_FILE)
    }

    fn application_state_directory(&self) -> PathBuf {
        self.state_home.join(APPLICATION_DIRECTORY)
    }
}

/// Validated paths used by one Omabox instance.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Paths {
    config_file: PathBuf,
    state_directory: PathBuf,
    journal_file: PathBuf,
    upload_staging_directory: PathBuf,
    recovery_directory: PathBuf,
    lock_file: PathBuf,
}

impl Paths {
    fn resolve(xdg: &XdgDirectories, sync_root: &Path) -> Result<Self, ConfigError> {
        let state_directory = lexical_normalize(&xdg.application_state_directory());
        let paths = Self {
            config_file: lexical_normalize(&xdg.config_file()),
            journal_file: state_directory.join(JOURNAL_FILE),
            upload_staging_directory: state_directory.join(UPLOAD_STAGING_DIRECTORY),
            recovery_directory: state_directory.join(RECOVERY_DIRECTORY),
            lock_file: state_directory.join(LOCK_FILE),
            state_directory,
        };
        paths.validate_outside(sync_root)?;
        Ok(paths)
    }

    fn validate_outside(&self, sync_root: &Path) -> Result<(), ConfigError> {
        let physical_root = canonicalize_sync_root(sync_root)?;
        for (role, path) in [
            (PathRole::StateDirectory, self.state_directory()),
            (PathRole::Journal, self.journal_file()),
            (PathRole::UploadStaging, self.upload_staging_directory()),
            (PathRole::Recovery, self.recovery_directory()),
        ] {
            let projected = project_physical_path(path)?;
            if projected == physical_root || projected.starts_with(&physical_root) {
                return Err(ConfigError::ProtectedPathInsideSyncRoot {
                    role,
                    path: path.to_path_buf(),
                    sync_root: sync_root.to_path_buf(),
                });
            }
        }
        Ok(())
    }

    /// Create the private state, upload staging, and legacy recovery directories.
    ///
    /// Validation runs again before any directory is created so a symlinked
    /// XDG ancestor cannot silently redirect safety-critical data into the sync
    /// root.
    pub fn prepare(&self, sync_root: &Path) -> Result<(), ConfigError> {
        self.validate_outside(sync_root)?;
        for (role, path) in [
            (PathRole::StateDirectory, self.state_directory()),
            (PathRole::UploadStaging, self.upload_staging_directory()),
            (PathRole::Recovery, self.recovery_directory()),
        ] {
            let mut builder = fs::DirBuilder::new();
            builder.recursive(true).mode(0o700);
            builder
                .create(path)
                .map_err(|source| ConfigError::CreateDirectory {
                    role,
                    path: path.to_path_buf(),
                    source,
                })?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|source| {
                ConfigError::SetDirectoryPermissions {
                    role,
                    path: path.to_path_buf(),
                    source,
                }
            })?;
        }
        self.validate_outside(sync_root)
    }

    /// Path to the non-secret TOML configuration file.
    #[must_use]
    pub fn config_file(&self) -> &Path {
        &self.config_file
    }

    /// XDG state directory reserved for Omabox.
    #[must_use]
    pub fn state_directory(&self) -> &Path {
        &self.state_directory
    }

    /// Path to the transactional SQLite journal.
    #[must_use]
    pub fn journal_file(&self) -> &Path {
        &self.journal_file
    }

    /// Directory for immutable upload staging.
    #[must_use]
    pub fn upload_staging_directory(&self) -> &Path {
        &self.upload_staging_directory
    }

    /// Directory retaining recovery data created by older versions.
    #[must_use]
    pub fn recovery_directory(&self) -> &Path {
        &self.recovery_directory
    }

    /// Path whose open file description carries the daemon instance lock.
    #[must_use]
    pub fn lock_file(&self) -> &Path {
        &self.lock_file
    }
}

/// Loaded non-secret configuration and its validated runtime paths.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    sync_root: PathBuf,
    dropbox_app_key: String,
    paths: Paths,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ConfigDocument {
    sync_root: PathBuf,
    dropbox_app_key: String,
}

impl Config {
    /// Load configuration using the process XDG environment.
    pub fn load() -> Result<Self, ConfigError> {
        Self::load_from(&XdgDirectories::from_environment()?)
    }

    /// Load configuration from explicit XDG base directories.
    pub fn load_from(xdg: &XdgDirectories) -> Result<Self, ConfigError> {
        let config_file = xdg.config_file();
        let contents = fs::read_to_string(&config_file).map_err(|source| ConfigError::Read {
            path: config_file.clone(),
            source,
        })?;
        let document = toml::from_str::<ConfigDocument>(&contents).map_err(|mut source| {
            source.set_input(None);
            ConfigError::Parse {
                path: config_file,
                source,
            }
        })?;
        Self::from_values(xdg, document.sync_root, document.dropbox_app_key)
    }

    /// Validate a configuration supplied by a setup or settings command.
    pub fn from_values(
        xdg: &XdgDirectories,
        sync_root: impl Into<PathBuf>,
        dropbox_app_key: impl Into<String>,
    ) -> Result<Self, ConfigError> {
        let requested_root = require_absolute("sync_root", sync_root.into())?;
        let dropbox_app_key = dropbox_app_key.into();
        if dropbox_app_key.trim().is_empty() {
            return Err(ConfigError::EmptyDropboxAppKey);
        }
        let sync_root = canonicalize_sync_root(&requested_root)?;
        let paths = Paths::resolve(xdg, &sync_root)?;
        Ok(Self {
            sync_root,
            dropbox_app_key,
            paths,
        })
    }

    /// Canonical local root synchronized with Dropbox.
    #[must_use]
    pub fn sync_root(&self) -> &Path {
        &self.sync_root
    }

    /// Public Dropbox application key used for OAuth.
    #[must_use]
    pub fn dropbox_app_key(&self) -> &str {
        &self.dropbox_app_key
    }

    /// Validated configuration and state paths.
    #[must_use]
    pub fn paths(&self) -> &Paths {
        &self.paths
    }

    /// Prepare runtime directories after validating their placement.
    pub fn prepare(&self) -> Result<(), ConfigError> {
        self.paths.prepare(&self.sync_root)
    }

    /// Atomically persist this non-secret configuration with owner-only access.
    pub fn write(&self) -> Result<(), ConfigError> {
        self.write_with_replacement(true)
    }

    /// Atomically persist initial configuration without replacing an existing file.
    pub fn write_new(&self) -> Result<(), ConfigError> {
        self.write_with_replacement(false)
    }

    fn write_with_replacement(&self, replace_existing: bool) -> Result<(), ConfigError> {
        let document = ConfigDocument {
            sync_root: self.sync_root.clone(),
            dropbox_app_key: self.dropbox_app_key.clone(),
        };
        let contents = toml::to_string(&document).map_err(ConfigError::Serialize)?;
        atomic_write_config(
            self.paths.config_file(),
            contents.as_bytes(),
            replace_existing,
        )
    }
}

/// Safety-sensitive path role used in diagnostics.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PathRole {
    /// XDG application state directory.
    StateDirectory,
    /// Transactional journal.
    Journal,
    /// Immutable upload staging directory.
    UploadStaging,
    /// Legacy recovery directory.
    Recovery,
}

impl fmt::Display for PathRole {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::StateDirectory => "state directory",
            Self::Journal => "journal",
            Self::UploadStaging => "upload staging directory",
            Self::Recovery => "recovery directory",
        })
    }
}

/// A typed configuration or path error.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum ConfigError {
    /// HOME is required when an XDG variable is not set.
    #[error("HOME is not set")]
    #[diagnostic(
        code(omabox::config::home_unavailable),
        help("Set HOME, or set both XDG_CONFIG_HOME and XDG_STATE_HOME to absolute paths.")
    )]
    HomeDirectoryUnavailable,

    /// An environment or configuration path was relative.
    #[error("{name} must be an absolute path, but was `{path}`")]
    #[diagnostic(
        code(omabox::config::path_not_absolute),
        help("Use an absolute path so the unattended service resolves it consistently.")
    )]
    PathNotAbsolute {
        /// Environment variable or configuration key.
        name: &'static str,
        /// Invalid path.
        path: PathBuf,
    },

    /// The configuration file could not be read.
    #[error("could not read Omabox configuration at `{path}`")]
    #[diagnostic(
        code(omabox::config::read),
        help("Create a readable file containing an absolute `sync_root` and a `dropbox_app_key`.")
    )]
    Read {
        /// Configuration file path.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },

    /// TOML configuration was invalid.
    #[error("could not parse Omabox configuration at `{path}`")]
    #[diagnostic(
        code(omabox::config::parse),
        help(
            "The file may contain only `sync_root` and `dropbox_app_key`; credentials do not belong in configuration."
        )
    )]
    Parse {
        /// Configuration file path.
        path: PathBuf,
        /// Underlying TOML error.
        #[source]
        source: toml::de::Error,
    },

    /// The public Dropbox application key was empty.
    #[error("Dropbox application key is empty")]
    #[diagnostic(
        code(omabox::config::empty_dropbox_app_key),
        help("Set `dropbox_app_key` to the public app key from the Dropbox developer console.")
    )]
    EmptyDropboxAppKey,

    /// Initial setup refused to replace an existing configuration.
    #[error("Omabox configuration already exists at `{path}`")]
    #[diagnostic(
        code(omabox::config::already_exists),
        help("Use Omabox settings commands to change existing configuration.")
    )]
    AlreadyExists {
        /// Existing configuration path.
        path: PathBuf,
    },

    /// A validated configuration could not be serialized.
    #[error("could not serialize Omabox configuration")]
    #[diagnostic(
        code(omabox::config::serialize),
        help("Use a sync-root path representable in TOML and retry.")
    )]
    Serialize(#[source] toml::ser::Error),

    /// The private configuration directory could not be prepared.
    #[error("could not prepare Omabox configuration directory at `{path}`")]
    #[diagnostic(
        code(omabox::config::prepare_configuration_directory),
        help("Ensure the XDG configuration location is owned by this user and writable.")
    )]
    PrepareConfigurationDirectory {
        /// Configuration directory path.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },

    /// An atomic configuration write failed.
    #[error("could not {operation} Omabox configuration at `{path}`")]
    #[diagnostic(
        code(omabox::config::write),
        help("Ensure the XDG configuration location is owned by this user and writable.")
    )]
    Write {
        /// Failed write phase.
        operation: &'static str,
        /// Configuration or temporary file path.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },

    /// A failed write also left its private temporary file behind.
    #[error("could not remove temporary configuration `{path}` after the write failed: {cleanup}")]
    #[diagnostic(
        code(omabox::config::cleanup_after_write),
        help(
            "The incomplete owner-only temporary file is ignored; fix directory access and retry."
        )
    )]
    CleanupAfterWrite {
        /// Temporary file that could not be removed.
        path: PathBuf,
        /// Original write failure.
        #[source]
        write: Box<ConfigError>,
        /// Cleanup failure.
        cleanup: io::Error,
    },

    /// The configured sync root could not be resolved.
    #[error("could not resolve sync root `{path}`")]
    #[diagnostic(
        code(omabox::config::sync_root_unavailable),
        help("Create the sync root as a local directory and ensure it is accessible.")
    )]
    ResolveSyncRoot {
        /// Configured sync root.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },

    /// The configured sync root was not a directory.
    #[error("sync root `{path}` is not a directory")]
    #[diagnostic(
        code(omabox::config::sync_root_not_directory),
        help("Set `sync_root` to an existing local directory.")
    )]
    SyncRootNotDirectory {
        /// Configured sync root.
        path: PathBuf,
    },

    /// A path could not be inspected during safety validation.
    #[error("could not inspect `{path}` while validating configuration paths")]
    #[diagnostic(
        code(omabox::config::inspect_path),
        help("Ensure every parent directory is accessible and retry.")
    )]
    InspectPath {
        /// Inspected path.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },

    /// Safety-critical state was placed inside the synchronized tree.
    #[error("{role} `{path}` must not be inside sync root `{sync_root}`")]
    #[diagnostic(
        code(omabox::config::state_inside_sync_root),
        help("Set XDG_STATE_HOME to a local directory outside the sync root.")
    )]
    ProtectedPathInsideSyncRoot {
        /// Role of the invalid path.
        role: PathRole,
        /// Invalid state path.
        path: PathBuf,
        /// Configured sync root.
        sync_root: PathBuf,
    },

    /// A runtime directory could not be created.
    #[error("could not create Omabox {role} at `{path}`")]
    #[diagnostic(
        code(omabox::config::create_directory),
        help("Ensure the XDG state location is writable and has sufficient space.")
    )]
    CreateDirectory {
        /// Role of the directory.
        role: PathRole,
        /// Directory path.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },

    /// A runtime directory could not be restricted to its owner.
    #[error("could not secure Omabox {role} at `{path}`")]
    #[diagnostic(
        code(omabox::config::set_directory_permissions),
        help("Ensure the XDG state location is owned by this user and retry.")
    )]
    SetDirectoryPermissions {
        /// Role of the directory.
        role: PathRole,
        /// Directory path.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },
}

fn atomic_write_config(
    path: &Path,
    contents: &[u8],
    replace_existing: bool,
) -> Result<(), ConfigError> {
    let parent = path.parent().ok_or_else(|| ConfigError::Write {
        operation: "locate the parent of",
        path: path.to_path_buf(),
        source: io::Error::new(
            io::ErrorKind::InvalidInput,
            "configuration path has no parent",
        ),
    })?;
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700);
    builder
        .create(parent)
        .and_then(|()| fs::set_permissions(parent, fs::Permissions::from_mode(0o700)))
        .map_err(|source| ConfigError::PrepareConfigurationDirectory {
            path: parent.to_path_buf(),
            source,
        })?;

    let sequence = CONFIG_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(
        ".{CONFIG_FILE}.{}.{}.tmp",
        std::process::id(),
        sequence
    ));
    match write_config_temporary(&temporary, path, parent, contents, replace_existing) {
        Ok(()) => Ok(()),
        Err(write) => match fs::remove_file(&temporary) {
            Ok(()) => Err(write),
            Err(cleanup) if cleanup.kind() == io::ErrorKind::NotFound => Err(write),
            Err(cleanup) => Err(ConfigError::CleanupAfterWrite {
                path: temporary,
                write: Box::new(write),
                cleanup,
            }),
        },
    }
}

fn write_config_temporary(
    temporary: &Path,
    destination: &Path,
    parent: &Path,
    contents: &[u8],
    replace_existing: bool,
) -> Result<(), ConfigError> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(temporary)
        .map_err(|source| ConfigError::Write {
            operation: "create a temporary",
            path: temporary.to_path_buf(),
            source,
        })?;
    file.write_all(contents)
        .and_then(|()| file.sync_all())
        .map_err(|source| ConfigError::Write {
            operation: "write a temporary",
            path: temporary.to_path_buf(),
            source,
        })?;
    if replace_existing {
        fs::rename(temporary, destination).map_err(|source| ConfigError::Write {
            operation: "install the new",
            path: destination.to_path_buf(),
            source,
        })?;
    } else {
        match rustix::fs::renameat_with(
            rustix::fs::CWD,
            temporary,
            rustix::fs::CWD,
            destination,
            rustix::fs::RenameFlags::NOREPLACE,
        ) {
            Ok(()) => {}
            Err(source) if source == rustix::io::Errno::EXIST => {
                return Err(ConfigError::AlreadyExists {
                    path: destination.to_path_buf(),
                });
            }
            Err(source) => {
                return Err(ConfigError::Write {
                    operation: "install the initial",
                    path: destination.to_path_buf(),
                    source: source.into(),
                });
            }
        }
    }
    File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|source| ConfigError::Write {
            operation: "make the new",
            path: destination.to_path_buf(),
            source,
        })
}

/// The held kernel lock for one daemon instance.
///
/// Dropping this value closes the file and releases the lock. The lock file is
/// intentionally not deleted: its presence does not indicate ownership, so no
/// stale-file cleanup or recovery protocol is needed.
#[derive(Debug)]
pub struct InstanceLock {
    _file: File,
    path: PathBuf,
}

impl InstanceLock {
    /// Try to acquire the daemon lock without waiting.
    pub fn acquire(path: impl AsRef<Path>) -> Result<Self, LockError> {
        let path = path.as_ref();
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|source| LockError::Open {
                path: path.to_path_buf(),
                source,
            })?;
        match file.try_lock() {
            Ok(()) => Ok(Self {
                _file: file,
                path: path.to_path_buf(),
            }),
            Err(fs::TryLockError::WouldBlock) => Err(LockError::AlreadyRunning {
                path: path.to_path_buf(),
            }),
            Err(fs::TryLockError::Error(source)) => Err(LockError::Acquire {
                path: path.to_path_buf(),
                source,
            }),
        }
    }

    /// Path of the inode carrying this kernel lock.
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// A typed single-instance locking error.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum LockError {
    /// The lock file could not be opened.
    #[error("could not open daemon lock file `{path}`")]
    #[diagnostic(
        code(omabox::lock::open),
        help("Ensure the Omabox state directory is writable and retry.")
    )]
    Open {
        /// Lock file path.
        path: PathBuf,
        /// Underlying filesystem error.
        #[source]
        source: io::Error,
    },

    /// Another daemon currently owns the kernel lock.
    #[error("another Omabox daemon is already running")]
    #[diagnostic(
        code(omabox::lock::already_running),
        help("Use the existing daemon instance; no lock-file cleanup is required.")
    )]
    AlreadyRunning {
        /// Contended lock file path.
        path: PathBuf,
    },

    /// The kernel lock operation failed.
    #[error("could not acquire daemon lock on `{path}`")]
    #[diagnostic(
        code(omabox::lock::acquire),
        help("Check filesystem lock support and retry.")
    )]
    Acquire {
        /// Lock file path.
        path: PathBuf,
        /// Underlying lock error.
        #[source]
        source: io::Error,
    },
}

/// A display and debug wrapper that never formats the wrapped value.
///
/// Use this for any credential-derived field passed to `tracing`. Omabox does
/// not accept secrets in its configuration file.
pub struct Redacted<'value, Value: ?Sized>(&'value Value);

/// Wrap a sensitive log field so both `%field` and `?field` are redacted.
#[must_use]
pub const fn redacted<Value: ?Sized>(value: &Value) -> Redacted<'_, Value> {
    Redacted(value)
}

impl<Value: ?Sized> fmt::Debug for Redacted<'_, Value> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let _ = self.0;
        formatter.write_str("[REDACTED]")
    }
}

impl<Value: ?Sized> fmt::Display for Redacted<'_, Value> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let _ = self.0;
        formatter.write_str("[REDACTED]")
    }
}

/// Initialize structured stderr logging for a CLI or daemon process.
pub fn initialize_logging() -> Result<(), LoggingError> {
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::INFO)
        .with_target(false)
        .finish();
    tracing::subscriber::set_global_default(subscriber)
        .map_err(|source| LoggingError::Initialize { source })
}

/// A typed structured-logging initialization error.
#[derive(Debug, Diagnostic, Error)]
#[non_exhaustive]
pub enum LoggingError {
    /// A global tracing subscriber was already installed or could not be set.
    #[error("could not initialize Omabox logging")]
    #[diagnostic(
        code(omabox::logging::initialize),
        help("Initialize logging only once at process startup.")
    )]
    Initialize {
        /// Underlying subscriber initialization error.
        #[source]
        source: tracing::subscriber::SetGlobalDefaultError,
    },
}

fn require_absolute(name: &'static str, path: PathBuf) -> Result<PathBuf, ConfigError> {
    if path.is_absolute() {
        Ok(lexical_normalize(&path))
    } else {
        Err(ConfigError::PathNotAbsolute { name, path })
    }
}

fn resolve_xdg_directories(
    home: Option<OsString>,
    configured_config_home: Option<OsString>,
    configured_state_home: Option<OsString>,
) -> Result<XdgDirectories, ConfigError> {
    let config_home = valid_xdg_home(configured_config_home);
    let state_home = valid_xdg_home(configured_state_home);
    let home = if config_home.is_none() || state_home.is_none() {
        let path = home.ok_or(ConfigError::HomeDirectoryUnavailable)?;
        Some(require_absolute("HOME", PathBuf::from(path))?)
    } else {
        None
    };

    let config_home = match config_home {
        Some(path) => path,
        None => home
            .as_ref()
            .ok_or(ConfigError::HomeDirectoryUnavailable)?
            .join(".config"),
    };
    let state_home = match state_home {
        Some(path) => path,
        None => home
            .as_ref()
            .ok_or(ConfigError::HomeDirectoryUnavailable)?
            .join(".local")
            .join("state"),
    };
    Ok(XdgDirectories {
        config_home,
        state_home,
    })
}

fn valid_xdg_home(value: Option<OsString>) -> Option<PathBuf> {
    let path = PathBuf::from(value?);
    (!path.as_os_str().is_empty() && path.is_absolute()).then(|| lexical_normalize(&path))
}

fn canonicalize_sync_root(path: &Path) -> Result<PathBuf, ConfigError> {
    let canonical = fs::canonicalize(path).map_err(|source| ConfigError::ResolveSyncRoot {
        path: path.to_path_buf(),
        source,
    })?;
    let metadata = fs::metadata(&canonical).map_err(|source| ConfigError::ResolveSyncRoot {
        path: path.to_path_buf(),
        source,
    })?;
    if metadata.is_dir() {
        Ok(canonical)
    } else {
        Err(ConfigError::SyncRootNotDirectory {
            path: path.to_path_buf(),
        })
    }
}

fn project_physical_path(path: &Path) -> Result<PathBuf, ConfigError> {
    let mut existing = path.to_path_buf();
    let mut missing = Vec::<OsString>::new();
    loop {
        match fs::symlink_metadata(&existing) {
            Ok(_) => {
                let mut projected =
                    fs::canonicalize(&existing).map_err(|source| ConfigError::InspectPath {
                        path: existing.clone(),
                        source,
                    })?;
                for component in missing.iter().rev() {
                    projected.push(component);
                }
                return Ok(lexical_normalize(&projected));
            }
            Err(source) if source.kind() == io::ErrorKind::NotFound => {
                let name = existing.file_name().map(OsString::from).ok_or_else(|| {
                    ConfigError::InspectPath {
                        path: path.to_path_buf(),
                        source: io::Error::new(
                            io::ErrorKind::NotFound,
                            "no existing ancestor could be resolved",
                        ),
                    }
                })?;
                missing.push(name);
                existing.pop();
            }
            Err(source) => {
                return Err(ConfigError::InspectPath {
                    path: existing,
                    source,
                });
            }
        }
    }
}

fn lexical_normalize(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(Path::new(std::path::MAIN_SEPARATOR_STR)),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    normalized
}

#[cfg(test)]
mod tests {
    use std::error::Error as _;

    use tempfile::TempDir;

    use super::*;

    fn fixture() -> Result<(TempDir, XdgDirectories, PathBuf), Box<dyn std::error::Error>> {
        let temporary = TempDir::new()?;
        let sync_root = temporary.path().join("Dropbox");
        fs::create_dir(&sync_root)?;
        let xdg = XdgDirectories::new(
            temporary.path().join("config"),
            temporary.path().join("state"),
        )?;
        fs::create_dir_all(
            xdg.config_file()
                .parent()
                .ok_or("config path had no parent")?,
        )?;
        Ok((temporary, xdg, sync_root))
    }

    fn write_config(xdg: &XdgDirectories, sync_root: &Path) -> Result<(), io::Error> {
        fs::write(
            xdg.config_file(),
            format!(
                "sync_root = {:?}\ndropbox_app_key = \"test-app-key\"\n",
                sync_root.display().to_string()
            ),
        )
    }

    #[test]
    fn config_resolves_xdg_paths_and_prepares_state() -> Result<(), Box<dyn std::error::Error>> {
        let (_temporary, xdg, sync_root) = fixture()?;
        write_config(&xdg, &sync_root)?;

        let config = Config::load_from(&xdg)?;
        config.prepare()?;

        assert_eq!(config.sync_root(), sync_root);
        assert_eq!(config.dropbox_app_key(), "test-app-key");
        assert_eq!(
            config.paths().journal_file(),
            xdg.state_home.join("omabox/journal.sqlite3")
        );
        assert!(config.paths().upload_staging_directory().is_dir());
        assert!(config.paths().recovery_directory().is_dir());
        assert!(!config.paths().journal_file().exists());
        Ok(())
    }

    #[test]
    fn config_write_atomically_replaces_with_owner_only_file()
    -> Result<(), Box<dyn std::error::Error>> {
        let (temporary, xdg, sync_root) = fixture()?;
        let replacement_root = temporary.path().join("Replacement");
        fs::create_dir(&replacement_root)?;
        write_config(&xdg, &sync_root)?;
        fs::set_permissions(xdg.config_file(), fs::Permissions::from_mode(0o644))?;

        let replacement = Config::from_values(&xdg, &replacement_root, "replacement-app-key")?;
        replacement.write()?;

        assert_eq!(
            fs::metadata(xdg.config_file())?.permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(Config::load_from(&xdg)?, replacement);
        let config_file = xdg.config_file();
        let config_directory = config_file.parent().ok_or("config path had no parent")?;
        assert_eq!(fs::read_dir(config_directory)?.count(), 1);
        Ok(())
    }

    #[test]
    fn initial_config_write_never_replaces_an_existing_file()
    -> Result<(), Box<dyn std::error::Error>> {
        let (temporary, xdg, sync_root) = fixture()?;
        let replacement_root = temporary.path().join("Replacement");
        fs::create_dir(&replacement_root)?;
        let existing = Config::from_values(&xdg, &sync_root, "existing-app-key")?;
        existing.write_new()?;
        let original = fs::read(xdg.config_file())?;

        let replacement = Config::from_values(&xdg, &replacement_root, "replacement-app-key")?;
        assert!(matches!(
            replacement.write_new(),
            Err(ConfigError::AlreadyExists { .. })
        ));
        assert_eq!(fs::read(xdg.config_file())?, original);
        Ok(())
    }

    #[test]
    fn prepare_creates_private_runtime_directories() -> Result<(), Box<dyn std::error::Error>> {
        let (_temporary, xdg, sync_root) = fixture()?;
        write_config(&xdg, &sync_root)?;
        let config = Config::load_from(&xdg)?;

        config.prepare()?;

        for path in [
            config.paths().state_directory(),
            config.paths().upload_staging_directory(),
            config.paths().recovery_directory(),
        ] {
            let mode = fs::metadata(path)?.permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "unexpected permissions for {}", path.display());
        }
        Ok(())
    }

    #[test]
    fn prepare_repairs_broad_runtime_directory_permissions()
    -> Result<(), Box<dyn std::error::Error>> {
        let (_temporary, xdg, sync_root) = fixture()?;
        write_config(&xdg, &sync_root)?;
        let config = Config::load_from(&xdg)?;
        let paths = [
            config.paths().state_directory(),
            config.paths().upload_staging_directory(),
            config.paths().recovery_directory(),
        ];
        for path in paths {
            fs::create_dir_all(path)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o777))?;
        }

        config.prepare()?;

        for path in paths {
            let mode = fs::metadata(path)?.permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "unexpected permissions for {}", path.display());
        }
        Ok(())
    }

    #[test]
    fn config_rejects_state_inside_sync_root() -> Result<(), Box<dyn std::error::Error>> {
        let (temporary, _xdg, sync_root) = fixture()?;
        let xdg = XdgDirectories::new(
            temporary.path().join("config-two"),
            sync_root.join("internal-state"),
        )?;
        fs::create_dir_all(
            xdg.config_file()
                .parent()
                .ok_or("config path had no parent")?,
        )?;
        write_config(&xdg, &sync_root)?;

        let error = Config::load_from(&xdg)
            .err()
            .ok_or("unsafe state was accepted")?;
        assert!(matches!(
            error,
            ConfigError::ProtectedPathInsideSyncRoot {
                role: PathRole::StateDirectory,
                ..
            }
        ));
        assert!(!xdg.application_state_directory().exists());
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn config_rejects_symlinked_state_inside_sync_root() -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::symlink;

        let (temporary, _xdg, sync_root) = fixture()?;
        let state_link = temporary.path().join("state-link");
        symlink(&sync_root, &state_link)?;
        let xdg = XdgDirectories::new(temporary.path().join("config-three"), state_link)?;
        fs::create_dir_all(
            xdg.config_file()
                .parent()
                .ok_or("config path had no parent")?,
        )?;
        write_config(&xdg, &sync_root)?;

        let error = Config::load_from(&xdg)
            .err()
            .ok_or("symlinked state was accepted")?;
        assert!(matches!(
            error,
            ConfigError::ProtectedPathInsideSyncRoot { .. }
        ));
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn config_rejects_dangling_state_symlink_into_sync_root_without_creating_target()
    -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::symlink;

        let (temporary, _xdg, sync_root) = fixture()?;
        let absent_target = sync_root.join("not-yet-existing-state");
        let state_link = temporary.path().join("dangling-state-link");
        symlink(&absent_target, &state_link)?;
        let xdg = XdgDirectories::new(temporary.path().join("config-four"), state_link)?;
        fs::create_dir_all(
            xdg.config_file()
                .parent()
                .ok_or("config path had no parent")?,
        )?;
        write_config(&xdg, &sync_root)?;

        let error = match Config::load_from(&xdg) {
            Ok(config) => config
                .prepare()
                .err()
                .ok_or("dangling state symlink was accepted")?,
            Err(error) => error,
        };
        assert!(matches!(error, ConfigError::InspectPath { .. }));
        assert!(!absent_target.exists());
        Ok(())
    }

    #[test]
    fn config_errors_preserve_sources_and_reject_unknown_fields()
    -> Result<(), Box<dyn std::error::Error>> {
        const SENTINEL: &str = "credential-sentinel-must-never-render";

        let (_temporary, xdg, sync_root) = fixture()?;
        fs::write(
            xdg.config_file(),
            format!(
                "sync_root = {:?}\nrefresh_token = {SENTINEL:?}\n",
                sync_root.display().to_string(),
            ),
        )?;

        let error = Config::load_from(&xdg)
            .err()
            .ok_or("secret field was accepted")?;
        assert!(matches!(error, ConfigError::Parse { .. }));
        let source = error.source().ok_or("parse error source was discarded")?;
        for rendered in [
            format!("{error}"),
            format!("{error:?}"),
            format!("{source}"),
            format!("{source:?}"),
        ] {
            assert!(!rendered.contains(SENTINEL));
        }
        let report = format!("{:?}", miette::Report::new(error));
        assert!(!report.contains(SENTINEL));
        Ok(())
    }

    #[test]
    fn config_rejects_empty_app_key_without_rendering_other_values()
    -> Result<(), Box<dyn std::error::Error>> {
        const SENTINEL: &str = "local-path-sentinel";

        let (temporary, xdg, _sync_root) = fixture()?;
        let sync_root = temporary.path().join(SENTINEL);
        fs::create_dir(&sync_root)?;
        fs::write(
            xdg.config_file(),
            format!(
                "sync_root = {:?}\ndropbox_app_key = \"  \"\n",
                sync_root.display().to_string()
            ),
        )?;

        let error = Config::load_from(&xdg)
            .err()
            .ok_or("empty app key was accepted")?;
        assert!(matches!(error, ConfigError::EmptyDropboxAppKey));
        for rendered in [
            format!("{error}"),
            format!("{error:?}"),
            format!("{:?}", miette::Report::new(error)),
        ] {
            assert!(!rendered.contains(SENTINEL));
        }
        Ok(())
    }

    #[test]
    fn xdg_empty_values_use_home_defaults() -> Result<(), Box<dyn std::error::Error>> {
        let temporary = TempDir::new()?;
        let xdg = resolve_xdg_directories(
            Some(temporary.path().as_os_str().to_owned()),
            Some(OsString::new()),
            Some(OsString::new()),
        )?;

        assert_eq!(xdg.config_home, temporary.path().join(".config"));
        assert_eq!(xdg.state_home, temporary.path().join(".local/state"));
        Ok(())
    }

    #[test]
    fn xdg_relative_values_use_home_defaults() -> Result<(), Box<dyn std::error::Error>> {
        let temporary = TempDir::new()?;
        let xdg = resolve_xdg_directories(
            Some(temporary.path().as_os_str().to_owned()),
            Some(OsString::from("relative-config")),
            Some(OsString::from("relative-state")),
        )?;

        assert_eq!(xdg.config_home, temporary.path().join(".config"));
        assert_eq!(xdg.state_home, temporary.path().join(".local/state"));
        Ok(())
    }

    #[test]
    fn xdg_absolute_values_do_not_require_home() -> Result<(), Box<dyn std::error::Error>> {
        let xdg = resolve_xdg_directories(
            None,
            Some(OsString::from("/configured/config")),
            Some(OsString::from("/configured/state")),
        )?;

        assert_eq!(xdg.config_home, Path::new("/configured/config"));
        assert_eq!(xdg.state_home, Path::new("/configured/state"));
        Ok(())
    }

    #[test]
    fn redacted_fields_never_format_the_secret() {
        let secret = "highly-sensitive-token";
        assert_eq!(format!("{}", redacted(secret)), "[REDACTED]");
        assert_eq!(format!("{:?}", redacted(secret)), "[REDACTED]");
    }

    #[test]
    fn lock_contention_is_clean_and_release_is_automatic() -> Result<(), Box<dyn std::error::Error>>
    {
        let temporary = TempDir::new()?;
        let path = temporary.path().join("daemon.lock");
        let first = InstanceLock::acquire(&path)?;

        let error = InstanceLock::acquire(&path)
            .err()
            .ok_or("second lock was acquired")?;
        assert!(matches!(error, LockError::AlreadyRunning { .. }));

        drop(first);
        let second = InstanceLock::acquire(&path)?;
        assert_eq!(second.path(), path);
        assert!(path.exists());
        Ok(())
    }
}
