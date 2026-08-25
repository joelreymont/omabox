//! One finite observe, plan, and journal pass.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;

use rustix::fd::OwnedFd;
use thiserror::Error;

use crate::dropbox::{DropboxClient, DropboxError};
use crate::journal::{
    Journal, JournalError, LocalObservationRecord, NoOpWrite, PlanConflictCompletion, PlanRecord,
    PlanWrite, RemoteObservationRecord, dropbox_canonical_path,
};
use crate::local::{
    CaseVariantRename, DownloadSlotIdentity, DownloadSlotLease, LocalError, MAX_PARALLEL_DOWNLOADS,
    ScanPublication, StageOutcome, StagedUpload, case_variant_name_max, configured_root_is_active,
    lease_download_slots, observe_upload_source, open_active_root,
    remove_unreferenced_upload_stages, rename_case_variant, scan_and_publish, stage_upload,
};
use crate::model::{Baseline, Conflict, Decision, Observation, Operation, RemoteFile};
use crate::planner::plan;
use crate::recovery::{
    RecoveryError, RecoveryMaterialization, ReplayBlocked, ReplayReport, destination,
    materialize_before_plan, materialize_local_conflict, materialize_remote_conflict,
    prune_completed_recoveries, replay_local_plans_at, replay_remote_operations_at,
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
    /// An exact Dropbox download failed for one synchronized path.
    #[error("could not stage the exact Dropbox download for `{path}`")]
    RemoteDownload {
        /// Synchronized path being staged.
        path: PathBuf,
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
    /// A bounded download worker could not be started.
    #[error("could not start a Dropbox download worker")]
    DownloadWorkerSpawn {
        /// Operating-system thread creation failure.
        #[source]
        source: io::Error,
    },
    /// A bounded download worker stopped without returning its typed result.
    #[error("a Dropbox download worker stopped unexpectedly")]
    DownloadWorkerStopped,
    /// Durable records violated the finite reconciliation contract.
    #[error("reconciliation found invalid journal state for `{path}`: {detail}")]
    InvalidJournalState {
        /// Synchronized path affected by the invalid record.
        path: PathBuf,
        /// Stable, non-secret explanation.
        detail: &'static str,
    },
    /// Two local paths cannot both be represented by Dropbox's case-insensitive identity.
    #[error("local paths `{first}` and `{second}` have the same Dropbox path identity")]
    LocalCaseCollision {
        /// First observed local spelling.
        first: PathBuf,
        /// Second observed local spelling.
        second: PathBuf,
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

/// Four persistent workers that stage exact Dropbox downloads without touching the journal.
pub struct ExactDownloadPool {
    jobs: mpsc::SyncSender<DownloadJob>,
    results: mpsc::Receiver<DownloadResult>,
    in_flight: BTreeSet<PathBuf>,
    workers: Vec<thread::JoinHandle<()>>,
}

impl ExactDownloadPool {
    /// Start the daemon's fixed download workers.
    pub fn new(dropbox: Arc<DropboxClient>) -> Result<Self, ReconcileError> {
        let (jobs, job_receiver) = mpsc::sync_channel(MAX_PARALLEL_DOWNLOADS);
        let job_receiver = Arc::new(Mutex::new(job_receiver));
        let (result_sender, results) = mpsc::channel();
        let mut workers = Vec::with_capacity(MAX_PARALLEL_DOWNLOADS);

        for index in 0..MAX_PARALLEL_DOWNLOADS {
            let receiver = Arc::clone(&job_receiver);
            let sender = result_sender.clone();
            let dropbox = Arc::clone(&dropbox);
            match thread::Builder::new()
                .name(format!("omabox-download-{index}"))
                .spawn(move || download_worker(&dropbox, &receiver, &sender))
            {
                Ok(worker) => workers.push(worker),
                Err(source) => {
                    drop(jobs);
                    drop(result_sender);
                    for worker in workers {
                        if worker.join().is_err() {
                            tracing::warn!("a download worker stopped during startup cleanup");
                        }
                    }
                    return Err(ReconcileError::DownloadWorkerSpawn { source });
                }
            }
        }
        drop(result_sender);
        Ok(Self {
            jobs,
            results,
            in_flight: BTreeSet::new(),
            workers,
        })
    }

    fn collect_results(&mut self) -> Result<Option<ReconcileError>, ReconcileError> {
        let failure = loop {
            match self.results.try_recv() {
                Ok(result) => {
                    self.in_flight.remove(&result.path);
                    if let Err(error) = result.outcome {
                        break Some(error);
                    }
                }
                Err(mpsc::TryRecvError::Empty) => break None,
                Err(mpsc::TryRecvError::Disconnected) => {
                    return Err(ReconcileError::DownloadWorkerStopped);
                }
            }
        };
        if self.workers.iter().any(thread::JoinHandle::is_finished) {
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        Ok(failure)
    }

    fn contains(&self, path: &Path) -> bool {
        self.in_flight.contains(path)
    }

    fn available(&self) -> usize {
        MAX_PARALLEL_DOWNLOADS.saturating_sub(self.in_flight.len())
    }

    fn schedule(&mut self, job: DownloadJob) -> Result<(), ReconcileError> {
        if self.workers.iter().any(thread::JoinHandle::is_finished) {
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        let path = job.path.clone();
        self.jobs
            .send(job)
            .map_err(|_| ReconcileError::DownloadWorkerStopped)?;
        self.in_flight.insert(path);
        Ok(())
    }
}

struct DownloadJob {
    root: Arc<OwnedFd>,
    root_path: PathBuf,
    path: PathBuf,
    source: RemoteFile,
    slot: Option<DownloadSlotLease>,
}

struct DownloadResult {
    path: PathBuf,
    outcome: Result<(), ReconcileError>,
}

fn download_worker(
    dropbox: &DropboxClient,
    jobs: &Mutex<mpsc::Receiver<DownloadJob>>,
    results: &mpsc::Sender<DownloadResult>,
) {
    loop {
        let job = {
            let receiver = match jobs.lock() {
                Ok(receiver) => receiver,
                Err(_) => return,
            };
            match receiver.recv() {
                Ok(job) => job,
                Err(_) => return,
            }
        };
        let outcome = stage_remote_at(
            dropbox,
            &job.root,
            &job.root_path,
            &job.path,
            &job.path,
            &job.source,
            job.slot.as_ref(),
        );
        if results
            .send(DownloadResult {
                path: job.path,
                outcome,
            })
            .is_err()
        {
            return;
        }
    }
}

/// Replay durable work once while missing exact downloads continue on persistent workers.
pub fn replay_pending(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    downloads: &mut ExactDownloadPool,
    sync_root: impl AsRef<Path>,
    upload_staging: impl AsRef<Path>,
    recovery_directory: impl AsRef<Path>,
) -> Result<ReplayReport, ReconcileError> {
    replay_pending_at(
        journal,
        dropbox,
        downloads,
        sync_root.as_ref(),
        upload_staging.as_ref(),
        recovery_directory.as_ref(),
    )
}

fn replay_pending_at(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    download_pool: &mut ExactDownloadPool,
    sync_root: &Path,
    upload_staging: &Path,
    recovery_directory: &Path,
) -> Result<ReplayReport, ReconcileError> {
    let download_failure = download_pool.collect_results()?;
    let Some(root) = open_active_root(journal, sync_root)? else {
        return Err(ReconcileError::LocalRootChanged);
    };
    let root = Arc::new(root);
    let root_generation = journal
        .local_root_binding()?
        .ok_or(ReconcileError::LocalRootChanged)?
        .generation;
    let pending_plans = journal.pending_plans()?;
    let mut report = replay_local_plans_at(
        journal,
        &root,
        sync_root,
        recovery_directory,
        pending_plans
            .iter()
            .filter(|plan| !download_pool.contains(&plan.path)),
    )?;
    for plan in pending_plans
        .iter()
        .filter(|plan| download_pool.contains(&plan.path))
    {
        let (_, source) = pending_download_operation(plan)?;
        report.blocked.push(ReplayBlocked::DownloadRequired {
            path: plan.path.clone(),
            content: source.content,
        });
    }
    if let Some(error) = download_failure {
        require_active_local_root(journal, sync_root)?;
        return Err(error);
    }
    let missing_downloads = report
        .blocked
        .iter()
        .filter_map(|blocked| match blocked {
            ReplayBlocked::DownloadRequired { path, .. } => Some(path.clone()),
            _ => None,
        })
        .collect::<BTreeSet<_>>();
    if missing_downloads.is_empty() {
        let _ = lease_download_slots(upload_staging, &[])?;
    }
    if !missing_downloads.is_empty() {
        let mut pending = pending_plans
            .into_iter()
            .map(|plan| (plan.path.clone(), plan))
            .collect::<BTreeMap<_, _>>();
        let mut downloads = Vec::with_capacity(missing_downloads.len());
        for path in missing_downloads {
            let Some(plan) = pending.remove(&path) else {
                return Err(invalid(
                    &path,
                    "pending download blocker has no matching plan",
                ));
            };
            let (operation_id, source) = pending_download_operation(&plan)?;
            downloads.push(PendingDownload {
                path,
                source,
                operation_id,
                slot: None,
            });
        }
        require_active_local_root(journal, sync_root)?;
        schedule_pending_downloads(
            download_pool,
            Arc::clone(&root),
            sync_root,
            upload_staging,
            root_generation,
            downloads,
        )?;
    }
    require_active_local_root(journal, sync_root)?;
    let remote = replay_remote_operations_at(
        journal,
        dropbox,
        &root,
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
    downloads: &mut ExactDownloadPool,
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
        downloads,
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
    downloads: &mut ExactDownloadPool,
) -> Result<ReconcileOutcome, ReconcileError> {
    let sync_root = sync_root.as_ref();
    let upload_staging = upload_staging.as_ref();
    let recovery_directory = recovery_directory.as_ref();
    let replay = replay_pending_at(
        journal,
        dropbox,
        downloads,
        sync_root,
        upload_staging,
        recovery_directory,
    )?;
    let scan = match scan_and_publish(journal, sync_root) {
        Ok(ScanPublication::Published(scan)) => scan,
        Ok(ScanPublication::RootChanged) => return Err(ReconcileError::LocalRootChanged),
        Err(LocalError::ChangedDuringRead { path, .. }) => {
            return Ok(ReconcileOutcome::FreshObservationRequired { path });
        }
        Err(source) => return Err(ReconcileError::Local { source }),
    };
    if let Some(source) = case_variant_source(scan.observations()) {
        let Some(root) = open_active_root(journal, sync_root)? else {
            return Err(ReconcileError::LocalRootChanged);
        };
        let Some(name_max) = case_variant_name_max(&root, &source)? else {
            return Ok(ReconcileOutcome::FreshObservationRequired { path: source });
        };
        let rename = case_variant_move(scan.observations(), source, name_max)?;
        match rename_case_variant(&root, &rename.source, &rename.destination)? {
            CaseVariantRename::Renamed | CaseVariantRename::Retry => {
                return Ok(ReconcileOutcome::FreshObservationRequired {
                    path: rename.source,
                });
            }
        }
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
        downloads,
    )
}

fn reconcile_published(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    sync_root: &Path,
    upload_staging: &Path,
    recovery_directory: &Path,
    replay: ReplayReport,
    downloads: &mut ExactDownloadPool,
) -> Result<ReconcileOutcome, ReconcileError> {
    let local = local_map(journal.local_inventory()?)?;
    let remote = remote_map(journal.remote_inventory()?.observations);
    let pending = journal
        .pending_plans()?
        .into_iter()
        .map(|plan| (dropbox_canonical_path(&plan.path), plan))
        .collect::<BTreeMap<_, _>>();
    let baseline_paths = journal
        .baseline_paths()?
        .into_iter()
        .map(|path| (dropbox_canonical_path(&path), path))
        .collect::<BTreeMap<_, _>>();
    let mut paths = baseline_paths.keys().cloned().collect::<BTreeSet<_>>();
    paths.extend(local.keys().cloned());
    paths.extend(remote.keys().cloned());
    let conflicts = journal.conflicts()?;
    let mut report = ReconcileReport {
        replayed_operations: replay.completed_operations,
        ..ReconcileReport::default()
    };
    let mut blocked_paths = BTreeSet::new();

    for canonical_path in paths {
        let baseline = match journal.baseline(&canonical_path)? {
            Some(value) => value,
            None => Baseline::Absent,
        };
        let local_observation = match local.get(&canonical_path) {
            Some(value) => value.observation.clone(),
            None => Observation::ConfirmedAbsent,
        };
        let remote_observation = match remote.get(&canonical_path) {
            Some(value) => value.observation.clone(),
            None => Observation::ConfirmedAbsent,
        };
        let path = local
            .get(&canonical_path)
            .map(|record| record.path.clone())
            .or_else(|| {
                remote
                    .get(&canonical_path)
                    .map(|record| record.path.clone())
            })
            .or_else(|| baseline_paths.get(&canonical_path).cloned())
            .ok_or_else(|| invalid(&canonical_path, "canonical path has no display spelling"))?;
        let decision = plan(&baseline, &local_observation, &remote_observation);

        if let Some(pending_plan) = pending.get(&canonical_path) {
            if downloads.contains(&pending_plan.path) {
                blocked_paths.insert(canonical_path.clone());
                continue;
            }
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
                blocked_paths.insert(canonical_path.clone());
            }
            continue;
        }

        match decision {
            Decision::NoOp(noop) => match journal.record_noop(&path, &noop)? {
                NoOpWrite::Recorded => report.noops += 1,
                NoOpWrite::PendingPlan(_) => {
                    blocked_paths.insert(canonical_path.clone());
                }
            },
            Decision::Blocked(_) => {
                blocked_paths.insert(canonical_path.clone());
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
                        blocked_paths.insert(canonical_path.clone());
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
                if !conflicts.iter().any(|record| {
                    dropbox_canonical_path(&record.path) == canonical_path
                        && record.conflict == conflict
                }) {
                    journal.record_conflict(&path, &conflict)?;
                    report.conflicts += 1;
                }
            }
        }
    }
    let applied = replay_pending_at(
        journal,
        dropbox,
        downloads,
        sync_root,
        upload_staging,
        recovery_directory,
    )?;
    report.replayed_operations += applied.completed_operations;
    journal.prune_completed_work()?;
    prune_completed_recoveries(journal, recovery_directory)?;
    let retained_uploads = journal.pending_upload_content()?;
    let pending = journal.pending_plans()?;
    blocked_paths.extend(
        pending
            .into_iter()
            .map(|plan| dropbox_canonical_path(&plan.path)),
    );
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
            // Exact downloads are fetched only after this plan is durable, allowing startup and
            // post-plan replay to share the same bounded batch.
            Operation::InstallLocal { .. } | Operation::ReplaceLocal { .. } => {}
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

struct PendingDownload {
    path: PathBuf,
    source: RemoteFile,
    operation_id: crate::journal::OperationId,
    slot: Option<DownloadSlotLease>,
}

fn pending_download_operation(
    plan: &PlanRecord,
) -> Result<(crate::journal::OperationId, RemoteFile), ReconcileError> {
    plan.operations
        .iter()
        .find_map(|planned| {
            if planned.status == crate::journal::RecordStatus::Completed {
                return None;
            }
            match &planned.operation {
                Operation::InstallLocal { source } | Operation::ReplaceLocal { source, .. } => {
                    Some((planned.id, source.clone()))
                }
                _ => None,
            }
        })
        .ok_or_else(|| {
            invalid(
                &plan.path,
                "pending download blocker has no matching local operation",
            )
        })
}

fn lease_pending_downloads(
    upload_staging: &Path,
    root_generation: u64,
    downloads: &mut [PendingDownload],
) -> Result<(), ReconcileError> {
    let identities = downloads
        .iter()
        .map(|download| {
            DownloadSlotIdentity::new(
                root_generation,
                download.operation_id,
                &download.path,
                &download.source,
            )
        })
        .collect::<Vec<_>>();
    let leases = lease_download_slots(upload_staging, &identities)?;
    for (download, lease) in downloads.iter_mut().zip(leases) {
        download.slot = lease;
    }
    Ok(())
}

fn schedule_pending_downloads(
    pool: &mut ExactDownloadPool,
    root: Arc<OwnedFd>,
    root_path: &Path,
    upload_staging: &Path,
    root_generation: u64,
    mut downloads: Vec<PendingDownload>,
) -> Result<(), ReconcileError> {
    lease_pending_downloads(upload_staging, root_generation, &mut downloads)?;
    downloads.sort_by_key(|download| download.slot.is_none());
    let mut available = pool.available();
    for download in downloads {
        if available == 0 {
            break;
        }
        if pool.contains(&download.path) {
            continue;
        }
        pool.schedule(DownloadJob {
            root: Arc::clone(&root),
            root_path: root_path.to_path_buf(),
            path: download.path,
            source: download.source,
            slot: download.slot,
        })?;
        available -= 1;
    }
    Ok(())
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
    let staged = dropbox
        .stage_exact_download_for(root, target, synchronized_path, remote)
        .map_err(|source| ReconcileError::RemoteDownload {
            path: synchronized_path.to_path_buf(),
            source,
        })?;
    match staged {
        StageOutcome::Staged(()) | StageOutcome::AlreadyStaged(()) => Ok(()),
        StageOutcome::ContentChanged { .. } => Err(ReconcileError::RemoteContentChanged {
            path: synchronized_path.to_path_buf(),
        }),
        StageOutcome::DestinationOccupied { path } => {
            Err(ReconcileError::StageDestinationOccupied { path })
        }
    }
}

fn stage_remote_at(
    dropbox: &DropboxClient,
    root: &OwnedFd,
    root_path: &Path,
    target: &Path,
    synchronized_path: &Path,
    remote: &crate::model::RemoteFile,
    slot: Option<&DownloadSlotLease>,
) -> Result<(), ReconcileError> {
    let staged = dropbox
        .stage_exact_download_for_at(root, root_path, target, synchronized_path, remote, slot)
        .map_err(|source| ReconcileError::RemoteDownload {
            path: synchronized_path.to_path_buf(),
            source,
        })?;
    match staged {
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

fn local_map(
    records: Vec<LocalObservationRecord>,
) -> Result<BTreeMap<PathBuf, LocalObservationRecord>, ReconcileError> {
    let mut mapped = BTreeMap::new();
    for record in records {
        let canonical_path = dropbox_canonical_path(&record.path);
        if let Some(existing) = mapped.insert(canonical_path, record.clone()) {
            return Err(ReconcileError::LocalCaseCollision {
                first: existing.path,
                second: record.path,
            });
        }
    }
    Ok(mapped)
}

#[derive(Debug, Eq, PartialEq)]
struct CaseVariantMove {
    source: PathBuf,
    destination: PathBuf,
}

fn case_variant_source(records: &[LocalObservationRecord]) -> Option<PathBuf> {
    let mut spellings = BTreeMap::<PathBuf, BTreeSet<PathBuf>>::new();
    for record in records {
        let canonical = dropbox_canonical_path(&record.path);
        spellings
            .entry(canonical)
            .or_default()
            .insert(record.path.clone());
    }
    spellings
        .values()
        .find(|paths| paths.len() > 1)
        .and_then(|variants| variants.last().cloned())
}

fn case_variant_move(
    records: &[LocalObservationRecord],
    source: PathBuf,
    name_max: usize,
) -> Result<CaseVariantMove, ReconcileError> {
    let occupied = records
        .iter()
        .map(|record| dropbox_canonical_path(&record.path))
        .collect::<BTreeSet<_>>();
    let Some(name) = source.file_name() else {
        return Err(invalid(
            &source,
            "local case collision has no final path component",
        ));
    };
    let Some(parent) = source.parent() else {
        return Err(invalid(&source, "local case collision has no parent path"));
    };
    for attempt in 0..=records.len() {
        let Some(candidate_name) = case_variant_name(name, attempt, name_max) else {
            break;
        };
        let destination = parent.join(candidate_name);
        if !occupied.contains(&dropbox_canonical_path(&destination)) {
            return Ok(CaseVariantMove {
                source,
                destination,
            });
        }
    }
    Err(invalid(
        &source,
        "could not select a unique local case-variant path",
    ))
}

fn case_variant_name(name: &OsStr, attempt: usize, name_max: usize) -> Option<OsString> {
    let suffix = if attempt == 0 {
        String::from(" (case variant)")
    } else {
        format!(" (case variant {})", attempt.saturating_add(1))
    };
    let prefix_max = name_max.checked_sub(suffix.len())?;
    let mut candidate = truncate_component(name, prefix_max);
    candidate.push(suffix);
    Some(candidate)
}

fn truncate_component(name: &OsStr, limit: usize) -> OsString {
    let bytes = name.as_bytes();
    if bytes.len() <= limit {
        return name.to_os_string();
    }
    if let Some(text) = name.to_str() {
        let mut end = limit;
        while !text.is_char_boundary(end) {
            end = end.saturating_sub(1);
        }
        OsString::from(&text[..end])
    } else {
        OsString::from_vec(bytes[..limit].to_vec())
    }
}

fn remote_map(records: Vec<RemoteObservationRecord>) -> BTreeMap<PathBuf, RemoteObservationRecord> {
    records
        .into_iter()
        .map(|record| (record.canonical_path.clone(), record))
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

    use proptest::prelude::*;
    use tempfile::TempDir;

    use super::*;
    use crate::local::{ConflictSide, conflict_relative_path, dropbox_content_hash};

    fn local_records(paths: impl IntoIterator<Item = PathBuf>) -> Vec<LocalObservationRecord> {
        paths
            .into_iter()
            .map(|path| LocalObservationRecord {
                path,
                observation: Observation::Unknown(crate::model::UnknownReason::Unsupported),
            })
            .collect()
    }

    proptest! {
        #[test]
        fn local_case_variants_never_collapse_into_one_observation(
            lowercase in "[a-z]{1,24}\\.txt",
        ) {
            let uppercase = lowercase.to_ascii_uppercase();
            let mut records = local_records([lowercase.into(), uppercase.into()]);

            let collision = match local_map(records.clone()) {
                Err(ReconcileError::LocalCaseCollision { .. }) => true,
                Ok(_) | Err(_) => false,
            };
            prop_assert!(collision);

            let Some(forward_source) = case_variant_source(&records) else {
                return Err(TestCaseError::fail("case collision had no source"));
            };
            let Ok(forward) = case_variant_move(&records, forward_source, 255) else {
                return Err(TestCaseError::fail("case collision had no automatic rename"));
            };
            records.reverse();
            let Some(reversed_source) = case_variant_source(&records) else {
                return Err(TestCaseError::fail("reversed case collision had no source"));
            };
            let Ok(reversed) = case_variant_move(&records, reversed_source, 255) else {
                return Err(TestCaseError::fail("reversed case collision had no rename"));
            };
            prop_assert_eq!(&forward, &reversed);
            let destination_is_unique = records.iter().all(|record| {
                dropbox_canonical_path(&record.path)
                    != dropbox_canonical_path(&forward.destination)
            });
            prop_assert!(destination_is_unique);
        }
    }

    #[test]
    fn case_variant_name_skips_existing_suffixes() -> Result<(), Box<dyn Error>> {
        let records = local_records(
            [
                "Credit",
                "credit",
                "credit (case variant)",
                "CREDIT (CASE VARIANT 2)",
            ]
            .map(PathBuf::from),
        );
        let Some(source) = case_variant_source(&records) else {
            return Err(io::Error::other("expected a case-variant rename").into());
        };
        let rename = case_variant_move(&records, source, 255)?;

        assert_eq!(rename.source, Path::new("credit"));
        assert_eq!(rename.destination, Path::new("credit (case variant 3)"));
        Ok(())
    }

    #[test]
    fn case_variant_name_fits_a_maximum_length_component() -> Result<(), Box<dyn Error>> {
        let records = local_records(["A".repeat(255).into(), "a".repeat(255).into()]);
        let Some(source) = case_variant_source(&records) else {
            return Err(io::Error::other("expected a maximum-length collision").into());
        };

        let rename = case_variant_move(&records, source, 255)?;

        let Some(destination_name) = rename.destination.file_name() else {
            return Err(io::Error::other("case variant destination had no name").into());
        };
        assert_eq!(destination_name.as_bytes().len(), 255);
        assert!(destination_name.as_bytes().ends_with(b" (case variant)"));
        Ok(())
    }

    #[test]
    fn case_variant_moves_converge_from_parent_to_child() -> Result<(), Box<dyn Error>> {
        let records = local_records(
            ["Credit", "credit", "credit/Expenses", "credit/expenses"].map(PathBuf::from),
        );
        let Some(parent_source) = case_variant_source(&records) else {
            return Err(io::Error::other("expected a parent collision").into());
        };
        let parent = case_variant_move(&records, parent_source, 255)?;
        assert_eq!(parent.source, Path::new("credit"));
        assert_eq!(parent.destination, Path::new("credit (case variant)"));

        let after_parent = local_records(
            [
                "Credit",
                "credit (case variant)",
                "credit (case variant)/Expenses",
                "credit (case variant)/expenses",
            ]
            .map(PathBuf::from),
        );
        let Some(child_source) = case_variant_source(&after_parent) else {
            return Err(io::Error::other("expected a child collision").into());
        };
        let child = case_variant_move(&after_parent, child_source, 255)?;
        assert_eq!(child.source, Path::new("credit (case variant)/expenses"));
        assert_eq!(
            child.destination,
            Path::new("credit (case variant)/expenses (case variant)")
        );

        let converged = local_records([
            PathBuf::from("Credit"),
            PathBuf::from("credit (case variant)"),
            PathBuf::from("credit (case variant)/Expenses"),
            child.destination,
        ]);
        assert_eq!(case_variant_source(&converged), None);
        Ok(())
    }

    use crate::model::{ContentIdentity, DropboxRevision, LocalFile, RemoteFile};
    use crate::recovery::replay_local_operations;

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
