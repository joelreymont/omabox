//! Durable, transactional synchronization state.

use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior, params};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::config::create_owner_only;
use crate::model::{
    Baseline, CanonicalPath, Conflict, ContentIdentity, LocalObservation, NoOpDecision,
    Observation, Operation, OperationPlan, RemoteObservation,
};

const MIGRATION_V1: &str = include_str!("../migrations/0001.sql");
const MIGRATION_V2: &str = include_str!("../migrations/0002.sql");
const MIGRATION_V3: &str = include_str!("../migrations/0003.sql");
const MIGRATION_V4: &str = include_str!("../migrations/0004.sql");
const MIGRATION_V5: &str = include_str!("../migrations/0005.sql");
const MIGRATION_V6: &str = include_str!("../migrations/0006.sql");
const MIGRATION_V7: &str = include_str!("../migrations/0007.sql");
const SCHEMA_VERSION: i64 = 7;
const BUSY_TIMEOUT_MILLISECONDS: u64 = 5_000;
const FINISH_PLAN: &str = "UPDATE plans \
    SET status = 'completed', blocked_json = NULL, retry_at = NULL WHERE id = ?1";
const PLAN_QUERY: &str = "SELECT plans.id, plans.path, plans.status, plans.blocked_json, \
     plans.retry_at, operations.id, operations.ordinal, operations.operation_json, \
     operations.status \
     FROM plans JOIN operations ON operations.plan_id = plans.id \
     WHERE plans.status = ?1 ORDER BY plans.id, operations.ordinal";
/// Schema versions before six have neither a blocked status nor its columns, so
/// a read-only journal opened on one reports every plan as pending or completed.
const LEGACY_PLAN_QUERY: &str = "SELECT plans.id, plans.path, plans.status, NULL, NULL, \
     operations.id, operations.ordinal, operations.operation_json, operations.status \
     FROM plans JOIN operations ON operations.plan_id = plans.id \
     WHERE plans.status = ?1 ORDER BY plans.id, operations.ordinal";
const DELETE_REMOTE_DESCENDANTS: &str = "DELETE FROM remote_observations \
    WHERE canonical_path >= ?1 AND canonical_path < ?2";

/// A journal failure with its operation, affected path, and original cause.
#[derive(Debug, Error)]
pub enum JournalError {
    /// The journal file could not be secured for its owner.
    #[error("journal operation `{operation}` failed for `{path}`")]
    File {
        /// Operation being attempted.
        operation: &'static str,
        /// Journal path involved.
        path: PathBuf,
        /// Original filesystem error.
        #[source]
        source: std::io::Error,
    },
    /// SQLite rejected a journal operation.
    #[error("journal operation `{operation}` failed for `{path}`")]
    Sqlite {
        /// Operation being attempted.
        operation: &'static str,
        /// Journal or synchronized path involved.
        path: PathBuf,
        /// Original SQLite error.
        #[source]
        source: rusqlite::Error,
    },
    /// A typed journal payload could not be encoded or decoded.
    #[error("journal operation `{operation}` could not process the record for `{path}`")]
    Json {
        /// Operation being attempted.
        operation: &'static str,
        /// Synchronized path associated with the payload.
        path: PathBuf,
        /// Original serialization error.
        #[source]
        source: serde_json::Error,
    },
    /// Persisted state violates a journal invariant.
    #[error("journal operation `{operation}` found invalid state for `{path}`: {detail}")]
    InvalidState {
        /// Operation being attempted.
        operation: &'static str,
        /// Journal or synchronized path involved.
        path: PathBuf,
        /// Stable explanation without record contents.
        detail: &'static str,
    },
    /// The database was written by a newer or otherwise unsupported schema.
    #[error(
        "journal `{path}` has unsupported schema version {found}; supported version is {supported}"
    )]
    UnsupportedVersion {
        /// Journal database path.
        path: PathBuf,
        /// Version stored in SQLite.
        found: i64,
        /// Version this binary understands.
        supported: i64,
    },
    /// The sync root's filesystem does not record creation times, so the root's identity cannot be kept.
    #[error("sync root `{path}` is on a filesystem that does not record creation times")]
    NoBirthTime {
        /// Canonical sync root path.
        path: PathBuf,
        /// Inode statx reported for the refused directory.
        inode: u64,
    },
}

impl JournalError {
    pub(crate) fn redact_paths(self) -> Self {
        let redacted = || PathBuf::from("[Omabox journal]");
        match self {
            Self::File {
                operation, source, ..
            } => Self::File {
                operation,
                path: redacted(),
                source,
            },
            Self::Sqlite {
                operation, source, ..
            } => Self::Sqlite {
                operation,
                path: redacted(),
                source,
            },
            Self::Json {
                operation, source, ..
            } => Self::Json {
                operation,
                path: redacted(),
                source,
            },
            Self::InvalidState {
                operation, detail, ..
            } => Self::InvalidState {
                operation,
                path: redacted(),
                detail,
            },
            Self::UnsupportedVersion {
                found, supported, ..
            } => Self::UnsupportedVersion {
                path: redacted(),
                found,
                supported,
            },
            Self::NoBirthTime { inode, .. } => Self::NoBirthTime {
                path: PathBuf::from("[Omabox sync root]"),
                inode,
            },
        }
    }
}

/// One path from a complete local inventory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalObservationRecord {
    /// Path relative to the configured sync root.
    pub path: PathBuf,
    /// Complete observation for the path.
    pub observation: LocalObservation,
}

/// Filesystem metadata that identifies the exact bytes hashed during a local scan.
///
/// Unknown fields are ignored so rows from earlier versions, which stored a `device`, still decode.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct LocalFileFingerprint {
    pub(crate) inode: u64,
    pub(crate) size: u64,
    pub(crate) modified_seconds: i64,
    pub(crate) modified_nanoseconds: u64,
    pub(crate) changed_seconds: i64,
    pub(crate) changed_nanoseconds: u64,
}

/// One reusable, verified Dropbox content hash from a complete local scan.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct LocalHashRecord {
    pub(crate) path: PathBuf,
    pub(crate) fingerprint: LocalFileFingerprint,
    pub(crate) content: ContentIdentity,
}

#[derive(Deserialize, Serialize)]
struct LocalHashValue {
    fingerprint: LocalFileFingerprint,
    content: ContentIdentity,
}

/// One path from a complete Dropbox inventory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteObservationRecord {
    /// Dropbox's case-insensitive identity relative to the configured root.
    pub canonical_path: CanonicalPath,
    /// Path relative to the configured sync root.
    pub path: PathBuf,
    /// Complete observation for the path, including its Dropbox revision.
    pub observation: RemoteObservation,
}

/// A complete remote inventory and the cursor that produced it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteInventory {
    /// Cursor committed with these observations, if an inventory exists.
    pub cursor: Option<String>,
    /// Complete set of committed observations.
    pub observations: Vec<RemoteObservationRecord>,
}

/// Durable common state with its display and Dropbox-canonical paths.
pub(crate) struct BaselineRecord {
    pub(crate) canonical_path: CanonicalPath,
    pub(crate) path: PathBuf,
    pub(crate) baseline: Baseline,
}

/// One ordered mutation from a validated Dropbox cursor continuation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum RemoteInventoryChange {
    /// Insert or replace one observed path by canonical Dropbox identity.
    Upsert(RemoteObservationRecord),
    /// Materialize a missing ancestor without replacing its authoritative casing.
    EnsureDirectory(RemoteObservationRecord),
    /// Remove one path and every descendant below it.
    DeleteSubtree { canonical_path: CanonicalPath },
}

/// Dropbox account and root permanently associated with this journal.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DropboxBinding {
    /// Stable Dropbox account identifier.
    pub account_id: String,
    /// Dropbox root namespace identifier for the account.
    pub root_namespace_id: String,
    /// Configured path within that namespace.
    pub remote_root: String,
}

/// Result of binding a journal to a Dropbox account and root.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DropboxBindingWrite {
    /// The journal was unbound and now holds the requested binding.
    Bound,
    /// The journal already held the requested binding.
    AlreadyBound,
    /// The journal is bound to a different account or root and was not changed.
    Mismatch {
        /// Binding that remains stored in the journal.
        existing: DropboxBinding,
    },
}

/// Filesystem identity of the configured local synchronization root.
///
/// The device number is not part of the identity: btrfs assigns each subvolume
/// a new anonymous device number at every mount, so the same directory reports
/// a different one after a reboot. Inode, birth time and subvolume live on disk.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalRootBinding {
    /// Canonical absolute path selected by the user.
    pub canonical_path: PathBuf,
    /// Inode identity returned by the local filesystem.
    pub inode: u64,
    /// Creation time of the root directory. `None` only for a binding recorded
    /// by a schema-6 journal, before birth times were kept.
    pub birth: Option<BirthTime>,
    /// The filesystem's subvolume ID when statx reports one (btrfs, bcachefs),
    /// else `None`.
    pub subvolume: Option<u64>,
}

/// Creation time of a filesystem object, as statx reports it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BirthTime {
    /// Seconds since the Unix epoch.
    pub seconds: i64,
    /// Nanoseconds within the second, below one billion.
    pub nanoseconds: u32,
}

/// `STATX_SUBVOL` from include/uapi/linux/stat.h (since Linux 6.10), which
/// rustix 1.1.4's `StatxFlags` does not name.
const STATX_SUBVOL: rustix::fs::StatxFlags = rustix::fs::StatxFlags::from_bits_retain(0x8000);

/// Fields every root identity statx asks the kernel for.
pub(crate) const ROOT_IDENTITY_STATX: rustix::fs::StatxFlags = rustix::fs::StatxFlags::INO
    .union(rustix::fs::StatxFlags::BTIME)
    .union(STATX_SUBVOL);

impl LocalRootBinding {
    /// Inspect one canonical local root path and capture its filesystem identity.
    pub fn inspect(canonical_path: impl AsRef<Path>) -> Result<Self, JournalError> {
        let canonical_path = canonical_path.as_ref().to_path_buf();
        let failure = |source| JournalError::File {
            operation: "inspect local root",
            path: canonical_path.clone(),
            source,
        };
        let statx = rustix::fs::statx(
            rustix::fs::CWD,
            &canonical_path,
            rustix::fs::AtFlags::empty(),
            ROOT_IDENTITY_STATX.union(rustix::fs::StatxFlags::TYPE),
        )
        .map_err(|errno| failure(std::io::Error::from(errno)))?;
        let mode = rustix::fs::RawMode::from(statx.stx_mode);
        if rustix::fs::FileType::from_raw_mode(mode) != rustix::fs::FileType::Directory {
            return Err(failure(std::io::Error::new(
                std::io::ErrorKind::NotADirectory,
                "configured local root is not a directory",
            )));
        }
        Self::from_statx(canonical_path.clone(), &statx)
    }

    /// Capture the identity of the root that `statx` describes.
    pub(crate) fn from_statx(
        canonical_path: PathBuf,
        statx: &rustix::fs::Statx,
    ) -> Result<Self, JournalError> {
        Self::from_statx_fields(
            canonical_path,
            rustix::fs::StatxFlags::from_bits_retain(statx.stx_mask),
            statx.stx_ino,
            BirthTime {
                seconds: statx.stx_btime.tv_sec,
                nanoseconds: statx.stx_btime.tv_nsec,
            },
            statx.stx_subvol,
        )
    }

    /// Build an identity from the mask statx returned and its raw fields;
    /// `Statx` is non-exhaustive, so tests reach the decision through here.
    fn from_statx_fields(
        canonical_path: PathBuf,
        mask: rustix::fs::StatxFlags,
        inode: u64,
        birth: BirthTime,
        subvolume: u64,
    ) -> Result<Self, JournalError> {
        if !mask.contains(rustix::fs::StatxFlags::BTIME) {
            return Err(JournalError::NoBirthTime {
                path: canonical_path,
                inode,
            });
        }
        Ok(Self {
            canonical_path,
            inode,
            birth: Some(birth),
            subvolume: mask.contains(STATX_SUBVOL).then_some(subvolume),
        })
    }
}

/// Active local root and the generation of baselines that belongs to it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalRootRecord {
    /// Bound path and filesystem object identity.
    pub binding: LocalRootBinding,
    /// Monotonically increasing root generation.
    pub generation: u64,
}

impl LocalRootRecord {
    /// Whether a refusal for missing birth times means another directory stands at
    /// this root's path, such as the mount point under an absent mount: the
    /// recorded root had a birth time, or, recorded before schema 7, another inode.
    pub(crate) fn stood_in_by(&self, error: &JournalError) -> bool {
        matches!(
            error,
            JournalError::NoBirthTime { path, inode }
                if *path == self.binding.canonical_path
                    && (self.binding.birth.is_some() || self.binding.inode != *inode)
        )
    }
}

/// Result of activating a configured local root.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LocalRootActivation {
    /// A new root generation was activated and local state was reset.
    Activated(LocalRootRecord),
    /// This exact root is already current.
    Current(LocalRootRecord),
    /// The configured path now names a different filesystem object.
    Unavailable {
        /// Root identity previously accepted for this path.
        recorded: LocalRootBinding,
        /// Root identity currently found at this path.
        actual: LocalRootBinding,
    },
}

/// Durable identity of a plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlanId(i64);

/// Durable identity of an operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OperationId(i64);

impl OperationId {
    pub(crate) fn to_be_bytes(self) -> [u8; 8] {
        self.0.to_be_bytes()
    }

    #[cfg(test)]
    pub(crate) fn for_test(value: i64) -> Self {
        Self(value)
    }
}

/// Durable identity of a recovery record.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RecoveryId(i64);

/// Whether durable work remains.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecordStatus {
    /// The effect or recovery work still needs to finish.
    Pending,
    /// The work finished durably.
    Completed,
}

/// One ordered operation belonging to a durable plan.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlannedOperation {
    /// Durable operation identity.
    pub id: OperationId,
    /// Zero-based execution order within the plan.
    pub ordinal: u32,
    /// Existing planner operation, including its safety preconditions.
    pub operation: Operation,
    /// Durable completion state.
    pub status: RecordStatus,
}

/// A durable per-path plan.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanRecord {
    /// Durable plan identity.
    pub id: PlanId,
    /// Path affected by the plan.
    pub path: PathBuf,
    /// Operations in their required execution order.
    pub operations: Vec<PlannedOperation>,
    /// Durable plan state.
    pub status: PlanStatus,
}

/// Durable state of one per-path plan.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PlanStatus {
    /// The plan is ready for its next effect.
    Pending,
    /// A classified per-path failure holds the plan until `retry_at`.
    Blocked {
        /// Why this path cannot progress.
        reason: BlockReason,
        /// Earliest retry in seconds since the Unix epoch.
        retry_at: u64,
    },
    /// The plan finished durably or was superseded.
    Completed,
}

/// Why one path cannot make progress until its cause is retried or cleared.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum BlockReason {
    /// The source exceeds the supported file-size limit; only changed input can retry.
    UnsupportedFileSize,
    /// Dropbox rejected the mutation with this documented tag.
    RemoteRejected {
        /// Documented Dropbox error tag.
        tag: String,
    },
    /// An exact download answered with this client-error status.
    DownloadUnavailable {
        /// HTTP status returned by Dropbox.
        status: u16,
    },
    /// Downloaded bytes did not match their expected hash, size, or revision.
    DownloadVerificationFailed,
    /// Unrelated bytes occupy the staging slot for this path.
    StageOccupied,
    /// A local object blocks the target path or one of its parents.
    LocalObjectInWay,
    /// Dropbox holds a folder or unsupported object where a file is expected.
    RemoteObject,
}

/// Result of holding a live plan until its cause is retried.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlanBlock {
    /// The plan does not exist.
    NotFound,
    /// The plan already finished, so nothing was blocked.
    AlreadyCompleted,
    /// The reason and retry time were committed.
    Blocked,
}

/// Result of returning a blocked plan to pending work.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlanUnblock {
    /// The plan does not exist.
    NotFound,
    /// The plan is not blocked, so nothing changed.
    NotBlocked,
    /// The plan is pending again.
    Unblocked,
}

/// Result of recording a plan intent.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PlanWrite {
    /// A new plan was committed.
    Recorded(PlanRecord),
    /// The path already owns a live plan; that committed plan is returned.
    AlreadyLive(PlanRecord),
}

/// Result of recording a planner-approved transition with no effects.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NoOpWrite {
    /// The observed baseline was committed.
    Recorded,
    /// A live effect plan owns the path, so the baseline was not changed.
    LivePlan(PlanId),
}

/// Result of committing one reconciliation's journal-only decisions together.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct ReconciliationWrite {
    pub(crate) recorded_noops: usize,
    pub(crate) recorded_plans: usize,
    /// Paths whose decision was not recorded because a live plan already owns
    /// them; a live plan is pending or blocked.
    pub(crate) live_paths: Vec<PathBuf>,
}

/// Result of completing one ordered operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OperationCompletion {
    /// The operation does not exist.
    NotFound,
    /// The operation was already completed.
    AlreadyCompleted,
    /// An earlier operation in the same plan remains pending.
    WaitingForEarlierOperation(OperationId),
    /// A final operation requires its actual resulting baseline.
    BaselineRequired,
    /// A non-final operation cannot advance the baseline.
    UnexpectedBaseline,
    /// The supplied baseline does not match the final operation's result.
    BaselineMismatch,
    /// This operation completed, while later work remains.
    OperationCompleted,
    /// This was the final operation; its plan and baseline completed atomically.
    PlanCompleted,
}

/// One durable conflict preserving the planner's full payload description.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConflictRecord {
    /// Durable conflict identity.
    pub id: i64,
    /// Conflicting path.
    pub path: PathBuf,
    /// Existing planner conflict value.
    pub conflict: Conflict,
}

/// Result of finishing a pending plan as a conflict.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlanConflictCompletion {
    /// The plan does not exist.
    NotFound,
    /// The plan was already completed, so no conflict was added.
    AlreadyCompleted,
    /// The conflict and plan completion were committed together.
    Recorded,
}

/// Result of retiring a stale pending plan without changing its baseline.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlanSupersede {
    /// The plan does not exist.
    NotFound,
    /// The plan was already completed.
    AlreadyCompleted,
    /// Pending operations and the plan were retired transactionally.
    Superseded,
}

/// A legacy recovery copy retained from an older Omabox version.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryRecord {
    /// Durable recovery identity.
    pub id: RecoveryId,
    /// Operation that originally created this recovery record.
    pub operation_id: OperationId,
    /// Original synchronized path.
    pub original_path: PathBuf,
    /// Destination in the recovery area.
    pub recovery_path: PathBuf,
    /// Identity of the retained bytes.
    pub content: ContentIdentity,
    /// Durable completion state.
    pub status: RecordStatus,
    /// Retention start in seconds since the Unix epoch, set when destructive work commits.
    pub retained_at: Option<u64>,
}

/// Result of recording recovery intent.
#[cfg(test)]
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RecoveryWrite {
    /// A new recovery intent was committed.
    Recorded(RecoveryRecord),
    /// Recovery intent was already committed for this operation.
    AlreadyRecorded(RecoveryRecord),
    /// The referenced operation does not exist.
    OperationNotFound,
    /// The referenced operation has already completed.
    OperationCompleted,
    /// The referenced operation does not replace or delete content.
    OperationNotDestructive,
}

/// Result of completing a recovery record.
#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryCompletion {
    /// The recovery record does not exist.
    NotFound,
    /// The recovery record was already completed.
    AlreadyCompleted,
    /// The recovery record was completed durably.
    Completed,
}

/// Result of forgetting retained recovery metadata after its payload was removed.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryForget {
    /// The recovery record does not exist.
    NotFound,
    /// The recovery payload may still be needed by unfinished work.
    Pending,
    /// Completed recovery metadata was removed.
    Forgotten,
}

/// SQLite-backed durable synchronization journal.
pub struct Journal {
    connection: Connection,
    database_path: PathBuf,
    schema_version: i64,
}

impl Journal {
    /// Open a journal and apply its migration.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, JournalError> {
        let path = path.as_ref().to_path_buf();
        create_owner_only(&path).map_err(|source| JournalError::File {
            operation: "create journal database",
            path: path.clone(),
            source,
        })?;
        // The guard above cannot outlast its own check, so SQLite is told not to
        // follow a link that appears between the two opens.
        let mut connection = Connection::open_with_flags(
            &path,
            OpenFlags::default() | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )
        .map_err(|source| JournalError::Sqlite {
            operation: "open journal",
            path: path.clone(),
            source,
        })?;
        set_busy_timeout(&connection, &path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).map_err(
            |source| JournalError::File {
                operation: "restrict journal permissions",
                path: path.clone(),
                source,
            },
        )?;
        let version = connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
            .map_err(|source| JournalError::Sqlite {
                operation: "read journal schema version",
                path: path.clone(),
                source,
            })?;
        if !(0..=SCHEMA_VERSION).contains(&version) {
            return Err(JournalError::UnsupportedVersion {
                path,
                found: version,
                supported: SCHEMA_VERSION,
            });
        }
        configure_writable(&connection, &path)?;
        if version < SCHEMA_VERSION {
            let transaction = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|source| JournalError::Sqlite {
                    operation: "begin journal migration",
                    path: path.clone(),
                    source,
                })?;
            if version == 0 {
                transaction
                    .execute_batch(MIGRATION_V1)
                    .map_err(|source| JournalError::Sqlite {
                        operation: "apply journal version-one migration",
                        path: path.clone(),
                        source,
                    })?;
            }
            if version < 2 {
                transaction
                    .execute_batch(MIGRATION_V2)
                    .map_err(|source| JournalError::Sqlite {
                        operation: "apply journal version-two migration",
                        path: path.clone(),
                        source,
                    })?;
            }
            if version < 3 {
                transaction
                    .execute_batch(MIGRATION_V3)
                    .map_err(|source| JournalError::Sqlite {
                        operation: "apply journal version-three migration",
                        path: path.clone(),
                        source,
                    })?;
            }
            if version < 4 {
                transaction
                    .execute_batch(MIGRATION_V4)
                    .map_err(|source| JournalError::Sqlite {
                        operation: "apply journal version-four migration",
                        path: path.clone(),
                        source,
                    })?;
                migrate_canonical_paths(&transaction, &path)?;
            }
            if version < 5 {
                transaction
                    .execute_batch(MIGRATION_V5)
                    .map_err(|source| JournalError::Sqlite {
                        operation: "apply journal version-five migration",
                        path: path.clone(),
                        source,
                    })?;
            }
            if version < 6 {
                migrate_blocked_plans(&transaction, &path)?;
            }
            if version < 7 {
                transaction
                    .execute_batch(MIGRATION_V7)
                    .map_err(|source| JournalError::Sqlite {
                        operation: "apply journal version-seven migration",
                        path: path.clone(),
                        source,
                    })?;
            }
            transaction
                .commit()
                .map_err(|source| JournalError::Sqlite {
                    operation: "commit journal migration",
                    path: path.clone(),
                    source,
                })?;
        }

        let mut journal = Self {
            connection,
            database_path: path,
            schema_version: SCHEMA_VERSION,
        };
        let _ = journal.prune_completed_work()?;
        Ok(journal)
    }

    /// Open an existing supported journal without creating or changing it.
    pub fn open_read_only(path: impl AsRef<Path>) -> Result<Self, JournalError> {
        let path = path.as_ref().to_path_buf();
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )
        .map_err(|source| JournalError::Sqlite {
            operation: "open journal read-only",
            path: path.clone(),
            source,
        })?;
        set_busy_timeout(&connection, &path)?;
        let version = connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))
            .map_err(|source| JournalError::Sqlite {
                operation: "read journal schema version",
                path: path.clone(),
                source,
            })?;
        if !(1..=SCHEMA_VERSION).contains(&version) {
            return Err(JournalError::UnsupportedVersion {
                path,
                found: version,
                supported: SCHEMA_VERSION,
            });
        }
        Ok(Self {
            connection,
            database_path: path,
            schema_version: version,
        })
    }

    /// Return the Dropbox account and root bound to this journal, if setup completed.
    pub fn dropbox_binding(&self) -> Result<Option<DropboxBinding>, JournalError> {
        self.connection
            .query_row(
                "SELECT account_id, root_namespace_id, remote_root \
                 FROM dropbox_binding WHERE singleton = 1",
                [],
                |row| {
                    Ok(DropboxBinding {
                        account_id: row.get(0)?,
                        root_namespace_id: row.get(1)?,
                        remote_root: row.get(2)?,
                    })
                },
            )
            .optional()
            .map_err(|source| {
                sqlite(
                    "read Dropbox account and root binding",
                    &self.database_path,
                    source,
                )
            })
    }

    /// Bind this journal to one Dropbox account and root without replacing an existing binding.
    pub fn bind_dropbox_root(
        &mut self,
        binding: &DropboxBinding,
    ) -> Result<DropboxBindingWrite, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin Dropbox root binding", &database_path, source))?;
        let inserted = transaction
            .execute(
                "INSERT INTO dropbox_binding(\
                     singleton, account_id, root_namespace_id, remote_root\
                 ) VALUES (1, ?1, ?2, ?3)\
                 ON CONFLICT(singleton) DO NOTHING",
                params![
                    binding.account_id,
                    binding.root_namespace_id,
                    binding.remote_root
                ],
            )
            .map_err(|source| sqlite("bind Dropbox account and root", &database_path, source))?;
        let outcome = if inserted == 1 {
            DropboxBindingWrite::Bound
        } else {
            let existing = transaction
                .query_row(
                    "SELECT account_id, root_namespace_id, remote_root \
                     FROM dropbox_binding WHERE singleton = 1",
                    [],
                    |row| {
                        Ok(DropboxBinding {
                            account_id: row.get(0)?,
                            root_namespace_id: row.get(1)?,
                            remote_root: row.get(2)?,
                        })
                    },
                )
                .map_err(|source| {
                    sqlite(
                        "read Dropbox account and root binding",
                        &database_path,
                        source,
                    )
                })?;
            if existing == *binding {
                DropboxBindingWrite::AlreadyBound
            } else {
                DropboxBindingWrite::Mismatch { existing }
            }
        };
        transaction
            .commit()
            .map_err(|source| sqlite("commit Dropbox root binding", &database_path, source))?;
        Ok(outcome)
    }

    /// Return the local root identity and generation, if one is active.
    pub fn local_root_binding(&self) -> Result<Option<LocalRootRecord>, JournalError> {
        if self.schema_version < 2 {
            return Ok(None);
        }
        read_local_root(&self.connection, &self.database_path, self.schema_version)
    }

    /// Activate a local root without carrying another root's deletion history into it.
    pub fn activate_local_root(
        &mut self,
        binding: &LocalRootBinding,
    ) -> Result<LocalRootActivation, JournalError> {
        let database_path = self.database_path.clone();
        let existing = read_local_root(&self.connection, &database_path, self.schema_version)?;
        if let Some(outcome) = local_root_activation_without_write(existing.as_ref(), binding) {
            return Ok(outcome);
        }
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin local root activation", &database_path, source))?;
        let existing = read_local_root(&transaction, &database_path, self.schema_version)?;
        if let Some(outcome) = local_root_activation_without_write(existing.as_ref(), binding) {
            return Ok(outcome);
        }
        let outcome = activate_or_upgrade_local_root(
            &transaction,
            existing.as_ref(),
            binding,
            &database_path,
        )?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit local root activation", &database_path, source))?;
        Ok(outcome)
    }

    /// Explicitly adopt a selected root, including a replacement at the same path.
    pub fn adopt_local_root(
        &mut self,
        binding: &LocalRootBinding,
    ) -> Result<LocalRootActivation, JournalError> {
        let database_path = self.database_path.clone();
        let existing = read_local_root(&self.connection, &database_path, self.schema_version)?;
        if let Some(record) = &existing
            && record.binding == *binding
        {
            return Ok(LocalRootActivation::Current(record.clone()));
        }
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin local root adoption", &database_path, source))?;
        let existing = read_local_root(&transaction, &database_path, self.schema_version)?;
        if let Some(record) = &existing
            && record.binding == *binding
        {
            return Ok(LocalRootActivation::Current(record.clone()));
        }
        let outcome = activate_or_upgrade_local_root(
            &transaction,
            existing.as_ref(),
            binding,
            &database_path,
        )?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit local root adoption", &database_path, source))?;
        Ok(outcome)
    }

    /// Publish a complete local inventory as one replacement transaction.
    #[cfg(test)]
    pub fn publish_local_inventory(
        &mut self,
        observations: &[LocalObservationRecord],
    ) -> Result<(), JournalError> {
        let encoded = observations
            .iter()
            .map(|record| {
                encode(
                    &record.observation,
                    "serialize local observation",
                    &record.path,
                )
                .map(|json| (path_bytes(&record.path), json))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| {
                sqlite("begin local inventory publication", &database_path, source)
            })?;
        transaction
            .execute("DELETE FROM local_observations", [])
            .map_err(|source| sqlite("replace local inventory", &database_path, source))?;
        for (path, json) in encoded {
            transaction
                .execute(
                    "INSERT INTO local_observations(path, observation_json) VALUES (?1, ?2)",
                    params![path, json],
                )
                .map_err(|source| sqlite("publish local observation", &database_path, source))?;
        }
        transaction
            .commit()
            .map_err(|source| sqlite("commit local inventory", &database_path, source))
    }

    /// Load verified hashes belonging to the active local-root generation.
    pub(crate) fn local_hash_cache(&self) -> Result<Vec<LocalHashRecord>, JournalError> {
        if self.schema_version < 3 {
            return Ok(Vec::new());
        }
        read_local_hash_cache(&self.connection, &self.database_path)
    }

    /// Atomically replace the complete local inventory and its bounded hash cache.
    ///
    /// Returns `false` without writing when `binding` is no longer the active root.
    pub(crate) fn publish_local_scan(
        &mut self,
        binding: &LocalRootBinding,
        observations: &[LocalObservationRecord],
        hashes: &[LocalHashRecord],
    ) -> Result<bool, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin local scan publication", &database_path, source))?;
        let Some(active) = read_local_root(&transaction, &database_path, self.schema_version)?
        else {
            return Ok(false);
        };
        if active.binding != *binding {
            return Ok(false);
        }
        let stored_observations = read_local_inventory(&transaction, &database_path)?;
        if stored_observations.as_slice() == observations {
            let stored_hashes = read_local_hash_cache(&transaction, &database_path)?;
            if stored_hashes.as_slice() == hashes {
                return Ok(true);
            }
        }
        let generation =
            i64::try_from(active.generation).map_err(|_| JournalError::InvalidState {
                operation: "publish local hash cache",
                path: database_path.clone(),
                detail: "local root generation exceeds SQLite integer range",
            })?;
        transaction
            .execute("DELETE FROM local_observations", [])
            .map_err(|source| sqlite("replace local inventory", &database_path, source))?;
        transaction
            .execute("DELETE FROM local_hash_cache", [])
            .map_err(|source| sqlite("replace local hash cache", &database_path, source))?;
        {
            let mut statement = transaction
                .prepare("INSERT INTO local_observations(path, observation_json) VALUES (?1, ?2)")
                .map_err(|source| {
                    sqlite(
                        "prepare local observation publication",
                        &database_path,
                        source,
                    )
                })?;
            for record in observations {
                let json = encode(
                    &record.observation,
                    "serialize local observation",
                    &record.path,
                )?;
                statement
                    .execute(params![path_bytes(&record.path), json])
                    .map_err(|source| {
                        sqlite("publish local observation", &database_path, source)
                    })?;
            }
        }
        {
            let mut statement = transaction
                .prepare(
                    "INSERT INTO local_hash_cache(\
                         root_generation, path, hash_json\
                     ) VALUES (?1, ?2, ?3)",
                )
                .map_err(|source| {
                    sqlite("prepare local hash publication", &database_path, source)
                })?;
            for record in hashes {
                if !is_dropbox_content_hash(record.content.as_str()) {
                    return Err(JournalError::InvalidState {
                        operation: "publish local hash cache",
                        path: record.path.clone(),
                        detail: "cached content identity is not a Dropbox content hash",
                    });
                }
                let value = LocalHashValue {
                    fingerprint: record.fingerprint.clone(),
                    content: record.content.clone(),
                };
                let json = encode(&value, "serialize local hash cache", &record.path)?;
                statement
                    .execute(params![generation, path_bytes(&record.path), json])
                    .map_err(|source| sqlite("publish local hash", &database_path, source))?;
            }
        }
        transaction
            .commit()
            .map_err(|source| sqlite("commit local scan", &database_path, source))?;
        Ok(true)
    }

    /// Load the complete committed local inventory.
    pub fn local_inventory(&self) -> Result<Vec<LocalObservationRecord>, JournalError> {
        read_local_inventory(&self.connection, &self.database_path)
    }

    /// Publish a complete remote inventory and its cursor in one transaction.
    pub fn publish_remote_inventory(
        &mut self,
        cursor: &str,
        observations: &[RemoteObservationRecord],
    ) -> Result<(), JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| {
                sqlite("begin remote inventory publication", &database_path, source)
            })?;
        transaction
            .execute("DELETE FROM remote_observations", [])
            .map_err(|source| sqlite("replace remote inventory", &database_path, source))?;
        {
            let mut statement = transaction
                .prepare(
                    "INSERT INTO remote_observations(\
                         path, observation_json, canonical_path\
                     ) VALUES (?1, ?2, ?3)",
                )
                .map_err(|source| {
                    sqlite(
                        "prepare remote inventory publication",
                        &database_path,
                        source,
                    )
                })?;
            for record in observations {
                let json = encode(
                    &record.observation,
                    "serialize remote observation",
                    &record.path,
                )?;
                statement
                    .execute(params![
                        path_bytes(&record.path),
                        json,
                        record.canonical_path.as_bytes()
                    ])
                    .map_err(|source| {
                        sqlite("publish remote observation", &database_path, source)
                    })?;
            }
        }
        transaction
            .execute(
                "INSERT INTO remote_inventory(singleton, cursor) VALUES (1, ?1) \
                 ON CONFLICT(singleton) DO UPDATE SET cursor = excluded.cursor",
                [cursor],
            )
            .map_err(|source| sqlite("publish remote cursor", &database_path, source))?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit remote inventory", &database_path, source))
    }

    /// Apply validated cursor changes and publish their final cursor atomically.
    pub(crate) fn apply_remote_inventory_delta(
        &mut self,
        cursor: &str,
        changes: &[RemoteInventoryChange],
    ) -> Result<(), JournalError> {
        enum EncodedChange {
            Upsert {
                path: Vec<u8>,
                canonical_path: Vec<u8>,
                observation: String,
            },
            EnsureDirectory {
                path: Vec<u8>,
                canonical_path: Vec<u8>,
                observation: String,
            },
            DeleteSubtree {
                canonical_path: Vec<u8>,
                descendant_prefix: Vec<u8>,
                descendant_end: Vec<u8>,
            },
        }

        let encoded = changes
            .iter()
            .map(|change| match change {
                RemoteInventoryChange::Upsert(record)
                | RemoteInventoryChange::EnsureDirectory(record) => {
                    if record.canonical_path != CanonicalPath::from_display(&record.path) {
                        return Err(JournalError::InvalidState {
                            operation: "validate remote inventory delta",
                            path: record.path.clone(),
                            detail: "canonical path does not match display path",
                        });
                    }
                    let path = path_bytes(&record.path);
                    let canonical_path = record.canonical_path.as_bytes().to_vec();
                    let observation = encode(
                        &record.observation,
                        "serialize remote inventory delta",
                        &record.path,
                    )?;
                    if matches!(change, RemoteInventoryChange::EnsureDirectory(_)) {
                        if record.observation != Observation::Directory {
                            return Err(JournalError::InvalidState {
                                operation: "validate remote inventory delta",
                                path: record.path.clone(),
                                detail: "ensured remote ancestor is not a directory",
                            });
                        }
                        Ok(EncodedChange::EnsureDirectory {
                            path,
                            canonical_path,
                            observation,
                        })
                    } else {
                        Ok(EncodedChange::Upsert {
                            path,
                            canonical_path,
                            observation,
                        })
                    }
                }
                RemoteInventoryChange::DeleteSubtree { canonical_path } => {
                    if canonical_path.as_bytes().is_empty() {
                        return Err(JournalError::InvalidState {
                            operation: "validate remote inventory delta",
                            path: canonical_path.as_path().to_path_buf(),
                            detail: "subtree deletion path is empty",
                        });
                    }
                    let (descendant_prefix, descendant_end) = canonical_path.subtree_range();
                    Ok(EncodedChange::DeleteSubtree {
                        canonical_path: canonical_path.as_bytes().to_vec(),
                        descendant_prefix,
                        descendant_end,
                    })
                }
            })
            .collect::<Result<Vec<_>, _>>()?;
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin remote inventory delta", &database_path, source))?;
        for change in encoded {
            match change {
                EncodedChange::Upsert {
                    path,
                    canonical_path,
                    observation,
                } => {
                    transaction
                        .execute(
                            "INSERT INTO remote_observations(\
                                 path, observation_json, canonical_path\
                             ) VALUES (?1, ?2, ?3) \
                             ON CONFLICT(canonical_path) DO UPDATE SET \
                                 path = excluded.path, \
                                 observation_json = excluded.observation_json \
                             WHERE path != excluded.path \
                                OR observation_json != excluded.observation_json",
                            params![path, observation, canonical_path],
                        )
                        .map_err(|source| {
                            sqlite("upsert remote inventory delta", &database_path, source)
                        })?;
                }
                EncodedChange::EnsureDirectory {
                    path,
                    canonical_path,
                    observation,
                } => {
                    transaction
                        .execute(
                            "INSERT INTO remote_observations(\
                                 path, observation_json, canonical_path\
                             ) VALUES (?1, ?2, ?3) \
                             ON CONFLICT(canonical_path) DO UPDATE SET \
                                 observation_json = excluded.observation_json \
                             WHERE observation_json != excluded.observation_json",
                            params![path, observation, canonical_path],
                        )
                        .map_err(|source| {
                            sqlite("ensure remote inventory directory", &database_path, source)
                        })?;
                }
                EncodedChange::DeleteSubtree {
                    canonical_path,
                    descendant_prefix,
                    descendant_end,
                } => {
                    transaction
                        .execute(
                            "DELETE FROM remote_observations WHERE canonical_path = ?1",
                            [canonical_path],
                        )
                        .map_err(|source| {
                            sqlite("delete remote inventory path", &database_path, source)
                        })?;
                    transaction
                        .execute(
                            DELETE_REMOTE_DESCENDANTS,
                            params![descendant_prefix, descendant_end],
                        )
                        .map_err(|source| {
                            sqlite(
                                "delete remote inventory descendants",
                                &database_path,
                                source,
                            )
                        })?;
                }
            }
        }
        transaction
            .execute(
                "INSERT INTO remote_inventory(singleton, cursor) VALUES (1, ?1) \
                 ON CONFLICT(singleton) DO UPDATE SET cursor = excluded.cursor",
                [cursor],
            )
            .map_err(|source| sqlite("publish remote delta cursor", &database_path, source))?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit remote inventory delta", &database_path, source))
    }

    /// Load only the committed remote cursor without decoding the full inventory.
    pub fn remote_cursor(&self) -> Result<Option<String>, JournalError> {
        self.connection
            .query_row(
                "SELECT cursor FROM remote_inventory WHERE singleton = 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|source| sqlite("read remote cursor", &self.database_path, source))
    }

    pub(crate) fn remote_directory_paths(
        &self,
    ) -> Result<Vec<(CanonicalPath, PathBuf)>, JournalError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT canonical_path, path FROM remote_observations \
                 WHERE observation_json = '\"Directory\"' ORDER BY canonical_path",
            )
            .map_err(|source| {
                sqlite(
                    "prepare remote directory path query",
                    &self.database_path,
                    source,
                )
            })?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?))
            })
            .map_err(|source| {
                sqlite("query remote directory paths", &self.database_path, source)
            })?;
        rows.map(|row| {
            row.map(|(canonical, path)| (CanonicalPath::from_bytes(canonical), bytes_path(path)))
                .map_err(|source| {
                    sqlite("read remote directory paths", &self.database_path, source)
                })
        })
        .collect()
    }

    /// Load a mutually consistent remote cursor and inventory snapshot.
    pub fn remote_inventory(&mut self) -> Result<RemoteInventory, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction()
            .map_err(|source| sqlite("begin remote inventory read", &database_path, source))?;
        let cursor = transaction
            .query_row(
                "SELECT cursor FROM remote_inventory WHERE singleton = 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|source| sqlite("read remote cursor", &database_path, source))?;
        let observations =
            read_remote_observations(&transaction, &database_path, self.schema_version)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit remote inventory read", &database_path, source))?;
        Ok(RemoteInventory {
            cursor,
            observations,
        })
    }

    /// Read the durable common baseline for a path.
    ///
    /// Baselines can only be written by completing the final operation of a
    /// pending plan; the public API deliberately has no independent setter.
    pub fn baseline(&self, path: &Path) -> Result<Option<Baseline>, JournalError> {
        let canonical_path = CanonicalPath::from_display(path);
        let query = if self.schema_version < 4 {
            "SELECT baseline_json FROM baselines WHERE path = ?1"
        } else {
            "SELECT baseline_json FROM baselines WHERE canonical_path = ?1"
        };
        let json = self
            .connection
            .query_row(
                query,
                [if self.schema_version < 4 {
                    path_bytes(path)
                } else {
                    canonical_path.as_bytes().to_vec()
                }],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|source| sqlite("read baseline", path, source))?;
        let Some(json) = json else {
            return Ok(None);
        };
        match decode(&json, "deserialize baseline", path)? {
            Baseline::Absent => Ok(None),
            baseline @ (Baseline::Present(_) | Baseline::Directory) => Ok(Some(baseline)),
        }
    }

    /// Load every path with a durable common baseline.
    pub fn baseline_paths(&self) -> Result<Vec<PathBuf>, JournalError> {
        let mut statement = self
            .connection
            .prepare("SELECT path FROM baselines WHERE baseline_json != '\"Absent\"' ORDER BY path")
            .map_err(|source| sqlite("prepare baseline path query", &self.database_path, source))?;
        let rows = statement
            .query_map([], |row| row.get::<_, Vec<u8>>(0))
            .map_err(|source| sqlite("query baseline paths", &self.database_path, source))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map(|paths| paths.into_iter().map(bytes_path).collect())
            .map_err(|source| sqlite("read baseline paths", &self.database_path, source))
    }

    /// Load every durable common baseline in Dropbox-canonical path order.
    pub(crate) fn baselines(&self) -> Result<Vec<BaselineRecord>, JournalError> {
        let query = if self.schema_version < 4 {
            "SELECT path, path, baseline_json FROM baselines \
             WHERE baseline_json != '\"Absent\"' ORDER BY path"
        } else {
            "SELECT canonical_path, path, baseline_json FROM baselines \
             WHERE baseline_json != '\"Absent\"' ORDER BY canonical_path"
        };
        let mut statement = self.connection.prepare(query).map_err(|source| {
            sqlite(
                "prepare baseline snapshot query",
                &self.database_path,
                source,
            )
        })?;
        let mut rows = statement
            .query([])
            .map_err(|source| sqlite("query baseline snapshot", &self.database_path, source))?;
        let mut records = Vec::new();
        while let Some(row) = rows
            .next()
            .map_err(|source| sqlite("read baseline snapshot", &self.database_path, source))?
        {
            let raw_canonical_path = row.get::<_, Vec<u8>>(0).map_err(|source| {
                sqlite("read baseline canonical path", &self.database_path, source)
            })?;
            let raw_path = row
                .get::<_, Vec<u8>>(1)
                .map_err(|source| sqlite("read baseline path", &self.database_path, source))?;
            let json = row
                .get::<_, String>(2)
                .map_err(|source| sqlite("read baseline payload", &self.database_path, source))?;
            let canonical_path = CanonicalPath::from_bytes(raw_canonical_path);
            let path = bytes_path(raw_path);
            let baseline = decode(&json, "deserialize baseline", &path)?;
            if baseline != Baseline::Absent {
                records.push(BaselineRecord {
                    canonical_path,
                    path,
                    baseline,
                });
            }
        }
        debug_assert!(
            records.is_sorted_by(|left, right| left.canonical_path < right.canonical_path),
            "baseline snapshot is not in canonical path order"
        );
        Ok(records)
    }

    /// Forget common history beneath an automatically renamed case-collision path.
    ///
    /// This is committed before the local rename so the resulting absence can
    /// never be interpreted as a user-requested Dropbox deletion, including
    /// after a crash between the two phases.
    pub(crate) fn invalidate_case_collision_baselines(
        &mut self,
        path: &Path,
    ) -> Result<(), JournalError> {
        let canonical = CanonicalPath::from_display(path);
        let exact = canonical.as_bytes().to_vec();
        if exact.is_empty() {
            return Err(JournalError::InvalidState {
                operation: "invalidate case-collision history",
                path: path.to_path_buf(),
                detail: "case-collision path is empty",
            });
        }
        let (descendants, descendants_end) = canonical.subtree_range();
        self.connection
            .execute(
                "DELETE FROM baselines WHERE canonical_path = ?1 \
                 OR (canonical_path >= ?2 AND canonical_path < ?3)",
                params![exact, descendants, descendants_end],
            )
            .map(|_| ())
            .map_err(|source| sqlite("invalidate case-collision history", path, source))
    }

    /// Record a planner-approved common baseline that requires no effect.
    pub fn record_noop(
        &mut self,
        path: &Path,
        noop: &NoOpDecision,
    ) -> Result<NoOpWrite, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin no-op baseline", &database_path, source))?;
        let outcome = record_noop_in(&transaction, path, noop)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit no-op baseline", &database_path, source))?;
        Ok(outcome)
    }

    /// Commit an ordered plan before returning it to an effect executor.
    pub fn record_plan(
        &mut self,
        path: &Path,
        plan: &OperationPlan,
    ) -> Result<PlanWrite, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin plan intent", &database_path, source))?;
        let outcome = record_plan_in(&transaction, &database_path, path, plan)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan intent", &database_path, source))?;
        Ok(outcome)
    }

    /// Commit all journal-only decisions from one complete observation together.
    pub(crate) fn record_reconciliation(
        &mut self,
        noops: &[(PathBuf, NoOpDecision)],
        plans: &[(PathBuf, OperationPlan)],
    ) -> Result<ReconciliationWrite, JournalError> {
        if noops.is_empty() && plans.is_empty() {
            return Ok(ReconciliationWrite::default());
        }
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin reconciliation decisions", &database_path, source))?;
        let mut write = ReconciliationWrite::default();
        for (path, noop) in noops {
            match record_noop_in(&transaction, path, noop)? {
                NoOpWrite::Recorded => write.recorded_noops += 1,
                NoOpWrite::LivePlan(_) => write.live_paths.push(path.clone()),
            }
        }
        for (path, plan) in plans {
            match record_plan_in(&transaction, &database_path, path, plan)? {
                PlanWrite::Recorded(_) => write.recorded_plans += 1,
                PlanWrite::AlreadyLive(_) => write.live_paths.push(path.clone()),
            }
        }
        transaction
            .commit()
            .map_err(|source| sqlite("commit reconciliation decisions", &database_path, source))?;
        Ok(write)
    }

    /// Load every plan awaiting its next effect after startup or interruption.
    pub fn pending_plans(&self) -> Result<Vec<PlanRecord>, JournalError> {
        read_plans_with_status(
            &self.connection,
            &self.database_path,
            self.plan_query(),
            "pending",
            "read pending plans",
        )
    }

    fn plan_query(&self) -> &'static str {
        if self.schema_version >= 6 {
            PLAN_QUERY
        } else {
            LEGACY_PLAN_QUERY
        }
    }

    /// Load every plan held by a classified per-path failure.
    pub fn blocked_plans(&self) -> Result<Vec<PlanRecord>, JournalError> {
        read_plans_with_status(
            &self.connection,
            &self.database_path,
            self.plan_query(),
            "blocked",
            "read blocked plans",
        )
    }

    /// Hold a live plan until its classified cause is worth retrying.
    pub fn block_plan(
        &mut self,
        plan_id: PlanId,
        reason: &BlockReason,
        retry_at: u64,
    ) -> Result<PlanBlock, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin plan block", &database_path, source))?;
        let Some((path, status)) = read_plan_state(
            &transaction,
            &database_path,
            plan_id,
            "read plan status for blocking",
        )?
        else {
            return Ok(PlanBlock::NotFound);
        };
        match status {
            PlanStatus::Completed => return Ok(PlanBlock::AlreadyCompleted),
            PlanStatus::Pending | PlanStatus::Blocked { .. } => {}
        }
        let json = encode(reason, "serialize block reason", &path)?;
        let retry_at = i64::try_from(retry_at).map_err(|_| JournalError::InvalidState {
            operation: "block plan",
            path: path.clone(),
            detail: "retry time exceeds the supported range",
        })?;
        transaction
            .execute(
                "UPDATE plans SET status = 'blocked', blocked_json = ?2, retry_at = ?3 \
                 WHERE id = ?1",
                params![plan_id.0, json, retry_at],
            )
            .map_err(|source| sqlite("block plan", &path, source))?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan block", &database_path, source))?;
        Ok(PlanBlock::Blocked)
    }

    /// Return a blocked plan to pending work for one more attempt.
    pub fn unblock_plan(&mut self, plan_id: PlanId) -> Result<PlanUnblock, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin plan unblock", &database_path, source))?;
        let Some((path, status)) = read_plan_state(
            &transaction,
            &database_path,
            plan_id,
            "read plan status for unblocking",
        )?
        else {
            return Ok(PlanUnblock::NotFound);
        };
        match status {
            PlanStatus::Pending | PlanStatus::Completed => return Ok(PlanUnblock::NotBlocked),
            PlanStatus::Blocked { .. } => {}
        }
        transaction
            .execute(
                "UPDATE plans SET status = 'pending', blocked_json = NULL, retry_at = NULL \
                 WHERE id = ?1",
                [plan_id.0],
            )
            .map_err(|source| sqlite("unblock plan", &path, source))?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan unblock", &database_path, source))?;
        Ok(PlanUnblock::Unblocked)
    }

    /// Return upload payloads still referenced by pending remote mutations.
    pub fn pending_upload_content(&self) -> Result<Vec<ContentIdentity>, JournalError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT plans.path, operations.operation_json \
                 FROM operations JOIN plans ON plans.id = operations.plan_id \
                 WHERE plans.status IN ('pending', 'blocked') \
                   AND operations.status = 'pending' \
                 ORDER BY operations.id",
            )
            .map_err(|source| {
                sqlite(
                    "prepare pending upload content query",
                    &self.database_path,
                    source,
                )
            })?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|source| {
                sqlite("query pending upload content", &self.database_path, source)
            })?;
        let encoded = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|source| sqlite("read pending upload content", &self.database_path, source))?;
        encoded
            .into_iter()
            .filter_map(|(raw_path, json)| {
                let path = bytes_path(raw_path);
                match decode::<Operation>(&json, "deserialize pending upload operation", &path) {
                    Ok(Operation::CreateRemote { content })
                    | Ok(Operation::ReplaceRemote { content, .. }) => Some(Ok(content)),
                    Ok(
                        Operation::CreateLocalDirectory
                        | Operation::CreateRemoteDirectory
                        | Operation::DeleteLocalDirectory
                        | Operation::InstallLocal { .. }
                        | Operation::PreserveLocal { .. }
                        | Operation::ReplaceLocal { .. }
                        | Operation::DeleteLocal { .. }
                        | Operation::PreserveRemote { .. }
                        | Operation::DeleteRemote { .. }
                        | Operation::DeleteRemoteDirectory,
                    ) => None,
                    Err(error) => Some(Err(error)),
                }
            })
            .collect()
    }

    /// Remove completed plan and operation history that no pending recovery needs.
    ///
    /// Completed recovery records are retained independently until their payload
    /// retention policy removes them.
    pub fn prune_completed_work(&mut self) -> Result<usize, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin completed work pruning", &database_path, source))?;
        let plan_ids = {
            let mut statement = transaction
                .prepare(
                    "SELECT plans.id FROM plans \
                     WHERE plans.status = 'completed' \
                     AND NOT EXISTS ( \
                         SELECT 1 FROM operations \
                         JOIN recovery_records \
                           ON recovery_records.operation_id = operations.id \
                         WHERE operations.plan_id = plans.id \
                           AND ( \
                               recovery_records.status = 'pending' \
                               OR recovery_records.retained_at IS NULL \
                           ) \
                     ) \
                     ORDER BY plans.id",
                )
                .map_err(|source| {
                    sqlite("prepare completed plan pruning", &database_path, source)
                })?;
            let rows = statement
                .query_map([], |row| row.get::<_, i64>(0))
                .map_err(|source| sqlite("query completed plan pruning", &database_path, source))?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|source| sqlite("read completed plan pruning", &database_path, source))?
        };
        for plan_id in &plan_ids {
            transaction
                .execute("DELETE FROM operations WHERE plan_id = ?1", [plan_id])
                .map_err(|source| sqlite("prune completed operations", &database_path, source))?;
            transaction
                .execute(
                    "DELETE FROM plans WHERE id = ?1 AND status = 'completed'",
                    [plan_id],
                )
                .map_err(|source| sqlite("prune completed plan", &database_path, source))?;
        }
        transaction
            .commit()
            .map_err(|source| sqlite("commit completed work pruning", &database_path, source))?;
        Ok(plan_ids.len())
    }

    /// Complete one operation in order.
    ///
    /// Completing the final operation updates its plan and actual resulting
    /// baseline in the same transaction. An interruption before that commit
    /// leaves both the operation and baseline unchanged.
    pub fn complete_operation(
        &mut self,
        operation_id: OperationId,
        resulting_baseline: Option<&Baseline>,
    ) -> Result<OperationCompletion, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin operation completion", &database_path, source))?;
        let completion = complete_operation_in(
            &transaction,
            &database_path,
            operation_id,
            resulting_baseline,
        )?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit operation completion", &database_path, source))?;
        Ok(completion)
    }

    /// Complete independent final effects in one atomic journal write.
    pub(crate) fn complete_final_operations(
        &mut self,
        completions: &[(OperationId, Baseline)],
    ) -> Result<Vec<OperationCompletion>, JournalError> {
        if completions.is_empty() {
            return Ok(Vec::new());
        }
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| {
                sqlite("begin final operation completions", &database_path, source)
            })?;
        let outcomes = completions
            .iter()
            .map(|(operation_id, baseline)| {
                complete_operation_in(&transaction, &database_path, *operation_id, Some(baseline))
            })
            .collect::<Result<Vec<_>, _>>()?;
        transaction.commit().map_err(|source| {
            sqlite("commit final operation completions", &database_path, source)
        })?;
        Ok(outcomes)
    }

    /// Record a conflict and retire its pending plan in one transaction.
    pub fn finish_plan_with_conflict(
        &mut self,
        plan_id: PlanId,
        conflict: &Conflict,
    ) -> Result<PlanConflictCompletion, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin plan conflict", &database_path, source))?;
        let Some((path, status)) = read_plan_state(
            &transaction,
            &database_path,
            plan_id,
            "read plan status for conflict",
        )?
        else {
            return Ok(PlanConflictCompletion::NotFound);
        };
        match status {
            PlanStatus::Completed => return Ok(PlanConflictCompletion::AlreadyCompleted),
            PlanStatus::Pending | PlanStatus::Blocked { .. } => {}
        }

        let json = encode(conflict, "serialize plan conflict", &path)?;
        transaction
            .execute(
                "INSERT INTO conflicts(path, conflict_json, canonical_path) VALUES (?1, ?2, ?3)",
                params![
                    path_bytes(&path),
                    json,
                    CanonicalPath::from_display(&path).as_bytes()
                ],
            )
            .map_err(|source| sqlite("record plan conflict", &path, source))?;
        transaction
            .execute(
                "UPDATE operations SET status = 'completed' WHERE plan_id = ?1",
                [plan_id.0],
            )
            .map_err(|source| sqlite("complete conflicted plan operations", &path, source))?;
        transaction
            .execute(FINISH_PLAN, [plan_id.0])
            .map_err(|source| sqlite("complete conflicted plan", &path, source))?;
        start_recovery_retention(&transaction, plan_id.0, &path)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan conflict", &database_path, source))?;
        Ok(PlanConflictCompletion::Recorded)
    }

    /// Retire stale effect intent without advancing or deleting its baseline.
    pub fn supersede_plan(&mut self, plan_id: PlanId) -> Result<PlanSupersede, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin plan supersession", &database_path, source))?;
        let Some((path, status)) = read_plan_state(
            &transaction,
            &database_path,
            plan_id,
            "read plan status for supersession",
        )?
        else {
            return Ok(PlanSupersede::NotFound);
        };
        match status {
            PlanStatus::Completed => return Ok(PlanSupersede::AlreadyCompleted),
            PlanStatus::Pending | PlanStatus::Blocked { .. } => {}
        }
        transaction
            .execute(
                "UPDATE operations SET status = 'completed' WHERE plan_id = ?1",
                [plan_id.0],
            )
            .map_err(|source| sqlite("retire superseded operations", &path, source))?;
        transaction
            .execute(FINISH_PLAN, [plan_id.0])
            .map_err(|source| sqlite("retire superseded plan", &path, source))?;
        start_recovery_retention(&transaction, plan_id.0, &path)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan supersession", &database_path, source))?;
        Ok(PlanSupersede::Superseded)
    }

    /// Persist a planner conflict without interpreting it or discarding a side.
    pub fn record_conflict(
        &mut self,
        path: &Path,
        conflict: &Conflict,
    ) -> Result<ConflictRecord, JournalError> {
        let json = encode(conflict, "serialize conflict", path)?;
        self.connection
            .execute(
                "INSERT INTO conflicts(path, conflict_json, canonical_path) VALUES (?1, ?2, ?3)",
                params![
                    path_bytes(path),
                    json,
                    CanonicalPath::from_display(path).as_bytes()
                ],
            )
            .map_err(|source| sqlite("record conflict", path, source))?;
        Ok(ConflictRecord {
            id: self.connection.last_insert_rowid(),
            path: path.to_path_buf(),
            conflict: conflict.clone(),
        })
    }

    /// Load all durable conflicts.
    pub fn conflicts(&self) -> Result<Vec<ConflictRecord>, JournalError> {
        let mut statement = self
            .connection
            .prepare("SELECT id, path, conflict_json FROM conflicts ORDER BY id")
            .map_err(|source| sqlite("prepare conflict query", &self.database_path, source))?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })
            .map_err(|source| sqlite("query conflicts", &self.database_path, source))?;
        let raw = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|source| sqlite("read conflicts", &self.database_path, source))?;
        raw.into_iter()
            .map(|(id, raw_path, json)| {
                let path = bytes_path(raw_path);
                let conflict = decode(&json, "deserialize conflict", &path)?;
                Ok(ConflictRecord { id, path, conflict })
            })
            .collect()
    }

    /// Commit a legacy recovery intent for compatibility tests.
    #[cfg(test)]
    pub fn record_recovery_intent(
        &mut self,
        operation_id: OperationId,
        recovery_path: &Path,
    ) -> Result<RecoveryWrite, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin recovery intent", &database_path, source))?;
        let operation_row = transaction
            .query_row(
                "SELECT plans.path, operations.operation_json, operations.status, \
                        operations.plan_id, operations.ordinal \
                 FROM operations JOIN plans ON plans.id = operations.plan_id \
                 WHERE operations.id = ?1",
                [operation_id.0],
                |row| {
                    Ok((
                        row.get::<_, Vec<u8>>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                },
            )
            .optional()
            .map_err(|source| sqlite("find recovery operation", &database_path, source))?;
        let Some((raw_original_path, operation_json, status, plan_id, ordinal)) = operation_row
        else {
            return Ok(RecoveryWrite::OperationNotFound);
        };
        let original_path = bytes_path(raw_original_path);
        if let Some(existing) =
            read_recovery_for_operation(&transaction, &database_path, operation_id)?
        {
            return Ok(RecoveryWrite::AlreadyRecorded(existing));
        }
        if decode_status(&status, "read recovery operation status", &original_path)?
            == RecordStatus::Completed
        {
            return Ok(RecoveryWrite::OperationCompleted);
        }
        let operation: Operation = decode(
            &operation_json,
            "deserialize recovery operation",
            &original_path,
        )?;
        if !is_destructive(&operation) {
            return Ok(RecoveryWrite::OperationNotDestructive);
        }
        let previous_json = if let Some(previous) = ordinal.checked_sub(1) {
            transaction
                .query_row(
                    "SELECT operation_json FROM operations \
                     WHERE plan_id = ?1 AND ordinal = ?2",
                    params![plan_id, previous],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(|source| sqlite("find preservation operation", &original_path, source))?
        } else {
            None
        };
        let Some(previous_json) = previous_json else {
            return Err(missing_preservation(&original_path));
        };
        let previous: Operation = decode(
            &previous_json,
            "deserialize preservation operation",
            &original_path,
        )?;
        let Some(content) = displaced_content(&previous, &operation) else {
            return Err(missing_preservation(&original_path));
        };
        let content_json = encode(&content, "serialize recovery content", &original_path)?;

        transaction
            .execute(
                "INSERT INTO recovery_records( \
                     operation_id, original_path, recovery_path, content_json, status \
                 ) VALUES (?1, ?2, ?3, ?4, 'pending')",
                params![
                    operation_id.0,
                    path_bytes(&original_path),
                    path_bytes(recovery_path),
                    content_json
                ],
            )
            .map_err(|source| sqlite("record recovery intent", &original_path, source))?;
        let recovery_id = RecoveryId(transaction.last_insert_rowid());
        let record =
            read_recovery(&transaction, &database_path, recovery_id, true)?.ok_or_else(|| {
                JournalError::InvalidState {
                    operation: "read recorded recovery intent",
                    path: original_path.clone(),
                    detail: "new recovery record disappeared inside its transaction",
                }
            })?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit recovery intent", &database_path, source))?;
        Ok(RecoveryWrite::Recorded(record))
    }

    /// Load every unfinished recovery record after startup or interruption.
    pub fn pending_recoveries(&self) -> Result<Vec<RecoveryRecord>, JournalError> {
        read_recoveries_with_status(
            &self.connection,
            &self.database_path,
            "pending",
            "read pending recovery",
            self.schema_version >= 2,
        )
    }

    /// Load retained recovery metadata whose payload is no longer needed by pending work.
    pub fn completed_recoveries(&self) -> Result<Vec<RecoveryRecord>, JournalError> {
        if self.schema_version < 2 {
            return Ok(Vec::new());
        }
        let mut statement = self
            .connection
            .prepare(
                "SELECT recovery_records.id FROM recovery_records \
                 LEFT JOIN operations ON operations.id = recovery_records.operation_id \
                 LEFT JOIN plans ON plans.id = operations.plan_id \
                 WHERE recovery_records.status = 'completed' \
                   AND recovery_records.retained_at IS NOT NULL \
                   AND ( \
                       operations.id IS NULL \
                       OR (operations.status = 'completed' AND plans.status = 'completed') \
                   ) \
                 ORDER BY recovery_records.id",
            )
            .map_err(|source| {
                sqlite(
                    "prepare completed recovery query",
                    &self.database_path,
                    source,
                )
            })?;
        let rows = statement
            .query_map([], |row| row.get::<_, i64>(0))
            .map_err(|source| sqlite("query completed recoveries", &self.database_path, source))?;
        let ids = rows.collect::<Result<Vec<_>, _>>().map_err(|source| {
            sqlite(
                "read completed recovery identities",
                &self.database_path,
                source,
            )
        })?;
        drop(statement);
        ids.into_iter()
            .map(|id| {
                read_recovery(&self.connection, &self.database_path, RecoveryId(id), true)?
                    .ok_or_else(|| JournalError::InvalidState {
                        operation: "read completed recovery",
                        path: self.database_path.clone(),
                        detail: "eligible recovery disappeared while reading the journal",
                    })
            })
            .collect()
    }

    /// Mark a test recovery record complete without altering its operation or baseline.
    #[cfg(test)]
    pub fn complete_recovery(
        &mut self,
        recovery_id: RecoveryId,
    ) -> Result<RecoveryCompletion, JournalError> {
        let status = self
            .connection
            .query_row(
                "SELECT status FROM recovery_records WHERE id = ?1",
                [recovery_id.0],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|source| sqlite("find recovery", &self.database_path, source))?;
        let Some(status) = status else {
            return Ok(RecoveryCompletion::NotFound);
        };
        if decode_status(&status, "read recovery status", &self.database_path)?
            == RecordStatus::Completed
        {
            return Ok(RecoveryCompletion::AlreadyCompleted);
        }
        self.connection
            .execute(
                "UPDATE recovery_records SET status = 'completed' WHERE id = ?1",
                [recovery_id.0],
            )
            .map_err(|source| sqlite("complete recovery", &self.database_path, source))?;
        Ok(RecoveryCompletion::Completed)
    }

    /// Forget one recovery record only after its payload is no longer pending.
    pub fn forget_completed_recovery(
        &mut self,
        recovery_id: RecoveryId,
    ) -> Result<RecoveryForget, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin recovery forgetting", &database_path, source))?;
        let state = transaction
            .query_row(
                "SELECT recovery_records.status, \
                        recovery_records.retained_at IS NOT NULL AND ( \
                            operations.id IS NULL OR ( \
                                operations.status = 'completed' AND plans.status = 'completed' \
                            ) \
                        ) \
                 FROM recovery_records \
                 LEFT JOIN operations ON operations.id = recovery_records.operation_id \
                 LEFT JOIN plans ON plans.id = operations.plan_id \
                 WHERE recovery_records.id = ?1",
                [recovery_id.0],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)),
            )
            .optional()
            .map_err(|source| sqlite("find recovery to forget", &database_path, source))?;
        let Some((status, eligible)) = state else {
            return Ok(RecoveryForget::NotFound);
        };
        if decode_status(&status, "read recovery status to forget", &database_path)?
            == RecordStatus::Pending
            || !eligible
        {
            return Ok(RecoveryForget::Pending);
        }
        transaction
            .execute(
                "DELETE FROM recovery_records WHERE id = ?1 AND status = 'completed'",
                [recovery_id.0],
            )
            .map_err(|source| sqlite("forget completed recovery", &database_path, source))?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit recovery forgetting", &database_path, source))?;
        Ok(RecoveryForget::Forgotten)
    }
}

/// Wait instead of failing while another connection commits.
///
/// Every connection sets this before its first statement, so a status read
/// during a daemon commit never surfaces as "database is locked".
fn set_busy_timeout(connection: &Connection, database_path: &Path) -> Result<(), JournalError> {
    connection
        .busy_timeout(std::time::Duration::from_millis(BUSY_TIMEOUT_MILLISECONDS))
        .map_err(|source| sqlite("set SQLite busy timeout", database_path, source))
}

fn configure_writable(connection: &Connection, database_path: &Path) -> Result<(), JournalError> {
    connection
        .pragma_update(None, "foreign_keys", true)
        .map_err(|source| sqlite("enable foreign keys", database_path, source))?;
    let journal_mode = connection
        .query_row("PRAGMA journal_mode = DELETE", [], |row| {
            row.get::<_, String>(0)
        })
        .map_err(|source| sqlite("set rollback journal mode", database_path, source))?;
    if !journal_mode.eq_ignore_ascii_case("delete") {
        return Err(JournalError::InvalidState {
            operation: "set rollback journal mode",
            path: database_path.to_path_buf(),
            detail: "SQLite did not enable DELETE journal mode",
        });
    }
    connection
        .pragma_update(None, "synchronous", "FULL")
        .map_err(|source| sqlite("set full SQLite synchronization", database_path, source))?;
    let synchronous = connection
        .query_row("PRAGMA synchronous", [], |row| row.get::<_, i64>(0))
        .map_err(|source| sqlite("verify SQLite synchronization", database_path, source))?;
    if synchronous != 2 {
        return Err(JournalError::InvalidState {
            operation: "verify SQLite synchronization",
            path: database_path.to_path_buf(),
            detail: "SQLite did not enable FULL synchronization",
        });
    }
    Ok(())
}

fn migrate_blocked_plans(
    connection: &Connection,
    database_path: &Path,
) -> Result<(), JournalError> {
    // Version four made the canonical columns unique, so backfilling a null
    // canonical path onto an existing claim would abort the whole migration
    // instead of discarding both claims. The rebuild recreates both indexes.
    connection
        .execute_batch(
            "DROP INDEX baselines_by_canonical_path; \
             DROP INDEX remote_observations_by_canonical_path;",
        )
        .map_err(|source| sqlite("relax canonical path indexes", database_path, source))?;
    for (select, update) in [
        (
            "SELECT rowid, path FROM baselines WHERE canonical_path IS NULL",
            "UPDATE baselines SET canonical_path = ?1 WHERE rowid = ?2",
        ),
        (
            "SELECT rowid, path FROM remote_observations WHERE canonical_path IS NULL",
            "UPDATE remote_observations SET canonical_path = ?1 WHERE rowid = ?2",
        ),
        (
            "SELECT rowid, path FROM conflicts WHERE canonical_path IS NULL",
            "UPDATE conflicts SET canonical_path = ?1 WHERE rowid = ?2",
        ),
        (
            "SELECT rowid, path FROM plans WHERE canonical_path IS NULL",
            "UPDATE plans SET canonical_path = ?1 WHERE rowid = ?2",
        ),
    ] {
        populate_canonical_paths(connection, database_path, select, update)?;
    }
    let sequence = connection
        .query_row(
            "SELECT seq FROM sqlite_sequence WHERE name = 'operations'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|source| sqlite("read operation sequence", database_path, source))?;
    connection
        .execute_batch(MIGRATION_V6)
        .map_err(|source| sqlite("apply journal version-six migration", database_path, source))?;
    if let Some(sequence) = sequence {
        connection
            .execute(
                "INSERT INTO sqlite_sequence(name, seq) SELECT 'operations', ?1 \
                 WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'operations')",
                [sequence],
            )
            .and_then(|_| {
                connection.execute(
                    "UPDATE sqlite_sequence SET seq = ?1 \
                     WHERE name = 'operations' AND seq < ?1",
                    [sequence],
                )
            })
            .map_err(|source| sqlite("restore operation sequence", database_path, source))?;
    }
    let violations = {
        let mut statement = connection
            .prepare("PRAGMA foreign_key_check")
            .map_err(|source| sqlite("prepare foreign key check", database_path, source))?;
        let rows = statement
            .query_map([], |_| Ok(()))
            .map_err(|source| sqlite("run foreign key check", database_path, source))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|source| sqlite("read foreign key check", database_path, source))?
            .len()
    };
    if violations > 0 {
        return Err(JournalError::InvalidState {
            operation: "apply journal version-six migration",
            path: database_path.to_path_buf(),
            detail: "rebuilt plan and operation tables left dangling references",
        });
    }
    // A migration step stamps the version it produces, not whatever the latest
    // schema happens to be, so adding version seven cannot silently relabel it.
    connection
        .pragma_update(None, "user_version", 6)
        .map_err(|source| sqlite("set journal schema version", database_path, source))
}

fn migrate_canonical_paths(
    connection: &Connection,
    database_path: &Path,
) -> Result<(), JournalError> {
    populate_canonical_paths(
        connection,
        database_path,
        "SELECT rowid, path FROM baselines",
        "UPDATE baselines SET canonical_path = ?1 WHERE rowid = ?2",
    )?;
    populate_canonical_paths(
        connection,
        database_path,
        "SELECT rowid, path FROM plans",
        "UPDATE plans SET canonical_path = ?1 WHERE rowid = ?2",
    )?;
    populate_canonical_paths(
        connection,
        database_path,
        "SELECT rowid, path FROM conflicts",
        "UPDATE conflicts SET canonical_path = ?1 WHERE rowid = ?2",
    )?;
    connection
        .execute_batch(
            "DELETE FROM baselines WHERE canonical_path IN ( \
                 SELECT canonical_path FROM baselines \
                 GROUP BY canonical_path HAVING COUNT(*) > 1 \
             ); \
             CREATE UNIQUE INDEX baselines_by_canonical_path \
                 ON baselines(canonical_path); \
             CREATE UNIQUE INDEX remote_observations_by_canonical_path \
                 ON remote_observations(canonical_path); \
             CREATE INDEX plans_by_canonical_path \
                 ON plans(canonical_path); \
             CREATE INDEX conflicts_by_canonical_path \
                 ON conflicts(canonical_path); \
             PRAGMA user_version = 4;",
        )
        .map_err(|source| sqlite("finalize canonical path migration", database_path, source))
}

fn populate_canonical_paths(
    connection: &Connection,
    database_path: &Path,
    select: &str,
    update: &str,
) -> Result<(), JournalError> {
    let rows = {
        let mut statement = connection
            .prepare(select)
            .map_err(|source| sqlite("prepare canonical path migration", database_path, source))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, Vec<u8>>(1)?))
            })
            .map_err(|source| sqlite("query canonical path migration", database_path, source))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|source| sqlite("read canonical path migration", database_path, source))?
    };
    for (row_id, raw_path) in rows {
        let canonical = CanonicalPath::from_display(&bytes_path(raw_path));
        connection
            .execute(update, params![canonical.as_bytes(), row_id])
            .map_err(|source| sqlite("write canonical path migration", database_path, source))?;
    }
    Ok(())
}

fn sqlite(operation: &'static str, path: &Path, source: rusqlite::Error) -> JournalError {
    JournalError::Sqlite {
        operation,
        path: path.to_path_buf(),
        source,
    }
}

fn encode<T: Serialize>(
    value: &T,
    operation: &'static str,
    path: &Path,
) -> Result<String, JournalError> {
    serde_json::to_string(value).map_err(|source| JournalError::Json {
        operation,
        path: path.to_path_buf(),
        source,
    })
}

fn decode<T: DeserializeOwned>(
    json: &str,
    operation: &'static str,
    path: &Path,
) -> Result<T, JournalError> {
    serde_json::from_str(json).map_err(|source| JournalError::Json {
        operation,
        path: path.to_path_buf(),
        source,
    })
}

fn path_bytes(path: &Path) -> Vec<u8> {
    path.as_os_str().as_bytes().to_vec()
}

fn bytes_path(bytes: Vec<u8>) -> PathBuf {
    PathBuf::from(OsString::from_vec(bytes))
}

fn decode_u64(bytes: &[u8], operation: &'static str, path: &Path) -> Result<u64, JournalError> {
    let raw = <[u8; 8]>::try_from(bytes).map_err(|_| JournalError::InvalidState {
        operation,
        path: path.to_path_buf(),
        detail: "filesystem identity has an invalid byte length",
    })?;
    Ok(u64::from_be_bytes(raw))
}

fn is_dropbox_content_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
}

fn decode_status(
    status: &str,
    operation: &'static str,
    path: &Path,
) -> Result<RecordStatus, JournalError> {
    match status {
        "pending" => Ok(RecordStatus::Pending),
        "completed" => Ok(RecordStatus::Completed),
        _ => Err(JournalError::InvalidState {
            operation,
            path: path.to_path_buf(),
            detail: "record has an unrecognized status",
        }),
    }
}

fn decode_plan_status(
    status: &str,
    blocked_json: Option<&str>,
    retry_at: Option<i64>,
    operation: &'static str,
    path: &Path,
) -> Result<PlanStatus, JournalError> {
    let invalid = |detail| JournalError::InvalidState {
        operation,
        path: path.to_path_buf(),
        detail,
    };
    match (status, blocked_json, retry_at) {
        ("pending", None, None) => Ok(PlanStatus::Pending),
        ("completed", None, None) => Ok(PlanStatus::Completed),
        ("blocked", Some(json), Some(retry_at)) => Ok(PlanStatus::Blocked {
            reason: decode(json, "deserialize block reason", path)?,
            retry_at: u64::try_from(retry_at)
                .map_err(|_| invalid("blocked plan has a negative retry time"))?,
        }),
        ("pending" | "completed" | "blocked", _, _) => {
            Err(invalid("plan status disagrees with its block columns"))
        }
        _ => Err(invalid("plan has an unrecognized status")),
    }
}

fn write_baseline(
    connection: &Connection,
    path: &Path,
    baseline: &Baseline,
) -> Result<(), JournalError> {
    let canonical_path = CanonicalPath::from_display(path);
    match baseline {
        Baseline::Absent => connection
            .execute(
                "DELETE FROM baselines WHERE canonical_path = ?1",
                [canonical_path.as_bytes()],
            )
            .map(|_| ())
            .map_err(|source| sqlite("remove absent baseline", path, source)),
        Baseline::Present(_) | Baseline::Directory => {
            let json = encode(baseline, "serialize present baseline", path)?;
            connection
                .execute(
                    "INSERT INTO baselines(path, baseline_json, canonical_path) \
                     VALUES (?1, ?2, ?3) \
                     ON CONFLICT(canonical_path) DO UPDATE SET \
                         path = excluded.path, \
                         baseline_json = excluded.baseline_json \
                     WHERE baselines.path != excluded.path \
                        OR baselines.baseline_json != excluded.baseline_json",
                    params![path_bytes(path), json, canonical_path.as_bytes()],
                )
                .map(|_| ())
                .map_err(|source| sqlite("record present baseline", path, source))
        }
    }
}

fn record_noop_in(
    connection: &Connection,
    path: &Path,
    noop: &NoOpDecision,
) -> Result<NoOpWrite, JournalError> {
    let canonical_path = CanonicalPath::from_display(path);
    let live = connection
        .query_row(
            "SELECT id FROM plans \
             WHERE canonical_path = ?1 AND status IN ('pending', 'blocked')",
            [canonical_path.as_bytes()],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|source| sqlite("find live plan for no-op", path, source))?;
    if let Some(id) = live {
        return Ok(NoOpWrite::LivePlan(PlanId(id)));
    }
    write_baseline(connection, path, noop.baseline())?;
    connection
        .execute(
            "DELETE FROM conflicts WHERE canonical_path = ?1",
            [canonical_path.as_bytes()],
        )
        .map_err(|source| sqlite("retire resolved conflicts", path, source))?;
    Ok(NoOpWrite::Recorded)
}

fn record_plan_in(
    connection: &Connection,
    database_path: &Path,
    path: &Path,
    plan: &OperationPlan,
) -> Result<PlanWrite, JournalError> {
    if plan.operations().is_empty() {
        return Err(JournalError::InvalidState {
            operation: "record plan",
            path: path.to_path_buf(),
            detail: "a plan must carry at least one operation",
        });
    }
    let encoded_operations = plan
        .operations()
        .iter()
        .enumerate()
        .map(|(ordinal, operation)| {
            let ordinal = i64::try_from(ordinal).map_err(|_| JournalError::InvalidState {
                operation: "record plan",
                path: path.to_path_buf(),
                detail: "operation count exceeds SQLite integer range",
            })?;
            encode(operation, "serialize operation", path).map(|json| (ordinal, json))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let canonical_path = CanonicalPath::from_display(path);
    let existing = connection
        .query_row(
            "SELECT id FROM plans \
             WHERE canonical_path = ?1 AND status IN ('pending', 'blocked')",
            [canonical_path.as_bytes()],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|source| sqlite("find live plan", path, source))?;
    if let Some(id) = existing {
        let plan = read_plan(connection, database_path, PlanId(id))?.ok_or_else(|| {
            JournalError::InvalidState {
                operation: "read existing live plan",
                path: path.to_path_buf(),
                detail: "live plan disappeared inside its transaction",
            }
        })?;
        return Ok(PlanWrite::AlreadyLive(plan));
    }

    connection
        .execute(
            "INSERT INTO plans(path, status, canonical_path) VALUES (?1, 'pending', ?2)",
            params![path_bytes(path), canonical_path.as_bytes()],
        )
        .map_err(|source| sqlite("record plan intent", path, source))?;
    let plan_id = PlanId(connection.last_insert_rowid());
    for (ordinal, operation_json) in encoded_operations {
        connection
            .execute(
                "INSERT INTO operations(plan_id, ordinal, operation_json, status) \
                 VALUES (?1, ?2, ?3, 'pending')",
                params![plan_id.0, ordinal, operation_json],
            )
            .map_err(|source| sqlite("record operation intent", path, source))?;
    }
    let plan = read_plan(connection, database_path, plan_id)?.ok_or_else(|| {
        JournalError::InvalidState {
            operation: "read recorded plan",
            path: path.to_path_buf(),
            detail: "new plan disappeared inside its transaction",
        }
    })?;
    Ok(PlanWrite::Recorded(plan))
}

fn complete_operation_in(
    connection: &Connection,
    database_path: &Path,
    operation_id: OperationId,
    resulting_baseline: Option<&Baseline>,
) -> Result<OperationCompletion, JournalError> {
    let row = connection
        .query_row(
            "SELECT operations.plan_id, operations.ordinal, operations.status, plans.status, \
                    plans.path, operations.operation_json, plans.blocked_json, plans.retry_at \
             FROM operations JOIN plans ON plans.id = operations.plan_id \
             WHERE operations.id = ?1",
            [operation_id.0],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Vec<u8>>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<i64>>(7)?,
                ))
            },
        )
        .optional()
        .map_err(|source| sqlite("find operation", database_path, source))?;
    let Some((
        plan_id,
        ordinal,
        operation_status,
        plan_status,
        raw_path,
        operation_json,
        blocked_json,
        retry_at,
    )) = row
    else {
        return Ok(OperationCompletion::NotFound);
    };
    let path = bytes_path(raw_path);
    let operation_status = decode_status(&operation_status, "read operation status", &path)?;
    let plan_status = decode_plan_status(
        &plan_status,
        blocked_json.as_deref(),
        retry_at,
        "read plan status",
        &path,
    )?;
    if operation_status == RecordStatus::Completed || plan_status == PlanStatus::Completed {
        return Ok(OperationCompletion::AlreadyCompleted);
    }
    let operation: Operation = decode(&operation_json, "deserialize operation", &path)?;

    let earlier = connection
        .query_row(
            "SELECT id FROM operations \
             WHERE plan_id = ?1 AND ordinal < ?2 AND status = 'pending' \
             ORDER BY ordinal LIMIT 1",
            params![plan_id, ordinal],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|source| sqlite("find earlier operation", &path, source))?;
    if let Some(id) = earlier {
        return Ok(OperationCompletion::WaitingForEarlierOperation(
            OperationId(id),
        ));
    }

    let has_later = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM operations WHERE plan_id = ?1 AND ordinal > ?2)",
            params![plan_id, ordinal],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|source| sqlite("find later operation", &path, source))?;
    let final_baseline = if has_later {
        if resulting_baseline.is_some() {
            return Ok(OperationCompletion::UnexpectedBaseline);
        }
        None
    } else {
        let Some(baseline) = resulting_baseline else {
            return Ok(OperationCompletion::BaselineRequired);
        };
        if !operation_matches_baseline(&operation, baseline) {
            return Ok(OperationCompletion::BaselineMismatch);
        }
        Some(baseline)
    };

    connection
        .execute(
            "UPDATE operations SET status = 'completed' WHERE id = ?1",
            [operation_id.0],
        )
        .map_err(|source| sqlite("complete operation", &path, source))?;
    connection
        .execute(
            "UPDATE recovery_records SET status = 'completed' \
             WHERE operation_id = ?1 AND status = 'pending'",
            [operation_id.0],
        )
        .map_err(|source| sqlite("retire legacy recovery intent", &path, source))?;
    let Some(baseline) = final_baseline else {
        return Ok(OperationCompletion::OperationCompleted);
    };

    write_baseline(connection, &path, baseline)?;
    connection
        .execute(
            "DELETE FROM conflicts WHERE canonical_path = ?1",
            [CanonicalPath::from_display(&path).as_bytes()],
        )
        .map_err(|source| sqlite("retire resolved conflicts", &path, source))?;
    connection
        .execute(FINISH_PLAN, [plan_id])
        .map_err(|source| sqlite("complete plan", &path, source))?;
    start_recovery_retention(connection, plan_id, &path)?;
    Ok(OperationCompletion::PlanCompleted)
}

fn start_recovery_retention(
    connection: &Connection,
    plan_id: i64,
    path: &Path,
) -> Result<(), JournalError> {
    connection
        .execute(
            "UPDATE recovery_records SET retained_at = unixepoch() \
             WHERE status = 'completed' AND retained_at IS NULL \
               AND operation_id IN ( \
                   SELECT id FROM operations WHERE plan_id = ?1 \
               )",
            [plan_id],
        )
        .map(|_| ())
        .map_err(|source| sqlite("start recovery retention", path, source))
}

fn activate_new_local_root(
    connection: &Connection,
    existing: Option<&LocalRootRecord>,
    binding: &LocalRootBinding,
    database_path: &Path,
) -> Result<LocalRootRecord, JournalError> {
    let generation = match existing {
        Some(record) => {
            record
                .generation
                .checked_add(1)
                .ok_or_else(|| JournalError::InvalidState {
                    operation: "advance local root generation",
                    path: database_path.to_path_buf(),
                    detail: "local root generation exhausted",
                })?
        }
        None => 1,
    };
    connection
        .execute(
            "DELETE FROM recovery_records \
             WHERE status = 'pending' OR operation_id IN ( \
                 SELECT operations.id FROM operations \
                 JOIN plans ON plans.id = operations.plan_id \
                 WHERE plans.status IN ('pending', 'blocked') \
             )",
            [],
        )
        .map_err(|source| sqlite("retire prior root recovery intents", database_path, source))?;
    connection
        .execute(
            "DELETE FROM operations WHERE plan_id IN ( \
                 SELECT id FROM plans WHERE status IN ('pending', 'blocked') \
             )",
            [],
        )
        .map_err(|source| sqlite("retire prior root operations", database_path, source))?;
    connection
        .execute(
            "DELETE FROM plans WHERE status IN ('pending', 'blocked')",
            [],
        )
        .map_err(|source| sqlite("retire prior root plans", database_path, source))?;
    connection
        .execute("DELETE FROM baselines", [])
        .map_err(|source| sqlite("clear prior root baselines", database_path, source))?;
    connection
        .execute("DELETE FROM local_observations", [])
        .map_err(|source| sqlite("clear prior root observations", database_path, source))?;
    connection
        .execute("DELETE FROM local_hash_cache", [])
        .map_err(|source| sqlite("clear prior root hash cache", database_path, source))?;
    connection
        .execute("DELETE FROM conflicts", [])
        .map_err(|source| sqlite("clear prior root conflicts", database_path, source))?;
    connection
        .execute(
            "DELETE FROM legacy_local_root_adoption WHERE singleton = 1",
            [],
        )
        .map_err(|source| sqlite("finish local root adoption", database_path, source))?;
    let record = LocalRootRecord {
        binding: binding.clone(),
        generation,
    };
    write_local_root(connection, &record, database_path)?;
    Ok(record)
}

/// Write the identity of a schema-6 root that `binding` inspected again, keeping
/// its generation and every piece of root-local state; otherwise start a new
/// generation.
fn activate_or_upgrade_local_root(
    connection: &Connection,
    existing: Option<&LocalRootRecord>,
    binding: &LocalRootBinding,
    database_path: &Path,
) -> Result<LocalRootActivation, JournalError> {
    if let Some(record) = existing
        && upgrades_legacy_root(&record.binding, binding)
    {
        let upgraded = LocalRootRecord {
            binding: binding.clone(),
            generation: record.generation,
        };
        write_local_root(connection, &upgraded, database_path)?;
        return Ok(LocalRootActivation::Current(upgraded));
    }
    activate_new_local_root(connection, existing, binding, database_path)
        .map(LocalRootActivation::Activated)
}

/// A binding recorded before schema 7 kept only the path, the inode and a
/// device number, which btrfs reassigns at every mount, so path and inode are
/// all that can tie it to the directory inspected now.
fn upgrades_legacy_root(recorded: &LocalRootBinding, actual: &LocalRootBinding) -> bool {
    recorded.birth.is_none()
        && recorded.canonical_path == actual.canonical_path
        && recorded.inode == actual.inode
}

fn local_root_activation_without_write(
    existing: Option<&LocalRootRecord>,
    binding: &LocalRootBinding,
) -> Option<LocalRootActivation> {
    let record = existing?;
    if record.binding == *binding {
        Some(LocalRootActivation::Current(record.clone()))
    } else if upgrades_legacy_root(&record.binding, binding) {
        None
    } else if record.binding.canonical_path == binding.canonical_path {
        Some(LocalRootActivation::Unavailable {
            recorded: record.binding.clone(),
            actual: binding.clone(),
        })
    } else {
        None
    }
}

fn write_local_root(
    connection: &Connection,
    record: &LocalRootRecord,
    database_path: &Path,
) -> Result<(), JournalError> {
    let generation = i64::try_from(record.generation).map_err(|_| JournalError::InvalidState {
        operation: "write local root binding",
        path: database_path.to_path_buf(),
        detail: "local root generation exceeds SQLite integer range",
    })?;
    let inode = record.binding.inode.to_be_bytes();
    let birth_seconds = record.binding.birth.map(|birth| birth.seconds);
    let birth_nanoseconds = record
        .binding
        .birth
        .map(|birth| i64::from(birth.nanoseconds));
    let subvolume = record.binding.subvolume.map(u64::to_be_bytes);
    connection
        .execute(
            "INSERT INTO local_root_binding( \
                 singleton, canonical_path, inode, birth_seconds, birth_nanoseconds, \
                 subvolume, generation \
             ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6) \
             ON CONFLICT(singleton) DO UPDATE SET \
                 canonical_path = excluded.canonical_path, \
                 inode = excluded.inode, \
                 birth_seconds = excluded.birth_seconds, \
                 birth_nanoseconds = excluded.birth_nanoseconds, \
                 subvolume = excluded.subvolume, \
                 generation = excluded.generation",
            params![
                path_bytes(&record.binding.canonical_path),
                inode.as_slice(),
                birth_seconds,
                birth_nanoseconds,
                subvolume.as_ref().map(<[u8; 8]>::as_slice),
                generation
            ],
        )
        .map(|_| ())
        .map_err(|source| sqlite("write local root binding", database_path, source))
}

fn read_local_root(
    connection: &Connection,
    database_path: &Path,
    schema_version: i64,
) -> Result<Option<LocalRootRecord>, JournalError> {
    // A read-only journal below version seven still holds the device column and
    // no birth time, so its binding reads exactly as the migration copies it.
    let query = if schema_version < 7 {
        "SELECT canonical_path, inode, NULL, NULL, NULL, generation \
         FROM local_root_binding WHERE singleton = 1"
    } else {
        "SELECT canonical_path, inode, birth_seconds, birth_nanoseconds, subvolume, generation \
         FROM local_root_binding WHERE singleton = 1"
    };
    connection
        .query_row(query, [], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, Vec<u8>>(1)?,
                row.get::<_, Option<i64>>(2)?,
                row.get::<_, Option<i64>>(3)?,
                row.get::<_, Option<Vec<u8>>>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })
        .optional()
        .map_err(|source| sqlite("read local root binding", database_path, source))?
        .map(
            |(raw_path, raw_inode, birth_seconds, birth_nanoseconds, raw_subvolume, generation)| {
                let canonical_path = bytes_path(raw_path);
                let birth = match (birth_seconds, birth_nanoseconds) {
                    (Some(seconds), Some(nanoseconds)) => Some(BirthTime {
                        seconds,
                        nanoseconds: u32::try_from(nanoseconds)
                            .ok()
                            .filter(|nanoseconds| *nanoseconds < 1_000_000_000)
                            .ok_or_else(|| JournalError::InvalidState {
                                operation: "read local root birth time",
                                path: canonical_path.clone(),
                                detail: "local root birth nanoseconds are out of range",
                            })?,
                    }),
                    (None, None) => None,
                    _ => {
                        return Err(JournalError::InvalidState {
                            operation: "read local root birth time",
                            path: canonical_path,
                            detail: "local root birth time is only partly recorded",
                        });
                    }
                };
                let subvolume = raw_subvolume
                    .map(|raw| decode_u64(&raw, "read local root subvolume", &canonical_path))
                    .transpose()?;
                Ok(LocalRootRecord {
                    binding: LocalRootBinding {
                        inode: decode_u64(&raw_inode, "read local root inode", &canonical_path)?,
                        birth,
                        subvolume,
                        canonical_path,
                    },
                    generation: u64::try_from(generation).map_err(|_| {
                        JournalError::InvalidState {
                            operation: "read local root generation",
                            path: database_path.to_path_buf(),
                            detail: "local root generation is outside the supported range",
                        }
                    })?,
                })
            },
        )
        .transpose()
}

fn read_local_inventory(
    connection: &Connection,
    database_path: &Path,
) -> Result<Vec<LocalObservationRecord>, JournalError> {
    let mut statement = connection
        .prepare("SELECT path, observation_json FROM local_observations ORDER BY path")
        .map_err(|source| sqlite("prepare local inventory query", database_path, source))?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|source| sqlite("query local inventory", database_path, source))?;
    rows.map(|row| {
        let (raw_path, json) =
            row.map_err(|source| sqlite("read local inventory", database_path, source))?;
        let path = bytes_path(raw_path);
        let observation = decode(&json, "deserialize local observation", &path)?;
        Ok(LocalObservationRecord { path, observation })
    })
    .collect()
}

fn read_local_hash_cache(
    connection: &Connection,
    database_path: &Path,
) -> Result<Vec<LocalHashRecord>, JournalError> {
    let mut statement = connection
        .prepare(
            "SELECT cache.path, cache.hash_json \
             FROM local_hash_cache AS cache \
             JOIN local_root_binding AS root \
               ON root.singleton = 1 AND cache.root_generation = root.generation \
             ORDER BY cache.path",
        )
        .map_err(|source| sqlite("prepare local hash cache query", database_path, source))?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|source| sqlite("query local hash cache", database_path, source))?;
    rows.map(|row| {
        let (raw_path, json) =
            row.map_err(|source| sqlite("read local hash cache", database_path, source))?;
        let path = bytes_path(raw_path);
        let value: LocalHashValue = decode(&json, "deserialize local hash cache", &path)?;
        if !is_dropbox_content_hash(value.content.as_str()) {
            return Err(JournalError::InvalidState {
                operation: "read local hash cache",
                path,
                detail: "cached content identity is not a Dropbox content hash",
            });
        }
        Ok(LocalHashRecord {
            path,
            fingerprint: value.fingerprint,
            content: value.content,
        })
    })
    .collect::<Result<Vec<_>, _>>()
    .inspect(|records| {
        debug_assert!(
            records.is_sorted_by(|left, right| {
                left.path.as_os_str().as_bytes() < right.path.as_os_str().as_bytes()
            }),
            "local hash cache is not in byte order"
        );
    })
}

fn read_remote_observations(
    connection: &Connection,
    database_path: &Path,
    schema_version: i64,
) -> Result<Vec<RemoteObservationRecord>, JournalError> {
    let query = if schema_version < 4 {
        "SELECT path, path, observation_json FROM remote_observations ORDER BY path"
    } else {
        "SELECT canonical_path, path, observation_json \
         FROM remote_observations ORDER BY canonical_path"
    };
    let mut statement = connection
        .prepare(query)
        .map_err(|source| sqlite("prepare remote inventory query", database_path, source))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, Vec<u8>>(1)?,
                row.get::<_, String>(2)?,
            ))
        })
        .map_err(|source| sqlite("query remote inventory", database_path, source))?;
    rows.map(|row| {
        let (raw_canonical_path, raw_path, json) =
            row.map_err(|source| sqlite("read remote inventory", database_path, source))?;
        let canonical_path = CanonicalPath::from_bytes(raw_canonical_path);
        let path = bytes_path(raw_path);
        let observation = decode(&json, "deserialize remote observation", &path)?;
        Ok(RemoteObservationRecord {
            canonical_path,
            path,
            observation,
        })
    })
    .collect::<Result<Vec<_>, _>>()
    .inspect(|records| {
        debug_assert!(
            records.is_sorted_by(|left, right| left.canonical_path < right.canonical_path),
            "remote inventory is not in canonical path order"
        );
    })
}

/// One joined plan and operation row.
struct PlanRow {
    plan_id: i64,
    path: Vec<u8>,
    status: String,
    blocked_json: Option<String>,
    retry_at: Option<i64>,
    operation_id: i64,
    ordinal: i64,
    operation_json: String,
    operation_status: String,
}

fn read_plans_with_status(
    connection: &Connection,
    database_path: &Path,
    query: &'static str,
    status: &'static str,
    operation: &'static str,
) -> Result<Vec<PlanRecord>, JournalError> {
    let mut statement = connection
        .prepare(query)
        .map_err(|source| sqlite("prepare plan query", database_path, source))?;
    let rows = statement
        .query_map([status], |row| {
            Ok(PlanRow {
                plan_id: row.get(0)?,
                path: row.get(1)?,
                status: row.get(2)?,
                blocked_json: row.get(3)?,
                retry_at: row.get(4)?,
                operation_id: row.get(5)?,
                ordinal: row.get(6)?,
                operation_json: row.get(7)?,
                operation_status: row.get(8)?,
            })
        })
        .map_err(|source| sqlite(operation, database_path, source))?;
    let mut plans: Vec<PlanRecord> = Vec::new();
    for row in rows {
        let row = row.map_err(|source| sqlite(operation, database_path, source))?;
        let path = bytes_path(row.path);
        let planned = PlannedOperation {
            id: OperationId(row.operation_id),
            ordinal: u32::try_from(row.ordinal).map_err(|_| JournalError::InvalidState {
                operation,
                path: path.clone(),
                detail: "operation ordinal exceeds the supported range",
            })?,
            operation: decode(&row.operation_json, "deserialize operation", &path)?,
            status: decode_status(&row.operation_status, "read operation status", &path)?,
        };
        match plans.last_mut() {
            Some(last) if last.id == PlanId(row.plan_id) => last.operations.push(planned),
            _ => plans.push(PlanRecord {
                id: PlanId(row.plan_id),
                status: decode_plan_status(
                    &row.status,
                    row.blocked_json.as_deref(),
                    row.retry_at,
                    operation,
                    &path,
                )?,
                path,
                operations: vec![planned],
            }),
        }
    }
    Ok(plans)
}

fn read_plan_state(
    connection: &Connection,
    database_path: &Path,
    plan_id: PlanId,
    operation: &'static str,
) -> Result<Option<(PathBuf, PlanStatus)>, JournalError> {
    let header = connection
        .query_row(
            "SELECT path, status, blocked_json, retry_at FROM plans WHERE id = ?1",
            [plan_id.0],
            |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            },
        )
        .optional()
        .map_err(|source| sqlite(operation, database_path, source))?;
    let Some((raw_path, status, blocked_json, retry_at)) = header else {
        return Ok(None);
    };
    let path = bytes_path(raw_path);
    let status = decode_plan_status(&status, blocked_json.as_deref(), retry_at, operation, &path)?;
    Ok(Some((path, status)))
}

fn read_plan(
    connection: &Connection,
    database_path: &Path,
    plan_id: PlanId,
) -> Result<Option<PlanRecord>, JournalError> {
    let Some((path, status)) = read_plan_state(connection, database_path, plan_id, "read plan")?
    else {
        return Ok(None);
    };

    let mut statement = connection
        .prepare(
            "SELECT id, ordinal, operation_json, status \
             FROM operations WHERE plan_id = ?1 ORDER BY ordinal",
        )
        .map_err(|source| sqlite("prepare plan operation query", &path, source))?;
    let rows = statement
        .query_map([plan_id.0], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })
        .map_err(|source| sqlite("query plan operations", &path, source))?;
    let raw_operations = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| sqlite("read plan operations", &path, source))?;
    let operations = raw_operations
        .into_iter()
        .map(|(id, ordinal, json, status)| {
            let ordinal = u32::try_from(ordinal).map_err(|_| JournalError::InvalidState {
                operation: "read operation ordinal",
                path: path.clone(),
                detail: "operation ordinal exceeds the supported range",
            })?;
            Ok(PlannedOperation {
                id: OperationId(id),
                ordinal,
                operation: decode(&json, "deserialize operation", &path)?,
                status: decode_status(&status, "read operation status", &path)?,
            })
        })
        .collect::<Result<Vec<_>, JournalError>>()?;

    Ok(Some(PlanRecord {
        id: plan_id,
        path,
        operations,
        status,
    }))
}

#[cfg(test)]
fn read_recovery_for_operation(
    connection: &Connection,
    database_path: &Path,
    operation_id: OperationId,
) -> Result<Option<RecoveryRecord>, JournalError> {
    let id = connection
        .query_row(
            "SELECT id FROM recovery_records WHERE operation_id = ?1",
            [operation_id.0],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|source| sqlite("find operation recovery", database_path, source))?;
    id.map(|id| read_recovery(connection, database_path, RecoveryId(id), true))
        .transpose()
        .map(Option::flatten)
}

fn read_recoveries_with_status(
    connection: &Connection,
    database_path: &Path,
    status: &'static str,
    operation: &'static str,
    has_retained_at: bool,
) -> Result<Vec<RecoveryRecord>, JournalError> {
    let mut statement = connection
        .prepare("SELECT id FROM recovery_records WHERE status = ?1 ORDER BY id")
        .map_err(|source| sqlite("prepare recovery query", database_path, source))?;
    let rows = statement
        .query_map([status], |row| row.get::<_, i64>(0))
        .map_err(|source| sqlite("query recoveries", database_path, source))?;
    let ids = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| sqlite("read recovery identities", database_path, source))?;
    drop(statement);

    ids.into_iter()
        .map(|id| {
            read_recovery(connection, database_path, RecoveryId(id), has_retained_at)?.ok_or_else(
                || JournalError::InvalidState {
                    operation,
                    path: database_path.to_path_buf(),
                    detail: "selected recovery disappeared while reading the journal",
                },
            )
        })
        .collect()
}

fn read_recovery(
    connection: &Connection,
    database_path: &Path,
    recovery_id: RecoveryId,
    has_retained_at: bool,
) -> Result<Option<RecoveryRecord>, JournalError> {
    let query = if has_retained_at {
        "SELECT operation_id, original_path, recovery_path, content_json, status, retained_at \
         FROM recovery_records WHERE id = ?1"
    } else {
        "SELECT operation_id, original_path, recovery_path, content_json, status, NULL \
         FROM recovery_records WHERE id = ?1"
    };
    let row = connection
        .query_row(query, [recovery_id.0], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, Vec<u8>>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<i64>>(5)?,
            ))
        })
        .optional()
        .map_err(|source| sqlite("read recovery", database_path, source))?;
    let Some((operation_id, raw_original, raw_recovery, content_json, status, retained_at)) = row
    else {
        return Ok(None);
    };
    let original_path = bytes_path(raw_original);
    let retained_at = retained_at
        .map(|value| {
            u64::try_from(value).map_err(|_| JournalError::InvalidState {
                operation: "read recovery retention start",
                path: original_path.clone(),
                detail: "recovery retention start is outside the supported range",
            })
        })
        .transpose()?;
    Ok(Some(RecoveryRecord {
        id: recovery_id,
        operation_id: OperationId(operation_id),
        recovery_path: bytes_path(raw_recovery),
        content: decode(
            &content_json,
            "deserialize recovery content",
            &original_path,
        )?,
        status: decode_status(&status, "read recovery status", &original_path)?,
        retained_at,
        original_path,
    }))
}

#[cfg(test)]
fn is_destructive(operation: &Operation) -> bool {
    matches!(
        operation,
        Operation::ReplaceLocal { .. }
            | Operation::DeleteLocal { .. }
            | Operation::ReplaceRemote { .. }
            | Operation::DeleteRemote { .. }
    )
}

#[cfg(test)]
fn missing_preservation(path: &Path) -> JournalError {
    JournalError::InvalidState {
        operation: "derive recovery content",
        path: path.to_path_buf(),
        detail: "destructive operation lacks immediately preceding matching preservation",
    }
}

#[cfg(test)]
fn displaced_content(preservation: &Operation, destructive: &Operation) -> Option<ContentIdentity> {
    match (preservation, destructive) {
        (
            Operation::PreserveLocal { file },
            Operation::ReplaceLocal {
                expected_content, ..
            }
            | Operation::DeleteLocal { expected_content },
        ) if file.content == *expected_content => Some(file.content.clone()),
        (
            Operation::PreserveRemote { file },
            Operation::ReplaceRemote {
                expected_revision, ..
            }
            | Operation::DeleteRemote { expected_revision },
        ) if file.revision == *expected_revision => Some(file.content.clone()),
        _ => None,
    }
}

fn operation_matches_baseline(operation: &Operation, baseline: &Baseline) -> bool {
    match (operation, baseline) {
        (
            Operation::CreateLocalDirectory | Operation::CreateRemoteDirectory,
            Baseline::Directory,
        ) => true,
        (Operation::DeleteLocalDirectory | Operation::DeleteRemoteDirectory, Baseline::Absent) => {
            true
        }
        (Operation::CreateRemote { content }, Baseline::Present(remote))
        | (Operation::ReplaceRemote { content, .. }, Baseline::Present(remote)) => {
            content == &remote.content
        }
        (Operation::InstallLocal { source }, Baseline::Present(remote))
        | (Operation::ReplaceLocal { source, .. }, Baseline::Present(remote)) => source == remote,
        (Operation::DeleteLocal { .. } | Operation::DeleteRemote { .. }, Baseline::Absent) => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;

    use tempfile::TempDir;

    use super::*;
    use crate::model::{
        Decision, DropboxRevision, LocalFile, Observation, RemoteFile, RemoteSubtree,
    };
    use crate::planner::plan;

    fn content(value: &str) -> ContentIdentity {
        ContentIdentity::new(value)
    }

    fn remote_file(value: &str, revision: &str) -> RemoteFile {
        RemoteFile::new(content(value), DropboxRevision::new(revision))
    }

    fn journal_path(directory: &TempDir) -> PathBuf {
        directory.path().join("journal.sqlite3")
    }

    fn canonical(path: &str) -> CanonicalPath {
        CanonicalPath::from_display(Path::new(path))
    }

    fn file_mode(path: &Path) -> Result<u32, std::io::Error> {
        Ok(fs::metadata(path)?.permissions().mode() & 0o777)
    }

    fn dropbox_binding(
        account_id: &str,
        root_namespace_id: &str,
        remote_root: &str,
    ) -> DropboxBinding {
        DropboxBinding {
            account_id: String::from(account_id),
            root_namespace_id: String::from(root_namespace_id),
            remote_root: String::from(remote_root),
        }
    }

    fn local_root(path: impl Into<PathBuf>, inode: u64) -> LocalRootBinding {
        LocalRootBinding {
            canonical_path: path.into(),
            inode,
            birth: Some(BirthTime {
                seconds: 1_700_000_000,
                nanoseconds: 5,
            }),
            subvolume: Some(256),
        }
    }

    fn local_hash(path: impl Into<PathBuf>, marker: u64) -> LocalHashRecord {
        LocalHashRecord {
            path: path.into(),
            fingerprint: LocalFileFingerprint {
                inode: marker + 1,
                size: marker + 2,
                modified_seconds: 1,
                modified_nanoseconds: marker % 1_000_000_000,
                changed_seconds: 2,
                changed_nanoseconds: marker % 1_000_000_000,
            },
            content: ContentIdentity::new("a".repeat(64)),
        }
    }

    fn recorded_plan(write: PlanWrite) -> Result<PlanRecord, JournalError> {
        match write {
            PlanWrite::Recorded(plan) => Ok(plan),
            PlanWrite::AlreadyLive(_) => Err(JournalError::InvalidState {
                operation: "extract recorded test plan",
                path: PathBuf::from("test"),
                detail: "test expected a newly recorded plan",
            }),
        }
    }

    fn recorded_recovery(write: RecoveryWrite) -> Result<RecoveryRecord, JournalError> {
        match write {
            RecoveryWrite::Recorded(record) => Ok(record),
            RecoveryWrite::AlreadyRecorded(_)
            | RecoveryWrite::OperationNotFound
            | RecoveryWrite::OperationCompleted
            | RecoveryWrite::OperationNotDestructive => Err(JournalError::InvalidState {
                operation: "extract recorded test recovery",
                path: PathBuf::from("test"),
                detail: "test expected a newly recorded recovery",
            }),
        }
    }

    /// Build an empty version-five database the way the migrations reach it.
    fn version_five(database_path: &Path) -> Result<Connection, Box<dyn Error>> {
        let connection = Connection::open(database_path)?;
        connection.execute_batch(MIGRATION_V1)?;
        connection.execute_batch(MIGRATION_V2)?;
        connection.execute_batch(MIGRATION_V3)?;
        connection.execute_batch(MIGRATION_V4)?;
        migrate_canonical_paths(&connection, database_path)?;
        connection.execute_batch(MIGRATION_V5)?;
        Ok(connection)
    }

    /// Build a version-six database holding a root binding, with the device
    /// number that version kept, and one baseline.
    fn version_six_with_root(
        database_path: &Path,
        root: &str,
        inode: u64,
        baseline_path: &Path,
        baseline: &Baseline,
    ) -> Result<(), Box<dyn Error>> {
        let connection = version_five(database_path)?;
        migrate_blocked_plans(&connection, database_path)?;
        connection.execute(
            "INSERT INTO local_root_binding(singleton, canonical_path, device, inode, generation) \
             VALUES (1, ?1, ?2, ?3, 3)",
            params![
                path_bytes(Path::new(root)),
                44_u64.to_be_bytes().as_slice(),
                inode.to_be_bytes().as_slice()
            ],
        )?;
        connection.execute(
            "INSERT INTO baselines(path, baseline_json, canonical_path) VALUES (?1, ?2, ?3)",
            params![
                path_bytes(baseline_path),
                encode(baseline, "test", baseline_path)?,
                CanonicalPath::from_display(baseline_path).as_bytes()
            ],
        )?;
        let version =
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        if version != 6 {
            return Err(format!("test journal reached version {version}, not 6").into());
        }
        Ok(())
    }

    fn operations(decision: Decision) -> Result<OperationPlan, JournalError> {
        match decision {
            Decision::Operations(plan) => Ok(plan),
            Decision::NoOp(_)
            | Decision::Blocked(_)
            | Decision::Conflict(_)
            | Decision::DirectoryCollision(_) => Err(JournalError::InvalidState {
                operation: "extract test operation plan",
                path: PathBuf::from("test"),
                detail: "test expected planner operations",
            }),
        }
    }

    fn noop(decision: Decision) -> Result<NoOpDecision, JournalError> {
        match decision {
            Decision::NoOp(noop) => Ok(noop),
            Decision::Operations(_)
            | Decision::Blocked(_)
            | Decision::Conflict(_)
            | Decision::DirectoryCollision(_) => Err(JournalError::InvalidState {
                operation: "extract test no-op",
                path: PathBuf::from("test"),
                detail: "test expected a planner no-op",
            }),
        }
    }

    #[test]
    fn journal_reopen_exposes_intent_without_advancing_baseline() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let path = Path::new("notes/report.txt");
        let operation = Operation::CreateRemote {
            content: content("new"),
        };
        let operation_plan = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("new"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;

        let plan = {
            let mut journal = Journal::open(journal_path(&directory))?;
            recorded_plan(journal.record_plan(path, &operation_plan)?)?
        };

        let reopened = Journal::open(journal_path(&directory))?;
        assert_eq!(reopened.baseline(path)?, None);
        assert_eq!(plan.operations[0].operation, operation);
        assert_eq!(reopened.pending_plans()?, vec![plan]);
        Ok(())
    }

    #[test]
    fn reconciliation_decisions_commit_atomically() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        journal.connection.execute_batch(
            "CREATE TRIGGER reject_test_plan BEFORE INSERT ON plans \
             WHEN hex(NEW.path) = hex('reject.txt') \
             BEGIN SELECT RAISE(ABORT, 'test rejection'); END;",
        )?;
        let matching = remote_file("same", "rev-same");
        let agreed = noop(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("same"))),
            &Observation::Present(matching),
            RemoteSubtree::Empty,
        ))?;
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("upload"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let noops = vec![(PathBuf::from("same.txt"), agreed)];
        let plans = vec![
            (PathBuf::from("safe.txt"), upload.clone()),
            (PathBuf::from("reject.txt"), upload),
        ];

        assert!(matches!(
            journal.record_reconciliation(&noops, &plans),
            Err(JournalError::Sqlite { .. })
        ));
        assert_eq!(journal.baseline(Path::new("same.txt"))?, None);
        assert!(journal.pending_plans()?.is_empty());
        Ok(())
    }

    #[test]
    fn final_effect_completions_commit_atomically() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let downloaded = remote_file("downloaded", "rev-downloaded");
        let operation_plan = operations(plan(
            &Baseline::Absent,
            &Observation::ConfirmedAbsent,
            &Observation::Present(downloaded.clone()),
            RemoteSubtree::Empty,
        ))?;
        let first_path = Path::new("first.txt");
        let second_path = Path::new("second.txt");
        let first = recorded_plan(journal.record_plan(first_path, &operation_plan)?)?;
        let second = recorded_plan(journal.record_plan(second_path, &operation_plan)?)?;
        journal.connection.execute_batch(
            "CREATE TRIGGER reject_test_completion BEFORE UPDATE OF status ON plans \
             WHEN hex(OLD.path) = hex('second.txt') AND NEW.status = 'completed' \
             BEGIN SELECT RAISE(ABORT, 'test rejection'); END;",
        )?;
        let completions = vec![
            (
                first.operations[0].id,
                Baseline::Present(downloaded.clone()),
            ),
            (second.operations[0].id, Baseline::Present(downloaded)),
        ];

        assert!(matches!(
            journal.complete_final_operations(&completions),
            Err(JournalError::Sqlite { .. })
        ));
        assert_eq!(journal.baseline(first_path)?, None);
        assert_eq!(journal.baseline(second_path)?, None);
        assert_eq!(journal.pending_plans()?.len(), 2);
        Ok(())
    }

    #[test]
    fn writable_journal_creates_owner_only_database() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);

        let _journal = Journal::open(&database_path)?;

        assert_eq!(file_mode(&database_path)?, 0o600);
        Ok(())
    }

    #[test]
    fn writable_journal_restricts_existing_database() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        drop(Journal::open(&database_path)?);
        fs::set_permissions(&database_path, fs::Permissions::from_mode(0o644))?;

        let _journal = Journal::open(&database_path)?;

        assert_eq!(file_mode(&database_path)?, 0o600);
        Ok(())
    }

    #[test]
    fn read_only_journal_preserves_existing_permissions() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        drop(Journal::open(&database_path)?);
        fs::set_permissions(&database_path, fs::Permissions::from_mode(0o644))?;

        let _journal = Journal::open_read_only(&database_path)?;

        assert_eq!(file_mode(&database_path)?, 0o644);
        Ok(())
    }

    /// rusqlite happens to open connections with the same five-second timeout,
    /// so this pins the value the design requires rather than whatever a
    /// dependency currently defaults to.
    #[test]
    fn every_connection_waits_out_a_concurrent_commit() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let writable = Journal::open(&database_path)?;

        let read_only = Journal::open_read_only(&database_path)?;

        for journal in [&writable, &read_only] {
            assert_eq!(
                journal
                    .connection
                    .query_row("PRAGMA busy_timeout", [], |row| row.get::<_, i64>(0))?,
                i64::try_from(BUSY_TIMEOUT_MILLISECONDS)?
            );
        }
        Ok(())
    }

    #[test]
    fn writable_journal_uses_full_synchronous_rollback_mode() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let journal = Journal::open(journal_path(&directory))?;

        let journal_mode = journal
            .connection
            .query_row("PRAGMA journal_mode", [], |row| row.get::<_, String>(0))?;
        let synchronous = journal
            .connection
            .query_row("PRAGMA synchronous", [], |row| row.get::<_, i64>(0))?;

        let busy_timeout = journal
            .connection
            .query_row("PRAGMA busy_timeout", [], |row| row.get::<_, i64>(0))?;
        let foreign_keys = journal
            .connection
            .query_row("PRAGMA foreign_keys", [], |row| row.get::<_, i64>(0))?;

        assert_eq!(journal_mode, "delete");
        assert_eq!(synchronous, 2);
        assert_eq!(busy_timeout, 5_000);
        assert_eq!(foreign_keys, 1);
        Ok(())
    }

    #[test]
    fn local_root_inspection_uses_directory_filesystem_identity() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let binding = LocalRootBinding::inspect(directory.path())?;
        let statx = rustix::fs::statx(
            rustix::fs::CWD,
            directory.path(),
            rustix::fs::AtFlags::empty(),
            ROOT_IDENTITY_STATX,
        )?;
        let mask = rustix::fs::StatxFlags::from_bits_retain(statx.stx_mask);

        assert_eq!(binding.canonical_path, directory.path());
        assert_eq!(binding.inode, statx.stx_ino);
        assert_eq!(
            binding.birth,
            Some(BirthTime {
                seconds: statx.stx_btime.tv_sec,
                nanoseconds: statx.stx_btime.tv_nsec,
            })
        );
        assert_eq!(
            binding.subvolume,
            mask.contains(STATX_SUBVOL).then_some(statx.stx_subvol)
        );

        let file = directory.path().join("not-a-root");
        fs::write(&file, b"file")?;
        let rejected = LocalRootBinding::inspect(file);
        assert!(matches!(rejected, Err(JournalError::File { .. })));
        Ok(())
    }

    #[test]
    fn root_identity_requires_a_recorded_birth_time() -> Result<(), Box<dyn Error>> {
        let birth = BirthTime {
            seconds: 1_700_000_000,
            nanoseconds: 5,
        };
        let Err(error) = LocalRootBinding::from_statx_fields(
            PathBuf::from("/sync"),
            rustix::fs::StatxFlags::INO | STATX_SUBVOL,
            2,
            birth,
            256,
        ) else {
            return Err("a root without a birth time was accepted".into());
        };
        assert!(
            matches!(&error, JournalError::NoBirthTime { path, .. } if path == Path::new("/sync"))
        );

        let without_subvolume = LocalRootBinding::from_statx_fields(
            PathBuf::from("/sync"),
            rustix::fs::StatxFlags::INO | rustix::fs::StatxFlags::BTIME,
            2,
            birth,
            256,
        )?;
        assert_eq!(without_subvolume.subvolume, None);
        Ok(())
    }

    #[test]
    fn stand_in_needs_the_root_path_and_a_birth_time_or_another_inode() {
        let refusal = |path: &str, inode| JournalError::NoBirthTime {
            path: PathBuf::from(path),
            inode,
        };
        let record = |path: &str, birth| LocalRootRecord {
            binding: LocalRootBinding {
                canonical_path: PathBuf::from(path),
                inode: 2,
                birth,
                subvolume: None,
            },
            generation: 1,
        };
        let birth = Some(BirthTime {
            seconds: 1_700_000_000,
            nanoseconds: 5,
        });

        let born = record("/sync/root", birth);
        assert!(born.stood_in_by(&refusal("/sync/root", 2)));
        assert!(born.stood_in_by(&refusal("/sync/root", 9)));

        let legacy = record("/sync/root", None);
        assert!(legacy.stood_in_by(&refusal("/sync/root", 9)));
        assert!(!legacy.stood_in_by(&refusal("/sync/root", 2)));

        let elsewhere = record("/sync/other", birth);
        assert!(!elsewhere.stood_in_by(&refusal("/sync/root", 9)));

        let file = JournalError::File {
            operation: "open the journal",
            path: PathBuf::from("/sync/root"),
            source: std::io::Error::from(std::io::ErrorKind::NotFound),
        };
        assert!(!born.stood_in_by(&file));
    }

    #[test]
    fn version_six_root_binding_upgrades_in_place_when_path_and_inode_match()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let baseline_path = Path::new("kept.txt");
        let baseline = Baseline::Present(remote_file("kept", "rev-kept"));
        version_six_with_root(&database_path, "/sync/root", 2, baseline_path, &baseline)?;
        let legacy = LocalRootRecord {
            binding: LocalRootBinding {
                canonical_path: PathBuf::from("/sync/root"),
                inode: 2,
                birth: None,
                subvolume: None,
            },
            generation: 3,
        };

        let read_only = Journal::open_read_only(&database_path)?;
        assert_eq!(read_only.local_root_binding()?, Some(legacy.clone()));
        drop(read_only);

        let mut journal = Journal::open(&database_path)?;
        assert_eq!(journal.schema_version, 7);
        assert_eq!(
            journal
                .connection
                .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?,
            7
        );
        assert_eq!(journal.local_root_binding()?, Some(legacy.clone()));
        let observation = LocalObservationRecord {
            path: PathBuf::from("observed.txt"),
            observation: Observation::Present(LocalFile::new(content("observed"))),
        };
        let hash = local_hash("observed.txt", 10);
        assert!(journal.publish_local_scan(
            &legacy.binding,
            std::slice::from_ref(&observation),
            std::slice::from_ref(&hash),
        )?);
        let conflict = Conflict::DivergentEdits {
            local: LocalFile::new(content("local-conflict")),
            remote: remote_file("remote-conflict", "rev-conflict"),
        };
        let conflict = journal.record_conflict(Path::new("conflict.txt"), &conflict)?;

        let inspected = local_root("/sync/root", 2);
        let upgraded = LocalRootRecord {
            binding: inspected.clone(),
            generation: 3,
        };
        let changes_before = journal.connection.total_changes();
        assert_eq!(
            journal.activate_local_root(&inspected)?,
            LocalRootActivation::Current(upgraded.clone())
        );
        assert_eq!(journal.connection.total_changes() - changes_before, 1);
        assert_eq!(journal.baseline(baseline_path)?, Some(baseline));
        assert_eq!(journal.local_inventory()?, vec![observation]);
        assert_eq!(journal.local_hash_cache()?, vec![hash]);
        assert_eq!(journal.conflicts()?, vec![conflict]);
        assert_eq!(journal.local_root_binding()?, Some(upgraded.clone()));
        assert_eq!(
            journal.activate_local_root(&inspected)?,
            LocalRootActivation::Current(upgraded)
        );
        Ok(())
    }

    #[test]
    fn version_six_root_binding_with_another_inode_is_unavailable_without_changes()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let baseline_path = Path::new("kept.txt");
        let baseline = Baseline::Present(remote_file("kept", "rev-kept"));
        version_six_with_root(&database_path, "/sync/root", 2, baseline_path, &baseline)?;
        let mut journal = Journal::open(&database_path)?;

        let root_before = journal.local_root_binding()?;
        let baselines_before = journal.baseline_paths()?;
        let changes_before = journal.connection.total_changes();
        let Some(recorded) = root_before.clone() else {
            return Err("the migrated journal lost its root binding".into());
        };
        let actual = local_root("/sync/root", 9);
        assert_eq!(
            journal.activate_local_root(&actual)?,
            LocalRootActivation::Unavailable {
                recorded: recorded.binding,
                actual,
            }
        );
        assert_eq!(journal.local_root_binding()?, root_before);
        assert_eq!(journal.baseline_paths()?, baselines_before);
        assert_eq!(journal.baseline(baseline_path)?, Some(baseline));
        assert_eq!(journal.connection.total_changes(), changes_before);
        Ok(())
    }

    #[test]
    fn same_path_and_inode_with_another_birth_or_subvolume_is_unavailable_without_changes()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let recorded = local_root("/sync/root", 2);
        let _ = journal.activate_local_root(&recorded)?;

        let another_birth = LocalRootBinding {
            birth: Some(BirthTime {
                seconds: 1_700_000_001,
                nanoseconds: 5,
            }),
            ..recorded.clone()
        };
        let another_subvolume = LocalRootBinding {
            subvolume: Some(257),
            ..recorded.clone()
        };
        let no_subvolume = LocalRootBinding {
            subvolume: None,
            ..recorded.clone()
        };
        for actual in [another_birth, another_subvolume, no_subvolume] {
            let changes_before = journal.connection.total_changes();
            assert_eq!(
                journal.activate_local_root(&actual)?,
                LocalRootActivation::Unavailable {
                    recorded: recorded.clone(),
                    actual,
                }
            );
            assert_eq!(journal.connection.total_changes(), changes_before);
        }
        Ok(())
    }

    #[test]
    fn adopting_a_matching_version_six_root_keeps_its_generation() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let baseline_path = Path::new("kept.txt");
        let baseline = Baseline::Present(remote_file("kept", "rev-kept"));
        version_six_with_root(&database_path, "/sync/root", 2, baseline_path, &baseline)?;
        let mut journal = Journal::open(&database_path)?;

        let inspected = local_root("/sync/root", 2);
        let upgraded = LocalRootRecord {
            binding: inspected.clone(),
            generation: 3,
        };
        assert_eq!(
            journal.adopt_local_root(&inspected)?,
            LocalRootActivation::Current(upgraded.clone())
        );
        assert_eq!(journal.local_root_binding()?, Some(upgraded));
        assert_eq!(journal.baseline(baseline_path)?, Some(baseline));
        Ok(())
    }

    #[test]
    fn replaced_same_path_is_unavailable_without_changing_journal_state()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let root = directory.path().join("root");
        let moved_root = directory.path().join("moved-root");
        fs::create_dir(&root)?;
        let recorded = LocalRootBinding::inspect(&root)?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let _ = journal.activate_local_root(&recorded)?;

        let agreed_path = Path::new("agreed.txt");
        let agreed_file = remote_file("agreed", "rev-agreed");
        let agreement = noop(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(agreed_file.content.clone())),
            &Observation::Present(agreed_file),
            RemoteSubtree::Empty,
        ))?;
        journal.record_noop(agreed_path, &agreement)?;
        journal.publish_local_inventory(&[LocalObservationRecord {
            path: PathBuf::from("local.txt"),
            observation: Observation::Present(LocalFile::new(content("local"))),
        }])?;
        let destructive = OperationPlan::new(vec![
            Operation::PreserveLocal {
                file: LocalFile::new(content("old")),
            },
            Operation::DeleteLocal {
                expected_content: content("old"),
            },
        ]);
        let recovery_payload = directory.path().join("recovery-payload");
        let staged_payload = directory.path().join("staged-payload");
        fs::write(&recovery_payload, b"recovery")?;
        fs::write(&staged_payload, b"staged")?;
        let pending = recorded_plan(journal.record_plan(Path::new("pending.txt"), &destructive)?)?;
        let _ = recorded_recovery(
            journal.record_recovery_intent(pending.operations[1].id, &recovery_payload)?,
        )?;
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("blocked"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let blocked = recorded_plan(journal.record_plan(Path::new("blocked.txt"), &upload)?)?;
        assert_eq!(
            journal.block_plan(blocked.id, &BlockReason::StageOccupied, 1_700_000_000)?,
            PlanBlock::Blocked
        );
        let conflict = Conflict::DivergentEdits {
            local: LocalFile::new(content("local-conflict")),
            remote: remote_file("remote-conflict", "rev-conflict"),
        };
        let _ = journal.record_conflict(Path::new("conflict.txt"), &conflict)?;

        let root_before = journal.local_root_binding()?;
        let baselines_before = journal.baseline_paths()?;
        let local_before = journal.local_inventory()?;
        let pending_before = journal.pending_plans()?;
        let blocked_before = journal.blocked_plans()?;
        let recoveries_before = journal.pending_recoveries()?;
        let conflicts_before = journal.conflicts()?;
        let changes_before = journal.connection.total_changes();

        fs::rename(&root, &moved_root)?;
        fs::create_dir(&root)?;
        let actual = LocalRootBinding::inspect(&root)?;
        assert_ne!(recorded, actual);
        assert_eq!(recorded.canonical_path, actual.canonical_path);
        assert_eq!(
            journal.activate_local_root(&actual)?,
            LocalRootActivation::Unavailable {
                recorded: recorded.clone(),
                actual: actual.clone(),
            }
        );
        assert_eq!(journal.local_root_binding()?, root_before);
        assert_eq!(journal.baseline_paths()?, baselines_before);
        assert_eq!(journal.local_inventory()?, local_before);
        assert_eq!(journal.pending_plans()?, pending_before);
        assert_eq!(journal.blocked_plans()?, blocked_before);
        assert_eq!(journal.pending_recoveries()?, recoveries_before);
        assert_eq!(journal.conflicts()?, conflicts_before);
        assert_eq!(journal.connection.total_changes(), changes_before);

        assert_eq!(
            journal.adopt_local_root(&actual)?,
            LocalRootActivation::Activated(LocalRootRecord {
                binding: actual,
                generation: 2,
            })
        );
        assert!(journal.baseline_paths()?.is_empty());
        assert!(journal.local_inventory()?.is_empty());
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.blocked_plans()?.is_empty());
        assert!(journal.pending_recoveries()?.is_empty());
        assert!(journal.conflicts()?.is_empty());
        assert_eq!(fs::read(recovery_payload)?, b"recovery");
        assert_eq!(fs::read(staged_payload)?, b"staged");
        Ok(())
    }

    #[test]
    fn local_root_generation_resets_only_root_local_state() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let first = local_root("/sync/first", 2);
        let first_record = LocalRootRecord {
            binding: first.clone(),
            generation: 1,
        };
        assert_eq!(
            journal.activate_local_root(&first)?,
            LocalRootActivation::Activated(first_record.clone())
        );

        let path = Path::new("tracked.txt");
        let agreed = remote_file("same", "rev-1");
        let baseline = noop(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("same"))),
            &Observation::Present(agreed.clone()),
            RemoteSubtree::Empty,
        ))?;
        journal.record_noop(path, &baseline)?;
        let local_observation = LocalObservationRecord {
            path: path.to_path_buf(),
            observation: Observation::Present(LocalFile::new(content("same"))),
        };
        journal.publish_local_inventory(std::slice::from_ref(&local_observation))?;
        let remote_observation = RemoteObservationRecord {
            canonical_path: CanonicalPath::from_display(path),
            path: path.to_path_buf(),
            observation: Observation::Present(agreed.clone()),
        };
        journal
            .publish_remote_inventory("cursor-kept", std::slice::from_ref(&remote_observation))?;
        let conflict = Conflict::DivergentEdits {
            local: LocalFile::new(content("local")),
            remote: remote_file("remote", "rev-conflict"),
        };
        let _ = journal.record_conflict(Path::new("old-root-conflict.txt"), &conflict)?;

        assert_eq!(
            journal.activate_local_root(&first)?,
            LocalRootActivation::Current(first_record)
        );
        assert_eq!(journal.baseline(path)?, Some(Baseline::Present(agreed)));

        let replacement = local_root("/sync/second", 4);
        let replacement_record = LocalRootRecord {
            binding: replacement.clone(),
            generation: 2,
        };
        assert_eq!(
            journal.activate_local_root(&replacement)?,
            LocalRootActivation::Activated(replacement_record.clone())
        );
        assert_eq!(journal.local_root_binding()?, Some(replacement_record));
        assert_eq!(journal.baseline(path)?, None);
        assert!(journal.baseline_paths()?.is_empty());
        assert!(journal.local_inventory()?.is_empty());
        assert!(journal.conflicts()?.is_empty());
        assert_eq!(
            journal.remote_inventory()?,
            RemoteInventory {
                cursor: Some(String::from("cursor-kept")),
                observations: vec![remote_observation],
            }
        );
        Ok(())
    }

    #[test]
    fn local_root_activation_retires_work_from_a_prior_or_unbound_root()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let current = local_root("/sync/current", 2);
        assert!(matches!(
            journal.activate_local_root(&current)?,
            LocalRootActivation::Activated(_)
        ));
        let operation_plan = OperationPlan::new(vec![
            Operation::PreserveLocal {
                file: LocalFile::new(content("pending")),
            },
            Operation::DeleteLocal {
                expected_content: content("pending"),
            },
        ]);
        let pending =
            recorded_plan(journal.record_plan(Path::new("pending.txt"), &operation_plan)?)?;
        let recovery_payload = directory.path().join("retained-recovery");
        let staged_payload = directory.path().join("retained-stage");
        fs::write(&recovery_payload, b"recovery")?;
        fs::write(&staged_payload, b"stage")?;
        let _ = recorded_recovery(
            journal.record_recovery_intent(pending.operations[1].id, &recovery_payload)?,
        )?;
        let blocked_plan = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("blocked"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let blocked = recorded_plan(journal.record_plan(Path::new("blocked.txt"), &blocked_plan)?)?;
        assert_eq!(
            journal.block_plan(blocked.id, &BlockReason::StageOccupied, 1_700_000_000)?,
            PlanBlock::Blocked
        );

        let replacement = local_root("/sync/replacement", 4);
        assert_eq!(
            journal.activate_local_root(&replacement)?,
            LocalRootActivation::Activated(LocalRootRecord {
                binding: replacement.clone(),
                generation: 2,
            })
        );
        assert_eq!(
            journal.local_root_binding()?,
            Some(LocalRootRecord {
                binding: replacement.clone(),
                generation: 2,
            })
        );
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.blocked_plans()?.is_empty());
        assert!(journal.pending_recoveries()?.is_empty());
        assert_eq!(fs::read(&recovery_payload)?, b"recovery");
        assert_eq!(fs::read(&staged_payload)?, b"stage");

        let unbound_path = directory.path().join("unbound.sqlite3");
        let mut unbound = Journal::open(unbound_path)?;
        let _ = unbound.record_plan(Path::new("pending.txt"), &operation_plan)?;
        assert_eq!(
            unbound.activate_local_root(&replacement)?,
            LocalRootActivation::Activated(LocalRootRecord {
                binding: replacement.clone(),
                generation: 1,
            })
        );
        assert!(unbound.pending_plans()?.is_empty());
        Ok(())
    }

    #[test]
    fn new_empty_root_downloads_remote_content_instead_of_deleting_it() -> Result<(), Box<dyn Error>>
    {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let _ = journal.activate_local_root(&local_root("/sync/old", 2))?;
        let path = Path::new("remote-only.txt");
        let remote = remote_file("remote", "rev-remote");
        let agreed = noop(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("remote"))),
            &Observation::Present(remote.clone()),
            RemoteSubtree::Empty,
        ))?;
        journal.record_noop(path, &agreed)?;

        let _ = journal.activate_local_root(&local_root("/sync/new-empty", 4))?;
        let baseline = match journal.baseline(path)? {
            Some(baseline) => baseline,
            None => Baseline::Absent,
        };
        let decision = operations(plan(
            &baseline,
            &Observation::ConfirmedAbsent,
            &Observation::Present(remote.clone()),
            RemoteSubtree::Empty,
        ))?;

        assert_eq!(
            decision.operations(),
            &[Operation::InstallLocal { source: remote }]
        );
        Ok(())
    }

    #[test]
    fn journal_dropbox_binding_survives_reopen() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let binding = dropbox_binding("dbid:account", "namespace-1", "/omabox");
        {
            let mut journal = Journal::open(&database_path)?;
            assert_eq!(
                journal.bind_dropbox_root(&binding)?,
                DropboxBindingWrite::Bound
            );
        }

        let mut reopened = Journal::open(&database_path)?;
        assert_eq!(reopened.dropbox_binding()?, Some(binding.clone()));
        assert_eq!(
            reopened.bind_dropbox_root(&binding)?,
            DropboxBindingWrite::AlreadyBound
        );
        Ok(())
    }

    #[test]
    fn journal_dropbox_binding_mismatch_never_replaces_existing() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let existing = dropbox_binding("dbid:account", "namespace-1", "/omabox");
        let mismatches = [
            dropbox_binding("dbid:other", "namespace-1", "/omabox"),
            dropbox_binding("dbid:account", "namespace-2", "/omabox"),
            dropbox_binding("dbid:account", "namespace-1", "/other"),
        ];
        {
            let mut journal = Journal::open(&database_path)?;
            assert_eq!(
                journal.bind_dropbox_root(&existing)?,
                DropboxBindingWrite::Bound
            );
            for mismatch in mismatches {
                assert_eq!(
                    journal.bind_dropbox_root(&mismatch)?,
                    DropboxBindingWrite::Mismatch {
                        existing: existing.clone()
                    }
                );
            }
        }

        let mut reopened = Journal::open(database_path)?;
        assert_eq!(
            reopened.bind_dropbox_root(&existing)?,
            DropboxBindingWrite::AlreadyBound
        );
        Ok(())
    }

    #[test]
    fn journal_noop_refreshes_revision_but_cannot_cross_a_pending_plan()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let path = Path::new("matching.txt");
        let observed = remote_file("same", "rev-current");
        let noop_decision = noop(plan(
            &Baseline::Present(remote_file("same", "rev-old")),
            &Observation::Present(LocalFile::new(content("same"))),
            &Observation::Present(observed.clone()),
            RemoteSubtree::Empty,
        ))?;
        assert_eq!(
            journal.record_noop(path, &noop_decision)?,
            NoOpWrite::Recorded
        );
        assert_eq!(journal.baseline(path)?, Some(Baseline::Present(observed)));
        let unchanged_at = journal.connection.total_changes();
        assert_eq!(
            journal.record_noop(path, &noop_decision)?,
            NoOpWrite::Recorded
        );
        assert_eq!(journal.connection.total_changes(), unchanged_at);

        let pending = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("new"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let pending = recorded_plan(journal.record_plan(path, &pending)?)?;
        let absent = noop(plan(
            &Baseline::Absent,
            &Observation::ConfirmedAbsent,
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        assert_eq!(
            journal.record_noop(path, &absent)?,
            NoOpWrite::LivePlan(pending.id)
        );
        assert_eq!(
            journal.baseline(path)?,
            Some(Baseline::Present(remote_file("same", "rev-current")))
        );
        Ok(())
    }

    #[test]
    fn absent_baseline_removes_its_row() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let path = Path::new("removed.txt");
        let present = noop(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("old"))),
            &Observation::Present(remote_file("old", "rev-old")),
            RemoteSubtree::Empty,
        ))?;
        journal.record_noop(path, &present)?;
        assert_eq!(journal.baseline_paths()?, vec![path.to_path_buf()]);

        let absent = noop(plan(
            &Baseline::Present(remote_file("old", "rev-old")),
            &Observation::ConfirmedAbsent,
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        journal.record_noop(path, &absent)?;

        assert_eq!(journal.baseline(path)?, None);
        assert!(journal.baseline_paths()?.is_empty());
        let stored = journal.connection.query_row(
            "SELECT COUNT(*) FROM baselines WHERE path = ?1",
            [path_bytes(path)],
            |row| row.get::<_, i64>(0),
        )?;
        assert_eq!(stored, 0);
        Ok(())
    }

    #[test]
    fn remote_subtree_delete_covers_a_child_named_with_a_high_byte() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let parent = PathBuf::from("p");
        let child = PathBuf::from(OsString::from_vec(b"p/\xffchild".to_vec()));
        journal.publish_remote_inventory(
            "cursor-old",
            &[
                RemoteObservationRecord {
                    canonical_path: CanonicalPath::from_display(&parent),
                    path: parent.clone(),
                    observation: Observation::Directory,
                },
                RemoteObservationRecord {
                    canonical_path: CanonicalPath::from_display(&child),
                    path: child,
                    observation: Observation::Present(remote_file("old", "rev-old")),
                },
            ],
        )?;
        assert_eq!(journal.remote_inventory()?.observations.len(), 2);

        journal.apply_remote_inventory_delta(
            "cursor-new",
            &[RemoteInventoryChange::DeleteSubtree {
                canonical_path: CanonicalPath::from_display(&parent),
            }],
        )?;

        assert!(journal.remote_inventory()?.observations.is_empty());
        Ok(())
    }

    #[test]
    fn case_collision_invalidation_covers_a_child_named_with_a_high_byte()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let parent = PathBuf::from("p");
        let child = PathBuf::from(OsString::from_vec(b"p/\xffchild".to_vec()));
        let directories = noop(plan(
            &Baseline::Directory,
            &Observation::Directory,
            &Observation::Directory,
            RemoteSubtree::Empty,
        ))?;
        journal.record_noop(&parent, &directories)?;
        let agreed = noop(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("old"))),
            &Observation::Present(remote_file("old", "rev-old")),
            RemoteSubtree::Empty,
        ))?;
        journal.record_noop(&child, &agreed)?;
        assert_eq!(journal.baselines()?.len(), 2);

        journal.invalidate_case_collision_baselines(&parent)?;

        assert!(journal.baselines()?.is_empty());
        Ok(())
    }

    #[test]
    fn baseline_snapshot_is_canonical_sorted() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        for (path, value, revision) in [
            (Path::new("Zulu.TXT"), "zulu", "rev-zulu"),
            (Path::new("alpha.txt"), "alpha", "rev-alpha"),
        ] {
            let agreed = noop(plan(
                &Baseline::Absent,
                &Observation::Present(LocalFile::new(content(value))),
                &Observation::Present(remote_file(value, revision)),
                RemoteSubtree::Empty,
            ))?;
            journal.record_noop(path, &agreed)?;
        }

        let records = journal.baselines()?;
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].canonical_path, canonical("alpha.txt"));
        assert_eq!(records[0].path, Path::new("alpha.txt"));
        assert_eq!(records[1].canonical_path, canonical("zulu.txt"));
        assert_eq!(records[1].path, Path::new("Zulu.TXT"));
        assert_eq!(
            records[1].baseline,
            Baseline::Present(remote_file("zulu", "rev-zulu"))
        );
        Ok(())
    }

    #[test]
    fn journal_remote_inventory_and_cursor_publish_atomically() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let old = RemoteObservationRecord {
            canonical_path: canonical("old.txt"),
            path: PathBuf::from("old.txt"),
            observation: Observation::Present(remote_file("old", "rev-old")),
        };
        journal.publish_remote_inventory("cursor-old", std::slice::from_ref(&old))?;

        let duplicate_path = PathBuf::from("duplicate.txt");
        let invalid_replacement = [
            RemoteObservationRecord {
                canonical_path: canonical("duplicate.txt"),
                path: duplicate_path.clone(),
                observation: Observation::ConfirmedAbsent,
            },
            RemoteObservationRecord {
                canonical_path: canonical("duplicate.txt"),
                path: duplicate_path,
                observation: Observation::Present(remote_file("new", "rev-new")),
            },
        ];
        let failed = journal.publish_remote_inventory("cursor-new", &invalid_replacement);
        assert!(failed.is_err());
        assert_eq!(
            journal.remote_inventory()?,
            RemoteInventory {
                cursor: Some(String::from("cursor-old")),
                observations: vec![old],
            }
        );
        Ok(())
    }

    #[test]
    fn remote_delta_mutates_only_changed_rows_and_cursor() -> Result<(), Box<dyn Error>> {
        const INVENTORY_SIZE: usize = 10_000;

        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let mut observations = Vec::with_capacity(INVENTORY_SIZE);
        observations.push(RemoteObservationRecord {
            canonical_path: canonical("bulk"),
            path: PathBuf::from("Bulk"),
            observation: Observation::Directory,
        });
        for index in 1..INVENTORY_SIZE {
            let path = PathBuf::from(format!("bulk/{index:05}.txt"));
            observations.push(RemoteObservationRecord {
                canonical_path: CanonicalPath::from_display(&path),
                path,
                observation: Observation::Present(remote_file("old", "rev-old")),
            });
        }
        journal.publish_remote_inventory("cursor-old", &observations)?;

        let before_empty = journal.connection.total_changes();
        journal.apply_remote_inventory_delta("cursor-empty", &[])?;
        assert_eq!(journal.connection.total_changes() - before_empty, 1);

        let changed_path = PathBuf::from("bulk/05000.txt");
        let changes = [
            RemoteInventoryChange::Upsert(RemoteObservationRecord {
                canonical_path: canonical("bulk"),
                path: PathBuf::from("Bulk"),
                observation: Observation::Directory,
            }),
            RemoteInventoryChange::DeleteSubtree {
                canonical_path: CanonicalPath::from_display(&changed_path),
            },
            RemoteInventoryChange::Upsert(RemoteObservationRecord {
                canonical_path: CanonicalPath::from_display(&changed_path),
                path: changed_path.clone(),
                observation: Observation::Present(remote_file("new", "rev-new")),
            }),
        ];
        let before_change = journal.connection.total_changes();
        journal.apply_remote_inventory_delta("cursor-new", &changes)?;
        assert_eq!(journal.connection.total_changes() - before_change, 3);

        let inventory = journal.remote_inventory()?;
        assert_eq!(inventory.cursor.as_deref(), Some("cursor-new"));
        assert_eq!(inventory.observations.len(), INVENTORY_SIZE);
        assert_eq!(
            inventory
                .observations
                .iter()
                .find(|record| record.canonical_path == CanonicalPath::from_display(&changed_path))
                .map(|record| &record.observation),
            Some(&Observation::Present(remote_file("new", "rev-new")))
        );
        Ok(())
    }

    #[test]
    fn remote_delta_deletes_only_the_named_subtree() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let observations = [
            ("a", Observation::Directory),
            (
                "a/child.txt",
                Observation::Present(remote_file("a-child", "rev-a")),
            ),
            ("ab", Observation::Directory),
            (
                "ab/child.txt",
                Observation::Present(remote_file("ab-child", "rev-ab")),
            ),
            (
                "a-file.txt",
                Observation::Present(remote_file("a-file", "rev-a-file")),
            ),
        ]
        .map(|(path, observation)| RemoteObservationRecord {
            canonical_path: canonical(path),
            path: PathBuf::from(path),
            observation,
        });
        journal.publish_remote_inventory("cursor-old", &observations)?;

        let descendant_prefix = b"a/".to_vec();
        let mut descendant_end = descendant_prefix.clone();
        descendant_end.push(u8::MAX);
        let query_plan = {
            let mut statement = journal
                .connection
                .prepare(&format!("EXPLAIN QUERY PLAN {DELETE_REMOTE_DESCENDANTS}"))?;
            let rows = statement.query_map(params![descendant_prefix, descendant_end], |row| {
                row.get::<_, String>(3)
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        assert!(
            query_plan
                .iter()
                .any(|detail| detail.contains("remote_observations_by_canonical_path"))
        );
        assert!(
            query_plan
                .iter()
                .all(|detail| !detail.contains("SCAN remote_observations"))
        );

        journal.apply_remote_inventory_delta(
            "cursor-new",
            &[RemoteInventoryChange::DeleteSubtree {
                canonical_path: canonical("a"),
            }],
        )?;

        let inventory = journal.remote_inventory()?;
        assert_eq!(inventory.cursor.as_deref(), Some("cursor-new"));
        assert_eq!(
            inventory
                .observations
                .iter()
                .map(|record| record.canonical_path.as_path())
                .collect::<Vec<_>>(),
            [
                Path::new("a-file.txt"),
                Path::new("ab"),
                Path::new("ab/child.txt")
            ]
        );
        Ok(())
    }

    #[test]
    fn journal_local_scan_replaces_inventory_and_hashes_atomically() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let binding = local_root("/sync", 2);
        let _ = journal.activate_local_root(&binding)?;
        let old = LocalObservationRecord {
            path: PathBuf::from("old.txt"),
            observation: Observation::Present(LocalFile::new(content("old"))),
        };
        let old_hash = local_hash("old.txt", 10);
        assert!(journal.publish_local_scan(
            &binding,
            std::slice::from_ref(&old),
            std::slice::from_ref(&old_hash),
        )?);
        let unchanged_start = journal.connection.total_changes();
        assert!(journal.publish_local_scan(
            &binding,
            std::slice::from_ref(&old),
            std::slice::from_ref(&old_hash),
        )?);
        assert_eq!(journal.connection.total_changes(), unchanged_start);

        let replacement = LocalObservationRecord {
            path: PathBuf::from("new.txt"),
            observation: Observation::Present(LocalFile::new(content("new"))),
        };
        let duplicate_hashes = [local_hash("new.txt", 20), local_hash("new.txt", 30)];
        assert!(
            journal
                .publish_local_scan(
                    &binding,
                    std::slice::from_ref(&replacement),
                    &duplicate_hashes,
                )
                .is_err()
        );

        assert_eq!(journal.local_inventory()?, vec![old.clone()]);
        assert_eq!(journal.local_hash_cache()?, vec![old_hash.clone()]);

        let stale_start = journal.connection.total_changes();
        assert!(!journal.publish_local_scan(
            &local_root("/stale", 4),
            std::slice::from_ref(&replacement),
            &[local_hash("new.txt", 20)],
        )?);
        assert_eq!(journal.connection.total_changes(), stale_start);
        assert_eq!(journal.local_inventory()?, vec![old]);
        assert_eq!(journal.local_hash_cache()?, vec![old_hash]);
        Ok(())
    }

    #[test]
    fn journal_final_operation_records_only_its_actual_result() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let path = Path::new("created.txt");
        let operation_plan = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("created"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let stale_conflict = Conflict::RemoteDeletionLocalEdit {
            local: LocalFile::new(content("created")),
        };
        let _ = journal.record_conflict(path, &stale_conflict)?;
        let plan = recorded_plan(journal.record_plan(path, &operation_plan)?)?;

        assert_eq!(
            journal.complete_operation(plan.operations[0].id, None)?,
            OperationCompletion::BaselineRequired
        );
        assert_eq!(journal.baseline(path)?, None);
        let wrong = Baseline::Present(remote_file("wrong", "rev-server"));
        assert_eq!(
            journal.complete_operation(plan.operations[0].id, Some(&wrong))?,
            OperationCompletion::BaselineMismatch
        );
        assert_eq!(journal.baseline(path)?, None);
        let actual = Baseline::Present(remote_file("created", "rev-server"));
        assert_eq!(
            journal.complete_operation(plan.operations[0].id, Some(&actual))?,
            OperationCompletion::PlanCompleted
        );
        assert_eq!(journal.baseline(path)?, Some(actual));
        assert!(journal.conflicts()?.is_empty());
        assert!(journal.pending_plans()?.is_empty());
        assert_eq!(
            journal.complete_operation(plan.operations[0].id, None)?,
            OperationCompletion::AlreadyCompleted
        );
        assert_eq!(journal.prune_completed_work()?, 1);
        assert_eq!(
            journal.complete_operation(plan.operations[0].id, None)?,
            OperationCompletion::NotFound
        );
        Ok(())
    }

    #[test]
    fn pending_upload_content_lists_only_unfinished_remote_payloads() -> Result<(), Box<dyn Error>>
    {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let create_path = Path::new("create.txt");
        let create = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("create"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let create = recorded_plan(journal.record_plan(create_path, &create)?)?;

        let replace_path = Path::new("replace.txt");
        let old = remote_file("old", "rev-old");
        let replace = operations(plan(
            &Baseline::Present(old.clone()),
            &Observation::Present(LocalFile::new(content("replace"))),
            &Observation::Present(old),
            RemoteSubtree::Empty,
        ))?;
        let _ = recorded_plan(journal.record_plan(replace_path, &replace)?)?;

        let download = operations(plan(
            &Baseline::Absent,
            &Observation::ConfirmedAbsent,
            &Observation::Present(remote_file("download", "rev-download")),
            RemoteSubtree::Empty,
        ))?;
        let _ = journal.record_plan(Path::new("download.txt"), &download)?;

        assert_eq!(
            journal.pending_upload_content()?,
            vec![content("create"), content("replace")]
        );

        let created = Baseline::Present(remote_file("create", "rev-created"));
        assert_eq!(
            journal.complete_operation(create.operations[0].id, Some(&created))?,
            OperationCompletion::PlanCompleted
        );
        assert_eq!(journal.pending_upload_content()?, vec![content("replace")]);
        Ok(())
    }

    #[test]
    fn journal_destructive_completion_retires_legacy_recovery_across_reopen()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("replace.txt");
        let old = content("old");
        let target = Baseline::Present(remote_file("new", "rev-server"));
        let operation_plan = OperationPlan::new(vec![
            Operation::PreserveRemote {
                file: remote_file("old", "rev-current"),
            },
            Operation::ReplaceRemote {
                content: content("new"),
                expected_revision: DropboxRevision::new("rev-current"),
            },
        ]);
        let (plan, recovery) = {
            let mut journal = Journal::open(&database_path)?;
            let plan = recorded_plan(journal.record_plan(path, &operation_plan)?)?;
            assert_eq!(
                journal.complete_operation(plan.operations[1].id, Some(&target))?,
                OperationCompletion::WaitingForEarlierOperation(plan.operations[0].id)
            );
            assert_eq!(
                journal.complete_operation(plan.operations[0].id, Some(&target))?,
                OperationCompletion::UnexpectedBaseline
            );
            assert_eq!(
                journal.complete_operation(plan.operations[0].id, None)?,
                OperationCompletion::OperationCompleted
            );
            let recovery = recorded_recovery(journal.record_recovery_intent(
                plan.operations[1].id,
                Path::new("recovery/replace.txt"),
            )?)?;
            (plan, recovery)
        };

        let mut reopened = Journal::open(&database_path)?;
        assert_eq!(recovery.content, old);
        assert_eq!(reopened.baseline(path)?, None);
        assert_eq!(reopened.pending_recoveries()?, vec![recovery.clone()]);
        assert_eq!(
            reopened.forget_completed_recovery(recovery.id)?,
            RecoveryForget::Pending
        );
        assert_eq!(
            reopened.complete_operation(plan.operations[1].id, Some(&target))?,
            OperationCompletion::PlanCompleted
        );
        assert_eq!(
            reopened.complete_operation(plan.operations[1].id, Some(&target))?,
            OperationCompletion::AlreadyCompleted
        );
        assert_eq!(reopened.baseline(path)?, Some(target));
        let eligible = reopened.completed_recoveries()?;
        let [eligible] = eligible.as_slice() else {
            return Err(JournalError::InvalidState {
                operation: "read retained test recovery",
                path: path.to_path_buf(),
                detail: "test expected exactly one retained recovery",
            }
            .into());
        };
        let Some(retained_at) = eligible.retained_at else {
            return Err(JournalError::InvalidState {
                operation: "read retained test recovery",
                path: path.to_path_buf(),
                detail: "completed destructive operation did not start retention",
            }
            .into());
        };
        assert!(retained_at > 0);
        let completed = RecoveryRecord {
            status: RecordStatus::Completed,
            retained_at: Some(retained_at),
            ..recovery.clone()
        };
        assert_eq!(eligible, &completed);
        assert_eq!(reopened.prune_completed_work()?, 1);
        assert!(read_plan(&reopened.connection, &database_path, plan.id)?.is_none());
        let fresh = operations(crate::planner::plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("fresh"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let fresh = recorded_plan(reopened.record_plan(Path::new("fresh.txt"), &fresh)?)?;
        assert!(fresh.operations[0].id.0 > recovery.operation_id.0);
        assert_eq!(
            reopened.completed_recoveries()?,
            vec![RecoveryRecord {
                status: RecordStatus::Completed,
                retained_at: Some(retained_at),
                ..recovery.clone()
            }]
        );
        assert_eq!(
            reopened.forget_completed_recovery(recovery.id)?,
            RecoveryForget::Forgotten
        );
        assert!(reopened.completed_recoveries()?.is_empty());
        assert_eq!(
            reopened.forget_completed_recovery(recovery.id)?,
            RecoveryForget::NotFound
        );
        Ok(())
    }

    #[test]
    fn version_one_migrates_without_absent_rows_or_recovery_loss() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("removed.txt");
        let kept_path = Path::new("kept.txt");
        let kept_baseline = Baseline::Present(remote_file("kept", "rev-kept"));
        let operation = Operation::DeleteLocal {
            expected_content: content("old"),
        };
        {
            let connection = Connection::open(&database_path)?;
            connection.execute_batch(MIGRATION_V1)?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                params![path_bytes(path), encode(&Baseline::Absent, "test", path)?],
            )?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                params![
                    path_bytes(kept_path),
                    encode(&kept_baseline, "test", kept_path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO plans(id, path, status) VALUES (10, ?1, 'completed')",
                [path_bytes(path)],
            )?;
            connection.execute(
                "INSERT INTO operations( \
                     id, plan_id, ordinal, operation_json, status \
                 ) VALUES (20, 10, 0, ?1, 'completed')",
                [encode(&operation, "test", path)?],
            )?;
            connection.execute(
                "INSERT INTO recovery_records( \
                     id, operation_id, original_path, recovery_path, content_json, status \
                 ) VALUES (30, 20, ?1, ?2, ?3, 'completed')",
                params![
                    path_bytes(path),
                    path_bytes(Path::new("recovery/removed.txt")),
                    encode(&content("old"), "test", path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO plans(id, path, status) VALUES (11, ?1, 'pending')",
                [path_bytes(Path::new("pending.txt"))],
            )?;
            connection.execute(
                "INSERT INTO operations( \
                     id, plan_id, ordinal, operation_json, status \
                 ) VALUES (21, 11, 0, ?1, 'pending')",
                [encode(&operation, "test", Path::new("pending.txt"))?],
            )?;
            connection.execute(
                "INSERT INTO recovery_records( \
                     id, operation_id, original_path, recovery_path, content_json, status \
                 ) VALUES (31, 21, ?1, ?2, ?3, 'pending')",
                params![
                    path_bytes(Path::new("pending.txt")),
                    path_bytes(Path::new("recovery/pending.txt")),
                    encode(&content("pending"), "test", Path::new("pending.txt"))?
                ],
            )?;
        }

        let legacy = Journal::open_read_only(&database_path)?;
        assert_eq!(legacy.baseline(path)?, None);
        assert_eq!(legacy.local_root_binding()?, None);
        assert_eq!(legacy.pending_plans()?.len(), 1);
        assert_eq!(
            legacy.pending_recoveries()?,
            vec![RecoveryRecord {
                id: RecoveryId(31),
                operation_id: OperationId(21),
                original_path: PathBuf::from("pending.txt"),
                recovery_path: PathBuf::from("recovery/pending.txt"),
                content: content("pending"),
                status: RecordStatus::Pending,
                retained_at: None,
            }]
        );
        assert!(legacy.completed_recoveries()?.is_empty());
        drop(legacy);

        let mut journal = Journal::open(&database_path)?;
        assert_eq!(journal.schema_version, 7);
        assert_eq!(journal.baseline(path)?, None);
        assert_eq!(journal.baseline(kept_path)?, Some(kept_baseline.clone()));
        assert_eq!(journal.baseline_paths()?, vec![kept_path.to_path_buf()]);
        assert!(read_plan(&journal.connection, &database_path, PlanId(10))?.is_none());
        let migrated = journal.completed_recoveries()?;
        let [migrated] = migrated.as_slice() else {
            return Err(JournalError::InvalidState {
                operation: "read migrated recovery",
                path: path.to_path_buf(),
                detail: "test expected exactly one migrated recovery",
            }
            .into());
        };
        assert_eq!(migrated.id, RecoveryId(30));
        assert_eq!(migrated.operation_id, OperationId(20));
        assert_eq!(migrated.original_path, path);
        assert_eq!(migrated.recovery_path, Path::new("recovery/removed.txt"));
        assert_eq!(migrated.content, content("old"));
        assert_eq!(migrated.status, RecordStatus::Completed);
        assert!(migrated.retained_at.is_some());
        assert_eq!(journal.pending_plans()?.len(), 1);
        assert_eq!(journal.pending_recoveries()?.len(), 1);
        assert_eq!(journal.pending_recoveries()?[0].retained_at, None);

        let configured = local_root("/sync/configured", 8);
        let configured_record = LocalRootRecord {
            binding: configured.clone(),
            generation: 1,
        };
        assert_eq!(
            journal.activate_local_root(&configured)?,
            LocalRootActivation::Activated(configured_record.clone())
        );
        assert_eq!(
            journal.local_root_binding()?,
            Some(configured_record.clone())
        );
        assert_eq!(journal.baseline(kept_path)?, None);
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.pending_recoveries()?.is_empty());

        let changed = local_root("/sync/changed", 10);
        assert_eq!(
            journal.activate_local_root(&changed)?,
            LocalRootActivation::Activated(LocalRootRecord {
                binding: changed,
                generation: 2,
            })
        );
        let version = journal
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 7);
        let mut foreign_keys = journal
            .connection
            .prepare("PRAGMA foreign_key_list(recovery_records)")?;
        let references = foreign_keys.query_map([], |_| Ok(()))?.count();
        assert_eq!(references, 0);
        Ok(())
    }

    #[test]
    fn version_three_migrates_existing_paths_to_canonical_identity() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let display_path = Path::new("Folder/Report.TXT");
        let canonical_path = Path::new("folder/report.txt");
        let baseline = Baseline::Present(remote_file("same", "rev-same"));
        let operation = Operation::CreateRemote {
            content: content("pending"),
        };
        {
            let connection = Connection::open(&database_path)?;
            connection.execute_batch(MIGRATION_V1)?;
            connection.execute_batch(MIGRATION_V2)?;
            connection.execute_batch(MIGRATION_V3)?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                params![
                    path_bytes(display_path),
                    encode(&baseline, "test", display_path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO plans(id, path, status) VALUES (10, ?1, 'pending')",
                [path_bytes(Path::new("Pending.TXT"))],
            )?;
            connection.execute(
                "INSERT INTO operations(\
                     id, plan_id, ordinal, operation_json, status\
                 ) VALUES (20, 10, 0, ?1, 'pending')",
                [encode(&operation, "test", Path::new("Pending.TXT"))?],
            )?;
            connection.execute(
                "INSERT INTO remote_observations(path, observation_json) VALUES (?1, ?2)",
                params![
                    path_bytes(display_path),
                    encode(
                        &Observation::Present(remote_file("same", "rev-same")),
                        "test",
                        display_path,
                    )?
                ],
            )?;
            connection.execute(
                "INSERT INTO remote_inventory(singleton, cursor) VALUES (1, 'stale')",
                [],
            )?;
        }

        let mut journal = Journal::open(&database_path)?;
        assert_eq!(journal.baseline(canonical_path)?, Some(baseline));
        assert_eq!(journal.baseline_paths()?, vec![display_path.to_path_buf()]);
        assert_eq!(
            journal.remote_inventory()?,
            RemoteInventory {
                cursor: None,
                observations: Vec::new(),
            }
        );
        let duplicate = OperationPlan::new(vec![operation]);
        assert!(matches!(
            journal.record_plan(Path::new("pending.txt"), &duplicate)?,
            PlanWrite::AlreadyLive(plan) if plan.path == Path::new("Pending.TXT")
        ));
        let version = journal
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 7);
        Ok(())
    }

    #[test]
    fn version_three_case_collisions_keep_one_live_plan_per_canonical_path()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let first_path = Path::new("Foo.txt");
        let second_path = Path::new("foo.TXT");
        let operation = Operation::CreateRemote {
            content: content("pending"),
        };
        {
            let connection = Connection::open(&database_path)?;
            connection.execute_batch(MIGRATION_V1)?;
            connection.execute_batch(MIGRATION_V2)?;
            connection.execute_batch(MIGRATION_V3)?;
            for (path, revision) in [(first_path, "rev-first"), (second_path, "rev-second")] {
                let baseline = Baseline::Present(remote_file("old", revision));
                connection.execute(
                    "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                    params![path_bytes(path), encode(&baseline, "test", path)?],
                )?;
            }
            for (plan_id, operation_id, path) in [(10, 20, first_path), (11, 21, second_path)] {
                connection.execute(
                    "INSERT INTO plans(id, path, status) VALUES (?1, ?2, 'pending')",
                    params![plan_id, path_bytes(path)],
                )?;
                connection.execute(
                    "INSERT INTO operations(\
                         id, plan_id, ordinal, operation_json, status\
                     ) VALUES (?1, ?2, 0, ?3, 'pending')",
                    params![operation_id, plan_id, encode(&operation, "test", path)?],
                )?;
            }
        }

        let mut journal = Journal::open(&database_path)?;
        assert!(journal.baseline_paths()?.is_empty());
        assert_eq!(journal.baseline(first_path)?, None);
        assert_eq!(journal.baseline(second_path)?, None);
        let live = journal.pending_plans()?;
        let [kept] = live.as_slice() else {
            return Err("collided plans did not converge on one live plan".into());
        };
        assert_eq!(kept.id, PlanId(10));
        assert_eq!(kept.path, first_path);
        assert_eq!(kept.status, PlanStatus::Pending);
        for (table, id) in [("plans", 11), ("operations", 21)] {
            let surviving = journal.connection.query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE id = ?1"),
                [id],
                |row| row.get::<_, i64>(0),
            )?;
            assert_eq!(surviving, 0, "superseded {table} row was not retired");
        }
        let new_plan = OperationPlan::new(vec![operation]);
        assert!(matches!(
            journal.record_plan(Path::new("FOO.txt"), &new_plan)?,
            PlanWrite::AlreadyLive(_)
        ));
        assert_eq!(journal.pending_plans()?.len(), 1);
        drop(journal);

        let reopened = Journal::open(&database_path)?;
        assert_eq!(reopened.pending_plans()?.len(), 1);
        assert!(reopened.baseline_paths()?.is_empty());
        Ok(())
    }

    #[test]
    fn blocking_a_plan_hides_it_from_pending_work_across_reopen() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("blocked.txt");
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("upload"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let reason = BlockReason::RemoteRejected {
            tag: String::from("insufficient_space"),
        };

        let mut journal = Journal::open(&database_path)?;
        let recorded = recorded_plan(journal.record_plan(path, &upload)?)?;
        assert_eq!(recorded.status, PlanStatus::Pending);
        assert_eq!(
            journal.block_plan(recorded.id, &reason, 1_700_000_000)?,
            PlanBlock::Blocked
        );

        assert!(journal.pending_plans()?.is_empty());
        let blocked = journal.blocked_plans()?;
        let [blocked] = blocked.as_slice() else {
            return Err("blocked plan was not durable".into());
        };
        assert_eq!(blocked.id, recorded.id);
        assert_eq!(blocked.path, path);
        assert_eq!(blocked.operations, recorded.operations);
        assert_eq!(
            blocked.status,
            PlanStatus::Blocked {
                reason: reason.clone(),
                retry_at: 1_700_000_000,
            }
        );
        drop(journal);

        let mut reopened = Journal::open(&database_path)?;
        assert!(reopened.pending_plans()?.is_empty());
        assert_eq!(reopened.blocked_plans()?.len(), 1);
        assert_eq!(
            reopened.block_plan(recorded.id, &BlockReason::StageOccupied, 1_700_003_600)?,
            PlanBlock::Blocked
        );
        let reblocked = reopened.blocked_plans()?;
        let [reblocked] = reblocked.as_slice() else {
            return Err("re-blocked plan was not durable".into());
        };
        assert_eq!(
            reblocked.status,
            PlanStatus::Blocked {
                reason: BlockReason::StageOccupied,
                retry_at: 1_700_003_600,
            }
        );

        assert_eq!(reopened.unblock_plan(recorded.id)?, PlanUnblock::Unblocked);
        assert!(reopened.blocked_plans()?.is_empty());
        let live = reopened.pending_plans()?;
        let [live] = live.as_slice() else {
            return Err("unblocked plan did not return to pending work".into());
        };
        assert_eq!(live.id, recorded.id);
        assert_eq!(live.status, PlanStatus::Pending);
        assert_eq!(reopened.unblock_plan(recorded.id)?, PlanUnblock::NotBlocked);
        Ok(())
    }

    #[test]
    fn blocking_reports_missing_and_finished_plans_without_changing_them()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("finished.txt");
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("upload"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let reason = BlockReason::DownloadUnavailable { status: 409 };

        let mut journal = Journal::open(&database_path)?;
        let recorded = recorded_plan(journal.record_plan(path, &upload)?)?;
        assert_eq!(
            journal.supersede_plan(recorded.id)?,
            PlanSupersede::Superseded
        );

        assert_eq!(
            journal.block_plan(recorded.id, &reason, 1_700_000_000)?,
            PlanBlock::AlreadyCompleted
        );
        assert!(journal.blocked_plans()?.is_empty());
        assert_eq!(journal.unblock_plan(recorded.id)?, PlanUnblock::NotBlocked);
        assert_eq!(
            journal.block_plan(PlanId(9_999), &reason, 1_700_000_000)?,
            PlanBlock::NotFound
        );
        assert_eq!(journal.unblock_plan(PlanId(9_999))?, PlanUnblock::NotFound);
        Ok(())
    }

    #[test]
    fn blocked_plan_upload_payloads_stay_referenced() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("upload.txt");
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("upload"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;

        let mut journal = Journal::open(&database_path)?;
        let recorded = recorded_plan(journal.record_plan(path, &upload)?)?;
        assert_eq!(journal.pending_upload_content()?, vec![content("upload")]);

        assert_eq!(
            journal.block_plan(recorded.id, &BlockReason::RemoteObject, 1_700_000_000)?,
            PlanBlock::Blocked
        );

        assert_eq!(journal.pending_upload_content()?, vec![content("upload")]);
        assert_eq!(
            journal.supersede_plan(recorded.id)?,
            PlanSupersede::Superseded
        );
        assert!(journal.pending_upload_content()?.is_empty());
        Ok(())
    }

    #[test]
    fn a_blocked_path_keeps_its_plan_instead_of_gaining_a_second_one() -> Result<(), Box<dyn Error>>
    {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("Contested.TXT");
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("upload"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;

        let mut journal = Journal::open(&database_path)?;
        let recorded = recorded_plan(journal.record_plan(path, &upload)?)?;
        assert_eq!(
            journal.block_plan(recorded.id, &BlockReason::LocalObjectInWay, 1_700_000_000)?,
            PlanBlock::Blocked
        );

        let repeated = journal.record_plan(Path::new("contested.txt"), &upload)?;
        let PlanWrite::AlreadyLive(live) = repeated else {
            return Err("a blocked path accepted a second live plan".into());
        };

        assert_eq!(live.id, recorded.id);
        assert_eq!(
            live.status,
            PlanStatus::Blocked {
                reason: BlockReason::LocalObjectInWay,
                retry_at: 1_700_000_000,
            }
        );
        assert_eq!(
            journal.connection.query_row(
                "SELECT COUNT(*) FROM plans WHERE status IN ('pending', 'blocked')",
                [],
                |row| row.get::<_, i64>(0)
            )?,
            1
        );
        Ok(())
    }

    #[test]
    fn pending_plans_reads_every_plan_and_operation_in_one_query() -> Result<(), Box<dyn Error>> {
        static STATEMENTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

        fn count(_: rusqlite::trace::TraceEvent<'_>) {
            STATEMENTS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }

        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("upload"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let displaced = LocalFile::new(content("displaced"));
        let ordered_plan = OperationPlan::new(vec![
            Operation::PreserveLocal {
                file: displaced.clone(),
            },
            Operation::DeleteLocal {
                expected_content: displaced.content,
            },
        ]);
        for name in ["a.txt", "b.txt", "c.txt"] {
            let _ = recorded_plan(journal.record_plan(Path::new(name), &upload)?)?;
        }
        let ordered = recorded_plan(journal.record_plan(Path::new("d.txt"), &ordered_plan)?)?;
        assert!(ordered.operations.len() > 1);

        STATEMENTS.store(0, std::sync::atomic::Ordering::Relaxed);
        journal.connection.trace_v2(
            rusqlite::trace::TraceEventCodes::SQLITE_TRACE_STMT,
            Some(count),
        );
        let plans = journal.pending_plans()?;
        journal
            .connection
            .trace_v2(rusqlite::trace::TraceEventCodes::empty(), None);

        assert_eq!(STATEMENTS.load(std::sync::atomic::Ordering::Relaxed), 1);
        assert_eq!(plans.len(), 4);
        let identities = plans
            .iter()
            .map(|record| {
                (
                    record.id,
                    record
                        .operations
                        .iter()
                        .map(|operation| operation.ordinal)
                        .collect::<Vec<_>>(),
                )
            })
            .collect::<Vec<_>>();
        let mut sorted = identities.clone();
        sorted.sort_by_key(|(id, _)| id.0);
        assert_eq!(identities, sorted);
        for (_, ordinals) in &identities {
            let mut expected = ordinals.clone();
            expected.sort_unstable();
            assert_eq!(ordinals, &expected);
        }
        Ok(())
    }

    #[test]
    fn version_five_migrates_plans_operations_and_canonical_paths() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let legacy_baseline_path = Path::new("Legacy/Report.TXT");
        let legacy_conflict_path = Path::new("Diverged.TXT");
        let legacy_remote_path = Path::new("Remote/Dir");
        let pending_path = Path::new("Pending.TXT");
        let completed_path = Path::new("done.txt");
        let baseline = Baseline::Present(remote_file("legacy", "rev-legacy"));
        let conflict = Conflict::RemoteDeletionLocalEdit {
            local: LocalFile::new(content("diverged")),
        };
        let first = Operation::CreateRemote {
            content: content("first"),
        };
        let second = Operation::DeleteRemote {
            expected_revision: DropboxRevision::new("rev-second"),
        };
        {
            let connection = version_five(&database_path)?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                params![
                    path_bytes(legacy_baseline_path),
                    encode(&baseline, "test", legacy_baseline_path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO conflicts(id, path, conflict_json) VALUES (40, ?1, ?2)",
                params![
                    path_bytes(legacy_conflict_path),
                    encode(&conflict, "test", legacy_conflict_path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO remote_observations(path, observation_json) VALUES (?1, ?2)",
                params![
                    path_bytes(legacy_remote_path),
                    encode(&RemoteObservation::Directory, "test", legacy_remote_path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO plans(id, path, status, canonical_path) \
                 VALUES (10, ?1, 'pending', ?2)",
                params![
                    path_bytes(pending_path),
                    canonical("pending.txt").as_bytes()
                ],
            )?;
            connection.execute(
                "INSERT INTO operations(id, plan_id, ordinal, operation_json, status) \
                 VALUES (20, 10, 0, ?1, 'pending')",
                [encode(&first, "test", pending_path)?],
            )?;
            connection.execute(
                "INSERT INTO operations(id, plan_id, ordinal, operation_json, status) \
                 VALUES (21, 10, 1, ?1, 'pending')",
                [encode(&second, "test", pending_path)?],
            )?;
            connection.execute(
                "INSERT INTO plans(id, path, status, canonical_path) \
                 VALUES (11, ?1, 'completed', ?2)",
                params![path_bytes(completed_path), canonical("done.txt").as_bytes()],
            )?;
            connection.execute(
                "INSERT INTO operations(id, plan_id, ordinal, operation_json, status) \
                 VALUES (22, 11, 0, ?1, 'completed')",
                [encode(&first, "test", completed_path)?],
            )?;
            connection.execute(
                "INSERT INTO recovery_records( \
                     id, operation_id, original_path, recovery_path, content_json, status \
                 ) VALUES (30, 22, ?1, ?2, ?3, 'completed')",
                params![
                    path_bytes(completed_path),
                    path_bytes(Path::new("recovery/done.txt")),
                    encode(&content("first"), "test", completed_path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO remote_inventory(singleton, cursor) VALUES (1, 'cursor-v5')",
                [],
            )?;
            connection.execute(
                "UPDATE sqlite_sequence SET seq = 99 WHERE name = 'operations'",
                [],
            )?;
        }

        let journal = Journal::open(&database_path)?;
        assert_eq!(journal.schema_version, 7);
        assert_eq!(
            journal
                .connection
                .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?,
            7
        );

        let pending = journal.pending_plans()?;
        let [plan] = pending.as_slice() else {
            return Err("migrated journal lost its single pending plan".into());
        };
        assert_eq!(plan.id, PlanId(10));
        assert_eq!(plan.path, pending_path);
        let identities = plan
            .operations
            .iter()
            .map(|operation| (operation.id, operation.ordinal, operation.status))
            .collect::<Vec<_>>();
        assert_eq!(
            identities,
            vec![
                (OperationId(20), 0, RecordStatus::Pending),
                (OperationId(21), 1, RecordStatus::Pending),
            ]
        );
        assert_eq!(
            journal
                .connection
                .query_row("SELECT status FROM plans WHERE id = 11", [], |row| row
                    .get::<_, String>(
                    0
                ))?,
            "completed"
        );
        assert_eq!(
            journal.connection.query_row(
                "SELECT status FROM operations WHERE id = 22",
                [],
                |row| row.get::<_, String>(0)
            )?,
            "completed"
        );

        assert_eq!(
            journal.baseline(Path::new("legacy/report.txt"))?,
            Some(baseline)
        );
        for (table, path, canonical_path) in [
            ("baselines", legacy_baseline_path, "legacy/report.txt"),
            ("conflicts", legacy_conflict_path, "diverged.txt"),
            ("remote_observations", legacy_remote_path, "remote/dir"),
        ] {
            let stored = journal.connection.query_row(
                &format!("SELECT canonical_path FROM {table} WHERE path = ?1"),
                [path_bytes(path)],
                |row| row.get::<_, Vec<u8>>(0),
            )?;
            assert_eq!(stored, canonical(canonical_path).as_bytes());
        }

        let mut check = journal.connection.prepare("PRAGMA foreign_key_check")?;
        assert_eq!(check.query_map([], |_| Ok(()))?.count(), 0);
        drop(check);
        let mut parents = journal
            .connection
            .prepare("PRAGMA foreign_key_list(operations)")?;
        let parents = parents
            .query_map([], |row| {
                Ok((row.get::<_, String>(2)?, row.get::<_, String>(6)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        assert_eq!(
            parents,
            vec![(String::from("plans"), String::from("RESTRICT"))]
        );

        for (name, expected) in [
            ("one_live_plan_per_path", 1),
            ("one_pending_plan_per_path", 0),
            ("operations_by_plan", 1),
            ("remote_directories", 1),
            ("baselines_by_canonical_path", 1),
            ("remote_observations_by_canonical_path", 1),
            ("conflicts_by_canonical_path", 1),
        ] {
            let found = journal.connection.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1",
                [name],
                |row| row.get::<_, i64>(0),
            )?;
            assert_eq!(found, expected, "index {name}");
        }

        for table in ["baselines", "remote_observations", "conflicts", "plans"] {
            let sql = journal.connection.query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |row| row.get::<_, String>(0),
            )?;
            assert!(sql.contains("STRICT"), "{table} is not STRICT");
            assert!(
                sql.contains("canonical_path BLOB NOT NULL"),
                "{table} allows a null canonical path"
            );
        }

        assert!(
            journal
                .connection
                .execute(
                    "INSERT INTO baselines(path, baseline_json, canonical_path) \
                     VALUES (?1, '\"Absent\"', NULL)",
                    [path_bytes(Path::new("null.txt"))],
                )
                .is_err()
        );
        assert!(
            journal
                .connection
                .execute(
                    "INSERT INTO plans(path, status, canonical_path, blocked_json, retry_at) \
                     VALUES (?1, 'blocked', ?2, NULL, NULL)",
                    params![
                        path_bytes(Path::new("blocked.txt")),
                        canonical("blocked.txt").as_bytes()
                    ],
                )
                .is_err()
        );
        assert_eq!(
            journal.connection.query_row(
                "SELECT seq FROM sqlite_sequence WHERE name = 'operations'",
                [],
                |row| row.get::<_, i64>(0)
            )?,
            99
        );
        assert_eq!(
            journal
                .connection
                .query_row("SELECT cursor FROM remote_inventory", [], |row| row
                    .get::<_, String>(0))?,
            "cursor-v5",
            "a migration that discarded no remote row still dropped its cursor"
        );
        Ok(())
    }

    #[test]
    fn version_five_backfill_collisions_discard_both_claims() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let kept_path = Path::new("Unique.TXT");
        let kept = Baseline::Present(remote_file("unique", "rev-unique"));
        let collided = Baseline::Present(remote_file("collided", "rev-collided"));
        let conflict = Conflict::RemoteDeletionLocalEdit {
            local: LocalFile::new(content("diverged")),
        };
        {
            let connection = version_five(&database_path)?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json, canonical_path) VALUES (?1, ?2, ?3)",
                params![
                    path_bytes(Path::new("Collided.TXT")),
                    encode(&collided, "test", Path::new("Collided.TXT"))?,
                    canonical("collided.txt").as_bytes()
                ],
            )?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                params![
                    path_bytes(Path::new("COLLIDED.txt")),
                    encode(&collided, "test", Path::new("COLLIDED.txt"))?
                ],
            )?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                params![path_bytes(kept_path), encode(&kept, "test", kept_path)?],
            )?;
            connection.execute(
                "INSERT INTO remote_observations(path, observation_json, canonical_path) \
                 VALUES (?1, ?2, ?3)",
                params![
                    path_bytes(Path::new("Remote/Dir")),
                    encode(
                        &RemoteObservation::Directory,
                        "test",
                        Path::new("Remote/Dir")
                    )?,
                    canonical("remote/dir").as_bytes()
                ],
            )?;
            connection.execute(
                "INSERT INTO remote_observations(path, observation_json) VALUES (?1, ?2)",
                params![
                    path_bytes(Path::new("REMOTE/dir")),
                    encode(
                        &RemoteObservation::Directory,
                        "test",
                        Path::new("REMOTE/dir")
                    )?
                ],
            )?;
            connection.execute(
                "INSERT INTO remote_inventory(singleton, cursor) VALUES (1, 'cursor-v5')",
                [],
            )?;
            for (id, path) in [
                (41, Path::new("Diverged.TXT")),
                (42, Path::new("diverged.txt")),
            ] {
                connection.execute(
                    "INSERT INTO conflicts(id, path, conflict_json) VALUES (?1, ?2, ?3)",
                    params![id, path_bytes(path), encode(&conflict, "test", path)?],
                )?;
            }
        }

        let journal = Journal::open(&database_path)?;

        assert_eq!(journal.schema_version, 7);
        assert_eq!(journal.baseline_paths()?, vec![kept_path.to_path_buf()]);
        assert_eq!(journal.baseline(Path::new("unique.txt"))?, Some(kept));
        assert_eq!(journal.baseline(Path::new("collided.txt"))?, None);
        assert_eq!(
            journal.connection.query_row(
                "SELECT COUNT(*) FROM remote_observations",
                [],
                |row| row.get::<_, i64>(0)
            )?,
            0
        );
        assert_eq!(
            journal
                .connection
                .query_row("SELECT COUNT(*) FROM remote_inventory", [], |row| row
                    .get::<_, i64>(0))?,
            0,
            "a discarded remote row left a cursor that can never redeliver it"
        );
        let conflicts = journal.conflicts()?;
        assert_eq!(conflicts.len(), 2);
        assert_eq!(
            journal.connection.query_row(
                "SELECT COUNT(*) FROM conflicts WHERE canonical_path = ?1",
                [canonical("diverged.txt").as_bytes()],
                |row| row.get::<_, i64>(0)
            )?,
            2
        );
        Ok(())
    }

    #[test]
    fn a_plan_without_operations_is_refused() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let empty = OperationPlan::new(Vec::new());

        let recorded = journal.record_plan(Path::new("empty.txt"), &empty);

        let error = recorded
            .err()
            .ok_or("journal accepted a plan with no operations")?;
        assert!(
            matches!(
                error,
                JournalError::InvalidState {
                    operation: "record plan",
                    ..
                }
            ),
            "unexpected error: {error:?}"
        );
        assert!(journal.pending_plans()?.is_empty());
        assert_eq!(
            journal
                .connection
                .query_row("SELECT COUNT(*) FROM plans", [], |row| row.get::<_, i64>(0))?,
            0
        );
        Ok(())
    }

    #[test]
    fn journal_creation_reports_its_own_filesystem_failure() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let sealed = directory.path().join("sealed");
        fs::create_dir(&sealed)?;
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o500))?;

        let opened = Journal::open(sealed.join("journal.sqlite3"));

        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o700))?;
        let error = opened.err().ok_or("sealed directory accepted a journal")?;
        assert!(
            matches!(
                error,
                JournalError::File {
                    operation: "create journal database",
                    ..
                }
            ),
            "unexpected error: {error:?}"
        );
        Ok(())
    }

    #[test]
    fn writable_journal_never_truncates_an_existing_database() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("kept.txt");
        let baseline = Baseline::Present(remote_file("kept", "rev-kept"));
        {
            let mut journal = Journal::open(&database_path)?;
            journal.record_noop(
                path,
                &noop(plan(
                    &Baseline::Absent,
                    &Observation::Present(LocalFile::new(content("kept"))),
                    &Observation::Present(remote_file("kept", "rev-kept")),
                    RemoteSubtree::Empty,
                ))?,
            )?;
        }

        let journal = Journal::open(&database_path)?;

        assert_eq!(journal.baseline(path)?, Some(baseline));
        assert_eq!(file_mode(&database_path)?, 0o600);
        Ok(())
    }

    #[test]
    fn journal_refuses_a_symlinked_database() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let planted = directory.path().join("planted.sqlite3");
        let dangling = directory.path().join("dangling.sqlite3");
        std::os::unix::fs::symlink(&planted, &dangling)?;

        let opened = Journal::open(&dangling);

        let error = opened
            .err()
            .ok_or("a dangling symlink was accepted as a journal")?;
        assert!(
            matches!(
                error,
                JournalError::File {
                    operation: "create journal database",
                    ..
                }
            ),
            "unexpected error: {error:?}"
        );
        assert!(
            !planted.try_exists()?,
            "the journal was created through a dangling symlink"
        );

        let existing = directory.path().join("existing.sqlite3");
        drop(Journal::open(&existing)?);
        let linked = directory.path().join("linked.sqlite3");
        std::os::unix::fs::symlink(&existing, &linked)?;

        let opened = Journal::open(&linked);

        let error = opened
            .err()
            .ok_or("a symlink to a database was accepted as a journal")?;
        assert!(
            matches!(
                error,
                JournalError::File {
                    operation: "create journal database",
                    ..
                }
            ),
            "unexpected error: {error:?}"
        );
        Ok(())
    }

    #[test]
    fn plan_status_decoding_names_the_state_it_rejects() -> Result<(), Box<dyn Error>> {
        let path = Path::new("crafted.txt");
        let blocked = encode(&BlockReason::StageOccupied, "test", path)?;

        assert_eq!(
            decode_plan_status("pending", None, None, "read plan status", path)?,
            PlanStatus::Pending
        );
        assert_eq!(
            decode_plan_status("completed", None, None, "read plan status", path)?,
            PlanStatus::Completed
        );
        for (status, json, retry_at, expected) in [
            (
                "pending",
                Some(blocked.as_str()),
                None,
                "plan status disagrees with its block columns",
            ),
            (
                "completed",
                None,
                Some(1),
                "plan status disagrees with its block columns",
            ),
            (
                "blocked",
                None,
                Some(1),
                "plan status disagrees with its block columns",
            ),
            (
                "blocked",
                Some(blocked.as_str()),
                None,
                "plan status disagrees with its block columns",
            ),
            ("retired", None, None, "plan has an unrecognized status"),
            (
                "retired",
                Some(blocked.as_str()),
                Some(1),
                "plan has an unrecognized status",
            ),
        ] {
            let error = decode_plan_status(status, json, retry_at, "read plan status", path)
                .err()
                .ok_or("crafted plan columns decoded as a status")?;
            assert!(
                matches!(
                    error,
                    JournalError::InvalidState { detail, .. } if detail == expected
                ),
                "unexpected error for status {status}: {error:?}"
            );
        }
        let negative = decode_plan_status(
            "blocked",
            Some(&blocked),
            Some(-1),
            "read plan status",
            path,
        )
        .err()
        .ok_or("a negative retry time decoded as a status")?;
        assert!(
            matches!(
                negative,
                JournalError::InvalidState {
                    detail: "blocked plan has a negative retry time",
                    ..
                }
            ),
            "unexpected error: {negative:?}"
        );
        Ok(())
    }

    #[test]
    fn version_five_retires_a_legacy_plan_that_owns_no_operations() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let orphan_path = Path::new("Orphan.TXT");
        {
            let connection = version_five(&database_path)?;
            connection.execute(
                "INSERT INTO plans(id, path, status, canonical_path) \
                 VALUES (12, ?1, 'pending', ?2)",
                params![path_bytes(orphan_path), canonical("orphan.txt").as_bytes()],
            )?;
        }

        let mut journal = Journal::open(&database_path)?;

        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.blocked_plans()?.is_empty());
        assert_eq!(
            journal.connection.query_row(
                "SELECT COUNT(*) FROM plans WHERE status IN ('pending', 'blocked')",
                [],
                |row| row.get::<_, i64>(0)
            )?,
            0
        );
        let upload = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("upload"))),
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        let recorded = recorded_plan(journal.record_plan(Path::new("orphan.txt"), &upload)?)?;
        assert_eq!(recorded.status, PlanStatus::Pending);
        Ok(())
    }

    #[test]
    fn failed_version_six_migration_leaves_version_five_intact() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let baseline_path = Path::new("Legacy/Report.TXT");
        let plan_path = Path::new("Pending.TXT");
        let baseline = Baseline::Present(remote_file("legacy", "rev-legacy"));
        let operation = Operation::CreateRemote {
            content: content("first"),
        };
        {
            let connection = version_five(&database_path)?;
            connection.execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2)",
                params![
                    path_bytes(baseline_path),
                    encode(&baseline, "test", baseline_path)?
                ],
            )?;
            connection.execute(
                "INSERT INTO plans(id, path, status, canonical_path) \
                 VALUES (10, ?1, 'pending', ?2)",
                params![path_bytes(plan_path), canonical("pending.txt").as_bytes()],
            )?;
            connection.execute(
                "INSERT INTO operations(id, plan_id, ordinal, operation_json, status) \
                 VALUES (20, 10, 0, ?1, 'pending')",
                [encode(&operation, "test", plan_path)?],
            )?;
            connection.execute_batch("CREATE TABLE plans_v6(blocker INTEGER) STRICT;")?;
        }

        let opened = Journal::open(&database_path);

        let error = opened
            .err()
            .ok_or("a blocked version-six migration reported success")?;
        assert!(
            matches!(
                error,
                JournalError::Sqlite {
                    operation: "apply journal version-six migration",
                    ..
                }
            ),
            "unexpected error: {error:?}"
        );
        let connection = Connection::open(&database_path)?;
        assert_eq!(
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?,
            5
        );
        for (name, expected) in [
            ("one_pending_plan_per_path", 1),
            ("baselines_by_canonical_path", 1),
            ("remote_observations_by_canonical_path", 1),
            ("one_live_plan_per_path", 0),
            ("remote_directories", 0),
        ] {
            let found = connection.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1",
                [name],
                |row| row.get::<_, i64>(0),
            )?;
            assert_eq!(found, expected, "index {name}");
        }
        assert_eq!(
            connection.query_row(
                "SELECT COUNT(*) FROM pragma_table_info('plans') WHERE name = 'blocked_json'",
                [],
                |row| row.get::<_, i64>(0)
            )?,
            0
        );
        assert_eq!(
            connection.query_row(
                "SELECT status FROM plans WHERE id = 10 AND canonical_path = ?1",
                [canonical("pending.txt").as_bytes()],
                |row| row.get::<_, String>(0)
            )?,
            "pending"
        );
        assert_eq!(
            connection.query_row(
                "SELECT COUNT(*) FROM operations WHERE id = 20 AND ordinal = 0 \
                 AND status = 'pending'",
                [],
                |row| row.get::<_, i64>(0)
            )?,
            1
        );
        assert!(
            connection.query_row(
                "SELECT canonical_path IS NULL FROM baselines WHERE path = ?1",
                [path_bytes(baseline_path)],
                |row| row.get::<_, bool>(0)
            )?,
            "the rolled back migration kept a backfilled canonical path"
        );
        Ok(())
    }

    #[test]
    fn failed_version_two_migration_leaves_version_one_intact() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        {
            let connection = Connection::open(&database_path)?;
            connection.execute_batch(MIGRATION_V1)?;
            connection
                .execute_batch("CREATE TABLE recovery_records_v2(blocker INTEGER) STRICT;")?;
        }

        assert!(Journal::open(&database_path).is_err());
        let connection = Connection::open(&database_path)?;
        let version =
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 1);
        let original_recovery_table = connection.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('recovery_records') \
             WHERE name = 'operation_id'",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        assert_eq!(original_recovery_table, 1);
        let local_root_table = connection.query_row(
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type = 'table' AND name = 'local_root_binding'",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        assert_eq!(local_root_table, 0);
        Ok(())
    }

    #[test]
    fn journal_rejects_newer_schema_without_changing_its_version() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let connection = Connection::open(&database_path)?;
        connection.pragma_update(None, "user_version", 8)?;
        drop(connection);

        let opened = Journal::open(&database_path);
        assert!(matches!(
            opened,
            Err(JournalError::UnsupportedVersion {
                found: 8,
                supported: 7,
                ..
            })
        ));
        let connection = Connection::open(database_path)?;
        let version =
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 8);
        Ok(())
    }

    #[test]
    fn superseding_a_raced_directory_plan_never_advances_its_baseline() -> Result<(), Box<dyn Error>>
    {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("parent");
        let mut journal = Journal::open(&database_path)?;
        let agreed = noop(plan(
            &Baseline::Absent,
            &Observation::Directory,
            &Observation::Directory,
            RemoteSubtree::Empty,
        ))?;
        assert_eq!(journal.record_noop(path, &agreed)?, NoOpWrite::Recorded);
        let pending = recorded_plan(journal.record_plan(
            path,
            &OperationPlan::new(vec![Operation::DeleteLocalDirectory]),
        )?)?;

        assert_eq!(
            journal.supersede_plan(pending.id)?,
            PlanSupersede::Superseded
        );
        assert_eq!(journal.baseline(path)?, Some(Baseline::Directory));
        assert!(journal.pending_plans()?.is_empty());
        assert!(journal.conflicts()?.is_empty());
        drop(journal);

        let reopened = Journal::open(&database_path)?;
        assert_eq!(reopened.baseline(path)?, Some(Baseline::Directory));
        assert!(reopened.pending_plans()?.is_empty());
        Ok(())
    }

    #[test]
    fn journal_plan_conflict_completes_once_without_advancing_baseline()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("conflict.txt");
        let baseline_file = remote_file("old", "rev-old");
        let conflict = Conflict::DivergentEdits {
            local: LocalFile::new(content("local")),
            remote: remote_file("remote", "rev-remote"),
        };
        let plan = {
            let mut journal = Journal::open(&database_path)?;
            let baseline = noop(plan(
                &Baseline::Absent,
                &Observation::Present(LocalFile::new(content("old"))),
                &Observation::Present(baseline_file.clone()),
                RemoteSubtree::Empty,
            ))?;
            assert_eq!(journal.record_noop(path, &baseline)?, NoOpWrite::Recorded);
            let operations = OperationPlan::new(vec![
                Operation::PreserveRemote {
                    file: baseline_file.clone(),
                },
                Operation::ReplaceRemote {
                    content: content("local"),
                    expected_revision: baseline_file.revision.clone(),
                },
            ]);
            let plan = recorded_plan(journal.record_plan(path, &operations)?)?;
            let [preservation, destructive] = plan.operations.as_slice() else {
                return Err(JournalError::InvalidState {
                    operation: "prepare conflicted recovery test",
                    path: path.to_path_buf(),
                    detail: "test expected preservation followed by destruction",
                }
                .into());
            };
            assert_eq!(
                journal.complete_operation(preservation.id, None)?,
                OperationCompletion::OperationCompleted
            );
            let recovery = recorded_recovery(
                journal
                    .record_recovery_intent(destructive.id, Path::new("recovery/conflict.txt"))?,
            )?;
            assert_eq!(
                journal.complete_recovery(recovery.id)?,
                RecoveryCompletion::Completed
            );
            let completed_copy =
                read_recovery(&journal.connection, &database_path, recovery.id, true)?.ok_or_else(
                    || JournalError::InvalidState {
                        operation: "read conflicted recovery test",
                        path: path.to_path_buf(),
                        detail: "test recovery disappeared before conflict completion",
                    },
                )?;
            assert_eq!(completed_copy.retained_at, None);
            assert_eq!(
                journal.finish_plan_with_conflict(plan.id, &conflict)?,
                PlanConflictCompletion::Recorded
            );
            let retained = journal.completed_recoveries()?;
            assert_eq!(retained.len(), 1);
            assert!(retained[0].retained_at.is_some());
            assert_eq!(
                journal.finish_plan_with_conflict(plan.id, &conflict)?,
                PlanConflictCompletion::AlreadyCompleted
            );
            plan
        };

        let mut reopened = Journal::open(&database_path)?;
        assert_eq!(
            reopened.baseline(path)?,
            Some(Baseline::Present(baseline_file))
        );
        assert!(reopened.pending_plans()?.is_empty());
        assert!(read_plan(&reopened.connection, &database_path, plan.id)?.is_none());
        let conflicts = reopened.conflicts()?;
        assert_eq!(conflicts.len(), 1);
        assert_eq!(conflicts[0].path, path);
        assert_eq!(conflicts[0].conflict, conflict);

        assert_eq!(
            reopened.finish_plan_with_conflict(plan.id, &conflict)?,
            PlanConflictCompletion::NotFound
        );
        assert_eq!(reopened.conflicts()?, conflicts);
        assert_eq!(
            reopened.finish_plan_with_conflict(PlanId(i64::MAX), &conflict)?,
            PlanConflictCompletion::NotFound
        );
        Ok(())
    }

    #[test]
    fn journal_conflict_preserves_every_typed_side_across_reopen() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let conflict = Conflict::DivergentEdits {
            local: LocalFile::new(content("local")),
            remote: remote_file("remote", "rev-remote"),
        };
        let expected = {
            let mut journal = Journal::open(&database_path)?;
            journal.record_conflict(Path::new("conflict.txt"), &conflict)?
        };

        let reopened = Journal::open(database_path)?;
        assert_eq!(reopened.conflicts()?, vec![expected]);
        Ok(())
    }

    #[test]
    fn journal_retires_conflict_description_when_the_path_converges() -> Result<(), Box<dyn Error>>
    {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let path = Path::new("resolved.txt");
        let conflict = Conflict::DivergentEdits {
            local: LocalFile::new(content("local")),
            remote: remote_file("remote", "rev-remote"),
        };
        let _ = journal.record_conflict(path, &conflict)?;
        assert_eq!(journal.conflicts()?.len(), 1);

        let absent = noop(plan(
            &Baseline::Absent,
            &Observation::ConfirmedAbsent,
            &Observation::ConfirmedAbsent,
            RemoteSubtree::Empty,
        ))?;
        assert_eq!(journal.record_noop(path, &absent)?, NoOpWrite::Recorded);
        assert!(journal.conflicts()?.is_empty());
        Ok(())
    }

    #[test]
    fn journal_schema_and_payload_columns_are_not_secret_bearing() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let journal = Journal::open(journal_path(&directory))?;
        let mut statement = journal.connection.prepare(
            "SELECT name, sql FROM sqlite_master \
             WHERE type IN ('table', 'index') AND sql IS NOT NULL ORDER BY name",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let schema = rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .map(|(name, sql)| format!("{name} {sql}"))
            .collect::<Vec<_>>()
            .join("\n")
            .to_lowercase();
        for forbidden in [
            "oauth",
            "credential",
            "access_token",
            "refresh_token",
            "secret",
        ] {
            assert!(!schema.contains(forbidden), "found forbidden schema term");
        }
        Ok(())
    }
}
