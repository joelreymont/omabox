//! One finite observe, plan, and journal pass.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;

use rustix::fd::OwnedFd;
use thiserror::Error;

use crate::dropbox::{DownloadAccess, DropboxClient, DropboxError};
use crate::journal::{
    BaselineRecord, Journal, JournalError, LocalObservationRecord, PlanConflictCompletion,
    PlanRecord, PlanSupersede, RemoteObservationRecord,
};
use crate::local::{
    DownloadSlotIdentity, DownloadSlotLease, LocalError, LocalRenameOutcome,
    MAX_PARALLEL_DOWNLOADS, ScanPublication, StageOutcome, StagedUpload, SyncRootAccess,
    configured_root_is_active, lease_download_slot, lease_download_slots, observe_upload_source,
    open_active_root, parent_name_max, remove_unreferenced_upload_stages, rename_case_variant,
    rename_file_copy, scan_and_publish, stage_upload, upload_source_changed,
};
use crate::model::{
    Baseline, CanonicalPath, Conflict, ContentIdentity, Decision, DirectoryCollision,
    LocalObservation, Observation, Operation, OperationPlan, RemoteFile, RemoteObservation,
    UnknownReason,
};
use crate::planner::plan;
use crate::recovery::{
    ExactCopyOutcome, RecoveryError, ReplayBlocked, ReplayReport, materialize_local_conflict,
    materialize_remote_conflict, materialize_remote_copy_at, prune_completed_recoveries,
    replay_local_plans_at, replay_remote_operations_at,
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
    /// The in-process resumable-slot coordinator became unavailable.
    #[error("the Dropbox download slot coordinator is unavailable")]
    DownloadSlotCoordinatorUnavailable,
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
    /// Paths Dropbox permanently rejected during this pass.
    pub sync_errors: usize,
    /// Whether background download workers still have files in flight.
    pub downloads_in_progress: bool,
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
    jobs: Option<mpsc::Sender<DownloadJob>>,
    results: mpsc::Receiver<DownloadResult>,
    scheduled: BTreeSet<PathBuf>,
    pending_failure: Option<ReconcileError>,
    slots: Arc<Mutex<DownloadSlots>>,
    cancelled: Arc<AtomicBool>,
    root_access: Arc<SyncRootAccess>,
    workers: Vec<thread::JoinHandle<()>>,
}

impl ExactDownloadPool {
    /// Start the daemon's fixed download workers.
    pub fn new(dropbox: Arc<DropboxClient>) -> Result<Self, ReconcileError> {
        let (jobs, job_receiver) = mpsc::channel();
        let job_receiver = Arc::new(Mutex::new(job_receiver));
        let (result_sender, results) = mpsc::channel();
        let slots = Arc::new(Mutex::new(DownloadSlots::default()));
        let cancelled = Arc::new(AtomicBool::new(false));
        let root_access = Arc::new(SyncRootAccess::default());
        let mut workers = Vec::with_capacity(MAX_PARALLEL_DOWNLOADS);

        for index in 0..MAX_PARALLEL_DOWNLOADS {
            let receiver = Arc::clone(&job_receiver);
            let sender = result_sender.clone();
            let dropbox = Arc::clone(&dropbox);
            let slots = Arc::clone(&slots);
            let cancelled = Arc::clone(&cancelled);
            let root_access = Arc::clone(&root_access);
            match thread::Builder::new()
                .name(format!("omabox-download-{index}"))
                .spawn(move || {
                    download_worker(
                        &dropbox,
                        &receiver,
                        &sender,
                        &slots,
                        &cancelled,
                        &root_access,
                    )
                }) {
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
            jobs: Some(jobs),
            results,
            scheduled: BTreeSet::new(),
            pending_failure: None,
            slots,
            cancelled,
            root_access,
            workers,
        })
    }

    fn collect_results(&mut self) -> Result<Option<ReconcileError>, ReconcileError> {
        loop {
            match self.results.try_recv() {
                Ok(result) => {
                    self.scheduled.remove(&result.path);
                    if let Some(Err(error)) = result.outcome
                        && self.pending_failure.is_none()
                    {
                        self.pending_failure = Some(error);
                    }
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    return Err(ReconcileError::DownloadWorkerStopped);
                }
            }
        }
        if self.scheduled.is_empty() && self.pending_failure.is_some() {
            self.cancelled.store(false, Ordering::Release);
            return Ok(self.pending_failure.take());
        }
        if self.workers.iter().any(thread::JoinHandle::is_finished) {
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        Ok(None)
    }

    fn contains(&self, path: &Path) -> bool {
        self.scheduled.contains(path)
    }

    fn is_empty(&self) -> bool {
        self.scheduled.is_empty()
    }

    fn accepts_jobs(&self) -> bool {
        self.pending_failure.is_none() && !self.cancelled.load(Ordering::Acquire)
    }

    fn schedule(&mut self, job: DownloadJob) -> Result<(), ReconcileError> {
        if self.pending_failure.is_some()
            || self.cancelled.load(Ordering::Acquire)
            || self.workers.iter().any(thread::JoinHandle::is_finished)
        {
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        let path = job.path.clone();
        if let Some(slot) = &job.slot {
            let mut slots = self
                .slots
                .lock()
                .map_err(|_| ReconcileError::DownloadSlotCoordinatorUnavailable)?;
            if !slots.reserved.insert(slot.slot()) {
                return Err(invalid(&path, "resumable download slot was assigned twice"));
            }
        }
        let Some(jobs) = &self.jobs else {
            return Err(ReconcileError::DownloadWorkerStopped);
        };
        if let Err(error) = jobs.send(job) {
            if let Some(slot) = &error.0.slot
                && let Ok(mut slots) = self.slots.lock()
            {
                slots.reserved.remove(&slot.slot());
            }
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        self.scheduled.insert(path);
        Ok(())
    }
}

impl Drop for ExactDownloadPool {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
        drop(self.jobs.take());
        for worker in self.workers.drain(..) {
            if worker.join().is_err() {
                tracing::warn!("a download worker stopped during shutdown");
            }
        }
    }
}

#[derive(Default)]
struct DownloadSlots {
    reserved: BTreeSet<u8>,
}

struct DownloadJob {
    root: Arc<OwnedFd>,
    root_path: PathBuf,
    staging_directory: PathBuf,
    path: PathBuf,
    source: RemoteFile,
    slot_identity: DownloadSlotIdentity,
    slot: Option<DownloadSlotLease>,
}

struct DownloadResult {
    path: PathBuf,
    outcome: Option<Result<(), ReconcileError>>,
}

fn download_worker(
    dropbox: &DropboxClient,
    jobs: &Mutex<mpsc::Receiver<DownloadJob>>,
    results: &mpsc::Sender<DownloadResult>,
    slots: &Mutex<DownloadSlots>,
    cancelled: &AtomicBool,
    root_access: &Arc<SyncRootAccess>,
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
        let path = job.path.clone();
        if cancelled.load(Ordering::Acquire) {
            if results
                .send(DownloadResult {
                    path,
                    outcome: None,
                })
                .is_err()
            {
                return;
            }
            continue;
        }
        let outcome = run_download_job(dropbox, job, slots, root_access);
        if outcome.is_err() {
            cancelled.store(true, Ordering::Release);
        }
        if results
            .send(DownloadResult {
                path,
                outcome: Some(outcome),
            })
            .is_err()
        {
            return;
        }
    }
}

fn run_download_job(
    dropbox: &DropboxClient,
    mut job: DownloadJob,
    slots: &Mutex<DownloadSlots>,
    root_access: &Arc<SyncRootAccess>,
) -> Result<(), ReconcileError> {
    let (lease, reserved_slot) = match job.slot.take() {
        Some(lease) => {
            let slot = lease.slot();
            (Some(lease), Some(slot))
        }
        None => acquire_download_slot(&job, slots)?,
    };
    let outcome = dropbox
        .stage_worker_download_at(
            &job.root,
            &job.root_path,
            &job.path,
            &job.source,
            DownloadAccess {
                lease: lease.as_ref(),
                staging_directory: Some(&job.staging_directory),
                root_access,
            },
        )
        .map_err(|source| ReconcileError::RemoteDownload {
            path: job.path.clone(),
            source,
        })
        .and_then(|staged| match staged {
            StageOutcome::Staged(()) | StageOutcome::AlreadyStaged(()) => Ok(()),
            StageOutcome::ContentChanged { .. } => Err(ReconcileError::RemoteContentChanged {
                path: job.path.clone(),
            }),
            StageOutcome::DestinationOccupied { path } => {
                Err(ReconcileError::StageDestinationOccupied { path })
            }
        });
    if let Some(slot) = reserved_slot {
        release_download_slot(slots, slot)?;
    }
    outcome
}

fn acquire_download_slot(
    job: &DownloadJob,
    slots: &Mutex<DownloadSlots>,
) -> Result<(Option<DownloadSlotLease>, Option<u8>), ReconcileError> {
    for slot in 0_u8..MAX_PARALLEL_DOWNLOADS as u8 {
        let reserved = {
            let mut slots = slots
                .lock()
                .map_err(|_| ReconcileError::DownloadSlotCoordinatorUnavailable)?;
            slots.reserved.insert(slot)
        };
        if !reserved {
            continue;
        }
        match lease_download_slot(&job.staging_directory, slot, &job.slot_identity) {
            Ok(Some(lease)) => return Ok((Some(lease), Some(slot))),
            Ok(None) => release_download_slot(slots, slot)?,
            Err(source) => {
                release_download_slot(slots, slot)?;
                return Err(source.into());
            }
        }
    }
    Ok((None, None))
}

fn release_download_slot(slots: &Mutex<DownloadSlots>, slot: u8) -> Result<(), ReconcileError> {
    let mut slots = slots
        .lock()
        .map_err(|_| ReconcileError::DownloadSlotCoordinatorUnavailable)?;
    slots.reserved.remove(&slot);
    Ok(())
}

/// Replay durable work once while missing exact downloads continue on persistent workers.
pub fn replay_pending(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    downloads: &mut ExactDownloadPool,
    sync_root: impl AsRef<Path>,
    upload_staging: impl AsRef<Path>,
) -> Result<ReplayReport, ReconcileError> {
    replay_pending_at(
        journal,
        dropbox,
        downloads,
        sync_root.as_ref(),
        upload_staging.as_ref(),
    )
}

fn replay_pending_at(
    journal: &mut Journal,
    dropbox: &DropboxClient,
    download_pool: &mut ExactDownloadPool,
    sync_root: &Path,
    upload_staging: &Path,
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
            ReplayBlocked::DownloadRequired { path, .. }
                if download_pool.accepts_jobs() && !download_pool.contains(path) =>
            {
                Some(path.clone())
            }
            _ => None,
        })
        .collect::<BTreeSet<_>>();
    if missing_downloads.is_empty() && download_pool.is_empty() {
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
                slot_identity: DownloadSlotIdentity::new(
                    root_generation,
                    operation_id,
                    &path,
                    &source,
                ),
                path,
                source,
                slot: None,
            });
        }
        require_active_local_root(journal, sync_root)?;
        schedule_pending_downloads(
            download_pool,
            Arc::clone(&root),
            sync_root,
            upload_staging,
            downloads,
        )?;
    }
    require_active_local_root(journal, sync_root)?;
    let remote = replay_remote_operations_at(journal, dropbox, &root, sync_root, upload_staging)?;
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
    let published_local = journal.local_inventory()?;
    if let CaseCollisionResolution::Renamed(path) =
        resolve_case_collision(journal, sync_root, &published_local)?
    {
        return Ok(ReconcileOutcome::FreshObservationRequired { path });
    }
    let replay = replay_pending_at(journal, dropbox, downloads, sync_root, upload_staging)?;
    let scan = match downloads
        .root_access
        .with_exclusive(|| scan_and_publish(journal, sync_root))
    {
        Ok(ScanPublication::Published(scan)) => scan,
        Ok(ScanPublication::RootChanged) => return Err(ReconcileError::LocalRootChanged),
        Err(LocalError::ChangedDuringRead { path, .. }) => {
            return Ok(ReconcileOutcome::FreshObservationRequired { path });
        }
        Err(source) => return Err(ReconcileError::Local { source }),
    };
    match resolve_case_collision(journal, sync_root, scan.observations())? {
        CaseCollisionResolution::None => {}
        CaseCollisionResolution::Renamed(path) | CaseCollisionResolution::Changed(path) => {
            return Ok(ReconcileOutcome::FreshObservationRequired { path });
        }
    }
    dropbox.refresh_inventory(journal)?;
    require_active_local_root(journal, sync_root)?;
    reconcile_published(
        journal,
        scan.into_observations(),
        dropbox,
        sync_root,
        upload_staging,
        recovery_directory,
        replay,
        downloads,
    )
}

enum CaseCollisionResolution {
    None,
    Renamed(PathBuf),
    Changed(PathBuf),
}

fn resolve_case_collision(
    journal: &mut Journal,
    sync_root: &Path,
    observations: &[LocalObservationRecord],
) -> Result<CaseCollisionResolution, ReconcileError> {
    let Some(source) = case_variant_source(observations) else {
        return Ok(CaseCollisionResolution::None);
    };
    let Some(root) = open_active_root(journal, sync_root)? else {
        return Err(ReconcileError::LocalRootChanged);
    };
    let Some(name_max) = parent_name_max(&root, &source)? else {
        return Ok(CaseCollisionResolution::Changed(source));
    };
    let rename = case_variant_move(observations, source, name_max)?;
    let canonical_source = CanonicalPath::from_display(&rename.source);
    for pending in journal.pending_plans()? {
        let canonical_pending = CanonicalPath::from_display(&pending.path);
        if canonical_pending == canonical_source || canonical_pending.is_beneath(&canonical_source)
        {
            supersede_pending_plan(journal, &pending)?;
        }
    }
    journal.invalidate_case_collision_baselines(&rename.source)?;
    match rename_case_variant(&root, &rename.source, &rename.destination)? {
        LocalRenameOutcome::Renamed => Ok(CaseCollisionResolution::Renamed(rename.source)),
        LocalRenameOutcome::Retry => Ok(CaseCollisionResolution::Changed(rename.source)),
    }
}

#[allow(clippy::too_many_arguments)]
fn reconcile_published(
    journal: &mut Journal,
    local_observations: Vec<LocalObservationRecord>,
    dropbox: &DropboxClient,
    sync_root: &Path,
    upload_staging: &Path,
    recovery_directory: &Path,
    replay: ReplayReport,
    downloads: &mut ExactDownloadPool,
) -> Result<ReconcileOutcome, ReconcileError> {
    let local = local_map(local_observations)?;
    let remote = remote_map(journal.remote_inventory()?.observations);
    let pending = journal
        .pending_plans()?
        .into_iter()
        .map(|plan| (CanonicalPath::from_display(&plan.path), plan))
        .collect::<BTreeMap<_, _>>();
    let baselines = journal.baselines()?;
    let conflicts = journal
        .conflicts()?
        .into_iter()
        .map(|record| (CanonicalPath::from_display(&record.path), record))
        .collect::<Vec<_>>();
    let conflict_paths = conflicts
        .iter()
        .map(|(canonical_path, _)| canonical_path.clone())
        .collect::<BTreeSet<_>>();
    let mut report = ReconcileReport {
        replayed_operations: replay.completed_operations,
        ..ReconcileReport::default()
    };
    let mut sync_error_paths = replay
        .blocked
        .iter()
        .filter_map(|blocked| match blocked {
            ReplayBlocked::SyncError { path, .. } => Some(path.clone()),
            _ => None,
        })
        .collect::<BTreeSet<_>>();
    let mut noops = Vec::new();
    let mut decisions = Vec::new();
    for_each_known_path(
        baselines,
        &local,
        &remote,
        |canonical_path,
         baseline_record,
         local_record,
         remote_record|
         -> Result<(), ReconcileError> {
            let (baseline_path, baseline) = match baseline_record {
                Some((path, baseline)) => (Some(path), baseline),
                None => (None, Baseline::Absent),
            };
            let unobserved_local;
            let local_observation = match local_record {
                Some(record) => &record.observation,
                None => {
                    unobserved_local = local_unobserved(&local, canonical_path);
                    &unobserved_local
                }
            };
            let unobserved_remote;
            let remote_observation = match remote_record {
                Some(record) => &record.observation,
                None => {
                    unobserved_remote = remote_unobserved(&remote, canonical_path);
                    &unobserved_remote
                }
            };
            let path = local_record
                .map(|record| record.path.clone())
                .or_else(|| remote_record.map(|record| record.path.clone()))
                .or(baseline_path)
                .ok_or_else(|| {
                    invalid(
                        canonical_path.as_path(),
                        "canonical path has no display spelling",
                    )
                })?;
            let decision = plan(&baseline, local_observation, remote_observation);
            let baseline_matches_noop = matches!(
                &decision,
                Decision::NoOp(noop) if &baseline == noop.baseline()
            );
            match decision {
                Decision::NoOp(noop) if !pending.contains_key(canonical_path) => {
                    if baseline_matches_noop && !conflict_paths.contains(canonical_path) {
                        report.noops += 1;
                    } else {
                        noops.push((path, noop));
                    }
                }
                decision => decisions.push(PathDecision {
                    canonical_path: canonical_path.clone(),
                    path,
                    baseline_matches_noop,
                    decision,
                }),
            }
            Ok(())
        },
    )?;
    decisions.sort_by(order_path_decisions);
    let mut blocked_paths = BTreeSet::new();
    let mut plans = Vec::new();

    for PathDecision {
        canonical_path,
        path,
        baseline_matches_noop,
        decision,
    } in decisions
    {
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
            } else if matches!(decision, Decision::DirectoryCollision(_)) {
                supersede_pending_plan(journal, pending_plan)?;
                return Ok(ReconcileOutcome::FreshObservationRequired { path });
            } else {
                blocked_paths.insert(canonical_path.clone());
            }
            continue;
        }

        match decision {
            Decision::NoOp(noop) => {
                if baseline_matches_noop && !conflict_paths.contains(&canonical_path) {
                    report.noops += 1;
                } else {
                    noops.push((path, noop));
                }
            }
            Decision::Blocked(_) => {
                blocked_paths.insert(canonical_path.clone());
            }
            Decision::Operations(plan) => {
                match prepare_plan(sync_root, upload_staging, &path, plan.operations())? {
                    Prepared::Ready(()) => {}
                    Prepared::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                }
                require_active_local_root(journal, sync_root)?;
                plans.push((path, plan));
            }
            Decision::Conflict(conflict) => {
                match prepare_conflict(dropbox, sync_root, upload_staging, &path, &conflict)? {
                    Prepared::Ready(()) => {}
                    Prepared::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                }
                if !conflicts.iter().any(|(existing, record)| {
                    *existing == canonical_path && record.conflict == conflict
                }) {
                    journal.record_conflict(&path, &conflict)?;
                    report.conflicts += 1;
                }
            }
            Decision::DirectoryCollision(collision) => {
                match prepare_directory_collision(
                    dropbox,
                    journal,
                    sync_root,
                    upload_staging,
                    &local,
                    &remote,
                    &path,
                    &collision,
                )? {
                    PreparedDirectoryCollision::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                    PreparedDirectoryCollision::Plan(plan) => {
                        require_active_local_root(journal, sync_root)?;
                        plans.push((path, plan));
                    }
                }
            }
        }
    }
    let write = journal.record_reconciliation(&noops, &plans)?;
    report.noops += write.recorded_noops;
    report.planned += write.recorded_plans;
    blocked_paths.extend(
        write
            .live_paths
            .into_iter()
            .map(|path| CanonicalPath::from_display(&path)),
    );
    let applied = replay_pending_at(journal, dropbox, downloads, sync_root, upload_staging)?;
    report.replayed_operations += applied.completed_operations;
    sync_error_paths.extend(applied.blocked.iter().filter_map(|blocked| match blocked {
        ReplayBlocked::SyncError { path, .. } => Some(path.clone()),
        _ => None,
    }));
    if let Some(path) = applied.blocked.iter().find_map(|blocked| match blocked {
        ReplayBlocked::FreshObservationRequired { path } => Some(path.clone()),
        _ => None,
    }) {
        return Ok(ReconcileOutcome::FreshObservationRequired { path });
    }
    journal.prune_completed_work()?;
    prune_completed_recoveries(journal, recovery_directory)?;
    let retained_uploads = journal.pending_upload_content()?;
    let pending = journal.pending_plans()?;
    blocked_paths.extend(
        pending
            .into_iter()
            .map(|plan| CanonicalPath::from_display(&plan.path)),
    );
    report.blocked = blocked_paths.len();
    report.sync_errors = sync_error_paths.len();
    report.downloads_in_progress = !downloads.is_empty();
    remove_unreferenced_upload_stages(upload_staging, &retained_uploads)?;
    Ok(ReconcileOutcome::Complete(report))
}

struct PathDecision {
    canonical_path: CanonicalPath,
    path: PathBuf,
    baseline_matches_noop: bool,
    decision: Decision,
}

fn order_path_decisions(left: &PathDecision, right: &PathDecision) -> std::cmp::Ordering {
    let left_delete = is_local_directory_delete(&left.decision);
    let right_delete = is_local_directory_delete(&right.decision);
    match (left_delete, right_delete) {
        (true, true) => path_depth(&right.path)
            .cmp(&path_depth(&left.path))
            .then_with(|| left.canonical_path.cmp(&right.canonical_path)),
        (true, false) => std::cmp::Ordering::Greater,
        (false, true) => std::cmp::Ordering::Less,
        (false, false) => path_depth(&left.path)
            .cmp(&path_depth(&right.path))
            .then_with(|| left.canonical_path.cmp(&right.canonical_path)),
    }
}

fn is_local_directory_delete(decision: &Decision) -> bool {
    matches!(
        decision,
        Decision::Operations(plan)
            if plan.operations() == [Operation::DeleteLocalDirectory]
    )
}

fn path_depth(path: &Path) -> usize {
    path.components().count()
}

enum Prepared<T> {
    Ready(T),
    FreshObservation,
}

fn prepare_plan(
    sync_root: &Path,
    upload_staging: &Path,
    path: &Path,
    operations: &[Operation],
) -> Result<Prepared<()>, ReconcileError> {
    for operation in operations {
        match operation {
            Operation::CreateLocalDirectory
            | Operation::CreateRemoteDirectory
            | Operation::DeleteLocalDirectory => {}
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
            Operation::PreserveRemote { .. } | Operation::PreserveLocal { .. } => {}
            Operation::DeleteLocal { .. } | Operation::DeleteRemote { .. } => {}
        }
    }
    Ok(Prepared::Ready(()))
}

enum PreparedDirectoryCollision {
    FreshObservation,
    Plan(OperationPlan),
}

#[derive(Clone, Copy)]
enum FileCopyOrigin {
    Local,
    Dropbox,
}

#[allow(clippy::too_many_arguments)]
fn prepare_directory_collision(
    dropbox: &DropboxClient,
    journal: &Journal,
    sync_root: &Path,
    upload_staging: &Path,
    local: &[(CanonicalPath, LocalObservationRecord)],
    remote: &[RemoteObservationRecord],
    path: &Path,
    collision: &DirectoryCollision,
) -> Result<PreparedDirectoryCollision, ReconcileError> {
    let Some(root) = open_active_root(journal, sync_root)? else {
        return Err(ReconcileError::LocalRootChanged);
    };
    let Some(name_max) = parent_name_max(&root, path)? else {
        return Ok(PreparedDirectoryCollision::FreshObservation);
    };
    match collision {
        DirectoryCollision::LocalFileRemoteDirectory { local: file } => {
            let excluded = BTreeSet::new();
            let destination = file_copy_path(
                local,
                remote,
                path,
                &file.content,
                FileCopyOrigin::Local,
                name_max,
                false,
                &excluded,
            )?;
            match rename_file_copy(&root, path, &destination)? {
                LocalRenameOutcome::Renamed | LocalRenameOutcome::Retry => {
                    Ok(PreparedDirectoryCollision::FreshObservation)
                }
            }
        }
        DirectoryCollision::LocalDirectoryRemoteFile { remote: file } => {
            let mut excluded = BTreeSet::new();
            loop {
                let destination = file_copy_path(
                    local,
                    remote,
                    path,
                    &file.content,
                    FileCopyOrigin::Dropbox,
                    name_max,
                    true,
                    &excluded,
                )?;
                match materialize_remote_copy_at(
                    dropbox,
                    &root,
                    sync_root,
                    &destination,
                    path,
                    file,
                )? {
                    ExactCopyOutcome::Ready => break,
                    ExactCopyOutcome::DestinationChanged => {
                        return Ok(PreparedDirectoryCollision::FreshObservation);
                    }
                    ExactCopyOutcome::StageOccupied => {
                        excluded.insert(destination);
                    }
                }
            }
            let plan = OperationPlan::new(vec![
                Operation::DeleteRemote {
                    expected_revision: file.revision.clone(),
                },
                Operation::CreateRemoteDirectory,
            ]);
            match prepare_plan(sync_root, upload_staging, path, plan.operations())? {
                Prepared::Ready(()) => Ok(PreparedDirectoryCollision::Plan(plan)),
                Prepared::FreshObservation => Ok(PreparedDirectoryCollision::FreshObservation),
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn file_copy_path(
    local: &[(CanonicalPath, LocalObservationRecord)],
    remote: &[RemoteObservationRecord],
    source: &Path,
    content: &ContentIdentity,
    origin: FileCopyOrigin,
    name_max: usize,
    reuse_matching: bool,
    excluded: &BTreeSet<PathBuf>,
) -> Result<PathBuf, ReconcileError> {
    let Some(name) = source.file_name() else {
        return Err(invalid(
            source,
            "directory collision has no final path component",
        ));
    };
    let Some(parent) = source.parent() else {
        return Err(invalid(source, "directory collision has no parent path"));
    };
    for attempt in 0..10_000 {
        let Some(candidate_name) = file_copy_name(name, content, origin, attempt, name_max) else {
            break;
        };
        let candidate = parent.join(candidate_name);
        if excluded.contains(&candidate) {
            continue;
        }
        let canonical = CanonicalPath::from_display(&candidate);
        let local_record = find_local(local, &canonical);
        let remote_record = find_remote(remote, &canonical);
        if local_record.is_none() && remote_record.is_none() {
            return Ok(candidate);
        }
        let local_matches = local_record.is_none_or(|record| {
            matches!(
                &record.observation,
                Observation::Present(file) if &file.content == content
            )
        });
        let remote_matches = remote_record.is_none_or(|record| {
            matches!(
                &record.observation,
                Observation::Present(file) if &file.content == content
            )
        });
        if reuse_matching && local_matches && remote_matches {
            return Ok(candidate);
        }
    }
    Err(invalid(
        source,
        "could not select a unique synchronized file-copy path",
    ))
}

fn file_copy_name(
    name: &OsStr,
    content: &ContentIdentity,
    origin: FileCopyOrigin,
    attempt: usize,
    name_max: usize,
) -> Option<OsString> {
    let mut identity = content
        .as_str()
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(12)
        .collect::<String>();
    if identity.is_empty() {
        identity.push_str("content");
    }
    let origin = match origin {
        FileCopyOrigin::Local => "local file",
        FileCopyOrigin::Dropbox => "Dropbox file",
    };
    let suffix = if attempt == 0 {
        format!(" ({origin} {identity})")
    } else {
        format!(" ({origin} {identity} {})", attempt.saturating_add(1))
    };
    let prefix_limit = name_max.checked_sub(suffix.len())?;
    let mut candidate = truncate_component(name, prefix_limit);
    candidate.push(suffix);
    Some(candidate)
}

fn supersede_pending_plan(
    journal: &mut Journal,
    pending: &PlanRecord,
) -> Result<(), ReconcileError> {
    match journal.supersede_plan(pending.id)? {
        PlanSupersede::Superseded | PlanSupersede::AlreadyCompleted => Ok(()),
        PlanSupersede::NotFound => Err(invalid(&pending.path, "stale pending plan disappeared")),
    }
}

struct PendingDownload {
    path: PathBuf,
    source: RemoteFile,
    slot_identity: DownloadSlotIdentity,
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
    downloads: &mut [PendingDownload],
) -> Result<(), ReconcileError> {
    let identities = downloads
        .iter()
        .map(|download| download.slot_identity.clone())
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
    mut downloads: Vec<PendingDownload>,
) -> Result<(), ReconcileError> {
    lease_pending_downloads(upload_staging, &mut downloads)?;
    downloads.sort_by_key(|download| download.slot.is_none());
    for download in downloads {
        if pool.contains(&download.path) {
            continue;
        }
        pool.schedule(DownloadJob {
            root: Arc::clone(&root),
            root_path: root_path.to_path_buf(),
            staging_directory: upload_staging.to_path_buf(),
            path: download.path,
            source: download.source,
            slot_identity: download.slot_identity,
            slot: download.slot,
        })?;
    }
    Ok(())
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
            Err(source) if upload_source_changed(&source, path) => Ok(Prepared::FreshObservation),
            Err(source) => Err(ReconcileError::Local { source }),
        },
        Ok(StageOutcome::ContentChanged { .. }) => Ok(Prepared::FreshObservation),
        Ok(StageOutcome::DestinationOccupied { path }) => {
            Err(ReconcileError::StageDestinationOccupied { path })
        }
        Err(source) if upload_source_changed(&source, path) => Ok(Prepared::FreshObservation),
        Err(source) => Err(ReconcileError::Local { source }),
    }
}

fn require_active_local_root(journal: &Journal, sync_root: &Path) -> Result<(), ReconcileError> {
    if configured_root_is_active(journal, sync_root)? {
        Ok(())
    } else {
        Err(ReconcileError::LocalRootChanged)
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
) -> Result<Vec<(CanonicalPath, LocalObservationRecord)>, ReconcileError> {
    let mut mapped = Vec::with_capacity(records.len());
    for record in records {
        let canonical_path = CanonicalPath::from_display(&record.path);
        mapped.push((canonical_path, record));
    }
    mapped.sort_by(|(left_canonical, left), (right_canonical, right)| {
        left_canonical
            .cmp(right_canonical)
            .then_with(|| left.path.cmp(&right.path))
    });
    for pair in mapped.windows(2) {
        let [(first_canonical, first), (second_canonical, second)] = pair else {
            continue;
        };
        if first_canonical == second_canonical {
            return Err(ReconcileError::LocalCaseCollision {
                first: first.path.clone(),
                second: second.path.clone(),
            });
        }
    }
    Ok(mapped)
}

/// Observation for a local path the scan published no record for.
fn local_unobserved(
    local: &[(CanonicalPath, LocalObservationRecord)],
    canonical_path: &CanonicalPath,
) -> LocalObservation {
    unobserved(ancestor_unknown(
        local,
        canonical_path,
        |(canonical_path, _)| canonical_path,
        |(_, record)| observed_unknown(&record.observation),
    ))
}

/// Observation for a remote path the durable listing holds no record for.
fn remote_unobserved(
    remote: &[RemoteObservationRecord],
    canonical_path: &CanonicalPath,
) -> RemoteObservation {
    unobserved(ancestor_unknown(
        remote,
        canonical_path,
        |record| &record.canonical_path,
        |record| observed_unknown(&record.observation),
    ))
}

/// Observation for a path one side holds no record for.
///
/// A missing record only proves absence when every ancestor was observed
/// completely. Beneath an unknown directory the scan or the listing never
/// looked, so the path inherits that reason and the planner blocks instead of
/// inferring a deletion from state nobody observed.
fn unobserved<T>(reason: Option<UnknownReason>) -> Observation<T> {
    match reason {
        Some(reason) => Observation::Unknown(reason),
        None => Observation::ConfirmedAbsent,
    }
}

/// Reason held by any recorded ancestor that was not observed completely.
///
/// A missing record proves absence only when every ancestor above it was
/// observed completely, so the walk climbs to the root rather than stopping at
/// the first ancestor that happens to have a record. Whichever producer put a
/// record beneath an unknown directory, it can never turn that directory's
/// descendants back into confirmed absence.
///
/// Records are sorted by canonical bytes, so each ancestor is one binary
/// search over the byte prefix ending at a separator.
fn ancestor_unknown<T>(
    records: &[T],
    canonical_path: &CanonicalPath,
    key: impl Fn(&T) -> &CanonicalPath,
    reason: impl Fn(&T) -> Option<UnknownReason>,
) -> Option<UnknownReason> {
    let mut ancestor = parent_bytes(canonical_path.as_bytes());
    while let Some(bytes) = ancestor {
        if let Ok(index) = records.binary_search_by(|record| key(record).as_bytes().cmp(bytes))
            && let Some(found) = records.get(index).and_then(&reason)
        {
            return Some(found);
        }
        ancestor = parent_bytes(bytes);
    }
    None
}

/// Canonical bytes of a path's parent, or `None` at a path with no parent.
///
/// Splitting from the right yields the last component first, so the remainder
/// is the parent and its absence ends the climb. No index is computed, so the
/// walk cannot end early on arithmetic that fails open into absence.
fn parent_bytes(path: &[u8]) -> Option<&[u8]> {
    path.rsplitn(2, |byte| *byte == b'/').nth(1)
}

fn observed_unknown<T>(observation: &Observation<T>) -> Option<UnknownReason> {
    match observation {
        Observation::Unknown(reason) => Some(*reason),
        Observation::Present(_) | Observation::Directory | Observation::ConfirmedAbsent => None,
    }
}

fn find_local<'a>(
    records: &'a [(CanonicalPath, LocalObservationRecord)],
    canonical_path: &CanonicalPath,
) -> Option<&'a LocalObservationRecord> {
    let Ok(index) = records.binary_search_by(|(path, _)| path.cmp(canonical_path)) else {
        return None;
    };
    records.get(index).map(|(_, record)| record)
}

#[derive(Debug, Eq, PartialEq)]
struct CaseVariantMove {
    source: PathBuf,
    destination: PathBuf,
}

fn case_variant_source(records: &[LocalObservationRecord]) -> Option<PathBuf> {
    let mut spellings = BTreeMap::<CanonicalPath, BTreeSet<PathBuf>>::new();
    for record in records {
        let canonical = CanonicalPath::from_display(&record.path);
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
        .map(|record| CanonicalPath::from_display(&record.path))
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
        if !occupied.contains(&CanonicalPath::from_display(&destination)) {
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

fn remote_map(mut records: Vec<RemoteObservationRecord>) -> Vec<RemoteObservationRecord> {
    records.sort_by(|left, right| left.canonical_path.cmp(&right.canonical_path));
    records
}

fn find_remote<'a>(
    records: &'a [RemoteObservationRecord],
    canonical_path: &CanonicalPath,
) -> Option<&'a RemoteObservationRecord> {
    let Ok(index) = records.binary_search_by(|record| record.canonical_path.cmp(canonical_path))
    else {
        return None;
    };
    records.get(index)
}

/// Visit every path any side knows once, in canonical order.
///
/// The visited path is borrowed: an idle pass decides a no-op for nearly every
/// path and must not allocate one canonical path per decision. The baseline's
/// own copy of the key is reused when the baseline is the merge minimum, so no
/// step clones.
fn for_each_known_path<E>(
    baselines: Vec<BaselineRecord>,
    local: &[(CanonicalPath, LocalObservationRecord)],
    remote: &[RemoteObservationRecord],
    mut visit: impl FnMut(
        &CanonicalPath,
        Option<(PathBuf, Baseline)>,
        Option<&LocalObservationRecord>,
        Option<&RemoteObservationRecord>,
    ) -> Result<(), E>,
) -> Result<(), E> {
    let mut baselines = baselines.into_iter().peekable();
    let mut local_index = 0;
    let mut remote_index = 0;
    loop {
        let side_minimum = [
            local
                .get(local_index)
                .map(|(canonical_path, _)| canonical_path),
            remote
                .get(remote_index)
                .map(|record| &record.canonical_path),
        ]
        .into_iter()
        .flatten()
        .min();
        let baseline_leads = match (baselines.peek(), side_minimum) {
            (Some(record), Some(minimum)) => &record.canonical_path <= minimum,
            (Some(_), None) => true,
            (None, _) => false,
        };
        let (baseline_key, baseline) = match baseline_leads.then(|| baselines.next()).flatten() {
            Some(record) => (
                Some(record.canonical_path),
                Some((record.path, record.baseline)),
            ),
            None => (None, None),
        };
        let canonical_path = match (baseline_key.as_ref(), side_minimum) {
            (Some(key), _) => key,
            (None, Some(minimum)) => minimum,
            (None, None) => return Ok(()),
        };
        let local_record = local
            .get(local_index)
            .and_then(|(path, record)| (path == canonical_path).then_some(record));
        if local_record.is_some() {
            local_index += 1;
        }
        let remote_record = remote
            .get(remote_index)
            .and_then(|record| (&record.canonical_path == canonical_path).then_some(record));
        if remote_record.is_some() {
            remote_index += 1;
        }
        visit(canonical_path, baseline, local_record, remote_record)?;
    }
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
                CanonicalPath::from_display(&record.path)
                    != CanonicalPath::from_display(&forward.destination)
            });
            prop_assert!(destination_is_unique);
        }

        #[test]
        fn known_path_merge_matches_set_union(
            baseline_names in prop::collection::btree_set("[a-z./ -]{1,12}", 0..24),
            local_names in prop::collection::btree_set("[a-z./ -]{1,12}", 0..24),
            remote_names in prop::collection::btree_set("[a-z./ -]{1,12}", 0..24),
        ) {
            let baseline_paths = merge_paths(&baseline_names);
            let local_paths = merge_paths(&local_names);
            let remote_paths = merge_paths(&remote_names);
            let state = TempDir::new().map_err(|error| TestCaseError::fail(error.to_string()))?;
            let mut journal = Journal::open(state.path().join("journal.sqlite3"))
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            seed_directory_baselines(&mut journal, &baseline_paths)
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            let baselines = journal
                .baselines()
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            prop_assert_eq!(baselines.len(), baseline_paths.len());
            let local = local_map(local_records(local_paths.iter().cloned()))
                .map_err(|error| TestCaseError::fail(error.to_string()))?;
            let remote = remote_paths
                .iter()
                .map(|path| RemoteObservationRecord {
                    canonical_path: CanonicalPath::from_display(path),
                    path: path.clone(),
                    observation: Observation::Directory,
                })
                .collect::<Vec<_>>();
            let remote = remote_map(remote);
            let mut merged = Vec::new();
            for_each_known_path(
                baselines,
                &local,
                &remote,
                |path, baseline, local, remote| -> Result<(), TestCaseError> {
                    let display = path.as_path();
                    prop_assert_eq!(baseline.is_some(), baseline_paths.contains(display));
                    prop_assert_eq!(local.is_some(), local_paths.contains(display));
                    prop_assert_eq!(remote.is_some(), remote_paths.contains(display));
                    merged.push(path.clone());
                    Ok(())
                },
            )?;
            let mut expected = baseline_paths
                .iter()
                .chain(&local_paths)
                .chain(&remote_paths)
                .map(|path| CanonicalPath::from_display(path))
                .collect::<Vec<_>>();
            expected.sort_by(|left, right| {
                left.as_bytes().cmp(right.as_bytes())
            });
            expected.dedup();
            prop_assert_eq!(merged, expected);
        }
    }

    fn merge_path(raw: &str) -> Option<PathBuf> {
        let mut path = PathBuf::new();
        for component in raw.split('/') {
            if component.is_empty() || component == "." || component == ".." {
                continue;
            }
            path.push(component);
        }
        (!path.as_os_str().is_empty()).then_some(path)
    }

    fn merge_paths(raw: &BTreeSet<String>) -> BTreeSet<PathBuf> {
        raw.iter()
            .map(String::as_str)
            .filter_map(merge_path)
            .collect()
    }

    fn seed_directory_baselines(
        journal: &mut Journal,
        paths: &BTreeSet<PathBuf>,
    ) -> Result<(), Box<dyn Error>> {
        let Decision::NoOp(noop) = plan(
            &Baseline::Directory,
            &Observation::Directory,
            &Observation::Directory,
        ) else {
            return Err(io::Error::other("matching directories were not a no-op").into());
        };
        for path in paths {
            if journal.record_noop(path, &noop)? != crate::journal::NoOpWrite::Recorded {
                return Err(io::Error::other("directory baseline was not recorded").into());
            }
        }
        Ok(())
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
    fn file_copy_name_is_deterministic_and_fits_the_parent_limit() -> Result<(), Box<dyn Error>> {
        let original = OsString::from("a".repeat(255));
        let content = ContentIdentity::new("b".repeat(64));
        let Some(first) = file_copy_name(&original, &content, FileCopyOrigin::Dropbox, 0, 255)
        else {
            return Err(io::Error::other("file-copy name did not fit").into());
        };
        let Some(second) = file_copy_name(&original, &content, FileCopyOrigin::Dropbox, 0, 255)
        else {
            return Err(io::Error::other("repeated file-copy name did not fit").into());
        };
        assert_eq!(first, second);
        assert_eq!(first.as_bytes().len(), 255);
        assert!(first.as_bytes().ends_with(b" (Dropbox file bbbbbbbbbbbb)"));
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

    use crate::journal::{NoOpWrite, PlanWrite};
    use crate::model::{BlockedReason, ContentIdentity, DropboxRevision, LocalFile, RemoteFile};

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

    fn canonical(path: &str) -> CanonicalPath {
        CanonicalPath::from_display(Path::new(path))
    }

    fn local_side(
        records: impl IntoIterator<Item = (PathBuf, LocalObservation)>,
    ) -> Result<Vec<(CanonicalPath, LocalObservationRecord)>, ReconcileError> {
        local_map(
            records
                .into_iter()
                .map(|(path, observation)| LocalObservationRecord { path, observation })
                .collect(),
        )
    }

    fn remote_side(
        records: impl IntoIterator<Item = (PathBuf, RemoteObservation)>,
    ) -> Vec<RemoteObservationRecord> {
        remote_map(
            records
                .into_iter()
                .map(|(path, observation)| RemoteObservationRecord {
                    canonical_path: CanonicalPath::from_display(&path),
                    path,
                    observation,
                })
                .collect(),
        )
    }

    fn present_locally(bytes: &[u8]) -> Result<LocalObservation, Box<dyn Error>> {
        Ok(Observation::Present(LocalFile::new(identity(bytes)?)))
    }

    #[test]
    fn a_path_below_an_unknown_directory_inherits_its_reason() -> Result<(), Box<dyn Error>> {
        let local = local_side([
            (
                PathBuf::from("locked"),
                Observation::Unknown(UnknownReason::Inaccessible),
            ),
            (PathBuf::from("open"), Observation::Directory),
            (PathBuf::from("open/kept.txt"), present_locally(b"kept")?),
        ])?;

        for path in ["locked/secret.txt", "Locked/Deep/Deeper.TXT"] {
            assert_eq!(
                local_unobserved(&local, &canonical(path)),
                Observation::Unknown(UnknownReason::Inaccessible),
                "{path} did not inherit the unknown directory"
            );
        }
        for path in ["gone.txt", "open/gone.txt", "open/kept.txt/below"] {
            assert_eq!(
                local_unobserved(&local, &canonical(path)),
                Observation::ConfirmedAbsent,
                "{path} was not confirmed absent"
            );
        }
        Ok(())
    }

    #[test]
    fn a_record_below_an_unknown_directory_cannot_restore_absence() -> Result<(), Box<dyn Error>> {
        // Some producer listed `volume/listed` even though `volume` itself was
        // never observed completely. Stopping the climb at the first ancestor
        // that happens to hold a record would read the rest of that subtree as
        // absent and delete it; the rule therefore climbs to the root.
        let remote = remote_side([
            (
                PathBuf::from("volume"),
                Observation::Unknown(UnknownReason::Unsupported),
            ),
            (PathBuf::from("volume/listed"), Observation::Directory),
        ]);

        for path in [
            "volume/gone.txt",
            "volume/listed/gone.txt",
            "volume/listed/deeper/gone.txt",
        ] {
            assert_eq!(
                remote_unobserved(&remote, &canonical(path)),
                Observation::Unknown(UnknownReason::Unsupported),
                "{path} was read as absent below an unknown directory"
            );
        }

        // With every ancestor observed completely the same paths are absent.
        let complete = remote_side([
            (PathBuf::from("volume"), Observation::Directory),
            (PathBuf::from("volume/listed"), Observation::Directory),
        ]);
        for path in ["volume/gone.txt", "volume/listed/deeper/gone.txt"] {
            assert_eq!(
                remote_unobserved(&complete, &canonical(path)),
                Observation::ConfirmedAbsent,
                "{path} was not confirmed absent below a complete listing"
            );
        }
        Ok(())
    }

    #[test]
    fn names_that_neighbor_the_separator_are_not_ancestors() -> Result<(), Box<dyn Error>> {
        let unreadable = OsString::from_vec(b"unreadable\xff".to_vec());
        let local = local_side([
            (
                PathBuf::from("report"),
                Observation::Unknown(UnknownReason::Incomplete),
            ),
            (PathBuf::from("report.txt"), present_locally(b"report")?),
            (PathBuf::from("report0"), Observation::Directory),
            (
                PathBuf::from(&unreadable),
                Observation::Unknown(UnknownReason::Inaccessible),
            ),
        ])?;

        for path in ["report/x", "REPORT/x/y"] {
            assert_eq!(
                local_unobserved(&local, &canonical(path)),
                Observation::Unknown(UnknownReason::Incomplete),
                "{path} did not inherit the incomplete directory"
            );
        }
        let below_unreadable = OsString::from_vec([unreadable.as_bytes(), b"/x"].concat());
        assert_eq!(
            local_unobserved(
                &local,
                &CanonicalPath::from_display(Path::new(&below_unreadable))
            ),
            Observation::Unknown(UnknownReason::Inaccessible)
        );
        for path in [
            "report.txt/x",
            "report0/x",
            "reportx/y",
            "report",
            "unreadable/x",
        ] {
            assert_eq!(
                local_unobserved(&local, &canonical(path)),
                Observation::ConfirmedAbsent,
                "{path} borrowed a reason from a name that is not its ancestor"
            );
        }
        Ok(())
    }

    #[test]
    fn an_unknown_ancestor_blocks_a_deletion_on_either_side() -> Result<(), Box<dyn Error>> {
        let file = RemoteFile::new(identity(b"secret")?, DropboxRevision::new("rev-secret"));
        let baseline = Baseline::Present(file.clone());
        let below = canonical("locked/secret.txt");
        for reason in [
            UnknownReason::Inaccessible,
            UnknownReason::Unsupported,
            UnknownReason::Incomplete,
        ] {
            let unknown_local =
                local_side([(PathBuf::from("locked"), Observation::Unknown(reason))])?;
            let listed_remote = remote_side([
                (PathBuf::from("locked"), Observation::Directory),
                (
                    PathBuf::from("locked/secret.txt"),
                    Observation::Present(file.clone()),
                ),
            ]);
            let decision = plan(
                &baseline,
                &local_unobserved(&unknown_local, &below),
                &match find_remote(&listed_remote, &below) {
                    Some(record) => record.observation.clone(),
                    None => remote_unobserved(&listed_remote, &below),
                },
            );
            assert!(
                matches!(
                    decision,
                    Decision::Blocked(BlockedReason::LocalUnknown(blocked)) if blocked == reason
                ),
                "an unreadable local directory planned {decision:?} for a path beneath it"
            );

            let scanned_local = local_side([
                (PathBuf::from("locked"), Observation::Directory),
                (
                    PathBuf::from("locked/secret.txt"),
                    present_locally(b"secret")?,
                ),
            ])?;
            let unknown_remote =
                remote_side([(PathBuf::from("locked"), Observation::Unknown(reason))]);
            let decision = plan(
                &baseline,
                &match find_local(&scanned_local, &below) {
                    Some(record) => record.observation.clone(),
                    None => local_unobserved(&scanned_local, &below),
                },
                &remote_unobserved(&unknown_remote, &below),
            );
            assert!(
                matches!(
                    decision,
                    Decision::Blocked(BlockedReason::RemoteUnknown(blocked)) if blocked == reason
                ),
                "an unknown Dropbox directory planned {decision:?} for a path beneath it"
            );
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
            PlanWrite::AlreadyLive(_) => {
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
