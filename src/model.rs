//! Domain values used by the pure per-path sync planner.

use std::fmt;

use serde::{Deserialize, Serialize};

/// Stable identity of a file's bytes.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ContentIdentity(String);

impl ContentIdentity {
    /// Construct a content identity supplied by a scanner or Dropbox response.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// Return the Dropbox content-hash representation.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Dropbox revision that guards a remote mutation.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct DropboxRevision(String);

impl DropboxRevision {
    /// Construct a revision supplied by Dropbox.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }
}

/// A locally observed regular file.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LocalFile {
    /// Identity of the observed bytes.
    pub content: ContentIdentity,
}

impl LocalFile {
    /// Construct a local file observation.
    pub fn new(content: ContentIdentity) -> Self {
        Self { content }
    }
}

/// A remotely observed Dropbox file.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RemoteFile {
    /// Identity of the observed bytes.
    pub content: ContentIdentity,
    /// Current Dropbox revision for these bytes.
    pub revision: DropboxRevision,
}

impl RemoteFile {
    /// Construct a remote file observation.
    pub fn new(content: ContentIdentity, revision: DropboxRevision) -> Self {
        Self { content, revision }
    }
}

/// Last common state durably recorded for one path.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum Baseline {
    /// The path had no synchronized file.
    Absent,
    /// Both sides last agreed on this content and Dropbox revision.
    Present(RemoteFile),
}

/// Why an observation cannot prove either presence or absence.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum UnknownReason {
    /// The complete scan or listing has not finished.
    Incomplete,
    /// The path or root could not be accessed.
    Inaccessible,
    /// A required local or remote service was unavailable.
    Unavailable,
    /// The available inventory is stale.
    Stale,
    /// Dropbox invalidated the inventory cursor.
    CursorReset,
    /// The observed object is outside the supported first-release scope.
    Unsupported,
}

impl fmt::Display for UnknownReason {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let reason = match self {
            Self::Incomplete => "observation is incomplete",
            Self::Inaccessible => "path is inaccessible",
            Self::Unavailable => "source is unavailable",
            Self::Stale => "inventory is stale",
            Self::CursorReset => "remote cursor was reset",
            Self::Unsupported => "object is unsupported",
        };
        formatter.write_str(reason)
    }
}

/// Result of observing one side of a path.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum Observation<T> {
    /// The path is present with a complete payload description.
    Present(T),
    /// A complete observation proves the path is absent.
    ConfirmedAbsent,
    /// Presence or absence cannot safely be determined.
    Unknown(UnknownReason),
}

/// Local observation accepted by the planner.
pub type LocalObservation = Observation<LocalFile>;

/// Remote observation accepted by the planner.
pub type RemoteObservation = Observation<RemoteFile>;

/// Ordered recovery or mutation step selected for one path.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum Operation {
    /// Create a remote file only while the remote path remains absent.
    CreateRemote { content: ContentIdentity },
    /// Install a remote file at a locally absent path.
    InstallLocal { source: RemoteFile },
    /// Retain the displaced local payload before mutation.
    PreserveLocal { file: LocalFile },
    /// Replace local bytes after retaining the displaced payload.
    ReplaceLocal {
        source: RemoteFile,
        expected_content: ContentIdentity,
    },
    /// Delete local bytes after retaining the displaced payload.
    DeleteLocal { expected_content: ContentIdentity },
    /// Retain the exact displaced Dropbox payload before mutation.
    PreserveRemote { file: RemoteFile },
    /// Replace a Dropbox file only if its last known revision still matches.
    ReplaceRemote {
        content: ContentIdentity,
        expected_revision: DropboxRevision,
    },
    /// Delete a Dropbox file only if its last known revision still matches.
    DeleteRemote { expected_revision: DropboxRevision },
}

impl Operation {
    pub(crate) fn description(&self) -> &'static str {
        match self {
            Self::CreateRemote { .. } => "create remote file if still absent",
            Self::InstallLocal { .. } => "install remote content locally",
            Self::PreserveLocal { .. } => "preserve displaced local payload",
            Self::ReplaceLocal { .. } => "replace local content",
            Self::DeleteLocal { .. } => "delete local file",
            Self::PreserveRemote { .. } => "preserve displaced remote payload",
            Self::ReplaceRemote { .. } => {
                "replace remote content if the expected revision still matches"
            }
            Self::DeleteRemote { .. } => {
                "delete remote file if the expected revision still matches"
            }
        }
    }
}

/// Non-empty ordered operations produced by the planner.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OperationPlan(Vec<Operation>);

impl OperationPlan {
    pub(crate) fn new(operations: Vec<Operation>) -> Self {
        Self(operations)
    }

    /// Return operations in their required execution order.
    #[must_use]
    pub fn operations(&self) -> &[Operation] {
        &self.0
    }
}

/// Explanation for a decision that requires no operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum NoOpReason {
    /// Both complete observations report absence.
    BothAbsent,
    /// Both present observations identify the same bytes.
    ContentMatches,
}

/// A planner-approved baseline transition that requires no effect.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoOpDecision {
    reason: NoOpReason,
    baseline: Baseline,
}

impl NoOpDecision {
    pub(crate) fn new(reason: NoOpReason, baseline: Baseline) -> Self {
        Self { reason, baseline }
    }

    /// Explain why no effect is required.
    #[must_use]
    pub fn reason(&self) -> NoOpReason {
        self.reason
    }

    /// Return the completely observed common state to record.
    #[must_use]
    pub fn baseline(&self) -> &Baseline {
        &self.baseline
    }
}

/// Unknown input that prevents a safe decision.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlockedReason {
    /// Only the local observation is unknown.
    LocalUnknown(UnknownReason),
    /// Only the remote observation is unknown.
    RemoteUnknown(UnknownReason),
    /// Both observations are unknown.
    BothUnknown {
        local: UnknownReason,
        remote: UnknownReason,
    },
}

/// Simultaneous states that cannot be reconciled without preserving a conflict.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum Conflict {
    /// Different files were independently introduced at a path with no baseline.
    InitialCollision {
        local: LocalFile,
        remote: RemoteFile,
    },
    /// Both files changed from the common baseline to different bytes.
    DivergentEdits {
        local: LocalFile,
        remote: RemoteFile,
    },
    /// The local file was deleted while the remote file changed.
    LocalDeletionRemoteEdit { remote: RemoteFile },
    /// The remote file was deleted while the local file changed.
    RemoteDeletionLocalEdit { local: LocalFile },
}

impl Conflict {
    /// Local payload retained by this conflict, when one is present.
    #[must_use]
    pub fn local(&self) -> Option<&LocalFile> {
        match self {
            Self::InitialCollision { local, .. }
            | Self::DivergentEdits { local, .. }
            | Self::RemoteDeletionLocalEdit { local } => Some(local),
            Self::LocalDeletionRemoteEdit { .. } => None,
        }
    }

    /// Remote payload retained by this conflict, when one is present.
    #[must_use]
    pub fn remote(&self) -> Option<&RemoteFile> {
        match self {
            Self::InitialCollision { remote, .. }
            | Self::DivergentEdits { remote, .. }
            | Self::LocalDeletionRemoteEdit { remote } => Some(remote),
            Self::RemoteDeletionLocalEdit { .. } => None,
        }
    }

    pub(crate) fn description(&self) -> &'static str {
        match self {
            Self::InitialCollision { .. } => {
                "different local and remote payloads were introduced; preserve both payloads"
            }
            Self::DivergentEdits { .. } => {
                "local and remote payloads diverged; preserve both payloads"
            }
            Self::LocalDeletionRemoteEdit { .. } => {
                "local deletion conflicts with a remote edit; preserve the remote payload"
            }
            Self::RemoteDeletionLocalEdit { .. } => {
                "remote deletion conflicts with a local edit; preserve the local payload"
            }
        }
    }
}

/// Pure planner outcome for one path.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Decision {
    /// The complete observations already agree.
    NoOp(NoOpDecision),
    /// Recovery and mutation steps, in execution order.
    Operations(OperationPlan),
    /// Uncertain state prevents a safe decision.
    Blocked(BlockedReason),
    /// Simultaneous changes must retain every present payload.
    Conflict(Conflict),
}

impl fmt::Display for Decision {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoOp(noop) if noop.reason() == NoOpReason::BothAbsent => {
                formatter.write_str("no operation: both sides are confirmed absent")
            }
            Self::NoOp(_) => formatter.write_str("no operation: local and remote content match"),
            Self::Operations(plan) => {
                formatter.write_str("operations:")?;
                for (index, operation) in plan.operations().iter().enumerate() {
                    write!(formatter, "\n{}. {}", index + 1, operation.description())?;
                }
                Ok(())
            }
            Self::Blocked(BlockedReason::LocalUnknown(reason)) => {
                write!(formatter, "blocked: local {reason}")
            }
            Self::Blocked(BlockedReason::RemoteUnknown(reason)) => {
                write!(formatter, "blocked: remote {reason}")
            }
            Self::Blocked(BlockedReason::BothUnknown { local, remote }) => {
                write!(formatter, "blocked: local {local}; remote {remote}")
            }
            Self::Conflict(conflict) => write!(formatter, "conflict: {}", conflict.description()),
        }
    }
}
