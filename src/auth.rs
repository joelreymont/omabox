//! Dropbox OAuth Authorization Code with PKCE.

use std::fmt;
use std::io::{self, Read as _, Write as _};
#[cfg(test)]
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::str;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rustix::rand::{GetRandomFlags, getrandom};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use thiserror::Error;

use crate::dropbox::DropboxEndpoints;
use crate::journal::DropboxBinding;
#[cfg(test)]
use crate::spawn::Launch;

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
        .map_err(|source| AuthError::CredentialJson { source })?;
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
            let _ = child.kill();
            let _ = child.wait();
            return Err(AuthError::CredentialPipeUnavailable {
                operation: "store Dropbox credential",
            });
        };
        let written = stdin.write_all(&secret);
        drop(stdin);
        if let Err(source) = written {
            let _ = child.wait();
            return Err(AuthError::CredentialWrite { source });
        }
        let status = child.wait().map_err(|source| AuthError::CredentialWait {
            operation: "store Dropbox credential",
            source,
        })?;
        if !status.success() {
            return Err(AuthError::CredentialStatus {
                operation: "store Dropbox credential",
                status: status.code(),
            });
        }
        Ok(())
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
            let _ = child.kill();
            let _ = child.wait();
            return Err(AuthError::CredentialPipeUnavailable {
                operation: "load Dropbox credential",
            });
        };
        let mut secret = Vec::new();
        let read = stdout
            .take(SECRET_BYTES_LIMIT as u64)
            .read_to_end(&mut secret);
        let status = child.wait().map_err(|source| AuthError::CredentialWait {
            operation: "load Dropbox credential",
            source,
        })?;
        read.map_err(|source| AuthError::CredentialRead { source })?;
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
        let stored: LoadedSecret =
            serde_json::from_str(secret).map_err(|source| AuthError::CredentialJson { source })?;
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
    verifier: String,
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
            .field("verifier", &"[REDACTED]")
            .finish()
    }
}

/// Tokens and account identity returned by initial authorization.
#[derive(Debug)]
pub struct AuthorizationGrant {
    /// Dropbox account that authorized access.
    pub account_id: String,
    /// Short-lived token for Dropbox API calls.
    pub access_token: AccessToken,
    /// Long-lived token that belongs in Secret Service.
    pub refresh_token: RefreshToken,
    /// Lifetime reported for the access token.
    pub expires_in: Duration,
}

/// A freshly issued short-lived access token.
#[derive(Debug)]
pub struct RefreshedAccess {
    /// Token for Dropbox API calls.
    pub access_token: AccessToken,
    /// Lifetime reported by Dropbox.
    pub expires_in: Duration,
}

/// Direct blocking Dropbox OAuth client.
pub struct OAuthClient {
    app_key: String,
    endpoints: DropboxEndpoints,
    agent: ureq::Agent,
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
        let config = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(60)))
            .build();
        Self {
            app_key: app_key.into(),
            endpoints,
            agent: ureq::Agent::new_with_config(config),
        }
    }

    /// Start one authorization attempt with a fresh PKCE verifier.
    pub fn begin(&self) -> Result<PendingAuthorization, AuthError> {
        let verifier = random_urlsafe()?;
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let query = form_urlencoded::Serializer::new(String::new())
            .append_pair("client_id", &self.app_key)
            .append_pair("response_type", "code")
            .append_pair("token_access_type", "offline")
            .append_pair(
                "scope",
                "account_info.read files.metadata.read files.content.read files.content.write",
            )
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .finish();
        Ok(PendingAuthorization {
            authorization_url: format!("{}?{query}", self.endpoints.authorize()),
            verifier,
        })
    }

    /// Exchange the manually copied authorization code.
    pub fn exchange(
        &self,
        pending: PendingAuthorization,
        code: &str,
    ) -> Result<AuthorizationGrant, AuthError> {
        let mut response = self
            .agent
            .post(self.endpoints.token())
            .send_form([
                ("client_id", self.app_key.as_str()),
                ("code", code),
                ("code_verifier", pending.verifier.as_str()),
                ("grant_type", "authorization_code"),
            ])
            .map_err(|source| AuthError::Transport {
                operation: "exchange authorization code",
                source,
            })?;
        require_success(
            response.status().as_u16(),
            response.headers().get("Retry-After"),
            "exchange authorization code",
        )?;
        let payload: AuthorizationResponse =
            response
                .body_mut()
                .read_json()
                .map_err(|source| AuthError::Response {
                    operation: "decode authorization response",
                    source,
                })?;
        Ok(AuthorizationGrant {
            account_id: payload.account_id,
            access_token: AccessToken(payload.access_token),
            refresh_token: RefreshToken(payload.refresh_token),
            expires_in: Duration::from_secs(payload.expires_in),
        })
    }

    /// Use a protected refresh token to obtain a new short-lived access token.
    pub fn refresh(&self, refresh_token: &RefreshToken) -> Result<RefreshedAccess, AuthError> {
        let mut response = self
            .agent
            .post(self.endpoints.token())
            .send_form([
                ("client_id", self.app_key.as_str()),
                ("refresh_token", refresh_token.expose()),
                ("grant_type", "refresh_token"),
            ])
            .map_err(|source| AuthError::Transport {
                operation: "refresh access token",
                source,
            })?;
        require_success(
            response.status().as_u16(),
            response.headers().get("Retry-After"),
            "refresh access token",
        )?;
        let payload: RefreshResponse =
            response
                .body_mut()
                .read_json()
                .map_err(|source| AuthError::Response {
                    operation: "decode token refresh response",
                    source,
                })?;
        Ok(RefreshedAccess {
            access_token: AccessToken(payload.access_token),
            expires_in: Duration::from_secs(payload.expires_in),
        })
    }
}

#[derive(Deserialize)]
struct AuthorizationResponse {
    access_token: String,
    refresh_token: String,
    expires_in: u64,
    account_id: String,
}

#[derive(Deserialize)]
struct RefreshResponse {
    access_token: String,
    expires_in: u64,
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
    /// Dropbox rate-limited an OAuth request.
    #[error("Dropbox OAuth operation `{operation}` was rate limited")]
    RateLimited {
        /// Safe operation name.
        operation: &'static str,
        /// Server-requested delay when Dropbox returned valid delta seconds.
        retry_after: Option<Duration>,
    },
    /// Dropbox returned a non-success status.
    #[error("Dropbox OAuth operation `{operation}` returned HTTP status {status}")]
    HttpStatus {
        /// Safe operation name.
        operation: &'static str,
        /// HTTP status code.
        status: u16,
    },
    /// The request could not be completed.
    #[error("Dropbox OAuth operation `{operation}` could not reach the service")]
    Transport {
        /// Safe operation name.
        operation: &'static str,
        /// Original transport error, which does not contain request headers or bodies.
        #[source]
        source: ureq::Error,
    },
    /// A successful response did not match Dropbox's documented schema.
    #[error("Dropbox OAuth operation `{operation}` returned an invalid response")]
    Response {
        /// Safe operation name.
        operation: &'static str,
        /// Original JSON decoding error.
        #[source]
        source: ureq::Error,
    },
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

fn random_urlsafe() -> Result<String, AuthError> {
    let mut bytes = [0_u8; RANDOM_VALUE_BYTES];
    getrandom(&mut bytes, GetRandomFlags::empty())
        .map_err(|source| AuthError::Random { source })?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn require_success(
    status: u16,
    retry_after: Option<&ureq::http::HeaderValue>,
    operation: &'static str,
) -> Result<(), AuthError> {
    if (200..300).contains(&status) {
        Ok(())
    } else if status == 429 {
        let retry_after = retry_after
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok())
            .map(Duration::from_secs);
        Err(AuthError::RateLimited {
            operation,
            retry_after,
        })
    } else {
        Err(AuthError::HttpStatus { operation, status })
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;
    use std::fs;
    use std::net::TcpListener;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use crate::dropbox::{DropboxClient, DropboxEndpoints, DropboxRoot};
    use crate::journal::{DropboxBinding, Journal};

    use super::{
        AccessToken, AuthError, CredentialLookup, OAuthClient, RefreshToken, RefreshTokenStore,
        require_success,
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
        let verifier = pending.verifier.clone();
        let diagnostic = format!("{pending:?}");

        assert!(!diagnostic.contains(&verifier));
        assert!(!diagnostic.contains("code_challenge="));
        Ok(())
    }

    #[test]
    fn oauth_rate_limit_preserves_retry_after_seconds() -> Result<(), Box<dyn Error>> {
        let retry_after = ureq::http::HeaderValue::from_static("17");
        let result = require_success(429, Some(&retry_after), "refresh access token");

        assert!(matches!(
            result,
            Err(AuthError::RateLimited {
                operation: "refresh access token",
                retry_after: Some(delay),
            }) if delay == Duration::from_secs(17)
        ));
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
        let verifier = pending.verifier.clone();
        let code = "authorization-code-sentinel";
        let exchange = oauth.exchange(pending, code);
        let exchange_error = exchange
            .err()
            .ok_or_else(|| std::io::Error::other("closed endpoint accepted exchange"))?;
        let exchange_diagnostic = error_diagnostic(&exchange_error);
        assert!(!exchange_diagnostic.contains(code));
        assert!(!exchange_diagnostic.contains(&verifier));

        let refresh_value = "refresh-token-sentinel";
        let refresh = oauth.refresh(&RefreshToken::from_secret(refresh_value));
        let refresh_error = refresh
            .err()
            .ok_or_else(|| std::io::Error::other("closed endpoint accepted refresh"))?;
        assert!(!error_diagnostic(&refresh_error).contains(refresh_value));
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
        );
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
