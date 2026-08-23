//! Verified recovery copies and direct replay of journaled local operations.

use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::journal::{
    Journal, JournalError, OperationCompletion, PlannedOperation, RecordStatus, RecoveryCompletion,
    RecoveryRecord, RecoveryWrite,
};
use crate::local::{
    DeleteOutcome, InstallOutcome, LocalError, StageOutcome, VerifiedRecovery, delete_local,
    install_download, materialize_verified_copy, open_private_directory, open_root, open_root_file,
    recovery_file_name, verify_private_copy,
};
use crate::model::{Baseline, ContentIdentity, Operation};

/// A recovery or local-replay failure.
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
    /// A journal record did not satisfy the local recovery contract.
    #[error("journaled local recovery state is invalid for `{path}`: {detail}")]
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
