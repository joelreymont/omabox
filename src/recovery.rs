//! Verified recovery copies and direct replay of journaled local operations.

use std::path::{Component, Path, PathBuf};

use thiserror::Error;

use crate::dropbox::{DropboxClient, DropboxError, MutationOutcome, RemotePathState};
use crate::journal::{
    Journal, JournalError, OperationCompletion, PlanConflictCompletion, PlannedOperation,
    RecordStatus, RecoveryCompletion, RecoveryRecord, RecoveryWrite,
};
use crate::local::{
    ConflictOutcome, ConflictSide, DeleteOutcome, InstallOutcome, LocalError, StageOutcome,
    StagedUpload, VerifiedRecovery, conflict_relative_path, delete_local, install_download,
    materialize_conflict, materialize_verified_copy, open_private_directory, open_root,
    open_root_file, recovery_file_name, stage_upload, verify_private_copy,
};
use crate::model::{Baseline, Conflict, ContentIdentity, LocalFile, Operation, RemoteFile};

/// A recovery or replay failure.
#[derive(Debug, Error)]
pub enum RecoveryError {
    /// A root-confined filesystem phase failed.
    #[error("local recovery filesystem phase failed")]
    Local {
        /// Original local filesystem error.
        #[source]
        source: LocalError,
    },
    /// A durable journal phase failed.
    #[error("local recovery journal phase failed")]
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

/// Why a replayable local operation remains pending.
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
    let recovery_directory = recovery_directory.as_ref();
    let name = recovery_file_name(&record.original_path, &record.content);
    let expected_path = destination(recovery_directory, &record.original_path, &record.content);
    if record.recovery_path != expected_path {
        return Err(RecoveryError::InvalidJournalState {
            path: record.original_path.clone(),
            detail: "recovery destination is not the deterministic configured path",
        });
    }

    let directory =
        open_private_directory(recovery_directory, "open configured recovery directory")?;
    if verify_private_copy(&directory, recovery_directory, &name, &record.content)? {
        return Ok(RecoveryMaterialization::AlreadyPresent(
            VerifiedRecovery::new(record.original_path.clone(), record.content.clone()),
        ));
    }
    let root = open_root(sync_root, "open sync root for recovery")?;
    let mut source = open_root_file(
        &root,
        &record.original_path,
        "open displaced local payload for recovery",
    )?;
    let outcome = materialize_verified_copy(
        &directory,
        recovery_directory,
        &name,
        &record.content,
        &mut source,
    )?;
    let verified = || VerifiedRecovery::new(record.original_path.clone(), record.content.clone());
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
    let recovery_directory = recovery_directory.as_ref();
    let plans = journal.pending_plans()?;
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
                        sync_root,
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
                    match install_download(sync_root, &plan.path, &source.content, None)? {
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
                        sync_root,
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
                    match install_download(sync_root, &plan.path, &source.content, Some(&recovery))?
                    {
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
                        sync_root,
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
                    match delete_local(sync_root, &plan.path, &recovery)? {
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
    let upload_staging = upload_staging.as_ref();
    let recovery_directory = recovery_directory.as_ref();
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
                    let Some(staged) = prepare_upload(
                        sync_root,
                        upload_staging,
                        &plan.path,
                        content,
                        &mut report,
                    )?
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
                            sync_root,
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
                    let Some(staged) = prepare_upload(
                        sync_root,
                        upload_staging,
                        &plan.path,
                        content,
                        &mut report,
                    )?
                    else {
                        break;
                    };
                    let outcome = dropbox
                        .replace_file(&plan.path, expected_revision, &staged)
                        .map_err(|source| dropbox_error(&plan.path, source))?;
                    apply_file_mutation(
                        journal,
                        dropbox,
                        sync_root,
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
                        sync_root,
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
    sync_root: &Path,
    upload_staging: &Path,
    path: &Path,
    content: &ContentIdentity,
    report: &mut ReplayReport,
) -> Result<Option<StagedUpload>, RecoveryError> {
    match stage_upload(sync_root, path, upload_staging, content)? {
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
    sync_root: &Path,
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
            materialize_local_conflict(sync_root, &plan.path, staged)?;
            materialize_remote_conflict(dropbox, sync_root, &plan.path, &remote)?;
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
                materialize_local_conflict(sync_root, &plan.path, staged)?;
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

fn apply_delete_mutation(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: &Path,
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
            materialize_remote_conflict(dropbox, sync_root, &plan.path, &remote)?;
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
    let bytes = staged.open_verified()?;
    match materialize_conflict(
        sync_root,
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
    let conflict = conflict_relative_path(path, ConflictSide::Remote, &remote.content)?;
    ensure_exact_copy(dropbox, sync_root, &conflict, path, remote)
}

fn ensure_exact_copy(
    dropbox: &DropboxClient,
    root: &Path,
    target: &Path,
    path: &Path,
    remote: &RemoteFile,
) -> Result<(), RecoveryError> {
    match install_download(root, target, &remote.content, None)? {
        InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => return Ok(()),
        InstallOutcome::DownloadRequired => {}
        InstallOutcome::StageDestinationOccupied { .. }
        | InstallOutcome::PreconditionChanged { .. } => {
            return Err(invalid(path, "exact Dropbox destination is occupied"));
        }
    }
    match dropbox
        .stage_exact_download(root, target, remote)
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
    match install_download(root, target, &remote.content, None)? {
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
    sync_root: &Path,
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
    let verified = match materialize(sync_root, recovery_directory, &record)? {
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
            detail: "journal rejected an ordered local preservation completion",
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
            detail: "journal rejected a completed durable local effect",
        }),
    }
}
