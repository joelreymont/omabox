#![cfg(feature = "dropbox-live")]

use std::env;
use std::error::Error;
use std::io;

use omabox::auth::{CredentialLookup, OAuthClient, RefreshTokenStore};
use omabox::dropbox::{AccountValidation, DropboxClient, DropboxRoot};
use omabox::journal::Journal;
use tempfile::TempDir;

#[test]
#[ignore = "requires an explicitly authorized dedicated Dropbox test account"]
fn refreshes_and_validates_desktop_credential() -> Result<(), Box<dyn Error>> {
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
    let directory = TempDir::new()?;
    let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;

    assert_eq!(
        client.validate_account(&mut journal)?,
        AccountValidation::Valid
    );
    Ok(())
}
