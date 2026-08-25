use std::error::Error;
use std::io::{self, Cursor, Read};
use std::path::{Path, PathBuf};

use omabox::journal::{
    Journal, LocalObservationRecord, LocalRootBinding, OperationCompletion, PlanRecord, PlanWrite,
};
use omabox::local::{
    ConflictOutcome, ConflictSide, DeleteOutcome, InstallOutcome, ReplacementPreparation,
    ScanPublication, StageOutcome, dropbox_content_hash, install_download, materialize_conflict,
    prepare_replacement, scan_and_publish, stage_download, stage_upload,
};
use omabox::model::{
    Baseline, ContentIdentity, Decision, DropboxRevision, LocalFile, Observation, OperationPlan,
    RemoteFile, UnknownReason,
};
use omabox::planner::plan;
use omabox::recovery::replay_local_operations;
use tempfile::TempDir;

fn identity(bytes: &[u8]) -> Result<ContentIdentity, Box<dyn Error>> {
    Ok(dropbox_content_hash(Cursor::new(bytes))?)
}

fn remote(bytes: &[u8], revision: &str) -> Result<RemoteFile, Box<dyn Error>> {
    Ok(RemoteFile::new(
        identity(bytes)?,
        DropboxRevision::new(revision),
    ))
}

fn operations(decision: Decision) -> Result<OperationPlan, Box<dyn Error>> {
    match decision {
        Decision::Operations(operations) => Ok(operations),
        Decision::NoOp(_)
        | Decision::Blocked(_)
        | Decision::Conflict(_)
        | Decision::DirectoryCollision(_) => {
            Err(io::Error::other("test expected planner operations").into())
        }
    }
}

fn recorded_plan(write: PlanWrite) -> Result<PlanRecord, Box<dyn Error>> {
    match write {
        PlanWrite::Recorded(plan) => Ok(plan),
        PlanWrite::AlreadyPending(_) => {
            Err(io::Error::other("test expected a newly recorded plan").into())
        }
    }
}

fn staged_download(outcome: StageOutcome<()>) -> Result<(), Box<dyn Error>> {
    match outcome {
        StageOutcome::Staged(stage) | StageOutcome::AlreadyStaged(stage) => Ok(stage),
        StageOutcome::ContentChanged { .. } => {
            Err(io::Error::other("test expected verified download bytes").into())
        }
        StageOutcome::DestinationOccupied { .. } => {
            Err(io::Error::other("test download stage destination was occupied").into())
        }
    }
}

fn only_entry(directory: &Path) -> Result<PathBuf, Box<dyn Error>> {
    let mut entries = std::fs::read_dir(directory)?;
    let first = entries
        .next()
        .transpose()?
        .ok_or_else(|| io::Error::other("test expected one directory entry"))?;
    if entries.next().transpose()?.is_some() {
        return Err(io::Error::other("test expected exactly one directory entry").into());
    }
    Ok(first.path())
}

fn observation_for<'a>(
    inventory: &'a [LocalObservationRecord],
    path: &Path,
) -> Result<&'a Observation<LocalFile>, Box<dyn Error>> {
    inventory
        .iter()
        .find(|record| record.path == path)
        .map(|record| &record.observation)
        .ok_or_else(|| io::Error::other("test inventory observation was missing").into())
}

fn operation(
    plan: &PlanRecord,
    index: usize,
) -> Result<&omabox::journal::PlannedOperation, Box<dyn Error>> {
    plan.operations
        .get(index)
        .ok_or_else(|| io::Error::other("test plan operation was missing").into())
}

#[test]
fn directory_effects_replay_after_the_filesystem_changed_before_journal_completion()
-> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let recovery = directory.path().join("recovery");
    let database = directory.path().join("journal.sqlite3");
    std::fs::create_dir(&root)?;
    std::fs::create_dir(&recovery)?;
    let path = Path::new("empty");

    let mut journal = Journal::open(&database)?;
    let create = operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Directory,
    ))?;
    let _ = recorded_plan(journal.record_plan(path, &create)?)?;
    std::fs::create_dir(root.join(path))?;
    drop(journal);

    let mut reopened = Journal::open(&database)?;
    let created = replay_local_operations(&mut reopened, &root)?;
    assert_eq!(created.completed_operations, 1);
    assert_eq!(reopened.baseline(path)?, Some(Baseline::Directory));
    assert!(reopened.pending_plans()?.is_empty());

    let delete = operations(plan(
        &Baseline::Directory,
        &Observation::Directory,
        &Observation::ConfirmedAbsent,
    ))?;
    let _ = recorded_plan(reopened.record_plan(path, &delete)?)?;
    std::fs::remove_dir(root.join(path))?;
    drop(reopened);

    let mut replayed = Journal::open(&database)?;
    let deleted = replay_local_operations(&mut replayed, &root)?;
    assert_eq!(deleted.completed_operations, 1);
    assert_eq!(replayed.baseline(path)?, None);
    assert!(replayed.pending_plans()?.is_empty());
    Ok(())
}

#[test]
fn replacement_root_scan_never_publishes_absence_under_old_binding() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let old_root = directory.path().join("old-root");
    std::fs::create_dir(&root)?;
    std::fs::write(root.join("keep.txt"), b"old root bytes")?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    assert!(matches!(
        scan_and_publish(&mut journal, &root)?,
        ScanPublication::Published(_)
    ));
    let published = journal.local_inventory()?;

    std::fs::rename(&root, &old_root)?;
    std::fs::create_dir(&root)?;

    assert_eq!(
        scan_and_publish(&mut journal, &root)?,
        ScanPublication::RootChanged
    );
    assert_eq!(journal.local_inventory()?, published);
    Ok(())
}

#[test]
fn immutable_upload_stage_survives_source_changes() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("upload-staging");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    let source = root.join("upload.txt");
    std::fs::write(&source, b"first")?;
    let first = identity(b"first")?;
    let stage = match stage_upload(&root, "upload.txt", &staging, &first)? {
        StageOutcome::Staged(stage) | StageOutcome::AlreadyStaged(stage) => stage,
        StageOutcome::ContentChanged { .. } => {
            return Err(io::Error::other("upload source changed unexpectedly").into());
        }
        StageOutcome::DestinationOccupied { .. } => {
            return Err(io::Error::other("upload stage destination was occupied").into());
        }
    };

    std::fs::write(source, b"second")?;
    assert!(matches!(
        stage_upload(&root, "upload.txt", &staging, &first)?,
        StageOutcome::AlreadyStaged(_)
    ));
    std::fs::remove_file(root.join("upload.txt"))?;
    assert!(matches!(
        stage_upload(&root, "upload.txt", &staging, &first)?,
        StageOutcome::AlreadyStaged(_)
    ));
    let mut staged = stage.open_verified()?;
    let mut bytes = Vec::new();
    staged.read_to_end(&mut bytes)?;
    assert_eq!(bytes, b"first");
    assert!(
        std::fs::metadata(only_entry(&staging)?)?
            .permissions()
            .readonly()
    );
    Ok(())
}

#[test]
fn download_stage_collision_preserves_user_bytes() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    std::fs::create_dir_all(&root)?;
    let desired = identity(b"download")?;
    staged_download(stage_download(
        &root,
        "target.txt",
        &desired,
        Cursor::new(b"download"),
    )?)?;
    let stage_path = only_entry(&root)?;
    std::fs::remove_file(&stage_path)?;
    std::fs::write(&stage_path, b"user collision")?;

    assert_eq!(
        stage_download(&root, "target.txt", &desired, Cursor::new(b"download"))?,
        StageOutcome::DestinationOccupied {
            path: stage_path.clone()
        }
    );
    std::fs::write(root.join("target.txt"), b"download")?;
    assert_eq!(
        install_download(&root, "target.txt", &desired, None)?,
        InstallOutcome::StageDestinationOccupied {
            path: stage_path.clone()
        }
    );
    assert_eq!(std::fs::read(stage_path)?, b"user collision");
    Ok(())
}

#[test]
fn same_content_user_stage_is_not_mistaken_for_owned_bytes() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    std::fs::create_dir_all(&root)?;
    let desired = identity(b"same bytes")?;
    staged_download(stage_download(
        &root,
        "target.txt",
        &desired,
        Cursor::new(b"same bytes"),
    )?)?;
    let stage_path = only_entry(&root)?;
    std::fs::remove_file(&stage_path)?;
    std::fs::write(&stage_path, b"same bytes")?;

    assert_eq!(
        stage_download(&root, "target.txt", &desired, Cursor::new(b"same bytes"))?,
        StageOutcome::DestinationOccupied {
            path: stage_path.clone()
        }
    );
    std::fs::write(root.join("target.txt"), b"same bytes")?;
    assert_eq!(
        install_download(&root, "target.txt", &desired, None)?,
        InstallOutcome::StageDestinationOccupied {
            path: stage_path.clone()
        }
    );
    assert_eq!(std::fs::read(&stage_path)?, b"same bytes");

    Ok(())
}

#[test]
fn reserved_artifacts_are_unknown_but_conflicts_are_present() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    std::fs::create_dir_all(&root)?;
    let suffix = "a".repeat(64);
    let download = PathBuf::from(format!(".omabox-download-{suffix}"));
    let displaced = PathBuf::from(format!(".omabox-displaced-{suffix}"));
    let deleted = PathBuf::from(format!(".omabox-deleted-{suffix}"));
    let conflict = PathBuf::from(format!(".omabox-conflict-local-{suffix}"));
    for path in [&download, &displaced, &deleted, &conflict] {
        std::fs::write(root.join(path), path.as_os_str().as_encoded_bytes())?;
    }
    let database = directory.path().join("journal.sqlite3");
    let mut journal = Journal::open(database)?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let _scan = scan_and_publish(&mut journal, &root)?;
    let inventory = journal.local_inventory()?;
    for path in [&download, &displaced, &deleted] {
        assert_eq!(
            observation_for(&inventory, path)?,
            &Observation::Unknown(UnknownReason::Unsupported)
        );
    }
    assert!(matches!(
        observation_for(&inventory, &conflict)?,
        Observation::Present(_)
    ));
    Ok(())
}

#[test]
fn already_installed_download_cleans_verified_stage_before_return() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    std::fs::create_dir_all(&root)?;
    let desired = identity(b"installed elsewhere")?;
    staged_download(stage_download(
        &root,
        "target.txt",
        &desired,
        Cursor::new(b"installed elsewhere"),
    )?)?;
    let stage_path = only_entry(&root)?;
    std::fs::write(root.join("target.txt"), b"installed elsewhere")?;

    assert_eq!(
        install_download(&root, "target.txt", &desired, None)?,
        InstallOutcome::AlreadyInstalled
    );
    assert!(!stage_path.exists());

    let database = directory.path().join("journal.sqlite3");
    let mut journal = Journal::open(database)?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    let _scan = scan_and_publish(&mut journal, &root)?;
    assert_eq!(
        journal.local_inventory()?,
        vec![LocalObservationRecord {
            path: PathBuf::from("target.txt"),
            observation: Observation::Present(LocalFile::new(desired)),
        }]
    );
    Ok(())
}

#[test]
fn restart_installs_a_verified_download_and_replay_is_idempotent() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&recovery)?;
    let database = directory.path().join("journal.sqlite3");
    let remote = remote(b"downloaded", "rev-download")?;
    let operation_plan = operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote.clone()),
    ))?;
    {
        let mut journal = Journal::open(&database)?;
        let _recorded =
            recorded_plan(journal.record_plan(Path::new("nested/download.txt"), &operation_plan)?)?;
        staged_download(stage_download(
            &root,
            "nested/download.txt",
            &remote.content,
            Cursor::new(b"downloaded"),
        )?)?;
    }

    let mut reopened = Journal::open(&database)?;
    let report = replay_local_operations(&mut reopened, &root)?;
    assert_eq!(report.completed_operations, 1);
    assert!(report.blocked.is_empty());
    assert_eq!(
        std::fs::read(root.join("nested/download.txt"))?,
        b"downloaded"
    );
    assert_eq!(
        reopened.baseline(Path::new("nested/download.txt"))?,
        Some(Baseline::Present(remote))
    );
    drop(reopened);

    let mut replayed = Journal::open(&database)?;
    let second = replay_local_operations(&mut replayed, &root)?;
    assert_eq!(second.completed_operations, 0);
    assert!(second.blocked.is_empty());
    Ok(())
}

#[test]
fn installed_download_completes_after_restart_without_its_consumed_stage()
-> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&recovery)?;
    let database = directory.path().join("journal.sqlite3");
    let remote = remote(b"durable", "rev-durable")?;
    let operation_plan = operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote.clone()),
    ))?;
    {
        let mut journal = Journal::open(&database)?;
        let _recorded =
            recorded_plan(journal.record_plan(Path::new("installed.txt"), &operation_plan)?)?;
        staged_download(stage_download(
            &root,
            "installed.txt",
            &remote.content,
            Cursor::new(b"durable"),
        )?)?;
        assert_eq!(
            install_download(&root, "installed.txt", &remote.content, None)?,
            InstallOutcome::Installed
        );
    }

    let mut reopened = Journal::open(&database)?;
    let report = replay_local_operations(&mut reopened, &root)?;
    assert_eq!(report.completed_operations, 1);
    assert!(report.blocked.is_empty());
    assert_eq!(std::fs::read(root.join("installed.txt"))?, b"durable");
    assert_eq!(
        reopened.baseline(Path::new("installed.txt"))?,
        Some(Baseline::Present(remote))
    );
    Ok(())
}

#[test]
fn replacement_replays_without_a_recovery_copy() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let recovery_directory = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&recovery_directory)?;
    std::fs::write(root.join("replace.txt"), b"old")?;
    let database = directory.path().join("journal.sqlite3");
    let old = remote(b"old", "rev-old")?;
    let new = remote(b"new", "rev-new")?;
    let operation_plan = operations(plan(
        &Baseline::Present(old.clone()),
        &Observation::Present(LocalFile::new(old.content.clone())),
        &Observation::Present(new.clone()),
    ))?;
    let replace = {
        let mut journal = Journal::open(&database)?;
        let recorded =
            recorded_plan(journal.record_plan(Path::new("replace.txt"), &operation_plan)?)?;
        staged_download(stage_download(
            &root,
            "replace.txt",
            &new.content,
            Cursor::new(b"new"),
        )?)?;
        operation(&recorded, 0)?.clone()
    };

    let mut reopened = Journal::open(&database)?;
    let report = replay_local_operations(&mut reopened, &root)?;
    assert_eq!(report.completed_operations, 1);
    assert!(report.blocked.is_empty());
    assert_eq!(std::fs::read(root.join("replace.txt"))?, b"new");
    assert_eq!(
        reopened.complete_operation(replace.id, Some(&Baseline::Present(new.clone())))?,
        OperationCompletion::AlreadyCompleted
    );
    assert_eq!(
        reopened.baseline(Path::new("replace.txt"))?,
        Some(Baseline::Present(new))
    );
    assert!(recovery_directory.read_dir()?.next().is_none());
    assert!(reopened.pending_recoveries()?.is_empty());
    assert!(reopened.completed_recoveries()?.is_empty());
    Ok(())
}

#[test]
fn replacement_resumes_from_a_durable_displacement_guard() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let recovery_directory = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&recovery_directory)?;
    std::fs::write(root.join("guarded.txt"), b"old")?;
    let database = directory.path().join("journal.sqlite3");
    let old = remote(b"old", "rev-old")?;
    let new = remote(b"new", "rev-new")?;
    let operation_plan = operations(plan(
        &Baseline::Present(old.clone()),
        &Observation::Present(LocalFile::new(old.content.clone())),
        &Observation::Present(new.clone()),
    ))?;

    {
        let mut journal = Journal::open(&database)?;
        let _recorded =
            recorded_plan(journal.record_plan(Path::new("guarded.txt"), &operation_plan)?)?;
        staged_download(stage_download(
            &root,
            "guarded.txt",
            &new.content,
            Cursor::new(b"new"),
        )?)?;
        assert_eq!(
            prepare_replacement(&root, "guarded.txt", &old.content)?,
            ReplacementPreparation::Prepared
        );
        assert!(!root.join("guarded.txt").exists());
    }

    let mut reopened = Journal::open(&database)?;
    let report = replay_local_operations(&mut reopened, &root)?;
    assert_eq!(report.completed_operations, 1);
    assert!(report.blocked.is_empty());
    assert_eq!(std::fs::read(root.join("guarded.txt"))?, b"new");
    assert_eq!(
        reopened.baseline(Path::new("guarded.txt"))?,
        Some(Baseline::Present(new))
    );
    assert!(recovery_directory.read_dir()?.next().is_none());
    Ok(())
}

#[test]
fn deletion_replays_after_effect_but_before_journal_completion() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let recovery_directory = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&recovery_directory)?;
    std::fs::write(root.join("delete.txt"), b"delete me")?;
    let database = directory.path().join("journal.sqlite3");
    let old = remote(b"delete me", "rev-old")?;
    let operation_plan = operations(plan(
        &Baseline::Present(old.clone()),
        &Observation::Present(LocalFile::new(old.content.clone())),
        &Observation::ConfirmedAbsent,
    ))?;

    let delete = {
        let mut journal = Journal::open(&database)?;
        let recorded =
            recorded_plan(journal.record_plan(Path::new("delete.txt"), &operation_plan)?)?;
        assert_eq!(
            omabox::local::delete_local(&root, "delete.txt", &old.content)?,
            DeleteOutcome::Deleted
        );
        operation(&recorded, 0)?.clone()
    };

    let mut reopened = Journal::open(&database)?;
    let report = replay_local_operations(&mut reopened, &root)?;
    assert_eq!(report.completed_operations, 1);
    assert!(report.blocked.is_empty());
    assert_eq!(
        reopened.complete_operation(delete.id, Some(&Baseline::Absent))?,
        OperationCompletion::AlreadyCompleted
    );
    assert_eq!(reopened.baseline(Path::new("delete.txt"))?, None);
    assert!(recovery_directory.read_dir()?.next().is_none());
    Ok(())
}

#[test]
fn changed_delete_precondition_is_left_pending_without_a_copy() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let recovery_directory = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&recovery_directory)?;
    std::fs::write(root.join("changed.txt"), b"old")?;
    let database = directory.path().join("journal.sqlite3");
    let old = remote(b"old", "rev-old")?;
    let operation_plan = operations(plan(
        &Baseline::Present(old.clone()),
        &Observation::Present(LocalFile::new(old.content.clone())),
        &Observation::ConfirmedAbsent,
    ))?;
    let mut journal = Journal::open(&database)?;
    let _recorded = recorded_plan(journal.record_plan(Path::new("changed.txt"), &operation_plan)?)?;

    std::fs::write(root.join("changed.txt"), b"new local edit")?;
    assert_eq!(
        omabox::local::delete_local(&root, "changed.txt", &old.content)?,
        DeleteOutcome::PreconditionChanged {
            actual: Some(identity(b"new local edit")?)
        }
    );
    assert_eq!(std::fs::read(root.join("changed.txt"))?, b"new local edit");
    assert!(recovery_directory.read_dir()?.next().is_none());
    assert_eq!(journal.pending_plans()?.len(), 1);
    Ok(())
}

#[test]
fn deterministic_conflicts_never_overwrite_an_existing_side() -> Result<(), Box<dyn Error>> {
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    std::fs::create_dir_all(&root)?;
    std::fs::write(root.join("report.txt"), b"local")?;
    let remote = identity(b"remote")?;

    let first = materialize_conflict(
        &root,
        "report.txt",
        ConflictSide::Remote,
        &remote,
        Cursor::new(b"remote"),
    )?;
    let path = match first {
        ConflictOutcome::Created { path } => path,
        ConflictOutcome::AlreadyPresent { .. } | ConflictOutcome::ContentChanged { .. } => {
            return Err(io::Error::other("test expected a new conflict file").into());
        }
    };
    let second = materialize_conflict(
        &root,
        "report.txt",
        ConflictSide::Remote,
        &remote,
        Cursor::new(b"remote"),
    )?;
    assert_eq!(
        second,
        ConflictOutcome::AlreadyPresent { path: path.clone() }
    );
    assert_eq!(std::fs::read(root.join(path))?, b"remote");
    assert_eq!(std::fs::read(root.join("report.txt"))?, b"local");
    Ok(())
}
