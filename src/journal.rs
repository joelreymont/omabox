//! Durable, transactional synchronization state.

use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior, params};
use serde::Serialize;
use serde::de::DeserializeOwned;
use thiserror::Error;

use crate::model::{
    Baseline, Conflict, ContentIdentity, LocalObservation, NoOpDecision, Operation, OperationPlan,
    RemoteObservation,
};

const MIGRATION: &str = include_str!("../migrations/0001.sql");

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

/// One path from a complete Dropbox inventory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RemoteObservationRecord {
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

/// Durable identity of a plan.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlanId(i64);

/// Durable identity of an operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct OperationId(i64);

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

/// SQLite-backed durable synchronization journal.
pub struct Journal {
    connection: Connection,
    database_path: PathBuf,
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
        if version != 0 && version != 1 {
            return Err(JournalError::UnsupportedVersion {
                path,
                found: version,
                supported: 1,
            });
        }
        connection
            .pragma_update(None, "foreign_keys", true)
            .map_err(|source| JournalError::Sqlite {
                operation: "enable foreign keys",
                path: path.clone(),
                source,
            })?;
        if version == 0 {
            let transaction = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|source| JournalError::Sqlite {
                    operation: "begin journal migration",
                    path: path.clone(),
                    source,
                })?;
            transaction
                .execute_batch(MIGRATION)
                .map_err(|source| JournalError::Sqlite {
                    operation: "apply journal migration",
                    path: path.clone(),
                    source,
                })?;
            transaction
                .commit()
                .map_err(|source| JournalError::Sqlite {
                    operation: "commit journal migration",
                    path: path.clone(),
                    source,
                })?;
        }

        Ok(Self {
            connection,
            database_path: path,
        })
    }

    /// Open an existing version-one journal without creating or changing it.
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
        if version != 1 {
            return Err(JournalError::UnsupportedVersion {
                path,
                found: version,
                supported: 1,
            });
        }
        Ok(Self {
            connection,
            database_path: path,
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
                .map(|json| (path_bytes(&record.path), json))
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
        for (path, json) in encoded {
            transaction
                .execute(
                    "INSERT INTO remote_observations(path, observation_json) VALUES (?1, ?2)",
                    params![path, json],
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
        let observations = read_remote_observations(&transaction, &database_path)?;
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
        let json = self
            .connection
            .query_row(
                "SELECT baseline_json FROM baselines WHERE path = ?1",
                [path_bytes(path)],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|source| sqlite("read baseline", path, source))?;
        json.map(|json| decode(&json, "deserialize baseline", path))
            .transpose()
    }

    /// Load every path with a durable common baseline.
    pub fn baseline_paths(&self) -> Result<Vec<PathBuf>, JournalError> {
        let mut statement = self
            .connection
            .prepare("SELECT path FROM baselines ORDER BY path")
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
        let baseline_json = encode(noop.baseline(), "serialize no-op baseline", path)?;
        let database_path = self.database_path.clone();
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|source| sqlite("begin no-op baseline", &database_path, source))?;
        let pending = transaction
            .query_row(
                "SELECT id FROM plans WHERE path = ?1 AND status = 'pending'",
                [path_bytes(path)],
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
        transaction
            .execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2) \
                 ON CONFLICT(path) DO UPDATE SET baseline_json = excluded.baseline_json",
                params![path_bytes(path), baseline_json],
            )
            .map_err(|source| sqlite("record no-op baseline", path, source))?;
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
        let existing = transaction
            .query_row(
                "SELECT id FROM plans WHERE path = ?1 AND status = 'pending'",
                [path_bytes(path)],
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
                "INSERT INTO plans(path, status) VALUES (?1, 'pending')",
                [path_bytes(path)],
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
        let baseline_json = if has_later {
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
            Some(encode(baseline, "serialize resulting baseline", &path)?)
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
        let Some(baseline_json) = baseline_json else {
            transaction
                .commit()
                .map_err(|source| sqlite("commit operation completion", &database_path, source))?;
            return Ok(OperationCompletion::OperationCompleted);
        };

        transaction
            .execute(
                "INSERT INTO baselines(path, baseline_json) VALUES (?1, ?2) \
                 ON CONFLICT(path) DO UPDATE SET baseline_json = excluded.baseline_json",
                params![path_bytes(&path), baseline_json],
            )
            .map_err(|source| sqlite("advance baseline", &path, source))?;
        transaction
            .execute(
                "UPDATE plans SET status = 'completed' WHERE id = ?1",
                [plan_id],
            )
            .map_err(|source| sqlite("complete plan", &path, source))?;
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
                "INSERT INTO conflicts(path, conflict_json) VALUES (?1, ?2)",
                params![path_bytes(&path), json],
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
                "INSERT INTO conflicts(path, conflict_json) VALUES (?1, ?2)",
                params![path_bytes(path), json],
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
            read_recovery(&transaction, &database_path, recovery_id)?.ok_or_else(|| {
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
        let mut statement = self
            .connection
            .prepare("SELECT id FROM recovery_records WHERE status = 'pending' ORDER BY id")
            .map_err(|source| sqlite("prepare recovery query", &self.database_path, source))?;
        let rows = statement
            .query_map([], |row| row.get::<_, i64>(0))
            .map_err(|source| sqlite("query pending recoveries", &self.database_path, source))?;
        let ids = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|source| sqlite("read recovery identities", &self.database_path, source))?;
        drop(statement);

        ids.into_iter()
            .map(|id| {
                read_recovery(&self.connection, &self.database_path, RecoveryId(id))?.ok_or_else(
                    || JournalError::InvalidState {
                        operation: "read pending recovery",
                        path: self.database_path.clone(),
                        detail: "pending recovery disappeared while reading the journal",
                    },
                )
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

fn read_remote_observations(
    connection: &Connection,
    database_path: &Path,
) -> Result<Vec<RemoteObservationRecord>, JournalError> {
    let mut statement = connection
        .prepare("SELECT path, observation_json FROM remote_observations ORDER BY path")
        .map_err(|source| sqlite("prepare remote inventory query", database_path, source))?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|source| sqlite("query remote inventory", database_path, source))?;
    let raw = rows
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| sqlite("read remote inventory", database_path, source))?;
    raw.into_iter()
        .map(|(raw_path, json)| {
            let path = bytes_path(raw_path);
            let observation = decode(&json, "deserialize remote observation", &path)?;
            Ok(RemoteObservationRecord { path, observation })
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
    id.map(|id| read_recovery(connection, database_path, RecoveryId(id)))
        .transpose()
        .map(Option::flatten)
}

fn read_recovery(
    connection: &Connection,
    database_path: &Path,
    recovery_id: RecoveryId,
) -> Result<Option<RecoveryRecord>, JournalError> {
    let row = connection
        .query_row(
            "SELECT operation_id, original_path, recovery_path, content_json, status \
             FROM recovery_records WHERE id = ?1",
            [recovery_id.0],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Vec<u8>>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            },
        )
        .optional()
        .map_err(|source| sqlite("read recovery", database_path, source))?;
    let Some((operation_id, raw_original, raw_recovery, content_json, status)) = row else {
        return Ok(None);
    };
    let original_path = bytes_path(raw_original);
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

        let mut reopened = Journal::open(database_path)?;
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
    fn journal_remote_inventory_and_cursor_publish_atomically() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let old = RemoteObservationRecord {
            path: PathBuf::from("old.txt"),
            observation: Observation::Present(remote_file("old", "rev-old")),
        };
        journal.publish_remote_inventory("cursor-old", std::slice::from_ref(&old))?;

        let duplicate_path = PathBuf::from("duplicate.txt");
        let invalid_replacement = [
            RemoteObservationRecord {
                path: duplicate_path.clone(),
                observation: Observation::ConfirmedAbsent,
            },
            RemoteObservationRecord {
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
    fn journal_final_operation_records_only_its_actual_result() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let mut journal = Journal::open(journal_path(&directory))?;
        let path = Path::new("created.txt");
        let operation_plan = operations(plan(
            &Baseline::Absent,
            &Observation::Present(LocalFile::new(content("created"))),
            &Observation::ConfirmedAbsent,
        ))?;
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
        assert!(journal.pending_plans()?.is_empty());
        assert_eq!(
            journal.complete_operation(plan.operations[0].id, None)?,
            OperationCompletion::AlreadyCompleted
        );
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

        let mut reopened = Journal::open(database_path)?;
        assert_eq!(recovery.content, old);
        assert_eq!(reopened.baseline(path)?, None);
        assert_eq!(reopened.pending_recoveries()?, vec![recovery.clone()]);
        assert_eq!(
            reopened.complete_operation(plan.operations[1].id, Some(&target))?,
            OperationCompletion::WaitingForRecovery(recovery.id)
        );
        assert_eq!(
            reopened.complete_recovery(recovery.id)?,
            RecoveryCompletion::Completed
        );
        assert_eq!(
            reopened.complete_operation(plan.operations[1].id, Some(&target))?,
            OperationCompletion::PlanCompleted
        );
        assert_eq!(reopened.baseline(path)?, Some(target));
        Ok(())
    }

    #[test]
    fn journal_rejects_newer_schema_without_changing_its_version() -> Result<(), Box<dyn Error>> {
        let directory = TempDir::new()?;
        let database_path = journal_path(&directory);
        let connection = Connection::open(&database_path)?;
        connection.pragma_update(None, "user_version", 2)?;
        drop(connection);

        let opened = Journal::open(&database_path);
        assert!(matches!(
            opened,
            Err(JournalError::UnsupportedVersion {
                found: 2,
                supported: 1,
                ..
            })
        ));
        let connection = Connection::open(database_path)?;
        let version =
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
        assert_eq!(version, 2);
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
            assert_eq!(
                journal.finish_plan_with_conflict(plan.id, &conflict)?,
                PlanConflictCompletion::Recorded
            );
            plan
        };

        let mut reopened = Journal::open(&database_path)?;
        assert_eq!(
            reopened.baseline(path)?,
            Some(Baseline::Present(baseline_file))
        );
        assert!(reopened.pending_plans()?.is_empty());
        let completed =
            read_plan(&reopened.connection, &database_path, plan.id)?.ok_or_else(|| {
                JournalError::InvalidState {
                    operation: "read completed test plan",
                    path: path.to_path_buf(),
                    detail: "completed plan disappeared",
                }
            })?;
        assert_eq!(completed.status, RecordStatus::Completed);
        assert!(
            completed
                .operations
                .iter()
                .all(|operation| operation.status == RecordStatus::Completed)
        );
        let conflicts = reopened.conflicts()?;
        assert_eq!(conflicts.len(), 1);
        assert_eq!(conflicts[0].path, path);
        assert_eq!(conflicts[0].conflict, conflict);

        assert_eq!(
            reopened.finish_plan_with_conflict(plan.id, &conflict)?,
            PlanConflictCompletion::AlreadyCompleted
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
