use std::collections::BTreeMap;
use std::error::Error;
use std::io::{self, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use omabox::auth::{AccessToken, AuthError, OAuthClient, RefreshToken};
use omabox::dropbox::{
    DropboxClient, DropboxEndpoints, DropboxError, DropboxLink, DropboxRoot, InventoryRefresh,
    MutationOutcome, RemotePathState,
};
use omabox::journal::{DropboxBinding, Journal, RemoteInventory, RemoteObservationRecord};
use omabox::local::{
    InstallOutcome, StageOutcome, StagedUpload, dropbox_content_hash, install_download,
    stage_upload,
};
use omabox::model::{ContentIdentity, DropboxRevision, Observation, RemoteFile, UnknownReason};
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
}

impl FakeServer {
    fn start(responses: Vec<FakeResponse>) -> io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let base = format!("http://{}", listener.local_addr()?);
        let worker = thread::spawn(move || serve(listener, responses));
        Ok(Self { base, worker })
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
}

struct FakeResponse {
    status: u16,
    body: Vec<u8>,
    headers: Vec<(String, String)>,
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
        }
    }

    fn header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }
}

struct FakeRequest {
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

fn serve(listener: TcpListener, responses: Vec<FakeResponse>) -> io::Result<Vec<FakeRequest>> {
    let mut requests = Vec::with_capacity(responses.len());
    for response in responses {
        let (mut stream, _) = listener.accept()?;
        requests.push(read_request(&mut stream)?);
        write_response(&mut stream, response)?;
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
