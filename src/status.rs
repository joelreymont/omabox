//! Stable, read-only explanations of durable synchronization state.

use std::path::{Path, PathBuf};

use miette::Diagnostic;
use thiserror::Error;

use crate::journal::{Journal, JournalError, RecordStatus};
use crate::model::Observation;

/// Status shown before setup has created a journal.
pub const NOT_INITIALIZED: &str = "Omabox is not set up; run `omabox setup [REMOTE_ROOT]`.";

/// Read the journal and render its durable state without contacting Dropbox.
pub fn render(journal: &mut Journal) -> Result<String, StatusError> {
    let mut entries = Vec::new();

    for plan in journal
        .pending_plans()
        .map_err(|source| status("read pending sync plans", source))?
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

    for record in journal
        .local_inventory()
        .map_err(|source| status("read local observations", source))?
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
    {
        if let Observation::Unknown(reason) = record.observation {
            entries.push(StatusEntry::new(
                record.path,
                format!("Dropbox status unknown: {reason}"),
            ));
        }
    }

    for record in journal
        .conflicts()
        .map_err(|source| status("read conflicts", source))?
    {
        entries.push(StatusEntry::new(
            record.path,
            format!("conflict: {}", record.conflict.description()),
        ));
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

/// A typed failure while reading durable status.
#[derive(Debug, Diagnostic, Error)]
#[error("could not {operation}")]
#[diagnostic(
    code(omabox::status::journal),
    help("Check access to the Omabox state directory, then retry `omabox status`.")
)]
pub struct StatusError {
    operation: &'static str,
    #[source]
    source: JournalError,
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
    StatusError { operation, source }
}

fn render_entries(entries: &[StatusEntry]) -> String {
    if entries.is_empty() {
        return String::from("Omabox has no recorded pending work or conflicts.\n");
    }

    let mut output = String::from("Omabox needs attention:\n");
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

    use crate::journal::{
        LocalObservationRecord, PlanWrite, RecoveryWrite, RemoteObservationRecord,
    };
    use crate::model::{
        Conflict, ContentIdentity, LocalFile, Observation, Operation, OperationPlan, RemoteFile,
        UnknownReason,
    };

    use super::*;

    #[test]
    fn status_snapshot_is_sorted_and_omits_internal_values() -> Result<(), Box<dyn Error>> {
        const SENTINEL: &str = "absolute-state-sentinel";

        let temporary = tempfile::TempDir::new()?;
        let mut journal = Journal::open(temporary.path().join("journal.sqlite3"))?;
        journal.publish_local_inventory(&[LocalObservationRecord {
            path: PathBuf::from("z-local.txt"),
            observation: Observation::Unknown(UnknownReason::Inaccessible),
        }])?;
        journal.publish_remote_inventory(
            "cursor-must-not-render",
            &[RemoteObservationRecord {
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
        journal.record_conflict(
            Path::new("b-conflict.txt"),
            &Conflict::RemoteDeletionLocalEdit {
                local: LocalFile::new(ContentIdentity::new("local-secret-sentinel")),
            },
        )?;
        journal.record_conflict(
            Path::new("c-conflict.txt"),
            &Conflict::LocalDeletionRemoteEdit {
                remote: RemoteFile::new(
                    ContentIdentity::new("remote-secret-sentinel"),
                    crate::model::DropboxRevision::new("revision-must-not-render"),
                ),
            },
        )?;

        let rendered = render(&mut journal)?;
        insta::assert_snapshot!(rendered, @r###"
        Omabox needs attention:
        - a-remote.txt: Dropbox status unknown: inventory is stale
        - b-conflict.txt: conflict: remote deletion conflicts with a local edit; preserve the local payload
        - c-conflict.txt: conflict: local deletion conflicts with a remote edit; preserve the remote payload
        - m-pending.txt: pending sync: 2 remaining; next: preserve displaced local payload
        - m-pending.txt: recovery copy is pending
        - z-local.txt: local status unknown: path is inaccessible
        "###);
        for forbidden in [
            SENTINEL,
            "cursor-must-not-render",
            "content-id-must-not-render",
            "revision-must-not-render",
            "local-secret-sentinel",
            "remote-secret-sentinel",
        ] {
            assert!(!rendered.contains(forbidden));
        }
        Ok(())
    }
}
