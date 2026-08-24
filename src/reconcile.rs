//! One finite observe, plan, and journal pass.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::dropbox::{DropboxClient, DropboxError};
use crate::journal::{
    Journal, JournalError, LocalObservationRecord, NoOpWrite, PlanConflictCompletion, PlanRecord,
    PlanWrite, RemoteObservationRecord,
};
use crate::local::{
    LocalError, ScanPublication, StageOutcome, StagedUpload, configured_root_is_active,
    observe_upload_source, remove_unreferenced_upload_stages, scan_and_publish, stage_upload,
};
use crate::model::{
    Baseline, Conflict, Decision, LocalObservation, Observation, Operation, RemoteObservation,
};
use crate::planner::plan;
use crate::recovery::{
    RecoveryError, RecoveryMaterialization, ReplayBlocked, ReplayReport, destination,
    materialize_before_plan, materialize_local_conflict, materialize_remote_conflict,
    prune_completed_recoveries, replay_local_operations, replay_remote_operations,
};

/// A reconciliation failure. Expected observation races are returned as outcomes instead.
#[derive(Debug, Error)]
pub enum ReconcileError {
    /// A local filesystem phase failed.
    #[error("reconciliation local filesystem phase failed")]
    Local {
        /// Original local error.
        #[source]
        source: LocalError,
    },
    /// A Dropbox phase failed.
    #[error("reconciliation Dropbox phase failed")]
    Dropbox {
        /// Original Dropbox error.
        #[source]
        source: DropboxError,
    },
    /// A journal phase failed.
    #[error("reconciliation journal phase failed")]
    Journal {
        /// Original journal error.
        #[source]
        source: JournalError,
    },
    /// Replaying durable work failed.
    #[error("reconciliation replay phase failed")]
    Recovery {
        /// Original replay error.
        #[source]
        source: RecoveryError,
    },
    /// Staged Dropbox bytes did not match their durable inventory identity.
    #[error("Dropbox returned different bytes while staging `{path}`")]
    RemoteContentChanged {
        /// Synchronized path whose exact revision was requested.
        path: PathBuf,
    },
    /// An unrelated file occupies an internal staging destination.
    #[error("reconciliation staging destination is occupied at `{path}`")]
    StageDestinationOccupied {
        /// Occupied path, without its contents.
        path: PathBuf,
    },
    /// Durable records violated the finite reconciliation contract.
    #[error("reconciliation found invalid journal state for `{path}`: {detail}")]
    InvalidJournalState {
        /// Synchronized path affected by the invalid record.
        path: PathBuf,
        /// Stable, non-secret explanation.
        detail: &'static str,
    },
    /// The configured path no longer names the journal's active local root.
    #[error("configured local root changed during reconciliation")]
    LocalRootChanged,
}

impl From<LocalError> for ReconcileError {
    fn from(source: LocalError) -> Self {
        Self::Local { source }
    }
}

impl From<DropboxError> for ReconcileError {
    fn from(source: DropboxError) -> Self {
        Self::Dropbox { source }
    }
}

impl From<JournalError> for ReconcileError {
    fn from(source: JournalError) -> Self {
        Self::Journal { source }
    }
}

impl From<RecoveryError> for ReconcileError {
    fn from(source: RecoveryError) -> Self {
        Self::Recovery { source }
    }
}

/// Work durably accepted by one reconciliation pass.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ReconcileReport {
    /// Operations completed during the startup and post-plan replay passes.
    pub replayed_operations: usize,
    /// Paths whose observations already agreed.
    pub noops: usize,
    /// New durable operation plans.
    pub planned: usize,
    /// Paths currently blocked by supported observation semantics.
    pub blocked: usize,
    /// Conflicts durably materialized and recorded.
    pub conflicts: usize,
}

/// Expected result of one finite reconciliation pass.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReconcileOutcome {
    /// The pass completed from two complete snapshots.
    Complete(ReconcileReport),
    /// A local file changed after observation; a fresh pass is required.
    FreshObservationRequired {
        /// Path whose observation became stale.
        path: PathBuf,
    },
    /// The daemon must reactivate the configured local root before another pass.
    LocalRootChanged,
}

/// Replay local work, fetch only missing exact downloads, then replay remote work once.
pub fn replay_pending(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: impl AsRef<Path>,
    upload_staging: impl AsRef<Path>,
    recovery_directory: impl AsRef<Path>,
) -> Result<ReplayReport, ReconcileError> {
    let sync_root = sync_root.as_ref();
    let upload_staging = upload_staging.as_ref();
    let recovery_directory = recovery_directory.as_ref();
    require_active_local_root(journal, sync_root)?;
    let mut report = replay_local_operations(journal, sync_root, recovery_directory)?;
    let missing_downloads = report
        .blocked
        .iter()
        .filter_map(|blocked| match blocked {
            ReplayBlocked::DownloadRequired { path, .. } => Some(path.clone()),
            _ => None,
        })
        .collect::<BTreeSet<_>>();
    if !missing_downloads.is_empty() {
        let pending = journal.pending_plans()?;
        for path in &missing_downloads {
            let source = pending
                .iter()
                .find(|plan| plan.path == *path)
                .and_then(|plan| {
                    plan.operations.iter().find_map(|planned| {
                        if planned.status == crate::journal::RecordStatus::Completed {
                            return None;
                        }
                        match &planned.operation {
                            Operation::InstallLocal { source }
                            | Operation::ReplaceLocal { source, .. } => Some(source),
                            _ => None,
                        }
                    })
                })
                .ok_or_else(|| {
                    invalid(
                        path,
                        "pending download blocker has no matching local operation",
                    )
                })?;
            stage_remote(dropbox, sync_root, path, path, source)?;
        }
        require_active_local_root(journal, sync_root)?;
        let resumed = replay_local_operations(journal, sync_root, recovery_directory)?;
        report.completed_operations += resumed.completed_operations;
        report.blocked = resumed.blocked;
    }
    require_active_local_root(journal, sync_root)?;
    let remote = replay_remote_operations(
        journal,
        dropbox,
        sync_root,
        upload_staging,
        recovery_directory,
    )?;
    report.completed_operations += remote.completed_operations;
    report.blocked.extend(remote.blocked);
    Ok(report)
}

/// Run startup replay, publish two complete inventories, and plan every known path once.
pub fn reconcile_once(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: impl AsRef<Path>,
    upload_staging: impl AsRef<Path>,
    recovery_directory: impl AsRef<Path>,
) -> Result<ReconcileOutcome, ReconcileError> {
    match reconcile_active_root(
        journal,
        dropbox,
        sync_root,
        upload_staging,
        recovery_directory,
    ) {
        Err(ReconcileError::LocalRootChanged) => Ok(ReconcileOutcome::LocalRootChanged),
        outcome => outcome,
    }
}

fn reconcile_active_root(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: impl AsRef<Path>,
    upload_staging: impl AsRef<Path>,
    recovery_directory: impl AsRef<Path>,
) -> Result<ReconcileOutcome, ReconcileError> {
    let sync_root = sync_root.as_ref();
    let upload_staging = upload_staging.as_ref();
    let recovery_directory = recovery_directory.as_ref();
    let replay = replay_pending(
        journal,
        dropbox,
        sync_root,
        upload_staging,
        recovery_directory,
    )?;
    if scan_and_publish(journal, sync_root)? == ScanPublication::RootChanged {
        return Err(ReconcileError::LocalRootChanged);
    }
    dropbox.refresh_inventory(journal)?;
    require_active_local_root(journal, sync_root)?;
    reconcile_published(
        journal,
        dropbox,
        sync_root,
        upload_staging,
        recovery_directory,
        replay,
    )
}

fn reconcile_published(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: &Path,
    upload_staging: &Path,
    recovery_directory: &Path,
    replay: ReplayReport,
) -> Result<ReconcileOutcome, ReconcileError> {
    let local = local_map(journal.local_inventory()?);
    let remote = remote_map(journal.remote_inventory()?.observations);
    let pending = journal
        .pending_plans()?
        .into_iter()
        .map(|plan| (plan.path.clone(), plan))
        .collect::<BTreeMap<_, _>>();
    let mut paths = journal
        .baseline_paths()?
        .into_iter()
        .collect::<BTreeSet<_>>();
    paths.extend(local.keys().cloned());
    paths.extend(remote.keys().cloned());
    let conflicts = journal.conflicts()?;
    let mut report = ReconcileReport {
        replayed_operations: replay.completed_operations,
        ..ReconcileReport::default()
    };
    let mut blocked_paths = BTreeSet::new();

    for path in paths {
        let baseline = match journal.baseline(&path)? {
            Some(value) => value,
            None => Baseline::Absent,
        };
        let local_observation = match local.get(&path) {
            Some(value) => value.clone(),
            None => Observation::ConfirmedAbsent,
        };
        let remote_observation = match remote.get(&path) {
            Some(value) => value.clone(),
            None => Observation::ConfirmedAbsent,
        };
        let decision = plan(&baseline, &local_observation, &remote_observation);

        if let Some(pending_plan) = pending.get(&path) {
            if let Decision::Conflict(conflict) = decision {
                match prepare_conflict(dropbox, sync_root, upload_staging, &path, &conflict)? {
                    Prepared::Ready(()) => {
                        finish_pending_conflict(journal, pending_plan, &conflict)?
                    }
                    Prepared::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                }
                report.conflicts += 1;
            } else {
                blocked_paths.insert(path.clone());
            }
            continue;
        }

        match decision {
            Decision::NoOp(noop) => match journal.record_noop(&path, &noop)? {
                NoOpWrite::Recorded => report.noops += 1,
                NoOpWrite::PendingPlan(_) => {
                    blocked_paths.insert(path.clone());
                }
            },
            Decision::Blocked(_) => {
                blocked_paths.insert(path.clone());
            }
            Decision::Operations(plan) => {
                match prepare_plan(
                    dropbox,
                    sync_root,
                    upload_staging,
                    recovery_directory,
                    &path,
                    plan.operations(),
                )? {
                    Prepared::Ready(()) => {}
                    Prepared::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                }
                require_active_local_root(journal, sync_root)?;
                match journal.record_plan(&path, &plan)? {
                    PlanWrite::Recorded(_) => report.planned += 1,
                    PlanWrite::AlreadyPending(_) => {
                        blocked_paths.insert(path.clone());
                    }
                }
            }
            Decision::Conflict(conflict) => {
                match prepare_conflict(dropbox, sync_root, upload_staging, &path, &conflict)? {
                    Prepared::Ready(()) => {}
                    Prepared::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                }
                if !conflicts
                    .iter()
                    .any(|record| record.path == path && record.conflict == conflict)
                {
                    journal.record_conflict(&path, &conflict)?;
                    report.conflicts += 1;
                }
            }
        }
    }
    let applied = replay_pending(
        journal,
        dropbox,
        sync_root,
        upload_staging,
        recovery_directory,
    )?;
    report.replayed_operations += applied.completed_operations;
    journal.prune_completed_work()?;
    prune_completed_recoveries(journal, recovery_directory)?;
    let retained_uploads = journal.pending_upload_content()?;
    let pending = journal.pending_plans()?;
    blocked_paths.extend(pending.into_iter().map(|plan| plan.path));
    report.blocked = blocked_paths.len();
    remove_unreferenced_upload_stages(upload_staging, &retained_uploads)?;
    Ok(ReconcileOutcome::Complete(report))
}

enum Prepared<T> {
    Ready(T),
    FreshObservation,
}

fn prepare_plan(
    dropbox: &DropboxClient,
    sync_root: &Path,
    upload_staging: &Path,
    recovery_directory: &Path,
    path: &Path,
    operations: &[Operation],
) -> Result<Prepared<()>, ReconcileError> {
    for operation in operations {
        match operation {
            Operation::CreateRemote { content } | Operation::ReplaceRemote { content, .. } => {
                if matches!(
                    prepare_local(sync_root, upload_staging, path, content)?,
                    Prepared::FreshObservation
                ) {
                    return Ok(Prepared::FreshObservation);
                }
            }
            Operation::InstallLocal { source } | Operation::ReplaceLocal { source, .. } => {
                stage_remote(dropbox, sync_root, path, path, source)?;
            }
            Operation::PreserveRemote { file } => {
                let target = destination(recovery_directory, path, &file.content);
                let Some(name) = target.file_name() else {
                    return Err(invalid(
                        path,
                        "remote recovery destination has no file name",
                    ));
                };
                stage_remote(dropbox, recovery_directory, Path::new(name), path, file)?;
            }
            Operation::PreserveLocal { file } => {
                if matches!(
                    prepare_local_preservation(sync_root, recovery_directory, path, &file.content)?,
                    Prepared::FreshObservation
                ) {
                    return Ok(Prepared::FreshObservation);
                }
            }
            Operation::DeleteLocal { .. } | Operation::DeleteRemote { .. } => {}
        }
    }
    Ok(Prepared::Ready(()))
}

fn prepare_local_preservation(
    sync_root: &Path,
    recovery_directory: &Path,
    path: &Path,
    content: &crate::model::ContentIdentity,
) -> Result<Prepared<()>, ReconcileError> {
    match materialize_before_plan(sync_root, recovery_directory, path, content) {
        Ok(RecoveryMaterialization::Created(_) | RecoveryMaterialization::AlreadyPresent(_)) => {
            Ok(Prepared::Ready(()))
        }
        Ok(RecoveryMaterialization::SourceChanged { .. }) => Ok(Prepared::FreshObservation),
        Err(source) if recovery_source_changed(&source, path) => Ok(Prepared::FreshObservation),
        Err(source) => Err(ReconcileError::Recovery { source }),
    }
}

fn prepare_conflict(
    dropbox: &DropboxClient,
    sync_root: &Path,
    upload_staging: &Path,
    path: &Path,
    conflict: &Conflict,
) -> Result<Prepared<()>, ReconcileError> {
    if let Some(local) = conflict.local() {
        let staged = match prepare_local(sync_root, upload_staging, path, &local.content)? {
            Prepared::Ready(staged) => staged,
            Prepared::FreshObservation => return Ok(Prepared::FreshObservation),
        };
        materialize_local_conflict(sync_root, path, &staged)?;
    }
    if let Some(remote) = conflict.remote() {
        materialize_remote_conflict(dropbox, sync_root, path, remote)?;
    }
    Ok(Prepared::Ready(()))
}

fn prepare_local(
    sync_root: &Path,
    upload_staging: &Path,
    path: &Path,
    content: &crate::model::ContentIdentity,
) -> Result<Prepared<StagedUpload>, ReconcileError> {
    match stage_upload(sync_root, path, upload_staging, content) {
        Ok(StageOutcome::Staged(staged)) => Ok(Prepared::Ready(staged)),
        Ok(StageOutcome::AlreadyStaged(staged)) => match observe_upload_source(sync_root, path) {
            Ok(actual) if actual == *content => Ok(Prepared::Ready(staged)),
            Ok(_) => Ok(Prepared::FreshObservation),
            Err(source) if local_source_changed(&source, path) => Ok(Prepared::FreshObservation),
            Err(source) => Err(ReconcileError::Local { source }),
        },
        Ok(StageOutcome::ContentChanged { .. }) => Ok(Prepared::FreshObservation),
        Ok(StageOutcome::DestinationOccupied { path }) => {
            Err(ReconcileError::StageDestinationOccupied { path })
        }
        Err(source) if local_source_changed(&source, path) => Ok(Prepared::FreshObservation),
        Err(source) => Err(ReconcileError::Local { source }),
    }
}

fn local_source_changed(error: &LocalError, path: &Path) -> bool {
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

fn recovery_source_changed(error: &RecoveryError, path: &Path) -> bool {
    match error {
        RecoveryError::Local { source } if local_source_changed(source, path) => true,
        RecoveryError::Local {
            source:
                LocalError::Io {
                    operation: "open displaced local payload for recovery",
                    path: changed,
                    ..
                },
        } => changed == path,
        RecoveryError::Local {
            source:
                LocalError::ChangedDuringRead {
                    operation: "materialize recovery copy",
                    ..
                },
        } => true,
        RecoveryError::Local { .. }
        | RecoveryError::Journal { .. }
        | RecoveryError::Dropbox { .. }
        | RecoveryError::InvalidJournalState { .. } => false,
    }
}

fn require_active_local_root(journal: &Journal, sync_root: &Path) -> Result<(), ReconcileError> {
    if configured_root_is_active(journal, sync_root)? {
        Ok(())
    } else {
        Err(ReconcileError::LocalRootChanged)
    }
}

fn stage_remote(
    dropbox: &DropboxClient,
    root: &Path,
    target: &Path,
    synchronized_path: &Path,
    remote: &crate::model::RemoteFile,
) -> Result<(), ReconcileError> {
    match dropbox.stage_exact_download_for(root, target, synchronized_path, remote)? {
        StageOutcome::Staged(()) | StageOutcome::AlreadyStaged(()) => Ok(()),
        StageOutcome::ContentChanged { .. } => Err(ReconcileError::RemoteContentChanged {
            path: synchronized_path.to_path_buf(),
        }),
        StageOutcome::DestinationOccupied { path } => {
            Err(ReconcileError::StageDestinationOccupied { path })
        }
    }
}

fn finish_pending_conflict(
    journal: &mut Journal,
    pending: &PlanRecord,
    conflict: &Conflict,
) -> Result<(), ReconcileError> {
    match journal.finish_plan_with_conflict(pending.id, conflict)? {
        PlanConflictCompletion::Recorded | PlanConflictCompletion::AlreadyCompleted => Ok(()),
        PlanConflictCompletion::NotFound => Err(invalid(
            &pending.path,
            "pending plan disappeared before conflict completion",
        )),
    }
}

fn local_map(records: Vec<LocalObservationRecord>) -> BTreeMap<PathBuf, LocalObservation> {
    records
        .into_iter()
        .map(|record| (record.path, record.observation))
        .collect()
}

fn remote_map(records: Vec<RemoteObservationRecord>) -> BTreeMap<PathBuf, RemoteObservation> {
    records
        .into_iter()
        .map(|record| (record.path, record.observation))
        .collect()
}

fn invalid(path: &Path, detail: &'static str) -> ReconcileError {
    ReconcileError::InvalidJournalState {
        path: path.to_path_buf(),
        detail,
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::io::{Cursor, Read as _};

    use tempfile::TempDir;

    use super::*;
    use crate::local::{ConflictSide, conflict_relative_path, dropbox_content_hash};
    use crate::model::{ContentIdentity, DropboxRevision, LocalFile, RemoteFile};

    fn identity(bytes: &[u8]) -> Result<ContentIdentity, Box<dyn Error>> {
        Ok(dropbox_content_hash(Cursor::new(bytes))?)
    }

    fn record_matching_baseline(
        journal: &mut Journal,
        path: &Path,
        remote: &RemoteFile,
    ) -> Result<(), Box<dyn Error>> {
        let local = Observation::Present(LocalFile::new(remote.content.clone()));
        let remote_observation = Observation::Present(remote.clone());
        let Decision::NoOp(noop) = plan(&Baseline::Absent, &local, &remote_observation) else {
            return Err(
                std::io::Error::other("matching observations did not produce a no-op").into(),
            );
        };
        if journal.record_noop(path, &noop)? != NoOpWrite::Recorded {
            return Err(std::io::Error::other("matching baseline was not recorded").into());
        }
        Ok(())
    }

    #[test]
    fn baseline_only_paths_are_included_in_confirmed_absence() -> Result<(), Box<dyn Error>> {
        let state = TempDir::new()?;
        let mut journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let path = Path::new("gone.txt");
        let remote = RemoteFile::new(identity(b"old")?, DropboxRevision::new("rev-old"));
        record_matching_baseline(&mut journal, path, &remote)?;

        let paths = journal.baseline_paths()?;
        assert_eq!(paths, vec![path.to_path_buf()]);
        assert!(matches!(
            plan(
                &match journal.baseline(path)? {
                    Some(value) => value,
                    None => return Err(std::io::Error::other("baseline disappeared").into()),
                },
                &Observation::ConfirmedAbsent,
                &Observation::ConfirmedAbsent,
            ),
            Decision::NoOp(ref noop) if noop.baseline() == &Baseline::Absent
        ));
        Ok(())
    }

    #[test]
    fn local_bytes_are_staged_before_plan_visibility() -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let state = TempDir::new()?;
        let mut journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let path = Path::new("upload.txt");
        let bytes = b"observed bytes";
        let content = identity(bytes)?;
        std::fs::write(root.path().join(path), bytes)?;

        let Prepared::Ready(staged) = prepare_local(root.path(), staging.path(), path, &content)?
        else {
            return Err(std::io::Error::other("stable local file requested a fresh scan").into());
        };
        assert!(journal.pending_plans()?.is_empty());
        let mut staged_bytes = Vec::new();
        staged.open_verified()?.read_to_end(&mut staged_bytes)?;
        assert_eq!(staged_bytes, bytes);

        let Decision::Operations(operation_plan) = plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content.clone())),
            &Observation::ConfirmedAbsent,
        ) else {
            return Err(std::io::Error::other("local creation did not produce a plan").into());
        };
        let _ = journal.record_plan(path, &operation_plan)?;
        assert_eq!(journal.pending_plans()?.len(), 1);
        let retained = journal.pending_upload_content()?;
        assert_eq!(retained, vec![content]);
        assert_eq!(
            remove_unreferenced_upload_stages(staging.path(), &retained)?,
            0
        );
        assert!(staging.path().join(staged.content().as_str()).is_file());
        Ok(())
    }

    #[test]
    fn matching_stage_still_requires_a_current_source_before_planning() -> Result<(), Box<dyn Error>>
    {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let state = TempDir::new()?;
        let journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let path = Path::new("changed.txt");
        let bytes = b"observed bytes";
        let content = identity(bytes)?;
        std::fs::write(root.path().join(path), bytes)?;
        assert!(matches!(
            prepare_local(root.path(), staging.path(), path, &content)?,
            Prepared::Ready(_)
        ));

        std::fs::write(root.path().join(path), b"new bytes")?;
        assert!(matches!(
            prepare_local(root.path(), staging.path(), path, &content)?,
            Prepared::FreshObservation
        ));
        assert_eq!(std::fs::read(root.path().join(path))?, b"new bytes");
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.conflicts()?.is_empty());

        std::fs::remove_file(root.path().join(path))?;
        assert!(matches!(
            prepare_local(root.path(), staging.path(), path, &content)?,
            Prepared::FreshObservation
        ));
        assert!(!root.path().join(path).exists());
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.conflicts()?.is_empty());
        Ok(())
    }

    #[test]
    fn local_recovery_exists_before_plan_and_survives_source_removal() -> Result<(), Box<dyn Error>>
    {
        let root = TempDir::new()?;
        let recovery = TempDir::new()?;
        let state = TempDir::new()?;
        let mut journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let path = Path::new("deleted.txt");
        let bytes = b"preserve before delete";
        let old = RemoteFile::new(identity(bytes)?, DropboxRevision::new("rev-old"));
        record_matching_baseline(&mut journal, path, &old)?;
        std::fs::write(root.path().join(path), bytes)?;

        assert!(matches!(
            prepare_local_preservation(root.path(), recovery.path(), path, &old.content)?,
            Prepared::Ready(())
        ));
        assert!(journal.pending_plans()?.is_empty());
        let recovery_path = destination(recovery.path(), path, &old.content);
        assert_eq!(std::fs::read(&recovery_path)?, bytes);

        let Decision::Operations(operation_plan) = plan(
            &Baseline::Present(old.clone()),
            &Observation::Present(LocalFile::new(old.content.clone())),
            &Observation::ConfirmedAbsent,
        ) else {
            return Err(std::io::Error::other("remote deletion did not produce a plan").into());
        };
        if !matches!(
            journal.record_plan(path, &operation_plan)?,
            PlanWrite::Recorded(_)
        ) {
            return Err(std::io::Error::other("fresh delete plan was not recorded").into());
        }
        std::fs::remove_file(root.path().join(path))?;

        let replay = replay_local_operations(&mut journal, root.path(), recovery.path())?;
        assert_eq!(replay.completed_operations, 2);
        assert!(replay.blocked.is_empty());
        assert!(journal.pending_plans()?.is_empty());
        assert_eq!(journal.baseline(path)?, None);
        assert_eq!(std::fs::read(recovery_path)?, bytes);
        Ok(())
    }

    #[test]
    fn existing_local_recovery_never_substitutes_for_the_live_source() -> Result<(), Box<dyn Error>>
    {
        let root = TempDir::new()?;
        let recovery = TempDir::new()?;
        let state = TempDir::new()?;
        let journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let path = Path::new("stale.txt");
        let expected = identity(b"observed")?;
        std::fs::write(root.path().join(path), b"observed")?;
        assert!(matches!(
            prepare_local_preservation(root.path(), recovery.path(), path, &expected)?,
            Prepared::Ready(())
        ));

        std::fs::write(root.path().join(path), b"changed")?;
        assert!(matches!(
            prepare_local_preservation(root.path(), recovery.path(), path, &expected)?,
            Prepared::FreshObservation
        ));
        std::fs::remove_file(root.path().join(path))?;
        assert!(matches!(
            prepare_local_preservation(root.path(), recovery.path(), path, &expected)?,
            Prepared::FreshObservation
        ));
        assert!(journal.pending_plans()?.is_empty());
        assert_eq!(
            std::fs::read(destination(recovery.path(), path, &expected))?,
            b"observed"
        );
        Ok(())
    }

    #[test]
    fn pending_changed_precondition_is_preserved_without_baseline_advance()
    -> Result<(), Box<dyn Error>> {
        let root = TempDir::new()?;
        let staging = TempDir::new()?;
        let state = TempDir::new()?;
        let mut journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let path = Path::new("edited.txt");
        let old = RemoteFile::new(identity(b"old")?, DropboxRevision::new("rev-old"));
        let edited = identity(b"local edit")?;
        record_matching_baseline(&mut journal, path, &old)?;
        std::fs::write(root.path().join(path), b"local edit")?;

        let Decision::Operations(operation_plan) = plan(
            &Baseline::Present(old.clone()),
            &Observation::Present(LocalFile::new(edited.clone())),
            &Observation::Present(old.clone()),
        ) else {
            return Err(std::io::Error::other("local edit did not produce a remote plan").into());
        };
        let pending = match journal.record_plan(path, &operation_plan)? {
            PlanWrite::Recorded(plan) => plan,
            PlanWrite::AlreadyPending(_) => {
                return Err(std::io::Error::other("fresh journal already had a plan").into());
            }
        };

        let Decision::Conflict(conflict) = plan(
            &Baseline::Present(old.clone()),
            &Observation::Present(LocalFile::new(edited.clone())),
            &Observation::ConfirmedAbsent,
        ) else {
            return Err(
                std::io::Error::other("remote deletion did not conflict with local edit").into(),
            );
        };
        let Prepared::Ready(staged) = prepare_local(root.path(), staging.path(), path, &edited)?
        else {
            return Err(
                std::io::Error::other("stable conflict source requested a fresh scan").into(),
            );
        };
        materialize_local_conflict(root.path(), path, &staged)?;
        finish_pending_conflict(&mut journal, &pending, &conflict)?;

        assert!(journal.pending_plans()?.is_empty());
        assert_eq!(journal.baseline(path)?, Some(Baseline::Present(old)));
        assert_eq!(journal.conflicts()?.len(), 1);
        let copy = conflict_relative_path(path, ConflictSide::Local, &edited)?;
        assert_eq!(std::fs::read(root.path().join(copy))?, b"local edit");
        Ok(())
    }
}
