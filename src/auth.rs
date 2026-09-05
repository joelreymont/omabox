//! Dropbox OAuth Authorization Code with PKCE.

use std::fmt;
use std::io::{self, Read as _, Write as _};
#[cfg(test)]
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::str;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use dropbox_sdk::oauth2::{Authorization, AuthorizeUrlBuilder, Oauth2Type, PkceCode, TokenType};
use rustix::rand::{GetRandomFlags, getrandom};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::dropbox::DropboxEndpoints;
use crate::journal::DropboxBinding;
#[cfg(test)]
use crate::spawn::Launch;
use crate::transport::{OAuthTransport, TransportError, oauth_failure};

const OAUTH_SCOPE: &str =
    "account_info.read files.metadata.read files.content.read files.content.write";
const RANDOM_VALUE_BYTES: usize = 32;
const SECRET_TOOL: &str = "/usr/bin/secret-tool";
const SECRET_BYTES_LIMIT: usize = 8192;
const SECRET_VERSION: u8 = 1;
const SECRET_LABEL: &str = "Omabox Dropbox credentials";
const SECRET_ATTRIBUTES: [&str; 4] = [
    "application",
    "org.omarchy.omabox",
    "kind",
    "dropbox-credentials-v1",
];

/// A Dropbox access token whose diagnostics never expose its value.
pub struct AccessToken(String);

impl AccessToken {
    pub(crate) fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[cfg(test)]
    pub(crate) fn for_test(value: impl Into<String>) -> Self {
        Self::new(value)
    }

    pub(crate) fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("AccessToken([REDACTED])")
    }
}

/// A Dropbox refresh token whose diagnostics never expose its value.
pub struct RefreshToken(String);

impl RefreshToken {
    /// Wrap a refresh token obtained from a protected credential source.
    #[must_use]
    pub fn from_secret(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub(crate) fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for RefreshToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("RefreshToken([REDACTED])")
    }
}

/// Refresh credential loaded from the user's Secret Service.
#[derive(Debug)]
pub struct StoredCredential {
    /// Non-secret identity that must be validated after refresh.
    pub binding: DropboxBinding,
    /// Protected long-lived refresh token.
    pub refresh_token: RefreshToken,
}

/// Expected result of looking for the singleton Dropbox credential.
#[derive(Debug)]
pub enum CredentialLookup {
    /// A protected credential and its binding were found.
    Found(StoredCredential),
    /// Secret Service could not return the singleton item.
    CredentialsUnavailable {
        /// Exit status from `secret-tool`, when the process exited normally.
        status: Option<i32>,
    },
}

/// Blocking access to Omabox's singleton Secret Service item.
#[derive(Clone, Debug)]
pub struct RefreshTokenStore {
    #[cfg(test)]
    launch: Launch,
}

impl RefreshTokenStore {
    /// Use the production Secret Service command.
    #[must_use]
    pub fn new() -> Self {
        Self {
            #[cfg(test)]
            launch: Launch::Program(PathBuf::from(SECRET_TOOL)),
        }
    }

    /// Store or update the refresh token and its non-secret Dropbox binding.
    pub fn store(
        &self,
        binding: &DropboxBinding,
        refresh_token: &RefreshToken,
    ) -> Result<(), AuthError> {
        let secret = serde_json::to_vec(&StoredSecret {
            version: SECRET_VERSION,
            refresh_token: refresh_token.expose(),
            account_id: &binding.account_id,
            root_namespace_id: &binding.root_namespace_id,
            remote_root: &binding.remote_root,
        })
        .map_err(credential_json)?;
        if secret.len() >= SECRET_BYTES_LIMIT {
            return Err(AuthError::CredentialTooLarge);
        }
        let mut child = self
            .command()
            .arg("store")
            .arg(format!("--label={SECRET_LABEL}"))
            .args(SECRET_ATTRIBUTES)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|source| AuthError::CredentialSpawn {
                operation: "store Dropbox credential",
                source,
            })?;
        let Some(mut stdin) = child.stdin.take() else {
            return Err(pipe_unavailable(
                "store Dropbox credential",
                terminate_child(&mut child),
            ));
        };
        let written = stdin.write_all(&secret);
        drop(stdin);
        write_outcome("store Dropbox credential", written, child.wait())
    }

    /// Load the singleton credential before the Dropbox account is known.
    pub fn load(&self) -> Result<CredentialLookup, AuthError> {
        let mut child = self
            .command()
            .arg("lookup")
            .args(SECRET_ATTRIBUTES)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|source| AuthError::CredentialSpawn {
                operation: "load Dropbox credential",
                source,
            })?;
        let Some(stdout) = child.stdout.take() else {
            return Err(pipe_unavailable(
                "load Dropbox credential",
                terminate_child(&mut child),
            ));
        };
        let mut secret = Vec::new();
        let read = stdout
            .take(SECRET_BYTES_LIMIT as u64)
            .read_to_end(&mut secret);
        let status = read_outcome("load Dropbox credential", read.map(|_| ()), child.wait())?;
        if !status.success() {
            return Ok(CredentialLookup::CredentialsUnavailable {
                status: status.code(),
            });
        }
        if secret.len() >= SECRET_BYTES_LIMIT {
            return Err(AuthError::CredentialTooLarge);
        }
        let secret =
            str::from_utf8(&secret).map_err(|source| AuthError::CredentialUtf8 { source })?;
        let stored: LoadedSecret = serde_json::from_str(secret).map_err(credential_json)?;
        if stored.version != SECRET_VERSION {
            return Err(AuthError::StoredCredentialVersion {
                found: stored.version,
            });
        }
        let binding = DropboxBinding {
            account_id: stored.account_id,
            root_namespace_id: stored.root_namespace_id,
            remote_root: stored.remote_root,
        };
        Ok(CredentialLookup::Found(StoredCredential {
            binding,
            refresh_token: RefreshToken(stored.refresh_token),
        }))
    }

    fn command(&self) -> Command {
        #[cfg(test)]
        let command = self.launch.command();
        #[cfg(not(test))]
        let command = Command::new(SECRET_TOOL);
        command
    }

    /// Stand in for `secret-tool` with a shell script `/bin/sh` reads.
    #[cfg(test)]
    fn with_script(script: impl Into<PathBuf>) -> Self {
        Self {
            launch: Launch::Script(script.into()),
        }
    }
}

impl Default for RefreshTokenStore {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Serialize)]
struct StoredSecret<'a> {
    version: u8,
    refresh_token: &'a str,
    account_id: &'a str,
    root_namespace_id: &'a str,
    remote_root: &'a str,
}

#[derive(Deserialize)]
struct LoadedSecret {
    version: u8,
    refresh_token: String,
    account_id: String,
    root_namespace_id: String,
    remote_root: String,
}

/// Browser authorization in progress, including its one-use PKCE proof.
pub struct PendingAuthorization {
    authorization_url: String,
    flow: Oauth2Type,
}

impl PendingAuthorization {
    /// URL the user must open to authorize Omabox.
    #[must_use]
    pub fn authorization_url(&self) -> &str {
        &self.authorization_url
    }
}

impl fmt::Debug for PendingAuthorization {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingAuthorization")
            .field("authorization_url", &"[REDACTED]")
            .field("flow", &"PKCE([REDACTED])")
            .finish()
    }
}

/// Tokens returned by initial authorization.
#[derive(Debug)]
pub struct AuthorizationGrant {
    /// Short-lived token for Dropbox API calls.
    pub access_token: AccessToken,
    /// Long-lived token that belongs in Secret Service.
    pub refresh_token: RefreshToken,
}

/// Direct blocking Dropbox OAuth client.
pub struct OAuthClient {
    app_key: String,
    transport: OAuthTransport,
}

impl OAuthClient {
    /// Construct an OAuth client using Dropbox's production endpoints.
    #[must_use]
    pub fn new(app_key: impl Into<String>) -> Self {
        Self::with_endpoints(app_key, DropboxEndpoints::production())
    }

    /// Construct an OAuth client with explicit endpoints.
    ///
    /// This is intended for protocol tests against a local fake server.
    #[must_use]
    pub fn with_endpoints(app_key: impl Into<String>, endpoints: DropboxEndpoints) -> Self {
        Self {
            app_key: app_key.into(),
            transport: OAuthTransport::new(endpoints.bases()),
        }
    }

    /// Start one authorization attempt with a fresh PKCE verifier.
    pub fn begin(&self) -> Result<PendingAuthorization, AuthError> {
        let flow = Oauth2Type::PKCE(PkceCode {
            code: random_urlsafe()?,
        });
        let authorization_url = AuthorizeUrlBuilder::new(&self.app_key, &flow)
            .token_type(TokenType::ShortLivedAndRefresh)
            .scope(OAUTH_SCOPE)
            .build()
            .into();
        Ok(PendingAuthorization {
            authorization_url,
            flow,
        })
    }

    /// Exchange the manually copied authorization code.
    pub fn exchange(
        &self,
        pending: PendingAuthorization,
        code: &str,
    ) -> Result<AuthorizationGrant, AuthError> {
        let mut authorization = Authorization::from_auth_code(
            self.app_key.clone(),
            pending.flow,
            String::from(code),
            None,
        );
        let access_token = authorization
            .obtain_access_token(self.transport.client())
            .map_err(sdk_error)?;
        let saved = authorization.save().ok_or(AuthError::MissingRefreshToken)?;
        let refresh_token = saved
            .strip_prefix("2&")
            .ok_or(AuthError::MissingRefreshToken)?;
        Ok(AuthorizationGrant {
            access_token: AccessToken::new(access_token),
            refresh_token: RefreshToken::from_secret(refresh_token),
        })
    }
}

/// OAuth setup or refresh failure with secret-safe diagnostics.
#[derive(Debug, Error)]
pub enum AuthError {
    /// OS randomness was unavailable.
    #[error("could not generate a secure OAuth proof")]
    Random {
        /// Original operating-system error.
        #[source]
        source: rustix::io::Errno,
    },
    /// The SDK OAuth exchange or refresh failed.
    #[error("Dropbox OAuth could not issue an access token")]
    Sdk {
        /// Typed, secret-safe transport or protocol failure.
        #[source]
        source: Box<TransportError>,
    },
    /// A completed code exchange did not yield the requested refresh token.
    #[error("Dropbox OAuth did not issue a refresh token")]
    MissingRefreshToken,
    /// `secret-tool` could not be started.
    #[error("credential operation `{operation}` could not start")]
    CredentialSpawn {
        /// Safe operation name without command arguments.
        operation: &'static str,
        /// Original process error.
        #[source]
        source: io::Error,
    },
    /// A requested subprocess pipe was unavailable.
    #[error("credential operation `{operation}` did not provide its required pipe")]
    CredentialPipeUnavailable {
        /// Safe operation name.
        operation: &'static str,
    },
    /// The protected credential could not be written to `secret-tool`.
    #[error("could not send the Dropbox credential to Secret Service")]
    CredentialWrite {
        /// Exit status of the credential process, or `None` when signalled or unreaped.
        status: Option<i32>,
        /// Original pipe error; it does not contain written bytes.
        #[source]
        source: io::Error,
    },
    /// Protected credential output could not be read.
    #[error("could not read the Dropbox credential from Secret Service")]
    CredentialRead {
        /// Original pipe error; it does not contain read bytes.
        #[source]
        source: io::Error,
    },
    /// `secret-tool` could not be reaped.
    #[error("credential operation `{operation}` could not wait for completion")]
    CredentialWait {
        /// Safe operation name.
        operation: &'static str,
        /// Original process error.
        #[source]
        source: io::Error,
    },
    /// A credential write command did not succeed.
    #[error("credential operation `{operation}` failed with status {status:?}")]
    CredentialStatus {
        /// Safe operation name.
        operation: &'static str,
        /// Exit status, or `None` when terminated by a signal.
        status: Option<i32>,
    },
    /// A credential subprocess failed and could not be reaped afterwards.
    #[error(transparent)]
    CredentialCleanup(Box<CredentialCleanup>),
    /// The versioned credential record could not be encoded or decoded.
    #[error("Secret Service returned an invalid Omabox Dropbox credential record")]
    CredentialJson {
        /// JSON error carrying only a category and location, never input bytes.
        #[source]
        source: serde_json::Error,
    },
    /// Secret Service returned a credential that was not UTF-8 JSON.
    #[error("Secret Service returned an invalid Omabox Dropbox credential encoding")]
    CredentialUtf8 {
        /// UTF-8 error carrying only byte offsets, never the input bytes.
        #[source]
        source: str::Utf8Error,
    },
    /// Secret Service returned or was given an unbounded credential record.
    #[error("Omabox Dropbox credential record exceeds the supported size")]
    CredentialTooLarge,
    /// The stored record uses an unsupported version.
    #[error("Secret Service returned unsupported Omabox credential version {found}")]
    StoredCredentialVersion {
        /// Unsupported non-secret format version.
        found: u8,
    },
}

fn sdk_error(source: dropbox_sdk::Error) -> AuthError {
    AuthError::Sdk {
        source: Box::new(oauth_failure(source)),
    }
}

fn random_urlsafe() -> Result<String, AuthError> {
    let mut bytes = [0_u8; RANDOM_VALUE_BYTES];
    getrandom(&mut bytes, GetRandomFlags::empty())
        .map_err(|source| AuthError::Random { source })?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn credential_json(source: serde_json::Error) -> AuthError {
    use serde::de::Error as _;

    let category = match source.classify() {
        serde_json::error::Category::Io => "I/O",
        serde_json::error::Category::Syntax => "syntax",
        serde_json::error::Category::Data => "data",
        serde_json::error::Category::Eof => "end-of-input",
    };
    let safe = serde_json::Error::custom(format!(
        "credential JSON {category} error at line {}, column {}",
        source.line(),
        source.column()
    ));
    AuthError::CredentialJson { source: safe }
}

/// A credential subprocess failure and the cleanup failure that followed it.
#[derive(Debug, Error)]
#[error("{failure}; its credential process could not be reaped: {cleanup}")]
pub struct CredentialCleanup {
    /// Failure that started cleanup, kept as the classifiable cause.
    #[source]
    pub failure: AuthError,
    /// Cleanup failure, which never contains subprocess output.
    pub cleanup: io::Error,
}

fn terminate_child(child: &mut Child) -> io::Result<()> {
    match (child.kill(), child.wait()) {
        (Ok(()), Ok(_)) => Ok(()),
        (Err(source), _) | (Ok(()), Err(source)) => Err(source),
    }
}

fn pipe_unavailable(operation: &'static str, cleanup: io::Result<()>) -> AuthError {
    let failure = AuthError::CredentialPipeUnavailable { operation };
    match cleanup {
        Ok(()) => failure,
        Err(cleanup) => {
            AuthError::CredentialCleanup(Box::new(CredentialCleanup { failure, cleanup }))
        }
    }
}

fn write_outcome(
    operation: &'static str,
    written: io::Result<()>,
    reaped: io::Result<ExitStatus>,
) -> Result<(), AuthError> {
    match (written, reaped) {
        (Ok(()), Ok(status)) if status.success() => Ok(()),
        (Ok(()), Ok(status)) => Err(AuthError::CredentialStatus {
            operation,
            status: status.code(),
        }),
        (Ok(()), Err(source)) => Err(AuthError::CredentialWait { operation, source }),
        (Err(source), Ok(status)) => Err(AuthError::CredentialWrite {
            status: status.code(),
            source,
        }),
        (Err(source), Err(cleanup)) => {
            Err(AuthError::CredentialCleanup(Box::new(CredentialCleanup {
                failure: AuthError::CredentialWrite {
                    status: None,
                    source,
                },
                cleanup,
            })))
        }
    }
}

fn read_outcome(
    operation: &'static str,
    read: io::Result<()>,
    reaped: io::Result<ExitStatus>,
) -> Result<ExitStatus, AuthError> {
    match (read, reaped) {
        (Ok(()), Ok(status)) => Ok(status),
        (Ok(()), Err(source)) => Err(AuthError::CredentialWait { operation, source }),
        (Err(source), Ok(_)) => Err(AuthError::CredentialRead { source }),
        (Err(source), Err(cleanup)) => {
            Err(AuthError::CredentialCleanup(Box::new(CredentialCleanup {
                failure: AuthError::CredentialRead { source },
                cleanup,
            })))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;
    use std::net::TcpListener;
    use std::path::{Path, PathBuf};

    use crate::dropbox::{DropboxClient, DropboxEndpoints, DropboxRoot};
    use crate::journal::{DropboxBinding, Journal};

    use super::{
        AccessToken, CredentialLookup, OAuthClient, Oauth2Type, RefreshToken, RefreshTokenStore,
    };

    #[test]
    fn secret_debug_values_are_redacted() -> Result<(), Box<dyn Error>> {
        let access = AccessToken(String::from("access-secret"));
        let refresh = RefreshToken::from_secret("refresh-secret");

        assert_eq!(format!("{access:?}"), "AccessToken([REDACTED])");
        assert_eq!(format!("{refresh:?}"), "RefreshToken([REDACTED])");
        Ok(())
    }

    #[test]
    fn pkce_authorization_uses_offline_code_flow() -> Result<(), Box<dyn Error>> {
        let oauth = OAuthClient::new("app-key");
        let pending = oauth.begin()?;
        let url = pending.authorization_url();

        assert!(url.starts_with("https://www.dropbox.com/oauth2/authorize?"));
        assert!(url.contains("response_type=code"));
        assert!(url.contains("token_access_type=offline"));
        assert!(url.contains("files.content.write"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(!url.contains("code_verifier"));
        assert!(!url.contains("redirect_uri"));
        assert!(!url.contains("state="));
        Ok(())
    }

    #[test]
    fn pending_authorization_debug_omits_pkce_proof() -> Result<(), Box<dyn Error>> {
        let oauth = OAuthClient::new("app-key");
        let pending = oauth.begin()?;
        let Oauth2Type::PKCE(pkce) = &pending.flow else {
            return Err(std::io::Error::other("authorization did not use PKCE").into());
        };
        let verifier = pkce.code.clone();
        let diagnostic = format!("{pending:?}");

        assert!(!diagnostic.contains(&verifier));
        assert!(!diagnostic.contains("code_challenge="));
        Ok(())
    }

    #[test]
    fn oauth_transport_diagnostics_never_include_submitted_secrets() -> Result<(), Box<dyn Error>> {
        let endpoint = closed_endpoint()?;
        let endpoints = DropboxEndpoints::new(
            format!("{endpoint}/authorize"),
            format!("{endpoint}/token"),
            format!("{endpoint}/2"),
            format!("{endpoint}/2"),
            format!("{endpoint}/2"),
        );
        let oauth = OAuthClient::with_endpoints("app-key", endpoints);
        let pending = oauth.begin()?;
        let Oauth2Type::PKCE(pkce) = &pending.flow else {
            return Err(std::io::Error::other("authorization did not use PKCE").into());
        };
        let verifier = pkce.code.clone();
        let code = "authorization-code-sentinel";
        let exchange = oauth.exchange(pending, code);
        let exchange_error = exchange
            .err()
            .ok_or_else(|| std::io::Error::other("closed endpoint accepted exchange"))?;
        let exchange_diagnostic = error_diagnostic(&exchange_error);
        assert!(!exchange_diagnostic.contains(code));
        assert!(!exchange_diagnostic.contains(&verifier));

        Ok(())
    }

    #[test]
    fn malformed_access_token_diagnostic_is_redacted() -> Result<(), Box<dyn Error>> {
        let endpoint = closed_endpoint()?;
        let endpoints = DropboxEndpoints::new(
            format!("{endpoint}/authorize"),
            format!("{endpoint}/token"),
            format!("{endpoint}/2"),
            format!("{endpoint}/2"),
            format!("{endpoint}/2"),
        );
        let secret = "malformed-access-token\r\nsentinel";
        let client = DropboxClient::with_endpoints(
            AccessToken(String::from(secret)),
            DropboxRoot::new("account", "namespace", "")?,
            endpoints,
        )?;
        let directory = tempfile::TempDir::new()?;
        let mut journal = Journal::open(directory.path().join("journal.sqlite3"))?;
        let failure = client
            .validate_account(&mut journal)
            .err()
            .ok_or_else(|| std::io::Error::other("malformed token was accepted"))?;

        assert!(!error_diagnostic(&failure).contains(secret));
        assert!(!error_diagnostic(&failure).contains("sentinel"));
        Ok(())
    }

    #[test]
    fn secret_tool_store_uses_fixed_arguments_and_exact_json_stdin() -> Result<(), Box<dyn Error>> {
        let directory = tempfile::TempDir::new()?;
        let script = fake_script(
            directory.path(),
            "store-fake",
            "printf '%s\\n' \"$@\" > \"$0.args\"\ncat > \"$0.stdin\"\n",
        )?;
        let binding = DropboxBinding {
            account_id: String::from("account-id"),
            root_namespace_id: String::from("namespace-id"),
            remote_root: String::from("/Root"),
        };
        let token = "credential-stdin-sentinel";

        RefreshTokenStore::with_script(&script)
            .store(&binding, &RefreshToken::from_secret(token))?;

        let arguments = fs::read_to_string(suffixed(&script, ".args"))?;
        assert_eq!(
            arguments.lines().collect::<Vec<_>>(),
            vec![
                "store",
                "--label=Omabox Dropbox credentials",
                "application",
                "org.omarchy.omabox",
                "kind",
                "dropbox-credentials-v1"
            ]
        );
        let input = fs::read(suffixed(&script, ".stdin"))?;
        assert!(!input.ends_with(b"\n"));
        let record: serde_json::Value = serde_json::from_slice(&input)?;
        assert_eq!(record["version"], 1);
        assert_eq!(record["refresh_token"], token);
        assert_eq!(record["account_id"], "account-id");
        assert_eq!(record["root_namespace_id"], "namespace-id");
        assert_eq!(record["remote_root"], "/Root");
        Ok(())
    }

    #[test]
    fn secret_tool_lookup_decodes_record_and_preserves_nonzero_status() -> Result<(), Box<dyn Error>>
    {
        let directory = tempfile::TempDir::new()?;
        let script = fake_script(
            directory.path(),
            "lookup-fake",
            "printf '%s\\n' \"$@\" > \"$0.args\"\nprintf '%s' '{\"version\":1,\"refresh_token\":\"lookup-token\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"/Root\"}'\n",
        )?;
        let found = RefreshTokenStore::with_script(&script).load()?;
        let CredentialLookup::Found(credential) = found else {
            return Err(std::io::Error::other("fake credential was unavailable").into());
        };
        assert_eq!(credential.binding.account_id, "account");
        assert_eq!(credential.binding.root_namespace_id, "namespace");
        assert_eq!(credential.binding.remote_root, "/Root");
        assert_eq!(credential.refresh_token.expose(), "lookup-token");
        assert_eq!(
            fs::read_to_string(suffixed(&script, ".args"))?
                .lines()
                .collect::<Vec<_>>(),
            vec![
                "lookup",
                "application",
                "org.omarchy.omabox",
                "kind",
                "dropbox-credentials-v1"
            ]
        );

        let unavailable = fake_script(directory.path(), "unavailable-fake", "exit 7\n")?;
        assert!(matches!(
            RefreshTokenStore::with_script(unavailable).load()?,
            CredentialLookup::CredentialsUnavailable { status: Some(7) }
        ));
        Ok(())
    }

    #[test]
    fn secret_tool_parser_diagnostics_do_not_echo_output() -> Result<(), Box<dyn Error>> {
        let directory = tempfile::TempDir::new()?;
        let secret = "parser-output-secret-sentinel";
        let script = fake_script(
            directory.path(),
            "malformed-fake",
            &format!("printf '%s' '{{\"refresh_token\":\"{secret}\",BROKEN'\n"),
        )?;
        let failure = RefreshTokenStore::with_script(script)
            .load()
            .err()
            .ok_or_else(|| std::io::Error::other("malformed credential was accepted"))?;

        assert!(!error_diagnostic(&failure).contains(secret));
        Ok(())
    }

    #[test]
    fn secret_tool_data_error_diagnostics_do_not_echo_output() -> Result<(), Box<dyn Error>> {
        let directory = tempfile::TempDir::new()?;
        let secret = "typed-field-secret-sentinel";
        let script = fake_script(
            directory.path(),
            "wrong-type-fake",
            &format!(
                "printf '%s' '{{\"version\":\"{secret}\",\"refresh_token\":\"token\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"\"}}'\n"
            ),
        )?;
        let failure = RefreshTokenStore::with_script(script)
            .load()
            .err()
            .ok_or_else(|| std::io::Error::other("wrongly typed credential was accepted"))?;
        let diagnostic = error_diagnostic(&failure);
        let report = format!("{:?}", miette::Report::msg(failure.to_string()));

        assert!(!diagnostic.contains(secret));
        assert!(!report.contains(secret));
        assert!(diagnostic.contains("credential JSON data error"));
        Ok(())
    }

    fn closed_endpoint() -> Result<String, std::io::Error> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let address = listener.local_addr()?;
        drop(listener);
        Ok(format!("http://{address}"))
    }

    fn error_diagnostic(error: &(dyn Error + 'static)) -> String {
        let mut diagnostic = format!("{error:?}\n{error}");
        let mut source = error.source();
        while let Some(current) = source {
            diagnostic.push('\n');
            diagnostic.push_str(&format!("{current:?}\n{current}"));
            source = current.source();
        }
        diagnostic
    }

    /// Write a `secret-tool` stand-in without the executable bit.
    ///
    /// `RefreshTokenStore::with_script` reads it through `/bin/sh`, so writing
    /// one can never collide with a concurrent spawn in the test binary.
    fn fake_script(directory: &Path, name: &str, body: &str) -> Result<PathBuf, std::io::Error> {
        let path = directory.join(name);
        fs::write(&path, body)?;
        Ok(path)
    }

    fn suffixed(path: &Path, suffix: &str) -> PathBuf {
        PathBuf::from(format!("{}{suffix}", path.display()))
    }
}
