//! The Rust version's answers for the Habu port's tests.
//!
//! `OMABOX_ORACLE=<dir> cargo test oracle -- --ignored` writes `json.tsv`,
//! `plan.tsv`, and `fold.tsv` into `<dir>`: one line per case, fields
//! separated by one tab, lines in byte order. The Habu tests read them to
//! show that the port writes the journal's JSON byte for byte as serde does
//! and decides as the planner decides. It also writes `schema.tsv`, a fresh
//! journal's `sqlite_master` in `rowid` order, and `journal.sqlite3`, a
//! journal written through `Journal`, with `journal.tsv`, its public reads.
//! This module lives under `journal` so it can serialise the private
//! hash-cache value and read `sqlite_master` itself.

use std::error::Error;
use std::fmt::Write as _;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use serde::Serialize;

use super::{
    BirthTime, BlockReason, DropboxBinding, DropboxBindingWrite, Journal, LocalFileFingerprint,
    LocalHashRecord, LocalHashValue, LocalObservationRecord, LocalRootActivation, LocalRootBinding,
    NoOpWrite, OperationCompletion, PlanBlock, PlanRecord, PlanWrite, RecoveryWrite,
    RemoteObservationRecord,
};
use crate::model::{
    Baseline, BlockedReason, CanonicalPath, Conflict, ContentIdentity, Decision,
    DirectoryCollision, DropboxRevision, LocalFile, LocalObservation, NoOpDecision, Observation,
    Operation, OperationPlan, RemoteFile, RemoteObservation, RemoteSubtree, UnknownReason,
};
use crate::planner::plan;

type Outcome = Result<(), Box<dyn Error>>;

/// Two distinct Dropbox content hashes.
const HASHES: [&str; 2] = [
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
];

/// Two distinct Dropbox revisions.
const REVISIONS: [&str; 2] = ["5f0a1b2c3d4e", "5f0a1b2c3d4f"];

/// A string payload that pins serde_json's escapes: a quote, a backslash,
/// a control character, DEL, a non-ASCII letter, and LINE SEPARATOR.
const ESCAPES: &str = "\"\\\u{1}\u{7f}\u{e9}\u{2028}";

const UNKNOWN_REASONS: [UnknownReason; 6] = [
    UnknownReason::Incomplete,
    UnknownReason::Inaccessible,
    UnknownReason::Unavailable,
    UnknownReason::Stale,
    UnknownReason::CursorReset,
    UnknownReason::Unsupported,
];

fn hash(index: usize) -> ContentIdentity {
    ContentIdentity::new(HASHES[index])
}

fn revision(index: usize) -> DropboxRevision {
    DropboxRevision::new(REVISIONS[index])
}

fn local_file(text: &str) -> LocalFile {
    LocalFile::new(ContentIdentity::new(text))
}

fn remote_file(content: &str, rev: &str) -> RemoteFile {
    RemoteFile::new(ContentIdentity::new(content), DropboxRevision::new(rev))
}

fn local_files() -> Vec<LocalFile> {
    (0..HASHES.len()).map(|h| LocalFile::new(hash(h))).collect()
}

fn remote_files() -> Vec<RemoteFile> {
    let mut files = Vec::new();
    for h in 0..HASHES.len() {
        for r in 0..REVISIONS.len() {
            files.push(RemoteFile::new(hash(h), revision(r)));
        }
    }
    files
}

/// The output directory `OMABOX_ORACLE` names.
fn oracle_dir() -> Result<PathBuf, Box<dyn Error>> {
    let dir =
        std::env::var_os("OMABOX_ORACLE").ok_or("set OMABOX_ORACLE to the output directory")?;
    Ok(PathBuf::from(dir))
}

/// Write `lines` to `<OMABOX_ORACLE>/<name>` in byte order, each ending in a
/// newline.
fn write_lines(name: &str, mut lines: Vec<String>) -> Outcome {
    lines.sort_unstable_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
    for pair in lines.windows(2) {
        if pair[0] == pair[1] {
            return Err(format!("{name}: duplicate line {}", pair[0]).into());
        }
    }
    write_ordered(name, &lines)
}

/// Write `lines` to `<OMABOX_ORACLE>/<name>` in the order given, each ending
/// in a newline.
fn write_ordered(name: &str, lines: &[String]) -> Outcome {
    let mut text = String::new();
    for line in lines {
        text.push_str(line);
        text.push('\n');
    }
    std::fs::write(oracle_dir()?.join(name), text)?;
    Ok(())
}

fn json<T: Serialize>(value: &T) -> Result<String, serde_json::Error> {
    serde_json::to_string(value)
}

fn json_line<T: Serialize>(key: &str, value: &T) -> Result<String, serde_json::Error> {
    Ok(format!("{key}\t{}", json(value)?))
}

#[test]
#[ignore = "writes the Habu port's test answers; run with OMABOX_ORACLE=<dir>"]
fn oracle_json() -> Outcome {
    let (h, r) = (HASHES[0], REVISIONS[0]);
    let file = local_file(h);
    let remote = remote_file(h, r);
    let mut lines = vec![
        json_line("ContentIdentity.value", &ContentIdentity::new(h))?,
        json_line(
            "ContentIdentity.value.escapes",
            &ContentIdentity::new(ESCAPES),
        )?,
        json_line("DropboxRevision.value", &DropboxRevision::new(r))?,
        json_line(
            "DropboxRevision.value.escapes",
            &DropboxRevision::new(ESCAPES),
        )?,
        json_line("LocalFile.value", &file)?,
        json_line("LocalFile.value.escapes", &local_file(ESCAPES))?,
        json_line("RemoteFile.value", &remote)?,
        json_line("RemoteFile.value.escapes", &remote_file(ESCAPES, ESCAPES))?,
        json_line("Baseline.Absent", &Baseline::Absent)?,
        json_line("Baseline.Present", &Baseline::Present(remote.clone()))?,
        json_line(
            "Baseline.Present.escapes",
            &Baseline::Present(remote_file(ESCAPES, ESCAPES)),
        )?,
        json_line("Baseline.Directory", &Baseline::Directory)?,
    ];
    for reason in UNKNOWN_REASONS {
        lines.push(json_line(&format!("UnknownReason.{reason:?}"), &reason)?);
    }

    let locals: [(&str, LocalObservation); 3] = [
        ("Present", Observation::Present(file.clone())),
        ("Directory", Observation::Directory),
        ("ConfirmedAbsent", Observation::ConfirmedAbsent),
    ];
    for (variant, observation) in &locals {
        lines.push(json_line(
            &format!("LocalObservation.{variant}"),
            observation,
        )?);
    }
    let remotes: [(&str, RemoteObservation); 3] = [
        ("Present", Observation::Present(remote.clone())),
        ("Directory", Observation::Directory),
        ("ConfirmedAbsent", Observation::ConfirmedAbsent),
    ];
    for (variant, observation) in &remotes {
        lines.push(json_line(
            &format!("RemoteObservation.{variant}"),
            observation,
        )?);
    }
    for reason in UNKNOWN_REASONS {
        let local: LocalObservation = Observation::Unknown(reason);
        let remote: RemoteObservation = Observation::Unknown(reason);
        lines.push(json_line(
            &format!("LocalObservation.Unknown.{reason:?}"),
            &local,
        )?);
        lines.push(json_line(
            &format!("RemoteObservation.Unknown.{reason:?}"),
            &remote,
        )?);
    }
    let local: LocalObservation = Observation::Present(local_file(ESCAPES));
    lines.push(json_line("LocalObservation.Present.escapes", &local)?);
    let remote_escapes: RemoteObservation = Observation::Present(remote_file(ESCAPES, ESCAPES));
    lines.push(json_line(
        "RemoteObservation.Present.escapes",
        &remote_escapes,
    )?);

    let other = remote_file(HASHES[1], REVISIONS[1]);
    let operations = [
        ("CreateLocalDirectory", Operation::CreateLocalDirectory),
        ("CreateRemoteDirectory", Operation::CreateRemoteDirectory),
        ("DeleteLocalDirectory", Operation::DeleteLocalDirectory),
        ("DeleteRemoteDirectory", Operation::DeleteRemoteDirectory),
        ("CreateRemote", Operation::CreateRemote { content: hash(0) }),
        (
            "InstallLocal",
            Operation::InstallLocal {
                source: remote.clone(),
            },
        ),
        (
            "PreserveLocal",
            Operation::PreserveLocal { file: file.clone() },
        ),
        (
            "ReplaceLocal",
            Operation::ReplaceLocal {
                source: other.clone(),
                expected_content: hash(0),
            },
        ),
        (
            "DeleteLocal",
            Operation::DeleteLocal {
                expected_content: hash(0),
            },
        ),
        (
            "PreserveRemote",
            Operation::PreserveRemote {
                file: remote.clone(),
            },
        ),
        (
            "ReplaceRemote",
            Operation::ReplaceRemote {
                content: hash(1),
                expected_revision: revision(0),
            },
        ),
        (
            "DeleteRemote",
            Operation::DeleteRemote {
                expected_revision: revision(0),
            },
        ),
    ];
    for (variant, operation) in &operations {
        lines.push(json_line(&format!("Operation.{variant}"), operation)?);
    }
    lines.push(json_line(
        "Operation.ReplaceLocal.escapes",
        &Operation::ReplaceLocal {
            source: remote_file(ESCAPES, ESCAPES),
            expected_content: ContentIdentity::new(ESCAPES),
        },
    )?);

    let conflicts = [
        (
            "InitialCollision",
            Conflict::InitialCollision {
                local: file.clone(),
                remote: other.clone(),
            },
        ),
        (
            "DivergentEdits",
            Conflict::DivergentEdits {
                local: file.clone(),
                remote: other.clone(),
            },
        ),
        (
            "LocalDeletionRemoteEdit",
            Conflict::LocalDeletionRemoteEdit { remote: other },
        ),
        (
            "RemoteDeletionLocalEdit",
            Conflict::RemoteDeletionLocalEdit { local: file },
        ),
    ];
    for (variant, conflict) in &conflicts {
        lines.push(json_line(&format!("Conflict.{variant}"), conflict)?);
    }
    lines.push(json_line(
        "Conflict.InitialCollision.escapes",
        &Conflict::InitialCollision {
            local: local_file(ESCAPES),
            remote: remote_file(ESCAPES, ESCAPES),
        },
    )?);

    let blocks = [
        ("UnsupportedFileSize", BlockReason::UnsupportedFileSize),
        (
            "RemoteRejected",
            BlockReason::RemoteRejected {
                tag: "insufficient_space".to_owned(),
            },
        ),
        (
            "DownloadUnavailable",
            BlockReason::DownloadUnavailable { status: 409 },
        ),
        (
            "DownloadVerificationFailed",
            BlockReason::DownloadVerificationFailed,
        ),
        ("StageOccupied", BlockReason::StageOccupied),
        ("LocalObjectInWay", BlockReason::LocalObjectInWay),
        ("RemoteObject", BlockReason::RemoteObject),
        ("ConflictCopyOccupied", BlockReason::ConflictCopyOccupied),
    ];
    for (variant, block) in &blocks {
        lines.push(json_line(&format!("BlockReason.{variant}"), block)?);
    }
    lines.push(json_line(
        "BlockReason.RemoteRejected.escapes",
        &BlockReason::RemoteRejected {
            tag: ESCAPES.to_owned(),
        },
    )?);

    let fingerprint = LocalFileFingerprint {
        inode: u64::MAX,
        size: 12_345,
        modified_seconds: -1,
        modified_nanoseconds: 999_999_999,
        changed_seconds: i64::MAX,
        changed_nanoseconds: 0,
    };
    lines.push(json_line(
        "LocalHashValue.value",
        &LocalHashValue {
            fingerprint: fingerprint.clone(),
            content: hash(0),
        },
    )?);
    lines.push(json_line(
        "LocalHashValue.value.escapes",
        &LocalHashValue {
            fingerprint,
            content: ContentIdentity::new(ESCAPES),
        },
    )?);
    write_lines("json.tsv", lines)
}

/// The decision's kind and payload, as `plan.tsv` records them.
fn decision_fields(decision: &Decision) -> Result<String, Box<dyn Error>> {
    Ok(match decision {
        Decision::NoOp(noop) => format!("noop\t{}", json(noop.baseline())?),
        Decision::Operations(operations) => match operations.operations() {
            [operation] => format!("operate\t{}", json(operation)?),
            other => return Err(format!("expected one operation, planned {other:?}").into()),
        },
        Decision::Blocked(
            BlockedReason::LocalUnknown(_)
            | BlockedReason::RemoteUnknown(_)
            | BlockedReason::BothUnknown { .. },
        ) => "blocked\tunknown".to_owned(),
        Decision::Blocked(BlockedReason::RemoteDirectoryOccupied) => "blocked\toccupied".to_owned(),
        Decision::Conflict(conflict) => format!("conflict\t{}", json(conflict)?),
        Decision::DirectoryCollision(DirectoryCollision::LocalFileRemoteDirectory { local }) => {
            format!("collision\tLocalFileRemoteDirectory\t{}", json(local)?)
        }
        Decision::DirectoryCollision(DirectoryCollision::LocalDirectoryRemoteFile { remote }) => {
            format!("collision\tLocalDirectoryRemoteFile\t{}", json(remote)?)
        }
    })
}

#[test]
#[ignore = "writes the Habu port's test answers; run with OMABOX_ORACLE=<dir>"]
fn oracle_plan() -> Outcome {
    let mut baselines = vec![Baseline::Absent, Baseline::Directory];
    baselines.extend(remote_files().into_iter().map(Baseline::Present));

    let mut locals: Vec<LocalObservation> = local_files()
        .into_iter()
        .map(Observation::Present)
        .collect();
    let mut remotes: Vec<RemoteObservation> = remote_files()
        .into_iter()
        .map(Observation::Present)
        .collect();
    locals.extend([Observation::Directory, Observation::ConfirmedAbsent]);
    remotes.extend([Observation::Directory, Observation::ConfirmedAbsent]);
    locals.extend(UNKNOWN_REASONS.map(Observation::Unknown));
    remotes.extend(UNKNOWN_REASONS.map(Observation::Unknown));

    // RemoteSubtree has no serde form; its variant names stand in as JSON
    // strings, the form serde gives a unit variant.
    let subtrees = [
        (RemoteSubtree::Empty, "\"Empty\""),
        (RemoteSubtree::Occupied, "\"Occupied\""),
    ];

    let mut lines = Vec::new();
    for baseline in &baselines {
        for local in &locals {
            for remote in &remotes {
                for (subtree, subtree_json) in subtrees {
                    let decision = plan(baseline, local, remote, subtree);
                    let mut line = String::new();
                    write!(
                        line,
                        "{}\t{}\t{}\t{subtree_json}\t{}",
                        json(baseline)?,
                        json(local)?,
                        json(remote)?,
                        decision_fields(&decision)?,
                    )?;
                    lines.push(line);
                }
            }
        }
    }
    write_lines("plan.tsv", lines)
}

fn hex(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push_str(&format!("{byte:02x}"));
    }
    text
}

#[test]
#[ignore = "writes the Habu port's test answers; run with OMABOX_ORACLE=<dir>"]
fn oracle_fold() -> Outcome {
    let texts = [
        // ASCII in mixed case, one component and several.
        "Report.TXT",
        "notes",
        "README",
        "A/B/C.Md",
        "MiXeD/CaSe/Path.Txt",
        "already/lower/case.txt",
        "Photos 2024/IMG_0001.JPG",
        // Greek: final and medial sigma.
        "\u{38c}\u{3a3}\u{39f}\u{3a3}",
        "\u{3a3}\u{391}\u{3a3}/\u{391}\u{3a3}",
        "\u{3a3}",
        "\u{39f}\u{394}\u{39f}\u{3a3}.txt",
        // Dotted capital I and plain capital I.
        "\u{130}",
        "\u{49}",
        "\u{130}stanbul/I\u{307}",
        // Sharp s and capital sharp s.
        "\u{df}",
        "\u{1e9e}",
        "Stra\u{df}e/STRA\u{1e9e}E",
        // Titlecase digraph and its upper and lower forms.
        "\u{1c5}",
        "\u{1c4}\u{1c6}",
        // Kelvin sign, Ohm sign, Angstrom sign.
        "\u{212a}",
        "\u{2126}",
        "\u{212b}",
        // Cherokee upper and lower.
        "\u{13a0}\u{13a1}",
        "\u{ab70}",
        // Georgian Mtavruli and Mkhedruli.
        "\u{1c90}\u{1c91}",
        "\u{10d0}",
        // Combining marks beside a precomposed letter.
        "E\u{301}",
        "\u{c9}",
        "A\u{30a}/O\u{308}\u{332}",
        // Emoji.
        "\u{1f600}",
        "Folder \u{1f4c1}/File",
        // Empty components, which Path iteration drops.
        "a//B",
        "A/",
        "",
    ];
    let mut inputs: Vec<Vec<u8>> = texts.iter().map(|text| text.as_bytes().to_vec()).collect();
    // A component that is not UTF-8 beside one that is.
    inputs.push(b"\xffAB/\xc3\x89T\xc3\xa9".to_vec());
    inputs.push(b"\xc9T\xc9/Caf\xe9".to_vec());

    let mut lines = Vec::new();
    for input in &inputs {
        let path = Path::new(std::ffi::OsStr::from_bytes(input));
        let folded = CanonicalPath::from_display(path);
        lines.push(format!("{}\t{}", hex(input), hex(folded.as_bytes())));
    }
    write_lines("fold.tsv", lines)
}

/// One `sqlite_master` field: NULL as empty, with newline, tab, and
/// backslash escaped.
fn schema_field(value: Option<String>) -> String {
    value.map_or_else(String::new, |text| {
        text.replace('\\', "\\\\")
            .replace('\n', "\\n")
            .replace('\t', "\\t")
    })
}

#[test]
#[ignore = "writes the Habu port's test answers; run with OMABOX_ORACLE=<dir>"]
fn oracle_schema() -> Outcome {
    let dir = tempfile::TempDir::new()?;
    let journal = Journal::open(dir.path().join("journal.sqlite3"))?;
    let mut statement = journal
        .connection
        .prepare("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY rowid")?;
    let rows = statement.query_map([], |row| {
        Ok([
            row.get::<_, Option<String>>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
        ])
    })?;
    let mut lines = Vec::new();
    for row in rows {
        let fields: Vec<String> = row?.into_iter().map(schema_field).collect();
        lines.push(fields.join("\t"));
    }
    let version = journal
        .connection
        .query_row("PRAGMA user_version", [], |row| row.get::<_, i64>(0))?;
    lines.push(format!("user_version\t{version}"));
    write_ordered("schema.tsv", &lines)
}

/// The no-op the planner decides for these observations.
fn planned_noop(
    baseline: &Baseline,
    local: &LocalObservation,
    remote: &RemoteObservation,
) -> Result<NoOpDecision, Box<dyn Error>> {
    match plan(baseline, local, remote, RemoteSubtree::Empty) {
        Decision::NoOp(noop) => Ok(noop),
        other => Err(format!("expected a no-op, planned {other:?}").into()),
    }
}

/// The operations the planner decides for these observations.
fn planned_operations(
    baseline: &Baseline,
    local: &LocalObservation,
    remote: &RemoteObservation,
) -> Result<OperationPlan, Box<dyn Error>> {
    match plan(baseline, local, remote, RemoteSubtree::Empty) {
        Decision::Operations(operations) => Ok(operations),
        other => Err(format!("expected operations, planned {other:?}").into()),
    }
}

fn recorded(write: PlanWrite) -> Result<PlanRecord, Box<dyn Error>> {
    match write {
        PlanWrite::Recorded(plan) => Ok(plan),
        PlanWrite::AlreadyLive(plan) => Err(format!("plan already live: {plan:?}").into()),
    }
}

fn expect<T: std::fmt::Debug + PartialEq>(what: &str, got: T, want: T) -> Outcome {
    if got == want {
        Ok(())
    } else {
        Err(format!("{what}: expected {want:?}, got {got:?}").into())
    }
}

/// The local root `journal.sqlite3` is bound to.
fn oracle_root() -> LocalRootBinding {
    LocalRootBinding {
        canonical_path: PathBuf::from("/home/user/Dropbox"),
        inode: 4242,
        birth: Some(BirthTime {
            seconds: 1_700_000_000,
            nanoseconds: 123_456_789,
        }),
        subvolume: Some(256),
    }
}

/// Write `journal.sqlite3` through `Journal` alone.
fn write_journal(path: &Path) -> Outcome {
    let mut journal = Journal::open(path)?;
    let binding = DropboxBinding {
        account_id: "dbid:FAKE-ACCOUNT-0000".to_owned(),
        root_namespace_id: "1234567890".to_owned(),
        remote_root: "/Omabox".to_owned(),
    };
    expect(
        "bind_dropbox_root",
        journal.bind_dropbox_root(&binding)?,
        DropboxBindingWrite::Bound,
    )?;
    let root = oracle_root();
    let activation = journal.activate_local_root(&root)?;
    if !matches!(activation, LocalRootActivation::Activated(_)) {
        return Err(format!("activate_local_root: {activation:?}").into());
    }

    let (docs, file_a) = (Path::new("Docs"), Path::new("Docs/A.txt"));
    let locals = [
        (docs, Observation::Directory),
        (file_a, Observation::Present(LocalFile::new(hash(0)))),
        (
            Path::new("Docs/Locked"),
            Observation::Unknown(UnknownReason::Inaccessible),
        ),
    ];
    let locals: Vec<LocalObservationRecord> = locals
        .into_iter()
        .map(|(path, observation)| LocalObservationRecord {
            path: path.to_path_buf(),
            observation,
        })
        .collect();
    let hashes = [LocalHashRecord {
        path: file_a.to_path_buf(),
        fingerprint: LocalFileFingerprint {
            inode: 4243,
            size: 0,
            modified_seconds: 1_700_000_100,
            modified_nanoseconds: 500,
            changed_seconds: 1_700_000_200,
            changed_nanoseconds: 600,
        },
        content: hash(0),
    }];
    expect(
        "publish_local_scan",
        journal.publish_local_scan(&root, &locals, &hashes)?,
        true,
    )?;

    let remotes = [
        (docs, Observation::Directory),
        (
            file_a,
            Observation::Present(RemoteFile::new(hash(0), revision(0))),
        ),
        (
            Path::new("Restricted"),
            Observation::Unknown(UnknownReason::Inaccessible),
        ),
    ];
    let remotes: Vec<RemoteObservationRecord> = remotes
        .into_iter()
        .map(|(path, observation)| RemoteObservationRecord {
            canonical_path: CanonicalPath::from_display(path),
            path: path.to_path_buf(),
            observation,
        })
        .collect();
    journal.publish_remote_inventory("AAFakeCursor0001", &remotes)?;

    // Baselines: Directory and Present by no-op; Absent by completing a
    // remote deletion, which removes the path's row.
    let local_a: LocalObservation = Observation::Present(LocalFile::new(hash(0)));
    let remote_a: RemoteObservation = Observation::Present(RemoteFile::new(hash(0), revision(0)));
    for (path, local, remote) in [
        (docs, Observation::Directory, Observation::Directory),
        (file_a, local_a, remote_a),
    ] {
        let noop = planned_noop(&Baseline::Absent, &local, &remote)?;
        expect(
            "record_noop",
            journal.record_noop(path, &noop)?,
            NoOpWrite::Recorded,
        )?;
    }
    let gone = Path::new("Old/Gone.txt");
    let gone_file = RemoteFile::new(hash(1), revision(1));
    let noop = planned_noop(
        &Baseline::Absent,
        &Observation::Present(LocalFile::new(hash(1))),
        &Observation::Present(gone_file.clone()),
    )?;
    journal.record_noop(gone, &noop)?;
    let delete = planned_operations(
        &Baseline::Present(gone_file.clone()),
        &Observation::ConfirmedAbsent,
        &Observation::Present(gone_file),
    )?;
    let delete = recorded(journal.record_plan(gone, &delete)?)?;
    expect(
        "complete Old/Gone.txt",
        journal.complete_operation(delete.operations[0].id, Some(&Baseline::Absent))?,
        OperationCompletion::PlanCompleted,
    )?;

    // A pending upload and a blocked download.
    let upload = planned_operations(
        &Baseline::Absent,
        &Observation::Present(LocalFile::new(hash(1))),
        &Observation::ConfirmedAbsent,
    )?;
    recorded(journal.record_plan(Path::new("Docs/New.txt"), &upload)?)?;
    let download = planned_operations(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(RemoteFile::new(hash(1), revision(1))),
    )?;
    let download = recorded(journal.record_plan(Path::new("Docs/Big.bin"), &download)?)?;
    expect(
        "block_plan",
        journal.block_plan(
            download.id,
            &BlockReason::DownloadUnavailable { status: 409 },
            1_700_003_600,
        )?,
        PlanBlock::Blocked,
    )?;

    journal.record_conflict(
        Path::new("Docs/Both.txt"),
        &Conflict::DivergentEdits {
            local: LocalFile::new(hash(0)),
            remote: RemoteFile::new(hash(1), revision(1)),
        },
    )?;

    // Legacy recoveries: one pending behind a completed preservation, one
    // completed with its plan.
    let kept = RemoteFile::new(hash(0), revision(0));
    let pending = OperationPlan::new(vec![
        Operation::PreserveRemote { file: kept },
        Operation::DeleteRemote {
            expected_revision: revision(0),
        },
    ]);
    let pending = recorded(journal.record_plan(Path::new("Trash/Old1.txt"), &pending)?)?;
    let intent = journal.record_recovery_intent(
        pending.operations[1].id,
        Path::new(".omabox-recovery/Trash/Old1.txt"),
    )?;
    if !matches!(intent, RecoveryWrite::Recorded(_)) {
        return Err(format!("record_recovery_intent: {intent:?}").into());
    }
    expect(
        "complete Trash/Old1.txt preservation",
        journal.complete_operation(pending.operations[0].id, None)?,
        OperationCompletion::OperationCompleted,
    )?;
    let done = OperationPlan::new(vec![
        Operation::PreserveLocal {
            file: LocalFile::new(hash(1)),
        },
        Operation::DeleteLocal {
            expected_content: hash(1),
        },
    ]);
    let done = recorded(journal.record_plan(Path::new("Trash/Old2.txt"), &done)?)?;
    let intent = journal.record_recovery_intent(
        done.operations[1].id,
        Path::new(".omabox-recovery/Trash/Old2.txt"),
    )?;
    if !matches!(intent, RecoveryWrite::Recorded(_)) {
        return Err(format!("record_recovery_intent: {intent:?}").into());
    }
    expect(
        "complete Trash/Old2.txt preservation",
        journal.complete_operation(done.operations[0].id, None)?,
        OperationCompletion::OperationCompleted,
    )?;
    expect(
        "complete Trash/Old2.txt deletion",
        journal.complete_operation(done.operations[1].id, Some(&Baseline::Absent))?,
        OperationCompletion::PlanCompleted,
    )?;
    Ok(())
}

#[test]
#[ignore = "writes the Habu port's test answers; run with OMABOX_ORACLE=<dir>"]
fn oracle_journal() -> Outcome {
    let path = oracle_dir()?.join("journal.sqlite3");
    for suffix in ["", "-journal", "-wal", "-shm"] {
        let mut name = path.clone().into_os_string();
        name.push(suffix);
        if let Err(error) = std::fs::remove_file(&name)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            return Err(error.into());
        }
    }
    write_journal(&path)?;

    // Read back what the closed journal holds, without changing it.
    let mut journal = Journal::open_read_only(&path)?;
    let mut lines = vec![
        format!("dropbox_binding\t{:?}", journal.dropbox_binding()?),
        format!("local_root_binding\t{:?}", journal.local_root_binding()?),
        format!("local_inventory\t{:?}", journal.local_inventory()?),
        format!("remote_inventory\t{:?}", journal.remote_inventory()?),
        format!("remote_cursor\t{:?}", journal.remote_cursor()?),
        format!("baseline_paths\t{:?}", journal.baseline_paths()?),
        format!("pending_plans\t{:?}", journal.pending_plans()?),
        format!("blocked_plans\t{:?}", journal.blocked_plans()?),
        format!("conflicts\t{:?}", journal.conflicts()?),
        format!("pending_recoveries\t{:?}", journal.pending_recoveries()?),
        format!(
            "completed_recoveries\t{:?}",
            journal.completed_recoveries()?
        ),
        format!(
            "pending_upload_content\t{:?}",
            journal.pending_upload_content()?
        ),
    ];
    for name in ["Docs", "Docs/A.txt", "Old/Gone.txt"] {
        lines.push(format!(
            "baseline({name})\t{:?}",
            journal.baseline(Path::new(name))?
        ));
    }
    drop(journal);
    for suffix in ["-journal", "-wal", "-shm"] {
        let mut name = path.clone().into_os_string();
        name.push(suffix);
        if Path::new(&name).exists() {
            return Err(format!("{} outlived the journal", Path::new(&name).display()).into());
        }
    }
    write_lines("journal.tsv", lines)
}
