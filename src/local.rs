//! Root-confined local observation and crash-safe file phases.

use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

use rustix::fd::{AsFd, OwnedFd};
use rustix::fs::{
    AtFlags, CWD, Dir, FileType, Mode, OFlags, RenameFlags, ResolveFlags, XattrFlags, fchmod,
    fgetxattr, fremovexattr, fsetxattr, fstat, fsync, linkat, mkdirat, openat2, renameat_with,
    unlinkat,
};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::journal::{Journal, JournalError, LocalObservationRecord};
use crate::model::{ContentIdentity, LocalFile, Observation, UnknownReason};

const DROPBOX_BLOCK_SIZE: usize = 4 * 1024 * 1024;
const DOWNLOAD_STAGE_XATTR: &str = "user.omabox.download-stage-v1";
const BELOW_ROOT: ResolveFlags = ResolveFlags::BENEATH
    .union(ResolveFlags::NO_SYMLINKS)
    .union(ResolveFlags::NO_MAGICLINKS);
const ABSOLUTE_SAFE: ResolveFlags = ResolveFlags::NO_SYMLINKS.union(ResolveFlags::NO_MAGICLINKS);

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
    observations: Vec<LocalObservationRecord>,
}

impl CompleteScan {
    /// Return the complete, path-sorted local observations.
    #[must_use]
    pub fn observations(&self) -> &[LocalObservationRecord] {
        &self.observations
    }
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

/// Verified recovery evidence required by a destructive local phase.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedRecovery {
    original_path: PathBuf,
    content: ContentIdentity,
}

impl VerifiedRecovery {
    pub(crate) fn new(original_path: PathBuf, content: ContentIdentity) -> Self {
        Self {
            original_path,
            content,
        }
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

/// Scan the complete root through no-follow, descriptor-relative opens.
///
/// Any inaccessible, changing, symlinked, magic-linked, or special entry
/// fails the whole scan. Callers therefore cannot confuse a partial walk with
/// confirmed absence. Directories are retained as conservative unknown file
/// observations while their contents are scanned recursively.
fn scan(root: impl AsRef<Path>) -> Result<CompleteScan, LocalError> {
    let root = root.as_ref();
    let root_fd = open_absolute_directory(root, "open sync root for scan")?;
    let before = stat_fd(&root_fd, root, "inspect sync root before scan")?;
    let mut observations = Vec::new();
    scan_directory(&root_fd, Path::new(""), &mut observations)?;
    let after = stat_fd(&root_fd, root, "inspect sync root after scan")?;
    if !same_observation(&before, &after) {
        return Err(LocalError::ChangedDuringRead {
            operation: "complete local scan",
            path: root.to_path_buf(),
        });
    }
    let rebound = open_absolute_directory(root, "reopen sync root after scan")?;
    let rebound_stat = stat_fd(&rebound, root, "verify sync root binding after scan")?;
    if !same_inode(&before, &rebound_stat) {
        return Err(LocalError::ChangedDuringRead {
            operation: "verify complete local scan root",
            path: root.to_path_buf(),
        });
    }
    observations.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(CompleteScan { observations })
}

/// Scan completely and publish only the successful inventory transaction.
pub fn scan_and_publish(
    journal: &mut Journal,
    root: impl AsRef<Path>,
) -> Result<CompleteScan, LocalError> {
    let scan = scan(root)?;
    journal
        .publish_local_inventory(scan.observations())
        .map_err(|source| LocalError::Journal { source })?;
    Ok(scan)
}

/// Copy a root-confined local file into immutable upload staging.
pub fn stage_upload(
    root: impl AsRef<Path>,
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
    if let Some((file, actual)) = open_and_hash_if_present(
        &directory,
        &name,
        &stage_path,
        "verify immutable upload stage",
    )? && reuse_verified_stage(&file, &actual, expected, None, &directory, &stage_path)?
    {
        return Ok(StageOutcome::AlreadyStaged(stage()));
    }

    let root_fd = open_absolute_directory(root.as_ref(), "open sync root for upload staging")?;
    let mut source = open_relative_regular(&root_fd, relative, "open upload source")?;
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

/// Re-observe one root-confined upload source without changing staging state.
pub(crate) fn observe_upload_source(
    root: impl AsRef<Path>,
    relative: impl AsRef<Path>,
) -> Result<ContentIdentity, LocalError> {
    let relative = relative.as_ref();
    let root = open_absolute_directory(root.as_ref(), "open sync root for upload observation")?;
    let mut source = open_relative_regular(&root, relative, "open upload source")?;
    hash_stable_file(&mut source, relative, "verify upload source")
}

/// Stage downloaded bytes beside their target, verify them, and sync them.
pub fn stage_download(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    expected: &ContentIdentity,
    mut bytes: impl Read,
) -> Result<StageOutcome<()>, LocalError> {
    require_content_hash(expected, "stage download")?;
    let target = target.as_ref();
    let root_fd = open_absolute_directory(root.as_ref(), "open sync root for download staging")?;
    let Some((parent, _, _)) = open_parent(&root_fd, target, true)? else {
        return Err(LocalError::UnsafeRelativePath {
            path: target.to_path_buf(),
        });
    };
    let name = internal_name("download", target, expected);
    let marker = internal_name("download-marker-v1", target, expected);
    let display_path = root.as_ref().join(parent_path(target)?).join(&name);
    let result = write_verified_stage(
        &parent,
        &name,
        &display_path,
        expected,
        &mut bytes,
        ExistingPolicy::OwnedDownload(marker.as_bytes()),
        "stage download",
    )?;
    map_stage_write(result, || ())
}

/// Durably prepare a recovered local file for replacement without deleting it.
///
/// This real filesystem phase is independently replayable: after it returns,
/// the original bytes are either still at the target or at a deterministic
/// same-directory guard, and the containing directory has been synchronized.
pub fn prepare_replacement(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    recovery: &VerifiedRecovery,
) -> Result<ReplacementPreparation, LocalError> {
    let root = root.as_ref();
    let target = target.as_ref();
    validate_recovery(recovery, target)?;
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
        recovery,
    )
}

/// Atomically install a verified staged download without overwriting a changed target.
///
/// `recovery` is required for replacement and proves the displaced bytes have
/// already been copied and verified. An initially absent install passes `None`
/// and uses `RENAME_NOREPLACE`.
pub fn install_download(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    desired: &ContentIdentity,
    recovery: Option<&VerifiedRecovery>,
) -> Result<InstallOutcome, LocalError> {
    let root = root.as_ref();
    let target = target.as_ref();
    require_content_hash(desired, "install download")?;
    let root_fd = open_absolute_directory(root, "open sync root for download install")?;
    let Some((parent, target_name, parent_relative)) = open_parent(&root_fd, target, false)? else {
        return Ok(InstallOutcome::DownloadRequired);
    };
    let stage_name = internal_name("download", target, desired);
    let stage_path = root.join(&parent_relative).join(&stage_name);
    let current = hash_at_if_present(&parent, &target_name, target, "check install precondition")?;
    if current.as_ref() == Some(desired) {
        sync_installed_download(
            &parent,
            &target_name,
            target,
            desired,
            MarkerRequirement::Optional,
        )?;
        if let StageCleanup::Occupied(path) =
            remove_verified_stage(&parent, &stage_name, desired, &stage_path, target)?
        {
            return Ok(InstallOutcome::StageDestinationOccupied { path });
        }
        if let Some(recovery) = recovery {
            validate_recovery(recovery, target)?;
            remove_guard_if_verified(&parent, target, recovery)?;
        }
        sync_directory(&parent, target, "sync already-installed download")?;
        return Ok(InstallOutcome::AlreadyInstalled);
    }

    let Some(recovery) = recovery else {
        if current.is_some() {
            return Ok(InstallOutcome::PreconditionChanged { actual: current });
        }
        match inspect_download_stage(&parent, &stage_name, &stage_path, target, desired)? {
            DownloadStage::Verified => {}
            DownloadStage::Missing => return Ok(InstallOutcome::DownloadRequired),
            DownloadStage::Occupied(path) => {
                return Ok(InstallOutcome::StageDestinationOccupied { path });
            }
        }
        return rename_stage_into_absent_target(
            &parent,
            &stage_name,
            &stage_path,
            &target_name,
            target,
            desired,
        );
    };
    validate_recovery(recovery, target)?;
    match inspect_download_stage(&parent, &stage_name, &stage_path, target, desired)? {
        DownloadStage::Verified => {}
        DownloadStage::Missing => return Ok(InstallOutcome::DownloadRequired),
        DownloadStage::Occupied(path) => {
            return Ok(InstallOutcome::StageDestinationOccupied { path });
        }
    }

    match prepare_replacement_at(
        &parent,
        root,
        &parent_relative,
        &target_name,
        target,
        recovery,
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
            sync_installed_download(
                &parent,
                &target_name,
                target,
                desired,
                MarkerRequirement::Optional,
            )?;
            if let StageCleanup::Occupied(path) =
                remove_verified_stage(&parent, &stage_name, desired, &stage_path, target)?
            {
                return Ok(InstallOutcome::StageDestinationOccupied { path });
            }
        }
        remove_guard_if_verified(&parent, target, recovery)?;
        if actual == *desired {
            sync_directory(&parent, target, "sync raced prepared replacement cleanup")?;
            return Ok(InstallOutcome::AlreadyInstalled);
        }
        sync_directory(&parent, target, "sync raced prepared replacement")?;
        return Ok(InstallOutcome::PreconditionChanged {
            actual: Some(actual),
        });
    }

    let guard = internal_name("displaced", target, &recovery.content);
    match renameat_with(
        &parent,
        &stage_name,
        &parent,
        &target_name,
        RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            sync_installed_download(
                &parent,
                &target_name,
                target,
                desired,
                MarkerRequirement::Required,
            )?;
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
                sync_installed_download(
                    &parent,
                    &target_name,
                    target,
                    desired,
                    MarkerRequirement::Optional,
                )?;
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

/// Conditionally delete a local file after a verified recovery copy exists.
pub fn delete_local(
    root: impl AsRef<Path>,
    target: impl AsRef<Path>,
    recovery: &VerifiedRecovery,
) -> Result<DeleteOutcome, LocalError> {
    let root = root.as_ref();
    let target = target.as_ref();
    validate_recovery(recovery, target)?;
    let root_fd = open_absolute_directory(root, "open sync root for local deletion")?;
    let Some((parent, target_name, parent_relative)) = open_parent(&root_fd, target, false)? else {
        return Ok(DeleteOutcome::AlreadyDeleted);
    };
    let guard = internal_name("deleted", target, &recovery.content);
    let guard_path = root.join(&parent_relative).join(&guard);
    let current = hash_at_if_present(&parent, &target_name, target, "check delete precondition")?;

    if current.is_none() {
        if let Some(guard_content) =
            hash_at_if_present(&parent, &guard, &guard_path, "inspect interrupted deletion")?
        {
            if guard_content != recovery.content {
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
    if current.as_ref() != Some(&recovery.content) {
        return Ok(DeleteOutcome::PreconditionChanged { actual: current });
    }
    if let Some(guard_content) =
        hash_at_if_present(&parent, &guard, &guard_path, "inspect deletion guard")?
    {
        if guard_content != recovery.content {
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
    if displaced.as_ref() != Some(&recovery.content) {
        let actual = displaced;
        restore_or_preserve_changed_guard(&parent, &guard, &target_name, target, actual.as_ref())?;
        return Ok(DeleteOutcome::PreconditionChanged { actual });
    }
    unlinkat(&parent, &guard, AtFlags::empty())
        .map_err(|source| syscall_failure("delete verified displaced file", target, source))?;
    sync_directory(&parent, target, "sync local deletion")?;
    Ok(DeleteOutcome::Deleted)
}

/// Materialize one deterministic conflict copy without overwriting any file.
pub fn materialize_conflict(
    root: impl AsRef<Path>,
    original: impl AsRef<Path>,
    side: ConflictSide,
    expected: &ContentIdentity,
    mut bytes: impl Read,
) -> Result<ConflictOutcome, LocalError> {
    require_content_hash(expected, "materialize conflict")?;
    let root = root.as_ref();
    let original = original.as_ref();
    let root_fd = open_absolute_directory(root, "open sync root for conflict")?;
    let Some((parent, _, _)) = open_parent(&root_fd, original, true)? else {
        return Err(LocalError::UnsafeRelativePath {
            path: original.to_path_buf(),
        });
    };
    let name = conflict_name(original, side, expected);
    let relative_path = conflict_relative_path(original, side, expected)?;
    let display_path = root.join(&relative_path);
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

pub(crate) fn open_root_file(
    root: &OwnedFd,
    relative: &Path,
    operation: &'static str,
) -> Result<File, LocalError> {
    open_relative_regular(root, relative, operation)
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

pub(crate) fn materialize_verified_copy(
    directory: &OwnedFd,
    directory_path: &Path,
    name: &OsStr,
    expected: &ContentIdentity,
    source: &mut File,
) -> Result<StageOutcome<()>, LocalError> {
    let destination = directory_path.join(name);
    let before = stat_fd(source, &destination, "inspect recovery source before copy")?;
    let result = write_verified_stage(
        directory,
        name,
        &destination,
        expected,
        source,
        ExistingPolicy::Preserve,
        "materialize recovery copy",
    )?;
    let after = stat_fd(source, &destination, "inspect recovery source after copy")?;
    if !same_observation(&before, &after) {
        return Err(LocalError::ChangedDuringRead {
            operation: "materialize recovery copy",
            path: destination,
        });
    }
    match result {
        StageWrite::Created => Ok(StageOutcome::Staged(())),
        StageWrite::Reused => Ok(StageOutcome::AlreadyStaged(())),
        StageWrite::Mismatch(actual) => Ok(StageOutcome::ContentChanged { actual }),
        StageWrite::Occupied(path) => Err(LocalError::DestinationOccupied {
            operation: "materialize recovery copy",
            path,
        }),
    }
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
    observations: &mut Vec<LocalObservationRecord>,
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
                    observations.push(LocalObservationRecord {
                        path,
                        observation: Observation::Unknown(UnknownReason::Unsupported),
                    });
                    continue;
                }
                let mut file = open_relative_at(directory, &name, &path, OFlags::RDONLY)?;
                let opened = stat_fd(&file, &path, "inspect opened scan file")?;
                if !same_inode(&probe_stat, &opened) {
                    return Err(LocalError::ChangedDuringRead {
                        operation: "open scanned file",
                        path,
                    });
                }
                let content = hash_stable_file(&mut file, &path, "hash local scan file")?;
                observations.push(LocalObservationRecord {
                    path,
                    observation: Observation::Present(LocalFile::new(content)),
                });
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
                observations.push(LocalObservationRecord {
                    path: path.clone(),
                    observation: Observation::Unknown(UnknownReason::Unsupported),
                });
                scan_directory(&child, &path, observations)?;
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
    Ok(())
}

fn hash_stream(reader: &mut impl Read) -> io::Result<ContentIdentity> {
    let mut aggregate = Sha256::new();
    let mut block = vec![0_u8; DROPBOX_BLOCK_SIZE];
    loop {
        let mut filled = 0;
        while filled < block.len() {
            let count = reader.read(&mut block[filled..])?;
            if count == 0 {
                break;
            }
            filled += count;
        }
        if filled == 0 {
            break;
        }
        aggregate.update(Sha256::digest(&block[..filled]));
        if filled < block.len() {
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
    let before = stat_fd(file, path, operation)?;
    if FileType::from_raw_mode(before.st_mode) != FileType::RegularFile {
        return Err(LocalError::UnsupportedObject {
            path: path.to_path_buf(),
        });
    }
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
    Ok(identity)
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
    let value = identity.as_str().as_bytes();
    if value.len() == 64
        && value
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
    {
        Ok(())
    } else {
        Err(LocalError::InvalidContentIdentity { operation })
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
    Ok(File::from(fd))
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
    Ok(open_and_hash_if_present(directory, name, path, operation)?.map(|(_, content)| content))
}

fn open_and_hash_if_present(
    directory: &OwnedFd,
    name: &OsStr,
    path: &Path,
    operation: &'static str,
) -> Result<Option<(File, ContentIdentity)>, LocalError> {
    match openat2(
        directory,
        name,
        OFlags::RDONLY | OFlags::CLOEXEC,
        Mode::empty(),
        BELOW_ROOT,
    ) {
        Ok(fd) => {
            let mut file = File::from(fd);
            let content = hash_stable_file(&mut file, path, operation)?;
            Ok(Some((file, content)))
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

enum DownloadStage {
    Missing,
    Verified,
    Occupied(PathBuf),
}

fn inspect_download_stage(
    directory: &OwnedFd,
    name: &OsStr,
    display_path: &Path,
    target: &Path,
    expected: &ContentIdentity,
) -> Result<DownloadStage, LocalError> {
    let Some((file, actual)) =
        open_and_hash_if_present(directory, name, display_path, "verify owned download stage")?
    else {
        return Ok(DownloadStage::Missing);
    };
    let marker = internal_name("download-marker-v1", target, expected);
    if actual == *expected && download_marker_matches(&file, marker.as_bytes(), display_path)? {
        Ok(DownloadStage::Verified)
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
            download_marker_matches(file, marker, path)
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
) -> Result<StageWrite, LocalError> {
    let marker = match policy {
        ExistingPolicy::OwnedDownload(marker) => Some(marker),
        ExistingPolicy::ReplacePrivate | ExistingPolicy::Preserve => None,
    };
    if let Some((file, actual)) =
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
            let Some((file, existing)) =
                open_and_hash_if_present(directory, name, display_path, "verify raced stage")?
            else {
                return Err(LocalError::ChangedDuringRead {
                    operation,
                    path: display_path.to_path_buf(),
                });
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
                    }),
                }
            }
        }
        Err(source) => Err(syscall_failure(
            "install verified private stage",
            display_path,
            source,
        )),
    }
}

fn copy_and_hash(
    reader: &mut impl Read,
    writer: &mut File,
    path: &Path,
    operation: &'static str,
) -> Result<ContentIdentity, LocalError> {
    let mut aggregate = Sha256::new();
    let mut block = vec![0_u8; DROPBOX_BLOCK_SIZE];
    loop {
        let mut filled = 0;
        while filled < block.len() {
            let count = reader
                .read(&mut block[filled..])
                .map_err(|source| io_failure(operation, path, source))?;
            if count == 0 {
                break;
            }
            writer
                .write_all(&block[filled..filled + count])
                .map_err(|source| io_failure("write private stage", path, source))?;
            filled += count;
        }
        if filled == 0 {
            break;
        }
        aggregate.update(Sha256::digest(&block[..filled]));
        if filled < block.len() {
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
    target_name: &OsStr,
    target: &Path,
    desired: &ContentIdentity,
) -> Result<InstallOutcome, LocalError> {
    match renameat_with(
        parent,
        stage_name,
        parent,
        target_name,
        RenameFlags::NOREPLACE,
    ) {
        Ok(()) => {
            sync_installed_download(
                parent,
                target_name,
                target,
                desired,
                MarkerRequirement::Required,
            )?;
            Ok(InstallOutcome::Installed)
        }
        Err(source) if source == rustix::io::Errno::EXIST => {
            let actual =
                hash_at_if_present(parent, target_name, target, "inspect raced initial install")?;
            if actual.as_ref() == Some(desired) {
                sync_installed_download(
                    parent,
                    target_name,
                    target,
                    desired,
                    MarkerRequirement::Optional,
                )?;
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
    recovery: &VerifiedRecovery,
) -> Result<ReplacementPreparation, LocalError> {
    let guard = internal_name("displaced", target, &recovery.content);
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
        if guard_content == recovery.content {
            return Ok(ReplacementPreparation::AlreadyPrepared);
        }
        return Err(LocalError::DestinationOccupied {
            operation: "prepare download replacement",
            path: guard_path,
        });
    }
    if current.as_ref() != Some(&recovery.content) {
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
            if existing.as_ref() == Some(&recovery.content) {
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
    if displaced.as_ref() != Some(&recovery.content) {
        let actual = displaced;
        restore_or_preserve_changed_guard(parent, &guard, target_name, target, actual.as_ref())?;
        return Ok(ReplacementPreparation::PreconditionChanged { actual });
    }
    Ok(ReplacementPreparation::Prepared)
}

fn validate_recovery(recovery: &VerifiedRecovery, target: &Path) -> Result<(), LocalError> {
    require_content_hash(&recovery.content, "validate recovery before mutation")?;
    if recovery.original_path == target {
        Ok(())
    } else {
        Err(LocalError::UnsafeRelativePath {
            path: recovery.original_path.clone(),
        })
    }
}

fn remove_guard_if_verified(
    parent: &OwnedFd,
    target: &Path,
    recovery: &VerifiedRecovery,
) -> Result<(), LocalError> {
    let guard = internal_name("displaced", target, &recovery.content);
    if let Some(actual) = hash_at_if_present(parent, &guard, target, "verify stale install guard")?
    {
        if actual != recovery.content {
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
        DownloadStage::Verified => {
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

#[derive(Clone, Copy, Eq, PartialEq)]
enum MarkerRequirement {
    Required,
    Optional,
}

fn sync_installed_download(
    parent: &OwnedFd,
    target_name: &OsStr,
    target: &Path,
    expected: &ContentIdentity,
    marker_requirement: MarkerRequirement,
) -> Result<(), LocalError> {
    let Some((file, actual)) =
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
    let marker_matches = download_marker_matches(&file, marker.as_bytes(), target)?;
    if marker_requirement == MarkerRequirement::Required && !marker_matches {
        return Err(LocalError::ChangedDuringRead {
            operation: "verify renamed download ownership",
            path: target.to_path_buf(),
        });
    }
    if marker_matches {
        fchmod(&file, Mode::RUSR | Mode::WUSR).map_err(|source| {
            syscall_failure("make installed download writable", target, source)
        })?;
        match fremovexattr(&file, DOWNLOAD_STAGE_XATTR) {
            Ok(()) => {}
            Err(source) if source == rustix::io::Errno::NODATA => {}
            Err(source) => {
                return Err(syscall_failure(
                    "clear installed download marker",
                    target,
                    source,
                ));
            }
        }
    }
    fsync(&file).map_err(|source| syscall_failure("sync installed download", target, source))?;
    sync_directory(parent, target, "sync installed download entry")
}

fn download_marker_matches(file: &File, marker: &[u8], path: &Path) -> Result<bool, LocalError> {
    let mut actual = [0_u8; 96];
    match fgetxattr(file, DOWNLOAD_STAGE_XATTR, &mut actual) {
        Ok(length) => Ok(actual.get(..length).is_some_and(|value| value == marker)),
        Err(source)
            if source == rustix::io::Errno::NODATA || source == rustix::io::Errno::RANGE =>
        {
            Ok(false)
        }
        Err(source) => Err(syscall_failure(
            "verify download stage marker",
            path,
            source,
        )),
    }
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
    use std::io::Cursor;

    use tempfile::TempDir;

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

    #[test]
    fn scan_rejects_symlinks_instead_of_publishing_absence() -> Result<(), Box<dyn Error>> {
        use std::os::unix::fs::symlink;

        let directory = TempDir::new()?;
        let outside = TempDir::new()?;
        std::fs::write(outside.path().join("outside.txt"), b"outside")?;
        symlink(outside.path(), directory.path().join("escape"))?;
        let result = scan(directory.path());
        assert!(result.is_err());
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
    fn renamed_download_requires_its_ownership_marker() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let target = Path::new("target.txt");
        std::fs::write(directory.path().join(target), b"remote")?;
        let desired = identity(b"remote")?;
        let parent = open_absolute_directory(directory.path(), "open test root")?;

        let required = sync_installed_download(
            &parent,
            target.as_os_str(),
            target,
            &desired,
            MarkerRequirement::Required,
        );
        assert!(matches!(
            required,
            Err(LocalError::ChangedDuringRead {
                operation: "verify renamed download ownership",
                ..
            })
        ));
        sync_installed_download(
            &parent,
            target.as_os_str(),
            target,
            &desired,
            MarkerRequirement::Optional,
        )?;
        Ok(())
    }
}
