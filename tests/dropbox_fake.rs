use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::{FileExt as _, FileTypeExt as _, PermissionsExt as _};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use omabox::auth::{AccessToken, AuthError, OAuthClient, RefreshToken};
use omabox::dropbox::{
    DropboxClient, DropboxEndpoints, DropboxError, DropboxLink, DropboxRoot, InventoryRefresh,
    LongPollWakeup, MutationOutcome, RemotePathState,
};
use omabox::journal::{
    DropboxBinding, Journal, LocalRootBinding, PlanWrite, RemoteInventory, RemoteObservationRecord,
};
use omabox::local::{
    InstallOutcome, ScanPublication, StageOutcome, StagedUpload, dropbox_content_hash,
    install_download, scan_and_publish, stage_download, stage_upload,
};
use omabox::model::{
    Baseline, Conflict, ContentIdentity, Decision, DropboxRevision, LocalFile, Observation,
    OperationPlan, RemoteFile, UnknownReason,
};
use omabox::planner::plan;
use omabox::reconcile::{
    ExactDownloadPool, ReconcileError, ReconcileOutcome, reconcile_once, replay_pending,
};
use omabox::recovery::{ReplayBlocked, ReplayReport, replay_remote_operations};
use omabox::runtime_status::{
    TransferDirection, TransferEvent, TransferObserver, TransferProgress,
};
use serde_json::json;
use tempfile::TempDir;

fn drive_replay(
    journal: &mut Journal,
    client: &DropboxClient,
    downloads: &mut ExactDownloadPool,
    root: &Path,
    staging: &Path,
) -> io::Result<Result<ReplayReport, ReconcileError>> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        match replay_pending(journal, client, downloads, root, staging) {
            Ok(report)
                if report
                    .blocked
                    .iter()
                    .any(|blocked| matches!(blocked, ReplayBlocked::DownloadRequired { .. })) => {}
            outcome => return Ok(outcome),
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "background download replay did not settle",
            ));
        }
        thread::yield_now();
    }
}

#[test]
fn oauth_listing_longpoll_and_exact_download_use_documented_protocol() -> Result<(), Box<dyn Error>>
{
    let bytes = b"verified Dropbox bytes";
    let identity = dropbox_content_hash(bytes.as_slice())?;
    let download_metadata = json!({
        ".tag": "file",
        "name": "Alpha.txt",
        "path_lower": "/sync/alpha.txt",
        "path_display": "/Sync/Alpha.txt",
        "rev": "rev-a",
        "content_hash": identity.as_str(),
        "size": bytes.len()
    })
    .to_string();
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "access_token": "opaque-access-a",
            "refresh_token": "opaque-refresh-a",
            "expires_in": 14400,
            "account_id": "account-a"
        })),
        FakeResponse::json(json!({
            "access_token": "opaque-access-b",
            "expires_in": 14400
        })),
        FakeResponse::json(json!({
            "account_id": "account-a",
            "root_info": {"root_namespace_id": "namespace-a"}
        })),
        FakeResponse::json(json!({
            ".tag": "folder",
            "path_lower": "/sync",
            "path_display": "/Sync"
        })),
        FakeResponse::json(json!({
            "account_id": "account-a",
            "root_info": {"root_namespace_id": "namespace-a"}
        })),
        FakeResponse::json(json!({
            ".tag": "folder",
            "path_lower": "/sync",
            "path_display": "/Sync"
        })),
        FakeResponse::json(json!({
            "entries": [
                {
                    ".tag": "folder",
                    "path_lower": "/sync/folder",
                    "path_display": "/Sync/Folder"
                },
                {
                    ".tag": "file",
                    "path_lower": "/sync/alpha.txt",
                    "path_display": "/Sync/Alpha.txt",
                    "rev": "rev-a",
                    "content_hash": identity.as_str(),
                    "is_downloadable": true
                }
            ],
            "cursor": "cursor-a",
            "has_more": true
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/sync/paper",
                "path_display": "/Sync/Paper",
                "rev": "rev-paper",
                "is_downloadable": false
            }],
            "cursor": "cursor-b",
            "has_more": false
        })),
        FakeResponse::json(json!({"changes": true, "backoff": 2})),
        FakeResponse::bytes(bytes.to_vec())
            .without_content_length()
            .header("Dropbox-API-Result", download_metadata),
    ])?;
    let endpoints = server.endpoints();
    let oauth = OAuthClient::with_endpoints("app-key", endpoints.clone());
    let pending = oauth.begin()?;
    let grant = oauth.exchange(pending, "authorization-code")?;
    assert_eq!(grant.account_id, "account-a");
    let refreshed = oauth.refresh(&grant.refresh_token)?;
    let client = match DropboxClient::link_with_endpoints(
        refreshed.access_token,
        grant.account_id,
        "/Sync",
        endpoints,
    )? {
        DropboxLink::Linked(client) => *client,
        DropboxLink::AccountChanged => {
            return Err(std::io::Error::other("authorized account changed during link").into());
        }
    };

    let state_directory = TempDir::new()?;
    let mut journal = Journal::open(state_directory.path().join("journal.sqlite3"))?;
    assert_eq!(
        client.refresh_inventory(&mut journal)?,
        InventoryRefresh::Published
    );
    let inventory = journal.remote_inventory()?;
    assert_eq!(inventory.cursor.as_deref(), Some("cursor-b"));
    assert_eq!(inventory.observations.len(), 3);
    assert_eq!(
        observation(&inventory, Path::new("Folder")),
        Some(&Observation::Directory)
    );
    assert_eq!(
        observation(&inventory, Path::new("Paper")),
        Some(&Observation::Unknown(UnknownReason::Unsupported))
    );

    assert_eq!(
        client.long_poll("cursor-b", Duration::from_secs(30))?,
        omabox::dropbox::LongPollWakeup::Changes {
            backoff: Some(Duration::from_secs(2))
        }
    );

    let sync_root = TempDir::new()?;
    let remote = RemoteFile::new(identity.clone(), DropboxRevision::new("rev-a"));
    assert!(matches!(
        client.stage_exact_download(sync_root.path(), "Alpha.txt", &remote)?,
        StageOutcome::Staged(())
    ));
    assert_eq!(
        install_download(sync_root.path(), "Alpha.txt", &identity, None)?,
        InstallOutcome::Installed
    );
    assert_eq!(std::fs::read(sync_root.path().join("Alpha.txt"))?, bytes);

    let requests = server.finish()?;
    assert_eq!(requests.len(), 10);
    assert_eq!(requests[0].path, "/oauth2/token");
    assert!(text_body(&requests[0])?.contains("grant_type=authorization_code"));
    assert!(text_body(&requests[0])?.contains("code_verifier="));
    assert!(!text_body(&requests[0])?.contains("redirect_uri"));
    assert!(!text_body(&requests[0])?.contains("state="));
    assert!(text_body(&requests[1])?.contains("grant_type=refresh_token"));
    assert_eq!(requests[2].path, "/2/users/get_current_account");
    assert_eq!(requests[3].path, "/2/files/get_metadata");
    assert_eq!(requests[4].path, "/2/users/get_current_account");
    assert_eq!(requests[5].path, "/2/files/get_metadata");
    assert_eq!(requests[6].path, "/2/files/list_folder");
    assert_eq!(requests[7].path, "/2/files/list_folder/continue");
    assert_eq!(requests[8].path, "/2/files/list_folder/longpoll");
    assert_eq!(requests[9].path, "/2/files/download");
    assert!(header(&requests[2], "authorization").is_some());
    assert!(header(&requests[2], "dropbox-api-path-root").is_none());
    assert_eq!(
        header(&requests[3], "dropbox-api-path-root"),
        Some(r#"{".tag":"root","root":"namespace-a"}"#)
    );
    assert!(
        header(&requests[9], "dropbox-api-arg")
            .is_some_and(|value| value.contains(r#""path":"rev:rev-a""#))
    );
    Ok(())
}

#[test]
fn exact_download_retry_reuses_a_stage_without_consuming_the_body() -> Result<(), Box<dyn Error>> {
    let bytes = b"already staged Dropbox bytes";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("staged-revision"));
    let metadata = download_metadata(
        "staged.txt",
        remote.revision.as_str(),
        &content,
        bytes.len(),
    );
    let server = FakeServer::start(vec![
        FakeResponse::bytes(bytes.to_vec()).header("Dropbox-API-Result", metadata),
    ])?;
    let client = fake_client(&server, "opaque-access-staged")?;
    let root = TempDir::new()?;

    assert!(matches!(
        client.stage_exact_download(root.path(), Path::new("staged.txt"), &remote)?,
        StageOutcome::Staged(())
    ));
    assert!(matches!(
        client.stage_exact_download(root.path(), Path::new("staged.txt"), &remote)?,
        StageOutcome::AlreadyStaged(())
    ));
    assert_eq!(server.finish()?.len(), 1);
    Ok(())
}

#[test]
fn exact_download_stage_race_still_counts_the_response_body() -> Result<(), Box<dyn Error>> {
    let bytes = b"complete expected Dropbox bytes";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("raced-revision"));
    let response = FakeResponse::bytes(b"short".to_vec())
        .header(
            "Dropbox-API-Result",
            download_metadata("raced.txt", remote.revision.as_str(), &content, bytes.len()),
        )
        .without_content_length();
    let (response, gate) = response.gated();
    let server = FakeServer::start(vec![response])?;
    let client = fake_client(&server, "opaque-access-raced-stage")?;
    let root = TempDir::new()?;
    let target = Path::new("raced.txt");

    let outcome = thread::scope(|scope| -> Result<_, Box<dyn Error>> {
        let worker = thread::Builder::new().spawn_scoped(scope, || {
            client.stage_exact_download(root.path(), target, &remote)
        })?;
        gate.request_received.recv().map_err(|_| {
            io::Error::other("fake Dropbox server stopped before receiving the request")
        })?;
        let staged = stage_download(root.path(), target, &content, bytes.as_slice());
        let release = gate
            .release_response
            .send(())
            .map_err(|_| io::Error::other("fake Dropbox response worker stopped before release"));
        assert!(matches!(staged?, StageOutcome::Staged(())));
        release?;
        worker
            .join()
            .map_err(|_| io::Error::other("exact-download worker stopped unexpectedly"))
            .map_err(Into::into)
    })?;

    assert!(matches!(
        outcome,
        Err(DropboxError::DownloadedLengthChanged)
    ));
    assert_eq!(server.finish()?.len(), 1);
    Ok(())
}

#[test]
fn one_reconciliation_pass_synchronizes_files_in_both_directions() -> Result<(), Box<dyn Error>> {
    let upload_bytes = b"local upload";
    let download_bytes = b"remote download";
    let upload_content = dropbox_content_hash(upload_bytes.as_slice())?;
    let download_content = dropbox_content_hash(download_bytes.as_slice())?;
    let downloaded = RemoteFile::new(
        download_content.clone(),
        DropboxRevision::new("rev-download"),
    );
    let uploaded = RemoteFile::new(upload_content.clone(), DropboxRevision::new("rev-upload"));
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [file_metadata(
                "/download.txt",
                "/download.txt",
                "rev-download",
                &download_content,
            )],
            "cursor": "cursor-complete",
            "has_more": false
        })),
        FakeResponse::bytes(download_bytes.to_vec())
            .header(
                "Dropbox-API-Result",
                download_metadata(
                    "download.txt",
                    "rev-download",
                    &download_content,
                    download_bytes.len(),
                ),
            )
            .for_path("/2/files/download"),
        FakeResponse::json(file_metadata(
            "/upload.txt",
            "/upload.txt",
            "rev-upload",
            &upload_content,
        ))
        .for_path("/2/files/upload"),
    ])?;
    let transfers = Arc::new(Mutex::new(Vec::new()));
    let captured = Arc::clone(&transfers);
    let observer: TransferObserver = Arc::new(move |sample| {
        if let Ok(mut samples) = captured.lock() {
            samples.push(sample);
        }
    });
    let client =
        Arc::new(fake_client(&server, "opaque-access-reconcile")?.with_transfer_observer(observer));
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("upload.txt"), upload_bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("stable fixture requested a fresh observation").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable fixture changed its local root").into());
        }
    };

    assert_eq!(report.planned, 2);
    assert_eq!(report.replayed_operations, 1);
    assert_eq!(report.blocked, 1);
    assert_eq!(report.conflicts, 0);
    let completed_download = drive_replay(&mut journal, &client, &mut downloads, &root, &staging)??;
    assert_eq!(completed_download.completed_operations, 1);
    assert_eq!(std::fs::read(root.join("download.txt"))?, download_bytes);
    assert_eq!(
        journal.baseline(Path::new("download.txt"))?,
        Some(Baseline::Present(downloaded))
    );
    assert_eq!(
        journal.baseline(Path::new("upload.txt"))?,
        Some(Baseline::Present(uploaded))
    );
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.conflicts()?.is_empty());
    let transfers = transfers
        .lock()
        .map_err(|_| io::Error::other("recorded transfer lock was poisoned"))?;
    let download_progress = TransferProgress::new(
        TransferDirection::Download,
        Path::new("download.txt"),
        u64::try_from(download_bytes.len())?,
        Some(u64::try_from(download_bytes.len())?),
    );
    let upload_progress = TransferProgress::new(
        TransferDirection::Upload,
        Path::new("upload.txt"),
        u64::try_from(upload_bytes.len())?,
        Some(u64::try_from(upload_bytes.len())?),
    );
    assert!(transfers.contains(&TransferEvent::Progress(download_progress.clone())));
    assert!(transfers.contains(&TransferEvent::Progress(upload_progress.clone())));
    assert!(transfers.contains(&TransferEvent::Finished(download_progress)));
    assert!(transfers.contains(&TransferEvent::Finished(upload_progress)));

    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
    assert_eq!(requests[0].path, "/2/users/get_current_account");
    assert_eq!(requests[1].path, "/2/files/list_folder");
    let download_request = requests[2..]
        .iter()
        .find(|request| request.path == "/2/files/download")
        .ok_or_else(|| io::Error::other("missing concurrent download request"))?;
    let upload_request = requests[2..]
        .iter()
        .find(|request| request.path == "/2/files/upload")
        .ok_or_else(|| io::Error::other("missing concurrent upload request"))?;
    assert!(download_request.body.is_empty());
    assert_eq!(upload_request.body, upload_bytes);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(required_header(
            upload_request,
            "dropbox-api-arg",
        )?)?,
        json!({
            "path": "/upload.txt",
            "mode": "add",
            "autorename": false,
            "strict_conflict": true,
            "content_hash": upload_content.as_str()
        })
    );
    Ok(())
}

#[test]
fn later_edits_sync_and_divergence_preserves_both_sides() -> Result<(), Box<dyn Error>> {
    let old_bytes = b"shared baseline";
    let local_bytes = b"later local edit";
    let remote_bytes = b"later Dropbox edit";
    let local_conflict_bytes = b"divergent local edit";
    let remote_conflict_bytes = b"divergent Dropbox edit";
    let old = RemoteFile::new(
        dropbox_content_hash(old_bytes.as_slice())?,
        DropboxRevision::new("rev-old"),
    );
    let local_update = RemoteFile::new(
        dropbox_content_hash(local_bytes.as_slice())?,
        DropboxRevision::new("rev-local-update"),
    );
    let remote_update = RemoteFile::new(
        dropbox_content_hash(remote_bytes.as_slice())?,
        DropboxRevision::new("rev-remote-update"),
    );
    let local_conflict = LocalFile::new(dropbox_content_hash(local_conflict_bytes.as_slice())?);
    let remote_conflict = RemoteFile::new(
        dropbox_content_hash(remote_conflict_bytes.as_slice())?,
        DropboxRevision::new("rev-remote-conflict"),
    );
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [
                file_metadata(
                    "/a-local-update.txt",
                    "/a-local-update.txt",
                    old.revision.as_str(),
                    &old.content,
                ),
                file_metadata(
                    "/b-remote-update.txt",
                    "/b-remote-update.txt",
                    remote_update.revision.as_str(),
                    &remote_update.content,
                ),
                file_metadata(
                    "/c-diverged.txt",
                    "/c-diverged.txt",
                    remote_conflict.revision.as_str(),
                    &remote_conflict.content,
                )
            ],
            "cursor": "cursor-after-edits",
            "has_more": false
        })),
        FakeResponse::bytes(remote_conflict_bytes.to_vec())
            .header(
                "Dropbox-API-Result",
                download_metadata(
                    "c-diverged.txt",
                    remote_conflict.revision.as_str(),
                    &remote_conflict.content,
                    remote_conflict_bytes.len(),
                ),
            )
            .for_path("/2/files/download"),
        FakeResponse::bytes(remote_bytes.to_vec())
            .header(
                "Dropbox-API-Result",
                download_metadata(
                    "b-remote-update.txt",
                    remote_update.revision.as_str(),
                    &remote_update.content,
                    remote_bytes.len(),
                ),
            )
            .for_path("/2/files/download"),
        FakeResponse::json(file_metadata(
            "/a-local-update.txt",
            "/a-local-update.txt",
            local_update.revision.as_str(),
            &local_update.content,
        ))
        .for_path("/2/files/upload"),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-later-edits")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("a-local-update.txt"), local_bytes)?;
    std::fs::write(root.join("b-remote-update.txt"), old_bytes)?;
    std::fs::write(root.join("c-diverged.txt"), local_conflict_bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    for path in [
        Path::new("a-local-update.txt"),
        Path::new("b-remote-update.txt"),
        Path::new("c-diverged.txt"),
    ] {
        seed_baseline(&mut journal, path, &old)?;
    }

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(
                io::Error::other("stable later edits requested a fresh observation").into(),
            );
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable fixture changed its local root").into());
        }
    };
    assert_eq!(report.planned, 2);
    assert_eq!(report.replayed_operations, 1);
    assert_eq!(report.blocked, 1);
    assert_eq!(report.conflicts, 1);
    let completed_download = drive_replay(&mut journal, &client, &mut downloads, &root, &staging)??;
    assert_eq!(completed_download.completed_operations, 1);

    assert_eq!(std::fs::read(root.join("a-local-update.txt"))?, local_bytes);
    assert_eq!(
        std::fs::read(root.join("b-remote-update.txt"))?,
        remote_bytes
    );
    assert_eq!(
        std::fs::read(root.join("c-diverged.txt"))?,
        local_conflict_bytes
    );
    assert_eq!(
        journal.baseline(Path::new("a-local-update.txt"))?,
        Some(Baseline::Present(local_update))
    );
    assert_eq!(
        journal.baseline(Path::new("b-remote-update.txt"))?,
        Some(Baseline::Present(remote_update))
    );
    assert_eq!(
        journal.baseline(Path::new("c-diverged.txt"))?,
        Some(Baseline::Present(old))
    );
    let conflicts = journal.conflicts()?;
    assert_eq!(conflicts.len(), 1);
    assert_eq!(conflicts[0].path, Path::new("c-diverged.txt"));
    assert_eq!(
        conflicts[0].conflict,
        Conflict::DivergentEdits {
            local: local_conflict,
            remote: remote_conflict,
        }
    );
    assert_eq!(
        conflict_bytes(&root)?,
        vec![
            remote_conflict_bytes.to_vec(),
            local_conflict_bytes.to_vec()
        ]
    );
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.pending_recoveries()?.is_empty());
    assert!(journal.completed_recoveries()?.is_empty());
    assert!(recovery.read_dir()?.next().is_none());

    let requests = server.finish()?;
    assert_eq!(requests.len(), 5);
    assert!(
        requests
            .iter()
            .all(|request| request.path != "/2/files/delete_v2")
    );
    let upload = requests
        .iter()
        .find(|request| request.path == "/2/files/upload")
        .ok_or_else(|| io::Error::other("missing conditional update request"))?;
    assert_eq!(upload.body, local_bytes);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(required_header(upload, "dropbox-api-arg")?)?,
        json!({
            "path": "/a-local-update.txt",
            "mode": {".tag": "update", "update": "rev-old"},
            "autorename": false,
            "strict_conflict": true,
            "content_hash": dropbox_content_hash(local_bytes.as_slice())?.as_str()
        })
    );
    let download_revisions = requests
        .iter()
        .filter(|request| request.path == "/2/files/download")
        .map(|request| required_header(request, "dropbox-api-arg"))
        .collect::<Result<Vec<_>, _>>()?;
    assert_eq!(download_revisions.len(), 2);
    assert!(
        download_revisions
            .iter()
            .any(|header| header.contains("rev:rev-remote-update"))
    );
    assert!(
        download_revisions
            .iter()
            .any(|header| header.contains("rev:rev-remote-conflict"))
    );
    Ok(())
}

#[test]
fn later_deletions_sync_in_both_directions() -> Result<(), Box<dyn Error>> {
    let old_bytes = b"shared deletion baseline";
    let old = RemoteFile::new(
        dropbox_content_hash(old_bytes.as_slice())?,
        DropboxRevision::new("rev-delete-baseline"),
    );
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [file_metadata(
                "/local-deleted.txt",
                "/local-deleted.txt",
                old.revision.as_str(),
                &old.content,
            )],
            "cursor": "cursor-after-deletions",
            "has_more": false
        })),
        FakeResponse::json(json!({
            "metadata": file_metadata(
                "/local-deleted.txt",
                "/local-deleted.txt",
                old.revision.as_str(),
                &old.content,
            )
        }))
        .for_path("/2/files/delete_v2"),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-later-deletions")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("dropbox-deleted.txt"), old_bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    for path in [
        Path::new("local-deleted.txt"),
        Path::new("dropbox-deleted.txt"),
    ] {
        seed_baseline(&mut journal, path, &old)?;
    }

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("stable deletions requested a fresh observation").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable fixture changed its local root").into());
        }
    };
    assert_eq!(report.planned, 2);
    assert_eq!(report.replayed_operations, 2);
    assert_eq!(report.blocked, 0);
    assert_eq!(report.conflicts, 0);
    assert!(!root.join("local-deleted.txt").exists());
    assert!(!root.join("dropbox-deleted.txt").exists());
    assert_eq!(journal.baseline(Path::new("local-deleted.txt"))?, None);
    assert_eq!(journal.baseline(Path::new("dropbox-deleted.txt"))?, None);
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.conflicts()?.is_empty());
    assert!(recovery.read_dir()?.next().is_none());

    let requests = server.finish()?;
    assert_eq!(requests.len(), 3);
    let deletion = requests
        .iter()
        .find(|request| request.path == "/2/files/delete_v2")
        .ok_or_else(|| io::Error::other("missing conditional Dropbox deletion"))?;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&deletion.body)?,
        json!({
            "path": "/local-deleted.txt",
            "parent_rev": "rev-delete-baseline"
        })
    );
    assert_eq!(
        requests
            .iter()
            .filter(|request| request.path == "/2/files/delete_v2")
            .count(),
        1
    );
    Ok(())
}

#[test]
fn one_reconciliation_pass_synchronizes_empty_and_nested_directories() -> Result<(), Box<dyn Error>>
{
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [
                folder_metadata("/remote", "/remote"),
                folder_metadata("/remote/child", "/remote/child")
            ],
            "cursor": "directories",
            "has_more": false
        })),
        FakeResponse::json(json!({"metadata": folder_metadata("/local", "/local")})),
        FakeResponse::json(json!({"metadata": folder_metadata("/local", "/local")})),
        FakeResponse::json(json!({
            "metadata": folder_metadata("/local/child", "/local/child")
        })),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-directories")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("local/child"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("stable directories requested a fresh scan").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable directory root changed").into());
        }
    };

    assert_eq!(report.planned, 4);
    assert_eq!(report.replayed_operations, 4);
    assert_eq!(report.blocked, 0);
    for path in ["local", "local/child", "remote", "remote/child"] {
        assert!(root.join(path).is_dir());
        assert_eq!(
            journal.baseline(Path::new(path))?,
            Some(Baseline::Directory)
        );
    }
    assert!(journal.pending_plans()?.is_empty());
    let requests = server.finish()?;
    assert_eq!(requests.len(), 5);
    assert_eq!(
        requests
            .iter()
            .filter(|request| request.path == "/2/files/create_folder_v2")
            .count(),
        3
    );
    Ok(())
}

#[test]
fn fresh_download_uses_parent_directory_casing_without_remote_writes() -> Result<(), Box<dyn Error>>
{
    let bytes = b"Dropbox source bytes";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let account = || {
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        }))
    };
    let server = FakeServer::start(vec![
        account(),
        FakeResponse::json(json!({
            "entries": [
                folder_metadata("/apps", "/apps"),
                file_metadata(
                    "/apps/entry.doentry",
                    "/Apps/Entry.doentry",
                    "remote-rev",
                    &content,
                )
            ],
            "cursor": "fresh-case",
            "has_more": false
        })),
        FakeResponse::bytes(bytes.to_vec())
            .header(
                "Dropbox-API-Result",
                download_metadata("apps/Entry.doentry", "remote-rev", &content, bytes.len()),
            )
            .for_path("/2/files/download"),
        account(),
        FakeResponse::json(json!({
            "entries": [file_metadata(
                "/apps/second.doentry",
                "/Apps/Second.doentry",
                "remote-rev-2",
                &content,
            )],
            "cursor": "fresh-case-2",
            "has_more": false
        }))
        .for_path("/2/files/list_folder/continue"),
        FakeResponse::bytes(bytes.to_vec())
            .header(
                "Dropbox-API-Result",
                download_metadata("apps/Second.doentry", "remote-rev-2", &content, bytes.len()),
            )
            .for_path("/2/files/download"),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-fresh-case")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let _ = reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )?;
    let replay = drive_replay(&mut journal, &client, &mut downloads, &root, &staging)??;
    assert_eq!(replay.completed_operations, 1);
    assert_eq!(std::fs::read(root.join("apps/Entry.doentry"))?, bytes);
    assert!(!root.join("Apps").exists());

    let second = reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )?;
    assert!(matches!(second, ReconcileOutcome::Complete(_)));
    let replay = drive_replay(&mut journal, &client, &mut downloads, &root, &staging)??;
    assert_eq!(replay.completed_operations, 1);
    assert_eq!(std::fs::read(root.join("apps/Second.doentry"))?, bytes);
    assert!(journal.pending_plans()?.is_empty());

    let requests = server.finish()?;
    assert!(requests.iter().all(|request| {
        request.path != "/2/files/create_folder_v2"
            && request.path != "/2/files/upload"
            && request.path != "/2/files/delete_v2"
    }));
    Ok(())
}

#[test]
fn remote_directory_deletion_removes_local_directories_deepest_first() -> Result<(), Box<dyn Error>>
{
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [],
            "cursor": "directories-deleted",
            "has_more": false
        })),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-directory-delete")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("gone/child"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    seed_directory_baseline(&mut journal, Path::new("gone"))?;
    seed_directory_baseline(&mut journal, Path::new("gone/child"))?;

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("stable directory deletion requested a rescan").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("directory deletion root changed").into());
        }
    };

    assert_eq!(report.planned, 2);
    assert_eq!(report.replayed_operations, 2);
    assert!(!root.join("gone").exists());
    assert_eq!(journal.baseline(Path::new("gone"))?, None);
    assert_eq!(journal.baseline(Path::new("gone/child"))?, None);
    assert!(journal.pending_plans()?.is_empty());
    assert_eq!(server.finish()?.len(), 2);
    Ok(())
}

#[test]
fn child_created_after_scan_forces_an_immediate_directory_rescan() -> Result<(), Box<dyn Error>> {
    let listing = FakeResponse::json(json!({
        "entries": [],
        "cursor": "directory-raced-after-scan",
        "has_more": false
    }));
    let (listing, gate) = listing.gated();
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        listing,
    ])?;
    let client = Arc::new(fake_client(
        &server,
        "opaque-access-post-plan-directory-race",
    )?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("gone"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    seed_directory_baseline(&mut journal, Path::new("gone"))?;

    let outcome = thread::scope(|scope| -> Result<_, Box<dyn Error>> {
        let worker = thread::Builder::new().spawn_scoped(scope, || {
            reconcile_once(
                &mut journal,
                &client,
                &mut downloads,
                &root,
                &staging,
                &recovery,
            )
        })?;
        gate.request_received.recv().map_err(|_| {
            io::Error::other("fake Dropbox server stopped before the directory listing")
        })?;
        std::fs::write(root.join("gone/new.txt"), b"created after scan")?;
        gate.release_response
            .send(())
            .map_err(|_| io::Error::other("directory listing response could not be released"))?;
        worker
            .join()
            .map_err(|_| io::Error::other("directory-race reconciliation stopped unexpectedly"))?
            .map_err(Into::into)
    })?;

    assert_eq!(
        outcome,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("gone")
        }
    );
    assert_eq!(
        std::fs::read(root.join("gone/new.txt"))?,
        b"created after scan"
    );
    assert_eq!(
        journal.baseline(Path::new("gone"))?,
        Some(Baseline::Directory)
    );
    assert!(journal.pending_plans()?.is_empty());
    assert_eq!(server.finish()?.len(), 2);
    Ok(())
}

#[test]
fn nonempty_directory_delete_reobserves_and_syncs_the_new_child() -> Result<(), Box<dyn Error>> {
    let child_bytes = b"new child";
    let child_content = dropbox_content_hash(child_bytes.as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [],
            "cursor": "parent-deleted",
            "has_more": false
        })),
        FakeResponse::json(json!({
            "metadata": folder_metadata("/parent", "/parent")
        })),
        FakeResponse::json(file_metadata(
            "/parent/new.txt",
            "/parent/new.txt",
            "rev-new-child",
            &child_content,
        )),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-directory-race")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("parent"))?;
    std::fs::write(root.join("parent/new.txt"), child_bytes)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    seed_directory_baseline(&mut journal, Path::new("parent"))?;

    let outcome = reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )?;

    assert_eq!(
        outcome,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("parent")
        }
    );
    assert_eq!(std::fs::read(root.join("parent/new.txt"))?, child_bytes);
    assert_eq!(
        journal.baseline(Path::new("parent"))?,
        Some(Baseline::Directory)
    );
    assert!(matches!(
        journal.baseline(Path::new("parent/new.txt"))?,
        Some(Baseline::Present(_))
    ));
    assert!(journal.pending_plans()?.is_empty());
    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
    assert_eq!(requests[2].path, "/2/files/create_folder_v2");
    assert_eq!(requests[3].path, "/2/files/upload");
    Ok(())
}

#[test]
fn remote_directory_preserves_a_local_file_under_a_synchronized_name() -> Result<(), Box<dyn Error>>
{
    let bytes = b"local file preserved beside directory";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let identity_prefix = content
        .as_str()
        .get(..12)
        .ok_or_else(|| io::Error::other("test content hash was too short"))?;
    let variant = format!("node (local file {identity_prefix})");
    let variant_api = format!("/{variant}");
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [folder_metadata("/node", "/node")],
            "cursor": "directory-file-collision",
            "has_more": false
        })),
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [],
            "cursor": "directory-file-collision",
            "has_more": false
        })),
        FakeResponse::json(file_metadata(
            &variant_api,
            &variant_api,
            "rev-local-copy",
            &content,
        )),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-local-file-directory")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("node"), bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    assert_eq!(
        reconcile_once(
            &mut journal,
            &client,
            &mut downloads,
            &root,
            &staging,
            &recovery,
        )?,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("node")
        }
    );
    assert!(!root.join("node").exists());
    assert_eq!(std::fs::read(root.join(&variant))?, bytes);
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.conflicts()?.is_empty());

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("preserved local file did not converge").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("local file collision changed its root").into());
        }
    };
    assert_eq!(report.planned, 2);
    assert_eq!(report.replayed_operations, 2);
    assert!(root.join("node").is_dir());
    assert_eq!(std::fs::read(root.join(&variant))?, bytes);
    assert_eq!(
        journal.baseline(Path::new("node"))?,
        Some(Baseline::Directory)
    );
    assert!(matches!(
        journal.baseline(Path::new(&variant))?,
        Some(Baseline::Present(_))
    ));
    assert!(journal.conflicts()?.is_empty());
    assert_eq!(server.finish()?.len(), 5);
    Ok(())
}

#[test]
fn local_directory_preserves_a_dropbox_file_under_a_synchronized_name() -> Result<(), Box<dyn Error>>
{
    let bytes = b"Dropbox file preserved beside directory";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let identity_prefix = content
        .as_str()
        .get(..12)
        .ok_or_else(|| io::Error::other("test content hash was too short"))?;
    let variant = format!("node (Dropbox file {identity_prefix})");
    let variant_api = format!("/{variant}");
    let variant_lower = variant_api.to_lowercase();
    let original = file_metadata("/node", "/node", "rev-remote-file", &content);
    let download = || {
        FakeResponse::bytes(bytes.to_vec()).header(
            "Dropbox-API-Result",
            download_metadata("node", "rev-remote-file", &content, bytes.len()),
        )
    };
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [original.clone()],
            "cursor": "remote-file",
            "has_more": false
        })),
        download(),
        FakeResponse::json(json!({"metadata": original})),
        FakeResponse::json(json!({
            "metadata": folder_metadata("/node", "/node")
        })),
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [folder_metadata("/node", "/node")],
            "cursor": "remote-directory",
            "has_more": false
        })),
        FakeResponse::json(json!({
            "entries": [folder_metadata("/node", "/node")],
            "cursor": "remote-directory",
            "has_more": false
        })),
        FakeResponse::json(file_metadata(
            &variant_lower,
            &variant_api,
            "rev-dropbox-copy",
            &content,
        )),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-remote-file-directory")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("node"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let first = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(
                io::Error::other("stable Dropbox file collision requested a rescan").into(),
            );
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("Dropbox file collision changed its root").into());
        }
    };
    assert_eq!(first.planned, 1);
    assert_eq!(first.replayed_operations, 2);
    assert!(root.join("node").is_dir());
    assert_eq!(std::fs::read(root.join(&variant))?, bytes);
    assert_eq!(
        journal.baseline(Path::new("node"))?,
        Some(Baseline::Directory)
    );
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.conflicts()?.is_empty());
    assert!(journal.completed_recoveries()?.is_empty());

    let second = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("Dropbox file copy did not converge").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("Dropbox file copy changed its root").into());
        }
    };
    assert_eq!(second.planned, 1);
    assert_eq!(second.replayed_operations, 1);
    assert_eq!(std::fs::read(root.join(&variant))?, bytes);
    assert!(matches!(
        journal.baseline(Path::new(&variant))?,
        Some(Baseline::Present(_))
    ));
    assert!(journal.conflicts()?.is_empty());
    let requests = server.finish()?;
    assert_eq!(requests.len(), 9);
    assert_eq!(
        requests
            .iter()
            .filter(|request| request.path == "/2/files/download")
            .count(),
        1
    );
    assert!(
        requests
            .iter()
            .any(|request| request.path == "/2/files/delete_v2")
    );
    assert!(
        requests
            .iter()
            .any(|request| request.path == "/2/files/create_folder_v2")
    );
    assert!(
        requests
            .iter()
            .any(|request| request.path == "/2/files/upload")
    );
    Ok(())
}

#[test]
fn directory_collision_copy_stays_bound_to_the_verified_root() -> Result<(), Box<dyn Error>> {
    let bytes = b"descriptor-bound Dropbox file copy";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let identity_prefix = content
        .as_str()
        .get(..12)
        .ok_or_else(|| io::Error::other("test content hash was too short"))?;
    let variant = format!("node (Dropbox file {identity_prefix})");
    let original = file_metadata("/node", "/node", "rev-root-swap", &content);
    let visible_download = FakeResponse::bytes(bytes.to_vec()).header(
        "Dropbox-API-Result",
        download_metadata("node", "rev-root-swap", &content, bytes.len()),
    );
    let (visible_download, gate) = visible_download.gated();
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [original],
            "cursor": "root-swap-directory-copy",
            "has_more": false
        })),
        visible_download,
    ])?;
    let client = Arc::new(fake_client(
        &server,
        "opaque-access-directory-copy-root-swap",
    )?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let old_root = directory.path().join("old-root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("node"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let outcome = thread::scope(|scope| -> Result<_, Box<dyn Error>> {
        let worker = thread::Builder::new().spawn_scoped(scope, || {
            reconcile_once(
                &mut journal,
                &client,
                &mut downloads,
                &root,
                &staging,
                &recovery,
            )
        })?;
        gate.request_received.recv().map_err(|_| {
            io::Error::other("fake Dropbox server stopped before the collision download")
        })?;
        std::fs::rename(&root, &old_root)?;
        std::fs::create_dir(&root)?;
        std::fs::write(root.join("canary.txt"), b"replacement root")?;
        gate.release_response
            .send(())
            .map_err(|_| io::Error::other("collision download response could not be released"))?;
        worker
            .join()
            .map_err(|_| io::Error::other("root-swap reconciliation stopped unexpectedly"))?
            .map_err(Into::into)
    })?;

    assert_eq!(outcome, ReconcileOutcome::LocalRootChanged);
    assert_eq!(std::fs::read(old_root.join(&variant))?, bytes);
    assert!(!root.join(&variant).exists());
    assert_eq!(std::fs::read(root.join("canary.txt"))?, b"replacement root");
    assert!(journal.pending_plans()?.is_empty());
    assert_eq!(journal.baseline(Path::new("node"))?, None);
    assert_eq!(server.finish()?.len(), 3);
    Ok(())
}

#[test]
fn directory_collision_destination_race_requests_a_fresh_scan() -> Result<(), Box<dyn Error>> {
    let bytes = b"Dropbox bytes that must remain exact";
    let raced_bytes = b"local file created after observation";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let identity_prefix = content
        .as_str()
        .get(..12)
        .ok_or_else(|| io::Error::other("test content hash was too short"))?;
    let variant = format!("node (Dropbox file {identity_prefix})");
    let original = file_metadata("/node", "/node", "rev-destination-race", &content);
    let download = FakeResponse::bytes(bytes.to_vec()).header(
        "Dropbox-API-Result",
        download_metadata("node", "rev-destination-race", &content, bytes.len()),
    );
    let (download, gate) = download.gated();
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [original],
            "cursor": "directory-copy-destination-race",
            "has_more": false
        })),
        download,
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-directory-copy-race")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("node"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let outcome = thread::scope(|scope| -> Result<_, Box<dyn Error>> {
        let worker = thread::Builder::new().spawn_scoped(scope, || {
            reconcile_once(
                &mut journal,
                &client,
                &mut downloads,
                &root,
                &staging,
                &recovery,
            )
        })?;
        gate.request_received.recv().map_err(|_| {
            io::Error::other("fake Dropbox server stopped before the raced copy download")
        })?;
        std::fs::write(root.join(&variant), raced_bytes)?;
        gate.release_response
            .send(())
            .map_err(|_| io::Error::other("raced copy response could not be released"))?;
        worker
            .join()
            .map_err(|_| io::Error::other("destination-race reconciliation stopped unexpectedly"))?
            .map_err(Into::into)
    })?;

    assert_eq!(
        outcome,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("node")
        }
    );
    assert_eq!(std::fs::read(root.join(&variant))?, raced_bytes);
    assert!(root.join("node").is_dir());
    assert!(journal.pending_plans()?.is_empty());
    assert_eq!(journal.baseline(Path::new("node"))?, None);
    assert_eq!(server.finish()?.len(), 3);
    Ok(())
}

#[test]
fn occupied_collision_stage_uses_the_next_synchronized_name() -> Result<(), Box<dyn Error>> {
    let bytes = b"Dropbox bytes preserved beside an occupied stage";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let identity_prefix = content
        .as_str()
        .get(..12)
        .ok_or_else(|| io::Error::other("test content hash was too short"))?;
    let first_variant = format!("node (Dropbox file {identity_prefix})");
    let second_variant = format!("node (Dropbox file {identity_prefix} 2)");
    let original = file_metadata("/node", "/node", "rev-occupied-stage", &content);
    let download = || {
        FakeResponse::bytes(bytes.to_vec()).header(
            "Dropbox-API-Result",
            download_metadata("node", "rev-occupied-stage", &content, bytes.len()),
        )
    };
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [original.clone()],
            "cursor": "occupied-directory-copy-stage",
            "has_more": false
        })),
        download(),
        FakeResponse::json(json!({"metadata": original})),
        FakeResponse::json(json!({
            "metadata": folder_metadata("/node", "/node")
        })),
    ])?;
    let client = Arc::new(fake_client(
        &server,
        "opaque-access-occupied-directory-copy-stage",
    )?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("node"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    assert!(matches!(
        stage_download(&root, Path::new(&first_variant), &content, bytes.as_slice())?,
        StageOutcome::Staged(())
    ));
    let occupied_stage = std::fs::read_dir(&root)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with(".omabox-download-"))
        })
        .ok_or_else(|| io::Error::other("test download stage was not created"))?;
    std::fs::set_permissions(&occupied_stage, std::fs::Permissions::from_mode(0o600))?;
    std::fs::write(&occupied_stage, b"unrelated stage bytes")?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("stable occupied stage requested a rescan").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("occupied-stage collision changed its root").into());
        }
    };

    assert_eq!(report.planned, 1);
    assert_eq!(report.replayed_operations, 2);
    assert!(!root.join(&first_variant).exists());
    assert_eq!(std::fs::read(root.join(&second_variant))?, bytes);
    assert_eq!(std::fs::read(&occupied_stage)?, b"unrelated stage bytes");
    assert_eq!(
        journal.baseline(Path::new("node"))?,
        Some(Baseline::Directory)
    );
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.conflicts()?.is_empty());
    assert_eq!(server.finish()?.len(), 5);
    Ok(())
}

#[test]
fn changed_dropbox_file_during_directory_conversion_replans_without_a_conflict_row()
-> Result<(), Box<dyn Error>> {
    let old_bytes = b"old Dropbox file";
    let new_bytes = b"new Dropbox file";
    let old_content = dropbox_content_hash(old_bytes.as_slice())?;
    let new_content = dropbox_content_hash(new_bytes.as_slice())?;
    let old = file_metadata("/node", "/node", "rev-old", &old_content);
    let download = || {
        FakeResponse::bytes(old_bytes.to_vec()).header(
            "Dropbox-API-Result",
            download_metadata("node", "rev-old", &old_content, old_bytes.len()),
        )
    };
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [old.clone()],
            "cursor": "old-file",
            "has_more": false
        })),
        download(),
        FakeResponse::status_json(409, json!({"error": {".tag": "path"}})),
        FakeResponse::json(file_metadata("/node", "/node", "rev-new", &new_content)),
    ])?;
    let client = Arc::new(fake_client(
        &server,
        "opaque-access-directory-revision-race",
    )?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("node"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    let outcome = reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )?;

    assert_eq!(
        outcome,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("node")
        }
    );
    assert!(root.join("node").is_dir());
    let preserved = std::fs::read_dir(&root)?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| path.is_file())
        .ok_or_else(|| io::Error::other("old Dropbox file copy was not preserved"))?;
    assert_eq!(std::fs::read(preserved)?, old_bytes);
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.conflicts()?.is_empty());
    assert_eq!(journal.baseline(Path::new("node"))?, None);
    let requests = server.finish()?;
    assert_eq!(requests.len(), 5);
    assert!(
        !requests
            .iter()
            .any(|request| request.path == "/2/files/create_folder_v2")
    );
    Ok(())
}

#[test]
fn large_replace_resumes_a_partially_stored_upload_chunk() -> Result<(), Box<dyn Error>> {
    const MIB: u64 = 1024 * 1024;
    const CHUNK: u64 = 32 * MIB;
    const SIZE: u64 = 150 * MIB + 1;
    let fixture = sparse_upload_fixture(SIZE, CHUNK / 2)?;
    let content = fixture.staged.content().clone();
    let session_id = "opaque-session-must-not-appear-in-errors";
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({"session_id": session_id})),
        FakeResponse::status_json(
            409,
            json!({
                "error_summary": "incorrect_offset/...",
                "error": {
                    ".tag": "incorrect_offset",
                    "correct_offset": CHUNK / 2
                }
            }),
        ),
        FakeResponse::json(json!({})),
        FakeResponse::json(json!({})),
        FakeResponse::json(json!({})),
        FakeResponse::json(json!({})),
        FakeResponse::json(json!({})),
        FakeResponse::json(file_metadata(
            "/large.bin",
            "/Large.bin",
            "new-revision",
            &content,
        )),
    ])?;
    let client = fake_client(&server, "opaque-access-large-upload")?;

    assert_eq!(
        client.replace_file(
            "Large.bin",
            &DropboxRevision::new("old-revision"),
            &fixture.staged,
        )?,
        MutationOutcome::Applied(RemotePathState::File(RemoteFile::new(
            content,
            DropboxRevision::new("new-revision"),
        )))
    );

    let requests = server.finish()?;
    assert_eq!(requests.len(), 8);
    assert_eq!(requests[0].path, "/2/files/upload_session/start");
    assert_eq!(requests[1].path, "/2/files/upload_session/append_v2");
    assert_eq!(requests[2].path, "/2/files/upload_session/append_v2");
    assert_eq!(requests[3].path, "/2/files/upload_session/append_v2");
    assert_eq!(requests[4].path, "/2/files/upload_session/append_v2");
    assert_eq!(requests[5].path, "/2/files/upload_session/append_v2");
    assert_eq!(requests[6].path, "/2/files/upload_session/append_v2");
    assert_eq!(requests[7].path, "/2/files/upload_session/finish");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(required_header(
            &requests[0],
            "dropbox-api-arg",
        )?)?,
        json!({"close": false})
    );
    for (request, offset) in
        requests[1..7]
            .iter()
            .zip([0, CHUNK / 2, CHUNK, 2 * CHUNK, 3 * CHUNK, 4 * CHUNK])
    {
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(required_header(
                request,
                "dropbox-api-arg",
            )?)?,
            json!({
                "cursor": {"session_id": session_id, "offset": offset},
                "close": false
            })
        );
    }
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(required_header(
            &requests[7],
            "dropbox-api-arg",
        )?)?,
        json!({
            "cursor": {"session_id": session_id, "offset": SIZE},
            "commit": {
                "path": "/Large.bin",
                "mode": {".tag": "update", "update": "old-revision"},
                "autorename": false,
                "strict_conflict": true
            }
        })
    );
    assert!(requests[0].body.is_empty());
    assert_eq!(u64::try_from(requests[1].body.len())?, CHUNK);
    assert_eq!(u64::try_from(requests[2].body.len())?, CHUNK / 2);
    assert_eq!(requests[2].body.first(), Some(&0xa5));
    assert_eq!(u64::try_from(requests[3].body.len())?, CHUNK);
    assert_eq!(u64::try_from(requests[4].body.len())?, CHUNK);
    assert_eq!(u64::try_from(requests[5].body.len())?, CHUNK);
    assert_eq!(u64::try_from(requests[6].body.len())?, SIZE - 4 * CHUNK);
    assert!(requests[7].body.is_empty());
    assert_eq!(
        requests
            .iter()
            .try_fold(0_u64, |total, request| -> io::Result<u64> {
                let length = u64::try_from(request.body.len()).map_err(io::Error::other)?;
                total
                    .checked_add(length)
                    .ok_or_else(|| io::Error::other("captured upload length overflowed"))
            })?,
        SIZE + CHUNK / 2
    );
    Ok(())
}

#[test]
fn case_only_remote_spelling_change_is_a_stable_noop() -> Result<(), Box<dyn Error>> {
    let bytes = b"same bytes across a case-only change";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("rev-same"));
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [file_metadata(
                "/report.txt",
                "/report.txt",
                "rev-same",
                &content,
            )],
            "cursor": "case-only",
            "has_more": false
        })),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-case-only")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("Report.TXT"), bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    seed_baseline(&mut journal, Path::new("Report.TXT"), &remote)?;

    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("stable case-only fixture requested a refresh").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable case-only fixture changed its root").into());
        }
    };

    assert_eq!(report.noops, 1);
    assert_eq!(report.planned, 0);
    assert_eq!(report.replayed_operations, 0);
    assert!(journal.pending_plans()?.is_empty());
    assert_eq!(
        journal.baseline(Path::new("report.txt"))?,
        Some(Baseline::Present(remote))
    );
    assert!(root.join("Report.TXT").is_file());
    assert!(!root.join("report.txt").exists());
    let inventory = journal.remote_inventory()?;
    let [record] = inventory.observations.as_slice() else {
        return Err(io::Error::other("expected one canonical remote observation").into());
    };
    assert_eq!(record.canonical_path, Path::new("report.txt"));
    assert_eq!(record.path, Path::new("report.txt"));
    assert_eq!(server.finish()?.len(), 2);
    Ok(())
}

#[test]
fn local_case_collision_is_renamed_before_planning_and_then_syncs() -> Result<(), Box<dyn Error>> {
    let first_bytes = b"first";
    let second_bytes = b"second";
    let first_content = dropbox_content_hash(first_bytes.as_slice())?;
    let second_content = dropbox_content_hash(second_bytes.as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [],
            "cursor": "empty",
            "has_more": false
        })),
        FakeResponse::json(file_metadata(
            "/foo.txt",
            "/Foo.txt",
            "rev-first",
            &first_content,
        )),
        FakeResponse::json(file_metadata(
            "/foo.txt (case variant)",
            "/foo.txt (case variant)",
            "rev-second",
            &second_content,
        )),
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-local-collision")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("Foo.txt"), first_bytes)?;
    std::fs::write(root.join("foo.txt"), second_bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    assert_eq!(
        reconcile_once(
            &mut journal,
            &client,
            &mut downloads,
            &root,
            &staging,
            &recovery,
        )?,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("foo.txt")
        }
    );
    assert!(journal.pending_plans()?.is_empty());
    assert!(journal.baseline_paths()?.is_empty());
    assert_eq!(std::fs::read(root.join("Foo.txt"))?, first_bytes);
    assert!(!root.join("foo.txt").exists());
    assert_eq!(
        std::fs::read(root.join("foo.txt (case variant)"))?,
        second_bytes
    );

    drop(journal);
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("renamed case variants did not converge").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable case-variant fixture changed its root").into());
        }
    };
    assert_eq!(report.planned, 2);
    assert_eq!(report.replayed_operations, 2);
    assert_eq!(report.blocked, 0);
    assert!(journal.pending_plans()?.is_empty());
    assert_eq!(server.finish()?.len(), 4);
    Ok(())
}

#[test]
fn automatic_case_rename_never_becomes_a_dropbox_delete() -> Result<(), Box<dyn Error>> {
    let bytes = b"remote-associated local bytes";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("rev-original"));
    let download = FakeResponse::bytes(bytes.to_vec())
        .header(
            "Dropbox-API-Result",
            download_metadata("Apps/entry.doentry", "rev-original", &content, bytes.len()),
        )
        .for_path("/2/files/download");
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        }))
        .for_path("/2/users/get_current_account"),
        FakeResponse::json(json!({
            "entries": [
                folder_metadata("/apps", "/Apps"),
                file_metadata(
                    "/apps/entry.doentry",
                    "/Apps/entry.doentry",
                    "rev-original",
                    &content,
                ),
            ],
            "cursor": "case-collision",
            "has_more": false,
        }))
        .for_path("/2/files/list_folder"),
        FakeResponse::json(json!({
            "metadata": folder_metadata(
                "/apps (case variant)",
                "/apps (case variant)",
            )
        }))
        .for_path("/2/files/create_folder_v2"),
        FakeResponse::json(json!({
            "metadata": folder_metadata(
                "/apps (case variant)",
                "/apps (case variant)",
            )
        }))
        .for_path("/2/files/create_folder_v2"),
        FakeResponse::json(file_metadata(
            "/apps (case variant)/entry.doentry",
            "/apps (case variant)/entry.doentry",
            "rev-variant",
            &content,
        ))
        .for_path("/2/files/upload"),
        download,
    ])?;
    let client = Arc::new(fake_client(&server, "opaque-access-case-rename-delete")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("Apps"))?;
    std::fs::create_dir_all(root.join("apps"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("apps/entry.doentry"), bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    seed_baseline(&mut journal, Path::new("Apps/entry.doentry"), &remote)?;
    assert!(matches!(
        scan_and_publish(&mut journal, &root)?,
        ScanPublication::Published(_)
    ));
    let stale_delete = planned_operations(plan(
        &Baseline::Present(remote.clone()),
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote.clone()),
    ))?;
    assert!(matches!(
        journal.record_plan(Path::new("Apps/entry.doentry"), &stale_delete)?,
        PlanWrite::Recorded(_)
    ));

    assert!(matches!(
        reconcile_once(
            &mut journal,
            &client,
            &mut downloads,
            &root,
            &staging,
            &recovery,
        )?,
        ReconcileOutcome::FreshObservationRequired { .. }
    ));
    let _ = reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )?;
    let replay = drive_replay(&mut journal, &client, &mut downloads, &root, &staging)??;
    assert!(replay.blocked.is_empty());
    assert_eq!(std::fs::read(root.join("Apps/entry.doentry"))?, bytes);
    assert_eq!(
        std::fs::read(root.join("apps (case variant)/entry.doentry"))?,
        bytes
    );
    assert!(!root.join("apps").exists());
    assert!(!root.join("apps (case variant 2)").exists());

    let requests = server.finish()?;
    assert!(
        requests
            .iter()
            .all(|request| request.path != "/2/files/delete_v2")
    );
    Ok(())
}

#[test]
fn local_case_collision_preserves_both_directory_trees() -> Result<(), Box<dyn Error>> {
    let server = FakeServer::start(Vec::new())?;
    let client = Arc::new(fake_client(&server, "opaque-access-directory-collision")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("Credit/statements"))?;
    std::fs::create_dir_all(root.join("credit/Expenses"))?;
    std::fs::create_dir_all(root.join("credit/expenses"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("Credit/statements/april.pdf"), b"statement")?;
    std::fs::write(root.join("credit/Expenses/invoice.pdf"), b"invoice")?;
    std::fs::write(root.join("credit/expenses/receipt.pdf"), b"receipt")?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;

    assert_eq!(
        reconcile_once(
            &mut journal,
            &client,
            &mut downloads,
            &root,
            &staging,
            &recovery,
        )?,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("credit")
        }
    );
    assert_eq!(
        std::fs::read(root.join("Credit/statements/april.pdf"))?,
        b"statement"
    );
    assert_eq!(
        std::fs::read(root.join("credit (case variant)/expenses/receipt.pdf"))?,
        b"receipt"
    );
    assert!(!root.join("credit").exists());
    assert!(journal.pending_plans()?.is_empty());

    assert_eq!(
        reconcile_once(
            &mut journal,
            &client,
            &mut downloads,
            &root,
            &staging,
            &recovery,
        )?,
        ReconcileOutcome::FreshObservationRequired {
            path: PathBuf::from("credit (case variant)/expenses")
        }
    );
    assert_eq!(
        std::fs::read(root.join("credit (case variant)/Expenses/invoice.pdf"))?,
        b"invoice"
    );
    assert_eq!(
        std::fs::read(root.join("credit (case variant)/expenses (case variant)/receipt.pdf"))?,
        b"receipt"
    );
    let scan = match scan_and_publish(&mut journal, &root)? {
        ScanPublication::Published(scan) => scan,
        ScanPublication::RootChanged => {
            return Err(io::Error::other("stable nested fixture changed its root").into());
        }
    };
    let mut canonical_paths = BTreeSet::new();
    assert!(
        scan.observations()
            .iter()
            .all(|record| canonical_paths.insert(record.path.to_string_lossy().to_lowercase()))
    );
    assert_eq!(server.finish()?.len(), 0);
    Ok(())
}

#[test]
fn pending_exact_downloads_use_bounded_parallel_workers() -> Result<(), Box<dyn Error>> {
    const DOWNLOAD_COUNT: usize = 8;
    const WORKER_COUNT: usize = 4;

    let bytes = b"bounded parallel download";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("shared-revision"));
    let metadata = download_metadata(
        "shared.txt",
        remote.revision.as_str(),
        &content,
        bytes.len(),
    );
    let mut response_groups = Vec::with_capacity(WORKER_COUNT);
    let mut first_wave = Vec::with_capacity(WORKER_COUNT);
    let mut second_wave = Vec::with_capacity(WORKER_COUNT);
    for _ in 0..WORKER_COUNT {
        let response =
            || FakeResponse::bytes(bytes.to_vec()).header("Dropbox-API-Result", metadata.clone());
        let (first, first_gate) = response().gated();
        let (second, second_gate) = response().gated();
        response_groups.push(vec![first, second]);
        first_wave.push(first_gate);
        second_wave.push(second_gate);
    }
    let server = FakeServer::start_keep_alive(response_groups)?;
    let client = Arc::new(fake_client(&server, "opaque-access-parallel")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    let operation_plan = planned_operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote),
    ))?;
    let mut paths = Vec::with_capacity(DOWNLOAD_COUNT);
    for index in 0..DOWNLOAD_COUNT {
        let path = Path::new(&format!("download-{index}.txt")).to_path_buf();
        if !matches!(
            journal.record_plan(&path, &operation_plan)?,
            PlanWrite::Recorded(_)
        ) {
            return Err(io::Error::other("fresh download plan was already pending").into());
        }
        paths.push(path);
    }

    let initial = replay_pending(&mut journal, &client, &mut downloads, &root, &staging)?;
    assert_eq!(initial.completed_operations, 0);
    for gate in &first_wave {
        gate.request_received
            .recv_timeout(Duration::from_secs(5))
            .map_err(|_| io::Error::other("first download wave did not start"))?;
    }
    for gate in first_wave {
        gate.release_response
            .send(())
            .map_err(|_| io::Error::other("first download wave stopped before release"))?;
    }
    for gate in &second_wave {
        gate.request_received
            .recv_timeout(Duration::from_secs(5))
            .map_err(|_| io::Error::other("workers did not self-feed the second download wave"))?;
    }
    for gate in second_wave {
        gate.release_response
            .send(())
            .map_err(|_| io::Error::other("second download wave stopped before release"))?;
    }

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut completed_operations = 0;
    while !journal.pending_plans()?.is_empty() {
        let report = replay_pending(&mut journal, &client, &mut downloads, &root, &staging)?;
        completed_operations += report.completed_operations;
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "parallel downloads did not finish",
            )
            .into());
        }
        thread::yield_now();
    }

    assert_eq!(completed_operations, DOWNLOAD_COUNT);
    assert!(journal.pending_plans()?.is_empty());
    for path in paths {
        assert_eq!(std::fs::read(root.join(path))?, bytes);
    }
    let maximum_active = server.maximum_active();
    let connection_count = server.connection_count();
    let requests = server.finish()?;
    assert_eq!(requests.len(), DOWNLOAD_COUNT);
    assert!(
        requests
            .iter()
            .all(|request| request.path == "/2/files/download")
    );
    assert_eq!(maximum_active, WORKER_COUNT);
    assert!(connection_count <= 4);
    Ok(())
}

#[test]
fn gated_download_does_not_stop_the_next_poll_and_reconciliation() -> Result<(), Box<dyn Error>> {
    let download_bytes = b"long remote download";
    let download_content = dropbox_content_hash(download_bytes.as_slice())?;
    let download = RemoteFile::new(
        download_content.clone(),
        DropboxRevision::new("long-download-revision"),
    );
    let upload_bytes = b"local change during download";
    let upload_content = dropbox_content_hash(upload_bytes.as_slice())?;
    let uploaded = RemoteFile::new(
        upload_content.clone(),
        DropboxRevision::new("unrelated-upload-revision"),
    );
    let response = FakeResponse::bytes(download_bytes.to_vec()).header(
        "Dropbox-API-Result",
        download_metadata(
            "long.bin",
            download.revision.as_str(),
            &download_content,
            download_bytes.len(),
        ),
    );
    let (response, gate) = response.gated();
    let server = FakeServer::start(vec![
        response,
        FakeResponse::json(json!({"changes": false})),
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [],
            "cursor": "cursor-after-gated-download",
            "has_more": false
        })),
        FakeResponse::json(file_metadata(
            "/unrelated.txt",
            "/unrelated.txt",
            uploaded.revision.as_str(),
            &upload_content,
        )),
    ])?;
    let finished_transfers = Arc::new(AtomicUsize::new(0));
    let recorded_finishes = Arc::clone(&finished_transfers);
    let observer: TransferObserver = Arc::new(move |event| {
        if matches!(event, TransferEvent::Finished(_)) {
            recorded_finishes.fetch_add(1, Ordering::SeqCst);
        }
    });
    let client = Arc::new(
        fake_client(&server, "opaque-access-nonblocking")?.with_transfer_observer(observer),
    );
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    let download_plan = planned_operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(download.clone()),
    ))?;
    if !matches!(
        journal.record_plan(Path::new("long.bin"), &download_plan)?,
        PlanWrite::Recorded(_)
    ) {
        return Err(io::Error::other("fresh long download plan was already pending").into());
    }

    let dispatched = replay_pending(&mut journal, &client, &mut downloads, &root, &staging)?;
    assert_eq!(dispatched.completed_operations, 0);
    gate.request_received.recv().map_err(|_| {
        io::Error::other("fake Dropbox server stopped before receiving the long download")
    })?;

    assert!(matches!(
        client.long_poll("cursor-before-gated-download", Duration::from_secs(30))?,
        LongPollWakeup::TimedOut { backoff: None }
    ));
    std::fs::write(root.join("unrelated.txt"), upload_bytes)?;
    let started = Instant::now();
    let report = match reconcile_once(
        &mut journal,
        &client,
        &mut downloads,
        &root,
        &staging,
        &recovery,
    )? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(
                io::Error::other("stable local change requested a fresh observation").into(),
            );
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable fixture changed its local root").into());
        }
    };
    assert!(started.elapsed() < Duration::from_secs(30));
    assert_eq!(report.planned, 1);
    assert_eq!(report.replayed_operations, 1);
    assert_eq!(
        journal.baseline(Path::new("unrelated.txt"))?,
        Some(Baseline::Present(uploaded))
    );
    assert_eq!(journal.pending_plans()?.len(), 1);
    assert!(!root.join("long.bin").exists());

    let finishes_before_release = finished_transfers.load(Ordering::SeqCst);
    gate.release_response
        .send(())
        .map_err(|_| io::Error::other("fake Dropbox response worker stopped before release"))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while finished_transfers.load(Ordering::SeqCst) == finishes_before_release {
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "long download did not finish after release",
            )
            .into());
        }
        thread::yield_now();
    }
    while !journal.pending_plans()?.is_empty() {
        let _report = replay_pending(&mut journal, &client, &mut downloads, &root, &staging)?;
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "released long download was not installed",
            )
            .into());
        }
        thread::yield_now();
    }
    assert_eq!(std::fs::read(root.join("long.bin"))?, download_bytes);
    assert_eq!(server.finish()?.len(), 5);
    Ok(())
}

#[test]
fn interrupted_exact_download_resumes_only_from_a_valid_range() -> Result<(), Box<dyn Error>> {
    const CHECKPOINT: usize = 64 * 1024 * 1024;
    const DROPBOX_BLOCK: usize = 4 * 1024 * 1024;

    let bytes = vec![b'x'; CHECKPOINT + DROPBOX_BLOCK + 257];
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("resume-revision"));
    let metadata = download_metadata(
        "resume.bin",
        remote.revision.as_str(),
        &content,
        bytes.len(),
    );
    let changed_content = dropbox_content_hash(b"different resumed bytes".as_slice())?;
    let changed_revision =
        download_metadata("resume.bin", "different-revision", &content, bytes.len());
    let changed_hash = download_metadata(
        "resume.bin",
        remote.revision.as_str(),
        &changed_content,
        bytes.len(),
    );
    let changed_size = download_metadata(
        "resume.bin",
        remote.revision.as_str(),
        &content,
        CHECKPOINT - 1,
    );
    let end = bytes.len() - 1;
    let valid_range = format!("bytes {CHECKPOINT}-{end}/{}", bytes.len());
    let responses = vec![
        FakeResponse::bytes(bytes.clone())
            .header("Dropbox-API-Result", metadata.clone())
            .disconnect_after(CHECKPOINT + DROPBOX_BLOCK + 17),
        FakeResponse::bytes(Vec::new()).header("Dropbox-API-Result", metadata.clone()),
        FakeResponse::range(
            Vec::new(),
            metadata.clone(),
            format!("bytes {}-{end}/{}", CHECKPOINT + 1, bytes.len()),
        ),
        FakeResponse::range(
            Vec::new(),
            metadata.clone(),
            format!("bytes {CHECKPOINT}-{}/{}", end - 1, bytes.len()),
        ),
        FakeResponse::range(
            Vec::new(),
            metadata.clone(),
            format!("bytes {CHECKPOINT}-{end}/{}", bytes.len() + 1),
        ),
        FakeResponse::range(Vec::new(), changed_revision, valid_range.clone()),
        FakeResponse::range(Vec::new(), changed_hash, valid_range.clone()),
        FakeResponse::range(Vec::new(), changed_size, valid_range.clone()),
        FakeResponse::range(Vec::new(), metadata.clone(), valid_range.clone()),
        FakeResponse::range(bytes[CHECKPOINT..].to_vec(), metadata, valid_range),
    ];
    let server = FakeServer::start(responses)?;
    let client = Arc::new(fake_client(&server, "opaque-access-resume")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    let operation_plan = planned_operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote.clone()),
    ))?;
    if !matches!(
        journal.record_plan(Path::new("resume.bin"), &operation_plan)?,
        PlanWrite::Recorded(_)
    ) {
        return Err(io::Error::other("fresh resume plan was already pending").into());
    }

    let mut replay = || drive_replay(&mut journal, &client, &mut downloads, &root, &staging);
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::DownloadBody { .. },
            ..
        })
    ));
    let partial = std::fs::read_dir(&staging)?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .find(|path| {
            path.file_name()
                .is_some_and(|name| name.to_string_lossy().starts_with(".omabox-download-slot-"))
        })
        .ok_or_else(|| io::Error::other("interrupted download did not retain its slot"))?;
    assert_eq!(
        std::fs::metadata(&partial)?.len(),
        u64::try_from(CHECKPOINT + DROPBOX_BLOCK)?
    );
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::InvalidDownloadRange,
            ..
        })
    ));
    assert_eq!(
        std::fs::metadata(&partial)?.len(),
        u64::try_from(CHECKPOINT)?
    );
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::InvalidDownloadRange,
            ..
        })
    ));
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::InvalidDownloadRange,
            ..
        })
    ));
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::InvalidDownloadRange,
            ..
        })
    ));
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::DownloadedRevisionChanged,
            ..
        })
    ));
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::DownloadedIdentityChanged,
            ..
        })
    ));
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::DownloadedSizeChanged,
            ..
        })
    ));
    assert!(matches!(
        replay()?,
        Err(ReconcileError::RemoteDownload {
            source: DropboxError::DownloadedLengthChanged,
            ..
        })
    ));
    let report = replay()??;
    drop(replay);
    assert_eq!(report.completed_operations, 1);
    assert_eq!(std::fs::read(root.join("resume.bin"))?, bytes);
    assert!(journal.pending_plans()?.is_empty());

    let requests = server.finish()?;
    assert_eq!(requests.len(), 10);
    assert!(header(&requests[0], "range").is_none());
    for request in &requests[1..] {
        assert_eq!(header(request, "range"), Some("bytes=67108864-"));
    }
    Ok(())
}

#[test]
fn unknown_download_slots_are_preserved_with_disposable_fallback() -> Result<(), Box<dyn Error>> {
    let bytes = b"fallback download";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("fallback-revision"));
    let server = FakeServer::start(vec![FakeResponse::bytes(bytes.to_vec()).header(
        "Dropbox-API-Result",
        download_metadata(
            "fallback.txt",
            remote.revision.as_str(),
            &content,
            bytes.len(),
        ),
    )])?;
    let client = Arc::new(fake_client(&server, "opaque-access-fallback")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let socket_path = staging.join(".omabox-download-slot-0");
    let _socket = UnixListener::bind(&socket_path)?;
    for slot in 1..4 {
        std::fs::write(
            staging.join(format!(".omabox-download-slot-{slot}")),
            format!("unknown-{slot}"),
        )?;
    }
    let read_only_path = staging.join(".omabox-download-slot-1");
    std::fs::set_permissions(&read_only_path, std::fs::Permissions::from_mode(0o400))?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    let operations = planned_operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote),
    ))?;
    let _ = journal.record_plan(Path::new("fallback.txt"), &operations)?;

    let report = drive_replay(&mut journal, &client, &mut downloads, &root, &staging)??;

    assert_eq!(report.completed_operations, 1);
    assert_eq!(std::fs::read(root.join("fallback.txt"))?, bytes);
    assert!(
        std::fs::symlink_metadata(&socket_path)?
            .file_type()
            .is_socket()
    );
    for slot in 1..4 {
        assert_eq!(
            std::fs::read_to_string(staging.join(format!(".omabox-download-slot-{slot}")))?,
            format!("unknown-{slot}")
        );
    }
    let requests = server.finish()?;
    assert_eq!(requests.len(), 1);
    assert!(header(&requests[0], "range").is_none());
    Ok(())
}

#[test]
fn root_swap_after_replay_validation_never_touches_the_replacement() -> Result<(), Box<dyn Error>> {
    let bytes = b"descriptor-bound download";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("root-swap-revision"));
    let response = FakeResponse::bytes(bytes.to_vec()).header(
        "Dropbox-API-Result",
        download_metadata(
            "download.txt",
            remote.revision.as_str(),
            &content,
            bytes.len(),
        ),
    );
    let (response, gate) = response.gated();
    let server = FakeServer::start(vec![response])?;
    let client = Arc::new(fake_client(&server, "opaque-access-root-swap-download")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let old_root = directory.path().join("old-root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    let path = Path::new("download.txt");
    let operation_plan = planned_operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote),
    ))?;
    if !matches!(
        journal.record_plan(path, &operation_plan)?,
        PlanWrite::Recorded(_)
    ) {
        return Err(io::Error::other("fresh root-swap plan was already pending").into());
    }

    let dispatched = replay_pending(&mut journal, &client, &mut downloads, &root, &staging)?;
    assert_eq!(dispatched.completed_operations, 0);
    gate.request_received.recv().map_err(|_| {
        io::Error::other("fake Dropbox server stopped before receiving the request")
    })?;
    std::fs::rename(&root, &old_root)?;
    std::fs::create_dir(&root)?;
    std::fs::write(root.join("canary.txt"), b"replacement bytes")?;
    gate.release_response
        .send(())
        .map_err(|_| io::Error::other("fake Dropbox response worker stopped before release"))?;

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let staged = std::fs::read_dir(&old_root)?.any(|entry| {
            entry.is_ok_and(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".omabox-download-")
            })
        });
        if staged {
            break;
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "descriptor-bound download was not staged",
            )
            .into());
        }
        thread::yield_now();
    }

    let outcome = replay_pending(&mut journal, &client, &mut downloads, &root, &staging);

    assert!(matches!(outcome, Err(ReconcileError::LocalRootChanged)));
    assert_eq!(
        std::fs::read(root.join("canary.txt"))?,
        b"replacement bytes"
    );
    let replacement_names = std::fs::read_dir(&root)?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<Result<Vec<_>, _>>()?;
    assert_eq!(
        replacement_names,
        vec![std::ffi::OsString::from("canary.txt")]
    );
    assert_eq!(journal.pending_plans()?.len(), 1);
    assert_eq!(journal.baseline(path)?, None);
    assert!(!old_root.join(path).exists());
    assert!(
        std::fs::read_dir(&old_root)?.any(|entry| entry.is_ok_and(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".omabox-download-")
        }))
    );
    assert_eq!(server.finish()?.len(), 1);
    Ok(())
}

#[test]
fn completed_download_batch_is_installed_before_the_next_batch_fails() -> Result<(), Box<dyn Error>>
{
    const DOWNLOAD_COUNT: usize = 5;
    const COMPLETED_BATCH: usize = 4;

    let bytes = b"install each bounded batch";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("batch-revision"));
    let metadata = download_metadata("batch.txt", remote.revision.as_str(), &content, bytes.len());
    let mut responses = (0..COMPLETED_BATCH)
        .map(|_| FakeResponse::bytes(bytes.to_vec()).header("Dropbox-API-Result", metadata.clone()))
        .collect::<Vec<_>>();
    responses.push(FakeResponse::status_json(
        500,
        json!({"error": "later batch"}),
    ));
    let server = FakeServer::start(responses)?;
    let client = Arc::new(fake_client(&server, "opaque-access-batches")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    let operation_plan = planned_operations(plan(
        &Baseline::Absent,
        &Observation::ConfirmedAbsent,
        &Observation::Present(remote),
    ))?;
    let paths = (0..DOWNLOAD_COUNT)
        .map(|index| PathBuf::from(format!("batch-{index}.txt")))
        .collect::<Vec<_>>();
    for path in &paths {
        if !matches!(
            journal.record_plan(path, &operation_plan)?,
            PlanWrite::Recorded(_)
        ) {
            return Err(io::Error::other("fresh batch plan was already pending").into());
        }
    }

    assert!(drive_replay(&mut journal, &client, &mut downloads, &root, &staging,)?.is_err());

    let installed = paths
        .iter()
        .filter(|path| root.join(path).is_file())
        .collect::<Vec<_>>();
    assert_eq!(installed.len(), COMPLETED_BATCH);
    for path in installed {
        assert_eq!(std::fs::read(root.join(path))?, bytes);
    }
    let pending = journal.pending_plans()?;
    let [pending] = pending.as_slice() else {
        return Err(io::Error::other("exactly one failed download must remain pending").into());
    };
    assert!(!root.join(&pending.path).exists());
    assert_eq!(server.finish()?.len(), DOWNLOAD_COUNT);
    Ok(())
}

#[test]
fn corrupt_exact_download_never_leaves_installable_bytes() -> Result<(), Box<dyn Error>> {
    let expected_bytes = b"expected download";
    let corrupt_bytes = b"corrupt response";
    let expected = dropbox_content_hash(expected_bytes.as_slice())?;
    let actual = dropbox_content_hash(corrupt_bytes.as_slice())?;
    let server = FakeServer::start(vec![FakeResponse::bytes(corrupt_bytes.to_vec()).header(
        "Dropbox-API-Result",
        download_metadata("corrupt.txt", "rev-corrupt", &expected, corrupt_bytes.len()),
    )])?;
    let client = fake_client(&server, "opaque-access-corrupt")?;
    let root = TempDir::new()?;
    let remote = RemoteFile::new(expected, DropboxRevision::new("rev-corrupt"));

    assert_eq!(
        client.stage_exact_download(root.path(), "corrupt.txt", &remote)?,
        StageOutcome::ContentChanged { actual }
    );
    assert!(!root.path().join("corrupt.txt").exists());
    assert!(std::fs::read_dir(root.path())?.next().is_none());
    let requests = server.finish()?;
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].path, "/2/files/download");
    Ok(())
}

#[test]
fn oauth_rate_limit_preserves_retry_after_header() -> Result<(), Box<dyn Error>> {
    let server = FakeServer::start(vec![
        FakeResponse::status_json(429, json!({})).header("Retry-After", "23"),
    ])?;
    let oauth = OAuthClient::with_endpoints("app-key", server.endpoints());

    assert!(matches!(
        oauth.refresh(&RefreshToken::from_secret("opaque-refresh")),
        Err(AuthError::RateLimited {
            operation: "refresh access token",
            retry_after: Some(delay),
        }) if delay == Duration::from_secs(23)
    ));
    assert_eq!(server.finish()?.len(), 1);
    Ok(())
}

#[test]
fn long_poll_exposes_reset_and_rate_limit_outcomes() -> Result<(), Box<dyn Error>> {
    let server = FakeServer::start(vec![
        FakeResponse::status_json(
            409,
            json!({"error_summary": "reset/", "error": {".tag": "reset"}}),
        ),
        FakeResponse::status_json(429, json!({})).header("Retry-After", "17"),
    ])?;
    let client = fake_client(&server, "opaque-access-long-poll")?;

    assert_eq!(
        client.long_poll("old-cursor", Duration::from_secs(30))?,
        omabox::dropbox::LongPollWakeup::CursorReset
    );
    assert!(matches!(
        client.long_poll("new-cursor", Duration::from_secs(30)),
        Err(DropboxError::RateLimited {
            operation: "wait for Dropbox changes",
            retry_after: Some(delay),
        }) if delay == Duration::from_secs(17)
    ));
    let requests = server.finish()?;
    assert_eq!(requests.len(), 2);
    assert!(
        requests
            .iter()
            .all(|request| request.path == "/2/files/list_folder/longpoll")
    );
    Ok(())
}

#[test]
fn replaced_local_root_never_replays_pending_deletion() -> Result<(), Box<dyn Error>> {
    let server = FakeServer::start(Vec::new())?;
    let client = Arc::new(fake_client(&server, "opaque-access-root-replacement")?);
    let mut downloads = ExactDownloadPool::new(Arc::clone(&client))?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let old_root = directory.path().join("old-root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;

    let path = Path::new("keep.txt");
    let bytes = b"must not be deleted from a replacement root";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("rev-old"));
    std::fs::write(root.join(path), bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.activate_local_root(&LocalRootBinding::inspect(&root)?)?;
    seed_baseline(&mut journal, path, &remote)?;
    let deletion = planned_operations(plan(
        &Baseline::Present(remote),
        &Observation::Present(LocalFile::new(content)),
        &Observation::ConfirmedAbsent,
    ))?;
    let _ = journal.record_plan(path, &deletion)?;

    std::fs::rename(&root, &old_root)?;
    std::fs::create_dir(&root)?;
    std::fs::write(root.join(path), bytes)?;

    assert_eq!(
        reconcile_once(
            &mut journal,
            &client,
            &mut downloads,
            &root,
            &staging,
            &recovery,
        )?,
        ReconcileOutcome::LocalRootChanged
    );
    assert_eq!(std::fs::read(root.join(path))?, bytes);
    assert_eq!(journal.pending_plans()?.len(), 1);
    assert!(server.finish()?.is_empty());
    Ok(())
}

#[test]
fn conditional_mutations_use_strict_documented_requests() -> Result<(), Box<dyn Error>> {
    let bytes = b"immutable upload payload";
    let fixture = upload_fixture(bytes)?;
    let content = fixture.staged.content().clone();
    let unicode_path = "Café/雪.txt";
    let server = FakeServer::start(vec![
        FakeResponse::json(file_metadata(
            "/café/雪.txt",
            "/Café/雪.txt",
            "created-rev",
            &content,
        )),
        FakeResponse::json(file_metadata(
            "/replace.txt",
            "/Replace.txt",
            "replacement-rev",
            &content,
        )),
        FakeResponse::json(json!({
            "metadata": file_metadata(
                "/delete.txt",
                "/Delete.txt",
                "delete-rev",
                &content,
            )
        })),
        FakeResponse::json(json!({
            "metadata": {
                ".tag": "folder",
                "path_lower": "/folder",
                "path_display": "/Folder"
            }
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-writes")?;

    assert_eq!(
        client.create_file(unicode_path, &fixture.staged)?,
        MutationOutcome::Applied(RemotePathState::File(RemoteFile::new(
            content.clone(),
            DropboxRevision::new("created-rev"),
        )))
    );
    assert_eq!(
        client.replace_file(
            "Replace.txt",
            &DropboxRevision::new("expected-rev"),
            &fixture.staged,
        )?,
        MutationOutcome::Applied(RemotePathState::File(RemoteFile::new(
            content.clone(),
            DropboxRevision::new("replacement-rev"),
        )))
    );
    assert_eq!(
        client.delete_file("Delete.txt", &DropboxRevision::new("delete-rev"))?,
        MutationOutcome::Applied(RemotePathState::Absent)
    );
    assert_eq!(
        client.create_folder("Folder")?,
        MutationOutcome::Applied(RemotePathState::Folder)
    );

    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
    assert_eq!(requests[0].path, "/2/files/upload");
    assert_eq!(requests[0].body, bytes);
    assert_eq!(
        header(&requests[0], "content-type"),
        Some("application/octet-stream")
    );
    let create_argument = required_header(&requests[0], "dropbox-api-arg")?;
    assert!(create_argument.is_ascii());
    assert!(create_argument.contains(r#"\u00e9"#));
    assert!(create_argument.contains(r#"\u96ea"#));
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(create_argument)?,
        json!({
            "path": format!("/{unicode_path}"),
            "mode": "add",
            "autorename": false,
            "strict_conflict": true,
            "content_hash": content.as_str()
        })
    );

    assert_eq!(requests[1].path, "/2/files/upload");
    assert_eq!(requests[1].body, bytes);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(required_header(
            &requests[1],
            "dropbox-api-arg"
        )?)?,
        json!({
            "path": "/Replace.txt",
            "mode": {".tag": "update", "update": "expected-rev"},
            "autorename": false,
            "strict_conflict": true,
            "content_hash": content.as_str()
        })
    );

    assert_eq!(requests[2].path, "/2/files/delete_v2");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&requests[2].body)?,
        json!({"path": "/Delete.txt", "parent_rev": "delete-rev"})
    );
    assert_eq!(requests[3].path, "/2/files/create_folder_v2");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&requests[3].body)?,
        json!({"path": "/Folder", "autorename": false})
    );
    assert!(requests.iter().all(|request| {
        header(request, "authorization") == Some("Bearer opaque-access-writes")
            && header(request, "dropbox-api-path-root")
                == Some(r#"{".tag":"root","root":"namespace"}"#)
    }));
    Ok(())
}

#[test]
fn explicit_conflict_uses_current_metadata_without_inventing_retry_safety()
-> Result<(), Box<dyn Error>> {
    let fixture = upload_fixture(b"new local bytes")?;
    let desired = fixture.staged.content().clone();
    let current = dropbox_content_hash(b"different remote bytes".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::status_json(409, json!({"error": {".tag": "path"}})),
        FakeResponse::json(file_metadata(
            "/conflict.txt",
            "/Conflict.txt",
            "current-rev",
            &current,
        )),
        FakeResponse::status_json(409, json!({"error": {".tag": "path"}})),
        FakeResponse::json(json!({
            ".tag": "deleted",
            "path_lower": "/unchanged.txt",
            "path_display": "/Unchanged.txt"
        })),
        FakeResponse::status_json(409, json!({"error": {".tag": "path"}})),
        FakeResponse::json(file_metadata(
            "/same.txt",
            "/Same.txt",
            "same-rev",
            &desired,
        )),
        FakeResponse::status_json(409, json!({"error": {".tag": "path"}})),
        FakeResponse::json(json!({
            ".tag": "file",
            "path_lower": "/incomplete.txt",
            "path_display": "/Incomplete.txt"
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-conflict")?;

    assert_eq!(
        client.create_file("Conflict.txt", &fixture.staged)?,
        MutationOutcome::PreconditionChanged(RemotePathState::File(RemoteFile::new(
            current,
            DropboxRevision::new("current-rev"),
        )))
    );
    assert!(matches!(
        client.create_file("Unchanged.txt", &fixture.staged),
        Err(DropboxError::HttpStatus {
            operation: "strictly create Dropbox file",
            status: 409,
        })
    ));
    assert!(matches!(
        client.replace_file(
            "Same.txt",
            &DropboxRevision::new("same-rev"),
            &fixture.staged,
        ),
        Err(DropboxError::HttpStatus {
            operation: "conditionally replace Dropbox file",
            status: 409,
        })
    ));
    assert!(matches!(
        client.delete_file("Incomplete.txt", &DropboxRevision::new("expected-rev")),
        Err(DropboxError::HttpStatus {
            operation: "conditionally delete Dropbox file",
            status: 409,
        })
    ));

    let requests = server.finish()?;
    assert_eq!(requests.len(), 8);
    let (pairs, remainder) = requests.as_chunks::<2>();
    assert!(remainder.is_empty());
    for pair in pairs {
        assert_eq!(pair[1].path, "/2/files/get_metadata");
        assert!(metadata_request_includes_deleted(&pair[1])?);
    }
    Ok(())
}

#[test]
fn ambiguous_mutations_are_verified_once_and_preserve_the_original_failure()
-> Result<(), Box<dyn Error>> {
    let fixture = upload_fixture(b"desired bytes")?;
    let desired = fixture.staged.content().clone();
    let old = dropbox_content_hash(b"old bytes".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::status_json(503, json!({})),
        FakeResponse::json(file_metadata(
            "/replace.txt",
            "/Replace.txt",
            "applied-rev",
            &desired,
        )),
        FakeResponse::status_json(503, json!({})),
        FakeResponse::json(file_metadata("/delete.txt", "/Delete.txt", "old-rev", &old)),
        FakeResponse::status_json(503, json!({})),
        FakeResponse::status_json(
            409,
            json!({
                "error": {".tag": "path", "path": {".tag": "not_found"}}
            }),
        ),
        FakeResponse::status_json(503, json!({})),
        FakeResponse::status_json(
            409,
            json!({
                "error": {".tag": "path", "path": {".tag": "restricted_content"}}
            }),
        ),
        FakeResponse::json(json!({})),
        FakeResponse::json(file_metadata(
            "/created.txt",
            "/Created.txt",
            "created-rev",
            &desired,
        )),
        FakeResponse::status_json(503, json!({})),
        FakeResponse::json(file_metadata(
            "/same.txt",
            "/Same.txt",
            "same-rev",
            &desired,
        )),
        FakeResponse::status_json(503, json!({})),
        FakeResponse::json(json!({
            ".tag": "file",
            "path_lower": "/incomplete.txt",
            "path_display": "/Incomplete.txt",
            "rev": "expected-rev"
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-ambiguous")?;

    assert_eq!(
        client.replace_file(
            "Replace.txt",
            &DropboxRevision::new("old-rev"),
            &fixture.staged,
        )?,
        MutationOutcome::Applied(RemotePathState::File(RemoteFile::new(
            desired.clone(),
            DropboxRevision::new("applied-rev"),
        )))
    );
    assert_eq!(
        client.delete_file("Delete.txt", &DropboxRevision::new("old-rev"))?,
        MutationOutcome::Pending
    );
    assert_eq!(
        client.delete_file("Gone.txt", &DropboxRevision::new("gone-rev"))?,
        MutationOutcome::Applied(RemotePathState::Absent)
    );
    assert!(matches!(
        client.create_folder("Blocked"),
        Err(DropboxError::HttpStatus {
            operation: "strictly create Dropbox folder",
            status: 503,
        })
    ));
    assert_eq!(
        client.create_file("Created.txt", &fixture.staged)?,
        MutationOutcome::Applied(RemotePathState::File(RemoteFile::new(
            desired,
            DropboxRevision::new("created-rev"),
        )))
    );
    assert_eq!(
        client.replace_file(
            "Same.txt",
            &DropboxRevision::new("same-rev"),
            &fixture.staged,
        )?,
        MutationOutcome::Pending
    );
    assert!(matches!(
        client.delete_file("Incomplete.txt", &DropboxRevision::new("expected-rev")),
        Err(DropboxError::HttpStatus {
            operation: "conditionally delete Dropbox file",
            status: 503,
        })
    ));

    let requests = server.finish()?;
    assert_eq!(requests.len(), 14);
    let (pairs, remainder) = requests.as_chunks::<2>();
    assert!(remainder.is_empty());
    for pair in pairs {
        assert_eq!(pair[1].path, "/2/files/get_metadata");
        assert!(metadata_request_includes_deleted(&pair[1])?);
    }
    Ok(())
}

#[test]
fn remote_replay_preserves_conflict_sides_without_a_backup_download() -> Result<(), Box<dyn Error>>
{
    let old_bytes = b"common bytes";
    let local_bytes = b"new local bytes";
    let remote_bytes = b"new remote bytes";
    let old = RemoteFile::new(
        dropbox_content_hash(old_bytes.as_slice())?,
        DropboxRevision::new("old-rev"),
    );
    let local = LocalFile::new(dropbox_content_hash(local_bytes.as_slice())?);
    let current = RemoteFile::new(
        dropbox_content_hash(remote_bytes.as_slice())?,
        DropboxRevision::new("current-rev"),
    );
    let current_metadata = download_metadata(
        "replace.txt",
        "current-rev",
        &current.content,
        remote_bytes.len(),
    );
    let server = FakeServer::start(vec![
        FakeResponse::status_json(409, json!({"error": {".tag": "path"}})),
        FakeResponse::json(file_metadata(
            "/replace.txt",
            "/Replace.txt",
            "current-rev",
            &current.content,
        )),
        FakeResponse::bytes(remote_bytes.to_vec()).header("Dropbox-API-Result", current_metadata),
    ])?;
    let client = fake_client(&server, "opaque-access-replay-conflict")?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("replace.txt"), local_bytes)?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    seed_baseline(&mut journal, Path::new("replace.txt"), &old)?;
    let operations = planned_operations(plan(
        &Baseline::Present(old.clone()),
        &Observation::Present(local.clone()),
        &Observation::Present(old.clone()),
    ))?;
    assert!(matches!(
        journal.record_plan(Path::new("replace.txt"), &operations)?,
        PlanWrite::Recorded(_)
    ));

    let report = replay_remote_operations(&mut journal, &client, &root, &staging)?;
    assert_eq!(report.completed_operations, 1);
    assert!(report.blocked.is_empty());
    assert!(journal.pending_plans()?.is_empty());
    assert_eq!(
        journal.baseline(Path::new("replace.txt"))?,
        Some(Baseline::Present(old.clone()))
    );
    assert_eq!(
        journal.conflicts()?.as_slice(),
        [omabox::journal::ConflictRecord {
            id: 1,
            path: Path::new("replace.txt").to_path_buf(),
            conflict: Conflict::DivergentEdits {
                local: local.clone(),
                remote: current.clone(),
            },
        }]
    );
    assert!(recovery.read_dir()?.next().is_none());
    assert!(journal.pending_recoveries()?.is_empty());
    assert!(journal.completed_recoveries()?.is_empty());
    assert_eq!(
        conflict_bytes(&root)?,
        vec![local_bytes.to_vec(), remote_bytes.to_vec()]
    );

    let requests = server.finish()?;
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[0].path, "/2/files/upload");
    assert_eq!(requests[1].path, "/2/files/get_metadata");
    assert_eq!(requests[2].path, "/2/files/download");
    assert!(required_header(&requests[2], "dropbox-api-arg")?.contains("rev:current-rev"));
    Ok(())
}

#[test]
fn remote_replay_creates_nested_parents_before_the_file() -> Result<(), Box<dyn Error>> {
    let bytes = b"nested bytes";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "metadata": {
                ".tag": "folder",
                "path_lower": "/one",
                "path_display": "/one"
            }
        })),
        FakeResponse::json(json!({
            "metadata": {
                ".tag": "folder",
                "path_lower": "/one/two",
                "path_display": "/one/two"
            }
        })),
        FakeResponse::json(file_metadata(
            "/one/two/file.txt",
            "/one/two/file.txt",
            "created-rev",
            &content,
        )),
    ])?;
    let client = fake_client(&server, "opaque-access-nested-create")?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("one/two"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("one/two/file.txt"), bytes)?;
    let operations = planned_operations(plan(
        &Baseline::Absent,
        &Observation::Present(LocalFile::new(content.clone())),
        &Observation::ConfirmedAbsent,
    ))?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    assert!(matches!(
        journal.record_plan(Path::new("one/two/file.txt"), &operations)?,
        PlanWrite::Recorded(_)
    ));

    let report = replay_remote_operations(&mut journal, &client, &root, &staging)?;
    assert_eq!(report.completed_operations, 1);
    assert!(report.blocked.is_empty());
    assert_eq!(
        journal.baseline(Path::new("one/two/file.txt"))?,
        Some(Baseline::Present(RemoteFile::new(
            content,
            DropboxRevision::new("created-rev"),
        )))
    );
    let requests = server.finish()?;
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[0].path, "/2/files/create_folder_v2");
    assert_eq!(requests[1].path, "/2/files/create_folder_v2");
    assert_eq!(requests[2].path, "/2/files/upload");
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&requests[0].body)?,
        json!({"path": "/one", "autorename": false})
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&requests[1].body)?,
        json!({"path": "/one/two", "autorename": false})
    );
    Ok(())
}

#[test]
fn stale_create_source_has_no_remote_effect() -> Result<(), Box<dyn Error>> {
    let expected = dropbox_content_hash(b"planned bytes".as_slice())?;
    let actual = dropbox_content_hash(b"changed bytes".as_slice())?;
    let server = FakeServer::start(Vec::new())?;
    let client = fake_client(&server, "opaque-access-stale-create")?;
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(root.join("nested"))?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    std::fs::write(root.join("nested/file.txt"), b"changed bytes")?;
    let operations = planned_operations(plan(
        &Baseline::Absent,
        &Observation::Present(LocalFile::new(expected)),
        &Observation::ConfirmedAbsent,
    ))?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    assert!(matches!(
        journal.record_plan(Path::new("nested/file.txt"), &operations)?,
        PlanWrite::Recorded(_)
    ));

    let report = replay_remote_operations(&mut journal, &client, &root, &staging)?;
    assert_eq!(
        report.blocked,
        vec![ReplayBlocked::PreconditionChanged {
            path: Path::new("nested/file.txt").to_path_buf(),
            actual: Some(actual),
        }]
    );
    assert!(server.finish()?.is_empty());
    assert_eq!(journal.pending_plans()?.len(), 1);
    Ok(())
}

#[test]
fn remote_delete_skips_backup_download_and_ambiguous_create_stays_pending()
-> Result<(), Box<dyn Error>> {
    let old_bytes = b"old remote bytes";
    let old = RemoteFile::new(
        dropbox_content_hash(old_bytes.as_slice())?,
        DropboxRevision::new("old-rev"),
    );
    let directory = TempDir::new()?;
    let root = directory.path().join("root");
    let staging = directory.path().join("staging");
    let recovery = directory.path().join("recovery");
    std::fs::create_dir_all(&root)?;
    std::fs::create_dir_all(&staging)?;
    std::fs::create_dir_all(&recovery)?;
    let database = directory.path().join("journal.sqlite3");
    let mut journal = Journal::open(&database)?;
    let delete = planned_operations(plan(
        &Baseline::Present(old.clone()),
        &Observation::ConfirmedAbsent,
        &Observation::Present(old.clone()),
    ))?;
    match journal.record_plan(Path::new("delete.txt"), &delete)? {
        PlanWrite::Recorded(_) => {}
        PlanWrite::AlreadyPending(_) => {
            return Err(io::Error::other("test expected a new delete plan").into());
        }
    }
    let delete_server = FakeServer::start(vec![FakeResponse::json(json!({
        "metadata": file_metadata("/delete.txt", "/Delete.txt", "old-rev", &old.content)
    }))])?;
    let delete_client = fake_client(&delete_server, "opaque-access-replay-delete")?;
    let report = replay_remote_operations(&mut journal, &delete_client, &root, &staging)?;
    assert_eq!(report.completed_operations, 1);
    assert!(recovery.read_dir()?.next().is_none());
    assert!(journal.pending_recoveries()?.is_empty());
    assert!(journal.completed_recoveries()?.is_empty());
    let requests = delete_server.finish()?;
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].path, "/2/files/delete_v2");

    std::fs::write(root.join("create.txt"), b"desired bytes")?;
    let desired = LocalFile::new(dropbox_content_hash(b"desired bytes".as_slice())?);
    let create = planned_operations(plan(
        &Baseline::Absent,
        &Observation::Present(desired),
        &Observation::ConfirmedAbsent,
    ))?;
    assert!(matches!(
        journal.record_plan(Path::new("create.txt"), &create)?,
        PlanWrite::Recorded(_)
    ));
    let pending_server = FakeServer::start(vec![
        FakeResponse::status_json(503, json!({})),
        FakeResponse::status_json(
            409,
            json!({"error": {".tag": "path", "path": {".tag": "not_found"}}}),
        ),
    ])?;
    let pending_client = fake_client(&pending_server, "opaque-access-replay-pending")?;
    let pending = replay_remote_operations(&mut journal, &pending_client, &root, &staging)?;
    assert_eq!(
        pending.blocked,
        vec![ReplayBlocked::RemotePending {
            path: Path::new("create.txt").to_path_buf(),
        }]
    );
    assert_eq!(pending_server.finish()?.len(), 2);
    drop(journal);
    assert_eq!(Journal::open(&database)?.pending_plans()?.len(), 1);
    Ok(())
}

#[test]
fn link_rejects_unavailable_file_and_restricted_roots() -> Result<(), Box<dyn Error>> {
    assert!(matches!(
        root_link_failure(FakeResponse::status_json(
            409,
            json!({"error": {".tag": "path"}})
        ))?,
        DropboxError::RemoteRootUnavailable
    ));
    assert!(matches!(
        root_link_failure(FakeResponse::json(json!({
            ".tag": "file",
            "path_lower": "/sync",
            "path_display": "/Sync"
        })))?,
        DropboxError::RemoteRootNotFolder
    ));
    for restriction in [json!({"no_access": true}), json!({"traverse_only": true})] {
        assert!(matches!(
            root_link_failure(FakeResponse::json(json!({
                ".tag": "folder",
                "path_lower": "/sync",
                "path_display": "/Sync",
                "sharing_info": restriction
            })))?,
            DropboxError::RemoteRootRestricted
        ));
    }

    Ok(())
}

#[test]
fn one_file_cursor_delta_updates_a_large_inventory_without_a_full_listing()
-> Result<(), Box<dyn Error>> {
    const INVENTORY_SIZE: usize = 10_000;

    let old_content = dropbox_content_hash(b"old inventory bytes".as_slice())?;
    let new_content = dropbox_content_hash(b"new inventory bytes".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [file_metadata(
                "/bulk/05000.txt",
                "/Bulk/05000.txt",
                "rev-new",
                &new_content,
            )],
            "cursor": "cursor-new",
            "has_more": false
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-large-delta")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let mut observations = Vec::with_capacity(INVENTORY_SIZE);
    observations.push(RemoteObservationRecord {
        canonical_path: PathBuf::from("bulk"),
        path: PathBuf::from("Bulk"),
        observation: Observation::Directory,
    });
    for index in 1..INVENTORY_SIZE {
        let name = format!("{index:05}.txt");
        observations.push(RemoteObservationRecord {
            canonical_path: PathBuf::from("bulk").join(&name),
            path: PathBuf::from("Bulk").join(name),
            observation: Observation::Present(RemoteFile::new(
                old_content.clone(),
                DropboxRevision::new("rev-old"),
            )),
        });
    }
    journal.publish_remote_inventory("cursor-old", &observations)?;

    assert_eq!(
        client.refresh_inventory(&mut journal)?,
        InventoryRefresh::Published
    );
    let inventory = journal.remote_inventory()?;
    assert_eq!(inventory.cursor.as_deref(), Some("cursor-new"));
    assert_eq!(inventory.observations.len(), INVENTORY_SIZE);
    assert_eq!(
        observation(&inventory, Path::new("Bulk/05000.txt")),
        Some(&Observation::Present(RemoteFile::new(
            new_content,
            DropboxRevision::new("rev-new")
        )))
    );
    let requests = server.finish()?;
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[1].path, "/2/files/list_folder/continue");
    assert!(
        requests
            .iter()
            .all(|request| request.path != "/2/files/list_folder")
    );
    Ok(())
}

#[test]
fn cursor_reset_rebuilds_before_one_complete_publication() -> Result<(), Box<dyn Error>> {
    let replacement = dropbox_content_hash(b"replacement".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::status_json(
            409,
            json!({"error_summary": "reset/", "error": {".tag": "reset"}}),
        ),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "folder",
                "path_lower": "/folder",
                "path_display": "/Folder"
            }],
            "cursor": "fresh-a",
            "has_more": true
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/new.txt",
                "path_display": "/New.txt",
                "rev": "rev-new",
                "content_hash": replacement.as_str()
            }],
            "cursor": "fresh-b",
            "has_more": false
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-reset")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let old = RemoteObservationRecord {
        canonical_path: Path::new("old.txt").to_path_buf(),
        path: Path::new("Old.txt").to_path_buf(),
        observation: Observation::Present(RemoteFile::new(
            ContentIdentity::new("old"),
            DropboxRevision::new("rev-old"),
        )),
    };
    journal.publish_remote_inventory("stale", &[old])?;

    assert_eq!(
        client.refresh_inventory(&mut journal)?,
        InventoryRefresh::RebuiltAfterCursorReset
    );
    let inventory = journal.remote_inventory()?;
    assert_eq!(inventory.cursor.as_deref(), Some("fresh-b"));
    assert!(observation(&inventory, Path::new("Old.txt")).is_none());
    assert!(matches!(
        observation(&inventory, Path::new("New.txt")),
        Some(Observation::Present(_))
    ));
    assert_eq!(
        observation(&inventory, Path::new("Folder")),
        Some(&Observation::Directory)
    );
    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
    Ok(())
}

#[test]
fn failed_rebuild_after_cursor_reset_preserves_durable_inventory() -> Result<(), Box<dyn Error>> {
    let old_content = dropbox_content_hash(b"durable old bytes".as_slice())?;
    let partial_content = dropbox_content_hash(b"uncommitted replacement".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::status_json(
            409,
            json!({"error_summary": "reset/", "error": {".tag": "reset"}}),
        ),
        FakeResponse::json(json!({
            "entries": [file_metadata(
                "/replacement.txt",
                "/Replacement.txt",
                "rev-partial",
                &partial_content,
            )],
            "cursor": "fresh-partial",
            "has_more": true
        })),
        FakeResponse::status_json(503, json!({"error": {".tag": "other"}})),
    ])?;
    let client = fake_client(&server, "opaque-access-failed-reset-rebuild")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let old = RemoteObservationRecord {
        canonical_path: Path::new("old.txt").to_path_buf(),
        path: Path::new("Old.txt").to_path_buf(),
        observation: Observation::Present(RemoteFile::new(
            old_content,
            DropboxRevision::new("rev-old"),
        )),
    };
    let durable_cursor = "durable-cursor";
    let durable = RemoteInventory {
        cursor: Some(String::from(durable_cursor)),
        observations: vec![old],
    };
    journal.publish_remote_inventory(durable_cursor, &durable.observations)?;

    assert!(client.refresh_inventory(&mut journal).is_err());
    assert_eq!(journal.remote_inventory()?, durable);
    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
    assert_eq!(requests[1].path, "/2/files/list_folder/continue");
    assert_eq!(requests[2].path, "/2/files/list_folder");
    assert_eq!(requests[3].path, "/2/files/list_folder/continue");
    Ok(())
}

#[test]
fn listing_applies_ordered_tree_mutations_across_pages() -> Result<(), Box<dyn Error>> {
    let identity = dropbox_content_hash(b"tree payload".as_slice())?;
    let file = |path_lower: &str, path_display: &str| {
        json!({
            ".tag": "file",
            "path_lower": path_lower,
            "path_display": path_display,
            "rev": "tree-revision",
            "content_hash": identity.as_str()
        })
    };
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [
                {".tag": "folder", "path_lower": "/node", "path_display": "/Node"},
                file("/node/child", "/Node/Child"),
                {".tag": "folder", "path_lower": "/gone", "path_display": "/Gone"},
                file("/gone/child", "/Gone/Child"),
                file("/ancestor", "/Ancestor"),
                file("/keep/child", "/Keep/Child")
            ],
            "cursor": "tree-a",
            "has_more": true
        })),
        FakeResponse::json(json!({
            "entries": [
                file("/node", "/Node"),
                {".tag": "deleted", "path_lower": "/gone", "path_display": "/Gone"},
                file("/ancestor/leaf", "/Ancestor/Leaf"),
                {".tag": "folder", "path_lower": "/keep", "path_display": "/Keep"},
                {".tag": "deleted", "path_lower": "/phantom/leaf", "path_display": "/Phantom/Leaf"}
            ],
            "cursor": "tree-b",
            "has_more": false
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-tree")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;

    assert_eq!(
        client.refresh_inventory(&mut journal)?,
        InventoryRefresh::Published
    );
    let inventory = journal.remote_inventory()?;
    assert_eq!(inventory.observations.len(), 5);
    assert!(matches!(
        observation(&inventory, Path::new("Node")),
        Some(Observation::Present(_))
    ));
    assert!(observation(&inventory, Path::new("Node/Child")).is_none());
    assert!(observation(&inventory, Path::new("Gone")).is_none());
    assert!(observation(&inventory, Path::new("Gone/Child")).is_none());
    for folder in [Path::new("Ancestor"), Path::new("Keep")] {
        assert_eq!(
            observation(&inventory, folder),
            Some(&Observation::Directory)
        );
    }
    assert!(matches!(
        observation(&inventory, Path::new("Ancestor/Leaf")),
        Some(Observation::Present(_))
    ));
    assert!(matches!(
        observation(&inventory, Path::new("Keep/Child")),
        Some(Observation::Present(_))
    ));
    assert!(observation(&inventory, Path::new("Phantom")).is_none());
    let requests = server.finish()?;
    assert_eq!(requests.len(), 3);
    Ok(())
}

#[test]
fn failed_later_page_cannot_publish_partial_listing_as_absence() -> Result<(), Box<dyn Error>> {
    let changed = dropbox_content_hash(b"changed".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/old.txt",
                "path_display": "/Old.txt",
                "rev": "rev-changed",
                "content_hash": changed.as_str()
            }],
            "cursor": "next",
            "has_more": true
        })),
        FakeResponse::status_json(503, json!({"error": {".tag": "other"}})),
    ])?;
    let client = fake_client(&server, "opaque-access-partial")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let old = RemoteObservationRecord {
        canonical_path: Path::new("old.txt").to_path_buf(),
        path: Path::new("Old.txt").to_path_buf(),
        observation: Observation::Present(RemoteFile::new(
            ContentIdentity::new("durable-old"),
            DropboxRevision::new("rev-old"),
        )),
    };
    journal.publish_remote_inventory("durable-cursor", std::slice::from_ref(&old))?;

    assert!(client.refresh_inventory(&mut journal).is_err());
    assert_eq!(
        journal.remote_inventory()?,
        RemoteInventory {
            cursor: Some(String::from("durable-cursor")),
            observations: vec![old],
        }
    );
    let requests = server.finish()?;
    assert_eq!(requests.len(), 3);
    assert_eq!(requests[1].path, "/2/files/list_folder/continue");
    assert_eq!(requests[2].path, "/2/files/list_folder/continue");
    Ok(())
}

#[test]
fn incomplete_downloadable_metadata_cannot_replace_durable_inventory() -> Result<(), Box<dyn Error>>
{
    let changed = dropbox_content_hash(b"validated first page".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/partial.txt",
                "path_display": "/Partial.txt",
                "rev": "rev-partial",
                "content_hash": changed.as_str()
            }],
            "cursor": "partial",
            "has_more": true
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/incomplete.txt",
                "path_display": "/Incomplete.txt",
                "rev": "rev-incomplete",
                "is_downloadable": true
            }],
            "cursor": "new",
            "has_more": false
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-metadata")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let old = RemoteObservationRecord {
        canonical_path: Path::new("old.txt").to_path_buf(),
        path: Path::new("Old.txt").to_path_buf(),
        observation: Observation::Unknown(UnknownReason::Stale),
    };
    journal.publish_remote_inventory("durable", std::slice::from_ref(&old))?;

    assert!(matches!(
        client.refresh_inventory(&mut journal),
        Err(DropboxError::IncompleteFileMetadata)
    ));
    assert_eq!(
        journal.remote_inventory()?,
        RemoteInventory {
            cursor: Some(String::from("durable")),
            observations: vec![old]
        }
    );
    assert_eq!(server.finish()?.len(), 3);
    Ok(())
}

#[test]
fn restricted_later_page_cannot_replace_durable_inventory() -> Result<(), Box<dyn Error>> {
    let identity = dropbox_content_hash(b"partial tree".as_slice())?;
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/partial.txt",
                "path_display": "/Partial.txt",
                "rev": "partial-revision",
                "content_hash": identity.as_str()
            }],
            "cursor": "partial",
            "has_more": true
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "folder",
                "path_lower": "/restricted",
                "path_display": "/Restricted",
                "sharing_info": {"traverse_only": true}
            }],
            "cursor": "restricted",
            "has_more": false
        })),
    ])?;
    let client = fake_client(&server, "opaque-access-restricted")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let durable = RemoteObservationRecord {
        canonical_path: Path::new("durable.txt").to_path_buf(),
        path: Path::new("Durable.txt").to_path_buf(),
        observation: Observation::Unknown(UnknownReason::Stale),
    };
    journal.publish_remote_inventory("durable", std::slice::from_ref(&durable))?;

    assert!(matches!(
        client.refresh_inventory(&mut journal),
        Err(DropboxError::RestrictedRemoteInventory)
    ));
    assert_eq!(
        journal.remote_inventory()?,
        RemoteInventory {
            cursor: Some(String::from("durable")),
            observations: vec![durable]
        }
    );
    assert_eq!(server.finish()?.len(), 3);
    Ok(())
}

#[test]
fn journal_binding_mismatch_blocks_inventory_before_listing() -> Result<(), Box<dyn Error>> {
    let server = FakeServer::start(vec![FakeResponse::json(json!({
        "account_id": "account",
        "root_info": {"root_namespace_id": "namespace"}
    }))])?;
    let client = fake_client(&server, "opaque-access-binding")?;
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
    let _ = journal.bind_dropbox_root(&DropboxBinding {
        account_id: String::from("different-account"),
        root_namespace_id: String::from("namespace"),
        remote_root: String::new(),
    })?;

    assert!(matches!(
        client.refresh_inventory(&mut journal),
        Err(DropboxError::AccountBindingChanged)
    ));
    assert_eq!(server.finish()?.len(), 1);
    Ok(())
}

fn fake_client(server: &FakeServer, access_token: &str) -> Result<DropboxClient, Box<dyn Error>> {
    let endpoints = server.endpoints();
    let access_token = fake_access_token(access_token)?;
    let root = DropboxRoot::new("account", "namespace", "")?;
    Ok(DropboxClient::with_endpoints(access_token, root, endpoints))
}

fn fake_access_token(value: &str) -> Result<AccessToken, Box<dyn Error>> {
    let token_server = FakeServer::start(vec![FakeResponse::json(json!({
        "access_token": value,
        "expires_in": 14400
    }))])?;
    let token_endpoints = token_server.endpoints();
    let token_oauth = OAuthClient::with_endpoints("app-key", token_endpoints);
    let refreshed =
        token_oauth.refresh(&omabox::auth::RefreshToken::from_secret("opaque-refresh"))?;
    let requests = token_server.finish()?;
    assert_eq!(requests.len(), 1);
    Ok(refreshed.access_token)
}

struct UploadFixture {
    _root: TempDir,
    _staging: TempDir,
    staged: StagedUpload,
}

fn upload_fixture(bytes: &[u8]) -> Result<UploadFixture, Box<dyn Error>> {
    let root = TempDir::new()?;
    let staging = TempDir::new()?;
    std::fs::write(root.path().join("payload"), bytes)?;
    let identity = dropbox_content_hash(bytes)?;
    let staged = match stage_upload(root.path(), "payload", staging.path(), &identity)? {
        StageOutcome::Staged(staged) | StageOutcome::AlreadyStaged(staged) => staged,
        StageOutcome::ContentChanged { .. } => {
            return Err(io::Error::other("upload fixture content changed").into());
        }
        StageOutcome::DestinationOccupied { .. } => {
            return Err(io::Error::other("upload fixture destination was occupied").into());
        }
    };
    Ok(UploadFixture {
        _root: root,
        _staging: staging,
        staged,
    })
}

fn sparse_upload_fixture(size: u64, marker_offset: u64) -> Result<UploadFixture, Box<dyn Error>> {
    let root = TempDir::new()?;
    let staging = TempDir::new()?;
    let source = root.path().join("payload");
    let file = std::fs::File::create(&source)?;
    file.set_len(size)?;
    file.write_all_at(&[0xa5], marker_offset)?;
    let identity = dropbox_content_hash(std::fs::File::open(&source)?)?;
    let staged = match stage_upload(root.path(), "payload", staging.path(), &identity)? {
        StageOutcome::Staged(staged) | StageOutcome::AlreadyStaged(staged) => staged,
        StageOutcome::ContentChanged { .. } => {
            return Err(io::Error::other("upload fixture content changed").into());
        }
        StageOutcome::DestinationOccupied { .. } => {
            return Err(io::Error::other("upload fixture destination was occupied").into());
        }
    };
    Ok(UploadFixture {
        _root: root,
        _staging: staging,
        staged,
    })
}

fn file_metadata(
    path_lower: &str,
    path_display: &str,
    revision: &str,
    content: &ContentIdentity,
) -> serde_json::Value {
    json!({
        ".tag": "file",
        "path_lower": path_lower,
        "path_display": path_display,
        "rev": revision,
        "content_hash": content.as_str(),
        "is_downloadable": true
    })
}

fn folder_metadata(path_lower: &str, path_display: &str) -> serde_json::Value {
    json!({
        ".tag": "folder",
        "path_lower": path_lower,
        "path_display": path_display
    })
}

fn download_metadata(path: &str, revision: &str, content: &ContentIdentity, size: usize) -> String {
    json!({
        ".tag": "file",
        "name": path,
        "path_lower": format!("/{path}"),
        "path_display": format!("/{path}"),
        "rev": revision,
        "content_hash": content.as_str(),
        "size": size
    })
    .to_string()
}

fn planned_operations(decision: Decision) -> Result<OperationPlan, io::Error> {
    match decision {
        Decision::Operations(operations) => Ok(operations),
        Decision::NoOp(_)
        | Decision::Blocked(_)
        | Decision::Conflict(_)
        | Decision::DirectoryCollision(_) => {
            Err(io::Error::other("test expected planned operations"))
        }
    }
}

fn seed_baseline(journal: &mut Journal, path: &Path, remote: &RemoteFile) -> Result<(), io::Error> {
    let decision = plan(
        &Baseline::Present(remote.clone()),
        &Observation::Present(LocalFile::new(remote.content.clone())),
        &Observation::Present(remote.clone()),
    );
    let Decision::NoOp(noop) = decision else {
        return Err(io::Error::other("test expected a no-op baseline"));
    };
    journal
        .record_noop(path, &noop)
        .map(|_| ())
        .map_err(io::Error::other)
}

fn seed_directory_baseline(journal: &mut Journal, path: &Path) -> Result<(), io::Error> {
    let decision = plan(
        &Baseline::Directory,
        &Observation::Directory,
        &Observation::Directory,
    );
    let Decision::NoOp(noop) = decision else {
        return Err(io::Error::other("test expected a directory no-op baseline"));
    };
    journal
        .record_noop(path, &noop)
        .map(|_| ())
        .map_err(io::Error::other)
}

fn conflict_bytes(root: &Path) -> Result<Vec<Vec<u8>>, io::Error> {
    let mut bytes = Vec::new();
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        if entry
            .file_name()
            .to_string_lossy()
            .starts_with(".omabox-conflict-")
        {
            bytes.push(std::fs::read(entry.path())?);
        }
    }
    bytes.sort();
    Ok(bytes)
}

fn root_link_failure(response: FakeResponse) -> Result<DropboxError, Box<dyn Error>> {
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        response,
    ])?;
    let outcome = DropboxClient::link_with_endpoints(
        fake_access_token("opaque-link-access")?,
        "account",
        "/Sync",
        server.endpoints(),
    );
    let failure = outcome
        .err()
        .ok_or_else(|| io::Error::other("invalid Dropbox root was linked"))?;
    assert_eq!(server.finish()?.len(), 2);
    Ok(failure)
}

fn observation<'a>(
    inventory: &'a RemoteInventory,
    path: &Path,
) -> Option<&'a Observation<RemoteFile>> {
    inventory
        .observations
        .iter()
        .find(|record| record.path == path)
        .map(|record| &record.observation)
}

fn text_body(request: &FakeRequest) -> Result<&str, std::str::Utf8Error> {
    std::str::from_utf8(&request.body)
}

fn header<'a>(request: &'a FakeRequest, name: &str) -> Option<&'a str> {
    request.headers.get(name).map(String::as_str)
}

fn required_header<'a>(request: &'a FakeRequest, name: &str) -> Result<&'a str, io::Error> {
    header(request, name).ok_or_else(|| io::Error::other(format!("missing {name} header")))
}

fn metadata_request_includes_deleted(request: &FakeRequest) -> Result<bool, serde_json::Error> {
    let body = serde_json::from_slice::<serde_json::Value>(&request.body)?;
    Ok(body.get("include_deleted") == Some(&serde_json::Value::Bool(true)))
}

struct FakeServer {
    base: String,
    worker: JoinHandle<io::Result<Vec<FakeRequest>>>,
    maximum_active: Arc<AtomicUsize>,
    connection_count: Arc<AtomicUsize>,
}

impl FakeServer {
    fn start(responses: Vec<FakeResponse>) -> io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let base = format!("http://{}", listener.local_addr()?);
        let maximum_active = Arc::new(AtomicUsize::new(0));
        let server_maximum = Arc::clone(&maximum_active);
        let connection_count = Arc::new(AtomicUsize::new(0));
        let server_connections = Arc::clone(&connection_count);
        let worker =
            thread::spawn(move || serve(listener, responses, server_maximum, server_connections));
        Ok(Self {
            base,
            worker,
            maximum_active,
            connection_count,
        })
    }

    fn start_keep_alive(response_groups: Vec<Vec<FakeResponse>>) -> io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let base = format!("http://{}", listener.local_addr()?);
        let maximum_active = Arc::new(AtomicUsize::new(0));
        let server_maximum = Arc::clone(&maximum_active);
        let connection_count = Arc::new(AtomicUsize::new(0));
        let server_connections = Arc::clone(&connection_count);
        let worker = thread::spawn(move || {
            serve_keep_alive(
                listener,
                response_groups,
                server_maximum,
                server_connections,
            )
        });
        Ok(Self {
            base,
            worker,
            maximum_active,
            connection_count,
        })
    }

    fn endpoints(&self) -> DropboxEndpoints {
        DropboxEndpoints::new(
            format!("{}/oauth2/authorize", self.base),
            format!("{}/oauth2/token", self.base),
            format!("{}/2", self.base),
            format!("{}/2", self.base),
            format!("{}/2", self.base),
        )
    }

    fn finish(self) -> io::Result<Vec<FakeRequest>> {
        self.worker
            .join()
            .map_err(|_| io::Error::other("fake Dropbox server thread failed"))?
    }

    fn maximum_active(&self) -> usize {
        self.maximum_active.load(Ordering::SeqCst)
    }

    fn connection_count(&self) -> usize {
        self.connection_count.load(Ordering::SeqCst)
    }
}

struct FakeResponse {
    status: u16,
    body: Vec<u8>,
    headers: Vec<(String, String)>,
    request_path: Option<String>,
    disconnect_after: Option<usize>,
    send_content_length: bool,
    gate: Option<ResponseGate>,
}

struct ResponseGate {
    request_received: mpsc::Sender<()>,
    release_response: mpsc::Receiver<()>,
}

struct ResponseGateControl {
    request_received: mpsc::Receiver<()>,
    release_response: mpsc::Sender<()>,
}

impl FakeResponse {
    fn json(value: serde_json::Value) -> Self {
        Self::status_json(200, value)
    }

    fn status_json(status: u16, value: serde_json::Value) -> Self {
        Self {
            status,
            body: value.to_string().into_bytes(),
            headers: vec![(
                String::from("Content-Type"),
                String::from("application/json"),
            )],
            request_path: None,
            disconnect_after: None,
            send_content_length: true,
            gate: None,
        }
    }

    fn bytes(body: Vec<u8>) -> Self {
        Self {
            status: 200,
            body,
            headers: vec![(
                String::from("Content-Type"),
                String::from("application/octet-stream"),
            )],
            request_path: None,
            disconnect_after: None,
            send_content_length: true,
            gate: None,
        }
    }

    fn range(body: Vec<u8>, metadata: String, content_range: String) -> Self {
        Self {
            status: 206,
            body,
            headers: vec![
                (String::from("Dropbox-API-Result"), metadata),
                (String::from("Content-Range"), content_range),
            ],
            request_path: None,
            disconnect_after: None,
            send_content_length: true,
            gate: None,
        }
    }

    fn header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    fn for_path(mut self, path: impl Into<String>) -> Self {
        self.request_path = Some(path.into());
        self
    }

    fn disconnect_after(mut self, bytes: usize) -> Self {
        self.disconnect_after = Some(bytes);
        self
    }

    fn without_content_length(mut self) -> Self {
        self.send_content_length = false;
        self
    }

    fn gated(mut self) -> (Self, ResponseGateControl) {
        let (request_received, wait_for_request) = mpsc::channel();
        let (release_response, wait_for_release) = mpsc::channel();
        self.gate = Some(ResponseGate {
            request_received,
            release_response: wait_for_release,
        });
        (
            self,
            ResponseGateControl {
                request_received: wait_for_request,
                release_response,
            },
        )
    }
}

struct FakeRequest {
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

fn serve(
    listener: TcpListener,
    mut responses: Vec<FakeResponse>,
    maximum_active: Arc<AtomicUsize>,
    connection_count: Arc<AtomicUsize>,
) -> io::Result<Vec<FakeRequest>> {
    let active = Arc::new(AtomicUsize::new(0));
    let mut handlers: Vec<JoinHandle<io::Result<FakeRequest>>> =
        Vec::with_capacity(responses.len());
    let response_count = responses.len();
    for _ in 0..response_count {
        let (mut stream, _) = listener.accept()?;
        connection_count.fetch_add(1, Ordering::SeqCst);
        let request = read_request(&mut stream)?;
        let response_index = match responses
            .iter()
            .position(|response| response.request_path.as_deref() == Some(request.path.as_str()))
        {
            Some(index) => index,
            None => responses
                .iter()
                .position(|response| response.request_path.is_none())
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!("no fake response matches request path `{}`", request.path),
                    )
                })?,
        };
        let response = responses.remove(response_index);
        let active = Arc::clone(&active);
        let maximum_active = Arc::clone(&maximum_active);
        handlers.push(thread::spawn(move || -> io::Result<FakeRequest> {
            finish_response(
                &mut stream,
                request,
                response,
                &active,
                &maximum_active,
                true,
            )
        }));
    }
    let mut requests = Vec::with_capacity(handlers.len());
    for handler in handlers {
        requests.push(
            handler
                .join()
                .map_err(|_| io::Error::other("fake Dropbox response worker failed"))??,
        );
    }
    Ok(requests)
}

fn serve_keep_alive(
    listener: TcpListener,
    response_groups: Vec<Vec<FakeResponse>>,
    maximum_active: Arc<AtomicUsize>,
    connection_count: Arc<AtomicUsize>,
) -> io::Result<Vec<FakeRequest>> {
    let active = Arc::new(AtomicUsize::new(0));
    let mut handlers = Vec::with_capacity(response_groups.len());
    for responses in response_groups {
        let (mut stream, _) = listener.accept()?;
        connection_count.fetch_add(1, Ordering::SeqCst);
        let active = Arc::clone(&active);
        let maximum_active = Arc::clone(&maximum_active);
        handlers.push(thread::spawn(move || -> io::Result<Vec<FakeRequest>> {
            let response_count = responses.len();
            let mut requests = Vec::with_capacity(response_count);
            for (index, response) in responses.into_iter().enumerate() {
                requests.push(serve_response(
                    &mut stream,
                    response,
                    &active,
                    &maximum_active,
                    index + 1 == response_count,
                )?);
            }
            Ok(requests)
        }));
    }
    let mut requests = Vec::new();
    for handler in handlers {
        requests.extend(
            handler
                .join()
                .map_err(|_| io::Error::other("fake keep-alive response worker failed"))??,
        );
    }
    Ok(requests)
}

fn serve_response(
    stream: &mut TcpStream,
    response: FakeResponse,
    active: &AtomicUsize,
    maximum_active: &AtomicUsize,
    close: bool,
) -> io::Result<FakeRequest> {
    let request = read_request(stream)?;
    finish_response(stream, request, response, active, maximum_active, close)
}

fn finish_response(
    stream: &mut TcpStream,
    request: FakeRequest,
    response: FakeResponse,
    active: &AtomicUsize,
    maximum_active: &AtomicUsize,
    close: bool,
) -> io::Result<FakeRequest> {
    let current = active.fetch_add(1, Ordering::SeqCst) + 1;
    maximum_active.fetch_max(current, Ordering::SeqCst);
    let outcome = (|| {
        if let Some(gate) = &response.gate {
            gate.request_received
                .send(())
                .map_err(|_| io::Error::other("test stopped before fake request notification"))?;
            gate.release_response
                .recv()
                .map_err(|_| io::Error::other("test stopped before fake response release"))?;
        }
        write_response(stream, response, close)
    })();
    active.fetch_sub(1, Ordering::SeqCst);
    outcome?;
    Ok(request)
}

fn read_request(stream: &mut TcpStream) -> io::Result<FakeRequest> {
    let mut received = Vec::new();
    let header_end = loop {
        if received.len() >= 64 * 1024 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "request headers too large",
            ));
        }
        let mut byte = [0_u8; 1];
        stream.read_exact(&mut byte)?;
        received.push(byte[0]);
        if received.ends_with(b"\r\n\r\n") {
            break received.len();
        }
    };
    let headers_text = std::str::from_utf8(&received[..header_end])
        .map_err(|source| io::Error::new(io::ErrorKind::InvalidData, source))?;
    let mut lines = headers_text.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing request line"))?;
    let path = request_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing request path"))?;
    let mut headers = BTreeMap::new();
    for line in lines.filter(|line| !line.is_empty()) {
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid header"))?;
        headers.insert(name.to_ascii_lowercase(), String::from(value.trim()));
    }
    let content_length = headers.get("content-length").map_or(Ok(0_usize), |value| {
        value
            .parse::<usize>()
            .map_err(|source| io::Error::new(io::ErrorKind::InvalidData, source))
    })?;
    let mut body = vec![0_u8; content_length];
    stream.read_exact(&mut body)?;
    Ok(FakeRequest {
        path: String::from(path),
        headers,
        body,
    })
}

fn write_response(stream: &mut TcpStream, response: FakeResponse, close: bool) -> io::Result<()> {
    let reason = if response.status == 200 {
        "OK"
    } else {
        "Test Response"
    };
    write!(stream, "HTTP/1.1 {} {}\r\n", response.status, reason)?;
    if response.send_content_length {
        write!(stream, "Content-Length: {}\r\n", response.body.len())?;
    }
    if close {
        stream.write_all(b"Connection: close\r\n")?;
    } else {
        stream.write_all(b"Connection: keep-alive\r\n")?;
    }
    for (name, value) in response.headers {
        write!(stream, "{name}: {value}\r\n")?;
    }
    stream.write_all(b"\r\n")?;
    let sent = response
        .disconnect_after
        .map_or(response.body.len(), |limit| limit.min(response.body.len()));
    stream.write_all(&response.body[..sent])
}
