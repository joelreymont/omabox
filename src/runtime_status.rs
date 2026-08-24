//! Ephemeral daemon status for local user-interface consumers.

use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write as _};
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, SystemTimeError, UNIX_EPOCH};

use serde::Serialize;
use thiserror::Error;

const APPLICATION_DIRECTORY: &str = "omabox";
const STATUS_FILE: &str = "status.json";
const SCHEMA_VERSION: u8 = 2;

/// Current high-level daemon activity.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DaemonPhase {
    /// The process is preparing configuration and credentials.
    Starting,
    /// A reconciliation pass is running.
    Syncing,
    /// The daemon is waiting for Dropbox changes.
    Waiting,
    /// Dropbox requested a retry delay.
    Backoff,
    /// The daemon stopped after a fatal error.
    Error,
}

/// Direction of one active byte transfer.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferDirection {
    /// Local staged bytes are being sent to Dropbox.
    Upload,
    /// Dropbox bytes are being staged locally.
    Download,
}

/// A sampled active transfer. The path is always relative to the sync root.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct TransferProgress {
    direction: TransferDirection,
    path: String,
    bytes_done: u64,
    bytes_total: Option<u64>,
}

impl TransferProgress {
    /// Build a non-secret progress sample for a synchronized path.
    #[must_use]
    pub fn new(
        direction: TransferDirection,
        path: &Path,
        bytes_done: u64,
        bytes_total: Option<u64>,
    ) -> Self {
        Self {
            direction,
            path: display_path(path),
            bytes_done,
            bytes_total,
        }
    }

    fn same_transfer(&self, other: &Self) -> bool {
        self.direction == other.direction && self.path == other.path
    }
}

/// One keyed update from a blocking Dropbox transfer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransferEvent {
    /// The keyed transfer started or made progress.
    Progress(TransferProgress),
    /// The keyed transfer completed or failed.
    Finished(TransferProgress),
}

/// Callback installed on the blocking Dropbox client.
pub type TransferObserver = Arc<dyn Fn(TransferEvent) + Send + Sync>;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct StatusSnapshot {
    version: u8,
    phase: DaemonPhase,
    transfers: Vec<TransferProgress>,
    last_error: Option<&'static str>,
    updated_at: u64,
}

/// Shared handle for publishing the daemon's current ephemeral status.
#[derive(Clone)]
pub struct RuntimeStatus {
    inner: Arc<Mutex<Publisher>>,
}

impl RuntimeStatus {
    /// Create `$XDG_RUNTIME_DIR/omabox/status.json` with owner-only access.
    pub fn from_environment() -> Result<Self, RuntimeStatusError> {
        let runtime = env::var_os("XDG_RUNTIME_DIR").ok_or(RuntimeStatusError::RuntimeMissing)?;
        Self::new(PathBuf::from(runtime))
    }

    /// Create a publisher beneath an explicit XDG runtime directory.
    pub fn new(runtime_directory: impl AsRef<Path>) -> Result<Self, RuntimeStatusError> {
        let runtime_directory = runtime_directory.as_ref();
        if !runtime_directory.is_absolute() {
            return Err(RuntimeStatusError::RuntimeNotAbsolute);
        }
        if !runtime_directory.is_dir() {
            return Err(RuntimeStatusError::RuntimeUnavailable);
        }
        let directory = runtime_directory.join(APPLICATION_DIRECTORY);
        create_private_directory(&directory)?;
        let mut publisher = Publisher {
            path: directory.join(STATUS_FILE),
            directory,
            snapshot: StatusSnapshot {
                version: SCHEMA_VERSION,
                phase: DaemonPhase::Starting,
                transfers: Vec::new(),
                last_error: None,
                updated_at: epoch_seconds()?,
            },
        };
        publisher.publish()?;
        Ok(Self {
            inner: Arc::new(Mutex::new(publisher)),
        })
    }

    /// Publish a phase transition.
    pub fn phase(&self, phase: DaemonPhase) {
        self.update(|publisher| {
            publisher.snapshot.phase = phase;
            publisher.snapshot.transfers.clear();
            true
        });
    }

    /// Refresh `updated_at` without changing observable daemon state.
    pub fn heartbeat(&self) {
        self.update(|_| true);
    }

    /// Publish a fatal, deliberately sanitized error summary.
    pub fn fatal_error(&self, message: &'static str) {
        self.update(|publisher| {
            publisher.snapshot.phase = DaemonPhase::Error;
            publisher.snapshot.transfers.clear();
            publisher.snapshot.last_error = Some(message);
            true
        });
    }

    /// Build the callback used by blocking upload and download readers.
    #[must_use]
    pub fn transfer_observer(&self) -> TransferObserver {
        let status = self.clone();
        Arc::new(move |event| {
            status.update(|publisher| publisher.record_transfer(event));
        })
    }

    fn update(&self, change: impl FnOnce(&mut Publisher) -> bool) {
        let mut publisher = match self.inner.lock() {
            Ok(publisher) => publisher,
            Err(_) => {
                tracing::error!("runtime status publisher lock is unavailable");
                return;
            }
        };
        if !change(&mut publisher) {
            return;
        }
        if let Err(error) = publisher.publish() {
            tracing::warn!(error = %error, "could not publish runtime status");
        }
    }
}

struct Publisher {
    directory: PathBuf,
    path: PathBuf,
    snapshot: StatusSnapshot,
}

impl Publisher {
    fn record_transfer(&mut self, event: TransferEvent) -> bool {
        match event {
            TransferEvent::Progress(progress) => self.record_progress(progress),
            TransferEvent::Finished(finished) => self.finish_transfer(&finished),
        }
    }

    fn record_progress(&mut self, progress: TransferProgress) -> bool {
        match self
            .snapshot
            .transfers
            .iter_mut()
            .find(|current| current.same_transfer(&progress))
        {
            Some(current) => *current = progress,
            None => self.snapshot.transfers.push(progress),
        }
        self.snapshot
            .transfers
            .sort_by(|left, right| left.path.cmp(&right.path));
        true
    }

    fn finish_transfer(&mut self, finished: &TransferProgress) -> bool {
        let previous_len = self.snapshot.transfers.len();
        self.snapshot
            .transfers
            .retain(|current| !current.same_transfer(finished));
        previous_len != self.snapshot.transfers.len()
    }

    fn publish(&mut self) -> Result<(), RuntimeStatusError> {
        let now = epoch_seconds()?;
        self.snapshot.updated_at = now;
        let payload = serde_json::to_vec(&self.snapshot)
            .map_err(|source| RuntimeStatusError::Serialize { source })?;
        let (mut temporary, temporary_path) = self.create_temporary()?;
        if let Err(source) = temporary.write_all(&payload) {
            drop(temporary);
            remove_temporary(&temporary_path);
            return Err(runtime_io("write the temporary status file", source));
        }
        if let Err(source) = temporary.flush() {
            drop(temporary);
            remove_temporary(&temporary_path);
            return Err(runtime_io("flush the temporary status file", source));
        }
        drop(temporary);
        if let Err(source) = fs::rename(&temporary_path, &self.path) {
            remove_temporary(&temporary_path);
            return Err(runtime_io("replace the status file", source));
        }
        Ok(())
    }

    fn create_temporary(&self) -> Result<(File, PathBuf), RuntimeStatusError> {
        let path = self
            .directory
            .join(format!(".status.{}.tmp", std::process::id()));
        remove_temporary(&path);
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|source| runtime_io("create the temporary status file", source))?;
        if let Err(source) = fs::set_permissions(&path, fs::Permissions::from_mode(0o600)) {
            drop(file);
            remove_temporary(&path);
            return Err(runtime_io("secure the temporary status file", source));
        }
        Ok((file, path))
    }
}

fn create_private_directory(path: &Path) -> Result<(), RuntimeStatusError> {
    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    match builder.create(path) {
        Ok(()) => {}
        Err(source) if source.kind() == io::ErrorKind::AlreadyExists && path.is_dir() => {}
        Err(source) => return Err(runtime_io("create the runtime status directory", source)),
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .map_err(|source| runtime_io("secure the runtime status directory", source))
}

fn epoch_seconds() -> Result<u64, RuntimeStatusError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|source| RuntimeStatusError::Clock { source })
}

fn display_path(path: &Path) -> String {
    if path.is_absolute() {
        String::from("(invalid synchronized path)")
    } else if path.as_os_str().is_empty() {
        String::from(".")
    } else {
        path.to_string_lossy().into_owned()
    }
}

fn runtime_io(operation: &'static str, source: io::Error) -> RuntimeStatusError {
    RuntimeStatusError::Io { operation, source }
}

fn remove_temporary(path: &Path) {
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(source) if source.kind() == io::ErrorKind::NotFound => {}
        Err(source) => {
            tracing::warn!(error = %source, "could not remove a temporary runtime status file");
        }
    }
}

/// Failure to initialize or atomically replace ephemeral runtime status.
#[derive(Debug, Error)]
pub enum RuntimeStatusError {
    /// The service environment lacks its per-user runtime directory.
    #[error("XDG_RUNTIME_DIR is not set")]
    RuntimeMissing,
    /// The supplied runtime directory was relative.
    #[error("XDG_RUNTIME_DIR must be absolute")]
    RuntimeNotAbsolute,
    /// The supplied runtime directory does not name an existing directory.
    #[error("XDG_RUNTIME_DIR is unavailable")]
    RuntimeUnavailable,
    /// A runtime filesystem operation failed.
    #[error("could not {operation}")]
    Io {
        /// Safe operation description.
        operation: &'static str,
        /// Underlying filesystem failure.
        #[source]
        source: io::Error,
    },
    /// The system clock was earlier than the Unix epoch.
    #[error("could not timestamp runtime status")]
    Clock {
        /// Underlying clock failure.
        #[source]
        source: SystemTimeError,
    },
    /// The fixed runtime schema could not be encoded.
    #[error("could not encode runtime status")]
    Serialize {
        /// Underlying JSON failure.
        #[source]
        source: serde_json::Error,
    },
}

#[cfg(test)]
mod tests {
    use serde_json::Value;
    use std::error::Error;
    use tempfile::TempDir;

    use super::*;

    #[test]
    fn status_is_private_versioned_and_atomically_replaced() -> Result<(), Box<dyn Error>> {
        let runtime = TempDir::new()?;
        let status = RuntimeStatus::new(runtime.path())?;
        status.phase(DaemonPhase::Waiting);
        status.heartbeat();

        let directory = runtime.path().join(APPLICATION_DIRECTORY);
        let path = directory.join(STATUS_FILE);
        assert_eq!(
            fs::metadata(&directory)?.permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(fs::metadata(&path)?.permissions().mode() & 0o777, 0o600);
        let value = serde_json::from_slice::<Value>(&fs::read(path)?)?;
        assert_eq!(value.as_object().map(|object| object.len()), Some(5));
        assert_eq!(value["version"], 2);
        assert_eq!(value["phase"], "waiting");
        assert_eq!(value["transfers"], serde_json::json!([]));
        assert!(value["updated_at"].as_u64().is_some());
        assert_eq!(value["last_error"], Value::Null);
        assert_eq!(fs::read_dir(directory)?.count(), 1);
        Ok(())
    }

    #[test]
    fn transfer_path_is_relative_and_error_is_fixed_text() -> Result<(), Box<dyn Error>> {
        let runtime = TempDir::new()?;
        let status = RuntimeStatus::new(runtime.path())?;
        let observer = status.transfer_observer();
        observer(TransferEvent::Progress(TransferProgress::new(
            TransferDirection::Download,
            Path::new("folder/report.txt"),
            4,
            Some(10),
        )));
        status.heartbeat();

        let path = runtime.path().join(APPLICATION_DIRECTORY).join(STATUS_FILE);
        let active = serde_json::from_slice::<Value>(&fs::read(&path)?)?;
        assert_eq!(active["transfers"][0]["direction"], "download");
        assert_eq!(active["transfers"][0]["path"], "folder/report.txt");
        assert_eq!(active["transfers"][0]["bytes_done"], 4);
        assert_eq!(active["transfers"][0]["bytes_total"], 10);

        observer(TransferEvent::Finished(TransferProgress::new(
            TransferDirection::Download,
            Path::new("folder/report.txt"),
            0,
            None,
        )));
        status.fatal_error("Dropbox authentication is unavailable.");
        let failed = serde_json::from_slice::<Value>(&fs::read(path)?)?;
        assert_eq!(failed["phase"], "error");
        assert_eq!(failed["transfers"], serde_json::json!([]));
        assert_eq!(
            failed["last_error"],
            "Dropbox authentication is unavailable."
        );
        Ok(())
    }

    #[test]
    fn every_active_transfer_is_published_until_it_finishes() -> Result<(), Box<dyn Error>> {
        let runtime = TempDir::new()?;
        let status = RuntimeStatus::new(runtime.path())?;
        let observer = status.transfer_observer();
        let first = TransferProgress::new(
            TransferDirection::Download,
            Path::new("first.txt"),
            3,
            Some(10),
        );
        let second = TransferProgress::new(
            TransferDirection::Download,
            Path::new("second.txt"),
            7,
            Some(20),
        );
        observer(TransferEvent::Progress(first.clone()));
        observer(TransferEvent::Progress(second.clone()));

        let path = runtime.path().join(APPLICATION_DIRECTORY).join(STATUS_FILE);
        let stable = serde_json::from_slice::<Value>(&fs::read(&path)?)?;
        assert_eq!(stable["transfers"].as_array().map(Vec::len), Some(2));
        assert_eq!(stable["transfers"][0]["path"], "first.txt");
        assert_eq!(stable["transfers"][1]["path"], "second.txt");

        observer(TransferEvent::Finished(first));
        let promoted = serde_json::from_slice::<Value>(&fs::read(&path)?)?;
        assert_eq!(promoted["transfers"].as_array().map(Vec::len), Some(1));
        assert_eq!(promoted["transfers"][0]["path"], "second.txt");
        assert_eq!(promoted["transfers"][0]["bytes_done"], 7);

        observer(TransferEvent::Finished(second));
        let complete = serde_json::from_slice::<Value>(&fs::read(path)?)?;
        assert_eq!(complete["transfers"], serde_json::json!([]));
        Ok(())
    }

    #[test]
    fn failed_replacement_does_not_leave_a_temporary_file() -> Result<(), Box<dyn Error>> {
        let runtime = TempDir::new()?;
        let status = RuntimeStatus::new(runtime.path())?;
        let directory = runtime.path().join(APPLICATION_DIRECTORY);
        let path = directory.join(STATUS_FILE);
        fs::remove_file(&path)?;
        fs::create_dir(&path)?;

        status.phase(DaemonPhase::Syncing);

        let names = fs::read_dir(directory)?
            .map(|entry| entry.map(|entry| entry.file_name()))
            .collect::<Result<Vec<_>, _>>()?;
        assert_eq!(names, [STATUS_FILE]);
        Ok(())
    }
}
