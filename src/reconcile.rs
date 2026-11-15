//! One finite observe, plan, and journal pass.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString};
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{SystemTime, SystemTimeError, UNIX_EPOCH};

use rustix::fd::OwnedFd;
use thiserror::Error;

use crate::dropbox::{DownloadAccess, DropboxClient, DropboxError};
use crate::exclusions::is_excluded;
use crate::journal::{
    BLOCK_RETRY_SECONDS, BaselineRecord, BlockReason, Journal, JournalError,
    LocalObservationRecord, OperationId, PlanBlock, PlanConflictCompletion, PlanId, PlanRecord,
    PlanStatus, PlanSupersede, PlanUnblock, RecordStatus, RemoteObservationRecord,
};
use crate::local::{
    DownloadSlotIdentity, DownloadSlotLease, LocalError, LocalRenameOutcome,
    MAX_PARALLEL_DOWNLOADS, ScanPublication, StageOutcome, StagedUpload, SyncRootAccess,
    configured_root_is_active, entry_exists_at, lease_download_slots, observe_upload_source,
    open_active_root, parent_name_max, remove_unreferenced_upload_stages, rename_case_variant,
    rename_file_copy, scan_and_publish, stage_upload, upload_source_changed,
};
use crate::model::{
    Baseline, BlockedReason, CanonicalPath, Conflict, ContentIdentity, Decision,
    DirectoryCollision, LocalObservation, Observation, Operation, OperationPlan, RemoteFile,
    RemoteObservation, RemoteSubtree, UnknownReason,
};
use crate::planner::plan;
use crate::recovery::{
    CopyOutcome, ExactCopyOutcome, RecoveryError, ReplayBlocked, ReplayReport,
    materialize_local_conflict, materialize_remote_conflict, materialize_remote_copy_at,
    prune_completed_recoveries, replay_local_plans_at, replay_remote_operations_at,
    retire_excluded_plans,
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
    /// The retry deadline could not be derived from the system clock.
    #[error("could not read the system clock for a download retry deadline")]
    Clock {
        /// Original system clock failure.
        #[source]
        source: SystemTimeError,
    },
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
    scheduled: BTreeMap<PathBuf, DownloadIdentity>,
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
            scheduled: BTreeMap::new(),
            pending_failure: None,
            slots,
            cancelled,
            root_access,
            workers,
        })
    }

    fn collect_results(&mut self) -> Result<CollectedDownloads, ReconcileError> {
        let mut collected = CollectedDownloads::default();
        loop {
            match self.results.try_recv() {
                Ok(result) => {
                    if self.scheduled.get(&result.path) == Some(&result.identity) {
                        self.scheduled.remove(&result.path);
                    }
                    match result.outcome {
                        DownloadOutcome::Completed | DownloadOutcome::Cancelled => {}
                        DownloadOutcome::Blocked(reason) => {
                            collected.blocked.push(BlockedDownload {
                                path: result.path,
                                identity: result.identity,
                                reason,
                            });
                        }
                        DownloadOutcome::Failed(error) if self.pending_failure.is_none() => {
                            self.pending_failure = Some(error);
                        }
                        DownloadOutcome::Failed(_) => {}
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
            collected.failure = self.pending_failure.take();
        }
        if self.workers.iter().any(thread::JoinHandle::is_finished) {
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        Ok(collected)
    }

    fn contains(&self, path: &Path) -> bool {
        self.scheduled.contains_key(path)
    }

    fn contains_plan(&self, plan: &PlanRecord) -> bool {
        let Some(identity) = pending_download_identity(plan) else {
            return false;
        };
        self.scheduled.get(&plan.path) == Some(&identity)
    }

    fn is_empty(&self) -> bool {
        self.scheduled.is_empty()
    }

    fn accepts_jobs(&self) -> bool {
        self.pending_failure.is_none() && !self.cancelled.load(Ordering::Acquire)
    }

    fn lease_and_schedule(
        &mut self,
        root: Arc<OwnedFd>,
        root_path: &Path,
        staging_directory: &Path,
        mut downloads: Vec<PendingDownload>,
        live_bindings: BTreeSet<[u8; 32]>,
    ) -> Result<(), ReconcileError> {
        downloads.retain(|download| !self.contains(&download.path));
        {
            let mut slots = self
                .slots
                .lock()
                .map_err(|_| ReconcileError::DownloadSlotCoordinatorUnavailable)?;
            slots.live = live_bindings;
            let identities = downloads
                .iter()
                .map(|download| download.slot_identity.clone())
                .collect::<Vec<_>>();
            let leases = lease_download_slots(staging_directory, &identities, |binding| {
                slots.protects(binding)
            })?;
            for (download, lease) in downloads.iter_mut().zip(leases) {
                let Some(lease) = lease else {
                    continue;
                };
                let binding = download.slot_identity.binding();
                if !slots.active.insert(binding) {
                    return Err(invalid(
                        &download.path,
                        "resumable download binding was assigned twice",
                    ));
                }
                download.slot = Some(LeasedDownloadSlot {
                    lease,
                    _reservation: DownloadSlotReservation {
                        slots: Arc::clone(&self.slots),
                        binding,
                    },
                });
            }
        }
        downloads.sort_by_key(|download| download.slot.is_none());
        for download in downloads {
            self.schedule(DownloadJob {
                root: Arc::clone(&root),
                root_path: root_path.to_path_buf(),
                staging_directory: staging_directory.to_path_buf(),
                path: download.path,
                identity: download.identity,
                source: download.source,
                slot_identity: download.slot_identity,
                slot: download.slot,
            })?;
        }
        Ok(())
    }

    fn schedule(&mut self, job: DownloadJob) -> Result<(), ReconcileError> {
        if self.pending_failure.is_some()
            || self.cancelled.load(Ordering::Acquire)
            || self.workers.iter().any(thread::JoinHandle::is_finished)
        {
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        let path = job.path.clone();
        let job_identity = job.identity;
        let Some(jobs) = &self.jobs else {
            return Err(ReconcileError::DownloadWorkerStopped);
        };
        if jobs.send(job).is_err() {
            return Err(ReconcileError::DownloadWorkerStopped);
        }
        self.scheduled.insert(path, job_identity);
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
    active: BTreeSet<[u8; 32]>,
    live: BTreeSet<[u8; 32]>,
}

impl DownloadSlots {
    fn protects(&self, binding: &[u8; 32]) -> bool {
        self.active.contains(binding) || self.live.contains(binding)
    }
}

struct LeasedDownloadSlot {
    lease: DownloadSlotLease,
    _reservation: DownloadSlotReservation,
}

struct DownloadSlotReservation {
    slots: Arc<Mutex<DownloadSlots>>,
    binding: [u8; 32],
}

impl Drop for DownloadSlotReservation {
    fn drop(&mut self) {
        if let Ok(mut slots) = self.slots.lock() {
            slots.active.remove(&self.binding);
        }
    }
}

struct DownloadJob {
    root: Arc<OwnedFd>,
    root_path: PathBuf,
    staging_directory: PathBuf,
    path: PathBuf,
    identity: DownloadIdentity,
    source: RemoteFile,
    slot_identity: DownloadSlotIdentity,
    slot: Option<LeasedDownloadSlot>,
}

struct DownloadResult {
    path: PathBuf,
    identity: DownloadIdentity,
    outcome: DownloadOutcome,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DownloadIdentity {
    plan: PlanId,
    operation: OperationId,
}

enum DownloadOutcome {
    Completed,
    Blocked(BlockReason),
    Failed(ReconcileError),
    Cancelled,
}

#[derive(Default)]
struct CollectedDownloads {
    blocked: Vec<BlockedDownload>,
    failure: Option<ReconcileError>,
}

struct BlockedDownload {
    path: PathBuf,
    identity: DownloadIdentity,
    reason: BlockReason,
}

fn download_worker(
    dropbox: &DropboxClient,
    jobs: &Mutex<mpsc::Receiver<DownloadJob>>,
    results: &mpsc::Sender<DownloadResult>,
    slots: &Arc<Mutex<DownloadSlots>>,
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
        let identity = job.identity;
        if cancelled.load(Ordering::Acquire) {
            drop(job);
            if results
                .send(DownloadResult {
                    path,
                    identity,
                    outcome: DownloadOutcome::Cancelled,
                })
                .is_err()
            {
                return;
            }
            continue;
        }
        let outcome = match run_download_job(dropbox, job, slots, root_access) {
            Ok(()) => DownloadOutcome::Completed,
            Err(error) => match download_block_reason(&error) {
                Some(reason) => {
                    tracing::warn!(
                        path = %path.display(),
                        reason = ?reason,
                        cause = %root_cause(&error),
                        "exact download blocked for its path"
                    );
                    DownloadOutcome::Blocked(reason)
                }
                None => DownloadOutcome::Failed(error),
            },
        };
        if matches!(outcome, DownloadOutcome::Failed(_)) {
            cancelled.store(true, Ordering::Release);
        }
        if results
            .send(DownloadResult {
                path,
                identity,
                outcome,
            })
            .is_err()
        {
            return;
        }
    }
}

/// The deepest cause in an error chain, which names what actually failed.
fn root_cause(error: &(dyn std::error::Error + 'static)) -> String {
    let mut reason = error;
    while let Some(source) = reason.source() {
        reason = source;
    }
    reason.to_string()
}

/// The durable per-path block one failed exact download earns, or `None`
/// when the failure concerns the session rather than the path.
fn download_block_reason(error: &ReconcileError) -> Option<BlockReason> {
    match error {
        ReconcileError::RemoteDownload {
            source: DropboxError::Sdk {
                outcome, source, ..
            },
            ..
        } => {
            if matches!(
                outcome,
                crate::dropbox::ApiOutcome::Unavailable | crate::dropbox::ApiOutcome::Unknown
            ) {
                return Some(BlockReason::DownloadUnavailable { status: 409 });
            }
            // A rejected or unmapped client status names this exact download,
            // not the session: block the path and let every other path continue.
            match source.as_ref() {
                dropbox_sdk::Error::BadRequest(_) => {
                    return Some(BlockReason::DownloadUnavailable { status: 400 });
                }
                dropbox_sdk::Error::UnexpectedHttpError { code, .. }
                    if (400..500).contains(code) =>
                {
                    return Some(BlockReason::DownloadUnavailable { status: *code });
                }
                _ => {}
            }
            if matches!(
                source.as_ref(),
                dropbox_sdk::Error::Json(_) | dropbox_sdk::Error::UnexpectedResponse(_)
            ) {
                return Some(BlockReason::DownloadVerificationFailed);
            }
            use crate::transport::TransportError as T;
            match source.downcast_ref_inner::<T>() {
                Some(
                    T::RangeIgnored { .. }
                    | T::RangeMismatch { .. }
                    | T::UnexpectedRangeStatus { .. }
                    | T::RangeUnsatisfiable { .. },
                ) => Some(BlockReason::DownloadVerificationFailed),
                _ => None,
            }
        }

        ReconcileError::RemoteDownload {
            source:
                DropboxError::DownloadedRevisionChanged
                | DropboxError::DownloadedIdentityChanged
                | DropboxError::DownloadedSizeChanged
                | DropboxError::InvalidDownloadRange
                | DropboxError::DownloadedLengthChanged,
            ..
        }
        | ReconcileError::RemoteContentChanged { .. } => {
            Some(BlockReason::DownloadVerificationFailed)
        }
        ReconcileError::StageDestinationOccupied { .. }
        | ReconcileError::RemoteDownload {
            source:
                DropboxError::LocalStage {
                    source: LocalError::DestinationOccupied { .. },
                },
            ..
        } => Some(BlockReason::StageOccupied),
        ReconcileError::RemoteDownload {
            source: DropboxError::LocalStage { source },
            ..
        } if local_download_object_blocks(source) => Some(BlockReason::LocalObjectInWay),
        _ => None,
    }
}

fn local_download_object_blocks(error: &LocalError) -> bool {
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

fn run_download_job(
    dropbox: &DropboxClient,
    mut job: DownloadJob,
    slots: &Arc<Mutex<DownloadSlots>>,
    root_access: &Arc<SyncRootAccess>,
) -> Result<(), ReconcileError> {
    let lease = match job.slot.take() {
        Some(lease) => Some(lease),
        None => acquire_download_slot(&job, slots)?,
    };
    let outcome = dropbox
        .stage_worker_download_at(
            &job.root,
            &job.root_path,
            &job.path,
            &job.source,
            DownloadAccess {
                lease: lease.as_ref().map(|leased| &leased.lease),
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
    drop(lease);
    outcome
}

fn acquire_download_slot(
    job: &DownloadJob,
    slots: &Arc<Mutex<DownloadSlots>>,
) -> Result<Option<LeasedDownloadSlot>, ReconcileError> {
    let mut slots_guard = slots
        .lock()
        .map_err(|_| ReconcileError::DownloadSlotCoordinatorUnavailable)?;
    let binding = job.slot_identity.binding();
    let lease = lease_download_slots(
        &job.staging_directory,
        std::slice::from_ref(&job.slot_identity),
        |candidate| slots_guard.protects(candidate),
    )?
    .into_iter()
    .next()
    .flatten();
    let Some(lease) = lease else {
        return Ok(None);
    };
    if !slots_guard.active.insert(binding) {
        return Err(invalid(
            &job.path,
            "resumable download binding was assigned twice",
        ));
    }
    Ok(Some(LeasedDownloadSlot {
        lease,
        _reservation: DownloadSlotReservation {
            slots: Arc::clone(slots),
            binding,
        },
    }))
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
    let collected = download_pool.collect_results()?;
    record_download_blocks(journal, &collected.blocked)?;
    let mut blocked_plans = journal.blocked_plans()?;
    retire_excluded_plans(journal, &mut blocked_plans)?;
    let Some(root) = open_active_root(journal, sync_root)? else {
        return Err(ReconcileError::LocalRootChanged);
    };
    let root = Arc::new(root);
    let root_generation = journal
        .local_root_binding()?
        .ok_or(ReconcileError::LocalRootChanged)?
        .generation;
    let mut pending_plans = journal.pending_plans()?;
    retire_excluded_plans(journal, &mut pending_plans)?;
    let live_bindings = pending_plans
        .iter()
        .chain(blocked_plans.iter())
        .filter_map(|plan| pending_download_slot_identity(plan, root_generation))
        .map(|identity| identity.binding())
        .collect::<BTreeSet<_>>();
    let mut report = replay_local_plans_at(
        journal,
        &root,
        sync_root,
        pending_plans
            .iter()
            .filter(|plan| !download_pool.contains_plan(plan)),
    )?;
    record_local_replay_blocks(journal, &pending_plans, &report.blocked)?;
    report
        .blocked
        .extend(blocked_plans.into_iter().filter_map(|plan| {
            let PlanStatus::Blocked { reason, .. } = plan.status else {
                return None;
            };
            Some(ReplayBlocked::DurablePlan {
                path: plan.path,
                reason,
            })
        }));
    for plan in pending_plans
        .iter()
        .filter(|plan| download_pool.contains_plan(plan))
    {
        let (_, source) = pending_download_operation(plan)?;
        report.blocked.push(ReplayBlocked::DownloadRequired {
            path: plan.path.clone(),
            content: source.content,
        });
    }
    if let Some(error) = collected.failure {
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
    let mut downloads = Vec::with_capacity(missing_downloads.len());
    if !missing_downloads.is_empty() {
        let mut pending = pending_plans
            .into_iter()
            .map(|plan| (plan.path.clone(), plan))
            .collect::<BTreeMap<_, _>>();
        for path in missing_downloads {
            let Some(plan) = pending.remove(&path) else {
                return Err(invalid(
                    &path,
                    "pending download blocker has no matching plan",
                ));
            };
            let (operation_id, source) = pending_download_operation(&plan)?;
            downloads.push(PendingDownload {
                identity: DownloadIdentity {
                    plan: plan.id,
                    operation: operation_id,
                },
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
    }
    download_pool.lease_and_schedule(
        Arc::clone(&root),
        sync_root,
        upload_staging,
        downloads,
        live_bindings,
    )?;
    require_active_local_root(journal, sync_root)?;
    let remote = replay_remote_operations_at(journal, dropbox, &root, sync_root, upload_staging)?;
    report.completed_operations += remote.completed_operations;
    report.blocked.extend(remote.blocked);
    Ok(report)
}

fn unix_now() -> Result<u64, ReconcileError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|source| ReconcileError::Clock { source })
}

fn record_download_blocks(
    journal: &mut Journal,
    blocked: &[BlockedDownload],
) -> Result<(), ReconcileError> {
    if blocked.is_empty() {
        return Ok(());
    }
    let retry_at = unix_now()?.saturating_add(BLOCK_RETRY_SECONDS);
    let pending = journal.pending_plans()?;
    for blocked in blocked {
        let current = pending.iter().find(|plan| {
            plan.path == blocked.path
                && plan.id == blocked.identity.plan
                && pending_download_identity(plan) == Some(blocked.identity)
        });
        let Some(plan) = current else {
            continue;
        };
        match journal.block_plan(plan.id, &blocked.reason, retry_at)? {
            PlanBlock::Blocked | PlanBlock::AlreadyCompleted | PlanBlock::NotFound => {}
        }
    }
    Ok(())
}

fn record_local_replay_blocks(
    journal: &mut Journal,
    pending: &[PlanRecord],
    blocked: &[ReplayBlocked],
) -> Result<(), ReconcileError> {
    for blocker in blocked {
        let (plan, reason) = match blocker {
            ReplayBlocked::StageDestinationOccupied { plan_id, .. } => {
                let Some(plan) = pending
                    .iter()
                    .find(|plan| plan.id == *plan_id && pending_download_identity(plan).is_some())
                else {
                    continue;
                };
                (plan, BlockReason::StageOccupied)
            }
            ReplayBlocked::LocalObject { path } => {
                let Some(plan) = pending.iter().find(|plan| plan.path == *path) else {
                    continue;
                };
                (plan, BlockReason::LocalObjectInWay)
            }
            _ => continue,
        };
        let retry_at = unix_now()?.saturating_add(BLOCK_RETRY_SECONDS);
        match journal.block_plan(plan.id, &reason, retry_at)? {
            PlanBlock::Blocked | PlanBlock::AlreadyCompleted | PlanBlock::NotFound => {}
        }
    }
    Ok(())
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
    let Some(source) = case_variant_source(observations, |canonical| {
        journal.baseline_spelling(canonical)
    })?
    else {
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
    let mut live = journal.pending_plans()?;
    live.extend(journal.blocked_plans()?);
    for pending in live {
        let canonical_pending = CanonicalPath::from_display(&pending.path);
        if canonical_pending == canonical_source || canonical_pending.is_beneath(&canonical_source)
        {
            supersede_pending_plan(journal, &pending)?;
        }
    }
    journal.invalidate_case_collision_baselines(&rename.source, |path| {
        entry_exists_at(&root, path).map_err(ReconcileError::from)
    })?;
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
    let mut live_plans = journal.pending_plans()?;
    live_plans.extend(journal.blocked_plans()?);
    let live = live_plans
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
        .filter_map(replay_sync_error_path)
        .collect::<BTreeSet<_>>();
    let mut noops = Vec::new();
    let mut decisions = Vec::new();
    for_each_known_path(
        baselines,
        &local,
        &remote,
        &live,
        |canonical_path,
         baseline_record,
         local_record,
         remote_record|
         -> Result<(), ReconcileError> {
            // An excluded path is outside synchronization, even when an older
            // journal has a baseline or remote observation for it. Never infer
            // deletion from its omission in the local scan.
            if is_excluded(canonical_path.as_path()) {
                return Ok(());
            }
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
            let path = match local_record {
                Some(record) => record.path.clone(),
                None => {
                    let candidate = baseline_path
                        .or_else(|| remote_record.map(|record| record.path.clone()))
                        .or_else(|| live.get(canonical_path).map(|plan| plan.path.clone()))
                        .ok_or_else(|| {
                            invalid(
                                canonical_path.as_path(),
                                "canonical path has no display spelling",
                            )
                        })?;
                    spell_with_local_ancestors(&local, canonical_path, candidate)
                }
            };
            let decision = plan(
                &baseline,
                local_observation,
                remote_observation,
                remote_subtree(&remote, canonical_path),
            );
            let baseline_matches_noop = matches!(
                &decision,
                Decision::NoOp(noop) if &baseline == noop.baseline()
            );
            match decision {
                Decision::NoOp(noop) if !live.contains_key(canonical_path) => {
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
    let now = unix_now()?;

    for PathDecision {
        canonical_path,
        path,
        baseline_matches_noop,
        decision,
    } in decisions
    {
        if let Some(pending_plan) = live.get(&canonical_path) {
            if downloads.contains_plan(pending_plan) {
                blocked_paths.insert(canonical_path.clone());
                continue;
            }
            if let Decision::Conflict(conflict) = decision {
                if let PlanStatus::Blocked { reason, retry_at } = &pending_plan.status
                    && matches!(
                        reason,
                        BlockReason::ConflictCopyOccupied | BlockReason::StageOccupied
                    )
                    && *retry_at > now
                {
                    blocked_paths.insert(canonical_path.clone());
                    continue;
                }
                match prepare_conflict(dropbox, sync_root, upload_staging, &path, &conflict)? {
                    PreparedConflict::Ready => {
                        finish_pending_conflict(journal, pending_plan, &conflict)?
                    }
                    PreparedConflict::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                    PreparedConflict::Blocked(reason) => {
                        let retry_at = now.saturating_add(BLOCK_RETRY_SECONDS);
                        match journal.block_plan(pending_plan.id, &reason, retry_at)? {
                            PlanBlock::Blocked => {}
                            PlanBlock::AlreadyCompleted | PlanBlock::NotFound => {
                                return Err(invalid(
                                    &pending_plan.path,
                                    "blocked conflict lost its pending plan",
                                ));
                            }
                        }
                        blocked_paths.insert(canonical_path.clone());
                        continue;
                    }
                }
                report.conflicts += 1;
                continue;
            } else if matches!(decision, Decision::DirectoryCollision(_)) {
                supersede_pending_plan(journal, pending_plan)?;
                return Ok(ReconcileOutcome::FreshObservationRequired { path });
            } else if let Decision::Blocked(reason) = decision {
                // A recorded remote directory delete rests on an inventory that
                // showed nothing beneath the path; entries there now retire it.
                // Every other block keeps its plan, whose own precondition still
                // guards the replay.
                if reason == BlockedReason::RemoteDirectoryOccupied {
                    supersede_pending_plan(journal, pending_plan)?;
                }
                blocked_paths.insert(canonical_path.clone());
                continue;
            } else if let Decision::Operations(plan) = &decision
                && remaining_operations_match(pending_plan, plan)
            {
                if let PlanStatus::Blocked { retry_at, .. } = &pending_plan.status
                    && *retry_at <= now
                {
                    match journal.unblock_plan(pending_plan.id)? {
                        PlanUnblock::Unblocked | PlanUnblock::NotBlocked => {}
                        PlanUnblock::NotFound => {
                            return Err(invalid(
                                &pending_plan.path,
                                "due blocked plan disappeared",
                            ));
                        }
                    }
                }
                blocked_paths.insert(canonical_path.clone());
                continue;
            } else {
                supersede_pending_plan(journal, pending_plan)?;
            }
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
                // A recorded conflict was prepared once; its copies now belong
                // to the user, who may edit, move, or delete them.
                if conflicts.iter().any(|(existing, record)| {
                    *existing == canonical_path && record.conflict == conflict
                }) {
                    continue;
                }
                match prepare_conflict(dropbox, sync_root, upload_staging, &path, &conflict)? {
                    PreparedConflict::Ready => {}
                    PreparedConflict::FreshObservation => {
                        return Ok(ReconcileOutcome::FreshObservationRequired { path });
                    }
                    PreparedConflict::Blocked(_) => {
                        blocked_paths.insert(canonical_path.clone());
                        continue;
                    }
                }
                journal.record_conflict(&path, &conflict)?;
                report.conflicts += 1;
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
    sync_error_paths.extend(applied.blocked.iter().filter_map(replay_sync_error_path));
    if let Some(path) = applied.blocked.iter().find_map(|blocked| match blocked {
        ReplayBlocked::FreshObservationRequired { path } => Some(path.clone()),
        _ => None,
    }) {
        return Ok(ReconcileOutcome::FreshObservationRequired { path });
    }
    journal.prune_completed_work()?;
    prune_completed_recoveries(journal, recovery_directory)?;
    let retained_uploads = journal.pending_upload_content()?;
    let mut live = journal.pending_plans()?;
    live.extend(journal.blocked_plans()?);
    blocked_paths.extend(
        live.into_iter()
            .map(|plan| CanonicalPath::from_display(&plan.path)),
    );
    report.blocked = blocked_paths.len();
    report.sync_errors = sync_error_paths.len();
    report.downloads_in_progress = !downloads.is_empty();
    remove_unreferenced_upload_stages(upload_staging, &retained_uploads)?;
    Ok(ReconcileOutcome::Complete(report))
}

fn replay_sync_error_path(blocked: &ReplayBlocked) -> Option<PathBuf> {
    match blocked {
        ReplayBlocked::SyncError { path, .. } | ReplayBlocked::DurablePlan { path, .. } => {
            Some(path.clone())
        }
        _ => None,
    }
}

fn remaining_operations_match(pending: &PlanRecord, fresh: &OperationPlan) -> bool {
    pending
        .operations
        .iter()
        .filter(|planned| planned.status == RecordStatus::Pending)
        .map(|planned| &planned.operation)
        .eq(fresh.operations())
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

/// Result of placing every copy of one conflict at its deterministic name.
enum PreparedConflict {
    Ready,
    FreshObservation,
    Blocked(BlockReason),
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
            | Operation::DeleteLocalDirectory
            | Operation::DeleteRemoteDirectory => {}
            Operation::CreateRemote { content } | Operation::ReplaceRemote { content, .. } => {
                match prepare_local(sync_root, upload_staging, path, content) {
                    Ok(Prepared::Ready(_)) => {}
                    Ok(Prepared::FreshObservation) => {
                        return Ok(Prepared::FreshObservation);
                    }
                    Err(ReconcileError::StageDestinationOccupied { .. }) => {}
                    Err(error) => return Err(error),
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
    identity: DownloadIdentity,
    source: RemoteFile,
    slot_identity: DownloadSlotIdentity,
    slot: Option<LeasedDownloadSlot>,
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

fn pending_download_identity(plan: &PlanRecord) -> Option<DownloadIdentity> {
    plan.operations.iter().find_map(|planned| {
        if planned.status == RecordStatus::Completed
            || !matches!(
                &planned.operation,
                Operation::InstallLocal { .. } | Operation::ReplaceLocal { .. }
            )
        {
            return None;
        }
        Some(DownloadIdentity {
            plan: plan.id,
            operation: planned.id,
        })
    })
}

fn pending_download_slot_identity(
    plan: &PlanRecord,
    root_generation: u64,
) -> Option<DownloadSlotIdentity> {
    plan.operations.iter().find_map(|planned| {
        if planned.status == RecordStatus::Completed {
            return None;
        }
        let source = match &planned.operation {
            Operation::InstallLocal { source } | Operation::ReplaceLocal { source, .. } => source,
            _ => return None,
        };
        Some(DownloadSlotIdentity::new(
            root_generation,
            planned.id,
            &plan.path,
            source,
        ))
    })
}

fn prepare_conflict(
    dropbox: &DropboxClient,
    sync_root: &Path,
    upload_staging: &Path,
    path: &Path,
    conflict: &Conflict,
) -> Result<PreparedConflict, ReconcileError> {
    if let Some(local) = conflict.local() {
        let staged = match prepare_local(sync_root, upload_staging, path, &local.content) {
            Ok(Prepared::Ready(staged)) => staged,
            Ok(Prepared::FreshObservation) => return Ok(PreparedConflict::FreshObservation),
            Err(ReconcileError::StageDestinationOccupied { .. }) => {
                return Ok(PreparedConflict::Blocked(BlockReason::StageOccupied));
            }
            Err(source) => return Err(source),
        };
        match materialize_local_conflict(sync_root, path, &staged)? {
            CopyOutcome::Ready => {}
            CopyOutcome::Blocked(reason) => return Ok(PreparedConflict::Blocked(reason)),
            CopyOutcome::SourceChanged => return Ok(PreparedConflict::FreshObservation),
        }
    }
    if let Some(remote) = conflict.remote() {
        match materialize_remote_conflict(dropbox, sync_root, path, remote)? {
            CopyOutcome::Ready => {}
            CopyOutcome::Blocked(reason) => return Ok(PreparedConflict::Blocked(reason)),
            CopyOutcome::SourceChanged => return Ok(PreparedConflict::FreshObservation),
        }
    }
    Ok(PreparedConflict::Ready)
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
        Err(LocalError::DestinationOccupied { path, .. }) => {
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
    for record in records
        .into_iter()
        .filter(|record| !is_excluded(&record.path))
    {
        let canonical_path = CanonicalPath::from_display(&record.path);
        mapped.push((canonical_path, record));
    }
    mapped.sort_by(|(left_canonical, left), (right_canonical, right)| {
        left_canonical
            .cmp(right_canonical)
            .then_with(|| left.path.cmp(&right.path))
    });
    for collision in mapped.chunk_by(|(left, _), (right, _)| left == right) {
        let [(_, first), (_, second), ..] = collision else {
            continue;
        };
        let unsupported_only = collision.iter().all(|(_, record)| {
            matches!(
                record.observation,
                Observation::Unknown(UnknownReason::Unsupported)
            )
        });
        if !unsupported_only {
            return Err(ReconcileError::LocalCaseCollision {
                first: first.path.clone(),
                second: second.path.clone(),
            });
        }
    }
    // A collision of unsupported spellings only cannot be renamed apart; it
    // plans nothing and infers no deletion, so its least spelling stands for
    // the path as one unknown observation.
    mapped.dedup_by(|(later, _), (earlier, _)| later == earlier);
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

/// Spell a path the scan did not observe with the local spelling of every
/// ancestor it did observe.
///
/// Dropbox guarantees the casing of only the last `path_display` component,
/// and a baseline may predate a local re-spelling, so a candidate spelling can
/// name ancestors that differ from the directories the filesystem holds. On a
/// case-sensitive filesystem an effect at that spelling would build a sibling
/// tree beside them, which the next scan reports as a case collision. Every
/// ancestor with a local record is therefore respelled from that record; the
/// final component keeps the candidate spelling.
fn spell_with_local_ancestors(
    local: &[(CanonicalPath, LocalObservationRecord)],
    canonical_path: &CanonicalPath,
    candidate: PathBuf,
) -> PathBuf {
    let canonical = canonical_path.as_path().iter().collect::<Vec<_>>();
    let display = candidate.iter().collect::<Vec<_>>();
    if canonical.len() != display.len() {
        return candidate;
    }
    let mut prefix = PathBuf::new();
    let mut spelled = PathBuf::new();
    for (index, (canonical_component, display_component)) in
        canonical.iter().zip(&display).enumerate()
    {
        prefix.push(canonical_component);
        let ancestor = if index + 1 < canonical.len() {
            local
                .binary_search_by(|(path, _)| path.as_bytes().cmp(prefix.as_os_str().as_bytes()))
                .ok()
                .and_then(|found| local.get(found))
                .and_then(|(_, record)| record.path.file_name())
        } else {
            None
        };
        match ancestor {
            Some(name) => spelled.push(name),
            None => spelled.push(display_component),
        }
    }
    spelled
}

#[derive(Debug, Eq, PartialEq)]
struct CaseVariantMove {
    source: PathBuf,
    destination: PathBuf,
}

/// Choose the spelling to rename in the first local case collision that has a
/// renamable spelling.
///
/// The rename moves only a regular file or a directory, so a spelling the scan
/// published as unsupported (a symlink, a special file, a reserved name or an
/// entry on another volume) is never a candidate. A collision of unsupported
/// spellings only is left in place: it plans nothing and infers no deletion,
/// so planning keeps it as one unknown path.
/// `recorded` reads the spelling a baseline at the colliding canonical path
/// was recorded under. The greatest candidate other than that one is renamed,
/// so the history stays attached to the file it was recorded for; when the
/// recorded spelling is the only candidate, it is renamed itself.
fn case_variant_source(
    records: &[LocalObservationRecord],
    recorded: impl FnOnce(&CanonicalPath) -> Result<Option<PathBuf>, JournalError>,
) -> Result<Option<PathBuf>, JournalError> {
    let mut spellings = BTreeMap::<CanonicalPath, BTreeMap<&PathBuf, bool>>::new();
    for record in records.iter().filter(|record| !is_excluded(&record.path)) {
        let canonical = CanonicalPath::from_display(&record.path);
        let renamable = !matches!(
            record.observation,
            Observation::Unknown(UnknownReason::Unsupported)
        );
        spellings
            .entry(canonical)
            .or_default()
            .insert(&record.path, renamable);
    }
    let Some((canonical, variants)) = spellings
        .iter()
        .find(|(_, paths)| paths.len() > 1 && paths.values().any(|renamable| *renamable))
    else {
        return Ok(None);
    };
    let kept = recorded(canonical)?;
    let mut candidates = variants
        .iter()
        .filter(|(_, renamable)| **renamable)
        .map(|(path, _)| *path)
        .rev();
    let preferred = candidates
        .clone()
        .find(|variant| kept.as_ref() != Some(*variant));
    Ok(preferred.or_else(|| candidates.next()).cloned())
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

/// What the sorted inventory holds beneath one canonical path.
///
/// Records sort by canonical bytes, so every descendant follows `path + "/"`
/// contiguously and the first record at or past that prefix decides. A sibling
/// such as `path.txt` sorts between the path and its children, so the search
/// targets the child prefix rather than the path itself.
fn remote_subtree(
    records: &[RemoteObservationRecord],
    canonical_path: &CanonicalPath,
) -> RemoteSubtree {
    let parent = canonical_path.as_bytes();
    let first_child = records
        .partition_point(|record| precedes_children(record.canonical_path.as_bytes(), parent));
    match records.get(first_child) {
        Some(record) if record.canonical_path.is_beneath(canonical_path) => RemoteSubtree::Occupied,
        _ => RemoteSubtree::Empty,
    }
}

/// Whether `bytes` sorts before every path beneath `parent`, that is before
/// `parent + "/"`, decided without building that prefix.
fn precedes_children(bytes: &[u8], parent: &[u8]) -> bool {
    match bytes.strip_prefix(parent) {
        None => bytes < parent,
        Some(rest) => rest.first().is_none_or(|byte| *byte < b'/'),
    }
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
    pending: &BTreeMap<CanonicalPath, PlanRecord>,
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
    let mut pending_paths = pending.keys().peekable();
    loop {
        let side_minimum = [
            local
                .get(local_index)
                .map(|(canonical_path, _)| canonical_path),
            remote
                .get(remote_index)
                .map(|record| &record.canonical_path),
            pending_paths.peek().copied(),
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
        let advance_pending = pending_paths
            .peek()
            .is_some_and(|pending| *pending == canonical_path);
        visit(canonical_path, baseline, local_record, remote_record)?;
        if advance_pending {
            let _ = pending_paths.next();
        }
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

    #[test]
    fn cancelled_queued_download_releases_its_binding_once() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let root_path = directory.path().join("root");
        let staging = directory.path().join("staging");
        std::fs::create_dir_all(&root_path)?;
        std::fs::create_dir_all(&staging)?;
        let root = Arc::new(crate::local::open_root(
            &root_path,
            "open cancellation test root",
        )?);
        let remote = RemoteFile::new(
            identity(b"cancelled download")?,
            DropboxRevision::new("cancelled-revision"),
        );
        let operation_plan = OperationPlan::new(vec![Operation::InstallLocal {
            source: remote.clone(),
        }]);
        let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
        let recorded = match journal.record_plan(Path::new("cancelled.bin"), &operation_plan)? {
            PlanWrite::Recorded(recorded) => recorded,
            PlanWrite::AlreadyLive(_) => {
                return Err(io::Error::other("cancellation test plan was already live").into());
            }
        };
        let [operation] = recorded.operations.as_slice() else {
            return Err(io::Error::other("cancellation test plan had another shape").into());
        };
        let identity = DownloadIdentity {
            plan: recorded.id,
            operation: operation.id,
        };
        let slot_identity =
            DownloadSlotIdentity::new(1, operation.id, Path::new("cancelled.bin"), &remote);
        let binding = slot_identity.binding();
        let lease =
            lease_download_slots(&staging, std::slice::from_ref(&slot_identity), |_| false)?
                .into_iter()
                .next()
                .flatten()
                .ok_or_else(|| io::Error::other("cancellation test slot was not leased"))?;
        let slots = Arc::new(Mutex::new(DownloadSlots::default()));
        {
            let mut locked = slots
                .lock()
                .map_err(|_| io::Error::other("slot coordinator was poisoned"))?;
            assert!(locked.active.insert(binding));
        }
        let (job_sender, job_receiver) = mpsc::channel();
        let (result_sender, result_receiver) = mpsc::channel();
        job_sender.send(DownloadJob {
            root,
            root_path,
            staging_directory: staging,
            path: PathBuf::from("cancelled.bin"),
            identity,
            source: remote,
            slot_identity,
            slot: Some(LeasedDownloadSlot {
                lease,
                _reservation: DownloadSlotReservation {
                    slots: Arc::clone(&slots),
                    binding,
                },
            }),
        })?;
        drop(job_sender);
        let cancelled = AtomicBool::new(true);
        let client = DropboxClient::new(
            crate::auth::AccessToken::for_test("unused-cancelled-worker-token"),
            crate::dropbox::DropboxRoot::new("account", "namespace", "")?,
        )?;
        download_worker(
            &client,
            &Mutex::new(job_receiver),
            &result_sender,
            &slots,
            &cancelled,
            &Arc::new(SyncRootAccess::default()),
        );
        let result = result_receiver.recv()?;
        assert_eq!(result.path, Path::new("cancelled.bin"));
        assert_eq!(result.identity, identity);
        assert!(matches!(result.outcome, DownloadOutcome::Cancelled));

        let mut locked = slots
            .lock()
            .map_err(|_| io::Error::other("slot coordinator was poisoned"))?;
        assert!(locked.active.insert(binding));
        assert!(!locked.active.insert(binding));
        Ok(())
    }
    use crate::local::{ConflictSide, conflict_relative_path, dropbox_content_hash};

    fn remote_download_error(source: DropboxError) -> ReconcileError {
        ReconcileError::RemoteDownload {
            path: PathBuf::from("download.txt"),
            source,
        }
    }

    #[test]
    fn download_failures_separate_path_blocks_from_global_errors() {
        use dropbox_sdk::types::{auth, files};
        use dropbox_sdk::{Error as SdkError, NoError};
        for reason in [
            files::LookupError::MalformedPath(None),
            files::LookupError::NotFound,
            files::LookupError::NotFile,
            files::LookupError::NotFolder,
            files::LookupError::RestrictedContent,
            files::LookupError::UnsupportedContentType,
        ] {
            let error = DropboxError::sdk(
                "download",
                SdkError::Api(files::DownloadError::Path(reason)),
            );
            assert_eq!(
                download_block_reason(&remote_download_error(error)),
                Some(BlockReason::DownloadUnavailable { status: 409 })
            );
        }
        for error in [
            SdkError::<NoError>::Authentication(auth::AuthError::InvalidAccessToken),
            SdkError::RateLimited {
                reason: auth::RateLimitReason::Other,
                retry_after_seconds: 1,
            },
            SdkError::ServerError(String::new()),
            SdkError::UnexpectedHttpError {
                code: 302,
                response: String::new(),
            },
        ] {
            assert_eq!(
                download_block_reason(&remote_download_error(DropboxError::sdk("download", error))),
                None
            );
        }
        for (error, status) in [
            (
                SdkError::<NoError>::BadRequest(String::from("Error in call to API function")),
                400,
            ),
            (
                SdkError::UnexpectedHttpError {
                    code: 418,
                    response: String::new(),
                },
                418,
            ),
        ] {
            assert_eq!(
                download_block_reason(&remote_download_error(DropboxError::sdk("download", error))),
                Some(BlockReason::DownloadUnavailable { status })
            );
        }
        for source in [
            DropboxError::DownloadedRevisionChanged,
            DropboxError::DownloadedIdentityChanged,
            DropboxError::DownloadedSizeChanged,
            DropboxError::InvalidDownloadRange,
            DropboxError::DownloadedLengthChanged,
        ] {
            assert_eq!(
                download_block_reason(&remote_download_error(source)),
                Some(BlockReason::DownloadVerificationFailed)
            );
        }
        assert_eq!(
            download_block_reason(&ReconcileError::StageDestinationOccupied {
                path: PathBuf::from("private-stage"),
            }),
            Some(BlockReason::StageOccupied)
        );
    }

    #[test]
    fn local_download_path_objects_are_durable_blocks() {
        let unsupported = remote_download_error(DropboxError::LocalStage {
            source: LocalError::UnsupportedObject {
                path: PathBuf::from("download.txt"),
            },
        });
        assert_eq!(
            download_block_reason(&unsupported),
            Some(BlockReason::LocalObjectInWay)
        );
        for errno in [rustix::io::Errno::LOOP, rustix::io::Errno::NOTDIR] {
            let source = remote_download_error(DropboxError::LocalStage {
                source: LocalError::Io {
                    operation: "prepare exact download",
                    path: PathBuf::from("download.txt"),
                    source: io::Error::from_raw_os_error(errno.raw_os_error()),
                },
            });
            assert_eq!(
                download_block_reason(&source),
                Some(BlockReason::LocalObjectInWay)
            );
        }
    }

    #[test]
    fn absent_paths_are_spelled_with_local_ancestor_casing() -> Result<(), Box<dyn Error>> {
        let local = local_map(local_records([
            PathBuf::from("Apps"),
            PathBuf::from("Apps/Day One"),
            PathBuf::from("Notes"),
        ]))?;
        let respelled = spell_with_local_ancestors(
            &local,
            &CanonicalPath::from_display(Path::new("apps/day one/journal")),
            PathBuf::from("apps/day one/Journal"),
        );
        assert_eq!(respelled, PathBuf::from("Apps/Day One/Journal"));
        let deeper = spell_with_local_ancestors(
            &local,
            &CanonicalPath::from_display(Path::new("apps/day one/journal/entries")),
            PathBuf::from("APPS/Day one/journal/Entries"),
        );
        assert_eq!(deeper, PathBuf::from("Apps/Day One/journal/Entries"));
        let fresh = spell_with_local_ancestors(
            &local,
            &CanonicalPath::from_display(Path::new("docs/report.txt")),
            PathBuf::from("Docs/Report.txt"),
        );
        assert_eq!(fresh, PathBuf::from("Docs/Report.txt"));
        let top = spell_with_local_ancestors(
            &local,
            &CanonicalPath::from_display(Path::new("notes")),
            PathBuf::from("NOTES"),
        );
        assert_eq!(top, PathBuf::from("NOTES"));
        Ok(())
    }

    fn no_baseline(_: &CanonicalPath) -> Result<Option<PathBuf>, JournalError> {
        Ok(None)
    }

    fn local_records(paths: impl IntoIterator<Item = PathBuf>) -> Vec<LocalObservationRecord> {
        paths
            .into_iter()
            .map(|path| LocalObservationRecord {
                path,
                observation: Observation::Directory,
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

            let Ok(Some(forward_source)) = case_variant_source(&records, no_baseline) else {
                return Err(TestCaseError::fail("case collision had no source"));
            };
            let Ok(forward) = case_variant_move(&records, forward_source, 255) else {
                return Err(TestCaseError::fail("case collision had no automatic rename"));
            };
            records.reverse();
            let Ok(Some(reversed_source)) = case_variant_source(&records, no_baseline) else {
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
            let pending = BTreeMap::new();
            let mut merged = Vec::new();
            for_each_known_path(
                baselines,
                &local,
                &remote,
                &pending,
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

    #[test]
    fn remaining_operation_comparison_ignores_a_completed_prefix() -> Result<(), Box<dyn Error>> {
        let state = TempDir::new()?;
        let mut journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let local = LocalFile::new(dropbox_content_hash(b"preserved".as_slice())?);
        let remote = RemoteFile::new(
            dropbox_content_hash(b"replacement".as_slice())?,
            crate::model::DropboxRevision::new("replacement-revision"),
        );
        let original = OperationPlan::new(vec![
            Operation::PreserveLocal { file: local },
            Operation::InstallLocal {
                source: remote.clone(),
            },
        ]);
        let recorded = match journal.record_plan(Path::new("file.txt"), &original)? {
            crate::journal::PlanWrite::Recorded(recorded) => recorded,
            crate::journal::PlanWrite::AlreadyLive(_) => {
                return Err("new test journal already held a live plan".into());
            }
        };
        let [completed, _remaining] = recorded.operations.as_slice() else {
            return Err("test plan did not contain two operations".into());
        };
        assert!(matches!(
            journal.complete_operation(completed.id, None)?,
            crate::journal::OperationCompletion::OperationCompleted
        ));
        let pending = journal.pending_plans()?;
        let [pending] = pending.as_slice() else {
            return Err("test journal did not retain one partial plan".into());
        };
        let fresh = OperationPlan::new(vec![Operation::InstallLocal { source: remote }]);

        assert!(remaining_operations_match(pending, &fresh));
        assert!(!remaining_operations_match(pending, &original));
        Ok(())
    }

    #[test]
    fn pending_only_paths_are_visited_as_absent_without_creating_a_baseline()
    -> Result<(), Box<dyn Error>> {
        let state = TempDir::new()?;
        let path = Path::new("removed.txt");
        let mut journal = Journal::open(state.path().join("journal.sqlite3"))?;
        let remote = RemoteFile::new(
            dropbox_content_hash(b"obsolete".as_slice())?,
            crate::model::DropboxRevision::new("obsolete-revision"),
        );
        let operation_plan = OperationPlan::new(vec![Operation::InstallLocal { source: remote }]);
        assert!(matches!(
            journal.record_plan(path, &operation_plan)?,
            crate::journal::PlanWrite::Recorded(_)
        ));
        let pending = journal
            .pending_plans()?
            .into_iter()
            .map(|plan| (CanonicalPath::from_display(&plan.path), plan))
            .collect::<BTreeMap<_, _>>();
        let local = Vec::new();
        let remote = Vec::new();
        let mut decisions = Vec::new();

        for_each_known_path(
            Vec::new(),
            &local,
            &remote,
            &pending,
            |canonical, baseline, local, remote| -> Result<(), io::Error> {
                assert_eq!(canonical, &CanonicalPath::from_display(path));
                assert!(baseline.is_none());
                assert!(local.is_none());
                assert!(remote.is_none());
                decisions.push(plan(
                    &Baseline::Absent,
                    &Observation::ConfirmedAbsent,
                    &Observation::ConfirmedAbsent,
                    RemoteSubtree::Empty,
                ));
                Ok(())
            },
        )?;

        assert!(matches!(decisions.as_slice(), [Decision::NoOp(_)]));
        assert_eq!(journal.baseline(path)?, None);
        Ok(())
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
            RemoteSubtree::Empty,
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
        let Some(source) = case_variant_source(&records, no_baseline)? else {
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
        let Some(source) = case_variant_source(&records, no_baseline)? else {
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
        let Some(parent_source) = case_variant_source(&records, no_baseline)? else {
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
        let Some(child_source) = case_variant_source(&after_parent, no_baseline)? else {
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
        assert_eq!(case_variant_source(&converged, no_baseline)?, None);
        Ok(())
    }

    #[test]
    fn case_variant_source_keeps_the_recorded_spelling() -> Result<(), Box<dyn Error>> {
        let recorded = |spelling: &'static str| {
            move |_: &CanonicalPath| -> Result<Option<PathBuf>, JournalError> {
                Ok(Some(PathBuf::from(spelling)))
            }
        };

        let records = local_records(["Foo.txt", "foo.txt"].map(PathBuf::from));
        assert_eq!(
            case_variant_source(&records, recorded("FOO.txt"))?,
            Some(PathBuf::from("foo.txt"))
        );

        // An unreadable spelling can still be renamed, so it moves and the
        // recorded one keeps its history.
        let records = vec![
            LocalObservationRecord {
                path: PathBuf::from("Notes.txt"),
                observation: Observation::Unknown(UnknownReason::Inaccessible),
            },
            LocalObservationRecord {
                path: PathBuf::from("notes.txt"),
                observation: Observation::Present(LocalFile::new(identity(b"notes")?)),
            },
        ];
        assert_eq!(
            case_variant_source(&records, recorded("notes.txt"))?,
            Some(PathBuf::from("Notes.txt"))
        );
        Ok(())
    }

    fn unsupported_records(paths: &[&str]) -> Vec<LocalObservationRecord> {
        paths
            .iter()
            .map(|path| LocalObservationRecord {
                path: PathBuf::from(path),
                observation: Observation::Unknown(UnknownReason::Unsupported),
            })
            .collect()
    }

    #[test]
    fn case_variant_source_leaves_unsupported_spellings() -> Result<(), Box<dyn Error>> {
        let records = unsupported_records(&["Link", "link"]);
        assert_eq!(case_variant_source(&records, no_baseline)?, None);
        Ok(())
    }

    #[test]
    fn case_variant_source_skips_an_unsupported_collision() -> Result<(), Box<dyn Error>> {
        let mut records = unsupported_records(&["Link", "link"]);
        for path in ["Notes.txt", "notes.txt"] {
            records.push(LocalObservationRecord {
                path: PathBuf::from(path),
                observation: Observation::Present(LocalFile::new(identity(path.as_bytes())?)),
            });
        }
        assert_eq!(
            case_variant_source(&records, no_baseline)?,
            Some(PathBuf::from("notes.txt"))
        );
        Ok(())
    }

    #[test]
    fn local_map_keeps_one_unsupported_spelling() -> Result<(), Box<dyn Error>> {
        let mapped = local_map(unsupported_records(&["link", "Link"]))?;
        let paths: Vec<_> = mapped.iter().map(|(_, record)| &record.path).collect();
        assert_eq!(paths, [&PathBuf::from("Link")]);
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
        let Decision::NoOp(noop) = plan(
            &Baseline::Absent,
            &local,
            &remote_observation,
            RemoteSubtree::Empty,
        ) else {
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
                RemoteSubtree::Empty,
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
                RemoteSubtree::Empty,
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
                RemoteSubtree::Empty,
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
            RemoteSubtree::Empty,
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
            RemoteSubtree::Empty,
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
            RemoteSubtree::Empty,
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
        assert_eq!(
            materialize_local_conflict(root.path(), path, &staged)?,
            CopyOutcome::Ready
        );
        finish_pending_conflict(&mut journal, &pending, &conflict)?;

        assert!(journal.pending_plans()?.is_empty());
        assert_eq!(journal.baseline(path)?, Some(Baseline::Present(old)));
        assert_eq!(journal.conflicts()?.len(), 1);
        let copy = conflict_relative_path(path, ConflictSide::Local, &edited)?;
        assert_eq!(std::fs::read(root.path().join(copy))?, b"local edit");
        Ok(())
    }

    fn remote_directory(path: &[u8]) -> RemoteObservationRecord {
        let path = PathBuf::from(OsString::from_vec(path.to_vec()));
        RemoteObservationRecord {
            canonical_path: CanonicalPath::from_display(&path),
            path,
            observation: Observation::Directory,
        }
    }

    #[test]
    fn remote_subtree_holds_only_true_descendants() {
        let records = remote_map(vec![
            remote_directory(b"Report"),
            remote_directory(b"report.txt"),
            remote_directory(b"Report/x"),
            remote_directory(b"reports/y"),
            remote_directory(b"deep/\xff"),
        ]);
        let subtree =
            |path: &str| remote_subtree(&records, &CanonicalPath::from_display(Path::new(path)));

        assert_eq!(subtree("report"), RemoteSubtree::Occupied);
        assert_eq!(subtree("reports"), RemoteSubtree::Occupied);
        assert_eq!(subtree("deep"), RemoteSubtree::Occupied);
        assert_eq!(subtree("report.txt"), RemoteSubtree::Empty);
        assert_eq!(subtree("report/x"), RemoteSubtree::Empty);
        assert_eq!(subtree("repo"), RemoteSubtree::Empty);
        assert_eq!(subtree("other"), RemoteSubtree::Empty);
    }

    proptest! {
        /// The allocation-free comparator must order exactly as a comparison
        /// against the materialized child prefix would.
        #[test]
        fn child_prefix_order_matches_the_materialized_prefix(
            bytes in prop::collection::vec(any::<u8>(), 0..6),
            parent in prop::collection::vec(any::<u8>(), 0..6),
        ) {
            let mut prefix = parent.clone();
            prefix.push(b'/');
            prop_assert_eq!(precedes_children(&bytes, &parent), bytes < prefix);
        }
    }
}
