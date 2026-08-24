//! Verified recovery copies and direct replay of journaled operations.

use std::io;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rustix::fd::OwnedFd;
use rustix::fs::{AtFlags, FileType, fsync, statat, unlinkat};
use thiserror::Error;

use crate::dropbox::{DropboxClient, DropboxError, MutationOutcome, RemotePathState};
use crate::journal::{
    Journal, JournalError, OperationCompletion, PlanConflictCompletion, PlanRecord,
    PlannedOperation, RecordStatus, RecoveryCompletion, RecoveryForget, RecoveryRecord,
    RecoveryWrite,
};
use crate::local::{
    ConflictOutcome, ConflictSide, DeleteOutcome, InstallOutcome, LocalError, StageOutcome,
    StagedUpload, VerifiedRecovery, conflict_relative_path, delete_local_at, install_download_at,
    materialize_conflict_at, materialize_verified_copy, observe_upload_source_at,
    open_private_directory, open_root, open_root_file, recovery_file_name, stage_upload_at,
    verify_private_copy,
};
use crate::model::{Baseline, Conflict, ContentIdentity, LocalFile, Operation, RemoteFile};

/// Completed recovery payloads remain available for this long before cleanup.
pub const COMPLETED_RECOVERY_RETENTION: Duration = Duration::from_secs(30 * 24 * 60 * 60);

/// A recovery or replay failure.
#[derive(Debug, Error)]
pub enum RecoveryError {
    /// A root-confined filesystem phase failed.
    #[error("recovery filesystem phase failed")]
    Local {
        /// Original local filesystem error.
        #[source]
        source: LocalError,
    },
    /// A durable journal phase failed.
    #[error("recovery journal phase failed")]
    Journal {
        /// Original journal error.
        #[source]
        source: JournalError,
    },
    /// Dropbox failed while replaying a journaled remote effect.
    #[error("Dropbox replay failed for `{path}`")]
    Dropbox {
        /// Synchronized path affected by the request.
        path: PathBuf,
        /// Original Dropbox client error.
        #[source]
        source: DropboxError,
    },
    /// A journal record did not satisfy the recovery contract.
    #[error("journaled recovery state is invalid for `{path}`: {detail}")]
    InvalidJournalState {
        /// Synchronized path affected by the invalid record.
        path: PathBuf,
        /// Stable, non-secret explanation.
        detail: &'static str,
    },
}

impl From<LocalError> for RecoveryError {
    fn from(source: LocalError) -> Self {
        Self::Local { source }
    }
}

impl From<JournalError> for RecoveryError {
    fn from(source: JournalError) -> Self {
        Self::Journal { source }
    }
}

/// Result of copying and verifying a journaled recovery payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RecoveryMaterialization {
    /// A new durable recovery file was created.
    Created(VerifiedRecovery),
    /// The same durable recovery file already existed.
    AlreadyPresent(VerifiedRecovery),
    /// The local source no longer contains the journaled bytes.
    SourceChanged {
        /// Identity of the current source bytes.
        actual: ContentIdentity,
    },
}

/// Why a replayable operation remains pending.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReplayBlocked {
    /// The exact remote payload must be downloaded before installation.
    DownloadRequired {
        /// Synchronized path awaiting bytes.
        path: PathBuf,
        /// Required Dropbox content identity.
        content: ContentIdentity,
    },
    /// Unrelated bytes occupy the deterministic download-stage path.
    StageDestinationOccupied {
        /// Reserved path that was preserved without modification.
        path: PathBuf,
    },
    /// The local path no longer satisfies the journaled precondition.
    PreconditionChanged {
        /// Synchronized path that changed.
        path: PathBuf,
        /// Current local content, or `None` when absent.
        actual: Option<ContentIdentity>,
    },
    /// A recovery copy cannot be made because its source changed.
    RecoverySourceChanged {
        /// Synchronized path that changed.
        path: PathBuf,
        /// Current source identity.
        actual: ContentIdentity,
    },
    /// The next journal phase requires Dropbox rather than the local engine.
    RemoteOperation {
        /// Synchronized path awaiting a remote phase.
        path: PathBuf,
    },
    /// Dropbox confirmed that the mutation remains safely retryable.
    RemotePending {
        /// Synchronized path awaiting another finite replay pass.
        path: PathBuf,
    },
    /// A folder or unsupported Dropbox object occupies a file operation path.
    RemoteObject {
        /// Synchronized path preserved without mutation.
        path: PathBuf,
    },
}

/// Work completed and conservatively deferred by one finite replay pass.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ReplayReport {
    /// Number of operation records durably completed during this pass.
    pub completed_operations: usize,
    /// Plans left pending for bytes, a changed precondition, or Dropbox work.
    pub blocked: Vec<ReplayBlocked>,
}

/// Deterministic, non-overwriting destination for a recovery record.
#[must_use]
pub fn destination(
    recovery_directory: impl AsRef<Path>,
    original_path: impl AsRef<Path>,
    content: &ContentIdentity,
) -> PathBuf {
    recovery_directory
        .as_ref()
        .join(recovery_file_name(original_path.as_ref(), content))
}

/// Remove expired recovery payloads that no unfinished journal work can need.
///
/// Unknown entries and records whose payload is not a verified regular file are
/// retained. The directory entry is synchronized before its completed journal
/// record is forgotten, so interruption safely retries the same cleanup.
pub fn prune_completed_recoveries(
    journal: &mut Journal,
    recovery_directory: impl AsRef<Path>,
) -> Result<usize, RecoveryError> {
    prune_completed_recoveries_at(journal, recovery_directory.as_ref(), SystemTime::now())
}

fn prune_completed_recoveries_at(
    journal: &mut Journal,
    recovery_directory: &Path,
    now: SystemTime,
) -> Result<usize, RecoveryError> {
    let directory =
        open_private_directory(recovery_directory, "open recovery directory for retention")?;
    let mut forgotten = 0;
    for record in journal.completed_recoveries()? {
        if record.recovery_path
            != destination(recovery_directory, &record.original_path, &record.content)
        {
            continue;
        }
        let name = recovery_file_name(&record.original_path, &record.content);
        let before = match statat(&directory, &name, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(metadata) => metadata,
            Err(source) if source == rustix::io::Errno::NOENT => {
                sync_retention_directory(&directory, recovery_directory)?;
                forgotten += forget_recovery(journal, &record)?;
                continue;
            }
            Err(source) => {
                return Err(retention_io(
                    "inspect retained recovery payload",
                    &record.recovery_path,
                    source,
                ));
            }
        };
        if FileType::from_raw_mode(before.st_mode) != FileType::RegularFile
            || !expired_recovery(&record, now)
        {
            continue;
        }
        match verify_private_copy(&directory, recovery_directory, &name, &record.content) {
            Ok(true) => {}
            Ok(false) => {
                sync_retention_directory(&directory, recovery_directory)?;
                forgotten += forget_recovery(journal, &record)?;
                continue;
            }
            Err(
                LocalError::CorruptPrivateFile { .. }
                | LocalError::UnsupportedObject { .. }
                | LocalError::ChangedDuringRead { .. }
                | LocalError::DestinationOccupied { .. }
                | LocalError::InvalidContentIdentity { .. }
                | LocalError::UnsafeRelativePath { .. },
            ) => continue,
            Err(source) => return Err(source.into()),
        }
        let after = match statat(&directory, &name, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(metadata) => metadata,
            Err(source) if source == rustix::io::Errno::NOENT => {
                sync_retention_directory(&directory, recovery_directory)?;
                forgotten += forget_recovery(journal, &record)?;
                continue;
            }
            Err(source) => {
                return Err(retention_io(
                    "reinspect retained recovery payload",
                    &record.recovery_path,
                    source,
                ));
            }
        };
        if FileType::from_raw_mode(after.st_mode) != FileType::RegularFile
            || before.st_dev != after.st_dev
            || before.st_ino != after.st_ino
        {
            continue;
        }
        match unlinkat(&directory, &name, AtFlags::empty()) {
            Ok(()) => {}
            Err(source) if source == rustix::io::Errno::NOENT => {}
            Err(source) => {
                return Err(retention_io(
                    "remove expired recovery payload",
                    &record.recovery_path,
                    source,
                ));
            }
        }
        sync_retention_directory(&directory, recovery_directory)?;
        forgotten += forget_recovery(journal, &record)?;
    }
    Ok(forgotten)
}

fn expired_recovery(record: &RecoveryRecord, now: SystemTime) -> bool {
    let Some(retained_at) = record.retained_at else {
        return false;
    };
    let Some(retained_since) = UNIX_EPOCH.checked_add(Duration::from_secs(retained_at)) else {
        return false;
    };
    now.duration_since(retained_since)
        .is_ok_and(|age| age >= COMPLETED_RECOVERY_RETENTION)
}

fn sync_retention_directory(
    directory: &impl rustix::fd::AsFd,
    path: &Path,
) -> Result<(), RecoveryError> {
    fsync(directory).map_err(|source| retention_io("sync recovery retention", path, source))
}

fn forget_recovery(journal: &mut Journal, record: &RecoveryRecord) -> Result<usize, RecoveryError> {
    match journal.forget_completed_recovery(record.id)? {
        RecoveryForget::Forgotten => Ok(1),
        RecoveryForget::NotFound => Ok(0),
        RecoveryForget::Pending => Err(RecoveryError::InvalidJournalState {
            path: record.original_path.clone(),
            detail: "completed recovery became pending during retention",
        }),
    }
}

fn retention_io(operation: &'static str, path: &Path, source: rustix::io::Errno) -> RecoveryError {
    RecoveryError::Local {
        source: LocalError::Io {
            operation,
            path: path.to_path_buf(),
            source: io::Error::from_raw_os_error(source.raw_os_error()),
        },
    }
}

/// Materialize and verify the concrete copy described by a recovery record.
///
/// The destination must equal the deterministic path derived from the record;
/// an existing different file is never overwritten.
pub fn materialize(
    sync_root: impl AsRef<Path>,
    recovery_directory: impl AsRef<Path>,
    record: &RecoveryRecord,
) -> Result<RecoveryMaterialization, RecoveryError> {
    let sync_root = sync_root.as_ref();
    let root = open_root(sync_root, "open sync root for recovery")?;
    materialize_at(&root, recovery_directory, record)
}

fn materialize_at(
    root: &OwnedFd,
    recovery_directory: impl AsRef<Path>,
    record: &RecoveryRecord,
) -> Result<RecoveryMaterialization, RecoveryError> {
    let recovery_directory = recovery_directory.as_ref();
    let expected_path = destination(recovery_directory, &record.original_path, &record.content);
    if record.recovery_path != expected_path {
        return Err(RecoveryError::InvalidJournalState {
            path: record.original_path.clone(),
            detail: "recovery destination is not the deterministic configured path",
        });
    }
    materialize_expected_at(
        root,
        recovery_directory,
        &record.original_path,
        &record.content,
    )
}

/// Materialize a deterministic local recovery copy before its plan is visible.
///
/// A prior matching copy is reusable, but never substitutes for checking that
/// the currently observed source still contains the planned bytes.
pub(crate) fn materialize_before_plan(
    sync_root: &Path,
    recovery_directory: &Path,
    original_path: &Path,
    content: &ContentIdentity,
) -> Result<RecoveryMaterialization, RecoveryError> {
    let root = open_root(sync_root, "open sync root for recovery preparation")?;
    let materialized = materialize_expected_at(&root, recovery_directory, original_path, content)?;
    let actual = observe_upload_source_at(&root, original_path)?;
    if actual != *content {
        return Ok(RecoveryMaterialization::SourceChanged { actual });
    }
    Ok(materialized)
}

fn materialize_expected_at(
    root: &OwnedFd,
    recovery_directory: &Path,
    original_path: &Path,
    content: &ContentIdentity,
) -> Result<RecoveryMaterialization, RecoveryError> {
    let name = recovery_file_name(original_path, content);
    let directory =
        open_private_directory(recovery_directory, "open configured recovery directory")?;
    if verify_private_copy(&directory, recovery_directory, &name, content)? {
        return Ok(RecoveryMaterialization::AlreadyPresent(
            VerifiedRecovery::new(original_path.to_path_buf(), content.clone()),
        ));
    }
    let mut source = open_root_file(
        root,
        original_path,
        "open displaced local payload for recovery",
    )?;
    let outcome =
        materialize_verified_copy(&directory, recovery_directory, &name, content, &mut source)?;
    let verified = || VerifiedRecovery::new(original_path.to_path_buf(), content.clone());
    match outcome {
        StageOutcome::Staged(()) => Ok(RecoveryMaterialization::Created(verified())),
        StageOutcome::AlreadyStaged(()) => Ok(RecoveryMaterialization::AlreadyPresent(verified())),
        StageOutcome::ContentChanged { actual } => {
            Ok(RecoveryMaterialization::SourceChanged { actual })
        }
        StageOutcome::DestinationOccupied { path } => Err(RecoveryError::Local {
            source: LocalError::DestinationOccupied {
                operation: "materialize recovery copy",
                path,
            },
        }),
    }
}

/// Replay every currently pending local journal phase once.
///
/// This is deliberately a finite match over the existing typed operation
/// records. Remote operations and missing downloads remain pending for the
/// sequential reconciler; no worker or executor abstraction is involved.
pub fn replay_local_operations(
    journal: &mut Journal,
    sync_root: impl AsRef<Path>,
    recovery_directory: impl AsRef<Path>,
) -> Result<ReplayReport, RecoveryError> {
    let sync_root = sync_root.as_ref();
    let root = open_root(sync_root, "open sync root for local replay")?;
    replay_local_operations_at(journal, &root, sync_root, recovery_directory.as_ref())
}

pub(crate) fn replay_local_operations_at(
    journal: &mut Journal,
    root: &OwnedFd,
    root_path: &Path,
    recovery_directory: &Path,
) -> Result<ReplayReport, RecoveryError> {
    let plans = journal.pending_plans()?;
    replay_local_plans_at(journal, root, root_path, recovery_directory, plans.iter())
}

pub(crate) fn replay_local_plans_at<'a>(
    journal: &mut Journal,
    root: &OwnedFd,
    root_path: &Path,
    recovery_directory: &Path,
    plans: impl IntoIterator<Item = &'a PlanRecord>,
) -> Result<ReplayReport, RecoveryError> {
    let mut report = ReplayReport::default();

    for plan in plans {
        for (index, planned) in plan.operations.iter().enumerate() {
            if planned.status == RecordStatus::Completed {
                continue;
            }
            let blocked = match &planned.operation {
                Operation::PreserveLocal { .. } => {
                    let following = plan.operations.get(index + 1).ok_or_else(|| {
                        RecoveryError::InvalidJournalState {
                            path: plan.path.clone(),
                            detail: "local preservation has no following destructive operation",
                        }
                    })?;
                    match ensure_verified_recovery(
                        journal,
                        root,
                        recovery_directory,
                        following,
                        &plan.path,
                    )? {
                        RecoveryReady::Verified(_) => {}
                        RecoveryReady::SourceChanged(actual) => {
                            report.blocked.push(ReplayBlocked::RecoverySourceChanged {
                                path: plan.path.clone(),
                                actual,
                            });
                            break;
                        }
                    }
                    complete_nonfinal(journal, planned, &plan.path)?;
                    report.completed_operations += 1;
                    None
                }
                Operation::InstallLocal { source } => {
                    match install_download_at(root, root_path, &plan.path, &source.content, None)? {
                        InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => {
                            complete_final(
                                journal,
                                planned,
                                &plan.path,
                                &Baseline::Present(source.clone()),
                            )?;
                            report.completed_operations += 1;
                            None
                        }
                        InstallOutcome::DownloadRequired => Some(ReplayBlocked::DownloadRequired {
                            path: plan.path.clone(),
                            content: source.content.clone(),
                        }),
                        InstallOutcome::StageDestinationOccupied { path } => {
                            Some(ReplayBlocked::StageDestinationOccupied { path })
                        }
                        InstallOutcome::PreconditionChanged { actual } => {
                            Some(ReplayBlocked::PreconditionChanged {
                                path: plan.path.clone(),
                                actual,
                            })
                        }
                    }
                }
                Operation::ReplaceLocal {
                    source,
                    expected_content: _,
                } => {
                    let recovery = match ensure_verified_recovery(
                        journal,
                        root,
                        recovery_directory,
                        planned,
                        &plan.path,
                    )? {
                        RecoveryReady::Verified(recovery) => recovery,
                        RecoveryReady::SourceChanged(actual) => {
                            report.blocked.push(ReplayBlocked::RecoverySourceChanged {
                                path: plan.path.clone(),
                                actual,
                            });
                            break;
                        }
                    };
                    match install_download_at(
                        root,
                        root_path,
                        &plan.path,
                        &source.content,
                        Some(&recovery),
                    )? {
                        InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => {
                            complete_final(
                                journal,
                                planned,
                                &plan.path,
                                &Baseline::Present(source.clone()),
                            )?;
                            report.completed_operations += 1;
                            None
                        }
                        InstallOutcome::DownloadRequired => Some(ReplayBlocked::DownloadRequired {
                            path: plan.path.clone(),
                            content: source.content.clone(),
                        }),
                        InstallOutcome::StageDestinationOccupied { path } => {
                            Some(ReplayBlocked::StageDestinationOccupied { path })
                        }
                        InstallOutcome::PreconditionChanged { actual } => {
                            Some(ReplayBlocked::PreconditionChanged {
                                path: plan.path.clone(),
                                actual,
                            })
                        }
                    }
                }
                Operation::DeleteLocal { .. } => {
                    let recovery = match ensure_verified_recovery(
                        journal,
                        root,
                        recovery_directory,
                        planned,
                        &plan.path,
                    )? {
                        RecoveryReady::Verified(recovery) => recovery,
                        RecoveryReady::SourceChanged(actual) => {
                            report.blocked.push(ReplayBlocked::RecoverySourceChanged {
                                path: plan.path.clone(),
                                actual,
                            });
                            break;
                        }
                    };
                    match delete_local_at(root, root_path, &plan.path, &recovery)? {
                        DeleteOutcome::Deleted | DeleteOutcome::AlreadyDeleted => {
                            complete_final(journal, planned, &plan.path, &Baseline::Absent)?;
                            report.completed_operations += 1;
                            None
                        }
                        DeleteOutcome::PreconditionChanged { actual } => {
                            Some(ReplayBlocked::PreconditionChanged {
                                path: plan.path.clone(),
                                actual,
                            })
                        }
                    }
                }
                Operation::CreateRemote { .. }
                | Operation::PreserveRemote { .. }
                | Operation::ReplaceRemote { .. }
                | Operation::DeleteRemote { .. } => Some(ReplayBlocked::RemoteOperation {
                    path: plan.path.clone(),
                }),
            };
            if let Some(blocked) = blocked {
                report.blocked.push(blocked);
                break;
            }
        }
    }
    Ok(report)
}

/// Replay every currently pending remote journal phase once.
pub fn replay_remote_operations(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: impl AsRef<Path>,
    upload_staging: impl AsRef<Path>,
    recovery_directory: impl AsRef<Path>,
) -> Result<ReplayReport, RecoveryError> {
    let sync_root = sync_root.as_ref();
    let root = open_root(sync_root, "open sync root for remote replay")?;
    replay_remote_operations_at(
        journal,
        dropbox,
        &root,
        sync_root,
        upload_staging.as_ref(),
        recovery_directory.as_ref(),
    )
}

pub(crate) fn replay_remote_operations_at(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    upload_staging: &Path,
    recovery_directory: &Path,
) -> Result<ReplayReport, RecoveryError> {
    let plans = journal.pending_plans()?;
    let mut report = ReplayReport::default();

    for plan in plans {
        for (index, planned) in plan.operations.iter().enumerate() {
            if planned.status == RecordStatus::Completed {
                continue;
            }
            let blocked = match &planned.operation {
                Operation::PreserveRemote { file } => {
                    let following = plan.operations.get(index + 1).ok_or_else(|| {
                        RecoveryError::InvalidJournalState {
                            path: plan.path.clone(),
                            detail: "remote preservation has no following destructive operation",
                        }
                    })?;
                    preserve_remote(
                        journal,
                        dropbox,
                        recovery_directory,
                        following,
                        &plan.path,
                        file,
                    )?;
                    complete_nonfinal(journal, planned, &plan.path)?;
                    report.completed_operations += 1;
                    None
                }
                Operation::CreateRemote { content } => {
                    let Some(staged) =
                        prepare_upload(root, upload_staging, &plan.path, content, &mut report)?
                    else {
                        break;
                    };
                    if let Some(blocked) = ensure_remote_parents(dropbox, &plan.path)? {
                        Some(blocked)
                    } else {
                        let outcome = dropbox
                            .create_file(&plan.path, &staged)
                            .map_err(|source| dropbox_error(&plan.path, source))?;
                        apply_file_mutation(
                            journal,
                            dropbox,
                            root,
                            root_path,
                            &plan,
                            planned,
                            &staged,
                            FileMutation::Create,
                            outcome,
                            &mut report,
                        )?
                    }
                }
                Operation::ReplaceRemote {
                    content,
                    expected_revision,
                } => {
                    let Some(staged) =
                        prepare_upload(root, upload_staging, &plan.path, content, &mut report)?
                    else {
                        break;
                    };
                    ensure_destructive_remote_recovery(
                        journal,
                        dropbox,
                        recovery_directory,
                        &plan,
                        index,
                        planned,
                        expected_revision,
                    )?;
                    let outcome = dropbox
                        .replace_file(&plan.path, expected_revision, &staged)
                        .map_err(|source| dropbox_error(&plan.path, source))?;
                    apply_file_mutation(
                        journal,
                        dropbox,
                        root,
                        root_path,
                        &plan,
                        planned,
                        &staged,
                        FileMutation::Replace,
                        outcome,
                        &mut report,
                    )?
                }
                Operation::DeleteRemote { expected_revision } => {
                    ensure_destructive_remote_recovery(
                        journal,
                        dropbox,
                        recovery_directory,
                        &plan,
                        index,
                        planned,
                        expected_revision,
                    )?;
                    let outcome = dropbox
                        .delete_file(&plan.path, expected_revision)
                        .map_err(|source| dropbox_error(&plan.path, source))?;
                    apply_delete_mutation(
                        journal,
                        dropbox,
                        root,
                        root_path,
                        &plan,
                        planned,
                        outcome,
                        &mut report,
                    )?
                }
                Operation::InstallLocal { .. }
                | Operation::PreserveLocal { .. }
                | Operation::ReplaceLocal { .. }
                | Operation::DeleteLocal { .. } => break,
            };
            if let Some(blocked) = blocked {
                report.blocked.push(blocked);
                break;
            }
        }
    }
    Ok(report)
}

fn ensure_destructive_remote_recovery(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    recovery_directory: &Path,
    plan: &crate::journal::PlanRecord,
    index: usize,
    destructive: &PlannedOperation,
    expected_revision: &crate::model::DropboxRevision,
) -> Result<(), RecoveryError> {
    let preserve = index
        .checked_sub(1)
        .and_then(|previous| plan.operations.get(previous))
        .ok_or_else(|| invalid(&plan.path, "remote mutation has no preceding preservation"))?;
    let Operation::PreserveRemote { file } = &preserve.operation else {
        return Err(invalid(
            &plan.path,
            "remote mutation is not preceded by remote preservation",
        ));
    };
    if &file.revision != expected_revision {
        return Err(invalid(
            &plan.path,
            "remote preservation revision does not match its mutation",
        ));
    }
    preserve_remote(
        journal,
        dropbox,
        recovery_directory,
        destructive,
        &plan.path,
        file,
    )
}

fn ensure_remote_parents(
    dropbox: &DropboxClient,
    path: &Path,
) -> Result<Option<ReplayBlocked>, RecoveryError> {
    let mut current = PathBuf::new();
    let mut parents = Vec::new();
    let components = path.components().collect::<Vec<_>>();
    if components.is_empty()
        || components
            .iter()
            .any(|component| !matches!(component, Component::Normal(_)))
    {
        return Err(invalid(path, "remote create path is not safely relative"));
    }
    for component in &components[..components.len() - 1] {
        let Component::Normal(component) = component else {
            return Err(invalid(path, "remote create path is not safely relative"));
        };
        current.push(component);
        parents.push(current.clone());
    }
    for parent in parents {
        match dropbox
            .create_folder(&parent)
            .map_err(|source| dropbox_error(path, source))?
        {
            MutationOutcome::Applied(RemotePathState::Folder) => {}
            MutationOutcome::Pending => {
                return Ok(Some(ReplayBlocked::RemotePending {
                    path: path.to_path_buf(),
                }));
            }
            MutationOutcome::PreconditionChanged(
                RemotePathState::File(_) | RemotePathState::Unsupported,
            ) => {
                return Ok(Some(ReplayBlocked::RemoteObject {
                    path: path.to_path_buf(),
                }));
            }
            MutationOutcome::Applied(_)
            | MutationOutcome::PreconditionChanged(
                RemotePathState::Absent | RemotePathState::Folder,
            ) => {
                return Err(invalid(
                    path,
                    "parent folder creation returned an impossible state",
                ));
            }
        }
    }
    Ok(None)
}

#[derive(Clone, Copy)]
enum FileMutation {
    Create,
    Replace,
}

fn prepare_upload(
    root: &OwnedFd,
    upload_staging: &Path,
    path: &Path,
    content: &ContentIdentity,
    report: &mut ReplayReport,
) -> Result<Option<StagedUpload>, RecoveryError> {
    match stage_upload_at(root, path, upload_staging, content)? {
        StageOutcome::Staged(stage) | StageOutcome::AlreadyStaged(stage) => Ok(Some(stage)),
        StageOutcome::ContentChanged { actual } => {
            report.blocked.push(ReplayBlocked::PreconditionChanged {
                path: path.to_path_buf(),
                actual: Some(actual),
            });
            Ok(None)
        }
        StageOutcome::DestinationOccupied { path } => {
            report
                .blocked
                .push(ReplayBlocked::StageDestinationOccupied { path });
            Ok(None)
        }
    }
}

fn preserve_remote(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    recovery_directory: &Path,
    following: &PlannedOperation,
    path: &Path,
    file: &RemoteFile,
) -> Result<(), RecoveryError> {
    let recovery_path = destination(recovery_directory, path, &file.content);
    let record = recovery_record(journal, following, path, &recovery_path)?;
    if record.recovery_path != recovery_path || record.content != file.content {
        return Err(invalid(
            path,
            "remote recovery record does not match its plan",
        ));
    }
    let name = recovery_file_name(path, &file.content);
    ensure_exact_copy(dropbox, recovery_directory, Path::new(&name), path, file)?;
    match journal.complete_recovery(record.id)? {
        RecoveryCompletion::Completed | RecoveryCompletion::AlreadyCompleted => Ok(()),
        RecoveryCompletion::NotFound => Err(invalid(
            path,
            "remote recovery disappeared from the journal",
        )),
    }
}

fn recovery_record(
    journal: &mut Journal,
    planned: &PlannedOperation,
    path: &Path,
    recovery_path: &Path,
) -> Result<RecoveryRecord, RecoveryError> {
    match journal.record_recovery_intent(planned.id, recovery_path)? {
        RecoveryWrite::Recorded(record) | RecoveryWrite::AlreadyRecorded(record) => Ok(record),
        RecoveryWrite::OperationNotFound => Err(invalid(path, "recovery operation disappeared")),
        RecoveryWrite::OperationCompleted => Err(invalid(
            path,
            "completed operation requested remote recovery",
        )),
        RecoveryWrite::OperationNotDestructive => {
            Err(invalid(path, "journal rejected remote recovery intent"))
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn apply_file_mutation(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    plan: &crate::journal::PlanRecord,
    planned: &PlannedOperation,
    staged: &StagedUpload,
    mutation: FileMutation,
    outcome: MutationOutcome,
    report: &mut ReplayReport,
) -> Result<Option<ReplayBlocked>, RecoveryError> {
    match outcome {
        MutationOutcome::Applied(RemotePathState::File(remote)) => {
            complete_final(journal, planned, &plan.path, &Baseline::Present(remote))?;
            report.completed_operations += 1;
            Ok(None)
        }
        MutationOutcome::Applied(_) => Err(invalid(
            &plan.path,
            "file mutation returned an impossible applied state",
        )),
        MutationOutcome::Pending => Ok(Some(ReplayBlocked::RemotePending {
            path: plan.path.clone(),
        })),
        MutationOutcome::PreconditionChanged(RemotePathState::File(remote)) => {
            materialize_local_conflict_at(root, root_path, &plan.path, staged)?;
            materialize_remote_conflict_at(dropbox, root, root_path, &plan.path, &remote)?;
            let local = LocalFile::new(staged.content().clone());
            let conflict = match mutation {
                FileMutation::Create => Conflict::InitialCollision { local, remote },
                FileMutation::Replace => Conflict::DivergentEdits { local, remote },
            };
            finish_conflict(journal, plan.id, &plan.path, &conflict)?;
            report.completed_operations += 1;
            Ok(None)
        }
        MutationOutcome::PreconditionChanged(RemotePathState::Absent) => match mutation {
            FileMutation::Replace => {
                materialize_local_conflict_at(root, root_path, &plan.path, staged)?;
                let conflict = Conflict::RemoteDeletionLocalEdit {
                    local: LocalFile::new(staged.content().clone()),
                };
                finish_conflict(journal, plan.id, &plan.path, &conflict)?;
                report.completed_operations += 1;
                Ok(None)
            }
            FileMutation::Create => Err(invalid(
                &plan.path,
                "create precondition changed to an impossible absent state",
            )),
        },
        MutationOutcome::PreconditionChanged(
            RemotePathState::Folder | RemotePathState::Unsupported,
        ) => Ok(Some(ReplayBlocked::RemoteObject {
            path: plan.path.clone(),
        })),
    }
}

#[allow(clippy::too_many_arguments)]
fn apply_delete_mutation(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    plan: &crate::journal::PlanRecord,
    planned: &PlannedOperation,
    outcome: MutationOutcome,
    report: &mut ReplayReport,
) -> Result<Option<ReplayBlocked>, RecoveryError> {
    match outcome {
        MutationOutcome::Applied(RemotePathState::Absent) => {
            complete_final(journal, planned, &plan.path, &Baseline::Absent)?;
            report.completed_operations += 1;
            Ok(None)
        }
        MutationOutcome::Applied(_) => Err(invalid(
            &plan.path,
            "delete mutation returned an impossible applied state",
        )),
        MutationOutcome::Pending => Ok(Some(ReplayBlocked::RemotePending {
            path: plan.path.clone(),
        })),
        MutationOutcome::PreconditionChanged(RemotePathState::File(remote)) => {
            materialize_remote_conflict_at(dropbox, root, root_path, &plan.path, &remote)?;
            let conflict = Conflict::LocalDeletionRemoteEdit { remote };
            finish_conflict(journal, plan.id, &plan.path, &conflict)?;
            report.completed_operations += 1;
            Ok(None)
        }
        MutationOutcome::PreconditionChanged(
            RemotePathState::Folder | RemotePathState::Unsupported,
        ) => Ok(Some(ReplayBlocked::RemoteObject {
            path: plan.path.clone(),
        })),
        MutationOutcome::PreconditionChanged(RemotePathState::Absent) => Err(invalid(
            &plan.path,
            "delete precondition changed to an impossible absent state",
        )),
    }
}

pub(crate) fn materialize_local_conflict(
    sync_root: &Path,
    path: &Path,
    staged: &StagedUpload,
) -> Result<(), RecoveryError> {
    let root = open_root(sync_root, "open sync root for local conflict")?;
    materialize_local_conflict_at(&root, sync_root, path, staged)
}

fn materialize_local_conflict_at(
    root: &OwnedFd,
    root_path: &Path,
    path: &Path,
    staged: &StagedUpload,
) -> Result<(), RecoveryError> {
    let bytes = staged.open_verified()?;
    match materialize_conflict_at(
        root,
        root_path,
        path,
        ConflictSide::Local,
        staged.content(),
        bytes,
    )? {
        ConflictOutcome::Created { .. } | ConflictOutcome::AlreadyPresent { .. } => Ok(()),
        ConflictOutcome::ContentChanged { .. } => Err(invalid(
            path,
            "verified upload changed during conflict copy",
        )),
    }
}

pub(crate) fn materialize_remote_conflict(
    dropbox: &DropboxClient,
    sync_root: &Path,
    path: &Path,
    remote: &RemoteFile,
) -> Result<(), RecoveryError> {
    let root = open_root(sync_root, "open sync root for remote conflict")?;
    materialize_remote_conflict_at(dropbox, &root, sync_root, path, remote)
}

fn materialize_remote_conflict_at(
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    path: &Path,
    remote: &RemoteFile,
) -> Result<(), RecoveryError> {
    let conflict = conflict_relative_path(path, ConflictSide::Remote, &remote.content)?;
    ensure_exact_copy_at(dropbox, root, root_path, &conflict, path, remote)
}

fn ensure_exact_copy(
    dropbox: &DropboxClient,
    root: &Path,
    target: &Path,
    path: &Path,
    remote: &RemoteFile,
) -> Result<(), RecoveryError> {
    let root_fd = open_root(root, "open exact-copy root")?;
    ensure_exact_copy_at(dropbox, &root_fd, root, target, path, remote)
}

fn ensure_exact_copy_at(
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    target: &Path,
    path: &Path,
    remote: &RemoteFile,
) -> Result<(), RecoveryError> {
    match install_download_at(root, root_path, target, &remote.content, None)? {
        InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => return Ok(()),
        InstallOutcome::DownloadRequired => {}
        InstallOutcome::StageDestinationOccupied { .. }
        | InstallOutcome::PreconditionChanged { .. } => {
            return Err(invalid(path, "exact Dropbox destination is occupied"));
        }
    }
    match dropbox
        .stage_exact_download_for_at(root, root_path, target, path, remote)
        .map_err(|source| dropbox_error(path, source))?
    {
        StageOutcome::Staged(()) | StageOutcome::AlreadyStaged(()) => {}
        StageOutcome::ContentChanged { .. } => {
            return Err(invalid(path, "exact Dropbox download changed content"));
        }
        StageOutcome::DestinationOccupied { .. } => {
            return Err(invalid(
                path,
                "exact Dropbox staging destination is occupied",
            ));
        }
    }
    match install_download_at(root, root_path, target, &remote.content, None)? {
        InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => Ok(()),
        InstallOutcome::DownloadRequired => {
            Err(invalid(path, "verified exact Dropbox download disappeared"))
        }
        InstallOutcome::StageDestinationOccupied { .. }
        | InstallOutcome::PreconditionChanged { .. } => {
            Err(invalid(path, "exact Dropbox destination is occupied"))
        }
    }
}

fn finish_conflict(
    journal: &mut Journal,
    plan_id: crate::journal::PlanId,
    path: &Path,
    conflict: &Conflict,
) -> Result<(), RecoveryError> {
    match journal.finish_plan_with_conflict(plan_id, conflict)? {
        PlanConflictCompletion::Recorded | PlanConflictCompletion::AlreadyCompleted => Ok(()),
        PlanConflictCompletion::NotFound => Err(invalid(path, "conflicted plan disappeared")),
    }
}

fn dropbox_error(path: &Path, source: DropboxError) -> RecoveryError {
    RecoveryError::Dropbox {
        path: path.to_path_buf(),
        source,
    }
}

fn invalid(path: &Path, detail: &'static str) -> RecoveryError {
    RecoveryError::InvalidJournalState {
        path: path.to_path_buf(),
        detail,
    }
}

enum RecoveryReady {
    Verified(VerifiedRecovery),
    SourceChanged(ContentIdentity),
}

fn ensure_verified_recovery(
    journal: &mut Journal,
    root: &OwnedFd,
    recovery_directory: &Path,
    planned: &PlannedOperation,
    path: &Path,
) -> Result<RecoveryReady, RecoveryError> {
    let expected = destructive_content(&planned.operation).ok_or_else(|| {
        RecoveryError::InvalidJournalState {
            path: path.to_path_buf(),
            detail: "local recovery requested for a non-destructive operation",
        }
    })?;
    let recovery_path = recovery_directory.join(recovery_file_name(path, expected));
    let record = match journal.record_recovery_intent(planned.id, &recovery_path)? {
        RecoveryWrite::Recorded(record) | RecoveryWrite::AlreadyRecorded(record) => record,
        RecoveryWrite::OperationNotFound => {
            return Err(RecoveryError::InvalidJournalState {
                path: path.to_path_buf(),
                detail: "recovery operation disappeared from the journal",
            });
        }
        RecoveryWrite::OperationCompleted => {
            return Err(RecoveryError::InvalidJournalState {
                path: path.to_path_buf(),
                detail: "completed operation unexpectedly requested recovery",
            });
        }
        RecoveryWrite::OperationNotDestructive => {
            return Err(RecoveryError::InvalidJournalState {
                path: path.to_path_buf(),
                detail: "journal rejected destructive local recovery intent",
            });
        }
    };
    let verified = match materialize_at(root, recovery_directory, &record)? {
        RecoveryMaterialization::Created(verified)
        | RecoveryMaterialization::AlreadyPresent(verified) => verified,
        RecoveryMaterialization::SourceChanged { actual } => {
            return Ok(RecoveryReady::SourceChanged(actual));
        }
    };
    match journal.complete_recovery(record.id)? {
        RecoveryCompletion::Completed | RecoveryCompletion::AlreadyCompleted => {
            Ok(RecoveryReady::Verified(verified))
        }
        RecoveryCompletion::NotFound => Err(RecoveryError::InvalidJournalState {
            path: path.to_path_buf(),
            detail: "materialized recovery disappeared from the journal",
        }),
    }
}

fn destructive_content(operation: &Operation) -> Option<&ContentIdentity> {
    match operation {
        Operation::ReplaceLocal {
            expected_content, ..
        }
        | Operation::DeleteLocal { expected_content } => Some(expected_content),
        Operation::CreateRemote { .. }
        | Operation::InstallLocal { .. }
        | Operation::PreserveLocal { .. }
        | Operation::PreserveRemote { .. }
        | Operation::ReplaceRemote { .. }
        | Operation::DeleteRemote { .. } => None,
    }
}

fn complete_nonfinal(
    journal: &mut Journal,
    planned: &PlannedOperation,
    path: &Path,
) -> Result<(), RecoveryError> {
    match journal.complete_operation(planned.id, None)? {
        OperationCompletion::OperationCompleted | OperationCompletion::AlreadyCompleted => Ok(()),
        OperationCompletion::NotFound
        | OperationCompletion::WaitingForEarlierOperation(_)
        | OperationCompletion::BaselineRequired
        | OperationCompletion::UnexpectedBaseline
        | OperationCompletion::BaselineMismatch
        | OperationCompletion::RecoveryRequired
        | OperationCompletion::WaitingForRecovery(_)
        | OperationCompletion::PlanCompleted => Err(RecoveryError::InvalidJournalState {
            path: path.to_path_buf(),
            detail: "journal rejected an ordered preservation completion",
        }),
    }
}

fn complete_final(
    journal: &mut Journal,
    planned: &PlannedOperation,
    path: &Path,
    baseline: &Baseline,
) -> Result<(), RecoveryError> {
    match journal.complete_operation(planned.id, Some(baseline))? {
        OperationCompletion::PlanCompleted | OperationCompletion::AlreadyCompleted => Ok(()),
        OperationCompletion::NotFound
        | OperationCompletion::WaitingForEarlierOperation(_)
        | OperationCompletion::BaselineRequired
        | OperationCompletion::UnexpectedBaseline
        | OperationCompletion::BaselineMismatch
        | OperationCompletion::RecoveryRequired
        | OperationCompletion::WaitingForRecovery(_)
        | OperationCompletion::OperationCompleted => Err(RecoveryError::InvalidJournalState {
            path: path.to_path_buf(),
            detail: "journal rejected a completed durable effect",
        }),
    }
}

#[cfg(test)]
mod retention_tests {
    use std::error::Error;
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use tempfile::TempDir;

    use super::{COMPLETED_RECOVERY_RETENTION, destination, prune_completed_recoveries_at};
    use crate::journal::{
        Journal, OperationCompletion, PlanRecord, PlanWrite, RecoveryCompletion, RecoveryForget,
        RecoveryRecord, RecoveryWrite,
    };
    use crate::local::dropbox_content_hash;
    use crate::model::{Baseline, ContentIdentity, LocalFile, Operation, OperationPlan};

    #[test]
    fn retention_expires_verified_payload_only_at_boundary() -> Result<(), Box<dyn Error>> {
        let fixture = RetentionFixture::new()?;
        let mut journal = Journal::open(&fixture.journal_path)?;
        let content = dropbox_content_hash(&b"retained bytes"[..])?;
        let (plan, recovery) = record_recovery(
            &mut journal,
            &fixture.recovery_directory,
            Path::new("expired.txt"),
            &content,
        )?;
        fs::write(&recovery.recovery_path, b"retained bytes")?;
        fs::OpenOptions::new()
            .write(true)
            .open(&recovery.recovery_path)?
            .set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH))?;
        complete_recovery_and_plan(&mut journal, &plan, &recovery)?;
        let completed = journal.completed_recoveries()?;
        let [completed] = completed.as_slice() else {
            return Err(test_error("test expected one retained recovery").into());
        };
        if completed.id != recovery.id {
            return Err(test_error("test retained the wrong recovery").into());
        }
        let Some(retained_at) = completed.retained_at else {
            return Err(test_error("test recovery retention did not start").into());
        };
        let Some(retained_since) = UNIX_EPOCH.checked_add(Duration::from_secs(retained_at)) else {
            return Err(test_error("test recovery timestamp overflowed").into());
        };
        let boundary = checked_add(retained_since, COMPLETED_RECOVERY_RETENTION)?;
        let before_boundary = boundary
            .checked_sub(Duration::from_nanos(1))
            .ok_or_else(|| test_error("test timestamp underflowed"))?;

        assert_eq!(
            prune_completed_recoveries_at(
                &mut journal,
                &fixture.recovery_directory,
                before_boundary,
            )?,
            0
        );
        assert!(recovery.recovery_path.is_file());
        assert_eq!(
            prune_completed_recoveries_at(&mut journal, &fixture.recovery_directory, boundary,)?,
            1
        );
        assert!(!recovery.recovery_path.exists());
        assert_eq!(
            journal.forget_completed_recovery(recovery.id)?,
            RecoveryForget::NotFound
        );
        Ok(())
    }

    #[test]
    fn retention_keeps_pending_corrupt_nonregular_and_orphan_entries() -> Result<(), Box<dyn Error>>
    {
        let fixture = RetentionFixture::new()?;
        let mut journal = Journal::open(&fixture.journal_path)?;

        let pending_content = dropbox_content_hash(&b"pending bytes"[..])?;
        let (_, pending) = record_recovery(
            &mut journal,
            &fixture.recovery_directory,
            Path::new("pending.txt"),
            &pending_content,
        )?;
        fs::write(&pending.recovery_path, b"pending bytes")?;

        let blocked_content = dropbox_content_hash(&b"blocked bytes"[..])?;
        let (_, blocked) = record_recovery(
            &mut journal,
            &fixture.recovery_directory,
            Path::new("blocked.txt"),
            &blocked_content,
        )?;
        fs::write(&blocked.recovery_path, b"blocked bytes")?;
        assert_eq!(
            journal.complete_recovery(blocked.id)?,
            RecoveryCompletion::Completed
        );

        let corrupt_content = dropbox_content_hash(&b"expected bytes"[..])?;
        let (corrupt_plan, corrupt) = record_recovery(
            &mut journal,
            &fixture.recovery_directory,
            Path::new("corrupt.txt"),
            &corrupt_content,
        )?;
        fs::write(&corrupt.recovery_path, b"different bytes")?;
        complete_recovery_and_plan(&mut journal, &corrupt_plan, &corrupt)?;

        let nonregular_content = dropbox_content_hash(&b"directory bytes"[..])?;
        let (nonregular_plan, nonregular) = record_recovery(
            &mut journal,
            &fixture.recovery_directory,
            Path::new("nonregular.txt"),
            &nonregular_content,
        )?;
        fs::create_dir(&nonregular.recovery_path)?;
        complete_recovery_and_plan(&mut journal, &nonregular_plan, &nonregular)?;

        let orphan = fixture.recovery_directory.join("unknown-orphan");
        fs::write(&orphan, b"unknown bytes")?;
        let after_retention = checked_add(SystemTime::now(), COMPLETED_RECOVERY_RETENTION)?;

        assert_eq!(
            prune_completed_recoveries_at(
                &mut journal,
                &fixture.recovery_directory,
                after_retention,
            )?,
            0
        );
        assert!(pending.recovery_path.is_file());
        assert!(blocked.recovery_path.is_file());
        assert!(corrupt.recovery_path.is_file());
        assert!(nonregular.recovery_path.is_dir());
        assert!(orphan.is_file());
        assert_eq!(journal.pending_recoveries()?, vec![pending]);
        let eligible = journal.completed_recoveries()?;
        assert_eq!(eligible.len(), 2);
        assert!(eligible.iter().any(|record| record.id == corrupt.id));
        assert!(eligible.iter().any(|record| record.id == nonregular.id));
        Ok(())
    }

    #[test]
    fn retention_finishes_metadata_cleanup_after_payload_deletion() -> Result<(), Box<dyn Error>> {
        let fixture = RetentionFixture::new()?;
        let mut journal = Journal::open(&fixture.journal_path)?;
        let content = dropbox_content_hash(&b"deleted before retry"[..])?;
        let (plan, recovery) = record_recovery(
            &mut journal,
            &fixture.recovery_directory,
            Path::new("interrupted.txt"),
            &content,
        )?;
        fs::write(&recovery.recovery_path, b"deleted before retry")?;
        complete_recovery_and_plan(&mut journal, &plan, &recovery)?;
        fs::remove_file(&recovery.recovery_path)?;

        assert_eq!(
            prune_completed_recoveries_at(
                &mut journal,
                &fixture.recovery_directory,
                SystemTime::now(),
            )?,
            1
        );
        assert_eq!(
            journal.forget_completed_recovery(recovery.id)?,
            RecoveryForget::NotFound
        );
        Ok(())
    }

    struct RetentionFixture {
        _directory: TempDir,
        journal_path: PathBuf,
        recovery_directory: PathBuf,
    }

    impl RetentionFixture {
        fn new() -> Result<Self, Box<dyn Error>> {
            let directory = TempDir::new()?;
            let journal_path = directory.path().join("journal.sqlite3");
            let recovery_directory = directory.path().join("recovery");
            fs::create_dir(&recovery_directory)?;
            Ok(Self {
                _directory: directory,
                journal_path,
                recovery_directory,
            })
        }
    }

    fn record_recovery(
        journal: &mut Journal,
        recovery_directory: &Path,
        original_path: &Path,
        content: &ContentIdentity,
    ) -> Result<(PlanRecord, RecoveryRecord), Box<dyn Error>> {
        let operations = OperationPlan::new(vec![
            Operation::PreserveLocal {
                file: LocalFile::new(content.clone()),
            },
            Operation::DeleteLocal {
                expected_content: content.clone(),
            },
        ]);
        let plan = match journal.record_plan(original_path, &operations)? {
            PlanWrite::Recorded(plan) => plan,
            PlanWrite::AlreadyPending(_) => {
                return Err(test_error("test path unexpectedly had a pending plan").into());
            }
        };
        let [_, destructive] = plan.operations.as_slice() else {
            return Err(test_error("test plan did not contain two operations").into());
        };
        let recovery_path = destination(recovery_directory, original_path, content);
        let recovery = match journal.record_recovery_intent(destructive.id, &recovery_path)? {
            RecoveryWrite::Recorded(recovery) => recovery,
            RecoveryWrite::AlreadyRecorded(_)
            | RecoveryWrite::OperationNotFound
            | RecoveryWrite::OperationCompleted
            | RecoveryWrite::OperationNotDestructive => {
                return Err(test_error("test recovery intent was not recorded").into());
            }
        };
        Ok((plan, recovery))
    }

    fn complete_recovery_and_plan(
        journal: &mut Journal,
        plan: &PlanRecord,
        recovery: &RecoveryRecord,
    ) -> Result<(), Box<dyn Error>> {
        if journal.complete_recovery(recovery.id)? != RecoveryCompletion::Completed {
            return Err(test_error("test recovery was not completed").into());
        }
        let [preservation, destructive] = plan.operations.as_slice() else {
            return Err(test_error("test plan did not contain two operations").into());
        };
        if journal.complete_operation(preservation.id, None)?
            != OperationCompletion::OperationCompleted
        {
            return Err(test_error("test preservation operation was not completed").into());
        }
        if journal.complete_operation(destructive.id, Some(&Baseline::Absent))?
            != OperationCompletion::PlanCompleted
        {
            return Err(test_error("test destructive plan was not completed").into());
        }
        Ok(())
    }

    fn checked_add(time: SystemTime, duration: Duration) -> Result<SystemTime, io::Error> {
        time.checked_add(duration)
            .ok_or_else(|| test_error("test timestamp overflowed"))
    }

    fn test_error(detail: &'static str) -> io::Error {
        io::Error::other(detail)
    }
}
