//! Durable, transactional synchronization state.

use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior, params};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::model::{
    Baseline, Conflict, ContentIdentity, LocalObservation, NoOpDecision, Operation, OperationPlan,
    RemoteObservation,
};

const MIGRATION_V1: &str = include_str!("../migrations/0001.sql");
const MIGRATION_V2: &str = include_str!("../migrations/0002.sql");
const MIGRATION_V3: &str = include_str!("../migrations/0003.sql");
const MIGRATION_V4: &str = include_str!("../migrations/0004.sql");
const SCHEMA_VERSION: i64 = 4;

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
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct LocalFileFingerprint {
    pub(crate) device: u64,
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
    pub canonical_path: PathBuf,
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
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalRootBinding {
    /// Canonical absolute path selected by the user.
    pub canonical_path: PathBuf,
    /// Device identity returned by the local filesystem.
    pub device: u64,
    /// Inode identity returned by the local filesystem.
    pub inode: u64,
}

impl LocalRootBinding {
    /// Inspect one canonical local root path and capture its filesystem identity.
    pub fn inspect(canonical_path: impl AsRef<Path>) -> Result<Self, JournalError> {
        let canonical_path = canonical_path.as_ref().to_path_buf();
        let metadata = std::fs::metadata(&canonical_path).map_err(|source| JournalError::File {
            operation: "inspect local root",
            path: canonical_path.clone(),
            source,
        })?;
        if !metadata.is_dir() {
            return Err(JournalError::File {
                operation: "inspect local root",
                path: canonical_path,
                source: std::io::Error::new(
                    std::io::ErrorKind::NotADirectory,
                    "configured local root is not a directory",
                ),
            });
        }
        Ok(Self {
            canonical_path,
            device: metadata.dev(),
            inode: metadata.ino(),
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

/// Result of activating a configured local root.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LocalRootActivation {
    /// A new root generation was activated and local state was reset.
    Activated(LocalRootRecord),
    /// This exact root is current, including after one-time legacy adoption.
    Current(LocalRootRecord),
    /// Unfinished work prevents changing or initially binding the root.
    Busy,
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
    /// Durable completion state.
    pub status: RecordStatus,
}

/// Result of recording a plan intent.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PlanWrite {
    /// A new plan was committed.
    Recorded(PlanRecord),
    /// The path already has a pending plan; that committed plan is returned.
    AlreadyPending(PlanRecord),
}

/// Result of recording a planner-approved transition with no effects.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NoOpWrite {
    /// The observed baseline was committed.
    Recorded,
    /// A pending effect plan owns the path, so the baseline was not changed.
    PendingPlan(PlanId),
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
    /// A destructive operation has no durable recovery intent.
    RecoveryRequired,
    /// Recovery intent exists, but the recovery copy is not complete.
    WaitingForRecovery(RecoveryId),
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

/// A recovery copy that must exist before its destructive operation runs.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryRecord {
    /// Durable recovery identity.
    pub id: RecoveryId,
    /// Destructive operation guarded by this recovery record.
    pub operation_id: OperationId,
    /// Original synchronized path.
    pub original_path: PathBuf,
    /// Destination in the recovery area.
    pub recovery_path: PathBuf,
    /// Identity of the bytes that must be recoverable.
    pub content: ContentIdentity,
    /// Durable completion state.
    pub status: RecordStatus,
    /// Retention start in seconds since the Unix epoch, set when destructive work commits.
    pub retained_at: Option<u64>,
}

/// Result of recording recovery intent.
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
        let mut connection = Connection::open(&path).map_err(|source| JournalError::Sqlite {
            operation: "open journal",
            path: path.clone(),
            source,
        })?;
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
        connection
            .pragma_update(None, "foreign_keys", true)
            .map_err(|source| JournalError::Sqlite {
                operation: "enable foreign keys",
                path: path.clone(),
                source,
            })?;
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
        let connection = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|source| JournalError::Sqlite {
                operation: "open journal read-only",
                path: path.clone(),
                source,
            })?;
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
        read_local_root(&self.connection, &self.database_path)
    }

    /// Activate a local root without carrying another root's deletion history into it.
    pub fn activate_local_root(
        &mut self,
        binding: &LocalRootBinding,
    ) -> Result<LocalRootActivation, JournalError> {
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin local root activation", &database_path, source))?;
        let existing = read_local_root(&transaction, &database_path)?;
        if let Some(record) = &existing
            && record.binding == *binding
        {
            return Ok(LocalRootActivation::Current(record.clone()));
        }
        let legacy_adoption = transaction
            .query_row(
                "SELECT EXISTS( \
                     SELECT 1 FROM legacy_local_root_adoption WHERE singleton = 1 \
                 )",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|source| sqlite("read legacy local root adoption", &database_path, source))?;
        if existing.is_none() && legacy_adoption {
            let record = LocalRootRecord {
                binding: binding.clone(),
                generation: 1,
            };
            write_local_root(&transaction, &record, &database_path)?;
            transaction
                .execute(
                    "DELETE FROM legacy_local_root_adoption WHERE singleton = 1",
                    [],
                )
                .map_err(|source| {
                    sqlite("finish legacy local root adoption", &database_path, source)
                })?;
            transaction.commit().map_err(|source| {
                sqlite("commit legacy local root adoption", &database_path, source)
            })?;
            return Ok(LocalRootActivation::Current(record));
        }
        let pending = transaction
            .query_row(
                "SELECT EXISTS( \
                     SELECT 1 FROM plans WHERE status = 'pending' \
                     UNION ALL \
                     SELECT 1 FROM recovery_records WHERE status = 'pending' \
                 )",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|source| sqlite("check local root activation work", &database_path, source))?;
        if pending {
            return Ok(LocalRootActivation::Busy);
        }
        let generation = match existing {
            Some(record) => {
                record
                    .generation
                    .checked_add(1)
                    .ok_or_else(|| JournalError::InvalidState {
                        operation: "advance local root generation",
                        path: database_path.clone(),
                        detail: "local root generation exhausted",
                    })?
            }
            None => 1,
        };
        transaction
            .execute("DELETE FROM baselines", [])
            .map_err(|source| sqlite("clear prior root baselines", &database_path, source))?;
        transaction
            .execute("DELETE FROM local_observations", [])
            .map_err(|source| sqlite("clear prior root observations", &database_path, source))?;
        transaction
            .execute("DELETE FROM local_hash_cache", [])
            .map_err(|source| sqlite("clear prior root hash cache", &database_path, source))?;
        transaction
            .execute("DELETE FROM conflicts", [])
            .map_err(|source| sqlite("clear prior root conflicts", &database_path, source))?;
        let record = LocalRootRecord {
            binding: binding.clone(),
            generation,
        };
        write_local_root(&transaction, &record, &database_path)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit local root activation", &database_path, source))?;
        Ok(LocalRootActivation::Activated(record))
    }

    /// Publish a complete local inventory as one replacement transaction.
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
        let encoded_observations = observations
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
        let encoded_hashes = hashes
            .iter()
            .map(|record| {
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
                encode(&value, "serialize local hash cache", &record.path)
                    .map(|json| (path_bytes(&record.path), json))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin local scan publication", &database_path, source))?;
        let Some(active) = read_local_root(&transaction, &database_path)? else {
            return Ok(false);
        };
        if active.binding != *binding {
            return Ok(false);
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
        for (path, json) in encoded_observations {
            transaction
                .execute(
                    "INSERT INTO local_observations(path, observation_json) VALUES (?1, ?2)",
                    params![path, json],
                )
                .map_err(|source| sqlite("publish local observation", &database_path, source))?;
        }
        for (path, json) in encoded_hashes {
            transaction
                .execute(
                    "INSERT INTO local_hash_cache(\
                         root_generation, path, hash_json\
                     ) VALUES (?1, ?2, ?3)",
                    params![generation, path, json],
                )
                .map_err(|source| sqlite("publish local hash", &database_path, source))?;
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
        let encoded = observations
            .iter()
            .map(|record| {
                encode(
                    &record.observation,
                    "serialize remote observation",
                    &record.path,
                )
                .map(|json| {
                    (
                        path_bytes(&record.path),
                        path_bytes(&record.canonical_path),
                        json,
                    )
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
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
        for (path, canonical_path, json) in encoded {
            transaction
                .execute(
                    "INSERT INTO remote_observations(\
                         path, observation_json, canonical_path\
                     ) VALUES (?1, ?2, ?3)",
                    params![path, json, canonical_path],
                )
                .map_err(|source| sqlite("publish remote observation", &database_path, source))?;
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
        let canonical_path = dropbox_canonical_path(path);
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
                    path_bytes(&canonical_path)
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
            baseline @ Baseline::Present(_) => Ok(Some(baseline)),
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
        let canonical_path = dropbox_canonical_path(path);
        let pending = transaction
            .query_row(
                "SELECT id FROM plans WHERE canonical_path = ?1 AND status = 'pending'",
                [path_bytes(&canonical_path)],
                |row| row.get::<_, i64>(0),
            )
            .optional()
            .map_err(|source| sqlite("find pending plan for no-op", path, source))?;
        if let Some(id) = pending {
            transaction
                .commit()
                .map_err(|source| sqlite("commit pending plan read", &database_path, source))?;
            return Ok(NoOpWrite::PendingPlan(PlanId(id)));
        }
        write_baseline(&transaction, path, noop.baseline())?;
        transaction
            .execute(
                "DELETE FROM conflicts WHERE canonical_path = ?1",
                [path_bytes(&canonical_path)],
            )
            .map_err(|source| sqlite("retire resolved conflicts", path, source))?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit no-op baseline", &database_path, source))?;
        Ok(NoOpWrite::Recorded)
    }

    /// Commit an ordered plan before returning it to an effect executor.
    pub fn record_plan(
        &mut self,
        path: &Path,
        plan: &OperationPlan,
    ) -> Result<PlanWrite, JournalError> {
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
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin plan intent", &database_path, source))?;
        let canonical_path = dropbox_canonical_path(path);
        let existing = transaction
            .query_row(
                "SELECT id FROM plans WHERE canonical_path = ?1 AND status = 'pending'",
                [path_bytes(&canonical_path)],
                |row| row.get::<_, i64>(0),
            )
            .optional()
            .map_err(|source| sqlite("find pending plan", path, source))?;
        if let Some(id) = existing {
            let plan = read_plan(&transaction, &database_path, PlanId(id))?.ok_or_else(|| {
                JournalError::InvalidState {
                    operation: "read existing pending plan",
                    path: path.to_path_buf(),
                    detail: "pending plan disappeared inside its transaction",
                }
            })?;
            transaction
                .commit()
                .map_err(|source| sqlite("commit pending plan read", &database_path, source))?;
            return Ok(PlanWrite::AlreadyPending(plan));
        }

        transaction
            .execute(
                "INSERT INTO plans(path, status, canonical_path) VALUES (?1, 'pending', ?2)",
                params![path_bytes(path), path_bytes(&canonical_path)],
            )
            .map_err(|source| sqlite("record plan intent", path, source))?;
        let plan_id = PlanId(transaction.last_insert_rowid());
        for (ordinal, operation_json) in encoded_operations {
            transaction
                .execute(
                    "INSERT INTO operations(plan_id, ordinal, operation_json, status) \
                     VALUES (?1, ?2, ?3, 'pending')",
                    params![plan_id.0, ordinal, operation_json],
                )
                .map_err(|source| sqlite("record operation intent", path, source))?;
        }
        let plan = read_plan(&transaction, &database_path, plan_id)?.ok_or_else(|| {
            JournalError::InvalidState {
                operation: "read recorded plan",
                path: path.to_path_buf(),
                detail: "new plan disappeared inside its transaction",
            }
        })?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan intent", &database_path, source))?;
        Ok(PlanWrite::Recorded(plan))
    }

    /// Load every unfinished plan after startup or interruption.
    pub fn pending_plans(&self) -> Result<Vec<PlanRecord>, JournalError> {
        let mut statement = self
            .connection
            .prepare("SELECT id FROM plans WHERE status = 'pending' ORDER BY id")
            .map_err(|source| sqlite("prepare pending plan query", &self.database_path, source))?;
        let rows = statement
            .query_map([], |row| row.get::<_, i64>(0))
            .map_err(|source| sqlite("query pending plans", &self.database_path, source))?;
        let ids = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|source| sqlite("read pending plan identity", &self.database_path, source))?;
        drop(statement);

        ids.into_iter()
            .map(|id| {
                read_plan(&self.connection, &self.database_path, PlanId(id))?.ok_or_else(|| {
                    JournalError::InvalidState {
                        operation: "read pending plan",
                        path: self.database_path.clone(),
                        detail: "pending plan disappeared while reading the journal",
                    }
                })
            })
            .collect()
    }

    /// Return upload payloads still referenced by pending remote mutations.
    pub fn pending_upload_content(&self) -> Result<Vec<ContentIdentity>, JournalError> {
        let mut statement = self
            .connection
            .prepare(
                "SELECT plans.path, operations.operation_json \
                 FROM operations JOIN plans ON plans.id = operations.plan_id \
                 WHERE plans.status = 'pending' AND operations.status = 'pending' \
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
                        Operation::InstallLocal { .. }
                        | Operation::PreserveLocal { .. }
                        | Operation::ReplaceLocal { .. }
                        | Operation::DeleteLocal { .. }
                        | Operation::PreserveRemote { .. }
                        | Operation::DeleteRemote { .. },
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
        let row = transaction
            .query_row(
                "SELECT operations.plan_id, operations.ordinal, operations.status, plans.status, \
                        plans.path, operations.operation_json \
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
                    ))
                },
            )
            .optional()
            .map_err(|source| sqlite("find operation", &database_path, source))?;
        let Some((plan_id, ordinal, operation_status, plan_status, raw_path, operation_json)) = row
        else {
            return Ok(OperationCompletion::NotFound);
        };
        let path = bytes_path(raw_path);
        let operation_status = decode_status(&operation_status, "read operation status", &path)?;
        let plan_status = decode_status(&plan_status, "read plan status", &path)?;
        if operation_status == RecordStatus::Completed || plan_status == RecordStatus::Completed {
            return Ok(OperationCompletion::AlreadyCompleted);
        }
        let operation: Operation = decode(&operation_json, "deserialize operation", &path)?;

        let earlier = transaction
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

        let has_later = transaction
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

        if is_destructive(&operation) {
            let recovery = transaction
                .query_row(
                    "SELECT id, status FROM recovery_records WHERE operation_id = ?1",
                    [operation_id.0],
                    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
                )
                .optional()
                .map_err(|source| sqlite("find required recovery", &path, source))?;
            let Some((recovery_id, status)) = recovery else {
                return Ok(OperationCompletion::RecoveryRequired);
            };
            if decode_status(&status, "read required recovery status", &path)?
                == RecordStatus::Pending
            {
                return Ok(OperationCompletion::WaitingForRecovery(RecoveryId(
                    recovery_id,
                )));
            }
        }

        transaction
            .execute(
                "UPDATE operations SET status = 'completed' WHERE id = ?1",
                [operation_id.0],
            )
            .map_err(|source| sqlite("complete operation", &path, source))?;
        let Some(baseline) = final_baseline else {
            transaction
                .commit()
                .map_err(|source| sqlite("commit operation completion", &database_path, source))?;
            return Ok(OperationCompletion::OperationCompleted);
        };

        write_baseline(&transaction, &path, baseline)?;
        transaction
            .execute(
                "DELETE FROM conflicts WHERE canonical_path = ?1",
                [path_bytes(&dropbox_canonical_path(&path))],
            )
            .map_err(|source| sqlite("retire resolved conflicts", &path, source))?;
        transaction
            .execute(
                "UPDATE plans SET status = 'completed' WHERE id = ?1",
                [plan_id],
            )
            .map_err(|source| sqlite("complete plan", &path, source))?;
        start_recovery_retention(&transaction, plan_id, &path)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan and baseline", &database_path, source))?;
        Ok(OperationCompletion::PlanCompleted)
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
        let plan = transaction
            .query_row(
                "SELECT path, status FROM plans WHERE id = ?1",
                [plan_id.0],
                |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()
            .map_err(|source| sqlite("find plan for conflict", &database_path, source))?;
        let Some((raw_path, status)) = plan else {
            return Ok(PlanConflictCompletion::NotFound);
        };
        let path = bytes_path(raw_path);
        if decode_status(&status, "read plan status for conflict", &path)?
            == RecordStatus::Completed
        {
            return Ok(PlanConflictCompletion::AlreadyCompleted);
        }

        let json = encode(conflict, "serialize plan conflict", &path)?;
        transaction
            .execute(
                "INSERT INTO conflicts(path, conflict_json, canonical_path) VALUES (?1, ?2, ?3)",
                params![
                    path_bytes(&path),
                    json,
                    path_bytes(&dropbox_canonical_path(&path))
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
            .execute(
                "UPDATE plans SET status = 'completed' WHERE id = ?1",
                [plan_id.0],
            )
            .map_err(|source| sqlite("complete conflicted plan", &path, source))?;
        start_recovery_retention(&transaction, plan_id.0, &path)?;
        transaction
            .commit()
            .map_err(|source| sqlite("commit plan conflict", &database_path, source))?;
        Ok(PlanConflictCompletion::Recorded)
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
                    path_bytes(&dropbox_canonical_path(path))
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

    /// Commit recovery intent before the associated destructive effect runs.
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

    /// Mark a recovery record complete without altering its operation or baseline.
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

fn configure_writable(connection: &Connection, database_path: &Path) -> Result<(), JournalError> {
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
    select: &'static str,
    update: &'static str,
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
        let canonical = dropbox_canonical_path(&bytes_path(raw_path));
        connection
            .execute(update, params![path_bytes(&canonical), row_id])
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

pub(crate) fn dropbox_canonical_path(path: &Path) -> PathBuf {
    path.iter()
        .map(|component| match component.to_str() {
            Some(text) => OsString::from(text.to_lowercase()),
            None => OsString::from_vec(
                component
                    .as_bytes()
                    .iter()
                    .map(u8::to_ascii_lowercase)
                    .collect(),
            ),
        })
        .collect()
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

fn write_baseline(
    connection: &Connection,
    path: &Path,
    baseline: &Baseline,
) -> Result<(), JournalError> {
    let canonical_path = dropbox_canonical_path(path);
    match baseline {
        Baseline::Absent => connection
            .execute(
                "DELETE FROM baselines WHERE canonical_path = ?1",
                [path_bytes(&canonical_path)],
            )
            .map(|_| ())
            .map_err(|source| sqlite("remove absent baseline", path, source)),
        Baseline::Present(_) => {
            let json = encode(baseline, "serialize present baseline", path)?;
            connection
                .execute(
                    "INSERT INTO baselines(path, baseline_json, canonical_path) \
                     VALUES (?1, ?2, ?3) \
                     ON CONFLICT(canonical_path) DO UPDATE SET \
                         path = excluded.path, \
                         baseline_json = excluded.baseline_json",
                    params![path_bytes(path), json, path_bytes(&canonical_path)],
                )
                .map(|_| ())
                .map_err(|source| sqlite("record present baseline", path, source))
        }
    }
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
    let device = record.binding.device.to_be_bytes();
    let inode = record.binding.inode.to_be_bytes();
    connection
        .execute(
            "INSERT INTO local_root_binding( \
                 singleton, canonical_path, device, inode, generation \
             ) VALUES (1, ?1, ?2, ?3, ?4) \
             ON CONFLICT(singleton) DO UPDATE SET \
                 canonical_path = excluded.canonical_path, \
                 device = excluded.device, \
                 inode = excluded.inode, \
                 generation = excluded.generation",
            params![
                path_bytes(&record.binding.canonical_path),
                device.as_slice(),
                inode.as_slice(),
                generation
            ],
        )
        .map(|_| ())
        .map_err(|source| sqlite("write local root binding", database_path, source))
}

fn read_local_root(
    connection: &Connection,
    database_path: &Path,
) -> Result<Option<LocalRootRecord>, JournalError> {
    connection
        .query_row(
            "SELECT canonical_path, device, inode, generation \
             FROM local_root_binding WHERE singleton = 1",
            [],
            |row| {
                Ok((
                    row.get::<_, Vec<u8>>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        )
        .optional()
        .map_err(|source| sqlite("read local root binding", database_path, source))?
        .map(|(raw_path, raw_device, raw_inode, generation)| {
            let canonical_path = bytes_path(raw_path);
            Ok(LocalRootRecord {
                binding: LocalRootBinding {
                    device: decode_u64(&raw_device, "read local root device", &canonical_path)?,
                    inode: decode_u64(&raw_inode, "read local root inode", &canonical_path)?,
                    canonical_path,
                },
                generation: u64::try_from(generation).map_err(|_| JournalError::InvalidState {
                    operation: "read local root generation",
                    path: database_path.to_path_buf(),
                    detail: "local root generation is outside the supported range",
                })?,
            })
        })
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
    let raw = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| sqlite("read local inventory", database_path, source))?;
    raw.into_iter()
        .map(|(raw_path, json)| {
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
    let raw = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| sqlite("read local hash cache", database_path, source))?;
    raw.into_iter()
        .map(|(raw_path, json)| {
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
        .collect()
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
    let raw = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| sqlite("read remote inventory", database_path, source))?;
    raw.into_iter()
        .map(|(raw_canonical_path, raw_path, json)| {
            let canonical_path = bytes_path(raw_canonical_path);
            let path = bytes_path(raw_path);
            let observation = decode(&json, "deserialize remote observation", &path)?;
            Ok(RemoteObservationRecord {
                canonical_path,
                path,
                observation,
            })
        })
        .collect()
}

fn read_plan(
    connection: &Connection,
    database_path: &Path,
    plan_id: PlanId,
) -> Result<Option<PlanRecord>, JournalError> {
    let header = connection
        .query_row(
            "SELECT path, status FROM plans WHERE id = ?1",
            [plan_id.0],
            |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|source| sqlite("read plan", database_path, source))?;
    let Some((raw_path, status)) = header else {
        return Ok(None);
    };
    let path = bytes_path(raw_path);
    let status = decode_status(&status, "read plan status", &path)?;

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

fn is_destructive(operation: &Operation) -> bool {
    matches!(
        operation,
        Operation::ReplaceLocal { .. }
            | Operation::DeleteLocal { .. }
            | Operation::ReplaceRemote { .. }
            | Operation::DeleteRemote { .. }
    )
}

fn missing_preservation(path: &Path) -> JournalError {
    JournalError::InvalidState {
        operation: "derive recovery content",
        path: path.to_path_buf(),
        detail: "destructive operation lacks immediately preceding matching preservation",
    }
}

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
    use crate::model::{Decision, DropboxRevision, LocalFile, Observation, RemoteFile};
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

    fn local_root(path: impl Into<PathBuf>, device: u64, inode: u64) -> LocalRootBinding {
        LocalRootBinding {
            canonical_path: path.into(),
            device,
            inode,
        }
    }

    fn local_hash(path: impl Into<PathBuf>, marker: u64) -> LocalHashRecord {
        LocalHashRecord {
            path: path.into(),
            fingerprint: LocalFileFingerprint {
                device: marker,
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
            PlanWrite::AlreadyPending(_) => Err(JournalError::InvalidState {
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

    fn operations(decision: Decision) -> Result<OperationPlan, JournalError> {
        match decision {
            Decision::Operations(plan) => Ok(plan),
            Decision::NoOp(_) | Decision::Blocked(_) | Decision::Conflict(_) => {
                Err(JournalError::InvalidState {
                    operation: "extract test operation plan",
                    path: PathBuf::from("test"),
                    detail: "test expected planner operations",
                })
            }
        }
    }

    fn noop(decision: Decision) -> Result<NoOpDecision, JournalError> {
        match decision {
            Decision::NoOp(noop) => Ok(noop),
            Decision::Operations(_) | Decision::Blocked(_) | Decision::Conflict(_) => {
                Err(JournalError::InvalidState {
                    operation: "extract test no-op",
                    path: PathBuf::from("test"),
                    detail: "test expected a planner no-op",
                })
            }
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

        assert_eq!(journal_mode, "delete");
        assert_eq!(synchronous, 2);
        Ok(())
    }

    #[test]
    fn local_root_inspection_uses_directory_filesystem_identity() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let binding = LocalRootBinding::inspect(directory.path())?;
        let metadata = fs::metadata(directory.path())?;

        assert_eq!(binding.canonical_path, directory.path());
        assert_eq!(binding.device, metadata.dev());
        assert_eq!(binding.inode, metadata.ino());

        let file = directory.path().join("not-a-root");
        fs::write(&file, b"file")?;
        let rejected = LocalRootBinding::inspect(file);
        assert!(matches!(rejected, Err(JournalError::File { .. })));
        Ok(())
    }

    #[test]
    fn local_root_generation_resets_only_root_local_state() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let first = local_root("/sync/first", 1, 2);
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
        ))?;
        journal.record_noop(path, &baseline)?;
        let local_observation = LocalObservationRecord {
            path: path.to_path_buf(),
            observation: Observation::Present(LocalFile::new(content("same"))),
        };
        journal.publish_local_inventory(std::slice::from_ref(&local_observation))?;
        let remote_observation = RemoteObservationRecord {
            canonical_path: dropbox_canonical_path(path),
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

        let replacement = local_root("/sync/second", 3, 4);
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
    fn local_root_activation_is_busy_without_changing_state() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let current = local_root("/sync/current", 1, 2);
        assert!(matches!(
            journal.activate_local_root(&current)?,
            LocalRootActivation::Activated(_)
        ));
        let operation_plan = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("pending"))),
            &Observation::ConfirmedAbsent,
        ))?;
        let _ = journal.record_plan(Path::new("pending.txt"), &operation_plan)?;

        let replacement = local_root("/sync/replacement", 3, 4);
        assert_eq!(
            journal.activate_local_root(&replacement)?,
            LocalRootActivation::Busy
        );
        assert_eq!(
            journal.local_root_binding()?,
            Some(LocalRootRecord {
                binding: current.clone(),
                generation: 1,
            })
        );
        assert!(matches!(
            journal.activate_local_root(&current)?,
            LocalRootActivation::Current(_)
        ));

        let unbound_path = directory.path().join("unbound.sqlite3");
        let mut unbound = Journal::open(unbound_path)?;
        let _ = unbound.record_plan(Path::new("pending.txt"), &operation_plan)?;
        assert_eq!(
            unbound.activate_local_root(&replacement)?,
            LocalRootActivation::Busy
        );
        assert_eq!(unbound.local_root_binding()?, None);
        Ok(())
    }

    #[test]
    fn new_empty_root_downloads_remote_content_instead_of_deleting_it() -> Result<(), Box<dyn Error>>
    {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let _ = journal.activate_local_root(&local_root("/sync/old", 1, 2))?;
        let path = Path::new("remote-only.txt");
        let remote = remote_file("remote", "rev-remote");
        let agreed = noop(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("remote"))),
            &Observation::Present(remote.clone()),
        ))?;
        journal.record_noop(path, &agreed)?;

        let _ = journal.activate_local_root(&local_root("/sync/new-empty", 3, 4))?;
        let baseline = match journal.baseline(path)? {
            Some(baseline) => baseline,
            None => Baseline::Absent,
        };
        let decision = operations(plan(
            &baseline,
            &Observation::ConfirmedAbsent,
            &Observation::Present(remote.clone()),
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
        ))?;
        assert_eq!(
            journal.record_noop(path, &noop_decision)?,
            NoOpWrite::Recorded
        );
        assert_eq!(journal.baseline(path)?, Some(Baseline::Present(observed)));

        let pending = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("new"))),
            &Observation::ConfirmedAbsent,
        ))?;
        let pending = recorded_plan(journal.record_plan(path, &pending)?)?;
        let absent = noop(plan(
            &Baseline::Absent,
            &Observation::ConfirmedAbsent,
            &Observation::ConfirmedAbsent,
        ))?;
        assert_eq!(
            journal.record_noop(path, &absent)?,
            NoOpWrite::PendingPlan(pending.id)
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
        ))?;
        journal.record_noop(path, &present)?;
        assert_eq!(journal.baseline_paths()?, vec![path.to_path_buf()]);

        let absent = noop(plan(
            &Baseline::Present(remote_file("old", "rev-old")),
            &Observation::ConfirmedAbsent,
            &Observation::ConfirmedAbsent,
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
    fn journal_remote_inventory_and_cursor_publish_atomically() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let old = RemoteObservationRecord {
            canonical_path: PathBuf::from("old.txt"),
            path: PathBuf::from("old.txt"),
            observation: Observation::Present(remote_file("old", "rev-old")),
        };
        journal.publish_remote_inventory("cursor-old", std::slice::from_ref(&old))?;

        let duplicate_path = PathBuf::from("duplicate.txt");
        let invalid_replacement = [
            RemoteObservationRecord {
                canonical_path: duplicate_path.clone(),
                path: duplicate_path.clone(),
                observation: Observation::ConfirmedAbsent,
            },
            RemoteObservationRecord {
                canonical_path: duplicate_path.clone(),
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
    fn journal_local_inventory_is_a_complete_atomic_replacement() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let old = LocalObservationRecord {
            path: PathBuf::from("old.txt"),
            observation: Observation::Present(LocalFile::new(content("old"))),
        };
        journal.publish_local_inventory(std::slice::from_ref(&old))?;

        let duplicate_path = PathBuf::from("duplicate.txt");
        let invalid_replacement = [
            LocalObservationRecord {
                path: duplicate_path.clone(),
                observation: Observation::ConfirmedAbsent,
            },
            LocalObservationRecord {
                path: duplicate_path,
                observation: Observation::Present(LocalFile::new(content("new"))),
            },
        ];
        let failed = journal.publish_local_inventory(&invalid_replacement);
        assert!(failed.is_err());
        assert_eq!(journal.local_inventory()?, vec![old]);
        Ok(())
    }

    #[test]
    fn journal_local_scan_replaces_inventory_and_hashes_atomically() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let binding = local_root("/sync", 1, 2);
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
        ))?;
        let create = recorded_plan(journal.record_plan(create_path, &create)?)?;

        let replace_path = Path::new("replace.txt");
        let old = remote_file("old", "rev-old");
        let replace = operations(plan(
            &Baseline::Present(old.clone()),
            &Observation::Present(LocalFile::new(content("replace"))),
            &Observation::Present(old),
        ))?;
        let replace = recorded_plan(journal.record_plan(replace_path, &replace)?)?;

        let download = operations(plan(
            &Baseline::Absent,
            &Observation::ConfirmedAbsent,
            &Observation::Present(remote_file("download", "rev-download")),
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
        assert_eq!(replace.operations.len(), 2);
        Ok(())
    }

    #[test]
    fn journal_destructive_completion_waits_for_derived_recovery_across_reopen()
    -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let path = Path::new("replace.txt");
        let old = content("old");
        let target = Baseline::Present(remote_file("new", "rev-server"));
        let operation_plan = operations(plan(
            &Baseline::Present(remote_file("old", "rev-old")),
            &Observation::Present(LocalFile::new(content("new"))),
            &Observation::Present(remote_file("old", "rev-current")),
        ))?;
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
            assert_eq!(
                journal.complete_operation(plan.operations[1].id, Some(&target))?,
                OperationCompletion::RecoveryRequired
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
            OperationCompletion::WaitingForRecovery(recovery.id)
        );
        assert_eq!(
            reopened.complete_recovery(recovery.id)?,
            RecoveryCompletion::Completed
        );
        let completed_copy =
            read_recovery(&reopened.connection, &database_path, recovery.id, true)?.ok_or_else(
                || JournalError::InvalidState {
                    operation: "read completed test recovery copy",
                    path: path.to_path_buf(),
                    detail: "completed test recovery disappeared",
                },
            )?;
        assert_eq!(completed_copy.status, RecordStatus::Completed);
        assert_eq!(completed_copy.retained_at, None);
        assert!(reopened.completed_recoveries()?.is_empty());
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
        assert_eq!(journal.schema_version, 4);
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

        let configured = local_root("/sync/configured", 7, 8);
        let configured_record = LocalRootRecord {
            binding: configured.clone(),
            generation: 1,
        };
        assert_eq!(
            journal.activate_local_root(&configured)?,
            LocalRootActivation::Current(configured_record.clone())
        );
        assert_eq!(
            journal.local_root_binding()?,
            Some(configured_record.clone())
        );
        assert_eq!(journal.baseline(kept_path)?, Some(kept_baseline));
        assert_eq!(journal.pending_plans()?.len(), 1);
        assert_eq!(journal.pending_recoveries()?.len(), 1);

        let changed = local_root("/sync/changed", 9, 10);
        assert_eq!(
            journal.activate_local_root(&changed)?,
            LocalRootActivation::Busy
        );
        assert_eq!(journal.local_root_binding()?, Some(configured_record));
        let version = journal
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 4);
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
            PlanWrite::AlreadyPending(plan) if plan.path == Path::new("Pending.TXT")
        ));
        let version = journal
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 4);
        Ok(())
    }

    #[test]
    fn version_three_case_collisions_migrate_without_losing_pending_work()
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
        assert_eq!(journal.pending_plans()?.len(), 2);
        let new_plan = OperationPlan::new(vec![operation]);
        assert!(matches!(
            journal.record_plan(Path::new("FOO.txt"), &new_plan)?,
            PlanWrite::AlreadyPending(_)
        ));
        assert_eq!(journal.pending_plans()?.len(), 2);
        drop(journal);

        let reopened = Journal::open(&database_path)?;
        assert_eq!(reopened.pending_plans()?.len(), 2);
        assert!(reopened.baseline_paths()?.is_empty());
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
        connection.pragma_update(None, "user_version", 5)?;
        drop(connection);

        let opened = Journal::open(&database_path);
        assert!(matches!(
            opened,
            Err(JournalError::UnsupportedVersion {
                found: 5,
                supported: 4,
                ..
            })
        ));
        let connection = Connection::open(database_path)?;
        let version =
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 5);
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
            ))?;
            assert_eq!(journal.record_noop(path, &baseline)?, NoOpWrite::Recorded);
            let operations = operations(plan(
                &Baseline::Present(baseline_file.clone()),
                &Observation::Present(LocalFile::new(content("local"))),
                &Observation::Present(baseline_file.clone()),
            ))?;
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
