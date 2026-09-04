//! Legacy recovery retention and direct replay of journaled operations.

use std::io;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rustix::fd::OwnedFd;
use rustix::fs::{AtFlags, FileType, fsync, statat, unlinkat};
use thiserror::Error;

use crate::dropbox::{
    DropboxClient, DropboxError, MutationOutcome, MutationRejection, RemotePathState,
};
use crate::journal::{
    Journal, JournalError, OperationCompletion, OperationId, PlanConflictCompletion, PlanId,
    PlanRecord, PlanSupersede, PlannedOperation, RecordStatus, RecoveryForget, RecoveryRecord,
};
use crate::local::{
    ConflictOutcome, ConflictSide, CreateDirectoryOutcome, DeleteDirectoryOutcome, DeleteOutcome,
    InstallOutcome, LocalError, StageOutcome, StagedUpload, conflict_relative_path,
    create_directory_at, delete_directory_at, delete_local_at, install_download_at,
    materialize_conflict_at, open_private_directory, open_root, recovery_file_name,
    upload_source_changed, verify_private_copy,
};
use crate::model::{Baseline, Conflict, ContentIdentity, LocalFile, Operation, RemoteFile};

/// Legacy recovery payloads remain available for this long before cleanup.
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

/// Result of installing an exact remote file at a caller-selected visible path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum ExactCopyOutcome {
    /// The exact bytes are durably present at the selected path.
    Ready,
    /// The selected visible path changed after observation.
    DestinationChanged,
    /// Unrelated bytes occupy the selected path's deterministic download stage.
    StageOccupied,
}

/// Why a replayable operation remains pending.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReplayBlocked {
    /// A classified durable failure holds one plan until its retry deadline.
    DurablePlan {
        /// Synchronized path preserved without mutation.
        path: PathBuf,
        /// Stable, safe reason recorded in the journal.
        reason: crate::journal::BlockReason,
    },
    /// A symlink, special object, or non-directory ancestor blocks a local effect.
    LocalObject {
        /// Synchronized path preserved without mutation.
        path: PathBuf,
    },
    /// A raced directory effect was retired so a complete scan can replan it.
    FreshObservationRequired {
        /// Synchronized path that must be observed again.
        path: PathBuf,
    },
    /// The exact remote payload must be downloaded before installation.
    DownloadRequired {
        /// Synchronized path awaiting bytes.
        path: PathBuf,
        /// Required Dropbox content identity.
        content: ContentIdentity,
    },
    /// Unrelated bytes occupy the deterministic download-stage path.
    StageDestinationOccupied {
        /// Durable plan that owns the staging operation.
        plan_id: PlanId,
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
    /// Dropbox permanently rejected this one path without affecting unrelated work.
    SyncError {
        /// Synchronized path that Dropbox rejected.
        path: PathBuf,
        /// Stable rejection category.
        rejection: MutationRejection,
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
fn destination(
    recovery_directory: impl AsRef<Path>,
    original_path: impl AsRef<Path>,
    content: &ContentIdentity,
) -> PathBuf {
    recovery_directory
        .as_ref()
        .join(recovery_file_name(original_path.as_ref(), content))
}

/// Remove expired legacy recovery payloads that no unfinished journal work can need.
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

/// Replay every currently pending local journal phase once.
///
/// This is deliberately a finite match over the existing typed operation
/// records. Remote operations and missing downloads remain pending for the
/// sequential reconciler; no worker or executor abstraction is involved.
pub fn replay_local_operations(
    journal: &mut Journal,
    sync_root: impl AsRef<Path>,
) -> Result<ReplayReport, RecoveryError> {
    let sync_root = sync_root.as_ref();
    let root = open_root(sync_root, "open sync root for local replay")?;
    replay_local_operations_at(journal, &root, sync_root)
}

pub(crate) fn replay_local_operations_at(
    journal: &mut Journal,
    root: &OwnedFd,
    root_path: &Path,
) -> Result<ReplayReport, RecoveryError> {
    let plans = journal.pending_plans()?;
    replay_local_plans_at(journal, root, root_path, plans.iter())
}

pub(crate) fn replay_local_plans_at<'a>(
    journal: &mut Journal,
    root: &OwnedFd,
    root_path: &Path,
    plans: impl IntoIterator<Item = &'a PlanRecord>,
) -> Result<ReplayReport, RecoveryError> {
    let mut report = ReplayReport::default();
    let mut final_completions = Vec::new();

    for plan in plans {
        for planned in &plan.operations {
            if planned.status == RecordStatus::Completed {
                continue;
            }
            let blocked = match &planned.operation {
                Operation::CreateLocalDirectory => match create_directory_at(root, &plan.path) {
                    Err(source) if local_object_blocks_replay(&source) => {
                        Some(ReplayBlocked::LocalObject {
                            path: plan.path.clone(),
                        })
                    }
                    Err(source) => return Err(source.into()),
                    Ok(outcome) => match outcome {
                        CreateDirectoryOutcome::Created
                        | CreateDirectoryOutcome::AlreadyPresent => {
                            final_completions.push(FinalCompletion::new(
                                planned,
                                &plan.path,
                                Baseline::Directory,
                            ));
                            None
                        }
                        CreateDirectoryOutcome::FreshObservation => {
                            supersede_plan(journal, plan)?;
                            Some(ReplayBlocked::FreshObservationRequired {
                                path: plan.path.clone(),
                            })
                        }
                    },
                },
                Operation::DeleteLocalDirectory => match delete_directory_at(root, &plan.path) {
                    Err(source) if local_object_blocks_replay(&source) => {
                        Some(ReplayBlocked::LocalObject {
                            path: plan.path.clone(),
                        })
                    }
                    Err(source) => return Err(source.into()),
                    Ok(outcome) => match outcome {
                        DeleteDirectoryOutcome::Deleted | DeleteDirectoryOutcome::AlreadyAbsent => {
                            final_completions.push(FinalCompletion::new(
                                planned,
                                &plan.path,
                                Baseline::Absent,
                            ));
                            None
                        }
                        DeleteDirectoryOutcome::FreshObservation => {
                            supersede_plan(journal, plan)?;
                            Some(ReplayBlocked::FreshObservationRequired {
                                path: plan.path.clone(),
                            })
                        }
                    },
                },
                Operation::PreserveLocal { .. } => {
                    complete_nonfinal(journal, planned, &plan.path)?;
                    report.completed_operations += 1;
                    None
                }
                Operation::InstallLocal { source } => {
                    match install_download_at(root, root_path, &plan.path, &source.content, None) {
                        Err(source) if local_object_blocks_replay(&source) => {
                            Some(ReplayBlocked::LocalObject {
                                path: plan.path.clone(),
                            })
                        }
                        Err(source) => return Err(source.into()),
                        Ok(outcome) => match outcome {
                            InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => {
                                final_completions.push(FinalCompletion::new(
                                    planned,
                                    &plan.path,
                                    Baseline::Present(source.clone()),
                                ));
                                None
                            }
                            InstallOutcome::DownloadRequired => {
                                Some(ReplayBlocked::DownloadRequired {
                                    path: plan.path.clone(),
                                    content: source.content.clone(),
                                })
                            }
                            InstallOutcome::StageDestinationOccupied { path } => {
                                Some(ReplayBlocked::StageDestinationOccupied {
                                    plan_id: plan.id,
                                    path,
                                })
                            }
                            InstallOutcome::PreconditionChanged { actual } => {
                                Some(ReplayBlocked::PreconditionChanged {
                                    path: plan.path.clone(),
                                    actual,
                                })
                            }
                        },
                    }
                }
                Operation::ReplaceLocal {
                    source,
                    expected_content,
                } => {
                    match install_download_at(
                        root,
                        root_path,
                        &plan.path,
                        &source.content,
                        Some(expected_content),
                    ) {
                        Err(source) if local_object_blocks_replay(&source) => {
                            Some(ReplayBlocked::LocalObject {
                                path: plan.path.clone(),
                            })
                        }
                        Err(source) => return Err(source.into()),
                        Ok(outcome) => match outcome {
                            InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => {
                                final_completions.push(FinalCompletion::new(
                                    planned,
                                    &plan.path,
                                    Baseline::Present(source.clone()),
                                ));
                                None
                            }
                            InstallOutcome::DownloadRequired => {
                                Some(ReplayBlocked::DownloadRequired {
                                    path: plan.path.clone(),
                                    content: source.content.clone(),
                                })
                            }
                            InstallOutcome::StageDestinationOccupied { path } => {
                                Some(ReplayBlocked::StageDestinationOccupied {
                                    plan_id: plan.id,
                                    path,
                                })
                            }
                            InstallOutcome::PreconditionChanged { actual } => {
                                Some(ReplayBlocked::PreconditionChanged {
                                    path: plan.path.clone(),
                                    actual,
                                })
                            }
                        },
                    }
                }
                Operation::DeleteLocal { expected_content } => {
                    match delete_local_at(root, root_path, &plan.path, expected_content) {
                        Err(source) if local_object_blocks_replay(&source) => {
                            Some(ReplayBlocked::LocalObject {
                                path: plan.path.clone(),
                            })
                        }
                        Err(source) => return Err(source.into()),
                        Ok(outcome) => match outcome {
                            DeleteOutcome::Deleted | DeleteOutcome::AlreadyDeleted => {
                                final_completions.push(FinalCompletion::new(
                                    planned,
                                    &plan.path,
                                    Baseline::Absent,
                                ));
                                None
                            }
                            DeleteOutcome::PreconditionChanged { actual } => {
                                Some(ReplayBlocked::PreconditionChanged {
                                    path: plan.path.clone(),
                                    actual,
                                })
                            }
                        },
                    }
                }
                Operation::CreateRemoteDirectory
                | Operation::CreateRemote { .. }
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
    commit_final_completions(journal, &final_completions)?;
    report.completed_operations += final_completions.len();
    Ok(report)
}

fn local_object_blocks_replay(error: &LocalError) -> bool {
    match error {
        LocalError::UnsupportedObject { .. } => true,
        LocalError::Io { source, .. } => {
            let raw = source.raw_os_error();
            raw == Some(rustix::io::Errno::LOOP.raw_os_error())
                || raw == Some(rustix::io::Errno::NOTDIR.raw_os_error())
        }
        _ => false,
    }
}

/// Replay every currently pending remote journal phase once.
pub fn replay_remote_operations(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: impl AsRef<Path>,
    upload_staging: impl AsRef<Path>,
) -> Result<ReplayReport, RecoveryError> {
    let sync_root = sync_root.as_ref();
    let root = open_root(sync_root, "open sync root for remote replay")?;
    replay_remote_operations_at(journal, dropbox, &root, sync_root, upload_staging.as_ref())
}

pub(crate) fn replay_remote_operations_at(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    upload_staging: &Path,
) -> Result<ReplayReport, RecoveryError> {
    let plans = journal.pending_plans()?;
    let mut report = ReplayReport::default();

    for plan in plans {
        for planned in &plan.operations {
            if planned.status == RecordStatus::Completed {
                continue;
            }
            let blocked = match &planned.operation {
                Operation::CreateRemoteDirectory => {
                    if let Some(blocked) = ensure_remote_parents(dropbox, &plan.path)? {
                        Some(blocked)
                    } else {
                        let outcome = dropbox
                            .create_folder(&plan.path)
                            .map_err(|source| dropbox_error(&plan.path, source))?;
                        apply_folder_mutation(journal, &plan, planned, outcome, &mut report)?
                    }
                }
                Operation::PreserveRemote { .. } => {
                    complete_nonfinal(journal, planned, &plan.path)?;
                    report.completed_operations += 1;
                    None
                }
                Operation::CreateRemote { content } => {
                    let Some(staged) =
                        prepare_upload(journal, &plan, root, upload_staging, content, &mut report)?
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
                        prepare_upload(journal, &plan, root, upload_staging, content, &mut report)?
                    else {
                        break;
                    };
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
                Operation::CreateLocalDirectory
                | Operation::DeleteLocalDirectory
                | Operation::InstallLocal { .. }
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
            MutationOutcome::Rejected(rejection) => {
                return Ok(Some(sync_error(path, rejection)));
            }
        }
    }
    Ok(None)
}

fn apply_folder_mutation(
    journal: &mut Journal,
    plan: &PlanRecord,
    planned: &PlannedOperation,
    outcome: MutationOutcome,
    report: &mut ReplayReport,
) -> Result<Option<ReplayBlocked>, RecoveryError> {
    match outcome {
        MutationOutcome::Applied(RemotePathState::Folder) => {
            complete_final(journal, planned, &plan.path, &Baseline::Directory)?;
            report.completed_operations += 1;
            Ok(None)
        }
        MutationOutcome::Pending => Ok(Some(ReplayBlocked::RemotePending {
            path: plan.path.clone(),
        })),
        MutationOutcome::PreconditionChanged(_)
        | MutationOutcome::Applied(
            RemotePathState::Absent | RemotePathState::File(_) | RemotePathState::Unsupported,
        ) => {
            supersede_plan(journal, plan)?;
            Ok(Some(ReplayBlocked::FreshObservationRequired {
                path: plan.path.clone(),
            }))
        }
        MutationOutcome::Rejected(rejection) => Ok(Some(sync_error(&plan.path, rejection))),
    }
}

#[derive(Clone, Copy)]
enum FileMutation {
    Create,
    Replace,
}

fn prepare_upload(
    journal: &mut Journal,
    plan: &PlanRecord,
    root: &OwnedFd,
    upload_staging: &Path,
    content: &ContentIdentity,
    report: &mut ReplayReport,
) -> Result<Option<StagedUpload>, RecoveryError> {
    let staged = match crate::local::stage_upload_at(root, &plan.path, upload_staging, content) {
        Ok(staged) => staged,
        Err(source) if upload_source_changed(&source, &plan.path) => {
            supersede_plan(journal, plan)?;
            report
                .blocked
                .push(ReplayBlocked::FreshObservationRequired {
                    path: plan.path.clone(),
                });
            return Ok(None);
        }
        Err(source) => return Err(source.into()),
    };
    match staged {
        StageOutcome::Staged(stage) | StageOutcome::AlreadyStaged(stage) => Ok(Some(stage)),
        StageOutcome::ContentChanged { .. } => {
            supersede_plan(journal, plan)?;
            report
                .blocked
                .push(ReplayBlocked::FreshObservationRequired {
                    path: plan.path.clone(),
                });
            Ok(None)
        }
        StageOutcome::DestinationOccupied { path } => {
            report
                .blocked
                .push(ReplayBlocked::StageDestinationOccupied {
                    plan_id: plan.id,
                    path,
                });
            Ok(None)
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
        MutationOutcome::Rejected(rejection) => Ok(Some(sync_error(&plan.path, rejection))),
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
    let keeps_directory = plan
        .operations
        .iter()
        .any(|operation| operation.operation == Operation::CreateRemoteDirectory);
    match outcome {
        MutationOutcome::Applied(RemotePathState::Absent) => {
            if plan
                .operations
                .last()
                .is_some_and(|last| last.id == planned.id)
            {
                complete_final(journal, planned, &plan.path, &Baseline::Absent)?;
            } else {
                complete_nonfinal(journal, planned, &plan.path)?;
            }
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
            if keeps_directory {
                supersede_plan(journal, plan)?;
                return Ok(Some(ReplayBlocked::FreshObservationRequired {
                    path: plan.path.clone(),
                }));
            }
            materialize_remote_conflict_at(dropbox, root, root_path, &plan.path, &remote)?;
            let conflict = Conflict::LocalDeletionRemoteEdit { remote };
            finish_conflict(journal, plan.id, &plan.path, &conflict)?;
            report.completed_operations += 1;
            Ok(None)
        }
        MutationOutcome::PreconditionChanged(
            RemotePathState::Folder | RemotePathState::Unsupported,
        ) if keeps_directory => {
            supersede_plan(journal, plan)?;
            Ok(Some(ReplayBlocked::FreshObservationRequired {
                path: plan.path.clone(),
            }))
        }
        MutationOutcome::PreconditionChanged(
            RemotePathState::Folder | RemotePathState::Unsupported,
        ) => Ok(Some(ReplayBlocked::RemoteObject {
            path: plan.path.clone(),
        })),
        MutationOutcome::PreconditionChanged(RemotePathState::Absent) if keeps_directory => {
            complete_nonfinal(journal, planned, &plan.path)?;
            report.completed_operations += 1;
            Ok(None)
        }
        MutationOutcome::PreconditionChanged(RemotePathState::Absent) => Err(invalid(
            &plan.path,
            "delete precondition changed to an impossible absent state",
        )),
        MutationOutcome::Rejected(rejection) => Ok(Some(sync_error(&plan.path, rejection))),
    }
}

fn sync_error(path: &Path, rejection: MutationRejection) -> ReplayBlocked {
    tracing::error!(path = %path.display(), reason = %rejection, "Dropbox rejected sync path");
    ReplayBlocked::SyncError {
        path: path.to_path_buf(),
        rejection,
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

/// Install one exact Dropbox file through an already-verified sync-root descriptor.
pub(crate) fn materialize_remote_copy_at(
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    target: &Path,
    source_path: &Path,
    remote: &RemoteFile,
) -> Result<ExactCopyOutcome, RecoveryError> {
    ensure_exact_copy_at(dropbox, root, root_path, target, source_path, remote)
}

fn materialize_remote_conflict_at(
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    path: &Path,
    remote: &RemoteFile,
) -> Result<(), RecoveryError> {
    let conflict = conflict_relative_path(path, ConflictSide::Remote, &remote.content)?;
    require_exact_copy(
        ensure_exact_copy_at(dropbox, root, root_path, &conflict, path, remote)?,
        path,
    )
}

fn ensure_exact_copy_at(
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    target: &Path,
    path: &Path,
    remote: &RemoteFile,
) -> Result<ExactCopyOutcome, RecoveryError> {
    match install_download_at(root, root_path, target, &remote.content, None)? {
        InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => {
            return Ok(ExactCopyOutcome::Ready);
        }
        InstallOutcome::DownloadRequired => {}
        InstallOutcome::StageDestinationOccupied { .. } => {
            return Ok(ExactCopyOutcome::StageOccupied);
        }
        InstallOutcome::PreconditionChanged { .. } => {
            return Ok(ExactCopyOutcome::DestinationChanged);
        }
    }
    match dropbox
        .stage_exact_download_for_at(root, root_path, target, path, remote, None)
        .map_err(|source| dropbox_error(path, source))?
    {
        StageOutcome::Staged(()) | StageOutcome::AlreadyStaged(()) => {}
        StageOutcome::ContentChanged { .. } => {
            return Err(invalid(path, "exact Dropbox download changed content"));
        }
        StageOutcome::DestinationOccupied { .. } => {
            return Ok(ExactCopyOutcome::StageOccupied);
        }
    }
    match install_download_at(root, root_path, target, &remote.content, None)? {
        InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => Ok(ExactCopyOutcome::Ready),
        InstallOutcome::DownloadRequired => {
            Err(invalid(path, "verified exact Dropbox download disappeared"))
        }
        InstallOutcome::StageDestinationOccupied { .. } => Ok(ExactCopyOutcome::StageOccupied),
        InstallOutcome::PreconditionChanged { .. } => Ok(ExactCopyOutcome::DestinationChanged),
    }
}

fn require_exact_copy(outcome: ExactCopyOutcome, path: &Path) -> Result<(), RecoveryError> {
    match outcome {
        ExactCopyOutcome::Ready => Ok(()),
        ExactCopyOutcome::DestinationChanged => {
            Err(invalid(path, "exact Dropbox destination is occupied"))
        }
        ExactCopyOutcome::StageOccupied => Err(invalid(
            path,
            "exact Dropbox staging destination is occupied",
        )),
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

fn supersede_plan(journal: &mut Journal, plan: &PlanRecord) -> Result<(), RecoveryError> {
    match journal.supersede_plan(plan.id)? {
        PlanSupersede::Superseded | PlanSupersede::AlreadyCompleted => Ok(()),
        PlanSupersede::NotFound => Err(invalid(&plan.path, "stale plan disappeared")),
    }
}

struct FinalCompletion {
    operation_id: OperationId,
    path: PathBuf,
    baseline: Baseline,
}

impl FinalCompletion {
    fn new(planned: &PlannedOperation, path: &Path, baseline: Baseline) -> Self {
        Self {
            operation_id: planned.id,
            path: path.to_path_buf(),
            baseline,
        }
    }
}

fn commit_final_completions(
    journal: &mut Journal,
    completions: &[FinalCompletion],
) -> Result<(), RecoveryError> {
    let requests = completions
        .iter()
        .map(|completion| (completion.operation_id, completion.baseline.clone()))
        .collect::<Vec<_>>();
    let outcomes = journal.complete_final_operations(&requests)?;
    for (completion, outcome) in completions.iter().zip(outcomes) {
        match outcome {
            OperationCompletion::PlanCompleted | OperationCompletion::AlreadyCompleted => {}
            OperationCompletion::NotFound
            | OperationCompletion::WaitingForEarlierOperation(_)
            | OperationCompletion::BaselineRequired
            | OperationCompletion::UnexpectedBaseline
            | OperationCompletion::BaselineMismatch
            | OperationCompletion::OperationCompleted => {
                return Err(RecoveryError::InvalidJournalState {
                    path: completion.path.clone(),
                    detail: "journal rejected a completed durable effect",
                });
            }
        }
    }
    Ok(())
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
        | OperationCompletion::OperationCompleted => Err(RecoveryError::InvalidJournalState {
            path: path.to_path_buf(),
            detail: "journal rejected a completed durable effect",
        }),
    }
}

#[cfg(test)]
mod compatibility_tests {
    use std::error::Error;
    use std::io::Cursor;
    use std::path::Path;

    use tempfile::TempDir;

    use super::replay_local_operations;
    use crate::journal::{Journal, PlanWrite};
    use crate::local::dropbox_content_hash;
    use crate::model::{LocalFile, Operation, OperationPlan};

    #[test]
    fn legacy_local_preservation_replays_without_creating_a_copy() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let root = directory.path().join("root");
        let recovery = directory.path().join("recovery");
        std::fs::create_dir_all(&root)?;
        std::fs::create_dir_all(&recovery)?;
        std::fs::write(root.join("legacy.txt"), b"old")?;
        let old = dropbox_content_hash(Cursor::new(b"old"))?;
        let legacy = OperationPlan::new(vec![
            Operation::PreserveLocal {
                file: LocalFile::new(old.clone()),
            },
            Operation::DeleteLocal {
                expected_content: old,
            },
        ]);
        let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
        match journal.record_plan(Path::new("legacy.txt"), &legacy)? {
            PlanWrite::Recorded(_) => {}
            PlanWrite::AlreadyLive(_) => {
                return Err(std::io::Error::other("fresh test journal had pending work").into());
            }
        }

        let report = replay_local_operations(&mut journal, &root)?;
        assert_eq!(report.completed_operations, 2);
        assert!(report.blocked.is_empty());
        assert!(!root.join("legacy.txt").exists());
        assert!(recovery.read_dir()?.next().is_none());
        assert!(journal.pending_recoveries()?.is_empty());
        assert!(journal.pending_plans()?.is_empty());
        Ok(())
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
            PlanWrite::AlreadyLive(_) => {
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
