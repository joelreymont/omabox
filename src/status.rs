//! Stable, read-only explanations of durable synchronization state.

use std::io;
use std::path::{Path, PathBuf};

use miette::Diagnostic;
use thiserror::Error;

use crate::exclusions::is_excluded;
use crate::journal::{BlockReason, Journal, JournalError, PlanStatus, RecordStatus};
use crate::model::Observation;

/// Status shown before setup has created a journal.
pub const NOT_INITIALIZED: &str = "Omabox is not set up; run `omabox setup [REMOTE_ROOT]`.";

/// Open an initialized journal read-only and explain its durable state.
pub fn render(path: impl AsRef<Path>) -> Result<String, StatusError> {
    let path = path.as_ref();
    match path.try_exists() {
        Ok(true) => {}
        Ok(false) => {
            return Ok(format!("{NOT_INITIALIZED}\n"));
        }
        Err(source) => return Err(StatusError::Inspect { source }),
    }
    let mut journal = Journal::open_read_only(path)
        .map_err(|source| status("open the journal read-only", source))?;
    if journal
        .dropbox_binding()
        .map_err(|source| status("read Dropbox setup state", source))?
        .is_none()
    {
        return Ok(format!("{NOT_INITIALIZED}\n"));
    }
    render_journal(&mut journal)
}

fn render_journal(journal: &mut Journal) -> Result<String, StatusError> {
    let mut entries = Vec::new();

    for plan in journal
        .pending_plans()
        .map_err(|source| status("read pending sync plans", source))?
        .into_iter()
        .filter(|plan| !is_excluded(&plan.path))
    {
        let pending = plan
            .operations
            .iter()
            .filter(|operation| operation.status == RecordStatus::Pending)
            .count();
        let next = plan
            .operations
            .iter()
            .find(|operation| operation.status == RecordStatus::Pending)
            .map(|operation| operation.operation.description());
        let detail = match next {
            Some(description) => {
                format!("pending sync: {pending} remaining; next: {description}")
            }
            None => String::from("pending sync: completion is awaiting journal recovery"),
        };
        entries.push(StatusEntry::new(plan.path, detail));
    }

    for plan in journal
        .blocked_plans()
        .map_err(|source| status("read blocked sync plans", source))?
        .into_iter()
        .filter(|plan| !is_excluded(&plan.path))
    {
        let PlanStatus::Blocked { reason, .. } = plan.status else {
            continue;
        };
        entries.push(StatusEntry::new(
            plan.path,
            format!(
                "blocked sync: {}; retry is scheduled",
                block_reason(&reason)
            ),
        ));
    }

    for record in journal
        .local_inventory()
        .map_err(|source| status("read local observations", source))?
        .into_iter()
        .filter(|record| !is_excluded(&record.path))
    {
        if let Observation::Unknown(reason) = record.observation {
            entries.push(StatusEntry::new(
                record.path,
                format!("local status unknown: {reason}"),
            ));
        }
    }

    for record in journal
        .remote_inventory()
        .map_err(|source| status("read remote observations", source))?
        .observations
        .into_iter()
        .filter(|record| !is_excluded(&record.path))
    {
        if let Observation::Unknown(reason) = record.observation {
            entries.push(StatusEntry::new(
                record.path,
                format!("Dropbox status unknown: {reason}"),
            ));
        }
    }

    for record in journal
        .pending_recoveries()
        .map_err(|source| status("read pending recovery copies", source))?
    {
        entries.push(StatusEntry::new(
            record.original_path,
            String::from("recovery copy is pending"),
        ));
    }

    entries.sort_by(|left, right| {
        left.path
            .cmp(&right.path)
            .then_with(|| left.detail.cmp(&right.detail))
    });
    Ok(render_entries(&entries))
}

fn block_reason(reason: &BlockReason) -> String {
    match reason {
        BlockReason::UnsupportedFileSize => {
            String::from("file exceeds the supported Dropbox upload size")
        }
        BlockReason::RemoteRejected { tag } => {
            format!("Dropbox rejected the path ({tag})")
        }
        BlockReason::DownloadUnavailable { status } => {
            format!("Dropbox download returned HTTP {status}")
        }
        BlockReason::DownloadVerificationFailed => {
            String::from("Dropbox download did not match its recorded identity")
        }
        BlockReason::StageOccupied => {
            String::from("unrelated data occupies the private staging path")
        }
        BlockReason::LocalObjectInWay => String::from("a local object blocks the download path"),
        BlockReason::RemoteObject => String::from("a Dropbox object blocks the file path"),
        BlockReason::ConflictCopyOccupied => {
            String::from("another file holds this path's conflict copy name")
        }
    }
}

/// A typed failure while reading durable status.
#[derive(Debug, Diagnostic, Error)]
pub enum StatusError {
    /// The journal path could not be inspected.
    #[error("could not inspect Omabox setup state")]
    #[diagnostic(
        code(omabox::status::inspect),
        help("Check access to the Omabox state directory, then retry `omabox status`.")
    )]
    Inspect {
        #[source]
        source: io::Error,
    },
    /// The initialized journal could not be read.
    #[error("could not {operation}")]
    #[diagnostic(
        code(omabox::status::journal),
        help("Check access to the Omabox state directory, then retry `omabox status`.")
    )]
    Journal {
        operation: &'static str,
        #[source]
        source: JournalError,
    },
}

#[derive(Debug)]
struct StatusEntry {
    path: PathBuf,
    detail: String,
}

impl StatusEntry {
    fn new(path: PathBuf, detail: String) -> Self {
        Self { path, detail }
    }
}

fn status(operation: &'static str, source: JournalError) -> StatusError {
    StatusError::Journal {
        operation,
        source: source.redact_paths(),
    }
}

fn render_entries(entries: &[StatusEntry]) -> String {
    if entries.is_empty() {
        return String::from("Omabox has no recorded work needing attention.\n");
    }

    let mut output = String::from("Omabox status:\n");
    for entry in entries {
        output.push_str("- ");
        output.push_str(&display_path(&entry.path));
        output.push_str(": ");
        output.push_str(&entry.detail);
        output.push('\n');
    }
    output
}

fn display_path(path: &Path) -> String {
    if path.is_absolute() {
        String::from("(invalid synchronized path)")
    } else if path.as_os_str().is_empty() {
        String::from(".")
    } else {
        path.to_string_lossy().into_owned()
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;

    use crate::journal::{
        BlockReason, LocalObservationRecord, PlanBlock, PlanWrite, RecoveryWrite,
        RemoteObservationRecord,
    };
    use crate::model::{
        CanonicalPath, Conflict, ContentIdentity, LocalFile, Observation, Operation, OperationPlan,
        RemoteFile, UnknownReason,
    };

    use super::*;

    #[test]
    fn status_snapshot_is_sorted_and_omits_internal_values() -> Result<(), Box<dyn Error>> {
        const SENTINEL: &str = "absolute-state-sentinel";

        let temporary = tempfile::TempDir::new()?;
        let journal_path = temporary.path().join("journal.sqlite3");
        let mut journal = Journal::open(&journal_path)?;
        journal.bind_dropbox_root(&crate::journal::DropboxBinding {
            account_id: String::from("account-id-must-not-render"),
            root_namespace_id: String::from("namespace-id-must-not-render"),
            remote_root: String::from("/remote-root-must-not-render"),
        })?;
        journal.publish_local_inventory(&[LocalObservationRecord {
            path: PathBuf::from("z-local.txt"),
            observation: Observation::Unknown(UnknownReason::Inaccessible),
        }])?;
        journal.publish_remote_inventory(
            "cursor-must-not-render",
            &[RemoteObservationRecord {
                canonical_path: CanonicalPath::from_display(Path::new("a-remote.txt")),
                path: PathBuf::from("a-remote.txt"),
                observation: Observation::Unknown(UnknownReason::Stale),
            }],
        )?;

        let displaced = LocalFile::new(ContentIdentity::new("content-id-must-not-render"));
        let plan = OperationPlan::new(vec![
            Operation::PreserveLocal {
                file: displaced.clone(),
            },
            Operation::DeleteLocal {
                expected_content: displaced.content,
            },
        ]);
        let PlanWrite::Recorded(plan) = journal.record_plan(Path::new("m-pending.txt"), &plan)?
        else {
            return Err("fresh plan was already pending".into());
        };
        let Some(operation) = plan.operations.get(1) else {
            return Err("recorded plan had no destructive operation".into());
        };
        let RecoveryWrite::Recorded(_) =
            journal.record_recovery_intent(operation.id, &Path::new("/private").join(SENTINEL))?
        else {
            return Err("fresh recovery was not recorded".into());
        };
        let blocked_plan = OperationPlan::new(vec![Operation::InstallLocal {
            source: RemoteFile::new(
                ContentIdentity::new("blocked-content-must-not-render"),
                crate::model::DropboxRevision::new("blocked-revision-must-not-render"),
            ),
        }]);
        let PlanWrite::Recorded(blocked) =
            journal.record_plan(Path::new("n-blocked.txt"), &blocked_plan)?
        else {
            return Err("fresh blocked plan was already live".into());
        };
        assert_eq!(
            journal.block_plan(
                blocked.id,
                &BlockReason::DownloadUnavailable { status: 409 },
                1_700_000_000,
            )?,
            PlanBlock::Blocked
        );
        journal.record_conflict(
            Path::new("b-diverged.txt"),
            &Conflict::RemoteDeletionLocalEdit {
                local: LocalFile::new(ContentIdentity::new("local-secret-sentinel")),
            },
        )?;
        journal.record_conflict(
            Path::new("c-diverged.txt"),
            &Conflict::LocalDeletionRemoteEdit {
                remote: RemoteFile::new(
                    ContentIdentity::new("remote-secret-sentinel"),
                    crate::model::DropboxRevision::new("revision-must-not-render"),
                ),
            },
        )?;

        drop(journal);
        let rendered = render(&journal_path)?;
        insta::assert_snapshot!(rendered, @r###"
        Omabox status:
        - a-remote.txt: Dropbox status unknown: inventory is stale
        - m-pending.txt: pending sync: 2 remaining; next: preserve displaced local payload
        - m-pending.txt: recovery copy is pending
        - n-blocked.txt: blocked sync: Dropbox download returned HTTP 409; retry is scheduled
        - z-local.txt: local status unknown: path is inaccessible
        "###);
        for forbidden in [
            SENTINEL,
            "cursor-must-not-render",
            "content-id-must-not-render",
            "revision-must-not-render",
            "blocked-content-must-not-render",
            "blocked-revision-must-not-render",
            "local-secret-sentinel",
            "remote-secret-sentinel",
            "account-id-must-not-render",
            "namespace-id-must-not-render",
            "remote-root-must-not-render",
            "b-diverged.txt",
            "c-diverged.txt",
        ] {
            assert!(!rendered.contains(forbidden));
        }
        Ok(())
    }

    #[test]
    fn status_never_initializes_or_migrates_a_journal() -> Result<(), Box<dyn Error>> {
        let temporary = tempfile::TempDir::new()?;

        let absent = temporary.path().join("absent.sqlite3");
        assert_eq!(render(&absent)?, format!("{NOT_INITIALIZED}\n"));
        assert!(!absent.exists());

        let empty = temporary.path().join("empty.sqlite3");
        fs::File::create(&empty)?;
        assert!(render(&empty).is_err());
        assert_eq!(fs::metadata(&empty)?.len(), 0);

        let version_zero = temporary.path().join("version-zero.sqlite3");
        drop(rusqlite::Connection::open(&version_zero)?);
        assert!(render(&version_zero).is_err());
        let connection = rusqlite::Connection::open_with_flags(
            &version_zero,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )?;
        assert_eq!(
            connection.query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?,
            0
        );

        let unbound = temporary.path().join("unbound.sqlite3");
        drop(Journal::open(&unbound)?);
        assert_eq!(render(&unbound)?, format!("{NOT_INITIALIZED}\n"));
        Ok(())
    }

    #[test]
    fn status_diagnostics_redact_the_absolute_journal_path() -> Result<(), Box<dyn Error>> {
        const SENTINEL: &str = "absolute-journal-path-sentinel";

        let temporary = tempfile::TempDir::new()?;
        let path = temporary.path().join(SENTINEL);
        drop(rusqlite::Connection::open(&path)?);
        let error = render(&path)
            .err()
            .ok_or("schema-zero journal unexpectedly rendered status")?;
        for rendered in [format!("{error}"), format!("{error:?}")] {
            assert!(!rendered.contains(SENTINEL));
        }
        assert!(!format!("{:?}", miette::Report::new(error)).contains(SENTINEL));
        Ok(())
    }
}
