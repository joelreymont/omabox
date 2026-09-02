//! Root-confined local observation and crash-safe file phases.

#[cfg(test)]
use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rustix::fd::{AsFd, OwnedFd};
use rustix::fs::{
    AtFlags, CWD, Dir, FileType, Mode, OFlags, RenameFlags, ResolveFlags, XattrFlags, fchmod,
    fgetxattr, fremovexattr, fsetxattr, fstat, fstatvfs, fsync, linkat, mkdirat, openat2,
    renameat_with, unlinkat,
};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::journal::{
    Journal, JournalError, LocalFileFingerprint, LocalHashRecord, LocalObservationRecord,
    LocalRootBinding, OperationId,
};
use crate::model::{ContentIdentity, LocalFile, Observation, UnknownReason};

const DROPBOX_BLOCK_SIZE: usize = 4 * 1024 * 1024;
const HASH_IO_BUFFER_SIZE: usize = 64 * 1024;
const MAX_PARALLEL_HASHES: usize = 12;
// Exceeds FAT's two-second mtime tick. The cache requires coherent local
// filesystem metadata; arbitrary stale network metadata is not supported.
const HASH_CACHE_RACY_WINDOW: Duration = Duration::from_secs(3);
const DOWNLOAD_STAGE_XATTR: &str = "user.omabox.download-stage-v1";
const DOWNLOAD_PARTIAL_XATTR: &str = "user.omabox.download-partial-v1";
const DOWNLOAD_CHECKPOINT_BYTES: u64 = 64 * 1024 * 1024;
const DOWNLOAD_SLOT_OWNER_PREFIX: &[u8] = b"omabox-download-slot-v1";
const DOWNLOAD_SLOT_STATE_LENGTH: usize = DOWNLOAD_SLOT_OWNER_PREFIX.len() + 32 + 8;
pub(crate) const MAX_PARALLEL_DOWNLOADS: usize = 4;
const BELOW_ROOT: ResolveFlags = ResolveFlags::BENEATH
    .union(ResolveFlags::NO_SYMLINKS)
    .union(ResolveFlags::NO_MAGICLINKS);
const ABSOLUTE_SAFE: ResolveFlags = ResolveFlags::NO_SYMLINKS.union(ResolveFlags::NO_MAGICLINKS);

/// Coordinates complete scans with daemon-owned mutations inside the sync root.
#[derive(Default)]
pub(crate) struct SyncRootAccess {
    lock: RwLock<()>,
}

impl SyncRootAccess {
    pub(crate) fn with_shared<T>(&self, action: impl FnOnce() -> T) -> T {
        let _guard = match self.lock.read() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        action()
    }

    pub(crate) fn with_exclusive<T>(&self, action: impl FnOnce() -> T) -> T {
        let _guard = match self.lock.write() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        };
        action()
    }
}

/// A local filesystem or local-inventory publication failure.
#[derive(Debug, Error)]
pub enum LocalError {
    /// A supplied synchronized path was not a safe, non-empty relative path.
    #[error("local path `{path}` is not a safe path relative to the sync root")]
    UnsafeRelativePath {
        /// Rejected path.
        path: PathBuf,
    },
    /// A path resolved to a symlink, magic link, or unsupported object.
    #[error("local path `{path}` is not a regular file or directory")]
    UnsupportedObject {
        /// Rejected path.
        path: PathBuf,
    },
    /// A file or directory changed while it was being observed.
    #[error("local path `{path}` changed during `{operation}`")]
    ChangedDuringRead {
        /// Operation that required a stable view.
        operation: &'static str,
        /// Path whose metadata changed.
        path: PathBuf,
    },
    /// A supplied identity was not a Dropbox content hash.
    #[error("operation `{operation}` requires a lowercase Dropbox content hash")]
    InvalidContentIdentity {
        /// Operation that consumed the identity.
        operation: &'static str,
    },
    /// A private staged or displaced file did not contain its named bytes.
    #[error("private local file for `{operation}` at `{path}` failed content verification")]
    CorruptPrivateFile {
        /// Operation using the private file.
        operation: &'static str,
        /// Private file path, without its contents.
        path: PathBuf,
    },
    /// A private path was already occupied by unrelated bytes.
    #[error("non-overwriting operation `{operation}` found unrelated bytes at `{path}`")]
    DestinationOccupied {
        /// Operation that refused to overwrite.
        operation: &'static str,
        /// Occupied path.
        path: PathBuf,
    },
    /// An operating-system filesystem operation failed.
    #[error("local filesystem operation `{operation}` failed for `{path}`")]
    Io {
        /// Operation being attempted.
        operation: &'static str,
        /// Affected path.
        path: PathBuf,
        /// Original operating-system error.
        #[source]
        source: io::Error,
    },
    /// The complete scan could not be published transactionally.
    #[error("could not publish the complete local inventory")]
    Journal {
        /// Original journal error.
        #[source]
        source: JournalError,
    },
    /// A bounded local hashing worker could not be started.
    #[error("could not start local hashing worker {worker}")]
    HashWorkerSpawn {
        /// Zero-based worker number.
        worker: usize,
        /// Original operating-system error.
        #[source]
        source: io::Error,
    },
    /// A bounded local hashing worker terminated without returning a result.
    #[error("local hashing worker {worker} terminated unexpectedly")]
    HashWorkerTerminated {
        /// Zero-based worker number.
        worker: usize,
    },
}

/// Failure while copying stage input, preserving whether the source or local storage failed.
#[derive(Debug, Error)]
pub(crate) enum StageIoError {
    /// Reading the supplied byte stream failed.
    #[error("could not read stage input during `{operation}` for `{path}`")]
    Read {
        operation: &'static str,
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    /// A local staging operation failed.
    #[error(transparent)]
    Local {
        #[from]
        source: LocalError,
    },
}

impl From<StageIoError> for LocalError {
    fn from(error: StageIoError) -> Self {
        match error {
            StageIoError::Read {
                operation,
                path,
                source,
            } => io_failure(operation, &path, source),
            StageIoError::Local { source } => source,
        }
    }
}

/// A hashing failure from the source stream.
#[derive(Debug, Error)]
pub enum HashError {
    /// Reading the byte stream failed.
    #[error("could not read bytes while computing the Dropbox content hash")]
    Read {
        /// Original read error.
        #[source]
        source: io::Error,
    },
}

/// A complete local inventory, safe to publish for absence decisions.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompleteScan {
    root_binding: LocalRootBinding,
    observations: Vec<LocalObservationRecord>,
    reusable_hashes: Vec<LocalHashRecord>,
}

struct PendingScan {
    root: PathBuf,
    root_fd: OwnedFd,
    root_before: rustix::fs::Stat,
    directories: Vec<ScannedDirectory>,
    observations: Vec<LocalObservationRecord>,
    cached_files: Vec<LocalHashRecord>,
    hash_jobs: Vec<HashJob>,
}

#[derive(Default)]
struct ScanEntries {
    observations: Vec<LocalObservationRecord>,
    cached_files: Vec<LocalHashRecord>,
    directories: Vec<ScannedDirectory>,
    hash_jobs: Vec<HashJob>,
}

struct ScannedDirectory {
    path: PathBuf,
    before: rustix::fs::Stat,
}

struct HashJob {
    path: PathBuf,
    fingerprint: LocalFileFingerprint,
}

struct HashWorkerOutput {
    results: Vec<(usize, Result<ScannedHash, LocalError>)>,
}

struct ScanHashResults {
    records: Vec<ScannedHash>,
    changed: Vec<PathBuf>,
}

struct ScannedHash {
    record: LocalHashRecord,
    reusable: bool,
}

#[derive(Clone, Copy)]
struct HashCacheCutoff {
    seconds: i64,
    nanoseconds: u32,
}

impl CompleteScan {
    /// Return the complete, path-sorted local observations.
    #[must_use]
    pub fn observations(&self) -> &[LocalObservationRecord] {
        &self.observations
    }

    pub(crate) fn into_observations(self) -> Vec<LocalObservationRecord> {
        self.observations
    }
}

/// Result of publishing a complete local inventory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ScanPublication {
    /// The scanned root still matched the active journal generation.
    Published(CompleteScan),
    /// The configured path no longer named the active root.
    RootChanged,
}

/// Result of a non-overwriting local entry rename.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LocalRenameOutcome {
    /// The observed entry was renamed and the parent directory was synchronized.
    Renamed,
    /// The source changed or the destination became occupied; rescan and retry.
    Retry,
}

/// A verified immutable upload-stage file.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StagedUpload {
    directory: PathBuf,
    name: OsString,
    content: ContentIdentity,
}

impl StagedUpload {
    fn file_path(&self) -> PathBuf {
        self.directory.join(&self.name)
    }

    /// Return the verified content identity reserved by this immutable stage.
    #[must_use]
    pub fn content(&self) -> &ContentIdentity {
        &self.content
    }

    /// Reopen and verify the exact file descriptor that an uploader should read.
    pub fn open_verified(&self) -> Result<File, LocalError> {
        let directory = open_absolute_directory(&self.directory, "open upload staging directory")?;
        let (mut file, actual) = open_and_hash_at(
            &directory,
            &self.name,
            &self.file_path(),
            "verify immutable upload stage",
        )?;
        if actual != self.content {
            return Err(LocalError::CorruptPrivateFile {
                operation: "open immutable upload stage",
                path: self.file_path(),
            });
        }
        file.seek(SeekFrom::Start(0)).map_err(|source| {
            io_failure("rewind immutable upload stage", &self.file_path(), source)
        })?;
        Ok(file)
    }
}

/// Result of supplying bytes for an immutable stage.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StageOutcome<Stage> {
    /// New verified bytes were installed in the stage.
    Staged(Stage),
    /// A prior verified stage was safely reused.
    AlreadyStaged(Stage),
    /// The supplied bytes did not match the planned identity.
    ContentChanged {
        /// Identity of the bytes actually supplied.
        actual: ContentIdentity,
    },
    /// A different file already occupies the reserved stage destination.
    DestinationOccupied {
        /// Reserved path that was preserved without modification.
        path: PathBuf,
    },
}

pub(crate) struct DownloadPartial {
    location: DownloadLocation,
    file: File,
    offset: u64,
    aggregate: Sha256,
}

pub(crate) enum DownloadPreparation {
    Ready(Box<DownloadPartial>),
    Complete(StageOutcome<()>),
    Ephemeral,
}

#[derive(Clone)]
pub(crate) struct DownloadSlotIdentity {
    binding: [u8; 32],
}

impl DownloadSlotIdentity {
    pub(crate) fn new(
        root_generation: u64,
        operation_id: OperationId,
        target: &Path,
        remote: &crate::model::RemoteFile,
    ) -> Self {
        let mut hasher = Sha256::new();
        hasher.update(b"omabox-download-slot-lease-v1");
        hasher.update(root_generation.to_be_bytes());
        hasher.update(operation_id.to_be_bytes());
        hasher.update(target.as_os_str().as_bytes());
        hasher.update([0]);
        hasher.update(remote.revision.as_str().as_bytes());
        hasher.update([0]);
        hasher.update(remote.content.as_str().as_bytes());
        Self {
            binding: hasher.finalize().into(),
        }
    }
}

pub(crate) struct DownloadSlotLease {
    directory: PathBuf,
    slot: u8,
    binding: [u8; 32],
}

impl DownloadSlotLease {
    pub(crate) fn slot(&self) -> u8 {
        self.slot
    }
}

struct DownloadLocation {
    source: DownloadSource,
    target_directory: OwnedFd,
    stage_name: OsString,
    stage_path: PathBuf,
    target: PathBuf,
    expected: ContentIdentity,
    root_access: Arc<SyncRootAccess>,
}

enum DownloadSource {
    Resumable {
        directory: OwnedFd,
        name: OsString,
        path: PathBuf,
        binding: [u8; 32],
    },
    Disposable {
        path: PathBuf,
    },
}

impl DownloadSource {
    fn path(&self) -> &Path {
        match self {
            Self::Resumable { path, .. } | Self::Disposable { path } => path,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DownloadSlotState {
    binding: [u8; 32],
    offset: u64,
}

impl DownloadPartial {
    pub(crate) fn offset(&self) -> u64 {
        self.offset
    }

    pub(crate) fn append(
        mut self,
        total: u64,
        reader: &mut impl Read,
    ) -> Result<StageOutcome<()>, StageIoError> {
        if self.offset > total {
            return Err(LocalError::ChangedDuringRead {
                operation: "validate resumed download size",
                path: self.location.target.clone(),
            }
            .into());
        }

        let mut buffer = [0_u8; HASH_IO_BUFFER_SIZE];
        while self.offset < total {
            let remaining = total - self.offset;
            let block_length = remaining.min(DROPBOX_BLOCK_SIZE as u64) as usize;
            let mut block_hasher = Sha256::new();
            let mut copied = 0;
            while copied < block_length {
                let length = (block_length - copied).min(buffer.len());
                if let Err(source) = reader.read_exact(&mut buffer[..length]) {
                    self.discard_uncommitted_block()?;
                    return Err(StageIoError::Read {
                        operation: "read resumed download",
                        path: self.location.target.clone(),
                        source,
                    });
                }
                if let Err(source) = self.file.write_all(&buffer[..length]) {
                    self.discard_uncommitted_block()?;
                    return Err(io_failure(
                        "write resumed download",
                        self.location.source.path(),
                        source,
                    )
                    .into());
                }
                block_hasher.update(&buffer[..length]);
                copied += length;
            }
            self.aggregate.update(block_hasher.finalize());
            self.offset += block_length as u64;
            if self.offset.is_multiple_of(DOWNLOAD_CHECKPOINT_BYTES) && self.offset < total {
                self.persist_checkpoint()?;
            }
        }
        let mut extra = [0_u8; 1];
        if reader
            .read(&mut extra)
            .map_err(|source| StageIoError::Read {
                operation: "finish resumed download",
                path: self.location.target.clone(),
                source,
            })?
            != 0
        {
            return Err(LocalError::ChangedDuringRead {
                operation: "validate resumed download length",
                path: self.location.target.clone(),
            }
            .into());
        }
        self.finish().map_err(Into::into)
    }

    fn discard_uncommitted_block(&mut self) -> Result<(), LocalError> {
        self.file.set_len(self.offset).map_err(|source| {
            io_failure(
                "discard incomplete resumed download block",
                self.location.source.path(),
                source,
            )
        })
    }

    fn persist_checkpoint(&mut self) -> Result<(), LocalError> {
        let DownloadSource::Resumable { binding, path, .. } = &self.location.source else {
            return Ok(());
        };
        sync_file(&self.file, path, "sync resumed download checkpoint")?;
        let state = encode_download_slot_state(DownloadSlotState {
            binding: *binding,
            offset: self.offset,
        });
        set_xattr(
            &self.file,
            DOWNLOAD_PARTIAL_XATTR,
            &state,
            XattrFlags::empty(),
            path,
            "record resumed download checkpoint",
        )?;
        sync_file(&self.file, path, "sync resumed download checkpoint marker")
    }

    fn finish(mut self) -> Result<StageOutcome<()>, LocalError> {
        let actual = ContentIdentity::new(hex_digest(self.aggregate.finalize()));
        if actual != self.location.expected {
            if matches!(self.location.source, DownloadSource::Resumable { .. })
                && reset_download_slot(&self.file, &self.location)?.is_none()
            {
                return Ok(StageOutcome::DestinationOccupied {
                    path: self.location.source.path().to_path_buf(),
                });
            }
            return Ok(StageOutcome::ContentChanged { actual });
        }
        sync_file(
            &self.file,
            self.location.source.path(),
            "sync completed resumed download data",
        )?;
        let stage_marker = internal_name(
            "download-marker-v1",
            &self.location.target,
            &self.location.expected,
        );
        set_xattr(
            &self.file,
            DOWNLOAD_STAGE_XATTR,
            stage_marker.as_bytes(),
            XattrFlags::CREATE,
            self.location.source.path(),
            "mark completed resumed download",
        )?;
        sync_file(
            &self.file,
            self.location.source.path(),
            "sync completed resumed download marker",
        )?;
        promote_completed_slot(&mut self.file, &self.location)
    }
}

/// Result of atomically installing a verified download.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum InstallOutcome {
    /// The staged file was installed durably.
    Installed,
    /// The desired bytes were already installed by an earlier attempt.
    AlreadyInstalled,
    /// No verified download stage is currently available.
    DownloadRequired,
    /// Unrelated bytes occupy the deterministic download-stage path.
    StageDestinationOccupied {
        /// Reserved path that was preserved without modification.
        path: PathBuf,
    },
    /// The destination no longer satisfies the recorded precondition.
    PreconditionChanged {
        /// Current content, or `None` when the destination is absent.
        actual: Option<ContentIdentity>,
    },
}

/// Result of durably moving a replacement precondition into its guard.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReplacementPreparation {
    /// The expected destination was moved to its durable displacement guard.
    Prepared,
    /// An earlier attempt already durably prepared the same displacement.
    AlreadyPrepared,
    /// The destination no longer satisfies the recovered precondition.
    PreconditionChanged {
        /// Current content, or `None` when neither destination nor guard exists.
        actual: Option<ContentIdentity>,
    },
}

/// Result of conditionally deleting a local file.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeleteOutcome {
    /// The expected file was removed durably.
    Deleted,
    /// An earlier attempt already removed the expected file.
    AlreadyDeleted,
    /// The destination no longer satisfies the recorded precondition.
    PreconditionChanged {
        /// Current content, or `None` when it is absent.
        actual: Option<ContentIdentity>,
    },
}

/// Result of creating a root-confined local directory.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CreateDirectoryOutcome {
    /// A new directory was created and synchronized.
    Created,
    /// The directory already existed and was synchronized.
    AlreadyPresent,
    /// The path changed or is occupied by another object; publish a fresh scan.
    FreshObservation,
}

/// Result of nonrecursively deleting a root-confined local directory.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeleteDirectoryOutcome {
    /// The empty directory was removed and its parent synchronized.
    Deleted,
    /// The directory was already absent.
    AlreadyAbsent,
    /// The path changed or became nonempty; publish a fresh scan.
    FreshObservation,
}

/// Side represented by a materialized conflict copy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConflictSide {
    /// Locally produced bytes.
    Local,
    /// Dropbox-produced bytes.
    Remote,
}

/// Result of materializing one non-overwriting conflict side.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ConflictOutcome {
    /// A new durable conflict destination was created.
    Created {
        /// Conflict path relative to the sync root.
        path: PathBuf,
    },
    /// The same conflict bytes already occupied the deterministic destination.
    AlreadyPresent {
        /// Conflict path relative to the sync root.
        path: PathBuf,
    },
    /// Supplied bytes did not match the recorded conflict identity.
    ContentChanged {
        /// Identity of the supplied bytes.
        actual: ContentIdentity,
    },
}

/// Compute Dropbox's block-composed SHA-256 content hash.
pub fn dropbox_content_hash(mut reader: impl Read) -> Result<ContentIdentity, HashError> {
    hash_stream(&mut reader).map_err(|source| HashError::Read { source })
}

fn hash_cache_cutoff(now: SystemTime) -> Option<HashCacheCutoff> {
    let elapsed = now
        .checked_sub(HASH_CACHE_RACY_WINDOW)?
        .duration_since(UNIX_EPOCH)
        .ok()?;
    Some(HashCacheCutoff {
        seconds: i64::try_from(elapsed.as_secs()).ok()?,
        nanoseconds: elapsed.subsec_nanos(),
    })
}

fn hash_is_reusable(record: &LocalHashRecord, cutoff: Option<HashCacheCutoff>) -> bool {
    let Some(cutoff) = cutoff else {
        return false;
    };
    timestamp_is_before(
        record.fingerprint.modified_seconds,
        record.fingerprint.modified_nanoseconds,
        cutoff,
    ) && timestamp_is_before(
        record.fingerprint.changed_seconds,
        record.fingerprint.changed_nanoseconds,
        cutoff,
    )
}

fn timestamp_is_before(seconds: i64, nanoseconds: u64, cutoff: HashCacheCutoff) -> bool {
    let Ok(nanoseconds) = u32::try_from(nanoseconds) else {
        return false;
    };
    nanoseconds < 1_000_000_000 && (seconds, nanoseconds) < (cutoff.seconds, cutoff.nanoseconds)
}

fn current_hash_cache_cutoff() -> Option<HashCacheCutoff> {
    hash_cache_cutoff(SystemTime::now())
}

/// Scan the complete root through no-follow, descriptor-relative opens.
///
/// Any inaccessible, changing, symlinked, magic-linked, or special entry
/// fails the whole scan. Callers therefore cannot confuse a partial walk with
/// confirmed absence. Directories are published as first-class observations
/// while their contents are scanned recursively.
#[cfg(test)]
fn scan(root: impl AsRef<Path>) -> Result<CompleteScan, LocalError> {
    scan_with_cache_and_workers_at(root, &[], MAX_PARALLEL_HASHES, None)
}

#[cfg(test)]
fn scan_with_cache_and_workers_at(
    root: impl AsRef<Path>,
    cache: &[LocalHashRecord],
    max_workers: usize,
    cache_cutoff: Option<HashCacheCutoff>,
) -> Result<CompleteScan, LocalError> {
    scan_with_cache_and_workers_completed_at(
        root,
        cache,
        max_workers,
        cache_cutoff,
        current_hash_cache_cutoff,
    )
}

#[cfg(test)]
fn scan_with_cache_and_workers_completed_at(
    root: impl AsRef<Path>,
    cache: &[LocalHashRecord],
    max_workers: usize,
    cache_cutoff: Option<HashCacheCutoff>,
    completed_cutoff: fn() -> Option<HashCacheCutoff>,
) -> Result<CompleteScan, LocalError> {
    let pending = enumerate_scan(root.as_ref(), cache, cache_cutoff)?;
    finish_scan_at(pending, max_workers, completed_cutoff)
}

fn enumerate_scan(
    root: &Path,
    cache: &[LocalHashRecord],
    cache_cutoff: Option<HashCacheCutoff>,
) -> Result<PendingScan, LocalError> {
    let root_fd = open_absolute_directory(root, "open sync root for scan")?;
    let before = stat_fd(&root_fd, root, "inspect sync root before scan")?;
    let mut entries = ScanEntries::default();
    scan_directory(&root_fd, Path::new(""), cache, cache_cutoff, &mut entries)?;
    entries
        .directories
        .sort_by(|left, right| left.path.cmp(&right.path));
    entries
        .cached_files
        .sort_by(|left, right| left.path.cmp(&right.path));
    entries
        .hash_jobs
        .sort_by(|left, right| left.path.cmp(&right.path));
    Ok(PendingScan {
        root: root.to_path_buf(),
        root_fd,
        root_before: before,
        directories: entries.directories,
        observations: entries.observations,
        cached_files: entries.cached_files,
        hash_jobs: entries.hash_jobs,
    })
}

#[cfg(test)]
fn finish_scan(pending: PendingScan, max_workers: usize) -> Result<CompleteScan, LocalError> {
    finish_scan_at(pending, max_workers, current_hash_cache_cutoff)
}

fn finish_scan_at(
    mut pending: PendingScan,
    max_workers: usize,
    completed_cutoff: fn() -> Option<HashCacheCutoff>,
) -> Result<CompleteScan, LocalError> {
    let mut hashed = hash_scan_files(
        &pending.root_fd,
        &pending.hash_jobs,
        max_workers,
        completed_cutoff,
    )?;
    let cached = revalidate_cached_files(&pending.root_fd, pending.cached_files)?;
    hashed.records.extend(cached.records);
    hashed.changed.extend(cached.changed);
    let mut reusable_hashes = Vec::with_capacity(hashed.records.len());
    for scanned in hashed.records {
        let record = scanned.record;
        pending.observations.push(LocalObservationRecord {
            path: record.path.clone(),
            observation: Observation::Present(LocalFile::new(record.content.clone())),
        });
        if scanned.reusable {
            reusable_hashes.push(record);
        }
    }
    pending.observations.extend(
        hashed
            .changed
            .into_iter()
            .map(|path| LocalObservationRecord {
                path,
                observation: Observation::Unknown(UnknownReason::Incomplete),
            }),
    );
    revalidate_directories(&pending.root_fd, &pending.directories)?;
    let rebound = open_absolute_directory(&pending.root, "reopen sync root after scan")?;
    let rebound_stat = stat_fd(
        &rebound,
        &pending.root,
        "verify sync root binding after scan",
    )?;
    if !same_inode(&pending.root_before, &rebound_stat) {
        return Err(LocalError::ChangedDuringRead {
            operation: "verify complete local scan root",
            path: pending.root,
        });
    }
    pending
        .observations
        .sort_by(|left, right| left.path.cmp(&right.path));
    reusable_hashes.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(CompleteScan {
        root_binding: root_binding(&pending.root, &pending.root_before),
        observations: pending.observations,
        reusable_hashes,
    })
}

/// Scan completely and publish only the successful inventory transaction.
pub fn scan_and_publish(
    journal: &mut Journal,
    root: impl AsRef<Path>,
) -> Result<ScanPublication, LocalError> {
    scan_and_publish_at(
        journal,
        root,
        current_hash_cache_cutoff(),
        current_hash_cache_cutoff,
    )
}

fn scan_and_publish_at(
    journal: &mut Journal,
    root: impl AsRef<Path>,
    cache_cutoff: Option<HashCacheCutoff>,
    completed_cutoff: fn() -> Option<HashCacheCutoff>,
) -> Result<ScanPublication, LocalError> {
    let root = root.as_ref();
    let cache = journal
        .local_hash_cache()
        .map_err(|source| LocalError::Journal { source })?;
    let pending = enumerate_scan(root, &cache, cache_cutoff)?;
    drop(cache);
    let scan = finish_scan_at(pending, MAX_PARALLEL_HASHES, completed_cutoff)?;
    if !active_root_matches(journal, &scan.root_binding)?
        || !configured_root_is_active(journal, root)?
    {
        return Ok(ScanPublication::RootChanged);
    }
    if !journal
        .publish_local_scan(
            &scan.root_binding,
            scan.observations(),
            &scan.reusable_hashes,
        )
        .map_err(|source| LocalError::Journal { source })?
    {
        return Ok(ScanPublication::RootChanged);
    }
    Ok(ScanPublication::Published(scan))
}

/// Check that the configured path still names the journal's active root.
pub(crate) fn configured_root_is_active(
    journal: &Journal,
    root: impl AsRef<Path>,
) -> Result<bool, LocalError> {
    Ok(open_active_root(journal, root)?.is_some())
}

/// Open the configured path and retain that exact directory when it is the active root.
pub(crate) fn open_active_root(
    journal: &Journal,
    root: impl AsRef<Path>,
) -> Result<Option<OwnedFd>, LocalError> {
    let root = root.as_ref();
    let directory = open_absolute_directory(root, "open sync root for identity verification")?;
    let stat = stat_fd(&directory, root, "inspect sync root identity")?;
    if active_root_matches(journal, &root_binding(root, &stat))? {
        Ok(Some(directory))
    } else {
        Ok(None)
    }
}

/// Rename one local case variant without overwriting any destination.
pub(crate) fn rename_case_variant(
    root: &OwnedFd,
    source: &Path,
    destination: &Path,
) -> Result<LocalRenameOutcome, LocalError> {
    rename_case_variant_with(root, source, destination, true, || Ok(()))
}

/// Rename one local regular file to a non-overwriting synchronized sibling.
pub(crate) fn rename_file_copy(
    root: &OwnedFd,
    source: &Path,
    destination: &Path,
) -> Result<LocalRenameOutcome, LocalError> {
    rename_case_variant_with(root, source, destination, false, || Ok(()))
}

fn rename_case_variant_with(
    root: &OwnedFd,
    source: &Path,
    destination: &Path,
    allow_directory: bool,
    before_rename: impl FnOnce() -> io::Result<()>,
) -> Result<LocalRenameOutcome, LocalError> {
    if parent_path(source)? != parent_path(destination)? {
        return Err(LocalError::UnsafeRelativePath {
            path: destination.to_path_buf(),
        });
    }
    let Some((parent, source_name, _)) = open_parent(root, source, false)? else {
        return Ok(LocalRenameOutcome::Retry);
    };
    let destination_components = safe_components(destination)?;
    let Some(destination_name) = destination_components.last() else {
        return Err(LocalError::UnsafeRelativePath {
            path: destination.to_path_buf(),
        });
    };
    let source_entry = match openat2(
        &parent,
        &source_name,
        OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    ) {
        Ok(entry) => entry,
        Err(error) if error == rustix::io::Errno::NOENT || error == rustix::io::Errno::LOOP => {
            return Ok(LocalRenameOutcome::Retry);
        }
        Err(error) => {
            return Err(syscall_failure(
                "inspect local rename source",
                source,
                error,
            ));
        }
    };
    let source_stat = stat_fd(&source_entry, source, "inspect local rename source type")?;
    let source_type = FileType::from_raw_mode(source_stat.st_mode);
    if source_type != FileType::RegularFile
        && !(allow_directory && source_type == FileType::Directory)
    {
        return Ok(LocalRenameOutcome::Retry);
    }
    before_rename().map_err(|error| io_failure("rename local entry", source, error))?;

    match renameat_with(
        &parent,
        &source_name,
        &parent,
        destination_name,
        RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            let renamed =
                named_inode_matches(&source_entry, &parent, destination_name, destination)?;
            sync_directory(&parent, destination, "sync local entry rename")?;
            if renamed {
                Ok(LocalRenameOutcome::Renamed)
            } else {
                Ok(LocalRenameOutcome::Retry)
            }
        }
        Err(error) if error == rustix::io::Errno::NOENT || error == rustix::io::Errno::EXIST => {
            Ok(LocalRenameOutcome::Retry)
        }
        Err(error) => Err(syscall_failure("rename local entry", source, error)),
    }
}

/// Return the component-length limit of an entry's actual parent filesystem.
pub(crate) fn parent_name_max(root: &OwnedFd, source: &Path) -> Result<Option<usize>, LocalError> {
    let Some((parent, _, _)) = open_parent(root, source, false)? else {
        return Ok(None);
    };
    let statistics = fstatvfs(&parent)
        .map_err(|error| syscall_failure("inspect parent filename limit", source, error))?;
    let name_max = usize::try_from(statistics.f_namemax).map_err(|error| {
        io_failure(
            "inspect parent filename limit",
            source,
            io::Error::new(io::ErrorKind::InvalidData, error),
        )
    })?;
    if name_max == 0 {
        return Err(io_failure(
            "inspect parent filename limit",
            source,
            io::Error::new(
                io::ErrorKind::InvalidData,
                "filesystem reported a zero limit",
            ),
        ));
    }
    Ok(Some(name_max))
}

fn active_root_matches(journal: &Journal, actual: &LocalRootBinding) -> Result<bool, LocalError> {
    journal
        .local_root_binding()
        .map(|active| active.is_some_and(|record| record.binding == *actual))
        .map_err(|source| LocalError::Journal { source })
}

fn root_binding(path: &Path, stat: &rustix::fs::Stat) -> LocalRootBinding {
    LocalRootBinding {
        canonical_path: path.to_path_buf(),
        device: stat.st_dev,
        inode: stat.st_ino,
    }
}

/// Copy a root-confined local file into immutable upload staging.
pub fn stage_upload(
    root: impl AsRef<Path>,
    relative: impl AsRef<Path>,
    staging_directory: impl AsRef<Path>,
    expected: &ContentIdentity,
) -> Result<StageOutcome<StagedUpload>, LocalError> {
    let root = open_absolute_directory(root.as_ref(), "open sync root for upload staging")?;
    stage_upload_at(&root, relative, staging_directory, expected)
}

pub(crate) fn stage_upload_at(
    root: &OwnedFd,
    relative: impl AsRef<Path>,
    staging_directory: impl AsRef<Path>,
    expected: &ContentIdentity,
) -> Result<StageOutcome<StagedUpload>, LocalError> {
    require_content_hash(expected, "stage upload")?;
    let relative = relative.as_ref();
    let directory_path = staging_directory.as_ref().to_path_buf();
    let directory = open_absolute_directory(&directory_path, "open upload staging directory")?;
    let name = OsString::from(expected.as_str());
    let stage = || StagedUpload {
        directory: directory_path.clone(),
        name: name.clone(),
        content: expected.clone(),
    };
    let stage_path = directory_path.join(&name);
    if let Some((file, actual, _)) = open_and_hash_if_present(
        &directory,
        &name,
        &stage_path,
        "verify immutable upload stage",
    )? && reuse_verified_stage(&file, &actual, expected, None, &directory, &stage_path)?
    {
        return Ok(StageOutcome::AlreadyStaged(stage()));
    }

    let mut source = open_relative_regular(root, relative, "open upload source")?;
    let source_before = stat_fd(&source, relative, "inspect upload source before staging")?;
    let result = write_verified_stage(
        &directory,
        &name,
        &stage_path,
        expected,
        &mut source,
        ExistingPolicy::ReplacePrivate,
        "stage upload",
    )?;
    let source_after = stat_fd(&source, relative, "inspect upload source after staging")?;
    if !same_observation(&source_before, &source_after) {
        return Err(LocalError::ChangedDuringRead {
            operation: "stage upload",
            path: relative.to_path_buf(),
        });
    }
    map_stage_write(result, stage)
}

/// Remove verified content-addressed upload stages that no pending work retains.
///
/// Unknown names, non-regular entries, changing files, and content mismatches are
/// preserved. The staging directory is synchronized once after all removals.
pub(crate) fn remove_unreferenced_upload_stages(
    staging_directory: impl AsRef<Path>,
    retained_contents: &[ContentIdentity],
) -> Result<usize, LocalError> {
    let staging_directory = staging_directory.as_ref();
    let directory = open_absolute_directory(
        staging_directory,
        "open upload staging directory for collection",
    )?;
    let retained = retained_contents
        .iter()
        .map(ContentIdentity::as_str)
        .collect::<BTreeSet<_>>();
    let mut stream = Dir::read_from(&directory).map_err(|source| {
        syscall_failure(
            "open upload staging directory stream",
            staging_directory,
            source,
        )
    })?;
    let mut names = Vec::new();
    while let Some(entry) = stream.read() {
        let entry = entry.map_err(|source| {
            syscall_failure("read upload staging directory", staging_directory, source)
        })?;
        let bytes = entry.file_name().to_bytes();
        if bytes != b"." && bytes != b".." {
            names.push(OsStr::from_bytes(bytes).to_os_string());
        }
    }
    names.sort();

    let mut removed = 0;
    for name in names {
        let Some(expected) = content_addressed_upload_name(&name) else {
            continue;
        };
        if retained.contains(expected) {
            continue;
        }
        let path = staging_directory.join(&name);
        if !verified_upload_stage_entry(&directory, &name, &path, expected)? {
            continue;
        }
        match unlinkat(&directory, &name, AtFlags::empty()) {
            Ok(()) => removed += 1,
            Err(source) if source == rustix::io::Errno::NOENT => {}
            Err(source) => {
                return Err(syscall_failure(
                    "remove unreferenced upload stage",
                    &path,
                    source,
                ));
            }
        }
    }
    if removed != 0 {
        sync_directory(
            &directory,
            staging_directory,
            "sync upload stage collection",
        )?;
    }
    Ok(removed)
}

/// Re-observe one root-confined upload source without changing staging state.
pub(crate) fn observe_upload_source(
    root: impl AsRef<Path>,
    relative: impl AsRef<Path>,
) -> Result<ContentIdentity, LocalError> {
    let root = open_absolute_directory(root.as_ref(), "open sync root for upload observation")?;
    observe_upload_source_at(&root, relative)
}

pub(crate) fn observe_upload_source_at(
    root: &OwnedFd,
    relative: impl AsRef<Path>,
) -> Result<ContentIdentity, LocalError> {
    let relative = relative.as_ref();
    let mut source = open_relative_regular(root, relative, "open upload source")?;
    hash_stable_file(&mut source, relative, "verify upload source")
}

pub(crate) fn upload_source_changed(error: &LocalError, path: &Path) -> bool {
    match error {
        LocalError::ChangedDuringRead { path: changed, .. }
        | LocalError::UnsupportedObject { path: changed } => changed == path,
        LocalError::Io {
            operation: "open upload source",
            path: changed,
            ..
        } => changed == path,
        _ => false,
    }
}

/// Stage downloaded bytes beside their target, verify them, and sync them.
pub fn stage_download(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    expected: &ContentIdentity,
    bytes: impl Read,
) -> Result<StageOutcome<()>, LocalError> {
    let root = root.as_ref();
    let root_fd = open_absolute_directory(root, "open sync root for download staging")?;
    stage_download_at(&root_fd, root, target, expected, bytes).map_err(Into::into)
}

pub(crate) fn stage_download_at(
    root: &OwnedFd,
    root_path: &Path,
    target: impl AsRef<Path>,
    expected: &ContentIdentity,
    mut bytes: impl Read,
) -> Result<StageOutcome<()>, StageIoError> {
    require_content_hash(expected, "stage download")?;
    let target = target.as_ref();
    let Some((parent, _, _)) = open_parent(root, target, true)? else {
        return Err(LocalError::UnsafeRelativePath {
            path: target.to_path_buf(),
        }
        .into());
    };
    let name = internal_name("download", target, expected);
    let marker = internal_name("download-marker-v1", target, expected);
    let display_path = root_path.join(parent_path(target)?).join(&name);
    let result = write_verified_stage(
        &parent,
        &name,
        &display_path,
        expected,
        &mut bytes,
        ExistingPolicy::OwnedDownload(marker.as_bytes()),
        "stage download",
    )?;
    Ok(map_stage_write(result, || ())?)
}

pub(crate) fn existing_download_stage_at(
    root: &OwnedFd,
    root_path: &Path,
    target: &Path,
    expected: &ContentIdentity,
) -> Result<Option<StageOutcome<()>>, LocalError> {
    require_content_hash(expected, "inspect download stage")?;
    let Some((parent, _, parent_relative)) = open_parent(root, target, true)? else {
        return Err(LocalError::UnsafeRelativePath {
            path: target.to_path_buf(),
        });
    };
    let name = internal_name("download", target, expected);
    let display_path = root_path.join(parent_relative).join(&name);
    match inspect_download_stage(&parent, &name, &display_path, target, expected)? {
        DownloadStage::Missing => Ok(None),
        DownloadStage::Verified(_) => Ok(Some(StageOutcome::AlreadyStaged(()))),
        DownloadStage::Occupied(path) => Ok(Some(StageOutcome::DestinationOccupied { path })),
    }
}

pub(crate) fn lease_download_slots(
    staging_directory: &Path,
    identities: &[DownloadSlotIdentity],
) -> Result<Vec<Option<DownloadSlotLease>>, LocalError> {
    let directory =
        open_private_directory(staging_directory, "open resumable download slot directory")?;
    let mut slots = Vec::with_capacity(MAX_PARALLEL_DOWNLOADS);
    for slot in 0_u8..MAX_PARALLEL_DOWNLOADS as u8 {
        let name = download_slot_name(slot);
        let path = staging_directory.join(&name);
        let (owned, usable) = match open_download_slot(&directory, &name, &path)? {
            DownloadSlotOpen::Missing => (None, true),
            DownloadSlotOpen::File(file) => {
                let stat = stat_fd(&file, &path, "inspect resumed download slot")?;
                if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
                    (None, false)
                } else if let Some(state) = read_download_slot_state(&file, &path)? {
                    (Some((file, state)), true)
                } else {
                    (None, false)
                }
            }
            DownloadSlotOpen::Occupied => (None, false),
        };
        slots.push(AvailableDownloadSlot {
            slot,
            owned,
            usable,
        });
    }

    let mut leases = std::iter::repeat_with(|| None)
        .take(identities.len())
        .collect::<Vec<_>>();
    for entry in &mut slots {
        let Some((_, state)) = &entry.owned else {
            continue;
        };
        let Some((index, identity)) = identities.iter().enumerate().find(|(index, identity)| {
            leases[*index].is_none() && identity.binding == state.binding
        }) else {
            continue;
        };
        leases[index] = Some(DownloadSlotLease {
            directory: staging_directory.to_path_buf(),
            slot: entry.slot,
            binding: identity.binding,
        });
        entry.usable = false;
    }

    for (index, identity) in identities.iter().enumerate() {
        if leases[index].is_some() {
            continue;
        }
        for entry in &mut slots {
            if !entry.usable {
                continue;
            }
            entry.usable = false;
            let name = download_slot_name(entry.slot);
            let path = staging_directory.join(&name);
            let claimed = match entry.owned.take() {
                Some((file, _)) => reset_download_slot_file_with(
                    &file,
                    &directory,
                    &name,
                    &path,
                    identity.binding,
                    || Ok(()),
                )?
                .is_some(),
                None => create_download_slot(&directory, &name, &path, identity.binding)?.is_some(),
            };
            if claimed {
                leases[index] = Some(DownloadSlotLease {
                    directory: staging_directory.to_path_buf(),
                    slot: entry.slot,
                    binding: identity.binding,
                });
                break;
            }
        }
    }
    for entry in slots {
        let Some((file, state)) = entry.usable.then_some(entry.owned).flatten() else {
            continue;
        };
        let name = download_slot_name(entry.slot);
        let path = staging_directory.join(&name);
        let _ =
            reset_download_slot_file_with(&file, &directory, &name, &path, state.binding, || {
                Ok(())
            })?;
    }
    Ok(leases)
}

pub(crate) fn lease_download_slot(
    staging_directory: &Path,
    slot: u8,
    identity: &DownloadSlotIdentity,
) -> Result<Option<DownloadSlotLease>, LocalError> {
    let directory =
        open_private_directory(staging_directory, "open resumable download slot directory")?;
    let name = download_slot_name(slot);
    let path = staging_directory.join(&name);
    let claimed = match open_download_slot(&directory, &name, &path)? {
        DownloadSlotOpen::Missing => {
            create_download_slot(&directory, &name, &path, identity.binding)?.is_some()
        }
        DownloadSlotOpen::File(file) => {
            let stat = stat_fd(&file, &path, "inspect resumed download slot")?;
            if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
                false
            } else if let Some(state) = read_download_slot_state(&file, &path)? {
                if state.binding == identity.binding {
                    true
                } else {
                    reset_download_slot_file_with(
                        &file,
                        &directory,
                        &name,
                        &path,
                        identity.binding,
                        || Ok(()),
                    )?
                    .is_some()
                }
            } else {
                false
            }
        }
        DownloadSlotOpen::Occupied => false,
    };
    Ok(claimed.then_some(DownloadSlotLease {
        directory: staging_directory.to_path_buf(),
        slot,
        binding: identity.binding,
    }))
}

struct AvailableDownloadSlot {
    slot: u8,
    owned: Option<(File, DownloadSlotState)>,
    usable: bool,
}

fn download_slot_name(slot: u8) -> OsString {
    OsString::from(format!(".omabox-download-slot-{slot}"))
}

#[cfg(test)]
pub(crate) fn prepare_download_slot_at(
    root: &OwnedFd,
    root_path: &Path,
    target: impl AsRef<Path>,
    expected: &ContentIdentity,
    lease: &DownloadSlotLease,
) -> Result<DownloadPreparation, LocalError> {
    let root_access = Arc::new(SyncRootAccess::default());
    prepare_download_slot_with_access_at(root, root_path, target, expected, lease, &root_access)
}

pub(crate) fn prepare_download_slot_with_access_at(
    root: &OwnedFd,
    root_path: &Path,
    target: impl AsRef<Path>,
    expected: &ContentIdentity,
    lease: &DownloadSlotLease,
    root_access: &Arc<SyncRootAccess>,
) -> Result<DownloadPreparation, LocalError> {
    require_content_hash(expected, "prepare resumed download")?;
    let target = target.as_ref();
    let parent = root_access.with_shared(|| open_parent(root, target, true))?;
    let Some((target_directory, _, parent_relative)) = parent else {
        return Err(LocalError::UnsafeRelativePath {
            path: target.to_path_buf(),
        });
    };
    let stage_name = internal_name("download", target, expected);
    let stage_path = root_path.join(&parent_relative).join(&stage_name);
    let slot_directory =
        open_private_directory(&lease.directory, "open resumable download slot directory")?;
    let slot_name = download_slot_name(lease.slot);
    let slot_path = lease.directory.join(&slot_name);
    match inspect_download_stage(
        &target_directory,
        &stage_name,
        &stage_path,
        target,
        expected,
    )? {
        DownloadStage::Verified(_) => {
            return Ok(DownloadPreparation::Complete(StageOutcome::AlreadyStaged(
                (),
            )));
        }
        DownloadStage::Occupied(path) => {
            return Ok(DownloadPreparation::Complete(
                StageOutcome::DestinationOccupied { path },
            ));
        }
        DownloadStage::Missing => {}
    }
    let mut file = match open_download_slot(&slot_directory, &slot_name, &slot_path)? {
        DownloadSlotOpen::File(file) => file,
        DownloadSlotOpen::Missing | DownloadSlotOpen::Occupied => {
            return Ok(DownloadPreparation::Ephemeral);
        }
    };
    let stat = stat_fd(&file, &slot_path, "inspect resumed download")?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Ok(DownloadPreparation::Ephemeral);
    }
    let mut length = u64::try_from(stat.st_size).map_err(|_| {
        io_failure(
            "inspect resumed download size",
            &slot_path,
            io::Error::new(io::ErrorKind::InvalidData, "partial file size is negative"),
        )
    })?;
    let Some(mut state) = read_download_slot_state(&file, &slot_path)? else {
        return Ok(DownloadPreparation::Ephemeral);
    };
    if state.binding != lease.binding {
        return Ok(DownloadPreparation::Ephemeral);
    }
    let location = DownloadLocation {
        source: DownloadSource::Resumable {
            directory: slot_directory,
            name: slot_name,
            path: slot_path,
            binding: lease.binding,
        },
        target_directory,
        stage_name,
        stage_path,
        target: target.to_path_buf(),
        expected: expected.clone(),
        root_access: Arc::clone(root_access),
    };
    let stage_marker = internal_name("download-marker-v1", target, expected);
    let needs_reset =
        match read_download_marker(&file, stage_marker.as_bytes(), location.source.path())? {
            DownloadMarker::Expected => {
                let actual = hash_stable_file(
                    &mut file,
                    location.source.path(),
                    "verify completed resumed download",
                )?;
                if actual == *expected {
                    return promote_completed_slot(&mut file, &location)
                        .map(DownloadPreparation::Complete);
                }
                true
            }
            DownloadMarker::Other => true,
            DownloadMarker::Missing => false,
        };
    if needs_reset
        || !state.offset.is_multiple_of(DOWNLOAD_CHECKPOINT_BYTES)
        || state.offset > length
    {
        let Some(reset) = reset_download_slot(&file, &location)? else {
            return Ok(DownloadPreparation::Ephemeral);
        };
        file = reset;
        state.offset = 0;
        length = 0;
    }
    if length != state.offset {
        file.set_len(state.offset).map_err(|source| {
            io_failure(
                "truncate resumed download tail",
                location.source.path(),
                source,
            )
        })?;
        sync_file(
            &file,
            location.source.path(),
            "sync truncated resumed download",
        )?;
    }
    let aggregate = hash_download_prefix(&mut file, state.offset, location.source.path())?;
    Ok(DownloadPreparation::Ready(Box::new(DownloadPartial {
        location,
        file,
        offset: state.offset,
        aggregate,
    })))
}

pub(crate) fn prepare_disposable_download_with_access_at(
    root: &OwnedFd,
    root_path: &Path,
    target: impl AsRef<Path>,
    expected: &ContentIdentity,
    staging_directory: &Path,
    root_access: &Arc<SyncRootAccess>,
) -> Result<DownloadPreparation, LocalError> {
    require_content_hash(expected, "prepare disposable download")?;
    let target = target.as_ref();
    let parent = root_access.with_shared(|| open_parent(root, target, true))?;
    let Some((target_directory, _, parent_relative)) = parent else {
        return Err(LocalError::UnsafeRelativePath {
            path: target.to_path_buf(),
        });
    };
    let stage_name = internal_name("download", target, expected);
    let stage_path = root_path.join(parent_relative).join(&stage_name);
    match inspect_download_stage(
        &target_directory,
        &stage_name,
        &stage_path,
        target,
        expected,
    )? {
        DownloadStage::Verified(_) => {
            return Ok(DownloadPreparation::Complete(StageOutcome::AlreadyStaged(
                (),
            )));
        }
        DownloadStage::Occupied(path) => {
            return Ok(DownloadPreparation::Complete(
                StageOutcome::DestinationOccupied { path },
            ));
        }
        DownloadStage::Missing => {}
    }
    let staging = open_private_directory(
        staging_directory,
        "open disposable download staging directory",
    )?;
    let display_path = staging_directory.join("<unnamed-download>");
    let fd = openat2(
        &staging,
        ".",
        OFlags::RDWR | OFlags::TMPFILE | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR,
        BELOW_ROOT,
    )
    .map_err(|source| syscall_failure("create disposable download stage", &display_path, source))?;
    Ok(DownloadPreparation::Ready(Box::new(DownloadPartial {
        location: DownloadLocation {
            source: DownloadSource::Disposable { path: display_path },
            target_directory,
            stage_name,
            stage_path,
            target: target.to_path_buf(),
            expected: expected.clone(),
            root_access: Arc::clone(root_access),
        },
        file: File::from(fd),
        offset: 0,
        aggregate: Sha256::new(),
    })))
}

enum DownloadSlotOpen {
    Missing,
    File(File),
    Occupied,
}

fn open_download_slot(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
) -> Result<DownloadSlotOpen, LocalError> {
    let probe = match openat2(
        directory,
        name,
        OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    ) {
        Ok(probe) => probe,
        Err(source) if source == rustix::io::Errno::NOENT => {
            return Ok(DownloadSlotOpen::Missing);
        }
        Err(source) if source == rustix::io::Errno::LOOP => {
            return Ok(DownloadSlotOpen::Occupied);
        }
        Err(source) => {
            return Err(syscall_failure(
                "inspect resumed download slot",
                path,
                source,
            ));
        }
    };
    let probed = stat_fd(&probe, path, "inspect resumed download slot")?;
    if FileType::from_raw_mode(probed.st_mode) != FileType::RegularFile {
        return Ok(DownloadSlotOpen::Occupied);
    }
    let candidate = match openat2(
        directory,
        name,
        OFlags::RDWR | OFlags::NONBLOCK | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    ) {
        Ok(candidate) => File::from(candidate),
        Err(source) if source == rustix::io::Errno::NOENT => {
            return Ok(DownloadSlotOpen::Missing);
        }
        Err(source) => {
            if !named_inode_matches(&probe, directory, name, path)?
                || source == rustix::io::Errno::ACCESS
                || source == rustix::io::Errno::PERM
            {
                return Ok(DownloadSlotOpen::Occupied);
            }
            return Err(syscall_failure("open resumed download", path, source));
        }
    };
    let opened = stat_fd(&candidate, path, "inspect opened download slot")?;
    if FileType::from_raw_mode(opened.st_mode) == FileType::RegularFile
        && same_inode(&probed, &opened)
    {
        Ok(DownloadSlotOpen::File(candidate))
    } else {
        Ok(DownloadSlotOpen::Occupied)
    }
}

fn create_download_slot(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    binding: [u8; 32],
) -> Result<Option<File>, LocalError> {
    let fd = openat2(
        directory,
        ".",
        OFlags::RDWR | OFlags::TMPFILE | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR,
        BELOW_ROOT,
    )
    .map_err(|source| syscall_failure("create resumed download slot", path, source))?;
    let file = File::from(fd);
    let state = encode_download_slot_state(DownloadSlotState { binding, offset: 0 });
    set_xattr(
        &file,
        DOWNLOAD_PARTIAL_XATTR,
        &state,
        XattrFlags::CREATE,
        path,
        "mark resumed download slot",
    )?;
    sync_file(&file, path, "sync new resumed download slot")?;
    match linkat(&file, "", directory, name, AtFlags::EMPTY_PATH) {
        Ok(()) => {
            sync_directory(directory, path, "sync new resumed download slot entry")?;
            Ok(Some(file))
        }
        Err(source) if source == rustix::io::Errno::EXIST => Ok(None),
        Err(source) => Err(syscall_failure(
            "install new resumed download slot",
            path,
            source,
        )),
    }
}

fn named_inode_matches(
    file: &impl AsFd,
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
) -> Result<bool, LocalError> {
    let held = stat_fd(file, path, "inspect held local entry")?;
    let entry = match openat2(
        directory,
        name,
        OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    ) {
        Ok(entry) => entry,
        Err(source) if source == rustix::io::Errno::NOENT || source == rustix::io::Errno::LOOP => {
            return Ok(false);
        }
        Err(source) => {
            return Err(syscall_failure("inspect named local entry", path, source));
        }
    };
    let named = stat_fd(&entry, path, "inspect named local entry")?;
    Ok(same_inode(&held, &named))
}

fn reset_download_slot(
    file: &File,
    location: &DownloadLocation,
) -> Result<Option<File>, LocalError> {
    let DownloadSource::Resumable {
        directory,
        name,
        path,
        binding,
    } = &location.source
    else {
        return Ok(None);
    };
    reset_download_slot_file_with(file, directory, name, path, *binding, || Ok(()))
}

fn reset_download_slot_file_with(
    file: &File,
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    new_binding: [u8; 32],
    before_reset: impl FnOnce() -> io::Result<()>,
) -> Result<Option<File>, LocalError> {
    if read_download_slot_state(file, path)?.is_none() {
        return Ok(None);
    }
    let candidate = match open_download_slot(directory, name, path)? {
        DownloadSlotOpen::File(candidate) => candidate,
        DownloadSlotOpen::Missing | DownloadSlotOpen::Occupied => return Ok(None),
    };
    let held = stat_fd(file, path, "inspect held resumed download slot")?;
    let opened = stat_fd(&candidate, path, "inspect reusable resumed download slot")?;
    if !same_inode(&held, &opened) {
        return Ok(None);
    }
    before_reset().map_err(|source| io_failure("reset resumed download slot", path, source))?;
    candidate
        .set_len(0)
        .map_err(|source| io_failure("truncate resumed download slot for reuse", path, source))?;
    set_xattr(
        &candidate,
        DOWNLOAD_PARTIAL_XATTR,
        &encode_download_slot_state(DownloadSlotState {
            binding: new_binding,
            offset: 0,
        }),
        XattrFlags::empty(),
        path,
        "reset resumed download slot checkpoint",
    )?;
    sync_file(&candidate, path, "sync reset resumed download slot")?;
    remove_xattr(
        &candidate,
        DOWNLOAD_STAGE_XATTR,
        path,
        "clear resumed download slot completion marker",
    )?;
    sync_file(&candidate, path, "sync reusable resumed download slot")?;
    if named_inode_matches(&candidate, directory, name, path)? {
        Ok(Some(candidate))
    } else {
        Ok(None)
    }
}

fn promote_completed_slot(
    file: &mut File,
    location: &DownloadLocation,
) -> Result<StageOutcome<()>, LocalError> {
    let root_access = Arc::clone(&location.root_access);
    root_access.with_shared(|| promote_completed_slot_with(file, location, || Ok(())))
}

fn promote_completed_slot_with(
    file: &mut File,
    location: &DownloadLocation,
    before_move: impl FnOnce() -> io::Result<()>,
) -> Result<StageOutcome<()>, LocalError> {
    let DownloadSource::Resumable {
        directory,
        name,
        path,
        ..
    } = &location.source
    else {
        return promote_completed_disposable(file, location, before_move);
    };
    if !download_slot_matches(file, location)? {
        return Ok(StageOutcome::DestinationOccupied { path: path.clone() });
    }
    before_move().map_err(|source| io_failure("promote completed download slot", path, source))?;
    match renameat_with(
        directory,
        name,
        &location.target_directory,
        &location.stage_name,
        RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            if !named_inode_matches(
                file,
                &location.target_directory,
                &location.stage_name,
                &location.stage_path,
            )? {
                let occupied = match renameat_with(
                    &location.target_directory,
                    &location.stage_name,
                    directory,
                    name,
                    RenameFlags::NOREPLACE,
                ) {
                    Ok(()) => path.clone(),
                    Err(source) if source == rustix::io::Errno::EXIST => {
                        location.stage_path.clone()
                    }
                    Err(source) => {
                        return Err(syscall_failure(
                            "restore swapped resumed download",
                            &location.stage_path,
                            source,
                        ));
                    }
                };
                sync_directory(directory, path, "sync restored download slot")?;
                sync_directory(
                    &location.target_directory,
                    &location.stage_path,
                    "sync restored download stage",
                )?;
                return Ok(StageOutcome::DestinationOccupied { path: occupied });
            }
            sync_directory(directory, path, "sync consumed download slot")?;
            sync_directory(
                &location.target_directory,
                &location.stage_path,
                "sync promoted download stage",
            )?;
            fchmod(&*file, Mode::RUSR).map_err(|source| {
                syscall_failure(
                    "make resumed download stage immutable",
                    &location.stage_path,
                    source,
                )
            })?;
            sync_file(file, &location.stage_path, "sync completed download stage")?;
            Ok(StageOutcome::Staged(()))
        }
        Err(source) if source == rustix::io::Errno::EXIST => {
            match inspect_download_stage(
                &location.target_directory,
                &location.stage_name,
                &location.stage_path,
                &location.target,
                &location.expected,
            )? {
                DownloadStage::Verified(_) => {
                    let _ = reset_download_slot(file, location)?;
                    Ok(StageOutcome::AlreadyStaged(()))
                }
                DownloadStage::Missing => Err(LocalError::ChangedDuringRead {
                    operation: "recover completed resumed download",
                    path: location.target.clone(),
                }),
                DownloadStage::Occupied(path) => Ok(StageOutcome::DestinationOccupied { path }),
            }
        }
        Err(source) if source == rustix::io::Errno::XDEV => copy_completed_slot(file, location),
        Err(source) => Err(syscall_failure(
            "recover completed resumed download",
            path,
            source,
        )),
    }
}

fn promote_completed_disposable(
    file: &mut File,
    location: &DownloadLocation,
    before_move: impl FnOnce() -> io::Result<()>,
) -> Result<StageOutcome<()>, LocalError> {
    before_move().map_err(|source| {
        io_failure(
            "promote completed disposable download",
            location.source.path(),
            source,
        )
    })?;
    match linkat(
        &*file,
        "",
        &location.target_directory,
        &location.stage_name,
        AtFlags::EMPTY_PATH,
    ) {
        Ok(()) => {
            sync_directory(
                &location.target_directory,
                &location.stage_path,
                "sync promoted disposable download",
            )?;
            fchmod(&*file, Mode::RUSR).map_err(|source| {
                syscall_failure(
                    "make disposable download stage immutable",
                    &location.stage_path,
                    source,
                )
            })?;
            sync_file(file, &location.stage_path, "sync disposable download stage")?;
            Ok(StageOutcome::Staged(()))
        }
        Err(source) if source == rustix::io::Errno::EXIST => match inspect_download_stage(
            &location.target_directory,
            &location.stage_name,
            &location.stage_path,
            &location.target,
            &location.expected,
        )? {
            DownloadStage::Verified(_) => Ok(StageOutcome::AlreadyStaged(())),
            DownloadStage::Missing => Err(LocalError::ChangedDuringRead {
                operation: "promote completed disposable download",
                path: location.target.clone(),
            }),
            DownloadStage::Occupied(path) => Ok(StageOutcome::DestinationOccupied { path }),
        },
        Err(source) if source == rustix::io::Errno::XDEV => copy_completed_slot(file, location),
        Err(source) => Err(syscall_failure(
            "promote completed disposable download",
            location.source.path(),
            source,
        )),
    }
}

fn copy_completed_slot(
    file: &mut File,
    location: &DownloadLocation,
) -> Result<StageOutcome<()>, LocalError> {
    file.seek(SeekFrom::Start(0)).map_err(|error| {
        io_failure(
            "rewind completed download slot",
            location.source.path(),
            error,
        )
    })?;
    let marker = internal_name("download-marker-v1", &location.target, &location.expected);
    let result = write_verified_stage(
        &location.target_directory,
        &location.stage_name,
        &location.stage_path,
        &location.expected,
        file,
        ExistingPolicy::OwnedDownload(marker.as_bytes()),
        "copy completed download slot",
    )?;
    let outcome = map_stage_write(result, || ())?;
    if matches!(
        outcome,
        StageOutcome::Staged(()) | StageOutcome::AlreadyStaged(())
    ) {
        let _ = reset_download_slot(file, location)?;
    }
    Ok(outcome)
}

fn read_download_slot_state(
    file: &File,
    path: &Path,
) -> Result<Option<DownloadSlotState>, LocalError> {
    let mut actual = [0_u8; DOWNLOAD_SLOT_STATE_LENGTH];
    let length = match fgetxattr(file, DOWNLOAD_PARTIAL_XATTR, &mut actual) {
        Ok(length) => length,
        Err(source)
            if source == rustix::io::Errno::NODATA || source == rustix::io::Errno::RANGE =>
        {
            return Ok(None);
        }
        Err(source) => {
            return Err(syscall_failure(
                "inspect resumed download slot marker",
                path,
                source,
            ));
        }
    };
    Ok(decode_download_slot_state(&actual[..length]))
}

fn encode_download_slot_state(state: DownloadSlotState) -> [u8; DOWNLOAD_SLOT_STATE_LENGTH] {
    let mut encoded = [0_u8; DOWNLOAD_SLOT_STATE_LENGTH];
    let binding_start = DOWNLOAD_SLOT_OWNER_PREFIX.len();
    let offset_start = binding_start + state.binding.len();
    encoded[..binding_start].copy_from_slice(DOWNLOAD_SLOT_OWNER_PREFIX);
    encoded[binding_start..offset_start].copy_from_slice(&state.binding);
    encoded[offset_start..].copy_from_slice(&state.offset.to_be_bytes());
    encoded
}

fn decode_download_slot_state(actual: &[u8]) -> Option<DownloadSlotState> {
    let binding_start = DOWNLOAD_SLOT_OWNER_PREFIX.len();
    let offset_start = binding_start + 32;
    if actual.len() != DOWNLOAD_SLOT_STATE_LENGTH
        || actual.get(..DOWNLOAD_SLOT_OWNER_PREFIX.len()) != Some(DOWNLOAD_SLOT_OWNER_PREFIX)
    {
        return None;
    }
    let mut binding = [0_u8; 32];
    binding.copy_from_slice(actual.get(binding_start..offset_start)?);
    let offset_bytes = actual.get(offset_start..)?;
    let mut offset_array = [0_u8; 8];
    offset_array.copy_from_slice(offset_bytes);
    Some(DownloadSlotState {
        binding,
        offset: u64::from_be_bytes(offset_array),
    })
}

fn download_slot_matches(file: &File, location: &DownloadLocation) -> Result<bool, LocalError> {
    let DownloadSource::Resumable { path, binding, .. } = &location.source else {
        return Ok(false);
    };
    read_download_slot_state(file, path)
        .map(|state| state.is_some_and(|state| state.binding == *binding))
}

fn hash_download_prefix(file: &mut File, offset: u64, path: &Path) -> Result<Sha256, LocalError> {
    file.seek(SeekFrom::Start(0))
        .map_err(|source| io_failure("rewind resumed download", path, source))?;
    let mut aggregate = Sha256::new();
    let mut remaining = offset;
    let mut buffer = [0_u8; HASH_IO_BUFFER_SIZE];
    while remaining != 0 {
        let mut block_hasher = Sha256::new();
        let mut block_remaining = DROPBOX_BLOCK_SIZE;
        while block_remaining != 0 {
            let length = block_remaining.min(buffer.len());
            file.read_exact(&mut buffer[..length])
                .map_err(|source| io_failure("rehash resumed download checkpoint", path, source))?;
            block_hasher.update(&buffer[..length]);
            block_remaining -= length;
        }
        aggregate.update(block_hasher.finalize());
        remaining -= DROPBOX_BLOCK_SIZE as u64;
    }
    file.seek(SeekFrom::Start(offset))
        .map_err(|source| io_failure("position resumed download", path, source))?;
    Ok(aggregate)
}

/// Durably prepare an expected local file for replacement without deleting it.
///
/// This real filesystem phase is independently replayable: after it returns,
/// the original bytes are either still at the target or at a deterministic
/// same-directory guard, and the containing directory has been synchronized.
pub fn prepare_replacement(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    expected_content: &ContentIdentity,
) -> Result<ReplacementPreparation, LocalError> {
    let root = root.as_ref();
    let target = target.as_ref();
    require_content_hash(expected_content, "prepare replacement")?;
    let root_fd = open_absolute_directory(root, "open sync root for replacement preparation")?;
    let Some((parent, target_name, parent_relative)) = open_parent(&root_fd, target, false)? else {
        return Ok(ReplacementPreparation::PreconditionChanged { actual: None });
    };
    prepare_replacement_at(
        &parent,
        root,
        &parent_relative,
        &target_name,
        target,
        expected_content,
    )
}

/// Atomically install a verified staged download without overwriting a changed target.
///
/// `expected_content` is required for replacement. An initially absent install
/// passes `None` and uses `RENAME_NOREPLACE`.
pub fn install_download(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    desired: &ContentIdentity,
    expected_content: Option<&ContentIdentity>,
) -> Result<InstallOutcome, LocalError> {
    let root = root.as_ref();
    let root_fd = open_absolute_directory(root, "open sync root for download install")?;
    install_download_at(&root_fd, root, target, desired, expected_content)
}

pub(crate) fn install_download_at(
    root: &OwnedFd,
    root_path: &Path,
    target: impl AsRef<Path>,
    desired: &ContentIdentity,
    expected_content: Option<&ContentIdentity>,
) -> Result<InstallOutcome, LocalError> {
    let target = target.as_ref();
    require_content_hash(desired, "install download")?;
    let Some((parent, target_name, parent_relative)) = open_parent(root, target, false)? else {
        return Ok(InstallOutcome::DownloadRequired);
    };
    let stage_name = internal_name("download", target, desired);
    let stage_path = root_path.join(&parent_relative).join(&stage_name);
    let current = hash_at_if_present(&parent, &target_name, target, "check install precondition")?;
    if current.as_ref() == Some(desired) {
        sync_installed_download(&parent, &target_name, target, desired)?;
        if let StageCleanup::Occupied(path) =
            remove_verified_stage(&parent, &stage_name, desired, &stage_path, target)?
        {
            return Ok(InstallOutcome::StageDestinationOccupied { path });
        }
        if let Some(expected_content) = expected_content {
            require_content_hash(expected_content, "clean replacement guard")?;
            remove_guard_if_verified(&parent, target, expected_content)?;
        }
        sync_directory(&parent, target, "sync already-installed download")?;
        return Ok(InstallOutcome::AlreadyInstalled);
    }

    let Some(expected_content) = expected_content else {
        if current.is_some() {
            return Ok(InstallOutcome::PreconditionChanged { actual: current });
        }
        let stage =
            match inspect_download_stage(&parent, &stage_name, &stage_path, target, desired)? {
                DownloadStage::Verified(file) => file,
                DownloadStage::Missing => return Ok(InstallOutcome::DownloadRequired),
                DownloadStage::Occupied(path) => {
                    return Ok(InstallOutcome::StageDestinationOccupied { path });
                }
            };
        return rename_stage_into_absent_target(
            &parent,
            &stage_name,
            &stage_path,
            &stage,
            &target_name,
            target,
            desired,
        );
    };
    require_content_hash(expected_content, "install replacement")?;
    let stage = match inspect_download_stage(&parent, &stage_name, &stage_path, target, desired)? {
        DownloadStage::Verified(file) => file,
        DownloadStage::Missing => return Ok(InstallOutcome::DownloadRequired),
        DownloadStage::Occupied(path) => {
            return Ok(InstallOutcome::StageDestinationOccupied { path });
        }
    };

    match prepare_replacement_at(
        &parent,
        root_path,
        &parent_relative,
        &target_name,
        target,
        expected_content,
    )? {
        ReplacementPreparation::Prepared | ReplacementPreparation::AlreadyPrepared => {}
        ReplacementPreparation::PreconditionChanged { actual } => {
            return Ok(InstallOutcome::PreconditionChanged { actual });
        }
    }

    let after_prepare =
        hash_at_if_present(&parent, &target_name, target, "resume prepared replacement")?;
    if let Some(actual) = after_prepare {
        if actual == *desired {
            sync_installed_download(&parent, &target_name, target, desired)?;
            if let StageCleanup::Occupied(path) =
                remove_verified_stage(&parent, &stage_name, desired, &stage_path, target)?
            {
                return Ok(InstallOutcome::StageDestinationOccupied { path });
            }
        }
        remove_guard_if_verified(&parent, target, expected_content)?;
        if actual == *desired {
            sync_directory(&parent, target, "sync raced prepared replacement cleanup")?;
            return Ok(InstallOutcome::AlreadyInstalled);
        }
        sync_directory(&parent, target, "sync raced prepared replacement")?;
        return Ok(InstallOutcome::PreconditionChanged {
            actual: Some(actual),
        });
    }

    let guard = internal_name("displaced", target, expected_content);
    verify_download_stage_before_rename(&stage, &stage_path)?;
    match renameat_with(
        &parent,
        &stage_name,
        &parent,
        &target_name,
        RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            sync_renamed_download(&stage, &parent, &target_name, target, desired)?;
            unlinkat(&parent, &guard, AtFlags::empty()).map_err(|source| {
                syscall_failure("remove displaced install guard", target, source)
            })?;
            sync_directory(&parent, target, "sync completed replacement")?;
            Ok(InstallOutcome::Installed)
        }
        Err(source) if source == rustix::io::Errno::EXIST => {
            let actual = hash_at_if_present(
                &parent,
                &target_name,
                target,
                "inspect raced install destination",
            )?;
            if actual.as_ref() == Some(desired) {
                sync_installed_download(&parent, &target_name, target, desired)?;
                if let StageCleanup::Occupied(path) =
                    remove_verified_stage(&parent, &stage_name, desired, &stage_path, target)?
                {
                    return Ok(InstallOutcome::StageDestinationOccupied { path });
                }
            }
            unlinkat(&parent, &guard, AtFlags::empty()).map_err(|remove_source| {
                syscall_failure("remove recovered displacement guard", target, remove_source)
            })?;
            if actual.as_ref() == Some(desired) {
                sync_directory(&parent, target, "sync raced replacement cleanup")?;
                Ok(InstallOutcome::AlreadyInstalled)
            } else {
                sync_directory(&parent, target, "sync raced replacement")?;
                Ok(InstallOutcome::PreconditionChanged { actual })
            }
        }
        Err(source) => Err(syscall_failure(
            "install verified replacement",
            target,
            source,
        )),
    }
}

/// Conditionally delete a local file while its observed content still matches.
pub fn delete_local(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    expected_content: &ContentIdentity,
) -> Result<DeleteOutcome, LocalError> {
    let root = root.as_ref();
    let root_fd = open_absolute_directory(root, "open sync root for local deletion")?;
    delete_local_at(&root_fd, root, target, expected_content)
}

pub(crate) fn delete_local_at(
    root: &OwnedFd,
    root_path: &Path,
    target: impl AsRef<Path>,
    expected_content: &ContentIdentity,
) -> Result<DeleteOutcome, LocalError> {
    let target = target.as_ref();
    require_content_hash(expected_content, "delete local file")?;
    let Some((parent, target_name, parent_relative)) = open_parent(root, target, false)? else {
        return Ok(DeleteOutcome::AlreadyDeleted);
    };
    let guard = internal_name("deleted", target, expected_content);
    let guard_path = root_path.join(&parent_relative).join(&guard);
    let current = hash_at_if_present(&parent, &target_name, target, "check delete precondition")?;

    if current.is_none() {
        if let Some(guard_content) =
            hash_at_if_present(&parent, &guard, &guard_path, "inspect interrupted deletion")?
        {
            if guard_content != *expected_content {
                restore_or_preserve_changed_guard(
                    &parent,
                    &guard,
                    &target_name,
                    target,
                    Some(&guard_content),
                )?;
                return Ok(DeleteOutcome::PreconditionChanged {
                    actual: Some(guard_content),
                });
            }
            unlinkat(&parent, &guard, AtFlags::empty())
                .map_err(|source| syscall_failure("finish interrupted deletion", target, source))?;
            sync_directory(&parent, target, "sync interrupted deletion")?;
            return Ok(DeleteOutcome::Deleted);
        }
        return Ok(DeleteOutcome::AlreadyDeleted);
    }
    if current.as_ref() != Some(expected_content) {
        if let Some(guard_content) =
            hash_at_if_present(&parent, &guard, &guard_path, "inspect raced deletion guard")?
        {
            if guard_content != *expected_content {
                return Err(LocalError::DestinationOccupied {
                    operation: "clean raced local deletion",
                    path: guard_path,
                });
            }
            unlinkat(&parent, &guard, AtFlags::empty())
                .map_err(|source| syscall_failure("remove raced deletion guard", target, source))?;
            sync_directory(&parent, target, "sync raced deletion guard removal")?;
        }
        return Ok(DeleteOutcome::PreconditionChanged { actual: current });
    }
    if let Some(guard_content) =
        hash_at_if_present(&parent, &guard, &guard_path, "inspect deletion guard")?
    {
        if guard_content != *expected_content {
            return Err(LocalError::DestinationOccupied {
                operation: "prepare local deletion",
                path: guard_path,
            });
        }
        unlinkat(&parent, &guard, AtFlags::empty())
            .map_err(|source| syscall_failure("remove stale deletion guard", target, source))?;
        sync_directory(&parent, target, "sync stale deletion guard removal")?;
    }

    match renameat_with(
        &parent,
        &target_name,
        &parent,
        &guard,
        RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {}
        Err(source) if source == rustix::io::Errno::NOENT => {
            return Ok(DeleteOutcome::AlreadyDeleted);
        }
        Err(source) => {
            return Err(syscall_failure(
                "move deleted file to displacement guard",
                target,
                source,
            ));
        }
    }
    sync_directory(&parent, target, "sync deletion displacement")?;
    let displaced =
        hash_at_if_present(&parent, &guard, &guard_path, "verify deletion displacement")?;
    if displaced.as_ref() != Some(expected_content) {
        let actual = displaced;
        restore_or_preserve_changed_guard(&parent, &guard, &target_name, target, actual.as_ref())?;
        return Ok(DeleteOutcome::PreconditionChanged { actual });
    }
    unlinkat(&parent, &guard, AtFlags::empty())
        .map_err(|source| syscall_failure("delete verified displaced file", target, source))?;
    sync_directory(&parent, target, "sync local deletion")?;
    Ok(DeleteOutcome::Deleted)
}

/// Create one local directory without following links or replacing an object.
pub(crate) fn create_directory_at(
    root: &OwnedFd,
    target: &Path,
) -> Result<CreateDirectoryOutcome, LocalError> {
    let Some((parent, name, _)) = open_parent(root, target, true)? else {
        return Err(LocalError::UnsafeRelativePath {
            path: target.to_path_buf(),
        });
    };
    match mkdirat(&parent, &name, Mode::RWXU) {
        Ok(()) => {
            sync_directory(&parent, target, "sync created local directory entry")?;
            let directory = open_directory_at(&parent, &name, target)?;
            sync_directory(&directory, target, "sync created local directory")?;
            Ok(CreateDirectoryOutcome::Created)
        }
        Err(source) if source == rustix::io::Errno::EXIST => match openat2(
            &parent,
            &name,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
            Mode::empty(),
            BELOW_ROOT,
        ) {
            Ok(directory) => {
                sync_directory(&directory, target, "sync existing local directory")?;
                sync_directory(&parent, target, "sync existing local directory entry")?;
                Ok(CreateDirectoryOutcome::AlreadyPresent)
            }
            Err(error)
                if error == rustix::io::Errno::NOENT
                    || error == rustix::io::Errno::NOTDIR
                    || error == rustix::io::Errno::LOOP =>
            {
                Ok(CreateDirectoryOutcome::FreshObservation)
            }
            Err(error) => Err(syscall_failure(
                "inspect occupied local directory path",
                target,
                error,
            )),
        },
        Err(source) => Err(syscall_failure("create local directory", target, source)),
    }
}

/// Delete one local directory only when it is still empty.
pub(crate) fn delete_directory_at(
    root: &OwnedFd,
    target: &Path,
) -> Result<DeleteDirectoryOutcome, LocalError> {
    let Some((parent, name, _)) = open_parent(root, target, false)? else {
        return Ok(DeleteDirectoryOutcome::AlreadyAbsent);
    };
    match unlinkat(&parent, &name, AtFlags::REMOVEDIR) {
        Ok(()) => {
            sync_directory(&parent, target, "sync deleted local directory")?;
            Ok(DeleteDirectoryOutcome::Deleted)
        }
        Err(source) if source == rustix::io::Errno::NOENT => {
            Ok(DeleteDirectoryOutcome::AlreadyAbsent)
        }
        Err(source)
            if source == rustix::io::Errno::NOTEMPTY
                || source == rustix::io::Errno::EXIST
                || source == rustix::io::Errno::NOTDIR
                || source == rustix::io::Errno::ISDIR =>
        {
            Ok(DeleteDirectoryOutcome::FreshObservation)
        }
        Err(source) => Err(syscall_failure(
            "delete empty local directory",
            target,
            source,
        )),
    }
}

/// Materialize one deterministic conflict copy without overwriting any file.
pub fn materialize_conflict(
    root: impl AsRef<Path>,
    original: impl AsRef<Path>,
    side: ConflictSide,
    expected: &ContentIdentity,
    bytes: impl Read,
) -> Result<ConflictOutcome, LocalError> {
    let root = root.as_ref();
    let root_fd = open_absolute_directory(root, "open sync root for conflict")?;
    materialize_conflict_at(&root_fd, root, original, side, expected, bytes)
}

pub(crate) fn materialize_conflict_at(
    root: &OwnedFd,
    root_path: &Path,
    original: impl AsRef<Path>,
    side: ConflictSide,
    expected: &ContentIdentity,
    mut bytes: impl Read,
) -> Result<ConflictOutcome, LocalError> {
    require_content_hash(expected, "materialize conflict")?;
    let original = original.as_ref();
    let Some((parent, _, _)) = open_parent(root, original, true)? else {
        return Err(LocalError::UnsafeRelativePath {
            path: original.to_path_buf(),
        });
    };
    let name = conflict_name(original, side, expected);
    let relative_path = conflict_relative_path(original, side, expected)?;
    let display_path = root_path.join(&relative_path);
    let result = write_verified_stage(
        &parent,
        &name,
        &display_path,
        expected,
        &mut bytes,
        ExistingPolicy::Preserve,
        "materialize conflict",
    )?;
    match result {
        StageWrite::Created => Ok(ConflictOutcome::Created {
            path: relative_path,
        }),
        StageWrite::Reused => Ok(ConflictOutcome::AlreadyPresent {
            path: relative_path,
        }),
        StageWrite::Mismatch(actual) => Ok(ConflictOutcome::ContentChanged { actual }),
        StageWrite::Occupied(path) => Err(LocalError::DestinationOccupied {
            operation: "materialize conflict",
            path,
        }),
    }
}

pub(crate) fn conflict_relative_path(
    original: &Path,
    side: ConflictSide,
    content: &ContentIdentity,
) -> Result<PathBuf, LocalError> {
    Ok(parent_path(original)?.join(conflict_name(original, side, content)))
}

pub(crate) fn open_root(root: &Path, operation: &'static str) -> Result<OwnedFd, LocalError> {
    open_absolute_directory(root, operation)
}

pub(crate) fn open_private_directory(
    path: &Path,
    operation: &'static str,
) -> Result<OwnedFd, LocalError> {
    open_absolute_directory(path, operation)
}

pub(crate) fn recovery_file_name(original: &Path, content: &ContentIdentity) -> OsString {
    internal_name("recovery", original, content)
}

pub(crate) fn verify_private_copy(
    directory: &OwnedFd,
    path: &Path,
    name: &OsStr,
    expected: &ContentIdentity,
) -> Result<bool, LocalError> {
    let Some(actual) =
        hash_at_if_present(directory, name, &path.join(name), "verify recovery copy")?
    else {
        return Ok(false);
    };
    if actual != *expected {
        return Err(LocalError::CorruptPrivateFile {
            operation: "verify recovery copy",
            path: path.join(name),
        });
    }
    sync_installed_file(directory, name, &path.join(name))?;
    Ok(true)
}

fn scan_directory(
    directory: &OwnedFd,
    relative: &Path,
    cache: &[LocalHashRecord],
    cache_cutoff: Option<HashCacheCutoff>,
    entries: &mut ScanEntries,
) -> Result<(), LocalError> {
    let before = stat_fd(directory, relative, "inspect directory before scan")?;
    let mut stream = Dir::read_from(directory)
        .map_err(|source| syscall_failure("open directory stream", relative, source))?;
    let mut names = Vec::new();
    while let Some(entry) = stream.read() {
        let entry = entry.map_err(|source| syscall_failure("read directory", relative, source))?;
        let bytes = entry.file_name().to_bytes();
        if bytes != b"." && bytes != b".." {
            names.push(OsStr::from_bytes(bytes).to_os_string());
        }
    }
    names.sort();

    for name in names {
        let path = relative.join(&name);
        let probe = openat2(
            directory,
            &name,
            OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
            BELOW_ROOT,
        )
        .map_err(|source| syscall_failure("inspect directory entry", &path, source))?;
        let probe_stat = stat_fd(&probe, &path, "inspect directory entry type")?;
        match FileType::from_raw_mode(probe_stat.st_mode) {
            FileType::RegularFile => {
                if is_reserved_artifact_name(&name) {
                    entries.observations.push(LocalObservationRecord {
                        path,
                        observation: Observation::Unknown(UnknownReason::Unsupported),
                    });
                    continue;
                }
                let file = open_relative_at(directory, &name, &path, OFlags::RDONLY)?;
                let opened = stat_fd(&file, &path, "inspect opened scan file")?;
                if !same_inode(&probe_stat, &opened) {
                    entries.observations.push(LocalObservationRecord {
                        path,
                        observation: Observation::Unknown(UnknownReason::Incomplete),
                    });
                    continue;
                }
                let fingerprint = file_fingerprint(&opened, &path)?;
                match cached_hash(cache, &path) {
                    Some(record)
                        if record.fingerprint == fingerprint
                            && hash_is_reusable(record, cache_cutoff) =>
                    {
                        entries.cached_files.push(LocalHashRecord {
                            path,
                            fingerprint,
                            content: record.content.clone(),
                        });
                    }
                    Some(_) | None => {
                        entries.hash_jobs.push(HashJob { path, fingerprint });
                    }
                }
            }
            FileType::Directory => {
                let child = open_directory_at(directory, &name, &path)?;
                let opened = stat_fd(&child, &path, "inspect opened scan directory")?;
                if !same_inode(&probe_stat, &opened) {
                    return Err(LocalError::ChangedDuringRead {
                        operation: "open scanned directory",
                        path,
                    });
                }
                entries.observations.push(LocalObservationRecord {
                    path: path.clone(),
                    observation: Observation::Directory,
                });
                scan_directory(&child, &path, cache, cache_cutoff, entries)?;
            }
            FileType::Symlink
            | FileType::Fifo
            | FileType::Socket
            | FileType::CharacterDevice
            | FileType::BlockDevice
            | FileType::Unknown => return Err(LocalError::UnsupportedObject { path }),
        }
    }
    let after = stat_fd(directory, relative, "inspect directory after scan")?;
    if !same_observation(&before, &after) {
        return Err(LocalError::ChangedDuringRead {
            operation: "scan directory",
            path: relative.to_path_buf(),
        });
    }
    entries.directories.push(ScannedDirectory {
        path: relative.to_path_buf(),
        before,
    });
    Ok(())
}

fn cached_hash<'a>(cache: &'a [LocalHashRecord], path: &Path) -> Option<&'a LocalHashRecord> {
    let Ok(index) = cache.binary_search_by(|record| record.path.as_path().cmp(path)) else {
        return None;
    };
    cache.get(index)
}

fn hash_scan_files(
    root: &OwnedFd,
    jobs: &[HashJob],
    max_workers: usize,
    completed_cutoff: fn() -> Option<HashCacheCutoff>,
) -> Result<ScanHashResults, LocalError> {
    if jobs.is_empty() {
        return Ok(ScanHashResults {
            records: Vec::new(),
            changed: Vec::new(),
        });
    }
    let available_workers = thread::available_parallelism().map_or(1, |count| count.get());
    let worker_count = max_workers.min(available_workers).max(1).min(jobs.len());
    let next_job = AtomicUsize::new(0);
    thread::scope(|scope| {
        let mut handles = Vec::with_capacity(worker_count);
        let mut spawn_failure = None;
        for worker in 0..worker_count {
            let next_job = &next_job;
            match thread::Builder::new()
                .name(format!("omabox-local-hash-{worker}"))
                .spawn_scoped(scope, move || {
                    let mut results = Vec::new();
                    loop {
                        let index = next_job.fetch_add(1, Ordering::Relaxed);
                        let Some(job) = jobs.get(index) else {
                            return HashWorkerOutput { results };
                        };
                        results.push((index, hash_scan_file(root, job, completed_cutoff)));
                    }
                }) {
                Ok(handle) => handles.push((worker, handle)),
                Err(source) => {
                    spawn_failure = Some(LocalError::HashWorkerSpawn { worker, source });
                    break;
                }
            }
        }

        let mut results = Vec::with_capacity(jobs.len());
        let mut terminated_worker = None;
        for (worker, handle) in handles {
            match handle.join() {
                Ok(output) => results.extend(output.results),
                Err(_) if terminated_worker.is_none() => terminated_worker = Some(worker),
                Err(_) => {}
            }
        }
        if let Some(worker) = terminated_worker {
            return Err(LocalError::HashWorkerTerminated { worker });
        }
        if let Some(error) = spawn_failure {
            return Err(error);
        }
        results.sort_by_key(|(index, _)| *index);
        let mut records = Vec::with_capacity(results.len());
        let mut changed = Vec::new();
        for (_, result) in results {
            match result {
                Ok(record) => records.push(record),
                Err(LocalError::ChangedDuringRead { path, .. }) => changed.push(path),
                Err(error) => return Err(error),
            }
        }
        Ok(ScanHashResults { records, changed })
    })
}

fn hash_scan_file(
    root: &OwnedFd,
    job: &HashJob,
    completed_cutoff: fn() -> Option<HashCacheCutoff>,
) -> Result<ScannedHash, LocalError> {
    let (mut file, opened) =
        open_relative_regular_with_stat(root, &job.path, "open enumerated scan file")?;
    if file_fingerprint(&opened, &job.path)? != job.fingerprint {
        return Err(LocalError::ChangedDuringRead {
            operation: "open enumerated scan file",
            path: job.path.clone(),
        });
    }
    let (content, fingerprint) =
        hash_stable_file_from_stat(&mut file, &job.path, "hash local scan file", opened)?;
    if fingerprint != job.fingerprint {
        return Err(LocalError::ChangedDuringRead {
            operation: "hash enumerated scan file",
            path: job.path.clone(),
        });
    }
    let record = LocalHashRecord {
        path: job.path.clone(),
        fingerprint,
        content,
    };
    Ok(ScannedHash {
        reusable: hash_is_reusable(&record, completed_cutoff()),
        record,
    })
}

fn revalidate_cached_files(
    root: &OwnedFd,
    cached_files: Vec<LocalHashRecord>,
) -> Result<ScanHashResults, LocalError> {
    let mut records = Vec::with_capacity(cached_files.len());
    let mut changed = Vec::new();
    for record in cached_files {
        let (_file, before) =
            open_relative_regular_with_stat(root, &record.path, "reopen cached scan file")?;
        if file_fingerprint(&before, &record.path)? != record.fingerprint {
            changed.push(record.path);
            continue;
        }
        records.push(ScannedHash {
            record,
            reusable: true,
        });
    }
    Ok(ScanHashResults { records, changed })
}

fn revalidate_directories(
    root: &OwnedFd,
    directories: &[ScannedDirectory],
) -> Result<(), LocalError> {
    for directory in directories {
        let current = if directory.path.as_os_str().is_empty() {
            stat_fd(root, &directory.path, "revalidate scanned directory")?
        } else {
            safe_components(&directory.path)?;
            let reopened = openat2(
                root,
                &directory.path,
                OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
                Mode::empty(),
                BELOW_ROOT,
            )
            .map_err(|source| {
                syscall_failure("reopen scanned directory", &directory.path, source)
            })?;
            stat_fd(&reopened, &directory.path, "revalidate scanned directory")?
        };
        if !same_observation(&directory.before, &current) {
            return Err(LocalError::ChangedDuringRead {
                operation: "revalidate scanned directory",
                path: directory.path.clone(),
            });
        }
    }
    Ok(())
}

fn hash_stream(reader: &mut impl Read) -> io::Result<ContentIdentity> {
    let mut aggregate = Sha256::new();
    let mut buffer = [0_u8; HASH_IO_BUFFER_SIZE];
    loop {
        let mut block_hasher = Sha256::new();
        let mut block_length = 0;
        while block_length < DROPBOX_BLOCK_SIZE {
            let length = (DROPBOX_BLOCK_SIZE - block_length).min(buffer.len());
            let count = reader.read(&mut buffer[..length])?;
            if count == 0 {
                break;
            }
            block_hasher.update(&buffer[..count]);
            block_length += count;
        }
        if block_length == 0 {
            break;
        }
        aggregate.update(block_hasher.finalize());
        if block_length < DROPBOX_BLOCK_SIZE {
            break;
        }
    }
    Ok(ContentIdentity::new(hex_digest(aggregate.finalize())))
}

fn hash_stable_file(
    file: &mut File,
    path: &Path,
    operation: &'static str,
) -> Result<ContentIdentity, LocalError> {
    hash_stable_file_with_fingerprint(file, path, operation).map(|(content, _)| content)
}

fn hash_stable_file_with_fingerprint(
    file: &mut File,
    path: &Path,
    operation: &'static str,
) -> Result<(ContentIdentity, LocalFileFingerprint), LocalError> {
    let before = stat_fd(file, path, operation)?;
    hash_stable_file_from_stat(file, path, operation, before)
}

fn hash_stable_file_from_stat(
    file: &mut File,
    path: &Path,
    operation: &'static str,
    before: rustix::fs::Stat,
) -> Result<(ContentIdentity, LocalFileFingerprint), LocalError> {
    if FileType::from_raw_mode(before.st_mode) != FileType::RegularFile {
        return Err(LocalError::UnsupportedObject {
            path: path.to_path_buf(),
        });
    }
    let fingerprint = file_fingerprint(&before, path)?;
    file.seek(SeekFrom::Start(0))
        .map_err(|source| io_failure("rewind file before hashing", path, source))?;
    let identity = hash_stream(file).map_err(|source| io_failure(operation, path, source))?;
    let after = stat_fd(file, path, operation)?;
    if !same_observation(&before, &after) {
        return Err(LocalError::ChangedDuringRead {
            operation,
            path: path.to_path_buf(),
        });
    }
    Ok((identity, fingerprint))
}

fn file_fingerprint(
    stat: &rustix::fs::Stat,
    path: &Path,
) -> Result<LocalFileFingerprint, LocalError> {
    let size = u64::try_from(stat.st_size).map_err(|_| {
        io_failure(
            "inspect local file size",
            path,
            io::Error::new(
                io::ErrorKind::InvalidData,
                "regular file reported a negative size",
            ),
        )
    })?;
    Ok(LocalFileFingerprint {
        device: stat.st_dev,
        inode: stat.st_ino,
        size,
        modified_seconds: stat.st_mtime,
        modified_nanoseconds: stat.st_mtime_nsec,
        changed_seconds: stat.st_ctime,
        changed_nanoseconds: stat.st_ctime_nsec,
    })
}

fn hex_digest(digest: impl AsRef<[u8]>) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let bytes = digest.as_ref();
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

fn require_content_hash(
    identity: &ContentIdentity,
    operation: &'static str,
) -> Result<(), LocalError> {
    if valid_content_hash_bytes(identity.as_str().as_bytes()) {
        Ok(())
    } else {
        Err(LocalError::InvalidContentIdentity { operation })
    }
}

fn valid_content_hash_bytes(value: &[u8]) -> bool {
    value.len() == 64
        && value
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
}

fn content_addressed_upload_name(name: &OsStr) -> Option<&str> {
    let bytes = name.as_bytes();
    if valid_content_hash_bytes(bytes) {
        std::str::from_utf8(bytes).ok()
    } else {
        None
    }
}

fn verified_upload_stage_entry(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    expected: &str,
) -> Result<bool, LocalError> {
    let Some(named) = open_upload_stage_candidate(
        directory,
        name,
        OFlags::PATH | OFlags::NOFOLLOW,
        path,
        "inspect upload stage for collection",
    )?
    else {
        return Ok(false);
    };
    let before = stat_fd(&named, path, "inspect upload stage for collection")?;
    if FileType::from_raw_mode(before.st_mode) != FileType::RegularFile {
        return Ok(false);
    }
    let Some(fd) = open_upload_stage_candidate(
        directory,
        name,
        OFlags::RDONLY,
        path,
        "open upload stage for collection",
    )?
    else {
        return Ok(false);
    };
    let mut file = File::from(fd);
    let opened = stat_fd(&file, path, "inspect opened upload stage for collection")?;
    if !same_observation(&before, &opened) {
        return Ok(false);
    }
    let actual = match hash_stable_file(&mut file, path, "verify upload stage for collection") {
        Ok(actual) => actual,
        Err(LocalError::ChangedDuringRead { .. } | LocalError::UnsupportedObject { .. }) => {
            return Ok(false);
        }
        Err(source) => return Err(source),
    };
    if actual.as_str() != expected {
        return Ok(false);
    }
    let Some(current) = open_upload_stage_candidate(
        directory,
        name,
        OFlags::PATH | OFlags::NOFOLLOW,
        path,
        "reinspect upload stage for collection",
    )?
    else {
        return Ok(false);
    };
    let after = stat_fd(&file, path, "reinspect opened upload stage for collection")?;
    let current = stat_fd(&current, path, "reinspect upload stage for collection")?;
    Ok(same_observation(&after, &current))
}

fn open_upload_stage_candidate(
    directory: &OwnedFd,
    name: &OsStr,
    flags: OFlags,
    path: &Path,
    operation: &'static str,
) -> Result<Option<OwnedFd>, LocalError> {
    match openat2(
        directory,
        name,
        flags | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    ) {
        Ok(fd) => Ok(Some(fd)),
        Err(source) if source == rustix::io::Errno::NOENT || source == rustix::io::Errno::LOOP => {
            Ok(None)
        }
        Err(source) => Err(syscall_failure(operation, path, source)),
    }
}

fn open_absolute_directory(path: &Path, operation: &'static str) -> Result<OwnedFd, LocalError> {
    if !path.is_absolute() {
        return Err(LocalError::UnsafeRelativePath {
            path: path.to_path_buf(),
        });
    }
    openat2(
        CWD,
        path,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
        ABSOLUTE_SAFE,
    )
    .map_err(|source| syscall_failure(operation, path, source))
}

fn open_parent(
    root: &OwnedFd,
    relative: &Path,
    create: bool,
) -> Result<Option<(OwnedFd, OsString, PathBuf)>, LocalError> {
    let components = safe_components(relative)?;
    let Some((name, parents)) = components.split_last() else {
        return Err(LocalError::UnsafeRelativePath {
            path: relative.to_path_buf(),
        });
    };
    let mut current = rustix::io::dup(root)
        .map_err(|source| syscall_failure("duplicate sync root descriptor", relative, source))?;
    let mut parent_relative = PathBuf::new();
    for component in parents {
        parent_relative.push(component);
        match open_directory_at(&current, component, &parent_relative) {
            Ok(next) => current = next,
            Err(LocalError::Io { source, .. })
                if source.kind() == io::ErrorKind::NotFound && !create =>
            {
                return Ok(None);
            }
            Err(LocalError::Io { source, .. })
                if source.kind() == io::ErrorKind::NotFound && create =>
            {
                match mkdirat(&current, component, Mode::RWXU) {
                    Ok(()) => {
                        sync_directory(
                            &current,
                            &parent_relative,
                            "sync newly created parent directory entry",
                        )?;
                    }
                    Err(error) if error == rustix::io::Errno::EXIST => {}
                    Err(error) => {
                        return Err(syscall_failure(
                            "create download parent directory",
                            &parent_relative,
                            error,
                        ));
                    }
                }
                let next = open_directory_at(&current, component, &parent_relative)?;
                sync_directory(&next, &parent_relative, "sync newly created directory")?;
                current = next;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(Some((current, name.clone(), parent_relative)))
}

fn parent_path(path: &Path) -> Result<&Path, LocalError> {
    safe_components(path)?;
    path.parent().ok_or_else(|| LocalError::UnsafeRelativePath {
        path: path.to_path_buf(),
    })
}

fn safe_components(path: &Path) -> Result<Vec<OsString>, LocalError> {
    if path.as_os_str().is_empty() || path.is_absolute() {
        return Err(LocalError::UnsafeRelativePath {
            path: path.to_path_buf(),
        });
    }
    path.components()
        .map(|component| match component {
            Component::Normal(value) => Ok(value.to_os_string()),
            Component::Prefix(_)
            | Component::RootDir
            | Component::CurDir
            | Component::ParentDir => Err(LocalError::UnsafeRelativePath {
                path: path.to_path_buf(),
            }),
        })
        .collect()
}

fn open_relative_regular(
    root: &OwnedFd,
    relative: &Path,
    operation: &'static str,
) -> Result<File, LocalError> {
    open_relative_regular_with_stat(root, relative, operation).map(|(file, _)| file)
}

fn open_relative_regular_with_stat(
    root: &OwnedFd,
    relative: &Path,
    operation: &'static str,
) -> Result<(File, rustix::fs::Stat), LocalError> {
    safe_components(relative)?;
    let fd = openat2(
        root,
        relative,
        OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    )
    .map_err(|source| syscall_failure(operation, relative, source))?;
    let stat = stat_fd(&fd, relative, operation)?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err(LocalError::UnsupportedObject {
            path: relative.to_path_buf(),
        });
    }
    Ok((File::from(fd), stat))
}

fn open_relative_at(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    flags: OFlags,
) -> Result<File, LocalError> {
    let fd = openat2(
        directory,
        name,
        flags | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    )
    .map_err(|source| syscall_failure("open root-confined file", path, source))?;
    Ok(File::from(fd))
}

fn open_directory_at(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
) -> Result<OwnedFd, LocalError> {
    openat2(
        directory,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    )
    .map_err(|source| syscall_failure("open root-confined directory", path, source))
}

fn open_and_hash_at(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    operation: &'static str,
) -> Result<(File, ContentIdentity), LocalError> {
    let mut file = open_relative_at(directory, name, path, OFlags::RDONLY)?;
    let identity = hash_stable_file(&mut file, path, operation)?;
    Ok((file, identity))
}

fn hash_at_if_present(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    operation: &'static str,
) -> Result<Option<ContentIdentity>, LocalError> {
    Ok(open_and_hash_if_present(directory, name, path, operation)?.map(|(_, content, _)| content))
}

fn open_and_hash_if_present(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    operation: &'static str,
) -> Result<Option<(File, ContentIdentity, LocalFileFingerprint)>, LocalError> {
    match openat2(
        directory,
        name,
        OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    ) {
        Ok(fd) => {
            let mut file = File::from(fd);
            let (content, fingerprint) =
                hash_stable_file_with_fingerprint(&mut file, path, operation)?;
            Ok(Some((file, content, fingerprint)))
        }
        Err(source) if source == rustix::io::Errno::NOENT => Ok(None),
        Err(source) => Err(syscall_failure(operation, path, source)),
    }
}

#[derive(Clone, Copy)]
enum ExistingPolicy<'a> {
    ReplacePrivate,
    Preserve,
    OwnedDownload(&'a [u8]),
}

enum StageWrite {
    Created,
    Reused,
    Mismatch(ContentIdentity),
    Occupied(PathBuf),
}

struct VerifiedDownloadStage {
    file: File,
    fingerprint: LocalFileFingerprint,
}

enum DownloadStage {
    Missing,
    Verified(VerifiedDownloadStage),
    Occupied(PathBuf),
}

fn inspect_download_stage(
    directory: &OwnedFd,
    name: &OsStr,
    display_path: &Path,
    target: &Path,
    expected: &ContentIdentity,
) -> Result<DownloadStage, LocalError> {
    let Some((file, actual, hashed)) =
        open_and_hash_if_present(directory, name, display_path, "verify owned download stage")?
    else {
        return Ok(DownloadStage::Missing);
    };
    let marker = internal_name("download-marker-v1", target, expected);
    if actual == *expected
        && read_download_marker(&file, marker.as_bytes(), display_path)? == DownloadMarker::Expected
    {
        let observed = file_fingerprint(
            &stat_fd(&file, display_path, "revalidate owned download stage")?,
            display_path,
        )?;
        if observed != hashed {
            return Err(LocalError::ChangedDuringRead {
                operation: "revalidate owned download stage",
                path: display_path.to_path_buf(),
            });
        }
        fchmod(&file, Mode::RUSR).map_err(|source| {
            syscall_failure(
                "make verified download stage immutable",
                display_path,
                source,
            )
        })?;
        sync_file(&file, display_path, "sync immutable download stage")?;
        let fingerprint = file_fingerprint(
            &stat_fd(&file, display_path, "inspect immutable download stage")?,
            display_path,
        )?;
        if !same_hashed_content(&hashed, &fingerprint) {
            return Err(LocalError::ChangedDuringRead {
                operation: "make verified download stage immutable",
                path: display_path.to_path_buf(),
            });
        }
        Ok(DownloadStage::Verified(VerifiedDownloadStage {
            file,
            fingerprint,
        }))
    } else {
        Ok(DownloadStage::Occupied(display_path.to_path_buf()))
    }
}

fn reuse_verified_stage(
    file: &File,
    actual: &ContentIdentity,
    expected: &ContentIdentity,
    marker: Option<&[u8]>,
    directory: &OwnedFd,
    path: &Path,
) -> Result<bool, LocalError> {
    if actual != expected
        || !marker.map_or(Ok(true), |marker| {
            read_download_marker(file, marker, path)
                .map(|actual| actual == DownloadMarker::Expected)
        })?
    {
        return Ok(false);
    }
    fsync(file).map_err(|source| syscall_failure("sync verified stage", path, source))?;
    sync_directory(directory, path, "sync verified stage entry")?;
    Ok(true)
}

fn write_verified_stage(
    directory: &OwnedFd,
    name: &OsStr,
    display_path: &Path,
    expected: &ContentIdentity,
    reader: &mut impl Read,
    policy: ExistingPolicy<'_>,
    operation: &'static str,
) -> Result<StageWrite, StageIoError> {
    let marker = match policy {
        ExistingPolicy::OwnedDownload(marker) => Some(marker),
        ExistingPolicy::ReplacePrivate | ExistingPolicy::Preserve => None,
    };
    if let Some((file, actual, _)) =
        open_and_hash_if_present(directory, name, display_path, operation)?
    {
        if reuse_verified_stage(&file, &actual, expected, marker, directory, display_path)? {
            return Ok(StageWrite::Reused);
        }
        if actual == *expected {
            return Ok(StageWrite::Occupied(display_path.to_path_buf()));
        }
        match policy {
            ExistingPolicy::Preserve | ExistingPolicy::OwnedDownload(_) => {
                return Ok(StageWrite::Occupied(display_path.to_path_buf()));
            }
            ExistingPolicy::ReplacePrivate => {
                unlinkat(directory, name, AtFlags::empty()).map_err(|source| {
                    syscall_failure("remove corrupt private stage", display_path, source)
                })?;
                sync_directory(directory, display_path, "sync corrupt stage removal")?;
            }
        }
    }

    let fd = openat2(
        directory,
        ".",
        OFlags::WRONLY | OFlags::TMPFILE | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR,
        BELOW_ROOT,
    )
    .map_err(|source| syscall_failure("create unnamed staging file", display_path, source))?;
    let mut file = File::from(fd);
    let actual = copy_and_hash(reader, &mut file, display_path, operation)?;
    if actual != *expected {
        return Ok(StageWrite::Mismatch(actual));
    }
    if let Some(marker) = marker {
        fsetxattr(&file, DOWNLOAD_STAGE_XATTR, marker, XattrFlags::CREATE)
            .map_err(|source| syscall_failure("mark owned download stage", display_path, source))?;
    }
    fchmod(&file, Mode::RUSR)
        .map_err(|source| syscall_failure("make staged bytes immutable", display_path, source))?;
    fsync(&file)
        .map_err(|source| syscall_failure("sync verified staged bytes", display_path, source))?;
    match linkat(&file, "", directory, name, AtFlags::EMPTY_PATH) {
        Ok(()) => {
            sync_directory(directory, display_path, "sync staged file entry")?;
            Ok(StageWrite::Created)
        }
        Err(source) if source == rustix::io::Errno::EXIST => {
            let Some((file, existing, _)) =
                open_and_hash_if_present(directory, name, display_path, "verify raced stage")?
            else {
                return Err(LocalError::ChangedDuringRead {
                    operation,
                    path: display_path.to_path_buf(),
                }
                .into());
            };
            if reuse_verified_stage(&file, &existing, expected, marker, directory, display_path)? {
                Ok(StageWrite::Reused)
            } else {
                match policy {
                    ExistingPolicy::Preserve | ExistingPolicy::OwnedDownload(_) => {
                        Ok(StageWrite::Occupied(display_path.to_path_buf()))
                    }
                    ExistingPolicy::ReplacePrivate => Err(LocalError::DestinationOccupied {
                        operation,
                        path: display_path.to_path_buf(),
                    }
                    .into()),
                }
            }
        }
        Err(source) => {
            Err(syscall_failure("install verified private stage", display_path, source).into())
        }
    }
}

fn copy_and_hash(
    reader: &mut impl Read,
    writer: &mut File,
    path: &Path,
    operation: &'static str,
) -> Result<ContentIdentity, StageIoError> {
    let mut aggregate = Sha256::new();
    let mut buffer = [0_u8; HASH_IO_BUFFER_SIZE];
    loop {
        let mut block_hasher = Sha256::new();
        let mut block_length = 0;
        while block_length < DROPBOX_BLOCK_SIZE {
            let length = (DROPBOX_BLOCK_SIZE - block_length).min(buffer.len());
            let count =
                reader
                    .read(&mut buffer[..length])
                    .map_err(|source| StageIoError::Read {
                        operation,
                        path: path.to_path_buf(),
                        source,
                    })?;
            if count == 0 {
                break;
            }
            writer
                .write_all(&buffer[..count])
                .map_err(|source| io_failure("write private stage", path, source))?;
            block_hasher.update(&buffer[..count]);
            block_length += count;
        }
        if block_length == 0 {
            break;
        }
        aggregate.update(block_hasher.finalize());
        if block_length < DROPBOX_BLOCK_SIZE {
            break;
        }
    }
    Ok(ContentIdentity::new(hex_digest(aggregate.finalize())))
}

fn map_stage_write<Stage>(
    write: StageWrite,
    stage: impl FnOnce() -> Stage,
) -> Result<StageOutcome<Stage>, LocalError> {
    match write {
        StageWrite::Created => Ok(StageOutcome::Staged(stage())),
        StageWrite::Reused => Ok(StageOutcome::AlreadyStaged(stage())),
        StageWrite::Mismatch(actual) => Ok(StageOutcome::ContentChanged { actual }),
        StageWrite::Occupied(path) => Ok(StageOutcome::DestinationOccupied { path }),
    }
}

fn rename_stage_into_absent_target(
    parent: &OwnedFd,
    stage_name: &OsStr,
    stage_path: &Path,
    stage: &VerifiedDownloadStage,
    target_name: &OsStr,
    target: &Path,
    desired: &ContentIdentity,
) -> Result<InstallOutcome, LocalError> {
    verify_download_stage_before_rename(stage, stage_path)?;
    match renameat_with(
        parent,
        stage_name,
        parent,
        target_name,
        RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            sync_renamed_download(stage, parent, target_name, target, desired)?;
            Ok(InstallOutcome::Installed)
        }
        Err(source) if source == rustix::io::Errno::EXIST => {
            let actual =
                hash_at_if_present(parent, target_name, target, "inspect raced initial install")?;
            if actual.as_ref() == Some(desired) {
                sync_installed_download(parent, target_name, target, desired)?;
                match remove_verified_stage(parent, stage_name, desired, stage_path, target)? {
                    StageCleanup::RemovedOrAbsent => {
                        sync_directory(parent, target, "sync raced initial install cleanup")?;
                        Ok(InstallOutcome::AlreadyInstalled)
                    }
                    StageCleanup::Occupied(path) => {
                        Ok(InstallOutcome::StageDestinationOccupied { path })
                    }
                }
            } else {
                Ok(InstallOutcome::PreconditionChanged { actual })
            }
        }
        Err(source) if source == rustix::io::Errno::NOENT => Ok(InstallOutcome::DownloadRequired),
        Err(source) => Err(syscall_failure(
            "install download into absent path",
            target,
            source,
        )),
    }
}

fn prepare_replacement_at(
    parent: &OwnedFd,
    root: &Path,
    parent_relative: &Path,
    target_name: &OsStr,
    target: &Path,
    expected_content: &ContentIdentity,
) -> Result<ReplacementPreparation, LocalError> {
    let guard = internal_name("displaced", target, expected_content);
    let guard_path = root.join(parent_relative).join(&guard);
    let current = hash_at_if_present(
        parent,
        target_name,
        target,
        "check replacement preparation precondition",
    )?;
    if let Some(guard_content) = hash_at_if_present(
        parent,
        &guard,
        &guard_path,
        "inspect replacement displacement guard",
    )? {
        if guard_content == *expected_content {
            return Ok(ReplacementPreparation::AlreadyPrepared);
        }
        return Err(LocalError::DestinationOccupied {
            operation: "prepare download replacement",
            path: guard_path,
        });
    }
    if current.as_ref() != Some(expected_content) {
        return Ok(ReplacementPreparation::PreconditionChanged { actual: current });
    }

    match renameat_with(parent, target_name, parent, &guard, RenameFlags::NOREPLACE) {
        Ok(()) => {}
        Err(source) if source == rustix::io::Errno::NOENT => {
            return Ok(ReplacementPreparation::PreconditionChanged { actual: None });
        }
        Err(source) if source == rustix::io::Errno::EXIST => {
            let existing = hash_at_if_present(
                parent,
                &guard,
                &guard_path,
                "verify raced replacement displacement",
            )?;
            if existing.as_ref() == Some(expected_content) {
                return Ok(ReplacementPreparation::AlreadyPrepared);
            }
            return Err(LocalError::DestinationOccupied {
                operation: "prepare download replacement",
                path: guard_path,
            });
        }
        Err(source) => {
            return Err(syscall_failure(
                "move replaced file to displacement guard",
                target,
                source,
            ));
        }
    }
    sync_directory(parent, target, "sync replacement displacement guard")?;
    let displaced = hash_at_if_present(
        parent,
        &guard,
        &guard_path,
        "verify displaced replacement file",
    )?;
    if displaced.as_ref() != Some(expected_content) {
        let actual = displaced;
        restore_or_preserve_changed_guard(parent, &guard, target_name, target, actual.as_ref())?;
        return Ok(ReplacementPreparation::PreconditionChanged { actual });
    }
    Ok(ReplacementPreparation::Prepared)
}

fn remove_guard_if_verified(
    parent: &OwnedFd,
    target: &Path,
    expected_content: &ContentIdentity,
) -> Result<(), LocalError> {
    let guard = internal_name("displaced", target, expected_content);
    if let Some(actual) = hash_at_if_present(parent, &guard, target, "verify stale install guard")?
    {
        if actual != *expected_content {
            return Err(LocalError::DestinationOccupied {
                operation: "clean completed replacement",
                path: target.to_path_buf(),
            });
        }
        unlinkat(parent, &guard, AtFlags::empty())
            .map_err(|source| syscall_failure("remove stale install guard", target, source))?;
    }
    Ok(())
}

enum StageCleanup {
    RemovedOrAbsent,
    Occupied(PathBuf),
}

fn remove_verified_stage(
    parent: &OwnedFd,
    name: &OsStr,
    expected: &ContentIdentity,
    path: &Path,
    target: &Path,
) -> Result<StageCleanup, LocalError> {
    match inspect_download_stage(parent, name, path, target, expected)? {
        DownloadStage::Occupied(path) => Ok(StageCleanup::Occupied(path)),
        DownloadStage::Verified(_) => {
            unlinkat(parent, name, AtFlags::empty())
                .map_err(|source| syscall_failure("remove verified staging file", path, source))?;
            Ok(StageCleanup::RemovedOrAbsent)
        }
        DownloadStage::Missing => Ok(StageCleanup::RemovedOrAbsent),
    }
}

fn restore_or_preserve_changed_guard(
    parent: &OwnedFd,
    guard: &OsStr,
    target_name: &OsStr,
    target: &Path,
    actual: Option<&ContentIdentity>,
) -> Result<(), LocalError> {
    match renameat_with(parent, guard, parent, target_name, RenameFlags::NOREPLACE) {
        Ok(()) => {
            sync_directory(parent, target, "restore changed local destination")?;
            Ok(())
        }
        Err(source) if source == rustix::io::Errno::EXIST => {
            let Some(actual) = actual else {
                return Err(LocalError::ChangedDuringRead {
                    operation: "preserve raced local destination",
                    path: target.to_path_buf(),
                });
            };
            let conflict = conflict_name(target, ConflictSide::Local, actual);
            match renameat_with(parent, guard, parent, &conflict, RenameFlags::NOREPLACE) {
                Ok(()) => {
                    sync_directory(parent, target, "sync preserved raced local destination")?;
                    Ok(())
                }
                Err(rename_source) if rename_source == rustix::io::Errno::EXIST => {
                    let existing = hash_at_if_present(
                        parent,
                        &conflict,
                        target,
                        "verify raced conflict destination",
                    )?;
                    if existing.as_ref() != Some(actual) {
                        return Err(LocalError::DestinationOccupied {
                            operation: "preserve raced local destination",
                            path: target.to_path_buf(),
                        });
                    }
                    unlinkat(parent, guard, AtFlags::empty()).map_err(|remove_source| {
                        syscall_failure("remove duplicate raced local copy", target, remove_source)
                    })?;
                    sync_directory(parent, target, "sync duplicate raced local cleanup")?;
                    Ok(())
                }
                Err(rename_source) => Err(syscall_failure(
                    "preserve raced local destination",
                    target,
                    rename_source,
                )),
            }
        }
        Err(source) => Err(syscall_failure(
            "restore changed local destination",
            target,
            source,
        )),
    }
}

fn sync_installed_file(
    parent: &OwnedFd,
    target_name: &OsStr,
    target: &Path,
) -> Result<(), LocalError> {
    let file = open_relative_at(parent, target_name, target, OFlags::RDONLY)?;
    fsync(&file).map_err(|source| syscall_failure("sync installed file", target, source))?;
    sync_directory(parent, target, "sync installed file entry")
}

fn verify_download_stage_before_rename(
    stage: &VerifiedDownloadStage,
    path: &Path,
) -> Result<(), LocalError> {
    let current = file_fingerprint(
        &stat_fd(&stage.file, path, "verify download stage before rename")?,
        path,
    )?;
    if current == stage.fingerprint {
        Ok(())
    } else {
        Err(LocalError::ChangedDuringRead {
            operation: "verify download stage before rename",
            path: path.to_path_buf(),
        })
    }
}

fn sync_renamed_download(
    stage: &VerifiedDownloadStage,
    parent: &OwnedFd,
    target_name: &OsStr,
    target: &Path,
    expected: &ContentIdentity,
) -> Result<(), LocalError> {
    let marker = internal_name("download-marker-v1", target, expected);
    let renamed = file_fingerprint(
        &stat_fd(&stage.file, target, "verify renamed download content")?,
        target,
    )?;
    if !same_hashed_content(&stage.fingerprint, &renamed)
        || !named_inode_matches(&stage.file, parent, target_name, target)?
        || read_download_marker(&stage.file, marker.as_bytes(), target)? != DownloadMarker::Expected
    {
        return Err(LocalError::ChangedDuringRead {
            operation: "verify renamed download ownership",
            path: target.to_path_buf(),
        });
    }
    sync_directory(parent, target, "sync installed download rename")?;
    finish_installed_download(&stage.file, target, true)?;
    let installed = file_fingerprint(
        &stat_fd(&stage.file, target, "verify installed download content")?,
        target,
    )?;
    if !same_hashed_content(&stage.fingerprint, &installed)
        || !named_inode_matches(&stage.file, parent, target_name, target)?
    {
        return Err(LocalError::ChangedDuringRead {
            operation: "verify installed download binding",
            path: target.to_path_buf(),
        });
    }
    Ok(())
}

fn sync_installed_download(
    parent: &OwnedFd,
    target_name: &OsStr,
    target: &Path,
    expected: &ContentIdentity,
) -> Result<(), LocalError> {
    let Some((file, actual, _)) =
        open_and_hash_if_present(parent, target_name, target, "verify installed download")?
    else {
        return Err(LocalError::ChangedDuringRead {
            operation: "verify installed download",
            path: target.to_path_buf(),
        });
    };
    if actual != *expected {
        return Err(LocalError::ChangedDuringRead {
            operation: "verify installed download",
            path: target.to_path_buf(),
        });
    }
    let marker = internal_name("download-marker-v1", target, expected);
    let marker_matches =
        read_download_marker(&file, marker.as_bytes(), target)? == DownloadMarker::Expected;
    finish_installed_download(&file, target, marker_matches)?;
    sync_directory(parent, target, "sync installed download entry")
}

fn finish_installed_download(
    file: &File,
    target: &Path,
    marker_matches: bool,
) -> Result<(), LocalError> {
    if marker_matches {
        fchmod(file, Mode::RUSR | Mode::WUSR).map_err(|source| {
            syscall_failure("make installed download writable", target, source)
        })?;
        remove_xattr(
            file,
            DOWNLOAD_PARTIAL_XATTR,
            target,
            "clear resumed download marker",
        )?;
        fsync(file)
            .map_err(|source| syscall_failure("sync installed download cleanup", target, source))?;
        remove_xattr(
            file,
            DOWNLOAD_STAGE_XATTR,
            target,
            "clear installed download marker",
        )?;
    }
    fsync(file).map_err(|source| syscall_failure("sync installed download", target, source))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DownloadMarker {
    Missing,
    Expected,
    Other,
}

fn read_download_marker(
    file: &File,
    expected: &[u8],
    path: &Path,
) -> Result<DownloadMarker, LocalError> {
    let mut actual = [0_u8; 96];
    match fgetxattr(file, DOWNLOAD_STAGE_XATTR, &mut actual) {
        Ok(length) if actual.get(..length) == Some(expected) => Ok(DownloadMarker::Expected),
        Ok(_) | Err(rustix::io::Errno::RANGE) => Ok(DownloadMarker::Other),
        Err(rustix::io::Errno::NODATA) => Ok(DownloadMarker::Missing),
        Err(source) => Err(syscall_failure(
            "verify download stage marker",
            path,
            source,
        )),
    }
}

fn set_xattr(
    file: &File,
    name: &str,
    value: &[u8],
    flags: XattrFlags,
    path: &Path,
    operation: &'static str,
) -> Result<(), LocalError> {
    fsetxattr(file, name, value, flags).map_err(|source| syscall_failure(operation, path, source))
}

fn remove_xattr(
    file: &File,
    name: &str,
    path: &Path,
    operation: &'static str,
) -> Result<(), LocalError> {
    match fremovexattr(file, name) {
        Ok(()) | Err(rustix::io::Errno::NODATA) => Ok(()),
        Err(source) => Err(syscall_failure(operation, path, source)),
    }
}

fn sync_file(file: &File, path: &Path, operation: &'static str) -> Result<(), LocalError> {
    sync_directory(file, path, operation)
}

fn sync_directory(
    directory: &impl AsFd,
    path: &Path,
    operation: &'static str,
) -> Result<(), LocalError> {
    fsync(directory).map_err(|source| syscall_failure(operation, path, source))
}

fn internal_name(prefix: &str, path: &Path, content: &ContentIdentity) -> OsString {
    let mut hasher = Sha256::new();
    hasher.update(prefix.as_bytes());
    hasher.update([0]);
    hasher.update(path.as_os_str().as_bytes());
    hasher.update([0]);
    hasher.update(content.as_str().as_bytes());
    OsString::from(format!(
        ".omabox-{prefix}-{}",
        hex_digest(hasher.finalize())
    ))
}

fn is_reserved_artifact_name(name: &OsStr) -> bool {
    const PREFIXES: [&[u8]; 3] = [
        b".omabox-download-",
        b".omabox-displaced-",
        b".omabox-deleted-",
    ];
    PREFIXES.iter().any(|prefix| {
        name.as_bytes().strip_prefix(*prefix).is_some_and(|suffix| {
            suffix.len() == 64
                && suffix
                    .iter()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
        })
    })
}

fn conflict_name(path: &Path, side: ConflictSide, content: &ContentIdentity) -> OsString {
    let side = match side {
        ConflictSide::Local => "local",
        ConflictSide::Remote => "remote",
    };
    internal_name(&format!("conflict-{side}"), path, content)
}

fn stat_fd(
    fd: &impl AsFd,
    path: &Path,
    operation: &'static str,
) -> Result<rustix::fs::Stat, LocalError> {
    fstat(fd).map_err(|source| syscall_failure(operation, path, source))
}

fn same_inode(left: &rustix::fs::Stat, right: &rustix::fs::Stat) -> bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
}

fn same_hashed_content(left: &LocalFileFingerprint, right: &LocalFileFingerprint) -> bool {
    left.device == right.device
        && left.inode == right.inode
        && left.size == right.size
        && left.modified_seconds == right.modified_seconds
        && left.modified_nanoseconds == right.modified_nanoseconds
}

fn same_observation(left: &rustix::fs::Stat, right: &rustix::fs::Stat) -> bool {
    same_inode(left, right)
        && left.st_size == right.st_size
        && left.st_mtime == right.st_mtime
        && left.st_mtime_nsec == right.st_mtime_nsec
        && left.st_ctime == right.st_ctime
        && left.st_ctime_nsec == right.st_ctime_nsec
}

fn io_failure(operation: &'static str, path: &Path, source: io::Error) -> LocalError {
    LocalError::Io {
        operation,
        path: path.to_path_buf(),
        source,
    }
}

fn syscall_failure(operation: &'static str, path: &Path, source: rustix::io::Errno) -> LocalError {
    io_failure(
        operation,
        path,
        io::Error::from_raw_os_error(source.raw_os_error()),
    )
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::io::{Cursor, SeekFrom};

    use proptest::prelude::*;
    use tempfile::TempDir;

    use crate::model::DropboxRevision;

    use super::*;

    fn identity(bytes: &[u8]) -> Result<ContentIdentity, HashError> {
        dropbox_content_hash(Cursor::new(bytes))
    }

    fn staged_download(outcome: StageOutcome<()>) -> Result<(), LocalError> {
        match outcome {
            StageOutcome::Staged(stage) | StageOutcome::AlreadyStaged(stage) => Ok(stage),
            StageOutcome::ContentChanged { .. } => Err(LocalError::ChangedDuringRead {
                operation: "extract test download stage",
                path: PathBuf::from("test"),
            }),
            StageOutcome::DestinationOccupied { path } => Err(LocalError::DestinationOccupied {
                operation: "extract test download stage",
                path,
            }),
        }
    }

    fn test_download_lease(
        staging: &Path,
        target: &Path,
        expected: &ContentIdentity,
        root_generation: u64,
        operation_id: i64,
    ) -> Result<DownloadSlotLease, LocalError> {
        let identity = test_slot_identity(target, expected, root_generation, operation_id);
        lease_download_slots(staging, &[identity])?
            .into_iter()
            .next()
            .flatten()
            .ok_or_else(|| LocalError::DestinationOccupied {
                operation: "lease test download slot",
                path: staging.to_path_buf(),
            })
    }

    fn test_slot_identity(
        target: &Path,
        expected: &ContentIdentity,
        root_generation: u64,
        operation_id: i64,
    ) -> DownloadSlotIdentity {
        let remote = crate::model::RemoteFile::new(
            expected.clone(),
            DropboxRevision::new(format!("revision-{operation_id}")),
        );
        DownloadSlotIdentity::new(
            root_generation,
            OperationId::for_test(operation_id),
            target,
            &remote,
        )
    }

    fn resumable_source(
        location: &DownloadLocation,
    ) -> io::Result<(&OwnedFd, &OsStr, &Path, [u8; 32])> {
        match &location.source {
            DownloadSource::Resumable {
                directory,
                name,
                path,
                binding,
            } => Ok((directory, name, path, *binding)),
            DownloadSource::Disposable { .. } => {
                Err(io::Error::other("test expected a resumable download"))
            }
        }
    }

    struct FragmentedReader<'a> {
        bytes: &'a [u8],
        fragments: &'a [usize],
        position: usize,
        next_fragment: usize,
    }

    impl<'a> FragmentedReader<'a> {
        fn new(bytes: &'a [u8], fragments: &'a [usize]) -> Self {
            Self {
                bytes,
                fragments,
                position: 0,
                next_fragment: 0,
            }
        }
    }

    impl Read for FragmentedReader<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if buffer.is_empty() || self.position == self.bytes.len() {
                return Ok(0);
            }
            if self.fragments.is_empty() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "fragment schedule is empty",
                ));
            }
            let fragment_index = self.next_fragment % self.fragments.len();
            let Some(&fragment) = self.fragments.get(fragment_index) else {
                return Err(io::Error::other("fragment schedule changed during read"));
            };
            if fragment == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "fragment length is zero",
                ));
            }
            let remaining = self.bytes.len() - self.position;
            let count = remaining.min(buffer.len()).min(fragment);
            let end = self.position + count;
            buffer[..count].copy_from_slice(&self.bytes[self.position..end]);
            self.position = end;
            self.next_fragment += 1;
            Ok(count)
        }
    }

    struct FailingBytes {
        remaining: u64,
    }

    impl Read for FailingBytes {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if self.remaining == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionReset,
                    "injected interrupted download",
                ));
            }
            let available = u64::try_from(buffer.len())
                .map_err(|_| io::Error::other("test buffer length overflowed"))?;
            let count = usize::try_from(self.remaining.min(available))
                .map_err(|_| io::Error::other("test read length overflowed"))?;
            buffer[..count].fill(b'x');
            self.remaining -= u64::try_from(count)
                .map_err(|_| io::Error::other("test read length overflowed"))?;
            Ok(count)
        }
    }

    fn hash_length_strategy() -> impl Strategy<Value = usize> {
        prop_oneof![
            Just(0),
            Just(1),
            Just(DROPBOX_BLOCK_SIZE - 1),
            Just(DROPBOX_BLOCK_SIZE),
            Just(DROPBOX_BLOCK_SIZE + 1),
            Just(2 * DROPBOX_BLOCK_SIZE - 1),
            Just(2 * DROPBOX_BLOCK_SIZE),
            Just(2 * DROPBOX_BLOCK_SIZE + 1),
            2_usize..=64 * 1024,
        ]
    }

    fn fragment_strategy() -> impl Strategy<Value = Vec<usize>> {
        prop_oneof![
            Just(vec![1, 7, 4096, 65_535]),
            Just(vec![17, 1021, 16_384]),
            prop::collection::vec(1_usize..=128 * 1024, 1..12),
        ]
    }

    fn patterned_bytes(length: usize, seed: u8) -> Vec<u8> {
        let mut state = u64::from(seed) | 1;
        (0..length)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state.to_le_bytes()[0]
            })
            .collect()
    }

    fn reference_dropbox_hash(bytes: &[u8]) -> ContentIdentity {
        let mut aggregate = Sha256::new();
        for block in bytes.chunks(DROPBOX_BLOCK_SIZE) {
            aggregate.update(Sha256::digest(block));
        }
        ContentIdentity::new(hex_digest(aggregate.finalize()))
    }

    #[test]
    fn case_variant_rename_preserves_tree_and_retries_races() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let source = Path::new("credit");
        let destination = Path::new("credit (case variant)");
        std::fs::create_dir(root.path().join(source))?;
        std::fs::write(root.path().join(source).join("receipt.pdf"), b"receipt")?;
        std::fs::write(root.path().join(destination), b"raced destination")?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;

        assert_eq!(
            rename_case_variant(&root_fd, source, destination)?,
            LocalRenameOutcome::Retry
        );
        assert_eq!(
            std::fs::read(root.path().join(destination))?,
            b"raced destination"
        );
        assert_eq!(
            std::fs::read(root.path().join(source).join("receipt.pdf"))?,
            b"receipt"
        );

        std::fs::remove_file(root.path().join(destination))?;
        assert_eq!(
            rename_case_variant(&root_fd, source, destination)?,
            LocalRenameOutcome::Renamed
        );
        assert!(!root.path().join(source).exists());
        assert_eq!(
            std::fs::read(root.path().join(destination).join("receipt.pdf"))?,
            b"receipt"
        );
        assert_eq!(
            rename_case_variant(&root_fd, source, destination)?,
            LocalRenameOutcome::Retry
        );
        Ok(())
    }

    #[test]
    fn case_variant_rename_preserves_a_swapped_source() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let source = Path::new("credit");
        let destination = Path::new("credit (case variant)");
        let preserved = Path::new("preserved-by-racer");
        std::fs::write(root.path().join(source), b"observed bytes")?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;

        let outcome = rename_case_variant_with(&root_fd, source, destination, true, || {
            std::fs::rename(root.path().join(source), root.path().join(preserved))?;
            std::fs::write(root.path().join(source), b"new bytes")
        })?;

        assert_eq!(outcome, LocalRenameOutcome::Retry);
        assert_eq!(
            std::fs::read(root.path().join(preserved))?,
            b"observed bytes"
        );
        assert_eq!(std::fs::read(root.path().join(destination))?, b"new bytes");
        assert!(!root.path().join(source).exists());
        Ok(())
    }

    fn scanned_content<'a>(
        scan: &'a CompleteScan,
        path: &Path,
    ) -> Result<&'a ContentIdentity, io::Error> {
        scan.observations
            .iter()
            .find_map(|record| {
                if record.path != path {
                    return None;
                }
                match &record.observation {
                    Observation::Present(file) => Some(&file.content),
                    Observation::Directory
                    | Observation::ConfirmedAbsent
                    | Observation::Unknown(_) => None,
                }
            })
            .ok_or_else(|| io::Error::other("scan did not contain the expected regular file"))
    }

    fn fingerprint(root: &Path, relative: &Path) -> Result<LocalFileFingerprint, LocalError> {
        let root = open_absolute_directory(root, "open test scan root")?;
        let file = open_relative_regular(&root, relative, "open test scan file")?;
        let stat = stat_fd(&file, relative, "inspect test scan file")?;
        file_fingerprint(&stat, relative)
    }

    fn test_cache(
        path: &Path,
        fingerprint: LocalFileFingerprint,
        content: &ContentIdentity,
    ) -> Vec<LocalHashRecord> {
        let record = LocalHashRecord {
            path: path.to_path_buf(),
            fingerprint,
            content: content.clone(),
        };
        vec![record]
    }

    fn all_cache_entries_stable() -> Option<HashCacheCutoff> {
        Some(HashCacheCutoff {
            seconds: i64::MAX,
            nanoseconds: 999_999_999,
        })
    }

    #[test]
    fn dropbox_hash_uses_block_hash_composition() -> Result<(), Box<dyn Error>> {
        let empty = identity(b"")?;
        assert_eq!(
            empty.as_str(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        let abc = identity(b"abc")?;
        assert_eq!(
            abc.as_str(),
            "4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358"
        );
        Ok(())
    }

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(12))]

        #[test]
        fn download_checkpoint_state_encodes_the_last_complete_boundary(
            interruption in 0_u64..=(1024 * DOWNLOAD_CHECKPOINT_BYTES + DROPBOX_BLOCK_SIZE as u64),
        ) {
            let offset = interruption / DOWNLOAD_CHECKPOINT_BYTES * DOWNLOAD_CHECKPOINT_BYTES;
            let expected = DownloadSlotState {
                binding: [7; 32],
                offset,
            };
            let state = encode_download_slot_state(expected);
            prop_assert_eq!(
                decode_download_slot_state(&state),
                Some(expected)
            );
            prop_assert!(offset <= interruption);
            prop_assert!(interruption < offset + DOWNLOAD_CHECKPOINT_BYTES);
            prop_assert!(offset.is_multiple_of(DROPBOX_BLOCK_SIZE as u64));
        }

        #[test]
        fn dropbox_hash_and_copy_are_independent_of_reader_fragmentation(
            length in hash_length_strategy(),
            fragments in fragment_strategy(),
            seed in any::<u8>(),
        ) {
            let bytes = patterned_bytes(length, seed);
            let expected = reference_dropbox_hash(&bytes);
            let streamed = dropbox_content_hash(FragmentedReader::new(&bytes, &fragments))
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            prop_assert_eq!(streamed.as_str(), expected.as_str());

            let mut copied = tempfile::tempfile()
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            let copied_identity = copy_and_hash(
                &mut FragmentedReader::new(&bytes, &fragments),
                &mut copied,
                Path::new("fragmented-download"),
                "test fragmented download copy",
            )
            .map_err(|error| TestCaseError::fail(error.to_string()))?;
            prop_assert_eq!(copied_identity.as_str(), expected.as_str());

            copied
                .seek(SeekFrom::Start(0))
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            let mut copied_bytes = Vec::new();
            copied
                .read_to_end(&mut copied_bytes)
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            prop_assert!(copied_bytes == bytes, "copied bytes differ from reader input");
        }
    }

    #[test]
    fn interrupted_downloads_resume_from_durable_boundaries() -> Result<(), Box<dyn Error>> {
        let block = DROPBOX_BLOCK_SIZE as u64;
        let checkpoint = DOWNLOAD_CHECKPOINT_BYTES;
        let total = checkpoint + 2 * block;
        for (interruption, written, durable) in [
            (checkpoint - 1, checkpoint - block, 0),
            (checkpoint, checkpoint, checkpoint),
            (checkpoint + 1, checkpoint, checkpoint),
            (checkpoint + block + 1, checkpoint + block, checkpoint),
        ] {
            let root = TempDir::new()?;
            let staging = TempDir::new()?;
            let target = Path::new("boundary.bin");
            let expected = identity(b"download never reaches verification")?;
            let root_fd = open_absolute_directory(root.path(), "open test root")?;
            let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
            let DownloadPreparation::Ready(partial) =
                prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
            else {
                return Err(io::Error::other("test expected a new download partial").into());
            };
            let partial_path = partial.location.source.path().to_path_buf();

            assert!(
                partial
                    .append(
                        total,
                        &mut FailingBytes {
                            remaining: interruption,
                        },
                    )
                    .is_err()
            );
            assert_eq!(std::fs::metadata(&partial_path)?.len(), written);

            let DownloadPreparation::Ready(resumed) =
                prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
            else {
                return Err(io::Error::other("test expected a resumed download partial").into());
            };
            assert_eq!(resumed.offset(), durable);
            assert_eq!(resumed.file.metadata()?.len(), durable);
        }
        Ok(())
    }

    #[test]
    fn scan_publishes_empty_and_nested_directories() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        std::fs::create_dir_all(root.path().join("parent/child"))?;
        std::fs::create_dir(root.path().join("empty"))?;

        let scan = scan(root.path())?;
        let observations = scan
            .observations()
            .iter()
            .map(|record| (record.path.as_path(), &record.observation))
            .collect::<BTreeMap<_, _>>();
        for path in [
            Path::new("empty"),
            Path::new("parent"),
            Path::new("parent/child"),
        ] {
            assert_eq!(observations.get(path), Some(&&Observation::Directory));
        }
        Ok(())
    }

    #[test]
    fn directory_effects_are_nonoverwriting_and_nonrecursive() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let root_fd = open_absolute_directory(root.path(), "open directory-effect test root")?;

        assert_eq!(
            create_directory_at(&root_fd, Path::new("parent/child"))?,
            CreateDirectoryOutcome::Created
        );
        assert_eq!(
            create_directory_at(&root_fd, Path::new("parent/child"))?,
            CreateDirectoryOutcome::AlreadyPresent
        );
        assert_eq!(
            delete_directory_at(&root_fd, Path::new("parent"))?,
            DeleteDirectoryOutcome::FreshObservation
        );
        assert_eq!(
            delete_directory_at(&root_fd, Path::new("parent/child"))?,
            DeleteDirectoryOutcome::Deleted
        );
        assert_eq!(
            delete_directory_at(&root_fd, Path::new("parent"))?,
            DeleteDirectoryOutcome::Deleted
        );

        std::fs::write(root.path().join("occupied"), b"preserved bytes")?;
        assert_eq!(
            create_directory_at(&root_fd, Path::new("occupied"))?,
            CreateDirectoryOutcome::FreshObservation
        );
        assert_eq!(
            delete_directory_at(&root_fd, Path::new("occupied"))?,
            DeleteDirectoryOutcome::FreshObservation
        );
        assert_eq!(
            std::fs::read(root.path().join("occupied"))?,
            b"preserved bytes"
        );
        Ok(())
    }

    #[test]
    fn parallel_cold_scan_matches_single_worker_scan() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        std::fs::create_dir_all(root.path().join("a/nested"))?;
        std::fs::create_dir(root.path().join("b"))?;
        for (path, bytes) in [
            ("00", b"zero".as_slice()),
            ("01", b"one".as_slice()),
            ("02", b"two".as_slice()),
            ("a/03", b"three".as_slice()),
            ("a/04", b"four".as_slice()),
            ("a/nested/05", b"five".as_slice()),
            ("b/06", b"six".as_slice()),
            ("b/07", b"seven".as_slice()),
        ] {
            std::fs::write(root.path().join(path), bytes)?;
        }

        let single = scan_with_cache_and_workers_completed_at(
            root.path(),
            &[],
            1,
            None,
            all_cache_entries_stable,
        )?;
        let parallel = scan_with_cache_and_workers_completed_at(
            root.path(),
            &[],
            MAX_PARALLEL_HASHES,
            None,
            all_cache_entries_stable,
        )?;

        assert_eq!(parallel, single);
        assert!(
            parallel
                .observations
                .windows(2)
                .all(|pair| pair[0].path < pair[1].path)
        );
        Ok(())
    }

    #[test]
    fn parallel_hash_failure_reports_lowest_path_and_preserves_publication()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let root = directory.path().join("root");
        std::fs::create_dir(&root)?;
        std::fs::write(root.join("kept"), b"kept")?;
        let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
        let _ = scan_and_publish(&mut journal, &root)?;
        let published_inventory = journal.local_inventory()?;
        let published_cache = journal.local_hash_cache()?;
        let cache = published_cache.clone();

        std::fs::write(root.join("a-missing"), b"a")?;
        std::fs::write(root.join("b-missing"), b"b")?;
        let pending = enumerate_scan(&root, &cache, hash_cache_cutoff(SystemTime::now()))?;
        std::fs::remove_file(root.join("a-missing"))?;
        std::fs::remove_file(root.join("b-missing"))?;

        let failure = finish_scan(pending, MAX_PARALLEL_HASHES);
        assert!(matches!(
            failure,
            Err(LocalError::Io { path, .. }) if path == Path::new("a-missing")
        ));
        assert_eq!(journal.local_inventory()?, published_inventory);
        assert_eq!(journal.local_hash_cache()?, published_cache);
        Ok(())
    }

    #[test]
    fn scan_revalidates_nested_directories_after_parallel_hashing() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        std::fs::create_dir(root.path().join("nested"))?;
        std::fs::write(root.path().join("nested/file"), b"bytes")?;
        let pending = enumerate_scan(root.path(), &[], None)?;
        std::fs::write(root.path().join("nested/appeared"), b"new")?;

        let result = finish_scan(pending, MAX_PARALLEL_HASHES);

        assert!(matches!(
            result,
            Err(LocalError::ChangedDuringRead { path, .. }) if path == Path::new("nested")
        ));
        Ok(())
    }

    #[test]
    fn changing_files_are_unknown_without_hiding_stable_files() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let cached_path = Path::new("cached");
        std::fs::write(root.path().join(cached_path), b"before")?;
        let first = scan_with_cache_and_workers_completed_at(
            root.path(),
            &[],
            1,
            None,
            all_cache_entries_stable,
        )?;
        let cache = first.reusable_hashes.clone();
        let hashing_path = Path::new("hashing");
        let stable_path = Path::new("stable");
        std::fs::write(root.path().join(hashing_path), b"before")?;
        std::fs::write(root.path().join(stable_path), b"stable")?;
        let pending = enumerate_scan(root.path(), &cache, all_cache_entries_stable())?;
        assert_eq!(pending.hash_jobs.len(), 2);
        assert_eq!(pending.cached_files.len(), 1);

        std::fs::write(root.path().join(cached_path), b"changed after enumeration")?;
        std::fs::write(root.path().join(hashing_path), b"also changed")?;
        let scan = finish_scan(pending, MAX_PARALLEL_HASHES)?;

        let observations = scan
            .observations()
            .iter()
            .map(|record| (record.path.as_path(), &record.observation))
            .collect::<BTreeMap<_, _>>();
        assert_eq!(
            observations.get(cached_path),
            Some(&&Observation::Unknown(UnknownReason::Incomplete))
        );
        assert_eq!(
            observations.get(hashing_path),
            Some(&&Observation::Unknown(UnknownReason::Incomplete))
        );
        assert!(matches!(
            observations.get(stable_path),
            Some(Observation::Present(_))
        ));
        Ok(())
    }

    #[test]
    fn unchanged_scan_file_reuses_cached_hash_without_reading_bytes() -> Result<(), Box<dyn Error>>
    {
        let root = TempDir::new()?;
        let path = Path::new("cached.txt");
        std::fs::write(root.path().join(path), b"bytes that would hash differently")?;
        let fingerprint = fingerprint(root.path(), path)?;
        let cached = ContentIdentity::new("0".repeat(64));
        let cache = test_cache(path, fingerprint, &cached);
        let scan = scan_with_cache_and_workers_at(
            root.path(),
            &cache,
            MAX_PARALLEL_HASHES,
            all_cache_entries_stable(),
        )?;

        assert_eq!(scanned_content(&scan, path)?, &cached);
        Ok(())
    }

    #[test]
    fn recent_cache_entry_is_rehashed_and_omitted() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let path = Path::new("recent.txt");
        let bytes = b"actual bytes";
        std::fs::write(root.path().join(path), bytes)?;
        let fingerprint = fingerprint(root.path(), path)?;
        let cutoff = HashCacheCutoff {
            seconds: fingerprint.modified_seconds,
            nanoseconds: u32::try_from(fingerprint.modified_nanoseconds)?,
        };
        let cached = ContentIdentity::new("0".repeat(64));
        let scan = scan_with_cache_and_workers_completed_at(
            root.path(),
            &test_cache(path, fingerprint, &cached),
            1,
            Some(cutoff),
            || None,
        )?;

        assert_eq!(scanned_content(&scan, path)?, &identity(bytes)?);
        assert!(scan.reusable_hashes.is_empty());
        Ok(())
    }

    #[test]
    fn every_fingerprint_field_mismatch_rehashes_the_file() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let path = Path::new("changed.txt");
        let bytes = b"actual bytes";
        std::fs::write(root.path().join(path), bytes)?;
        let actual = identity(bytes)?;
        let cached = ContentIdentity::new("0".repeat(64));
        let original = fingerprint(root.path(), path)?;
        let mut variants = Vec::new();

        let mut changed = original.clone();
        changed.device ^= 1;
        variants.push(changed);
        let mut changed = original.clone();
        changed.inode ^= 1;
        variants.push(changed);
        let mut changed = original.clone();
        changed.size ^= 1;
        variants.push(changed);
        let mut changed = original.clone();
        changed.modified_seconds ^= 1;
        variants.push(changed);
        let mut changed = original.clone();
        changed.modified_nanoseconds ^= 1;
        variants.push(changed);
        let mut changed = original.clone();
        changed.changed_seconds ^= 1;
        variants.push(changed);
        let mut changed = original;
        changed.changed_nanoseconds ^= 1;
        variants.push(changed);

        for changed in variants {
            let scan = scan_with_cache_and_workers_at(
                root.path(),
                &test_cache(path, changed, &cached),
                MAX_PARALLEL_HASHES,
                all_cache_entries_stable(),
            )?;
            assert_eq!(scanned_content(&scan, path)?, &actual);
        }
        Ok(())
    }

    #[test]
    fn scan_publication_uses_completion_cutoff_for_new_hashes() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let root = directory.path().join("root");
        std::fs::create_dir(&root)?;
        std::fs::write(root.join("slow.txt"), b"newly hashed")?;
        let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

        let _ = scan_and_publish_at(&mut journal, &root, None, all_cache_entries_stable)?;

        assert_eq!(journal.local_hash_cache()?.len(), 1);
        Ok(())
    }

    #[test]
    fn failed_scan_preserves_published_inventory_and_hash_cache() -> Result<(), Box<dyn Error>> {
        use std::os::unix::fs::symlink;

        let directory = TempDir::new()?;
        let root = directory.path().join("root");
        let outside = directory.path().join("outside");
        std::fs::create_dir(&root)?;
        std::fs::create_dir(&outside)?;
        std::fs::write(root.join("kept.txt"), b"kept")?;
        let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
        assert!(matches!(
            scan_and_publish_at(
                &mut journal,
                &root,
                all_cache_entries_stable(),
                all_cache_entries_stable,
            )?,
            ScanPublication::Published(_)
        ));
        let inventory = journal.local_inventory()?;
        let cache = journal.local_hash_cache()?;
        assert_eq!(cache.len(), 1);

        symlink(&outside, root.join("unsupported-link"))?;
        assert!(scan_and_publish(&mut journal, &root).is_err());
        assert_eq!(journal.local_inventory()?, inventory);
        assert_eq!(journal.local_hash_cache()?, cache);
        Ok(())
    }

    #[test]
    fn switching_local_root_clears_the_hash_cache() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let first = directory.path().join("first");
        let second = directory.path().join("second");
        std::fs::create_dir(&first)?;
        std::fs::create_dir(&second)?;
        std::fs::write(first.join("cached.txt"), b"cached")?;
        let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&first)?)?;
        let _ = scan_and_publish_at(
            &mut journal,
            &first,
            all_cache_entries_stable(),
            all_cache_entries_stable,
        )?;
        assert_eq!(journal.local_hash_cache()?.len(), 1);

        let _ = journal.activate_local_root(&LocalRootBinding::inspect(&second)?)?;

        assert!(journal.local_inventory()?.is_empty());
        assert!(journal.local_hash_cache()?.is_empty());
        Ok(())
    }

    #[test]
    fn upload_stage_collection_removes_only_verified_unreferenced_content()
    -> Result<(), Box<dyn Error>> {
        use std::os::unix::fs::symlink;

        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        std::fs::write(root.path().join("retained"), b"pending bytes")?;
        std::fs::write(root.path().join("orphan"), b"completed bytes")?;
        let retained = identity(b"pending bytes")?;
        let orphan = identity(b"completed bytes")?;
        let corrupt = identity(b"claimed bytes")?;
        let directory = identity(b"directory entry")?;
        let link = identity(b"symlink entry")?;

        let _ = stage_upload(root.path(), "retained", staging.path(), &retained)?;
        let _ = stage_upload(root.path(), "orphan", staging.path(), &orphan)?;
        std::fs::write(staging.path().join(corrupt.as_str()), b"different bytes")?;
        std::fs::create_dir(staging.path().join(directory.as_str()))?;
        symlink(
            root.path().join("retained"),
            staging.path().join(link.as_str()),
        )?;
        std::fs::write(staging.path().join("unrecognized"), b"leave me")?;

        assert_eq!(
            remove_unreferenced_upload_stages(staging.path(), std::slice::from_ref(&retained),)?,
            1
        );
        assert!(staging.path().join(retained.as_str()).is_file());
        assert!(!staging.path().join(orphan.as_str()).exists());
        assert_eq!(
            std::fs::read(staging.path().join(corrupt.as_str()))?,
            b"different bytes"
        );
        assert!(staging.path().join(directory.as_str()).is_dir());
        assert!(staging.path().join(link.as_str()).is_symlink());
        assert_eq!(
            std::fs::read(staging.path().join("unrecognized"))?,
            b"leave me"
        );
        Ok(())
    }

    #[test]
    fn completed_partial_recovers_before_and_after_rename() -> Result<(), Box<dyn Error>> {
        for renamed_before_chmod in [false, true] {
            let root = TempDir::new()?;
            let staging = TempDir::new()?;
            let target = Path::new("target.txt");
            let bytes = b"completed bytes";
            let expected = identity(bytes)?;
            let root_fd = open_absolute_directory(root.path(), "open test root")?;
            let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
            let DownloadPreparation::Ready(mut partial) =
                prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
            else {
                return Err(io::Error::other("test expected a new download partial").into());
            };
            partial.file.write_all(bytes)?;
            let stage_marker = internal_name("download-marker-v1", target, &expected);
            fsetxattr(
                &partial.file,
                DOWNLOAD_STAGE_XATTR,
                stage_marker.as_bytes(),
                XattrFlags::CREATE,
            )?;
            fsync(&partial.file)?;
            if renamed_before_chmod {
                let (slot_directory, slot_name, _, _) = resumable_source(&partial.location)?;
                renameat_with(
                    slot_directory,
                    slot_name,
                    &partial.location.target_directory,
                    &partial.location.stage_name,
                    RenameFlags::NOREPLACE,
                )?;
            }
            drop(partial);

            let preparation =
                prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?;
            assert!(if renamed_before_chmod {
                matches!(
                    preparation,
                    DownloadPreparation::Complete(StageOutcome::AlreadyStaged(()))
                )
            } else {
                matches!(
                    preparation,
                    DownloadPreparation::Complete(StageOutcome::Staged(()))
                )
            });
            assert!(matches!(
                prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?,
                DownloadPreparation::Complete(StageOutcome::AlreadyStaged(()))
            ));
            assert_eq!(
                install_download(root.path(), target, &expected, None)?,
                InstallOutcome::Installed
            );
            assert_eq!(std::fs::read(root.path().join(target))?, bytes);
        }
        Ok(())
    }

    #[test]
    fn download_promotion_cannot_invalidate_complete_scan() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let target = Path::new("target.txt");
        let bytes = b"complete bytes";
        let expected = identity(bytes)?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;
        let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
        let root_access = Arc::new(SyncRootAccess::default());
        let DownloadPreparation::Ready(mut partial) = prepare_download_slot_with_access_at(
            &root_fd,
            root.path(),
            target,
            &expected,
            &lease,
            &root_access,
        )?
        else {
            return Err(io::Error::other("test expected a new download partial").into());
        };
        partial.file.write_all(bytes)?;
        let stage_marker = internal_name("download-marker-v1", target, &expected);
        fsetxattr(
            &partial.file,
            DOWNLOAD_STAGE_XATTR,
            stage_marker.as_bytes(),
            XattrFlags::CREATE,
        )?;
        fsync(&partial.file)?;

        let mut journal = Journal::open(staging.path().join("journal.sqlite3"))?;
        let _ = journal.activate_local_root(&LocalRootBinding::inspect(root.path())?)?;
        let (finished_sender, finished_receiver) = std::sync::mpsc::channel();
        let (publication, worker) = root_access.with_exclusive(|| {
            let worker = thread::Builder::new()
                .name(String::from("test-download-promotion"))
                .spawn(move || {
                    let result = promote_completed_slot(&mut partial.file, &partial.location);
                    let _ = finished_sender.send(());
                    result
                })?;
            match finished_receiver.recv_timeout(Duration::from_millis(50)) {
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Ok(()) => {
                    return Err(io::Error::other("download mutated the root during a scan").into());
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(io::Error::other("download promotion worker disconnected").into());
                }
            }
            let publication = scan_and_publish(&mut journal, root.path())?;
            Ok::<_, Box<dyn Error>>((publication, worker))
        })?;

        assert!(matches!(publication, ScanPublication::Published(_)));
        let outcome = worker
            .join()
            .map_err(|_| io::Error::other("download promotion worker stopped unexpectedly"))??;
        assert!(matches!(outcome, StageOutcome::Staged(())));
        assert_eq!(journal.local_inventory()?.len(), 0);
        assert!(matches!(
            existing_download_stage_at(&root_fd, root.path(), target, &expected)?,
            Some(StageOutcome::AlreadyStaged(()))
        ));
        Ok(())
    }

    #[test]
    fn disposable_download_body_does_not_hold_the_scan_lock() -> Result<(), Box<dyn Error>> {
        struct GatedReader {
            bytes: Cursor<Vec<u8>>,
            started: Option<std::sync::mpsc::Sender<()>>,
            release: std::sync::mpsc::Receiver<()>,
        }

        impl Read for GatedReader {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                if let Some(started) = self.started.take() {
                    started
                        .send(())
                        .map_err(|_| io::Error::other("test start receiver disconnected"))?;
                    self.release
                        .recv()
                        .map_err(|_| io::Error::other("test release sender disconnected"))?;
                }
                self.bytes.read(buffer)
            }
        }

        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let target = Path::new("fallback.bin");
        let bytes = b"disposable download".to_vec();
        let expected = identity(&bytes)?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;
        let root_access = Arc::new(SyncRootAccess::default());
        let DownloadPreparation::Ready(partial) = prepare_disposable_download_with_access_at(
            &root_fd,
            root.path(),
            target,
            &expected,
            staging.path(),
            &root_access,
        )?
        else {
            return Err(io::Error::other("test expected a disposable download").into());
        };
        assert!(matches!(
            &partial.location.source,
            DownloadSource::Disposable { .. }
        ));

        let total = u64::try_from(bytes.len())?;
        let (started_sender, started_receiver) = std::sync::mpsc::channel();
        let (release_sender, release_receiver) = std::sync::mpsc::channel();
        let (scan_sender, scan_receiver) = std::sync::mpsc::channel();
        let outcome = thread::scope(|scope| -> Result<_, Box<dyn Error>> {
            let download = thread::Builder::new().spawn_scoped(scope, || {
                partial.append(
                    total,
                    &mut GatedReader {
                        bytes: Cursor::new(bytes),
                        started: Some(started_sender),
                        release: release_receiver,
                    },
                )
            })?;
            started_receiver.recv_timeout(Duration::from_secs(1))?;
            let scan_access = Arc::clone(&root_access);
            let scan = thread::Builder::new().spawn_scoped(scope, move || {
                scan_access.with_exclusive(|| scan_sender.send(()))
            })?;
            let scan_result = scan_receiver.recv_timeout(Duration::from_millis(250));
            release_sender
                .send(())
                .map_err(|_| io::Error::other("test download reader disconnected"))?;
            let download = download
                .join()
                .map_err(|_| io::Error::other("test download worker stopped"))??;
            scan.join()
                .map_err(|_| io::Error::other("test scan worker stopped"))?
                .map_err(|_| io::Error::other("test scan receiver disconnected"))?;
            scan_result?;
            Ok(download)
        })?;

        assert!(matches!(outcome, StageOutcome::Staged(())));
        assert!(matches!(
            existing_download_stage_at(&root_fd, root.path(), target, &expected)?,
            Some(StageOutcome::AlreadyStaged(()))
        ));
        assert_eq!(std::fs::read_dir(staging.path())?.count(), 0);
        Ok(())
    }

    #[test]
    fn corrupt_completed_partial_restarts_only_when_owned() -> Result<(), Box<dyn Error>> {
        for owned in [true, false] {
            let root = TempDir::new()?;
            let staging = TempDir::new()?;
            let target = Path::new("target.txt");
            let expected = identity(b"complete bytes")?;
            let root_fd = open_absolute_directory(root.path(), "open test root")?;
            let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
            let DownloadPreparation::Ready(mut partial) =
                prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
            else {
                return Err(io::Error::other("test expected a new download partial").into());
            };
            partial.file.write_all(b"incomplete")?;
            if !owned {
                fsetxattr(
                    &partial.file,
                    DOWNLOAD_PARTIAL_XATTR,
                    b"foreign owner",
                    XattrFlags::empty(),
                )?;
            }
            let partial_path = partial.location.source.path().to_path_buf();
            let stage_marker = internal_name("download-marker-v1", target, &expected);
            fsetxattr(
                &partial.file,
                DOWNLOAD_STAGE_XATTR,
                stage_marker.as_bytes(),
                XattrFlags::CREATE,
            )?;
            fsync(&partial.file)?;
            drop(partial);

            let preparation =
                prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?;
            if owned {
                let DownloadPreparation::Ready(restarted) = preparation else {
                    return Err(io::Error::other("owned corrupt partial did not restart").into());
                };
                assert_eq!(restarted.offset(), 0);
                assert_eq!(restarted.file.metadata()?.len(), 0);
            } else {
                assert!(matches!(preparation, DownloadPreparation::Ephemeral));
                assert_eq!(std::fs::read(partial_path)?, b"incomplete");
            }
        }
        Ok(())
    }

    #[test]
    fn completed_partial_promotion_preserves_a_swapped_replacement() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let target = Path::new("target.txt");
        let bytes = b"complete bytes";
        let expected = identity(bytes)?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;
        let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
        let DownloadPreparation::Ready(mut partial) =
            prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
        else {
            return Err(io::Error::other("test expected a new download partial").into());
        };
        partial.file.write_all(bytes)?;
        let stage_marker = internal_name("download-marker-v1", target, &expected);
        fsetxattr(
            &partial.file,
            DOWNLOAD_STAGE_XATTR,
            stage_marker.as_bytes(),
            XattrFlags::CREATE,
        )?;
        fsync(&partial.file)?;
        let moved = staging.path().join("held-slot");
        let partial_path = partial.location.source.path().to_path_buf();

        assert!(matches!(
            promote_completed_slot_with(&mut partial.file, &partial.location, || {
                std::fs::rename(&partial_path, &moved)?;
                std::fs::write(&partial_path, b"replacement")
            })?,
            StageOutcome::DestinationOccupied { path }
                if path == partial_path
        ));
        assert_eq!(std::fs::read(&partial_path)?, b"replacement");
        assert_eq!(std::fs::read(moved)?, bytes);
        assert!(!partial.location.stage_path.exists());
        Ok(())
    }

    #[test]
    fn cross_filesystem_slot_completion_copies_rehashes_and_frees_the_slot()
    -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let target = Path::new("target.txt");
        let bytes = b"complete bytes";
        let expected = identity(bytes)?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;
        let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
        let DownloadPreparation::Ready(mut partial) =
            prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
        else {
            return Err(io::Error::other("test expected a new download slot").into());
        };
        partial.file.write_all(bytes)?;
        let stage_marker = internal_name("download-marker-v1", target, &expected);
        fsetxattr(
            &partial.file,
            DOWNLOAD_STAGE_XATTR,
            stage_marker.as_bytes(),
            XattrFlags::CREATE,
        )?;
        fsync(&partial.file)?;

        assert!(matches!(
            copy_completed_slot(&mut partial.file, &partial.location)?,
            StageOutcome::Staged(())
        ));
        assert_eq!(std::fs::metadata(partial.location.source.path())?.len(), 0);
        assert_eq!(
            install_download(root.path(), target, &expected, None)?,
            InstallOutcome::Installed
        );
        assert_eq!(std::fs::read(root.path().join(target))?, bytes);
        Ok(())
    }

    #[test]
    fn partial_reset_never_mutates_a_swapped_replacement() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let target = Path::new("target.txt");
        let expected = identity(b"expected bytes")?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;
        let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
        let DownloadPreparation::Ready(partial) =
            prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
        else {
            return Err(io::Error::other("test expected a new download partial").into());
        };
        let partial_path = partial.location.source.path().to_path_buf();
        let moved = staging.path().join("held-slot");
        let (slot_directory, slot_name, slot_path, binding) = resumable_source(&partial.location)?;

        assert!(
            reset_download_slot_file_with(
                &partial.file,
                slot_directory,
                slot_name,
                slot_path,
                binding,
                || {
                    std::fs::rename(&partial_path, &moved)?;
                    std::fs::write(&partial_path, b"replacement")
                },
            )?
            .is_none()
        );
        assert_eq!(std::fs::read(&partial_path)?, b"replacement");
        assert_eq!(std::fs::metadata(&moved)?.len(), 0);
        let moved_file = File::open(moved)?;
        assert_eq!(
            read_download_slot_state(&moved_file, target)?,
            Some(DownloadSlotState { binding, offset: 0 })
        );
        let marker = internal_name("download-marker-v1", target, &expected);
        assert_eq!(
            read_download_marker(&moved_file, marker.as_bytes(), target)?,
            DownloadMarker::Missing
        );
        Ok(())
    }

    #[test]
    fn interrupted_partial_reset_replays_to_a_reusable_zero_checkpoint()
    -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let target = Path::new("target.txt");
        let bytes = b"complete bytes";
        let expected = identity(bytes)?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;
        let lease = test_download_lease(staging.path(), target, &expected, 1, 1)?;
        let DownloadPreparation::Ready(mut partial) =
            prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?
        else {
            return Err(io::Error::other("test expected a new download partial").into());
        };
        partial.file.write_all(bytes)?;
        let stage_marker = internal_name("download-marker-v1", target, &expected);
        fsetxattr(
            &partial.file,
            DOWNLOAD_STAGE_XATTR,
            stage_marker.as_bytes(),
            XattrFlags::CREATE,
        )?;
        fsync(&partial.file)?;
        partial.file.set_len(0)?;
        let (_, _, _, binding) = resumable_source(&partial.location)?;
        fsetxattr(
            &partial.file,
            DOWNLOAD_PARTIAL_XATTR,
            &encode_download_slot_state(DownloadSlotState { binding, offset: 0 }),
            XattrFlags::empty(),
        )?;
        fsync(&partial.file)?;
        staged_download(stage_download(
            root.path(),
            target,
            &expected,
            Cursor::new(bytes),
        )?)?;
        let partial_path = partial.location.source.path().to_path_buf();
        drop(partial);

        assert!(matches!(
            prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?,
            DownloadPreparation::Complete(StageOutcome::AlreadyStaged(()))
        ));
        assert_eq!(std::fs::metadata(&partial_path)?.len(), 0);
        assert!(matches!(
            prepare_download_slot_at(&root_fd, root.path(), target, &expected, &lease)?,
            DownloadPreparation::Complete(StageOutcome::AlreadyStaged(()))
        ));
        assert_eq!(
            install_download(root.path(), target, &expected, None)?,
            InstallOutcome::Installed
        );
        assert_eq!(std::fs::read(root.path().join(target))?, bytes);
        Ok(())
    }

    #[test]
    fn download_slot_pool_has_four_fixed_paths_without_overflow() -> Result<(), Box<dyn Error>> {
        let staging = TempDir::new()?;
        let expected = identity(b"download")?;
        let identities = (0_i64..5)
            .map(|operation| {
                test_slot_identity(
                    Path::new(&format!("target-{operation}")),
                    &expected,
                    1,
                    operation + 1,
                )
            })
            .collect::<Vec<_>>();

        let leases = lease_download_slots(staging.path(), &identities)?;
        assert_eq!(leases.iter().filter(|lease| lease.is_some()).count(), 4);
        let mut names = std::fs::read_dir(staging.path())?
            .map(|entry| entry.map(|entry| entry.file_name()))
            .collect::<Result<Vec<_>, _>>()?;
        names.sort();
        assert_eq!(names, (0_u8..4).map(download_slot_name).collect::<Vec<_>>());
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn slots_lease_through_a_symlinked_state_home() -> Result<(), Box<dyn Error>> {
        use std::os::unix::fs::symlink;

        use crate::config::{Config, XdgDirectories};

        let temporary = TempDir::new()?;
        let physical_state = temporary.path().join("physical-state");
        std::fs::create_dir(&physical_state)?;
        let physical_state = std::fs::canonicalize(&physical_state)?;
        let state_link = temporary.path().join("state-link");
        symlink(&physical_state, &state_link)?;
        let sync_root = temporary.path().join("Dropbox");
        std::fs::create_dir(&sync_root)?;
        let xdg = XdgDirectories::new(temporary.path().join("config"), &state_link)?;
        let config = Config::from_values(&xdg, &sync_root, "test-app-key")?;
        config.prepare()?;

        let staging = config.paths().upload_staging_directory();
        let expected = identity(b"download")?;
        let lease = test_download_lease(staging, Path::new("target.txt"), &expected, 1, 1)?;

        let paths = config.paths();
        for path in [
            paths.state_directory(),
            paths.journal_file(),
            paths.upload_staging_directory(),
            paths.recovery_directory(),
            paths.lock_file(),
        ] {
            assert!(
                path.starts_with(&physical_state),
                "path was not projected: {}",
                path.display()
            );
        }
        assert!(
            physical_state
                .join("omabox/upload-staging")
                .join(download_slot_name(lease.slot))
                .is_file()
        );
        Ok(())
    }

    #[test]
    fn stale_slot_is_rebound_across_root_and_operation_identity() -> Result<(), Box<dyn Error>> {
        let staging = TempDir::new()?;
        let target = Path::new("target.txt");
        let expected = identity(b"download")?;
        let old_identity = test_slot_identity(target, &expected, 1, 10);
        let old_lease = lease_download_slots(staging.path(), std::slice::from_ref(&old_identity))?
            .into_iter()
            .next()
            .flatten()
            .ok_or_else(|| io::Error::other("old slot was not leased"))?;
        let old_binding = old_lease.binding;
        let old_path = staging.path().join(download_slot_name(old_lease.slot));
        std::fs::write(&old_path, b"stale bytes")?;
        assert!(lease_download_slots(staging.path(), &[])?.is_empty());
        let freed = File::open(&old_path)?;
        assert_eq!(freed.metadata()?.len(), 0);
        assert_eq!(
            read_download_slot_state(&freed, &old_path)?,
            Some(DownloadSlotState {
                binding: old_binding,
                offset: 0,
            })
        );

        let changed_root = test_slot_identity(target, &expected, 2, 10);
        let changed_operation = test_slot_identity(target, &expected, 1, 11);
        assert_ne!(changed_root.binding, old_binding);
        assert_ne!(changed_operation.binding, old_binding);
        let new_lease = lease_download_slots(staging.path(), &[changed_root])?
            .into_iter()
            .next()
            .flatten()
            .ok_or_else(|| io::Error::other("stale slot was not rebound"))?;
        let file = File::open(staging.path().join(download_slot_name(new_lease.slot)))?;
        assert_eq!(file.metadata()?.len(), 0);
        assert_eq!(
            read_download_slot_state(&file, &old_path)?,
            Some(DownloadSlotState {
                binding: new_lease.binding,
                offset: 0,
            })
        );
        Ok(())
    }

    #[test]
    fn absent_install_never_overwrites_an_existing_file() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let desired = identity(b"remote")?;
        staged_download(stage_download(
            directory.path(),
            Path::new("target.txt"),
            &desired,
            Cursor::new(b"remote"),
        )?)?;
        std::fs::write(directory.path().join("target.txt"), b"local")?;

        let outcome = install_download(directory.path(), "target.txt", &desired, None)?;
        assert!(matches!(
            outcome,
            InstallOutcome::PreconditionChanged { actual: Some(_) }
        ));
        assert_eq!(
            std::fs::read(directory.path().join("target.txt"))?,
            b"local"
        );
        Ok(())
    }

    #[test]
    fn delete_replay_preserves_a_raced_edit_and_removes_its_guard() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let target = Path::new("target.txt");
        let expected = identity(b"old")?;
        std::fs::write(root.path().join(target), b"old")?;
        let guard = internal_name("deleted", target, &expected);
        std::fs::rename(root.path().join(target), root.path().join(&guard))?;
        std::fs::write(root.path().join(target), b"raced edit")?;

        assert!(matches!(
            delete_local(root.path(), target, &expected)?,
            DeleteOutcome::PreconditionChanged { actual: Some(_) }
        ));
        assert_eq!(std::fs::read(root.path().join(target))?, b"raced edit");
        assert!(!root.path().join(guard).exists());
        Ok(())
    }

    #[test]
    fn install_rejects_stage_changed_through_a_preexisting_writer() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let target = Path::new("target.txt");
        let expected = identity(b"remote")?;
        staged_download(stage_download(
            root.path(),
            target,
            &expected,
            Cursor::new(b"remote"),
        )?)?;
        let root_fd = open_absolute_directory(root.path(), "open test root")?;
        let Some((parent, target_name, parent_relative)) = open_parent(&root_fd, target, false)?
        else {
            return Err(io::Error::other("test target had no parent").into());
        };
        let stage_name = internal_name("download", target, &expected);
        let stage_path = root.path().join(parent_relative).join(&stage_name);
        let stage_file = File::open(&stage_path)?;
        fchmod(&stage_file, Mode::RUSR | Mode::WUSR)?;
        drop(stage_file);
        let mut writer = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&stage_path)?;
        let DownloadStage::Verified(stage) =
            inspect_download_stage(&parent, &stage_name, &stage_path, target, &expected)?
        else {
            return Err(io::Error::other("test stage was not verified").into());
        };
        fchmod(&writer, Mode::RUSR | Mode::WUSR)?;
        writer.seek(SeekFrom::Start(0))?;
        writer.write_all(b"mutant")?;
        writer.sync_all()?;

        let result = rename_stage_into_absent_target(
            &parent,
            &stage_name,
            &stage_path,
            &stage,
            &target_name,
            target,
            &expected,
        );

        assert!(matches!(
            result,
            Err(LocalError::ChangedDuringRead {
                operation: "verify download stage before rename",
                ..
            })
        ));
        assert!(!root.path().join(target).exists());
        assert_eq!(std::fs::read(stage_path)?, b"mutant");
        Ok(())
    }

    #[test]
    fn installed_download_cleanup_replays_around_partial_marker_removal()
    -> Result<(), Box<dyn Error>> {
        for partial_was_removed in [false, true] {
            let directory = TempDir::new()?;
            let target = Path::new("target.txt");
            let target_path = directory.path().join(target);
            let bytes = b"installed bytes";
            let expected = identity(bytes)?;
            std::fs::write(&target_path, bytes)?;
            let file = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(&target_path)?;
            let binding = test_slot_identity(target, &expected, 1, 1).binding;
            let stage_marker = internal_name("download-marker-v1", target, &expected);
            fsetxattr(
                &file,
                DOWNLOAD_PARTIAL_XATTR,
                &encode_download_slot_state(DownloadSlotState { binding, offset: 0 }),
                XattrFlags::CREATE,
            )?;
            fsetxattr(
                &file,
                DOWNLOAD_STAGE_XATTR,
                stage_marker.as_bytes(),
                XattrFlags::CREATE,
            )?;
            fchmod(&file, Mode::RUSR)?;
            fsync(&file)?;
            let parent = open_absolute_directory(directory.path(), "open test root")?;

            if partial_was_removed {
                fchmod(&file, Mode::RUSR | Mode::WUSR)?;
                fremovexattr(&file, DOWNLOAD_PARTIAL_XATTR)?;
                fsync(&file)?;
            } else {
                assert_eq!(
                    read_download_slot_state(&file, target)?,
                    Some(DownloadSlotState { binding, offset: 0 })
                );
            }
            assert_eq!(
                read_download_marker(&file, stage_marker.as_bytes(), target)?,
                DownloadMarker::Expected
            );

            sync_installed_download(&parent, target.as_os_str(), target, &expected)?;
            assert_eq!(
                read_download_marker(&file, stage_marker.as_bytes(), target)?,
                DownloadMarker::Missing
            );
            assert_eq!(read_download_slot_state(&file, target)?, None);
            let mode = Mode::from_bits_retain(stat_fd(&file, target, "inspect test mode")?.st_mode);
            assert!(mode.contains(Mode::RUSR | Mode::WUSR));
            sync_installed_download(&parent, target.as_os_str(), target, &expected)?;
        }
        Ok(())
    }

    #[test]
    fn renamed_download_requires_its_ownership_marker() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let target = Path::new("target.txt");
        std::fs::write(directory.path().join(target), b"remote")?;
        let desired = identity(b"remote")?;
        let parent = open_absolute_directory(directory.path(), "open test root")?;
        let file = File::open(directory.path().join(target))?;
        let stage = VerifiedDownloadStage {
            fingerprint: file_fingerprint(
                &stat_fd(&file, target, "inspect test download")?,
                target,
            )?,
            file,
        };

        let required = sync_renamed_download(&stage, &parent, target.as_os_str(), target, &desired);
        assert!(matches!(
            required,
            Err(LocalError::ChangedDuringRead {
                operation: "verify renamed download ownership",
                ..
            })
        ));
        sync_installed_download(&parent, target.as_os_str(), target, &desired)?;
        Ok(())
    }
}
