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
use rustix::fs::OFlags;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::stale::{self, Leftover};

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
        self.config_directory().join(CONFIG_FILE)
    }

    fn config_directory(&self) -> PathBuf {
        self.config_home.join(APPLICATION_DIRECTORY)
    }

    fn application_state_directory(&self) -> PathBuf {
        self.state_home.join(APPLICATION_DIRECTORY)
    }
}

/// Paths owned by one Omabox instance. [`Config`] holds them only after
/// checking they lie outside its sync root; [`Paths::resolve_private`] does not
/// check.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Paths {
    config_directory: PathBuf,
    state_directory: PathBuf,
    journal_file: PathBuf,
    upload_staging_directory: PathBuf,
    recovery_directory: PathBuf,
    lock_file: PathBuf,
}

impl Paths {
    /// Resolve every path this instance owns, without checking them against a sync root.
    ///
    /// The staging and recovery directories are the ones opened with
    /// `RESOLVE_NO_SYMLINKS`, so a symlinked XDG ancestor or leaf would make
    /// every open of them fail with `ELOOP`. The state directory is only
    /// created, the journal is opened by SQLite, and the lock by
    /// `OpenOptions`; all five are stored physically anyway so the whole
    /// private tree lives in one namespace, and `validate_outside` compares
    /// every private path physically. Each leaf is projected in its own right,
    /// so a relinked `upload-staging` is followed too, not just a symlinked
    /// ancestor. The configuration directory stays lexical: it is read and
    /// written with symlink-following calls, so a user may keep it in a
    /// dotfiles tree.
    pub fn resolve_private(xdg: &XdgDirectories) -> Result<Self, ConfigError> {
        let state = xdg.application_state_directory();
        Ok(Self {
            config_directory: lexical_normalize(&xdg.config_directory()),
            state_directory: project_physical_path(&state, Dangling::Refuse)?,
            journal_file: project_physical_path(&state.join(JOURNAL_FILE), Dangling::Refuse)?,
            upload_staging_directory: project_physical_path(
                &state.join(UPLOAD_STAGING_DIRECTORY),
                Dangling::Refuse,
            )?,
            recovery_directory: project_physical_path(
                &state.join(RECOVERY_DIRECTORY),
                Dangling::Refuse,
            )?,
            lock_file: project_physical_path(&state.join(LOCK_FILE), Dangling::Refuse)?,
        })
    }

    /// Check every private path lies outside `sync_root`. The root need not
    /// exist: it is compared by the physical path it will have once it does,
    /// following dangling symlinks; a root whose projection fails is refused.
    /// [`Config::validate_with`] checks again with the canonical root before
    /// anything reads it.
    fn validate_outside(&self, sync_root: &Path) -> Result<(), ConfigError> {
        let physical_root = project_physical_path(sync_root, Dangling::Follow)?;
        for (role, path) in [
            (PathRole::Config, self.config_directory()),
            (PathRole::StateDirectory, self.state_directory()),
            (PathRole::Journal, self.journal_file()),
            (PathRole::UploadStaging, self.upload_staging_directory()),
            (PathRole::Recovery, self.recovery_directory()),
            (PathRole::Lock, self.lock_file()),
        ] {
            let projected = project_physical_path(path, Dangling::Refuse)?;
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
    pub(crate) fn prepare(&self, sync_root: &Path) -> Result<(), ConfigError> {
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

    /// XDG configuration directory reserved for Omabox.
    #[must_use]
    pub fn config_directory(&self) -> &Path {
        &self.config_directory
    }

    /// Path to the non-secret TOML configuration file.
    #[must_use]
    pub fn config_file(&self) -> PathBuf {
        self.config_directory.join(CONFIG_FILE)
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

/// Stored non-secret configuration, read without touching the sync root.
///
/// Loading checks only that `sync_root` is absolute and `dropbox_app_key` is
/// non-empty, so the stored settings stay readable while the root is
/// unavailable. [`Config::validate`] resolves the root and the state paths.
/// Built only through `checked`, so every value passed those checks.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConfigDocument {
    sync_root: PathBuf,
    dropbox_app_key: String,
}

/// On-disk form of the configuration file, unchecked.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct StoredDocument {
    sync_root: PathBuf,
    dropbox_app_key: String,
}

impl ConfigDocument {
    /// Load the stored configuration using the process XDG environment.
    pub fn load() -> Result<Self, ConfigError> {
        Self::load_from(&XdgDirectories::from_environment()?)
    }

    /// Load the stored configuration from explicit XDG base directories.
    pub fn load_from(xdg: &XdgDirectories) -> Result<Self, ConfigError> {
        let document = read_config_document(xdg)?;
        Self::checked(document.sync_root, document.dropbox_app_key)
    }

    fn checked(sync_root: PathBuf, dropbox_app_key: String) -> Result<Self, ConfigError> {
        let sync_root = require_absolute("sync_root", sync_root)?;
        if dropbox_app_key.trim().is_empty() {
            return Err(ConfigError::EmptyDropboxAppKey);
        }
        Ok(Self {
            sync_root,
            dropbox_app_key,
        })
    }

    /// Stored local sync root, absolute and lexically normalized but not resolved.
    #[must_use]
    pub fn sync_root(&self) -> &Path {
        &self.sync_root
    }

    /// Public Dropbox application key used for OAuth.
    #[must_use]
    pub fn dropbox_app_key(&self) -> &str {
        &self.dropbox_app_key
    }
}

impl Config {
    /// Load configuration using the process XDG environment.
    pub fn load() -> Result<Self, ConfigError> {
        Self::load_from(&XdgDirectories::from_environment()?)
    }

    /// Load configuration from explicit XDG base directories.
    pub fn load_from(xdg: &XdgDirectories) -> Result<Self, ConfigError> {
        Self::validate(&ConfigDocument::load_from(xdg)?, xdg)
    }

    /// Validate a configuration supplied by a setup or settings command.
    pub fn from_values(
        xdg: &XdgDirectories,
        sync_root: impl Into<PathBuf>,
        dropbox_app_key: impl Into<String>,
    ) -> Result<Self, ConfigError> {
        let document = ConfigDocument::checked(sync_root.into(), dropbox_app_key.into())?;
        Self::validate(&document, xdg)
    }

    /// Resolve a stored configuration's sync root and check the state paths lie outside it.
    pub fn validate(document: &ConfigDocument, xdg: &XdgDirectories) -> Result<Self, ConfigError> {
        Self::validate_with(document, Paths::resolve_private(xdg)?)
    }

    /// Validate `document` against `paths` already resolved, so the
    /// configuration holds the same paths the caller has opened.
    pub fn validate_with(document: &ConfigDocument, paths: Paths) -> Result<Self, ConfigError> {
        let sync_root = canonicalize_sync_root(document.sync_root())?;
        paths.validate_outside(&sync_root)?;
        Ok(Self {
            sync_root,
            dropbox_app_key: document.dropbox_app_key.clone(),
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

    /// Atomically persist this non-secret configuration with owner-only access,
    /// and return the stale temporaries the write could not remove.
    pub fn write(&self) -> Result<Vec<Leftover>, ConfigError> {
        self.write_with_replacement(true)
    }

    /// Atomically persist initial configuration without replacing an existing
    /// file, and return the stale temporaries the write could not remove.
    pub fn write_new(&self) -> Result<Vec<Leftover>, ConfigError> {
        self.write_with_replacement(false)
    }

    fn write_with_replacement(&self, replace_existing: bool) -> Result<Vec<Leftover>, ConfigError> {
        let document = StoredDocument {
            sync_root: self.sync_root.clone(),
            dropbox_app_key: self.dropbox_app_key.clone(),
        };
        let contents = toml::to_string(&document).map_err(ConfigError::Serialize)?;
        atomic_write_config(
            &self.paths.config_file(),
            contents.as_bytes(),
            replace_existing,
        )
    }
}

fn read_config_document(xdg: &XdgDirectories) -> Result<StoredDocument, ConfigError> {
    let config_file = xdg.config_file();
    let contents = fs::read_to_string(&config_file).map_err(|source| ConfigError::Read {
        path: config_file.clone(),
        source,
    })?;
    toml::from_str::<StoredDocument>(&contents).map_err(|mut source| {
        source.set_input(None);
        ConfigError::Parse {
            path: config_file,
            source,
        }
    })
}

/// Safety-sensitive path role used in diagnostics.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PathRole {
    /// XDG application configuration directory.
    Config,
    /// XDG application state directory.
    StateDirectory,
    /// Transactional journal.
    Journal,
    /// Immutable upload staging directory.
    UploadStaging,
    /// Legacy recovery directory.
    Recovery,
    /// Daemon instance lock.
    Lock,
}

impl PathRole {
    /// XDG base-directory variable that governs where this path lives.
    fn xdg_variable(self) -> &'static str {
        match self {
            Self::Config => "XDG_CONFIG_HOME",
            Self::StateDirectory
            | Self::Journal
            | Self::UploadStaging
            | Self::Recovery
            | Self::Lock => "XDG_STATE_HOME",
        }
    }
}

impl fmt::Display for PathRole {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Config => "configuration directory",
            Self::StateDirectory => "state directory",
            Self::Journal => "journal",
            Self::UploadStaging => "upload staging directory",
            Self::Recovery => "recovery directory",
            Self::Lock => "daemon lock",
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
    #[error(
        "the configuration write failed and cleanup also failed: {}; the incomplete owner-only temporary file is ignored",
        .cleanup[0]
    )]
    #[diagnostic(code(omabox::config::cleanup_after_write), forward(write))]
    CleanupAfterWrite {
        /// Original write failure.
        #[source]
        write: Box<ConfigError>,
        /// The single cleanup failure, rendered as a related diagnostic.
        #[related]
        cleanup: Box<[ConfigError; 1]>,
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
        help("Set {} to a local directory outside the sync root.", role.xdg_variable())
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
) -> Result<Vec<Leftover>, ConfigError> {
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

    // A failed write drops these; the next write sweeps again.
    let leftovers = stale::sweep(parent, format!(".{CONFIG_FILE}.").as_bytes(), b".tmp");
    let sequence = CONFIG_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(
        ".{CONFIG_FILE}.{}.{}.tmp",
        std::process::id(),
        sequence
    ));
    match write_config_temporary(&temporary, path, parent, contents, replace_existing) {
        Ok(()) => Ok(leftovers),
        Err(write) => match fs::remove_file(&temporary) {
            Ok(()) => Err(write),
            Err(cleanup) if cleanup.kind() == io::ErrorKind::NotFound => Err(write),
            Err(cleanup) => Err(cleanup_after_write(temporary, write, cleanup)),
        },
    }
}

fn cleanup_after_write(temporary: PathBuf, write: ConfigError, cleanup: io::Error) -> ConfigError {
    ConfigError::CleanupAfterWrite {
        cleanup: Box::new([ConfigError::Write {
            operation: "remove the temporary",
            path: temporary,
            source: cleanup,
        }]),
        write: Box::new(write),
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

/// Create `path` as an owner-only regular file, or accept one that already
/// exists.
///
/// `O_EXCL` reports a dangling symlink as an existing file, so the link itself
/// is inspected before any caller follows it. Symlinks, directories, and
/// special files are refused rather than written through, which stops a
/// planted link from redirecting durable state to an attacker-chosen path.
pub(crate) fn create_owner_only(path: &Path) -> Result<(), io::Error> {
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(_) => Ok(()),
        Err(source) if source.kind() == io::ErrorKind::AlreadyExists => {
            if fs::symlink_metadata(path)?.file_type().is_file() {
                Ok(())
            } else {
                Err(io::Error::other("existing path is not a regular file"))
            }
        }
        Err(source) => Err(source),
    }
}

/// The held kernel lock for one daemon instance.
///
/// Dropping this value unlocks the file before closing it, so the lock is
/// released even while a child forked meanwhile still holds a copy of its
/// descriptor. The lock file is intentionally not deleted: its presence does not indicate ownership, so no
/// stale-file cleanup or recovery protocol is needed.
#[derive(Debug)]
pub struct InstanceLock {
    file: File,
    path: PathBuf,
}

impl InstanceLock {
    /// Try to acquire the daemon lock without waiting.
    pub fn acquire(path: impl AsRef<Path>) -> Result<Self, LockError> {
        let path = path.as_ref();
        create_owner_only(path).map_err(|source| LockError::Open {
            path: path.to_path_buf(),
            source,
        })?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(OFlags::NOFOLLOW.bits().cast_signed())
            .open(path)
            .map_err(|source| LockError::Open {
                path: path.to_path_buf(),
                source,
            })?;
        match file.try_lock() {
            Ok(()) => Ok(Self {
                file,
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

impl Drop for InstanceLock {
    fn drop(&mut self) {
        if let Err(error) = self.file.unlock() {
            tracing::warn!(
                path = %self.path.display(),
                error = %error,
                "could not unlock the daemon lock file; closing it instead"
            );
        }
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
        None => default_config_home(home.as_ref().ok_or(ConfigError::HomeDirectoryUnavailable)?),
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

/// Resolve the XDG config home for an absolute `home`.
///
/// An empty or relative `XDG_CONFIG_HOME` is ignored and `home/.config` is
/// used, as for [`XdgDirectories::from_environment`].
pub(crate) fn resolve_config_home(home: &Path, configured: Option<OsString>) -> PathBuf {
    match valid_xdg_home(configured) {
        Some(path) => path,
        None => default_config_home(home),
    }
}

fn default_config_home(home: &Path) -> PathBuf {
    home.join(".config")
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

/// How [`project_physical_path`] treats a dangling symlink on the way.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Dangling {
    /// A dangling symlink on the way fails the projection, for a path Omabox creates.
    Refuse,
    /// A dangling symlink on the way is followed to where its target would be,
    /// for a path that is only compared.
    Follow,
}

/// Symlinks one projection may follow, as Linux's `MAXSYMLINKS`.
const MAX_SYMLINK_HOPS: usize = 40;

/// The physical path `path` has, or will have once its missing components
/// exist: the nearest existing ancestor is canonicalized; `dangling` says
/// whether a dangling symlink on the way fails the projection or is followed.
/// Missing components count as plain directories, so a `..` after one leaves it.
fn project_physical_path(path: &Path, dangling: Dangling) -> Result<PathBuf, ConfigError> {
    let mut current = path.to_path_buf();
    let mut hops = 0;
    loop {
        match project_once(&current, dangling)? {
            Projection::Physical(projected) => return Ok(projected),
            Projection::Dangling(next) if hops < MAX_SYMLINK_HOPS => {
                hops += 1;
                current = next;
            }
            Projection::Dangling(_) => {
                return Err(ConfigError::InspectPath {
                    path: path.to_path_buf(),
                    // `ELOOP`, whose kind is `FilesystemLoop`, as the kernel reports it.
                    source: io::Error::from_raw_os_error(rustix::io::Errno::LOOP.raw_os_error()),
                });
            }
        }
    }
}

/// One step of [`project_physical_path`].
enum Projection {
    /// The physical path, fully projected.
    Physical(PathBuf),
    /// The path a followed dangling symlink leads to, still to be projected.
    Dangling(PathBuf),
}

fn project_once(path: &Path, dangling: Dangling) -> Result<Projection, ConfigError> {
    let mut existing = path.to_path_buf();
    let mut missing = Vec::<OsString>::new();
    loop {
        match fs::symlink_metadata(&existing) {
            Ok(metadata) => {
                let canonical = match fs::canonicalize(&existing) {
                    Ok(canonical) => canonical,
                    Err(source)
                        if dangling == Dangling::Follow
                            && metadata.file_type().is_symlink()
                            && source.kind() == io::ErrorKind::NotFound =>
                    {
                        let target = fs::read_link(&existing).map_err(|source| {
                            ConfigError::InspectPath {
                                path: existing.clone(),
                                source,
                            }
                        })?;
                        let mut next = existing
                            .parent()
                            .map_or_else(PathBuf::new, Path::to_path_buf)
                            .join(target);
                        for component in missing.iter().rev() {
                            next.push(component);
                        }
                        return Ok(Projection::Dangling(next));
                    }
                    Err(source) => {
                        return Err(ConfigError::InspectPath {
                            path: existing,
                            source,
                        });
                    }
                };
                let mut projected = canonical;
                for component in missing.iter().rev() {
                    projected.push(component);
                }
                return Ok(Projection::Physical(lexical_normalize(&projected)));
            }
            Err(source) if source.kind() == io::ErrorKind::NotFound => {
                if existing.components().next_back() == Some(Component::ParentDir) {
                    missing.push(OsString::from(".."));
                    existing.pop();
                    continue;
                }
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
            fs::canonicalize(&xdg.state_home)?.join("omabox/journal.sqlite3")
        );
        assert!(config.paths().upload_staging_directory().is_dir());
        assert!(config.paths().recovery_directory().is_dir());
        assert!(!config.paths().journal_file().exists());
        Ok(())
    }

    #[test]
    fn document_loads_when_the_recorded_root_is_unavailable()
    -> Result<(), Box<dyn std::error::Error>> {
        let (_temporary, xdg, sync_root) = fixture()?;
        write_config(&xdg, &sync_root)?;
        let available = Config::load_from(&xdg)?;
        fs::remove_dir(&sync_root)?;

        assert!(matches!(
            Config::load_from(&xdg),
            Err(ConfigError::ResolveSyncRoot { .. })
        ));
        let document = ConfigDocument::load_from(&xdg)?;
        assert_eq!(document.sync_root(), sync_root);
        assert_eq!(document.dropbox_app_key(), "test-app-key");
        assert_eq!(&Paths::resolve_private(&xdg)?, available.paths());
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

    #[cfg(unix)]
    #[test]
    fn relinked_runtime_leaves_are_projected_individually() -> Result<(), Box<dyn std::error::Error>>
    {
        use std::os::unix::fs::symlink;

        let (temporary, xdg, sync_root) = fixture()?;
        let elsewhere = temporary.path().join("elsewhere");
        fs::create_dir(&elsewhere)?;
        fs::create_dir_all(xdg.application_state_directory())?;
        symlink(
            &elsewhere,
            xdg.application_state_directory()
                .join(UPLOAD_STAGING_DIRECTORY),
        )?;
        write_config(&xdg, &sync_root)?;

        let config = Config::load_from(&xdg)?;
        config.prepare()?;

        assert_eq!(
            config.paths().upload_staging_directory(),
            fs::canonicalize(&elsewhere)?
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn projection_follows_a_dangling_absolute_symlink() -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::symlink;

        let temporary = TempDir::new()?;
        let link = temporary.path().join("link");
        symlink(temporary.path().join("data/sub"), &link)?;

        assert_eq!(
            project_physical_path(&link.join("leaf"), Dangling::Follow)?,
            fs::canonicalize(temporary.path())?.join("data/sub/leaf")
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn projection_follows_a_dangling_relative_symlink() -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::symlink;

        let temporary = TempDir::new()?;
        fs::create_dir(temporary.path().join("links"))?;
        let link = temporary.path().join("links/link");
        symlink("../data/sub", &link)?;

        assert_eq!(
            project_physical_path(&link.join("leaf"), Dangling::Follow)?,
            fs::canonicalize(temporary.path())?.join("data/sub/leaf")
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn projection_leaves_a_missing_component_on_parent() -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::symlink;

        let temporary = TempDir::new()?;
        let expected = fs::canonicalize(temporary.path())?.join("data/leaf");
        fs::create_dir(temporary.path().join("links"))?;
        let link = temporary.path().join("links/link");
        symlink("../missing/../data", &link)?;

        assert_eq!(
            project_physical_path(&link.join("leaf"), Dangling::Follow)?,
            expected
        );
        assert_eq!(
            project_physical_path(
                &temporary.path().join("missing/../data/leaf"),
                Dangling::Refuse
            )?,
            expected
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn projection_refuses_a_symlink_loop() -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::symlink;

        let temporary = TempDir::new()?;
        let first = temporary.path().join("first");
        symlink(temporary.path().join("second"), &first)?;
        symlink(&first, temporary.path().join("second"))?;

        let error = project_physical_path(&first, Dangling::Follow)
            .err()
            .ok_or("a symlink loop was projected")?;
        assert!(
            matches!(
                &error,
                ConfigError::InspectPath { source, .. }
                    if source.raw_os_error() == Some(rustix::io::Errno::LOOP.raw_os_error())
            ),
            "unexpected error: {error:?}"
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn refusing_projection_fails_on_a_dangling_symlink() -> Result<(), Box<dyn std::error::Error>> {
        use std::os::unix::fs::symlink;

        let temporary = TempDir::new()?;
        let link = temporary.path().join("link");
        symlink(temporary.path().join("data"), &link)?;

        let error = project_physical_path(&link.join("leaf"), Dangling::Refuse)
            .err()
            .ok_or("a dangling symlink was followed")?;
        assert!(
            matches!(error, ConfigError::InspectPath { .. }),
            "unexpected error: {error:?}"
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn prepare_refuses_state_below_a_dangling_root_target() -> Result<(), Box<dyn std::error::Error>>
    {
        use std::os::unix::fs::symlink;

        let temporary = TempDir::new()?;
        let root = temporary.path().join("root");
        let data = temporary.path().join("data");
        symlink(&data, &root)?;
        let xdg = XdgDirectories::new(temporary.path().join("config"), data.join("state"))?;
        let paths = Paths::resolve_private(&xdg)?;

        let error = paths
            .prepare(&root)
            .err()
            .ok_or("state below the root's target was accepted")?;
        assert!(
            matches!(error, ConfigError::ProtectedPathInsideSyncRoot { .. }),
            "unexpected error: {error:?}"
        );
        assert!(!data.exists());
        Ok(())
    }

    #[test]
    fn config_rejects_sync_root_containing_the_config_directory()
    -> Result<(), Box<dyn std::error::Error>> {
        let temporary = TempDir::new()?;
        let sync_root = temporary.path().join("Dropbox");
        fs::create_dir(&sync_root)?;
        let xdg = XdgDirectories::new(&sync_root, temporary.path().join("state"))?;

        let error = Config::from_values(&xdg, &sync_root, "test-app-key")
            .err()
            .ok_or("config directory inside sync root was accepted")?;

        assert!(
            matches!(
                error,
                ConfigError::ProtectedPathInsideSyncRoot {
                    role: PathRole::Config,
                    ..
                }
            ),
            "unexpected error: {error:?}"
        );
        let help = error
            .help()
            .ok_or("protected path error rendered no help")?
            .to_string();
        assert_eq!(
            help,
            "Set XDG_CONFIG_HOME to a local directory outside the sync root."
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn config_rejects_a_lock_symlinked_into_the_sync_root() -> Result<(), Box<dyn std::error::Error>>
    {
        use std::os::unix::fs::symlink;

        let (_temporary, xdg, sync_root) = fixture()?;
        let stolen = sync_root.join("stolen.lock");
        fs::write(&stolen, b"")?;
        fs::create_dir_all(xdg.application_state_directory())?;
        symlink(&stolen, xdg.application_state_directory().join(LOCK_FILE))?;
        write_config(&xdg, &sync_root)?;

        let error = Config::load_from(&xdg)
            .err()
            .ok_or("lock inside sync root was accepted")?;

        assert!(
            matches!(
                error,
                ConfigError::ProtectedPathInsideSyncRoot {
                    role: PathRole::Lock,
                    ..
                }
            ),
            "unexpected error: {error:?}"
        );
        let help = error
            .help()
            .ok_or("protected path error rendered no help")?
            .to_string();
        assert_eq!(
            help,
            "Set XDG_STATE_HOME to a local directory outside the sync root."
        );
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
    fn cleanup_after_write_renders_both_chains_and_both_helps() {
        let write = ConfigError::Write {
            operation: "write a temporary",
            path: PathBuf::from("/config.tmp"),
            source: io::Error::other("write-inner-cause"),
        };
        let error = cleanup_after_write(
            PathBuf::from("/config.tmp"),
            write,
            io::Error::other("cleanup-inner-cause"),
        );
        // miette wraps help at the terminal width; compare word sequences.
        let rendered = format!("{:?}", miette::Report::new(error));
        let report = rendered.split_whitespace().collect::<Vec<_>>().join(" ");
        for text in ["write-inner-cause", "cleanup-inner-cause"] {
            assert!(report.contains(text), "missing {text:?} in:\n{report}");
        }
        // Both failures are `Write`, so the primary's forwarded help and the
        // related cleanup's help are the same text, rendered twice.
        let help = "Ensure the XDG configuration location is owned by this user and writable.";
        assert_eq!(
            report.matches(help).count(),
            2,
            "want both helps in:\n{report}"
        );
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
    fn daemon_lock_file_is_created_for_its_owner_only() -> Result<(), Box<dyn std::error::Error>> {
        let temporary = TempDir::new()?;
        let path = temporary.path().join("daemon.lock");

        let lock = InstanceLock::acquire(&path)?;

        assert_eq!(fs::metadata(&path)?.permissions().mode() & 0o777, 0o600);
        drop(lock);
        Ok(())
    }

    #[test]
    fn daemon_lock_refuses_a_symlinked_lock_file() -> Result<(), Box<dyn std::error::Error>> {
        let temporary = TempDir::new()?;
        let planted = temporary.path().join("planted.lock");
        let dangling = temporary.path().join("dangling.lock");
        std::os::unix::fs::symlink(&planted, &dangling)?;

        let error = InstanceLock::acquire(&dangling)
            .err()
            .ok_or("a dangling symlink was accepted as a lock file")?;
        assert!(
            matches!(error, LockError::Open { .. }),
            "unexpected error: {error:?}"
        );
        assert!(
            !planted.try_exists()?,
            "the lock file was created through a dangling symlink"
        );

        let existing = temporary.path().join("existing.lock");
        drop(InstanceLock::acquire(&existing)?);
        let linked = temporary.path().join("linked.lock");
        std::os::unix::fs::symlink(&existing, &linked)?;

        let error = InstanceLock::acquire(&linked)
            .err()
            .ok_or("a symlink to a lock file was accepted")?;
        assert!(
            matches!(error, LockError::Open { .. }),
            "unexpected error: {error:?}"
        );
        Ok(())
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

    #[test]
    fn dropping_the_lock_releases_it_while_a_descriptor_copy_is_open()
    -> Result<(), Box<dyn std::error::Error>> {
        let temporary = TempDir::new()?;
        let path = temporary.path().join("daemon.lock");
        let first = InstanceLock::acquire(&path)?;
        // The duplicate shares the open file description, as a forked child's
        // copy of the descriptor does.
        let copy = rustix::io::dup(&first.file)?;

        drop(first);
        let second = InstanceLock::acquire(&path)?;

        assert_eq!(second.path(), path);
        drop(copy);
        Ok(())
    }
}
