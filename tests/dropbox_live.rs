#![cfg(feature = "dropbox-live")]

use std::env;
use std::error::Error;
use std::fs;
use std::io;
use std::path::Path;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

use omabox::auth::{CredentialLookup, OAuthClient, RefreshTokenStore};
use omabox::dropbox::{
    AccountValidation, DropboxClient, DropboxRoot, MutationOutcome, RemotePathState,
};
use omabox::journal::Journal;
use omabox::local::{
    InstallOutcome, StageOutcome, StagedUpload, dropbox_content_hash, install_download,
    stage_upload,
};
use omabox::model::{ContentIdentity, Observation, RemoteFile};
use tempfile::TempDir;

#[test]
#[ignore = "mutates an explicitly authorized dedicated Dropbox test root"]
fn round_trips_a_file_through_real_dropbox() -> Result<(), Box<dyn Error>> {
    let app_key = env::var("OMABOX_DROPBOX_APP_KEY")
        .map_err(|source| io::Error::new(io::ErrorKind::NotFound, source))?;
    let credential = match RefreshTokenStore::new().load()? {
        CredentialLookup::Found(credential) => credential,
        CredentialLookup::CredentialsUnavailable { status } => {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("desktop Dropbox credential is unavailable (status {status:?})"),
            )
            .into());
        }
    };
    let oauth = OAuthClient::new(app_key);
    let access = oauth.refresh(&credential.refresh_token)?;
    let root = DropboxRoot::from_binding(&credential.binding)?;
    let client = DropboxClient::new(access.access_token, root);
    let state_directory = TempDir::new()?;
    let mut journal = Journal::open(state_directory.path().join("journal.sqlite3"))?;
    if client.validate_account(&mut journal)? != AccountValidation::Valid {
        return Err(io::Error::other("dedicated Dropbox test binding is no longer valid").into());
    }

    let source_root = TempDir::new()?;
    let upload_staging = TempDir::new()?;
    let download_root = TempDir::new()?;
    let remote_path = unique_remote_path()?;
    let first_bytes =
        format!("omabox real Dropbox round-trip {remote_path}: initial\n").into_bytes();
    let replacement_bytes =
        format!("omabox real Dropbox round-trip {remote_path}: replacement\n").into_bytes();
    let first_stage = stage_payload(
        source_root.path(),
        upload_staging.path(),
        "initial",
        &first_bytes,
    )?;
    let replacement_stage = stage_payload(
        source_root.path(),
        upload_staging.path(),
        "replacement",
        &replacement_bytes,
    )?;
    let round_trip = (|| -> Result<(), Box<dyn Error>> {
        let created = applied_file(
            client.create_file(&remote_path, &first_stage)?,
            "create the live-test file",
        )?;

        match client.stage_exact_download(download_root.path(), "downloaded", &created)? {
            StageOutcome::Staged(()) | StageOutcome::AlreadyStaged(()) => {}
            StageOutcome::ContentChanged { .. } => {
                return Err(io::Error::other("the exact Dropbox download changed content").into());
            }
            StageOutcome::DestinationOccupied { .. } => {
                return Err(io::Error::other("the exact-download stage was occupied").into());
            }
        }
        match install_download(download_root.path(), "downloaded", &created.content, None)? {
            InstallOutcome::Installed | InstallOutcome::AlreadyInstalled => {}
            _ => {
                return Err(
                    io::Error::other("the exact Dropbox download was not installed").into(),
                );
            }
        }
        if fs::read(download_root.path().join("downloaded"))? != first_bytes {
            return Err(io::Error::other("the exact Dropbox download had unexpected bytes").into());
        }

        let replacement = applied_file(
            client.replace_file(&remote_path, &created.revision, &replacement_stage)?,
            "conditionally replace the live-test file",
        )?;
        match client.delete_file(&remote_path, &replacement.revision)? {
            MutationOutcome::Applied(RemotePathState::Absent) => {}
            _ => {
                return Err(io::Error::other(
                    "conditionally deleting the live-test file did not confirm absence",
                )
                .into());
            }
        }

        client.refresh_inventory(&mut journal)?;
        let inventory = journal.remote_inventory()?;
        if inventory
            .observations
            .iter()
            .any(|record| record.path == Path::new(&remote_path))
        {
            return Err(io::Error::other(
                "a complete Dropbox listing still contained the deleted live-test file",
            )
            .into());
        }
        Ok(())
    })();

    if let Err(original) = round_trip {
        if let Err(cleanup) = cleanup_remote_file(
            &client,
            &mut journal,
            &remote_path,
            [first_stage.content(), replacement_stage.content()],
        ) {
            eprintln!("live-test cleanup also failed: {cleanup}");
        }
        return Err(original);
    }
    Ok(())
}

fn stage_payload(
    source_root: &Path,
    staging: &Path,
    name: &str,
    bytes: &[u8],
) -> Result<StagedUpload, Box<dyn Error>> {
    fs::write(source_root.join(name), bytes)?;
    let identity = dropbox_content_hash(bytes)?;
    match stage_upload(source_root, name, staging, &identity)? {
        StageOutcome::Staged(stage) | StageOutcome::AlreadyStaged(stage) => Ok(stage),
        StageOutcome::ContentChanged { .. } => {
            Err(io::Error::other("live-test upload source changed during staging").into())
        }
        StageOutcome::DestinationOccupied { .. } => {
            Err(io::Error::other("live-test upload stage was occupied").into())
        }
    }
}

fn applied_file(
    outcome: MutationOutcome,
    operation: &'static str,
) -> Result<RemoteFile, io::Error> {
    match outcome {
        MutationOutcome::Applied(RemotePathState::File(remote)) => Ok(remote),
        _ => Err(io::Error::other(format!(
            "Dropbox did not {operation} as requested"
        ))),
    }
}

fn cleanup_remote_file(
    client: &DropboxClient,
    journal: &mut Journal,
    remote_path: &str,
    owned_contents: [&ContentIdentity; 2],
) -> Result<(), Box<dyn Error>> {
    client.refresh_inventory(journal)?;
    let inventory = journal.remote_inventory()?;
    let current = inventory
        .observations
        .iter()
        .find(|record| record.path == Path::new(remote_path));
    let Some(current) = current else {
        return Ok(());
    };
    let Observation::Present(remote) = &current.observation else {
        return Err(io::Error::other("cleanup could not confirm the live-test file").into());
    };
    if !owned_contents.contains(&&remote.content) {
        return Err(io::Error::other("cleanup preserved remotely changed live-test bytes").into());
    }
    match client.delete_file(remote_path, &remote.revision)? {
        MutationOutcome::Applied(RemotePathState::Absent) => Ok(()),
        _ => Err(io::Error::other("cleanup did not confirm live-test file deletion").into()),
    }
}

fn unique_remote_path() -> Result<String, io::Error> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?;
    Ok(format!(
        "omabox-live-{}-{}.txt",
        process::id(),
        elapsed.as_nanos()
    ))
}
