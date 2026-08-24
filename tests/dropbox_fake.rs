use std::collections::BTreeMap;
use std::error::Error;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use omabox::auth::{AccessToken, AuthError, OAuthClient, RefreshToken};
use omabox::dropbox::{
    DropboxClient, DropboxEndpoints, DropboxError, DropboxLink, DropboxRoot, InventoryRefresh,
    MutationOutcome, RemotePathState,
};
use omabox::journal::{
    DropboxBinding, Journal, LocalRootBinding, PlanWrite, RemoteInventory, RemoteObservationRecord,
};
use omabox::local::{
    InstallOutcome, StageOutcome, StagedUpload, dropbox_content_hash, install_download,
    stage_upload,
};
use omabox::model::{
    Baseline, Conflict, ContentIdentity, Decision, DropboxRevision, LocalFile, Observation,
    OperationPlan, RemoteFile, UnknownReason,
};
use omabox::planner::plan;
use omabox::reconcile::{ReconcileOutcome, reconcile_once, replay_pending};
use omabox::recovery::{ReplayBlocked, destination, replay_remote_operations};
use omabox::runtime_status::{
    TransferDirection, TransferEvent, TransferObserver, TransferProgress,
};
use serde_json::json;
use tempfile::TempDir;

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
        "content_hash": identity.as_str()
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
        FakeResponse::bytes(bytes.to_vec()).header("Dropbox-API-Result", download_metadata),
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
        Some(&Observation::Unknown(UnknownReason::Unsupported))
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
        FakeResponse::bytes(download_bytes.to_vec()).header(
            "Dropbox-API-Result",
            download_metadata("download.txt", "rev-download", &download_content),
        ),
        FakeResponse::json(file_metadata(
            "/upload.txt",
            "/upload.txt",
            "rev-upload",
            &upload_content,
        )),
    ])?;
    let transfers = Arc::new(Mutex::new(Vec::new()));
    let captured = Arc::clone(&transfers);
    let observer: TransferObserver = Arc::new(move |sample| {
        if let Ok(mut samples) = captured.lock() {
            samples.push(sample);
        }
    });
    let client = fake_client(&server, "opaque-access-reconcile")?.with_transfer_observer(observer);
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

    let report = match reconcile_once(&mut journal, &client, &root, &staging, &recovery)? {
        ReconcileOutcome::Complete(report) => report,
        ReconcileOutcome::FreshObservationRequired { .. } => {
            return Err(io::Error::other("stable fixture requested a fresh observation").into());
        }
        ReconcileOutcome::LocalRootChanged => {
            return Err(io::Error::other("stable fixture changed its local root").into());
        }
    };

    assert_eq!(report.planned, 2);
    assert_eq!(report.replayed_operations, 2);
    assert_eq!(report.blocked, 0);
    assert_eq!(report.conflicts, 0);
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
    assert!(transfers.contains(&TransferEvent::Progress(download_progress)));
    assert!(transfers.contains(&TransferEvent::Progress(upload_progress.clone())));
    assert_eq!(
        transfers.last(),
        Some(&TransferEvent::Finished(upload_progress))
    );

    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
    assert_eq!(requests[0].path, "/2/users/get_current_account");
    assert_eq!(requests[1].path, "/2/files/list_folder");
    assert_eq!(requests[2].path, "/2/files/download");
    assert_eq!(requests[3].path, "/2/files/upload");
    assert_eq!(requests[3].body, upload_bytes);
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(required_header(
            &requests[3],
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
fn pending_exact_downloads_use_bounded_parallel_workers() -> Result<(), Box<dyn Error>> {
    const DOWNLOAD_COUNT: usize = 8;

    let bytes = b"bounded parallel download";
    let content = dropbox_content_hash(bytes.as_slice())?;
    let remote = RemoteFile::new(content.clone(), DropboxRevision::new("shared-revision"));
    let metadata = download_metadata("shared.txt", remote.revision.as_str(), &content);
    let responses = (0..DOWNLOAD_COUNT)
        .map(|_| {
            FakeResponse::bytes(bytes.to_vec())
                .header("Dropbox-API-Result", metadata.clone())
                .delay(Duration::from_millis(150))
        })
        .collect();
    let server = FakeServer::start(responses)?;
    let client = fake_client(&server, "opaque-access-parallel")?;
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

    let report = replay_pending(&mut journal, &client, &root, &staging, &recovery)?;

    assert_eq!(report.completed_operations, DOWNLOAD_COUNT);
    assert!(report.blocked.is_empty());
    assert!(journal.pending_plans()?.is_empty());
    for path in paths {
        assert_eq!(std::fs::read(root.join(path))?, bytes);
    }
    let maximum_active = server.maximum_active();
    let requests = server.finish()?;
    assert_eq!(requests.len(), DOWNLOAD_COUNT);
    assert!(
        requests
            .iter()
            .all(|request| request.path == "/2/files/download")
    );
    assert!(maximum_active >= 2);
    assert!(maximum_active <= 4);
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
    let metadata = download_metadata("batch.txt", remote.revision.as_str(), &content);
    let mut responses = (0..COMPLETED_BATCH)
        .map(|_| FakeResponse::bytes(bytes.to_vec()).header("Dropbox-API-Result", metadata.clone()))
        .collect::<Vec<_>>();
    responses.push(FakeResponse::status_json(
        500,
        json!({"error": "later batch"}),
    ));
    let server = FakeServer::start(responses)?;
    let client = fake_client(&server, "opaque-access-batches")?;
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

    assert!(replay_pending(&mut journal, &client, &root, &staging, &recovery).is_err());

    for path in &paths[..COMPLETED_BATCH] {
        assert_eq!(std::fs::read(root.join(path))?, bytes);
    }
    assert!(!root.join(&paths[COMPLETED_BATCH]).exists());
    assert_eq!(journal.pending_plans()?.len(), 1);
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
        download_metadata("corrupt.txt", "rev-corrupt", &expected),
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
    let client = fake_client(&server, "opaque-access-root-replacement")?;
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
        reconcile_once(&mut journal, &client, &root, &staging, &recovery)?,
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
fn remote_replay_preserves_old_revision_and_retires_a_replacement_conflict()
-> Result<(), Box<dyn Error>> {
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
    let old_metadata = download_metadata("replace.txt", "old-rev", &old.content);
    let current_metadata = download_metadata("replace.txt", "current-rev", &current.content);
    let server = FakeServer::start(vec![
        FakeResponse::bytes(old_bytes.to_vec()).header("Dropbox-API-Result", old_metadata),
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

    let report = replay_remote_operations(&mut journal, &client, &root, &staging, &recovery)?;
    assert_eq!(report.completed_operations, 2);
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
    assert_eq!(
        std::fs::read(destination(
            &recovery,
            Path::new("replace.txt"),
            &old.content,
        ))?,
        old_bytes
    );
    assert_eq!(
        conflict_bytes(&root)?,
        vec![local_bytes.to_vec(), remote_bytes.to_vec()]
    );

    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
    assert_eq!(requests[0].path, "/2/files/download");
    assert_eq!(requests[1].path, "/2/files/upload");
    assert_eq!(requests[2].path, "/2/files/get_metadata");
    assert_eq!(requests[3].path, "/2/files/download");
    assert!(required_header(&requests[0], "dropbox-api-arg")?.contains("rev:old-rev"));
    assert!(required_header(&requests[3], "dropbox-api-arg")?.contains("rev:current-rev"));
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

    let report = replay_remote_operations(&mut journal, &client, &root, &staging, &recovery)?;
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

    let report = replay_remote_operations(&mut journal, &client, &root, &staging, &recovery)?;
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
fn remote_replay_rebuilds_missing_recovery_and_leaves_ambiguous_create_pending()
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
    let delete_plan = match journal.record_plan(Path::new("delete.txt"), &delete)? {
        PlanWrite::Recorded(plan) => plan,
        PlanWrite::AlreadyPending(_) => {
            return Err(io::Error::other("test expected a new delete plan").into());
        }
    };
    let preserve_operation = delete_plan
        .operations
        .first()
        .ok_or_else(|| io::Error::other("test expected a preservation operation"))?;
    assert!(matches!(
        journal.complete_operation(preserve_operation.id, None)?,
        omabox::journal::OperationCompletion::OperationCompleted
    ));
    let recovery_path = destination(&recovery, Path::new("delete.txt"), &old.content);
    let delete_metadata = download_metadata("delete.txt", "old-rev", &old.content);
    let delete_server = FakeServer::start(vec![
        FakeResponse::bytes(old_bytes.to_vec()).header("Dropbox-API-Result", delete_metadata),
        FakeResponse::json(json!({
            "metadata": file_metadata("/delete.txt", "/Delete.txt", "old-rev", &old.content)
        })),
    ])?;
    let delete_client = fake_client(&delete_server, "opaque-access-replay-delete")?;
    let report =
        replay_remote_operations(&mut journal, &delete_client, &root, &staging, &recovery)?;
    assert_eq!(report.completed_operations, 1);
    assert_eq!(std::fs::read(recovery_path)?, old_bytes);
    let requests = delete_server.finish()?;
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].path, "/2/files/download");
    assert_eq!(requests[1].path, "/2/files/delete_v2");

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
    let pending =
        replay_remote_operations(&mut journal, &pending_client, &root, &staging, &recovery)?;
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
        Some(&Observation::Unknown(UnknownReason::Unsupported))
    );
    let requests = server.finish()?;
    assert_eq!(requests.len(), 4);
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
            Some(&Observation::Unknown(UnknownReason::Unsupported))
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
    assert_eq!(requests[2].path, "/2/files/list_folder");
    Ok(())
}

#[test]
fn incomplete_downloadable_metadata_cannot_replace_durable_inventory() -> Result<(), Box<dyn Error>>
{
    let server = FakeServer::start(vec![
        FakeResponse::json(json!({
            "account_id": "account",
            "root_info": {"root_namespace_id": "namespace"}
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/changed.txt",
                "path_display": "/Changed.txt",
                "rev": "rev-changed",
                "content_hash": "change-probe"
            }],
            "cursor": "probe",
            "has_more": false
        })),
        FakeResponse::json(json!({
            "entries": [{
                ".tag": "file",
                "path_lower": "/partial.txt",
                "path_display": "/Partial.txt",
                "rev": "rev-partial",
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
                ".tag": "folder",
                "path_lower": "/probe",
                "path_display": "/Probe"
            }],
            "cursor": "probe",
            "has_more": false
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
    assert_eq!(server.finish()?.len(), 4);
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

fn download_metadata(path: &str, revision: &str, content: &ContentIdentity) -> String {
    json!({
        ".tag": "file",
        "name": path,
        "path_lower": format!("/{path}"),
        "path_display": format!("/{path}"),
        "rev": revision,
        "content_hash": content.as_str()
    })
    .to_string()
}

fn planned_operations(decision: Decision) -> Result<OperationPlan, io::Error> {
    match decision {
        Decision::Operations(operations) => Ok(operations),
        Decision::NoOp(_) | Decision::Blocked(_) | Decision::Conflict(_) => {
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
}

impl FakeServer {
    fn start(responses: Vec<FakeResponse>) -> io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let base = format!("http://{}", listener.local_addr()?);
        let maximum_active = Arc::new(AtomicUsize::new(0));
        let server_maximum = Arc::clone(&maximum_active);
        let worker = thread::spawn(move || serve(listener, responses, server_maximum));
        Ok(Self {
            base,
            worker,
            maximum_active,
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
}

struct FakeResponse {
    status: u16,
    body: Vec<u8>,
    headers: Vec<(String, String)>,
    delay: Duration,
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
            delay: Duration::ZERO,
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
            delay: Duration::ZERO,
        }
    }

    fn header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    fn delay(mut self, delay: Duration) -> Self {
        self.delay = delay;
        self
    }
}

struct FakeRequest {
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

fn serve(
    listener: TcpListener,
    responses: Vec<FakeResponse>,
    maximum_active: Arc<AtomicUsize>,
) -> io::Result<Vec<FakeRequest>> {
    let active = Arc::new(AtomicUsize::new(0));
    let mut handlers: Vec<JoinHandle<io::Result<FakeRequest>>> =
        Vec::with_capacity(responses.len());
    for response in responses {
        let (mut stream, _) = listener.accept()?;
        let active = Arc::clone(&active);
        let maximum_active = Arc::clone(&maximum_active);
        handlers.push(thread::spawn(move || {
            let request = read_request(&mut stream)?;
            let current = active.fetch_add(1, Ordering::SeqCst) + 1;
            maximum_active.fetch_max(current, Ordering::SeqCst);
            thread::sleep(response.delay);
            let written = write_response(&mut stream, response);
            active.fetch_sub(1, Ordering::SeqCst);
            written?;
            Ok(request)
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

fn write_response(stream: &mut TcpStream, response: FakeResponse) -> io::Result<()> {
    let reason = if response.status == 200 {
        "OK"
    } else {
        "Test Response"
    };
    write!(
        stream,
        "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: close\r\n",
        response.status,
        reason,
        response.body.len()
    )?;
    for (name, value) in response.headers {
        write!(stream, "{name}: {value}\r\n")?;
    }
    stream.write_all(b"\r\n")?;
    stream.write_all(&response.body)
}
