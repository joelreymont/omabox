//! Domain values used by the pure per-path sync planner.

use std::borrow::Borrow;
use std::cmp::Ordering;
use std::ffi::OsString;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// One byte past the separator, so `[path + "/", path + SUBTREE_END)` is
/// exactly the set of byte strings that begin with `path + "/"`. Ending the
/// range at `path + "/" + 0xFF` instead would drop every child whose name
/// starts with `0xFF`.
const SUBTREE_END: u8 = b'/' + 1;

/// Dropbox-canonical path relative to the sync root.
///
/// Ordering, equality, and hashing all read the raw bytes, so the in-memory
/// order of a set of canonical paths is always the SQLite BLOB order the
/// journal returns. `Path` compares component by component, which puts
/// `notes/bar` before `notes.txt` while SQLite puts it after; mixing the two
/// silently drops the baselines of files under a directory that has a sibling
/// sorting between the directory and its children.
#[derive(Clone, Debug)]
pub struct CanonicalPath(PathBuf);

impl CanonicalPath {
    /// Fold one display path relative to the sync root into Dropbox's identity.
    #[must_use]
    pub fn from_display(path: &Path) -> Self {
        Self(
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
                .collect(),
        )
    }

    /// Rebuild an already canonical path from its stored bytes.
    pub(crate) fn from_bytes(bytes: Vec<u8>) -> Self {
        Self(PathBuf::from(OsString::from_vec(bytes)))
    }

    /// Borrow the canonical path for display and filesystem-shaped operations.
    #[must_use]
    pub fn as_path(&self) -> &Path {
        &self.0
    }

    /// Borrow the ordered byte representation stored in the journal.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_os_str().as_bytes()
    }

    /// Return whether this path lies strictly beneath `ancestor`.
    #[must_use]
    pub fn is_beneath(&self, ancestor: &Self) -> bool {
        let ancestor = ancestor.as_bytes();
        self.as_bytes()
            .strip_prefix(ancestor)
            .is_some_and(|remainder| remainder.first() == Some(&b'/'))
    }

    /// Return the half-open byte range holding exactly the paths beneath this
    /// one, so a range query and `is_beneath` always agree.
    pub(crate) fn subtree_range(&self) -> (Vec<u8>, Vec<u8>) {
        let mut start = Vec::with_capacity(self.as_bytes().len() + 1);
        start.extend_from_slice(self.as_bytes());
        let mut end = start.clone();
        start.push(b'/');
        end.push(SUBTREE_END);
        (start, end)
    }
}

impl Ord for CanonicalPath {
    fn cmp(&self, other: &Self) -> Ordering {
        self.as_bytes().cmp(other.as_bytes())
    }
}

impl PartialOrd for CanonicalPath {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for CanonicalPath {
    fn eq(&self, other: &Self) -> bool {
        self.as_bytes() == other.as_bytes()
    }
}

impl Eq for CanonicalPath {}

impl Hash for CanonicalPath {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.as_bytes().hash(state);
    }
}

/// Ordering, equality, and hashing are all defined over these bytes, so keyed
/// collections can be looked up by a borrowed slice without building a path.
impl Borrow<[u8]> for CanonicalPath {
    fn borrow(&self) -> &[u8] {
        self.as_bytes()
    }
}

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

    /// Return the revision value supplied by Dropbox.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
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
    /// Both sides last agreed that a directory exists at the path.
    Directory,
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
    /// A directory is present at the path.
    Directory,
    /// A complete observation proves the path is absent.
    ConfirmedAbsent,
    /// Presence or absence cannot safely be determined.
    Unknown(UnknownReason),
}

/// Local observation accepted by the planner.
pub type LocalObservation = Observation<LocalFile>;

/// Remote observation accepted by the planner.
pub type RemoteObservation = Observation<RemoteFile>;

/// What the durable remote inventory holds beneath one path.
///
/// Dropbox deletes a folder together with everything inside it, so the planner
/// deletes a remote directory only while the inventory shows nothing beneath
/// it. An occupied directory waits until every descendant has been reconciled
/// away on its own terms; nothing beneath it is ever inferred deleted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RemoteSubtree {
    /// The inventory records nothing beneath the path.
    Empty,
    /// The inventory records at least one descendant, whatever its state.
    Occupied,
}

/// Ordered mutation step selected for one path.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum Operation {
    /// Create a local directory while the path remains absent.
    CreateLocalDirectory,
    /// Create a Dropbox directory while the path remains absent.
    CreateRemoteDirectory,
    /// Remove an empty local directory after confirmed remote absence.
    DeleteLocalDirectory,
    /// Remove an empty Dropbox directory after confirmed local absence.
    DeleteRemoteDirectory,
    /// Create a remote file only while the remote path remains absent.
    CreateRemote { content: ContentIdentity },
    /// Install a remote file at a locally absent path.
    InstallLocal { source: RemoteFile },
    /// Legacy recovery step retained only to decode old journals.
    PreserveLocal { file: LocalFile },
    /// Replace local bytes if the observed content still matches.
    ReplaceLocal {
        source: RemoteFile,
        expected_content: ContentIdentity,
    },
    /// Delete local bytes if the observed content still matches.
    DeleteLocal { expected_content: ContentIdentity },
    /// Legacy recovery step retained only to decode old journals.
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
            Self::CreateLocalDirectory => "create local directory if still absent",
            Self::CreateRemoteDirectory => "create remote directory if still absent",
            Self::DeleteLocalDirectory => "delete empty local directory",
            Self::DeleteRemoteDirectory => "delete empty remote directory",
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
    /// Both complete observations report a directory.
    DirectoriesMatch,
}

/// A file occupies the same synchronized path as a directory.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DirectoryCollision {
    /// Move the local file to a deterministic synchronized sibling, then keep the directory.
    LocalFileRemoteDirectory { local: LocalFile },
    /// Copy the exact Dropbox file to a deterministic synchronized sibling, then keep the directory.
    LocalDirectoryRemoteFile { remote: RemoteFile },
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

/// Input that prevents a safe decision for now.
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
    /// The locally deleted directory still holds Dropbox entries, so its
    /// deletion waits until each descendant has been reconciled away.
    RemoteDirectoryOccupied,
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
    /// A directory wins over a file after the file is preserved under a synchronized name.
    DirectoryCollision(DirectoryCollision),
}

impl fmt::Display for Decision {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoOp(noop) if noop.reason() == NoOpReason::BothAbsent => {
                formatter.write_str("no operation: both sides are confirmed absent")
            }
            Self::NoOp(noop) if noop.reason() == NoOpReason::DirectoriesMatch => {
                formatter.write_str("no operation: both sides contain a directory")
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
            Self::Blocked(BlockedReason::RemoteDirectoryOccupied) => {
                formatter.write_str("blocked: remote directory still holds entries")
            }
            Self::Conflict(conflict) => write!(formatter, "conflict: {}", conflict.description()),
            Self::DirectoryCollision(_) => formatter
                .write_str("preserve the file under a synchronized name and keep the directory"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn canonical(path: &str) -> CanonicalPath {
        CanonicalPath::from_display(Path::new(path))
    }

    #[test]
    fn canonical_order_is_bytewise_not_component_wise() {
        let directory = canonical("report");
        let sibling = canonical("report.txt");
        let child = canonical("report/x");

        assert!(directory < sibling);
        assert!(sibling < child);
        assert!(Path::new("report/x") < Path::new("report.txt"));
    }

    #[test]
    fn canonical_paths_fold_case_and_compare_by_bytes() {
        assert_eq!(canonical("Report/X.TXT"), canonical("report/x.txt"));
        assert_eq!(canonical("Report/X.TXT").as_bytes(), b"report/x.txt");
        assert_ne!(canonical("report"), canonical("report.txt"));
    }

    #[test]
    fn subtree_range_holds_exactly_the_paths_beneath_an_ancestor() {
        let ancestor = canonical("report");
        let (start, end) = ancestor.subtree_range();

        for beneath in [
            CanonicalPath::from_bytes(b"report/\xff".to_vec()),
            CanonicalPath::from_bytes(b"report/\xffdeep/\xff".to_vec()),
            canonical("report/x"),
            canonical("report/\u{10ffff}"),
        ] {
            assert!(beneath.is_beneath(&ancestor));
            assert!(beneath.as_bytes() >= start.as_slice());
            assert!(beneath.as_bytes() < end.as_slice());
        }
        for outside in [
            canonical("report"),
            canonical("report.txt"),
            canonical("report0"),
            canonical("reports/x"),
        ] {
            assert!(!outside.is_beneath(&ancestor));
            assert!(outside.as_bytes() < start.as_slice() || outside.as_bytes() >= end.as_slice());
        }
    }

    #[test]
    fn only_true_descendants_are_beneath_an_ancestor() {
        let ancestor = canonical("report");

        assert!(canonical("report/x").is_beneath(&ancestor));
        assert!(canonical("report/x/deep").is_beneath(&ancestor));
        assert!(!canonical("report.txt").is_beneath(&ancestor));
        assert!(!canonical("report2/x").is_beneath(&ancestor));
        assert!(!ancestor.is_beneath(&ancestor));
        assert!(!canonical("other/report/x").is_beneath(&ancestor));
    }
}
