//! Dropbox wire transport for `dropbox-sdk`'s synchronous client traits.
//!
//! The SDK owns the generated types, the routes and the response parser. Its
//! client boundary cannot express what Dropbox's documented behavior needs, so
//! every gap is an explicit adapter here: origin rebasing, per-kind deadlines,
//! header validation, `Dropbox-API-Arg` escaping, range verification,
//! rate-limit and path-root errors, and a single-flight token refresh.
//!
//! Both agents refuse to follow redirects. Rebasing keeps the route path, so an
//! authorization header can only ever travel to an origin the SDK named; a
//! followed redirect would carry it anywhere, so a 3xx is handed to the SDK as
//! an unexpected status instead.

use std::fmt;
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use dropbox_sdk::client_trait::{
    HttpClient, HttpRequest, HttpRequestResultRaw, NoauthClient, UserAuthClient,
};
use dropbox_sdk::oauth2::Authorization;
use dropbox_sdk::types::auth::RateLimitReason;
use dropbox_sdk::types::common::{PathRoot, PathRootError};
use dropbox_sdk::{Error as SdkError, NoError};
use serde::Deserialize;
use serde::de::IgnoredAny;
use thiserror::Error;
use ureq::http::header::{InvalidHeaderName, InvalidHeaderValue};
use ureq::http::{HeaderMap, HeaderName, HeaderValue};

use crate::auth::{AccessToken, AuthError, RefreshToken, RefreshTokenStore};
use crate::journal::DropboxBinding;

/// Longest delay Dropbox may ask this client to wait before retrying.
pub const MAX_RETRY_AFTER: Duration = Duration::from_secs(15 * 60);

/// Deadline for establishing a connection, on both agents.
const CONNECT_SECONDS: u64 = 15;
/// Deadline for a whole JSON call, and for sending a content request.
const JSON_REQUEST_SECONDS: u64 = 60;
/// Longest a content body may make no progress at all.
const BODY_IDLE_SECONDS: u64 = 60;
/// Deadline for Dropbox's answer once an upload body has been sent.
///
/// ureq lets a preceding phase's deadline bind the next one, so the wait for an
/// upload's response is never longer than [`BODY_IDLE_SECONDS`] measured from
/// the last body byte. Keeping this at or below that value makes the row of the
/// deadline table the binding one by construction.
const UPLOAD_RESPONSE_SECONDS: u64 = 60;
/// Deadline for a session finish, which commits every appended byte.
const SESSION_FINISH_SECONDS: u64 = 60 * 60;
/// Slack Dropbox documents for long-poll responses beyond the asked timeout.
const LONG_POLL_SLACK_SECONDS: u64 = 90;
/// Local grace on top of Dropbox's documented long-poll slack.
const LONG_POLL_GRACE_SECONDS: u64 = 105;
/// Timeout a long-poll request means when its argument omits one.
const DEFAULT_LONG_POLL_SECONDS: u64 = 30;

/// Longest error body `execute` reads to build a typed local error.
const ERROR_BODY_LIMIT: u64 = 64 * 1024;
/// Idle connections kept per agent.
const IDLE_CONNECTIONS: usize = 4;

/// Seconds in one day, for `Retry-After` dates.
const SECONDS_PER_DAY: u64 = 24 * 60 * 60;
/// Seconds in one hour, for `Retry-After` dates.
const SECONDS_PER_HOUR: u64 = 60 * 60;
/// Seconds in one minute, for `Retry-After` dates.
const SECONDS_PER_MINUTE: u64 = 60;
/// Length of the one date form HTTP servers must send.
const FIXDATE_BYTES: usize = 29;
/// First year a `Retry-After` date may name.
const EPOCH_YEAR: u64 = 1970;
/// Last year a `Retry-After` date may name.
const LAST_YEAR: u64 = 9999;
/// Day names an IMF-fixdate may start with.
const DAY_NAMES: [&[u8]; 7] = [b"Mon", b"Tue", b"Wed", b"Thu", b"Fri", b"Sat", b"Sun"];
/// Month names an IMF-fixdate may carry.
const MONTH_NAMES: [&[u8]; 12] = [
    b"Jan", b"Feb", b"Mar", b"Apr", b"May", b"Jun", b"Jul", b"Aug", b"Sep", b"Oct", b"Nov", b"Dec",
];

const RANGE: &str = "range";
const CONTENT_RANGE: &str = "content-range";
const CONTENT_LENGTH: &str = "content-length";
const RETRY_AFTER: &str = "retry-after";
const DROPBOX_API_RESULT: &str = "dropbox-api-result";
const DROPBOX_API_ARG: &str = "dropbox-api-arg";
const PATH_ROOT_ERROR: &str = "dropbox-api-path-root-error";
const ACCEPT_ENCODING: &str = "accept-encoding";

/// The four origins `dropbox-sdk` builds request URLs from.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Base {
    /// `https://api.dropboxapi.com/2/`.
    Api,
    /// `https://content.dropboxapi.com/2/`.
    Content,
    /// `https://notify.dropboxapi.com/2/`.
    Notify,
    /// `https://api.dropboxapi.com/`, which the API prefix must be matched before.
    OAuth,
}

/// Dropbox's documented origins, longest path prefix first.
const PRODUCTION: [(Base, &str); 4] = [
    (Base::Api, "https://api.dropboxapi.com/2/"),
    (Base::Content, "https://content.dropboxapi.com/2/"),
    (Base::Notify, "https://notify.dropboxapi.com/2/"),
    (Base::OAuth, "https://api.dropboxapi.com/"),
];

/// What shape of deadline a route needs.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RequestKind {
    /// A JSON call with both bodies bounded by one deadline.
    Rpc,
    /// A content upload whose request body is streamed.
    Upload,
    /// An upload-session finish, which commits every appended byte.
    Finish,
    /// A content download whose response body is streamed.
    Download,
    /// A long poll whose deadline follows the timeout it asks for.
    LongPoll,
    /// An OAuth token request, which carries no authorization.
    OAuth,
}

/// Every route this client issues, with its origin and deadline shape.
///
/// A route outside this table is a typed error rather than a request sent with
/// a guessed deadline.
const ROUTES: [(Base, &str, RequestKind); 13] = [
    (Base::Api, "files/list_folder", RequestKind::Rpc),
    (Base::Api, "files/list_folder/continue", RequestKind::Rpc),
    (Base::Api, "files/get_metadata", RequestKind::Rpc),
    (Base::Api, "files/delete_v2", RequestKind::Rpc),
    (Base::Api, "files/create_folder_v2", RequestKind::Rpc),
    (Base::Api, "users/get_current_account", RequestKind::Rpc),
    (Base::Content, "files/download", RequestKind::Download),
    (Base::Content, "files/upload", RequestKind::Upload),
    (
        Base::Content,
        "files/upload_session/start",
        RequestKind::Upload,
    ),
    (
        Base::Content,
        "files/upload_session/append_v2",
        RequestKind::Upload,
    ),
    (
        Base::Content,
        "files/upload_session/finish",
        RequestKind::Finish,
    ),
    (
        Base::Notify,
        "files/list_folder/longpoll",
        RequestKind::LongPoll,
    ),
    (Base::OAuth, "oauth2/token", RequestKind::OAuth),
];

/// Origins this transport sends to.
///
/// Production callers use [`Bases::production`]. [`Bases::new`] exists so
/// protocol tests can point the real transport at a local server; rebasing
/// keeps the route path, so an authorization header can never travel to an
/// origin the SDK did not name.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Bases {
    api: String,
    content: String,
    notify: String,
    oauth: String,
}

impl Bases {
    /// Dropbox's documented production origins.
    #[must_use]
    pub fn production() -> Self {
        Self {
            api: String::from(PRODUCTION[0].1),
            content: String::from(PRODUCTION[1].1),
            notify: String::from(PRODUCTION[2].1),
            oauth: String::from(PRODUCTION[3].1),
        }
    }

    /// Explicit origins for a local protocol server.
    ///
    /// Each value must end with the separator that precedes a route path.
    #[must_use]
    pub fn new(
        api: impl Into<String>,
        content: impl Into<String>,
        notify: impl Into<String>,
        oauth: impl Into<String>,
    ) -> Self {
        Self {
            api: api.into(),
            content: content.into(),
            notify: notify.into(),
            oauth: oauth.into(),
        }
    }

    fn origin(&self, base: Base) -> &str {
        match base {
            Base::Api => &self.api,
            Base::Content => &self.content,
            Base::Notify => &self.notify,
            Base::OAuth => &self.oauth,
        }
    }

    /// Map one SDK-built URL onto this transport's origins and deadline shape.
    fn resolve(&self, url: &str) -> Result<Target, TransportError> {
        for (base, prefix) in PRODUCTION {
            let Some(route) = url.strip_prefix(prefix) else {
                continue;
            };
            let kind = ROUTES
                .iter()
                .find(|(origin, name, _)| *origin == base && *name == route)
                .map(|(_, _, kind)| *kind)
                .ok_or_else(|| TransportError::UnsupportedRoute {
                    route: String::from(route),
                })?;
            return Ok(Target {
                kind,
                url: format!("{}{route}", self.origin(base)),
            });
        }
        Err(TransportError::UnsupportedOrigin {
            url: String::from(url),
        })
    }
}

impl Default for Bases {
    fn default() -> Self {
        Self::production()
    }
}

/// A resolved request destination.
#[derive(Clone, Debug, Eq, PartialEq)]
struct Target {
    kind: RequestKind,
    url: String,
}

/// Per-kind deadline constants.
///
/// Conformance tests inject small values to prove each row of the deadline
/// table behaviorally; production always uses [`Deadlines::production`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Deadlines {
    /// Connection deadline, shared by both agents.
    pub connect: Duration,
    /// Whole-call deadline for JSON calls, and send deadline for downloads.
    pub json_request: Duration,
    /// Longest a content body may make no progress.
    pub body_idle: Duration,
    /// Deadline for Dropbox's answer to an upload; never above `body_idle`.
    pub upload_response: Duration,
    /// Deadline for a session finish.
    pub session_finish: Duration,
    /// Slack Dropbox documents beyond a long poll's own timeout.
    pub long_poll_slack: Duration,
    /// Local grace on top of that slack.
    pub long_poll_grace: Duration,
}

impl Deadlines {
    /// The deadlines Omabox runs with.
    #[must_use]
    pub fn production() -> Self {
        Self {
            connect: Duration::from_secs(CONNECT_SECONDS),
            json_request: Duration::from_secs(JSON_REQUEST_SECONDS),
            body_idle: Duration::from_secs(BODY_IDLE_SECONDS),
            upload_response: Duration::from_secs(UPLOAD_RESPONSE_SECONDS),
            session_finish: Duration::from_secs(SESSION_FINISH_SECONDS),
            long_poll_slack: Duration::from_secs(LONG_POLL_SLACK_SECONDS),
            long_poll_grace: Duration::from_secs(LONG_POLL_GRACE_SECONDS),
        }
    }

    /// The ureq phase deadlines one request sets; every other phase stays unset.
    fn phases(&self, kind: RequestKind, body: &[u8]) -> Result<Phases, TransportError> {
        Ok(match kind {
            RequestKind::Rpc | RequestKind::OAuth => Phases {
                global: Some(self.json_request),
                ..Phases::default()
            },
            RequestKind::Download => Phases {
                send_request: Some(self.json_request),
                recv_body: Some(self.body_idle),
                ..Phases::default()
            },
            RequestKind::Upload => Phases {
                send_body: Some(self.body_idle),
                recv_response: Some(self.upload_response),
                ..Phases::default()
            },
            RequestKind::Finish => Phases {
                recv_response: Some(self.session_finish),
                ..Phases::default()
            },
            RequestKind::LongPoll => Phases {
                global: Some(self.long_poll(body)?),
                ..Phases::default()
            },
        })
    }

    /// The deadline a long poll needs: its own timeout, Dropbox's slack, ours.
    fn long_poll(&self, body: &[u8]) -> Result<Duration, TransportError> {
        let argument: LongPollArgument = serde_json::from_slice(body)
            .map_err(|source| TransportError::LongPollArgument { source })?;
        let seconds = match argument.timeout {
            Some(seconds) => seconds,
            None => DEFAULT_LONG_POLL_SECONDS,
        };
        let overflow = || TransportError::LongPollOverflow { seconds };
        let total = seconds
            .checked_add(self.long_poll_slack.as_secs())
            .ok_or_else(overflow)?
            .checked_add(self.long_poll_grace.as_secs())
            .ok_or_else(overflow)?;
        Ok(Duration::from_secs(total))
    }
}

impl Default for Deadlines {
    fn default() -> Self {
        Self::production()
    }
}

/// The ureq phase deadlines applied to one request.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Phases {
    /// Deadline for the whole call.
    pub global: Option<Duration>,
    /// Deadline for sending the request head.
    pub send_request: Option<Duration>,
    /// Idle deadline while sending a request body.
    pub send_body: Option<Duration>,
    /// Deadline for the response head.
    pub recv_response: Option<Duration>,
    /// Idle deadline while reading a response body.
    pub recv_body: Option<Duration>,
}

/// A request the SDK is building, with its destination resolved eagerly.
///
/// [`HttpRequest::set_header`] cannot fail, so header names and values are kept
/// raw and validated in [`HttpClient::execute`], where a typed error can be
/// returned. A repeated name replaces the earlier one case-insensitively, so a
/// second `Range` or `Dropbox-API-Arg` can never reach Dropbox.
pub struct Request {
    target: Result<Target, TransportError>,
    headers: Vec<(String, String)>,
}

impl HttpRequest for Request {
    fn set_header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((String::from(name), String::from(value)));
        self
    }
}

/// Fold raw header pairs, last write per name winning case-insensitively.
///
/// The `Dropbox-API-Arg` value is re-encoded here, and a download always asks
/// for one representation, so offsets, lengths and hashes agree.
fn fold_headers(
    raw: Vec<(String, String)>,
    kind: RequestKind,
) -> Result<Vec<(String, String)>, TransportError> {
    let mut folded: Vec<(String, String)> = Vec::with_capacity(raw.len() + 1);
    for (name, value) in raw {
        match folded
            .iter_mut()
            .find(|(existing, _)| existing.eq_ignore_ascii_case(&name))
        {
            Some(slot) => {
                slot.0 = name;
                slot.1 = value;
            }
            None => folded.push((name, value)),
        }
    }
    for (name, value) in &mut folded {
        if name.eq_ignore_ascii_case(DROPBOX_API_ARG) {
            *value = escape_argument(value)?;
        }
    }
    if kind == RequestKind::Download {
        match folded
            .iter_mut()
            .find(|(name, _)| name.eq_ignore_ascii_case(ACCEPT_ENCODING))
        {
            Some(slot) => slot.1 = String::from("identity"),
            None => folded.push((String::from(ACCEPT_ENCODING), String::from("identity"))),
        }
    }
    Ok(folded)
}

/// Validate folded headers into the pairs ureq will send.
fn validate_headers(
    folded: &[(String, String)],
) -> Result<Vec<(HeaderName, HeaderValue)>, TransportError> {
    let mut validated = Vec::with_capacity(folded.len());
    for (name, value) in folded {
        let header = HeaderName::from_bytes(name.as_bytes()).map_err(|source| {
            TransportError::HeaderName {
                name: name.clone(),
                source,
            }
        })?;
        let content =
            HeaderValue::from_str(value).map_err(|source| TransportError::HeaderValue {
                name: name.clone(),
                source,
            })?;
        validated.push((header, content));
    }
    Ok(validated)
}

/// The offset a resume asked Dropbox to start from.
///
/// Only `bytes=N-` is used: a fresh download sends no range at all, so
/// `bytes=0-` is a caller bug rather than a request.
fn requested_range(folded: &[(String, String)]) -> Result<Option<u64>, TransportError> {
    let Some((_, value)) = folded
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case(RANGE))
    else {
        return Ok(None);
    };
    let unsupported = || TransportError::UnsupportedRange {
        value: value.clone(),
    };
    let offset = value
        .strip_prefix("bytes=")
        .and_then(|rest| rest.strip_suffix('-'))
        .ok_or_else(unsupported)?
        .parse::<u64>()
        .map_err(|_| unsupported())?;
    if offset == 0 {
        return Err(TransportError::ZeroRange);
    }
    Ok(Some(offset))
}

/// Re-encode a `Dropbox-API-Arg` value so every byte is printable ASCII.
///
/// The value must be JSON. Scalars from `U+0020` through `U+007E` are kept
/// verbatim, which preserves the escapes the serializer already wrote; every
/// other scalar becomes `\uXXXX`, as a UTF-16 surrogate pair above `U+FFFF`.
/// Never bytewise: a multi-byte scalar is one unit, not several.
fn escape_argument(value: &str) -> Result<String, TransportError> {
    serde_json::from_str::<IgnoredAny>(value)
        .map_err(|source| TransportError::ArgumentNotJson { source })?;
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut escaped = String::with_capacity(value.len());
    for scalar in value.chars() {
        if matches!(scalar, ' '..='~') {
            escaped.push(scalar);
            continue;
        }
        let mut units = [0_u16; 2];
        for unit in scalar.encode_utf16(&mut units) {
            escaped.push('\\');
            escaped.push('u');
            for shift in [12_u32, 8, 4, 0] {
                let digit = usize::from((*unit >> shift) & 0x0f);
                escaped.push(char::from(HEX[digit]));
            }
        }
    }
    Ok(escaped)
}

/// Delay a `Retry-After` header asks for, as delta seconds or an IMF-fixdate.
///
/// A date that has already passed asks for no delay rather than a negative one.
fn retry_after(value: Option<&str>, now: SystemTime) -> Option<Duration> {
    let value = value?.trim();
    if let Ok(seconds) = value.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }
    let at = fixdate(value)?;
    Some(match at.duration_since(now) {
        Ok(delay) => delay,
        Err(_) => Duration::ZERO,
    })
}

/// Parse `Sun, 06 Nov 1994 08:49:37 GMT`, the only form servers must send.
fn fixdate(value: &str) -> Option<SystemTime> {
    let bytes = value.as_bytes();
    if bytes.len() != FIXDATE_BYTES
        || !DAY_NAMES.contains(&&bytes[..3])
        || &bytes[3..5] != b", "
        || bytes[7] != b' '
        || bytes[11] != b' '
        || bytes[16] != b' '
        || bytes[19] != b':'
        || bytes[22] != b':'
        || &bytes[25..] != b" GMT"
    {
        return None;
    }
    let day = digits(&bytes[5..7])?;
    let month = month(&bytes[8..11])?;
    let year = digits(&bytes[12..16])?;
    let hour = digits(&bytes[17..19])?;
    let minute = digits(&bytes[20..22])?;
    let second = digits(&bytes[23..25])?;
    if !(EPOCH_YEAR..=LAST_YEAR).contains(&year)
        || day < 1
        || day > month_days(year, month)?
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let seconds = epoch_days(year, month, day)? * SECONDS_PER_DAY
        + hour * SECONDS_PER_HOUR
        + minute * SECONDS_PER_MINUTE
        + second.min(59);
    Some(UNIX_EPOCH + Duration::from_secs(seconds))
}

fn digits(bytes: &[u8]) -> Option<u64> {
    if bytes.is_empty() {
        return None;
    }
    let mut value = 0_u64;
    for byte in bytes {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value.checked_mul(10)?.checked_add(u64::from(byte - b'0'))?;
    }
    Some(value)
}

fn month(name: &[u8]) -> Option<u64> {
    let index = MONTH_NAMES.iter().position(|month| *month == name)?;
    u64::try_from(index).ok().map(|index| index + 1)
}

fn month_days(year: u64, month: u64) -> Option<u64> {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => Some(31),
        4 | 6 | 9 | 11 => Some(30),
        2 if leap_year(year) => Some(29),
        2 => Some(28),
        _ => None,
    }
}

fn leap_year(year: u64) -> bool {
    year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400))
}

/// Whole days from 1970-01-01 to a validated civil date at or after the epoch.
fn epoch_days(year: u64, month: u64, day: u64) -> Option<u64> {
    let mut days = 0;
    for past in EPOCH_YEAR..year {
        days += if leap_year(past) { 366 } else { 365 };
    }
    for past in 1..month {
        days += month_days(year, past)?;
    }
    Some(days + day - 1)
}

/// Blocking Dropbox transport over two pooled ureq agents.
pub struct Transport {
    content: ureq::Agent,
    poll: ureq::Agent,
    bases: Bases,
    tokens: Arc<TokenState>,
    path_root: String,
    deadlines: Deadlines,
}

impl Transport {
    /// Bind a transport to one activated path root.
    pub fn new(
        bases: Bases,
        path_root: &PathRoot,
        tokens: Arc<TokenState>,
    ) -> Result<Self, TransportError> {
        Self::with_deadlines(bases, path_root, tokens, Deadlines::production())
    }

    /// Bind a transport with explicit deadlines, for conformance tests.
    pub fn with_deadlines(
        bases: Bases,
        path_root: &PathRoot,
        tokens: Arc<TokenState>,
        deadlines: Deadlines,
    ) -> Result<Self, TransportError> {
        let path_root = serde_json::to_string(path_root)
            .map_err(|source| TransportError::PathRootArgument { source })?;
        Ok(Self {
            content: agent(deadlines.connect),
            poll: agent(deadlines.connect),
            bases,
            tokens,
            path_root,
            deadlines,
        })
    }

    /// The shared access-token state, so routes can report a rejected token.
    #[must_use]
    pub fn tokens(&self) -> &Arc<TokenState> {
        &self.tokens
    }

    /// Bind a token from initial authorization without refresh credentials.
    pub fn with_access_token(
        bases: Bases,
        path_root: &PathRoot,
        token: &AccessToken,
    ) -> Result<Self, TransportError> {
        Self::new(bases, path_root, Arc::new(TokenState::access_only(token)))
    }

    /// Refresh a token explicitly rejected before the SDK's expiry retry.
    pub fn refresh_access(&self, old: Arc<String>) -> Result<bool, TransportError> {
        self.tokens.refresh(old.as_str(), self.refresh_client())
    }

    /// Retry durable rotation storage without another OAuth request.
    pub fn retry_persistence(&self) -> Result<(), TransportError> {
        self.tokens.retry_persistence()
    }

    /// A client for unauthenticated long polling, using the retained poll pool.
    #[must_use]
    pub fn noauth(&self) -> RefreshClient<'_> {
        self.refresh_client()
    }

    fn wire(&self, kind: RequestKind) -> Wire<'_> {
        let agent = match kind {
            RequestKind::LongPoll | RequestKind::OAuth => &self.poll,
            RequestKind::Rpc
            | RequestKind::Upload
            | RequestKind::Finish
            | RequestKind::Download => &self.content,
        };
        Wire {
            agent,
            deadlines: &self.deadlines,
        }
    }

    /// Account lookup carries authentication without a file namespace header.
    #[must_use]
    pub fn account(&self) -> AccountClient<'_> {
        AccountClient(self)
    }

    fn refresh_client(&self) -> RefreshClient<'_> {
        RefreshClient {
            agent: &self.poll,
            bases: &self.bases,
            deadlines: &self.deadlines,
        }
    }
}

/// One agent plus the deadlines that bound the requests sent through it.
struct Wire<'a> {
    agent: &'a ureq::Agent,
    deadlines: &'a Deadlines,
}

impl Wire<'_> {
    /// Send one resolved request and hand its streaming body back to the SDK.
    fn send(
        &self,
        target: Target,
        headers: Vec<(String, String)>,
        body: &[u8],
    ) -> Result<HttpRequestResultRaw, TransportError> {
        let folded = fold_headers(headers, target.kind)?;
        let range = requested_range(&folded)?;
        let validated = validate_headers(&folded)?;
        let phases = self.deadlines.phases(target.kind, body)?;

        let mut config = self.agent.post(&target.url).config();
        config = config.timeout_global(phases.global);
        config = config.timeout_send_request(phases.send_request);
        config = config.timeout_send_body(phases.send_body);
        config = config.timeout_recv_response(phases.recv_response);
        config = config.timeout_recv_body(phases.recv_body);
        let mut builder = config.build();
        for (name, value) in validated {
            builder = builder.header(name, value);
        }
        let response = builder
            .send(body)
            .map_err(|source| TransportError::Unreachable { source })?;

        let (parts, body) = response.into_parts();
        let status = parts.status.as_u16();
        let result_header = text_header(&parts.headers, DROPBOX_API_RESULT)?;
        let content_length = number_header(&parts.headers, CONTENT_LENGTH);
        let delay = retry_after(readable(&parts.headers, RETRY_AFTER), SystemTime::now());

        if status == 429 {
            return Err(match bounded_body(body) {
                Ok(body) => rate_limited(body, delay),
                Err(source) => TransportError::DelayedBodyFailure {
                    status,
                    delay: delay.map_or(Duration::ZERO, |delay| delay.min(MAX_RETRY_AFTER)),
                    source: Box::new(source),
                },
            });
        }
        if (500..600).contains(&status)
            && let Some(delay) = delay
        {
            return Err(TransportError::ServerBusy {
                delay: delay.min(MAX_RETRY_AFTER),
                body: match bounded_body(body) {
                    Ok(body) => body,
                    Err(source) => {
                        return Err(TransportError::DelayedBodyFailure {
                            status,
                            delay: delay.min(MAX_RETRY_AFTER),
                            source: Box::new(source),
                        });
                    }
                },
            });
        }
        if status == 422 {
            return Err(path_root_refused(
                text_header(&parts.headers, PATH_ROOT_ERROR)?,
                body,
            ));
        }
        let ranges = text_headers(&parts.headers, CONTENT_RANGE)?;
        if status == 416 {
            return Err(TransportError::RangeUnsatisfiable {
                length: unsatisfiable_length(&ranges),
            });
        }
        if let Some(requested) = range
            && (200..300).contains(&status)
        {
            match status {
                200 => return Err(TransportError::RangeIgnored { requested }),
                206 => verify_partial(&ranges, requested, content_length)?,
                other => {
                    return Err(TransportError::UnexpectedRangeStatus {
                        status: other,
                        requested,
                    });
                }
            }
        }
        Ok(HttpRequestResultRaw {
            status,
            result_header,
            content_length,
            body: stream(body),
        })
    }
}

/// Build the rate-limit failure Dropbox's body and header describe together.
fn rate_limited(body: String, header: Option<Duration>) -> TransportError {
    let parsed = serde_json::from_str::<Envelope<RateLimited>>(&body).ok();
    let from_body = parsed
        .as_ref()
        .map(|envelope| Duration::from_secs(envelope.error.retry_after));
    let delay = match (from_body, header) {
        (Some(body), Some(header)) => body.max(header),
        (Some(body), None) => body,
        (None, Some(header)) => header,
        (None, None) => Duration::ZERO,
    };
    TransportError::RateLimitFailure {
        reason: parsed.map(|envelope| envelope.error.reason),
        delay: delay.min(MAX_RETRY_AFTER),
        body,
    }
}

/// Type a refused path root from its header, falling back to the body.
fn path_root_refused(header: Option<String>, body: ureq::Body) -> TransportError {
    if let Some(header) = header
        && let Ok(source) = serde_json::from_str::<PathRootError>(&header)
    {
        return TransportError::PathRoot { source };
    }
    let body = match bounded_body(body) {
        Ok(body) => body,
        Err(failure) => return failure,
    };
    match serde_json::from_str::<Envelope<PathRootError>>(&body) {
        Ok(envelope) => TransportError::PathRoot {
            source: envelope.error,
        },
        Err(_) => TransportError::PathRootUnreadable { body },
    }
}

/// The length a 416 reports through `Content-Range: bytes */LENGTH`.
fn unsatisfiable_length(ranges: &[String]) -> Option<u64> {
    let [value] = ranges else {
        return None;
    };
    value
        .strip_prefix("bytes */")
        .and_then(|total| total.parse().ok())
}

/// Check that a partial response describes exactly the range that was asked for.
fn verify_partial(
    ranges: &[String],
    requested: u64,
    content_length: Option<u64>,
) -> Result<(), TransportError> {
    let [value] = ranges else {
        return Err(TransportError::RangeMismatch {
            requested,
            value: ranges.join(", "),
        });
    };
    let mismatch = || TransportError::RangeMismatch {
        requested,
        value: value.clone(),
    };
    let (span, total) = value
        .strip_prefix("bytes ")
        .and_then(|rest| rest.split_once('/'))
        .ok_or_else(mismatch)?;
    let (start, end) = span.split_once('-').ok_or_else(mismatch)?;
    let start = digits(start.as_bytes()).ok_or_else(mismatch)?;
    let end = digits(end.as_bytes()).ok_or_else(mismatch)?;
    if start != requested || end < start {
        return Err(mismatch());
    }
    if total != "*" && digits(total.as_bytes()).ok_or_else(mismatch)? <= end {
        return Err(mismatch());
    }
    let length = end
        .checked_sub(start)
        .and_then(|span| span.checked_add(1))
        .ok_or_else(mismatch)?;
    match content_length {
        Some(reported) if reported != length => Err(mismatch()),
        _ => Ok(()),
    }
}

/// Both agents accept every status so the SDK's parser classifies it, and
/// refuse redirects so an authorization header stays on its own origin.
fn agent(connect: Duration) -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .max_redirects_will_error(false)
        .timeout_connect(Some(connect))
        .max_idle_connections(IDLE_CONNECTIONS)
        .max_idle_connections_per_host(IDLE_CONNECTIONS)
        .build();
    ureq::Agent::new_with_config(config)
}

impl HttpClient for Transport {
    type Request = Request;

    fn execute(&self, request: Request, body: &[u8]) -> Result<HttpRequestResultRaw, SdkError> {
        let Request { target, headers } = request;
        let target = target.map_err(local)?;
        self.wire(target.kind)
            .send(target, headers, body)
            .map_err(local)
    }

    fn new_request(&self, url: &str) -> Request {
        Request {
            target: self.bases.resolve(url),
            headers: Vec::new(),
        }
    }

    fn update_token(&self, old: Arc<String>) -> Result<bool, SdkError> {
        self.tokens
            .refresh(old.as_str(), self.refresh_client())
            .map_err(local)
    }

    fn token(&self) -> Option<Arc<String>> {
        self.tokens.token()
    }

    fn path_root(&self) -> Option<&str> {
        Some(&self.path_root)
    }
}

impl UserAuthClient for Transport {}

/// Account-only SDK client, sharing token refresh and pools without a path root.
pub struct AccountClient<'a>(&'a Transport);
impl HttpClient for AccountClient<'_> {
    type Request = Request;
    fn new_request(&self, url: &str) -> Request {
        self.0.new_request(url)
    }
    fn execute(&self, request: Request, body: &[u8]) -> Result<HttpRequestResultRaw, SdkError> {
        self.0.execute(request, body)
    }
    fn token(&self) -> Option<Arc<String>> {
        self.0.token()
    }
    fn update_token(&self, old: Arc<String>) -> Result<bool, SdkError> {
        self.0.update_token(old)
    }
}
impl UserAuthClient for AccountClient<'_> {}

/// An unauthenticated pool available before account/root activation.
pub struct OAuthTransport {
    agent: ureq::Agent,
    bases: Bases,
    deadlines: Deadlines,
}

impl OAuthTransport {
    /// Construct the pool used for the initial OAuth exchange.
    #[must_use]
    pub fn new(bases: Bases) -> Self {
        let deadlines = Deadlines::production();
        Self {
            agent: agent(deadlines.connect),
            bases,
            deadlines,
        }
    }

    /// Borrow a by-value SDK client that carries neither token nor path root.
    #[must_use]
    pub fn client(&self) -> RefreshClient<'_> {
        RefreshClient {
            agent: &self.agent,
            bases: &self.bases,
            deadlines: &self.deadlines,
        }
    }
}

/// The unauthenticated client an OAuth refresh runs through.
///
/// It exposes no token and no path root, so a refresh can never carry either.
pub struct RefreshClient<'a> {
    agent: &'a ureq::Agent,
    bases: &'a Bases,
    deadlines: &'a Deadlines,
}

impl HttpClient for RefreshClient<'_> {
    type Request = Request;

    fn execute(&self, request: Request, body: &[u8]) -> Result<HttpRequestResultRaw, SdkError> {
        let Request { target, headers } = request;
        let target = target.map_err(local)?;
        let wire = Wire {
            agent: self.agent,
            deadlines: self.deadlines,
        };
        wire.send(target, headers, body).map_err(local)
    }

    fn new_request(&self, url: &str) -> Request {
        Request {
            target: self.bases.resolve(url),
            headers: Vec::new(),
        }
    }
}

impl NoauthClient for RefreshClient<'_> {}

/// Somewhere durable to keep a rotated refresh token.
///
/// The transport depends on the capability, not on the Secret Service command
/// that implements it, so rotation failure is testable without a keyring.
pub trait RotationStore: Send + Sync {
    /// Replace the stored credential with a rotated refresh token.
    fn replace(&self, binding: &DropboxBinding, refresh: &RefreshToken) -> Result<(), AuthError>;
}

impl RotationStore for RefreshTokenStore {
    fn replace(&self, binding: &DropboxBinding, refresh: &RefreshToken) -> Result<(), AuthError> {
        self.store(binding, refresh)
    }
}

/// Why the stored refresh token can no longer produce access tokens.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RejectCause {
    /// Dropbox refused the refresh token itself.
    #[error("Dropbox rejected the stored refresh token")]
    InvalidGrant,
    /// A freshly refreshed access token was still refused.
    #[error("Dropbox rejected a freshly refreshed access token")]
    InvalidAccessToken,
}

/// Access-token lifecycle shared by every request in flight.
pub struct TokenState {
    shared: Mutex<Shared>,
    advanced: Condvar,
    refresher: Mutex<Option<Refresher>>,
    refreshed: AtomicBool,
    refreshable: bool,
}

/// State guarded by the lock [`TokenState::token`] takes.
struct Shared {
    phase: TokenPhase,
    /// The failure of one attempt, kept for the cohort that waited on it.
    failure: Option<(u64, Arc<TransportError>)>,
    waiters: usize,
}

/// Where the access token is in its lifecycle.
enum TokenPhase {
    /// The current access token; `None` only at generation zero.
    Ready {
        generation: u64,
        token: Option<Arc<String>>,
    },
    /// One thread is refreshing away from `generation`; peers wait.
    Refreshing {
        generation: u64,
        previous: Option<Arc<String>>,
    },
    /// A rotated refresh token is usable but is not stored yet.
    PendingPersistence { generation: u64, token: Arc<String> },
    /// Only the user can restore access.
    Rejected { cause: RejectCause },
}

/// A rotated refresh token Secret Service has not accepted yet.
struct Rotation {
    token: RefreshToken,
    saved: String,
}

/// Refresh machinery, held only by the one thread performing a refresh.
struct Refresher {
    auth: Authorization,
    binding: DropboxBinding,
    store: Arc<dyn RotationStore>,
    stored: String,
    pending: Option<Rotation>,
}

/// What one completed refresh produced.
enum Refreshed {
    /// A usable token whose rotation, if any, is stored.
    Stored(Arc<String>),
    /// A usable token whose rotation Secret Service refused.
    Unstored(Arc<String>, AuthError),
}

/// Whether this caller must refresh, may proceed, or has to wait.
enum Claim {
    Refresh(u64),
    Peer,
    Wait(u64),
    Reject(RejectCause),
}

impl TokenState {
    fn access_only(token: &AccessToken) -> Self {
        Self {
            shared: Mutex::new(Shared {
                phase: TokenPhase::Ready {
                    generation: 0,
                    token: Some(Arc::new(token.expose().to_owned())),
                },
                failure: None,
                waiters: 0,
            }),
            advanced: Condvar::new(),
            refreshable: false,
            refresher: Mutex::new(None),
            refreshed: AtomicBool::new(false),
        }
    }

    fn retry_persistence(&self) -> Result<(), TransportError> {
        let mut locked = guard(&self.refresher);
        let Some(refresher) = locked.as_mut() else {
            return Ok(());
        };
        let Some(rotation) = refresher.pending.as_ref() else {
            return Ok(());
        };
        refresher
            .store
            .replace(&refresher.binding, &rotation.token)
            .map_err(|source| TransportError::RotationNotStored { source })?;
        if let Some(rotation) = refresher.pending.take() {
            refresher.stored = rotation.saved;
        }
        let mut shared = guard(&self.shared);
        if let TokenPhase::PendingPersistence { generation, token } = &shared.phase {
            shared.phase = TokenPhase::Ready {
                generation: *generation,
                token: Some(Arc::clone(token)),
            };
        }
        Ok(())
    }

    /// Start from a stored refresh token, with no access token yet.
    pub fn new(
        app_key: impl Into<String>,
        refresh: &RefreshToken,
        binding: DropboxBinding,
        store: Arc<dyn RotationStore>,
    ) -> Result<Self, TransportError> {
        let auth =
            Authorization::from_refresh_token(app_key.into(), String::from(refresh.expose()));
        let stored = auth.save().ok_or(TransportError::RotationUnsupported)?;
        Ok(Self {
            shared: Mutex::new(Shared {
                phase: TokenPhase::Ready {
                    generation: 0,
                    token: None,
                },
                failure: None,
                waiters: 0,
            }),
            advanced: Condvar::new(),
            refreshable: true,
            refresher: Mutex::new(Some(Refresher {
                auth,
                binding,
                store,
                stored,
                pending: None,
            })),
            refreshed: AtomicBool::new(false),
        })
    }

    /// The current access token, without waiting for a refresh in flight.
    #[must_use]
    pub fn token(&self) -> Option<Arc<String>> {
        match &guard(&self.shared).phase {
            TokenPhase::Ready { token, .. } => token.clone(),
            TokenPhase::PendingPersistence { token, .. } => Some(Arc::clone(token)),
            TokenPhase::Refreshing { previous, .. } => previous.clone(),
            TokenPhase::Rejected { .. } => None,
        }
    }

    /// Whether any refresh has produced a token in this process.
    #[must_use]
    pub fn refreshed(&self) -> bool {
        self.refreshed.load(Ordering::SeqCst)
    }

    /// Record that Dropbox refused a token that cannot be refreshed away.
    pub fn reject(&self, cause: RejectCause) {
        let mut shared = guard(&self.shared);
        shared.phase = TokenPhase::Rejected { cause };
        shared.failure = None;
        self.advanced.notify_all();
    }

    /// Refresh the access token the caller holds, at most once per generation.
    fn refresh(&self, old: &str, client: RefreshClient<'_>) -> Result<bool, TransportError> {
        if !self.refreshable {
            return match guard(&self.shared).phase {
                TokenPhase::Rejected { cause } => Err(TransportError::RefreshRejected(cause)),
                _ => Ok(false),
            };
        }
        let Some(generation) = self.claim(old)? else {
            return Ok(true);
        };
        let outcome = self.perform(client);
        self.publish(generation, outcome)
    }

    /// Decide whether this caller performs the refresh, waiting if a peer does.
    fn claim(&self, old: &str) -> Result<Option<u64>, TransportError> {
        let mut shared = guard(&self.shared);
        loop {
            let claim = match &shared.phase {
                TokenPhase::Rejected { cause } => Claim::Reject(*cause),
                TokenPhase::Ready { generation, token } => match current(token.as_ref()) == old {
                    true => Claim::Refresh(*generation),
                    false => Claim::Peer,
                },
                TokenPhase::PendingPersistence { generation, token } => {
                    match token.as_str() == old {
                        true => Claim::Refresh(*generation),
                        false => Claim::Peer,
                    }
                }
                TokenPhase::Refreshing {
                    generation,
                    previous,
                } => match current(previous.as_ref()) == old {
                    true => Claim::Wait(*generation),
                    false => Claim::Peer,
                },
            };
            match claim {
                Claim::Reject(cause) => return Err(TransportError::RefreshRejected(cause)),
                Claim::Peer => return Ok(None),
                Claim::Refresh(generation) => {
                    if shared.waiters > 0
                        && let Some((_, cause)) = &shared.failure
                    {
                        return Err(TransportError::SharedRefresh(Arc::clone(cause)));
                    }
                    let previous = match &shared.phase {
                        TokenPhase::Ready { token, .. } => token.clone(),
                        TokenPhase::PendingPersistence { token, .. } => Some(Arc::clone(token)),
                        TokenPhase::Refreshing { previous, .. } => previous.clone(),
                        TokenPhase::Rejected { .. } => None,
                    };
                    shared.failure = None;
                    shared.phase = TokenPhase::Refreshing {
                        generation,
                        previous,
                    };
                    return Ok(Some(generation));
                }
                Claim::Wait(generation) => {
                    shared.waiters += 1;
                    shared = wait(&self.advanced, shared);
                    shared.waiters -= 1;
                    if let Some((failed, cause)) = &shared.failure
                        && *failed == generation
                    {
                        return Err(TransportError::SharedRefresh(Arc::clone(cause)));
                    }
                }
            }
        }
    }

    /// Do the Secret Service and network work, off the lock `token` takes.
    fn perform(&self, client: RefreshClient<'_>) -> Result<Refreshed, TransportError> {
        let mut locked = guard(&self.refresher);
        let Some(refresher) = locked.as_mut() else {
            return Err(TransportError::RotationUnsupported);
        };
        if let Some(rotation) = refresher.pending.take() {
            if let Err(source) = refresher.store.replace(&refresher.binding, &rotation.token) {
                refresher.pending = Some(rotation);
                return Err(TransportError::RotationNotStored { source });
            }
            refresher.stored = rotation.saved;
            let token = self.token().ok_or(TransportError::RotationUnsupported)?;
            return Ok(Refreshed::Stored(token));
        }
        let token = Arc::new(
            refresher
                .auth
                .obtain_access_token(client)
                .map_err(oauth_failure)?,
        );
        let saved = refresher
            .auth
            .save()
            .ok_or(TransportError::RotationUnsupported)?;
        if saved == refresher.stored {
            return Ok(Refreshed::Stored(token));
        }
        let rotated = saved
            .strip_prefix("2&")
            .ok_or(TransportError::RotationUnsupported)?;
        let rotation = Rotation {
            token: RefreshToken::from_secret(rotated),
            saved,
        };
        match refresher.store.replace(&refresher.binding, &rotation.token) {
            Ok(()) => {
                refresher.stored = rotation.saved;
                Ok(Refreshed::Stored(token))
            }
            Err(source) => {
                refresher.pending = Some(rotation);
                Ok(Refreshed::Unstored(token, source))
            }
        }
    }

    /// Publish the outcome and wake every caller waiting on this generation.
    fn publish(
        &self,
        generation: u64,
        outcome: Result<Refreshed, TransportError>,
    ) -> Result<bool, TransportError> {
        let mut shared = guard(&self.shared);
        if let TokenPhase::Rejected { cause } = shared.phase {
            self.advanced.notify_all();
            return Err(TransportError::RefreshRejected(cause));
        }
        let published = match outcome {
            Ok(Refreshed::Stored(token)) => {
                shared.phase = TokenPhase::Ready {
                    generation: generation + 1,
                    token: Some(token),
                };
                self.refreshed.store(true, Ordering::SeqCst);
                Ok(true)
            }
            Ok(Refreshed::Unstored(token, source)) => {
                shared.phase = TokenPhase::PendingPersistence {
                    generation: generation + 1,
                    token,
                };
                self.refreshed.store(true, Ordering::SeqCst);
                Err(TransportError::RotationNotStored { source })
            }
            Err(TransportError::RefreshRejected(cause)) => {
                shared.phase = TokenPhase::Rejected { cause };
                Err(TransportError::RefreshRejected(cause))
            }
            Err(failure) => {
                let previous = match &shared.phase {
                    TokenPhase::Refreshing { previous, .. } => previous.clone(),
                    TokenPhase::Ready { token, .. } => token.clone(),
                    TokenPhase::PendingPersistence { token, .. } => Some(Arc::clone(token)),
                    TokenPhase::Rejected { .. } => None,
                };
                shared.phase = TokenPhase::Ready {
                    generation,
                    token: previous,
                };
                let shared_failure = Arc::new(failure);
                shared.failure = Some((generation, Arc::clone(&shared_failure)));
                Err(TransportError::SharedRefresh(shared_failure))
            }
        };
        self.advanced.notify_all();
        published
    }
}

/// The token string a caller would have seen, empty before the first refresh.
fn current(token: Option<&Arc<String>>) -> &str {
    match token {
        Some(token) => token.as_str(),
        None => "",
    }
}

/// Take a lock without a panicking poison policy.
fn guard<T>(lock: &Mutex<T>) -> MutexGuard<'_, T> {
    match lock.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// Wait on a condition variable without a panicking poison policy.
fn wait<'a, T>(condvar: &Condvar, guard: MutexGuard<'a, T>) -> MutexGuard<'a, T> {
    match condvar.wait(guard) {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// Wrap a local failure the way the SDK carries client errors.
fn local(failure: TransportError) -> SdkError<NoError> {
    SdkError::HttpClient(Box::new(failure))
}

/// Recover the typed local failure an OAuth refresh ran into.
/// Classify an OAuth failure after removing secret-bearing response text.
pub fn oauth_failure(failure: SdkError<NoError>) -> TransportError {
    let unusable = |failure: SdkError<NoError>| TransportError::RefreshUnusable {
        source: Box::new(sanitize_oauth_error(failure)),
    };
    match failure {
        SdkError::HttpClient(boxed) => match boxed.downcast::<TransportError>() {
            Ok(local) => redact_oauth_transport(*local),
            Err(other) => unusable(SdkError::HttpClient(other)),
        },
        SdkError::BadRequest(body) => match invalid_grant(&body) {
            true => TransportError::RefreshRejected(RejectCause::InvalidGrant),
            false => unusable(SdkError::BadRequest(body)),
        },
        // `NoError` is uninhabited, so this arm exists only for exhaustiveness.
        failure @ (SdkError::Api(_)
        | SdkError::Json(_)
        | SdkError::UnexpectedResponse(_)
        | SdkError::Authentication(_)
        | SdkError::RateLimited { .. }
        | SdkError::AccessDenied(_)
        | SdkError::ServerError(_)
        | SdkError::UnexpectedHttpError { .. }) => unusable(failure),
    }
}

fn redact_oauth_transport(failure: TransportError) -> TransportError {
    match failure {
        TransportError::RateLimitFailure { reason, delay, .. } => {
            TransportError::RateLimitFailure {
                reason,
                delay,
                body: String::from("[redacted OAuth response]"),
            }
        }
        TransportError::ServerBusy { delay, .. } => TransportError::ServerBusy {
            delay,
            body: String::from("[redacted OAuth response]"),
        },
        TransportError::PathRootUnreadable { .. } => TransportError::PathRootUnreadable {
            body: String::from("[redacted OAuth response]"),
        },
        failure => failure,
    }
}

fn sanitize_oauth_error(failure: SdkError<NoError>) -> SdkError<NoError> {
    match failure {
        SdkError::BadRequest(_) => SdkError::BadRequest(String::from("[redacted OAuth response]")),
        SdkError::UnexpectedResponse(_) => {
            SdkError::UnexpectedResponse(String::from("[redacted OAuth response]"))
        }
        SdkError::ServerError(_) => {
            SdkError::ServerError(String::from("[redacted OAuth response]"))
        }
        SdkError::UnexpectedHttpError { code, .. } => SdkError::UnexpectedHttpError {
            code,
            response: String::from("[redacted OAuth response]"),
        },
        SdkError::Json(_) => SdkError::Json(<serde_json::Error as serde::de::Error>::custom(
            "malformed OAuth response",
        )),
        failure @ (SdkError::Api(_)
        | SdkError::HttpClient(_)
        | SdkError::Authentication(_)
        | SdkError::RateLimited { .. }
        | SdkError::AccessDenied(_)) => failure,
    }
}

fn sdk_outcome(failure: &SdkError<NoError>) -> Outcome {
    use dropbox_sdk::types::auth::AuthError as Authentication;
    match failure {
        SdkError::Api(never) => match *never {},
        SdkError::HttpClient(_) | SdkError::ServerError(_) => Outcome::Retry { delay: None },
        SdkError::RateLimited {
            retry_after_seconds,
            ..
        } => Outcome::Retry {
            delay: Some(Duration::from_secs(u64::from(*retry_after_seconds)).min(MAX_RETRY_AFTER)),
        },
        SdkError::Authentication(auth) => match auth {
            Authentication::ExpiredAccessToken => Outcome::Retry { delay: None },
            Authentication::InvalidAccessToken
            | Authentication::InvalidSelectUser
            | Authentication::InvalidSelectAdmin
            | Authentication::UserSuspended
            | Authentication::MissingScope(_)
            | Authentication::RouteAccessDenied => Outcome::UserAction,
            Authentication::Other => Outcome::Invariant,
            // The pinned generated enum is non-exhaustive.
            _ => Outcome::Invariant,
        },
        SdkError::AccessDenied(_) => Outcome::UserAction,
        SdkError::BadRequest(_)
        | SdkError::UnexpectedResponse(_)
        | SdkError::UnexpectedHttpError { .. }
        | SdkError::Json(_) => Outcome::Invariant,
    }
}

/// Whether Dropbox refused the refresh token itself.
fn invalid_grant(body: &str) -> bool {
    match serde_json::from_str::<Envelope<String>>(body) {
        Ok(envelope) => envelope.error == "invalid_grant",
        Err(_) => false,
    }
}

/// What a caller must do about a transport failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    /// Retry, after the delay Dropbox asked for when it asked for one.
    Retry { delay: Option<Duration> },
    /// Wait for the environment to recover and publish the cause.
    Environmental,
    /// Only the user can restore this.
    UserAction,
    /// A bug on one side of the wire.
    Invariant,
}

/// A failure this transport detects, carried through `Error::HttpClient`.
#[derive(Debug, Error)]
pub enum TransportError {
    /// The SDK built a URL from an origin this transport does not serve.
    #[error("Dropbox transport was given the unsupported request URL `{url}`")]
    UnsupportedOrigin {
        /// URL the SDK asked for; it never carries request arguments.
        url: String,
    },
    /// The SDK asked for a route this transport does not map.
    #[error("Dropbox transport was given the unsupported route `{route}`")]
    UnsupportedRoute {
        /// Route path below the origin.
        route: String,
    },
    /// A header name the SDK set is not a valid header name.
    #[error("Dropbox request header name `{name}` is invalid")]
    HeaderName {
        /// Rejected header name.
        name: String,
        /// Original validation error.
        #[source]
        source: InvalidHeaderName,
    },
    /// A header value the SDK set is not a valid header value.
    #[error("Dropbox request header `{name}` carries an invalid value")]
    HeaderValue {
        /// Header whose value was rejected; the value itself is never rendered.
        name: String,
        /// Original validation error, which does not carry the value.
        #[source]
        source: InvalidHeaderValue,
    },
    /// The `Dropbox-API-Arg` header value was not JSON.
    #[error("Dropbox request argument header is not JSON")]
    ArgumentNotJson {
        /// Original JSON error, which carries only a category and a location.
        #[source]
        source: serde_json::Error,
    },
    /// The activated path root could not be serialized.
    #[error("Dropbox path root could not be serialized")]
    PathRootArgument {
        /// Original JSON error.
        #[source]
        source: serde_json::Error,
    },
    /// A resume asked for `bytes=0-`, which must be a plain unranged download.
    #[error("Dropbox download requested a zero-offset range instead of no range")]
    ZeroRange,
    /// A range this transport does not implement was requested.
    #[error("Dropbox download requested the unsupported range `{value}`")]
    UnsupportedRange {
        /// Requested `Range` value.
        value: String,
    },
    /// A long-poll argument could not be read from the request body.
    #[error("Dropbox long-poll argument is not JSON")]
    LongPollArgument {
        /// Original JSON error.
        #[source]
        source: serde_json::Error,
    },
    /// A long-poll deadline overflowed the supported range.
    #[error("Dropbox long-poll timeout {seconds} seconds overflows its deadline")]
    LongPollOverflow {
        /// Timeout the request asked for.
        seconds: u64,
    },
    /// The request could not be completed.
    #[error("Dropbox request could not reach the service")]
    Unreachable {
        /// Original transport error, which carries no headers or bodies.
        #[source]
        source: ureq::Error,
    },
    /// A bounded error body could not be read.
    #[error("Dropbox error response body could not be read")]
    ErrorBody {
        /// Original transport error.
        #[source]
        source: ureq::Error,
    },
    /// A response header was not readable text.
    #[error("Dropbox response header `{name}` is not text")]
    ResponseHeader {
        /// Header that could not be read.
        name: String,
    },
    /// A retryable response carried a delay but its body could not be read.
    #[error("Dropbox asked for a retry after {delay:?}, but its error body could not be read")]
    DelayedBodyFailure {
        /// Original HTTP status distinguishes a rejected request from an ambiguous mutation.
        status: u16,
        /// Delay retained independently of reading the body.
        delay: Duration,
        /// Original bounded body failure.
        #[source]
        source: Box<TransportError>,
    },
    /// Dropbox rate limited the request.
    #[error("Dropbox rate limited the request; retry after {delay:?}")]
    RateLimitFailure {
        /// Documented reason, absent when the body could not be parsed.
        reason: Option<RateLimitReason>,
        /// Delay to honor, capped at [`MAX_RETRY_AFTER`].
        delay: Duration,
        /// Bounded response body, which carries no credential of ours.
        body: String,
    },
    /// Dropbox asked the caller to come back later after a server failure.
    #[error("Dropbox is unavailable; retry after {delay:?}")]
    ServerBusy {
        /// Delay to honor, capped at [`MAX_RETRY_AFTER`].
        delay: Duration,
        /// Bounded response body.
        body: String,
    },
    /// Dropbox refused the activated path root.
    #[error("Dropbox refused the activated path root")]
    PathRoot {
        /// Typed path-root error.
        #[source]
        source: PathRootError,
    },
    /// A 422 did not describe which path-root rule it broke.
    #[error("Dropbox refused the path root without a documented reason")]
    PathRootUnreadable {
        /// Bounded response body.
        body: String,
    },
    /// A ranged download was answered with the whole file.
    #[error("Dropbox ignored the requested range from offset {requested}")]
    RangeIgnored {
        /// Offset the request asked to resume from.
        requested: u64,
    },
    /// A partial response did not describe the range that was asked for.
    #[error("Dropbox returned a partial response that does not match offset {requested}")]
    RangeMismatch {
        /// Offset the request asked to resume from.
        requested: u64,
        /// Value the response carried, or the empty string when absent.
        value: String,
    },
    /// A ranged download succeeded with a status that cannot carry a range.
    #[error("Dropbox answered a ranged download with HTTP {status}")]
    UnexpectedRangeStatus {
        /// Status the response carried.
        status: u16,
        /// Offset the request asked to resume from.
        requested: u64,
    },
    /// Dropbox cannot serve the requested range.
    ///
    /// Staging decides whether to verify or restart, so this never reaches the
    /// daemon's classification as a plain retry.
    #[error("Dropbox cannot serve the requested range")]
    RangeUnsatisfiable {
        /// Current length Dropbox reported, when it reported one.
        length: Option<u64>,
    },
    /// A refresh could not be turned into a usable access token.
    #[error("Dropbox refused to issue an access token")]
    RefreshUnusable {
        /// Original SDK error.
        #[source]
        source: Box<SdkError<NoError>>,
    },
    /// The refresh token is gone.
    #[error(transparent)]
    RefreshRejected(RejectCause),
    /// A rotated refresh token could not be stored.
    #[error("the rotated Dropbox refresh token could not be stored")]
    RotationNotStored {
        /// Original credential-store error.
        #[source]
        source: AuthError,
    },
    /// The SDK produced an authorization this record cannot hold.
    #[error("Dropbox authorization cannot be stored as a refresh token record")]
    RotationUnsupported,
    /// The failure of one refresh attempt, shared by every caller of it.
    ///
    /// Every caller retains and classifies the same underlying typed cause.
    #[error("{0}")]
    SharedRefresh(#[source] Arc<TransportError>),
}

impl TransportError {
    /// What the caller must do about this failure.
    #[must_use]
    pub fn outcome(&self) -> Outcome {
        match self {
            Self::UnsupportedOrigin { .. }
            | Self::UnsupportedRoute { .. }
            | Self::HeaderName { .. }
            | Self::HeaderValue { .. }
            | Self::ArgumentNotJson { .. }
            | Self::PathRootArgument { .. }
            | Self::ZeroRange
            | Self::UnsupportedRange { .. }
            | Self::LongPollArgument { .. }
            | Self::LongPollOverflow { .. }
            | Self::ResponseHeader { .. }
            | Self::RotationUnsupported => Outcome::Invariant,
            Self::Unreachable { .. }
            | Self::ErrorBody { .. }
            | Self::RangeIgnored { .. }
            | Self::RangeMismatch { .. }
            | Self::UnexpectedRangeStatus { .. }
            | Self::RangeUnsatisfiable { .. } => Outcome::Retry { delay: None },
            Self::RefreshUnusable { source } => sdk_outcome(source),
            Self::RateLimitFailure { delay, .. }
            | Self::ServerBusy { delay, .. }
            | Self::DelayedBodyFailure { delay, .. } => Outcome::Retry {
                delay: Some(*delay),
            },
            Self::PathRoot { .. } | Self::PathRootUnreadable { .. } | Self::RefreshRejected(_) => {
                Outcome::UserAction
            }
            Self::RotationNotStored { .. } => Outcome::Environmental,
            Self::SharedRefresh(cause) => cause.outcome(),
        }
    }
}

/// Dropbox's implicit envelope around a documented error value.
#[derive(Debug, Deserialize)]
struct Envelope<T> {
    error: T,
}

/// The rate-limit body, whose `retry_after` some routes omit.
#[derive(Debug, Deserialize)]
struct RateLimited {
    reason: RateLimitReason,
    #[serde(default)]
    retry_after: u64,
}

/// The part of a long-poll argument that decides the deadline.
#[derive(Debug, Deserialize)]
struct LongPollArgument {
    timeout: Option<u64>,
}

impl fmt::Debug for Transport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Transport")
            .field("bases", &self.bases)
            .field("deadlines", &self.deadlines)
            .finish_non_exhaustive()
    }
}

/// Read a bounded error body, so a hostile response cannot exhaust memory.
fn bounded_body(body: ureq::Body) -> Result<String, TransportError> {
    body.into_with_config()
        .limit(ERROR_BODY_LIMIT)
        .read_to_string()
        .map_err(|source| TransportError::ErrorBody { source })
}

/// One response header this transport must be able to read as text.
fn text_header(headers: &HeaderMap, name: &str) -> Result<Option<String>, TransportError> {
    match headers.get(name) {
        None => Ok(None),
        Some(value) => match value.to_str() {
            Ok(text) => Ok(Some(String::from(text))),
            Err(_) => Err(TransportError::ResponseHeader {
                name: String::from(name),
            }),
        },
    }
}

/// Every value of one response header, all of which must be text.
fn text_headers(headers: &HeaderMap, name: &str) -> Result<Vec<String>, TransportError> {
    let mut values = Vec::new();
    for value in headers.get_all(name) {
        match value.to_str() {
            Ok(text) => values.push(String::from(text)),
            Err(_) => {
                return Err(TransportError::ResponseHeader {
                    name: String::from(name),
                });
            }
        }
    }
    Ok(values)
}

/// One response header whose absence and unreadability mean the same thing.
fn readable<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name).and_then(|value| value.to_str().ok())
}

/// One response header documented to carry a byte count.
fn number_header(headers: &HeaderMap, name: &str) -> Option<u64> {
    readable(headers, name).and_then(|value| value.trim().parse().ok())
}

/// Hand a response body to the SDK without draining or buffering it.
fn stream(body: ureq::Body) -> Box<dyn Read + Send> {
    Box::new(body.into_with_config().limit(u64::MAX).reader())
}
#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::error::Error;
    use std::io::{self, Read as _, Write as _};
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc;
    use std::sync::{Arc, Barrier, Mutex, OnceLock, Weak};
    use std::thread::{self, JoinHandle};
    use std::time::{Duration, UNIX_EPOCH};

    use dropbox_sdk::client_trait::{HttpClient as _, HttpRequest as _, HttpRequestResultRaw};
    use dropbox_sdk::types::auth::RateLimitReason;
    use dropbox_sdk::types::common::{PathRoot, PathRootError, RootInfo};
    use dropbox_sdk::{Error as SdkError, NoError};
    use serde_json::json;

    use crate::auth::{AuthError, RefreshToken};
    use crate::journal::DropboxBinding;

    use super::{
        Bases, Deadlines, MAX_RETRY_AFTER, Outcome, Phases, RejectCause, RequestKind,
        RotationStore, TokenState, Transport, TransportError, agent, escape_argument, fixdate,
        retry_after,
    };

    const APP_KEY: &str = "test-app-key";
    const NAMESPACE: &str = "9001";

    // ---------------------------------------------------------------- endpoints

    #[test]
    fn every_documented_origin_maps_to_its_route_kind() -> Result<(), Box<dyn Error>> {
        let bases = Bases::new(
            "https://api.example/2/",
            "https://content.example/2/",
            "https://notify.example/2/",
            "https://oauth.example/",
        );

        for (url, kind, rebased) in [
            (
                "https://api.dropboxapi.com/2/files/list_folder",
                RequestKind::Rpc,
                "https://api.example/2/files/list_folder",
            ),
            (
                "https://api.dropboxapi.com/2/users/get_current_account",
                RequestKind::Rpc,
                "https://api.example/2/users/get_current_account",
            ),
            (
                "https://content.dropboxapi.com/2/files/download",
                RequestKind::Download,
                "https://content.example/2/files/download",
            ),
            (
                "https://content.dropboxapi.com/2/files/upload",
                RequestKind::Upload,
                "https://content.example/2/files/upload",
            ),
            (
                "https://content.dropboxapi.com/2/files/upload_session/append_v2",
                RequestKind::Upload,
                "https://content.example/2/files/upload_session/append_v2",
            ),
            (
                "https://content.dropboxapi.com/2/files/upload_session/finish",
                RequestKind::Finish,
                "https://content.example/2/files/upload_session/finish",
            ),
            (
                "https://notify.dropboxapi.com/2/files/list_folder/longpoll",
                RequestKind::LongPoll,
                "https://notify.example/2/files/list_folder/longpoll",
            ),
            (
                "https://api.dropboxapi.com/oauth2/token",
                RequestKind::OAuth,
                "https://oauth.example/oauth2/token",
            ),
        ] {
            let target = bases.resolve(url).map_err(|failure| {
                io::Error::other(format!("documented URL {url} did not resolve: {failure}"))
            })?;
            assert_eq!(target.kind, kind, "wrong kind for {url}");
            assert_eq!(target.url, rebased, "wrong rebasing for {url}");
        }
        Ok(())
    }

    #[test]
    fn unmapped_origins_and_routes_never_resolve() {
        let bases = Bases::production();

        for url in [
            "http://api.dropboxapi.com/2/files/list_folder",
            "https://api.dropboxapi.com.example/2/files/list_folder",
            "https://api.dropboxapi.com:8443/2/files/list_folder",
            "https://evil.example/2/files/list_folder",
            "https://content.dropboxapi.com/files/download",
        ] {
            assert!(
                matches!(
                    bases.resolve(url),
                    Err(TransportError::UnsupportedOrigin { .. })
                ),
                "resolved unsupported origin {url}"
            );
        }

        for url in [
            "https://api.dropboxapi.com/2/files/download",
            "https://content.dropboxapi.com/2/files/list_folder",
            "https://api.dropboxapi.com/2/files/permanently_delete",
            "https://api.dropboxapi.com/oauth2/authorize",
        ] {
            assert!(
                matches!(
                    bases.resolve(url),
                    Err(TransportError::UnsupportedRoute { .. })
                ),
                "resolved unsupported route {url}"
            );
        }
    }

    #[test]
    fn an_unknown_url_fails_when_the_request_is_executed() -> Result<(), Box<dyn Error>> {
        let transport = transport(Bases::production(), Deadlines::production())?;
        let request = transport.new_request("https://evil.example/2/files/download");

        let failure = require_failure(transport.execute(request, &[]))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::UnsupportedOrigin { url })
                if url == "https://evil.example/2/files/download"
        ));
        Ok(())
    }

    // ------------------------------------------------------------------ headers

    #[test]
    fn repeated_headers_replace_case_insensitively() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(200, json!({"ok": true}))])?;
        let transport = transport(fake.bases(), Deadlines::production())?;

        let request = transport
            .new_request("https://content.dropboxapi.com/2/files/download")
            .set_header("Range", "bytes=5-")
            .set_header("Dropbox-API-Arg", "{\"a\":1}")
            .set_header("range", "bytes=9-")
            .set_header("DROPBOX-API-ARG", "{\"b\":2}");
        let _ = transport.execute(request, &[]);

        let recorded = fake.finish()?;
        let first = recorded.first().ok_or("fake server saw no request")?;
        assert_eq!(first.all("range"), vec![String::from("bytes=9-")]);
        assert_eq!(
            first.all("dropbox-api-arg"),
            vec![String::from("{\"b\":2}")]
        );
        assert_eq!(first.all("accept-encoding"), vec![String::from("identity")]);
        Ok(())
    }

    #[test]
    fn invalid_headers_are_typed_and_never_render_their_value() -> Result<(), Box<dyn Error>> {
        let transport = transport(Bases::production(), Deadlines::production())?;

        let named = transport
            .new_request("https://api.dropboxapi.com/2/files/list_folder")
            .set_header("Bad Header", "value");
        let failure = require_failure(transport.execute(named, &[]))?;
        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::HeaderName { name, .. }) if name == "Bad Header"
        ));

        let valued = transport
            .new_request("https://api.dropboxapi.com/2/files/list_folder")
            .set_header("Authorization", "Bearer secret\ntoken");
        let failure = require_failure(transport.execute(valued, &[]))?;
        let rendered = format!("{failure}");
        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::HeaderValue { name, .. }) if name == "Authorization"
        ));
        assert!(
            !rendered.contains("secret"),
            "header diagnostics leaked the value: {rendered}"
        );
        Ok(())
    }

    // ---------------------------------------------------------- Dropbox-API-Arg

    #[test]
    fn arguments_are_escaped_per_unicode_scalar_value() -> Result<(), Box<dyn Error>> {
        let value = json!({
            "path": "/Caf\u{e9}/\u{96ea}/\u{1d11e}/\u{7f}",
            "quote\"and\\slash": "line\nfeed\ttab",
        });
        let source = serde_json::to_string(&value)?;

        let encoded = escape_argument(&source)?;

        assert!(
            encoded.bytes().all(|byte| (0x20..0x7f).contains(&byte)),
            "escaped argument carried a non-printable byte: {encoded:?}"
        );
        assert!(encoded.contains(r"\u00e9"), "missing e-acute: {encoded}");
        assert!(encoded.contains(r"\u96ea"), "missing snow: {encoded}");
        assert!(
            encoded.contains(r"\ud834\udd1e"),
            "astral scalar was not a surrogate pair: {encoded}"
        );
        assert!(encoded.contains(r"\u007f"), "missing delete: {encoded}");
        assert!(
            encoded.contains(r#"\""#) && encoded.contains(r"\\"),
            "existing JSON escapes were not kept: {encoded}"
        );
        assert!(
            !encoded.contains(r"\u005c") && !encoded.contains(r"\u0022"),
            "an existing escape was escaped again: {encoded}"
        );
        assert_eq!(serde_json::from_str::<serde_json::Value>(&encoded)?, value);
        Ok(())
    }

    #[test]
    fn a_non_json_argument_is_refused() {
        assert!(matches!(
            escape_argument("not json"),
            Err(TransportError::ArgumentNotJson { .. })
        ));
    }

    #[test]
    fn the_argument_header_reaches_dropbox_escaped() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(200, json!({"ok": true}))])?;
        let transport = transport(fake.bases(), Deadlines::production())?;
        let argument = serde_json::to_string(&json!({"path": "/\u{96ea}.txt"}))?;

        let request = transport
            .new_request("https://api.dropboxapi.com/2/files/get_metadata")
            .set_header("Dropbox-API-Arg", &argument);
        let _ = transport.execute(request, b"{}");

        let recorded = fake.finish()?;
        let first = recorded.first().ok_or("fake server saw no request")?;
        assert_eq!(
            first.all("dropbox-api-arg"),
            vec![String::from(r#"{"path":"/\u96ea.txt"}"#)]
        );
        Ok(())
    }

    // ----------------------------------------------------------------- deadlines

    #[test]
    fn every_deadline_row_is_exactly_what_the_table_documents() -> Result<(), Box<dyn Error>> {
        let deadlines = Deadlines::production();
        let long_poll = serde_json::to_vec(&json!({"cursor": "c", "timeout": 300}))?;

        assert_eq!(
            deadlines.phases(RequestKind::Rpc, b"{}")?,
            Phases {
                global: Some(Duration::from_secs(60)),
                ..Phases::default()
            }
        );
        assert_eq!(
            deadlines.phases(RequestKind::OAuth, b"grant_type=refresh_token")?,
            Phases {
                global: Some(Duration::from_secs(60)),
                ..Phases::default()
            }
        );
        assert_eq!(
            deadlines.phases(RequestKind::Download, &[])?,
            Phases {
                send_request: Some(Duration::from_secs(60)),
                recv_body: Some(Duration::from_secs(60)),
                ..Phases::default()
            }
        );
        assert_eq!(
            deadlines.phases(RequestKind::Upload, b"payload")?,
            Phases {
                send_body: Some(Duration::from_secs(60)),
                recv_response: Some(Duration::from_secs(60)),
                ..Phases::default()
            }
        );
        assert_eq!(
            deadlines.phases(RequestKind::Finish, &[])?,
            Phases {
                recv_response: Some(Duration::from_secs(60 * 60)),
                ..Phases::default()
            }
        );
        assert_eq!(
            deadlines.phases(RequestKind::LongPoll, &long_poll)?,
            Phases {
                global: Some(Duration::from_secs(300 + 90 + 105)),
                ..Phases::default()
            }
        );
        assert_eq!(
            deadlines.phases(RequestKind::LongPoll, br#"{"cursor":"c"}"#)?,
            Phases {
                global: Some(Duration::from_secs(30 + 90 + 105)),
                ..Phases::default()
            }
        );
        assert!(matches!(
            deadlines.phases(RequestKind::LongPoll, b"not json"),
            Err(TransportError::LongPollArgument { .. })
        ));
        assert!(matches!(
            deadlines.phases(
                RequestKind::LongPoll,
                br#"{"timeout":18446744073709551615}"#
            ),
            Err(TransportError::LongPollOverflow { .. })
        ));
        assert!(
            deadlines.upload_response <= deadlines.body_idle,
            "an upload's response deadline must bind before the body idle deadline"
        );
        Ok(())
    }

    #[test]
    fn a_json_call_stops_at_its_global_deadline() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![
            Reply::json(200, json!({"ok": true})).delay_head(Duration::from_secs(3)),
        ])?;
        let transport = transport(fake.bases(), quick())?;

        let request = transport.new_request("https://api.dropboxapi.com/2/files/list_folder");
        let failure = require_failure(transport.execute(request, b"{}"))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::Unreachable { .. })
        ));
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn a_download_body_stops_only_when_it_stops_moving() -> Result<(), Box<dyn Error>> {
        let stalled = Fake::start(vec![
            Reply::bytes(200, vec![7; 64])
                .in_chunks(2, Duration::ZERO)
                .send_bytes(32)
                .hold(Duration::from_secs(3)),
        ])?;
        let idle = transport(stalled.bases(), quick())?;
        let request = idle.new_request("https://content.dropboxapi.com/2/files/download");
        let mut raw = idle
            .execute(request, &[])
            .map_err(|failure| io::Error::other(format!("download refused: {failure}")))?;
        let mut received = Vec::new();
        let outcome = raw.body.read_to_end(&mut received);
        assert!(
            outcome.is_err(),
            "an idle download body was read to completion"
        );
        drop(stalled.finish());

        let dribbling = Fake::start(vec![
            Reply::bytes(200, vec![7; 64]).in_chunks(4, Duration::from_millis(400)),
        ])?;
        let moving = transport(dribbling.bases(), quick())?;
        let request = moving.new_request("https://content.dropboxapi.com/2/files/download");
        let mut raw = moving
            .execute(request, &[])
            .map_err(|failure| io::Error::other(format!("download refused: {failure}")))?;
        let mut received = Vec::new();
        raw.body.read_to_end(&mut received)?;
        assert_eq!(received.len(), 64);
        drop(dribbling.finish());
        Ok(())
    }

    #[test]
    fn an_upload_stops_when_its_body_stops_moving() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![
            Reply::json(200, json!({"ok": true}))
                .without_reading_body()
                .hold(Duration::from_secs(5)),
        ])?;
        let transport = transport(fake.bases(), quick())?;

        let request = transport.new_request("https://content.dropboxapi.com/2/files/upload");
        let failure = require_failure(transport.execute(request, &vec![9_u8; 16 * 1024 * 1024]))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::Unreachable { .. })
        ));
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn an_upload_stops_waiting_for_its_commit() -> Result<(), Box<dyn Error>> {
        let deadlines = Deadlines {
            body_idle: Duration::from_secs(5),
            upload_response: Duration::from_secs(1),
            ..quick()
        };
        let fake = Fake::start(vec![
            Reply::json(200, json!({"ok": true})).delay_head(Duration::from_secs(3)),
        ])?;
        let transport = transport(fake.bases(), deadlines)?;

        let request = transport.new_request("https://content.dropboxapi.com/2/files/upload");
        let failure = require_failure(transport.execute(request, b"payload"))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::Unreachable { .. })
        ));
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn a_sent_upload_body_still_binds_the_commit_deadline() -> Result<(), Box<dyn Error>> {
        let deadlines = Deadlines {
            body_idle: Duration::from_secs(1),
            upload_response: Duration::from_secs(30),
            ..quick()
        };
        let fake = Fake::start(vec![
            Reply::json(200, json!({"ok": true})).delay_head(Duration::from_secs(3)),
        ])?;
        let transport = transport(fake.bases(), deadlines)?;

        let request = transport.new_request("https://content.dropboxapi.com/2/files/upload");
        let failure = require_failure(transport.execute(request, b"payload"))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::Unreachable { .. })
        ));
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn a_session_finish_waits_past_every_upload_deadline() -> Result<(), Box<dyn Error>> {
        let deadlines = Deadlines {
            body_idle: Duration::from_secs(1),
            upload_response: Duration::from_secs(1),
            session_finish: Duration::from_secs(30),
            ..quick()
        };
        let fake = Fake::start(vec![
            Reply::json(200, json!({"ok": true})).delay_head(Duration::from_secs(3)),
        ])?;
        let transport = transport(fake.bases(), deadlines)?;

        let request =
            transport.new_request("https://content.dropboxapi.com/2/files/upload_session/finish");
        let raw = transport
            .execute(request, &[])
            .map_err(|failure| io::Error::other(format!("finish refused: {failure}")))?;

        assert_eq!(raw.status, 200);
        assert_eq!(
            Deadlines::production().session_finish,
            Duration::from_secs(60 * 60)
        );
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn a_long_poll_deadline_follows_the_timeout_it_asks_for() -> Result<(), Box<dyn Error>> {
        let deadlines = Deadlines {
            long_poll_slack: Duration::ZERO,
            long_poll_grace: Duration::from_secs(1),
            ..quick()
        };
        let fake = Fake::start(vec![
            Reply::json(200, json!({"changes": false})).delay_head(Duration::from_secs(3)),
        ])?;
        let impatient = transport(fake.bases(), deadlines)?;

        let request =
            impatient.new_request("https://notify.dropboxapi.com/2/files/list_folder/longpoll");
        let failure =
            require_failure(impatient.execute(request, br#"{"cursor":"c","timeout":0}"#))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::Unreachable { .. })
        ));
        drop(fake.finish());

        let patient = Fake::start(vec![
            Reply::json(200, json!({"changes": false})).delay_head(Duration::from_secs(1)),
        ])?;
        let patient_transport = transport(
            patient.bases(),
            Deadlines {
                long_poll_slack: Duration::ZERO,
                long_poll_grace: Duration::from_secs(30),
                ..quick()
            },
        )?;
        let request = patient_transport
            .new_request("https://notify.dropboxapi.com/2/files/list_folder/longpoll");
        let raw = patient_transport
            .execute(request, br#"{"cursor":"c","timeout":0}"#)
            .map_err(|failure| io::Error::other(format!("long poll refused: {failure}")))?;
        assert_eq!(raw.status, 200);
        drop(patient.finish());
        Ok(())
    }

    #[test]
    fn agents_hand_every_status_to_the_parser_without_following_redirects() {
        let agent = agent(Duration::from_secs(5));
        let config = agent.config();

        assert!(!config.http_status_as_error());
        assert_eq!(config.max_redirects(), 0);
        assert_eq!(config.timeouts().connect, Some(Duration::from_secs(5)));
        assert_eq!(config.max_idle_connections_per_host(), 4);
    }

    // ----------------------------------------------------------------- statuses

    #[test]
    fn documented_statuses_reach_the_parser_unchanged() -> Result<(), Box<dyn Error>> {
        for (status, body) in [
            (400, json!({"error_summary": "bad_request/"})),
            (401, json!({"error": {".tag": "expired_access_token"}})),
            (403, json!({"error": {".tag": "invalid_account_type"}})),
            (
                409,
                json!({"error": {".tag": "path", "path": {".tag": "not_found"}}}),
            ),
            (500, json!({"error_summary": "internal"})),
        ] {
            let fake = Fake::start(vec![Reply::json(status, body.clone())])?;
            let transport = transport(fake.bases(), Deadlines::production())?;
            let request = transport.new_request("https://api.dropboxapi.com/2/files/get_metadata");

            let mut raw = transport.execute(request, b"{}").map_err(|failure| {
                io::Error::other(format!("HTTP {status} was not passed through: {failure}"))
            })?;

            assert_eq!(raw.status, status);
            let mut received = String::new();
            raw.body.read_to_string(&mut received)?;
            assert_eq!(serde_json::from_str::<serde_json::Value>(&received)?, body);
            drop(fake.finish());
        }
        Ok(())
    }

    #[test]
    fn result_and_length_headers_are_copied() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![
            Reply::bytes(200, vec![1, 2, 3, 4]).header("Dropbox-API-Result", r#"{"name":"a.txt"}"#),
        ])?;
        let transport = transport(fake.bases(), Deadlines::production())?;

        let request = transport.new_request("https://content.dropboxapi.com/2/files/download");
        let raw = transport
            .execute(request, &[])
            .map_err(|failure| io::Error::other(format!("download refused: {failure}")))?;

        assert_eq!(raw.result_header.as_deref(), Some(r#"{"name":"a.txt"}"#));
        assert_eq!(raw.content_length, Some(4));
        drop(fake.finish());
        Ok(())
    }

    // -------------------------------------------------------------- rate limits

    #[test]
    fn rate_limits_take_the_greater_delay_and_cap_it() -> Result<(), Box<dyn Error>> {
        let body = json!({
            "error_summary": "too_many_requests/",
            "error": {"reason": {".tag": "too_many_requests"}, "retry_after": 5},
        });

        assert_eq!(
            rate_limit_delay(Reply::json(429, body.clone()))?,
            Duration::from_secs(5)
        );
        assert_eq!(
            rate_limit_delay(Reply::json(429, body.clone()).header("Retry-After", "30"))?,
            Duration::from_secs(30)
        );
        assert_eq!(
            rate_limit_delay(Reply::json(429, body).header("Retry-After", "2"))?,
            Duration::from_secs(5)
        );

        let huge = json!({
            "error_summary": "too_many_requests/",
            "error": {"reason": {".tag": "too_many_requests"}, "retry_after": 86_400},
        });
        assert_eq!(
            rate_limit_delay(Reply::json(429, huge).header("Retry-After", "99999"))?,
            MAX_RETRY_AFTER
        );
        Ok(())
    }

    #[test]
    fn a_rate_limit_keeps_its_reason_and_body() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(
            429,
            json!({
                "error_summary": "too_many_write_operations/",
                "error": {"reason": {".tag": "too_many_write_operations"}},
            }),
        )])?;
        let transport = transport(fake.bases(), Deadlines::production())?;
        let request = transport.new_request("https://content.dropboxapi.com/2/files/upload");

        let failure = require_failure(transport.execute(request, b"payload"))?;

        match local_failure(&failure) {
            Some(TransportError::RateLimitFailure {
                reason,
                delay,
                body,
            }) => {
                assert_eq!(
                    reason.as_ref(),
                    Some(&RateLimitReason::TooManyWriteOperations)
                );
                assert_eq!(*delay, Duration::ZERO);
                assert!(body.contains("too_many_write_operations"));
            }
            other => return Err(io::Error::other(format!("unexpected outcome {other:?}")).into()),
        }
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn an_unreadable_rate_limit_body_still_honors_the_header() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![
            Reply::bytes(429, b"<html>slow down</html>".to_vec()).header("Retry-After", "12"),
        ])?;
        let transport = transport(fake.bases(), Deadlines::production())?;
        let request = transport.new_request("https://api.dropboxapi.com/2/files/list_folder");

        let failure = require_failure(transport.execute(request, b"{}"))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::RateLimitFailure { reason: None, delay, .. })
                if *delay == Duration::from_secs(12)
        ));
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn a_server_failure_with_a_delay_becomes_a_typed_wait() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![
            Reply::json(503, json!({"error_summary": "unavailable"})).header("Retry-After", "7"),
        ])?;
        let transport = transport(fake.bases(), Deadlines::production())?;
        let request = transport.new_request("https://api.dropboxapi.com/2/files/list_folder");

        let failure = require_failure(transport.execute(request, b"{}"))?;

        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::ServerBusy { delay, .. }) if *delay == Duration::from_secs(7)
        ));
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn retry_after_reads_delta_seconds_and_http_dates() -> Result<(), Box<dyn Error>> {
        let now = UNIX_EPOCH + Duration::from_secs(1_000);

        assert_eq!(retry_after(None, now), None);
        assert_eq!(
            retry_after(Some("  23 "), now),
            Some(Duration::from_secs(23))
        );
        assert_eq!(retry_after(Some("soon"), now), None);
        assert_eq!(retry_after(Some("-5"), now), None);

        let stamp =
            fixdate("Wed, 21 Oct 2015 07:28:00 GMT").ok_or("documented example did not parse")?;
        assert_eq!(stamp.duration_since(UNIX_EPOCH)?.as_secs(), 1_445_412_480);
        assert_eq!(
            retry_after(
                Some("Wed, 21 Oct 2015 07:28:00 GMT"),
                stamp - Duration::from_secs(90)
            ),
            Some(Duration::from_secs(90))
        );
        assert_eq!(
            retry_after(Some("Wed, 21 Oct 2015 07:28:00 GMT"), stamp),
            Some(Duration::ZERO)
        );

        for malformed in [
            "",
            "Wed, 21 Oct 2015 07:28:00 UTC",
            "Xyz, 21 Oct 2015 07:28:00 GMT",
            "Sun, 29 Feb 2015 07:28:00 GMT",
            "Wed, 21 Oct 1969 07:28:00 GMT",
            "Wed, 21 Oct 2015 24:28:00 GMT",
            "Sun Nov  6 08:49:37 1994",
        ] {
            assert_eq!(fixdate(malformed), None, "accepted {malformed:?}");
        }
        Ok(())
    }

    // ---------------------------------------------------------------- path root

    #[test]
    fn a_refused_path_root_is_typed_from_the_header_or_the_body() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![
            Reply::json(422, json!({"error_summary": "path_root"}))
                .header("Dropbox-API-Path-Root-Error", r#"{".tag":"no_permission"}"#),
        ])?;
        let failure = path_root_failure(&fake)?;
        assert!(matches!(
            failure,
            TransportError::PathRoot {
                source: PathRootError::NoPermission
            }
        ));

        let fake = Fake::start(vec![Reply::json(
            422,
            json!({
                "error_summary": "path_root",
                "error": {
                    ".tag": "invalid_root",
                    "invalid_root": {
                        ".tag": "user",
                        "root_namespace_id": "1234",
                        "home_namespace_id": "5678",
                    },
                },
            }),
        )])?;
        let failure = path_root_failure(&fake)?;
        assert!(matches!(
            failure,
            TransportError::PathRoot {
                source: PathRootError::InvalidRoot(RootInfo::User(_))
            }
        ));

        let fake = Fake::start(vec![
            Reply::json(422, json!({"error_summary": "path_root"})).header(
                "Dropbox-API-Path-Root-Error",
                r#"{".tag":"a_future_reason"}"#,
            ),
        ])?;
        let failure = path_root_failure(&fake)?;
        assert!(matches!(
            failure,
            TransportError::PathRoot {
                source: PathRootError::Other
            }
        ));
        assert_eq!(failure.outcome(), Outcome::UserAction);

        let fake = Fake::start(vec![Reply::bytes(422, b"unprocessable".to_vec())])?;
        let failure = path_root_failure(&fake)?;
        assert!(matches!(failure, TransportError::PathRootUnreadable { .. }));
        assert_eq!(failure.outcome(), Outcome::UserAction);
        Ok(())
    }

    // ------------------------------------------------------------------- ranges

    #[test]
    fn a_partial_download_must_describe_the_range_that_was_asked_for() -> Result<(), Box<dyn Error>>
    {
        let good = Reply::bytes(206, vec![3; 100])
            .header("Content-Range", "bytes 100-199/500")
            .header("Dropbox-API-Result", "{}");
        let raw = ranged(good, Some("bytes=100-"))?.map_err(|failure| {
            io::Error::other(format!(
                "a documented partial response was refused: {failure}"
            ))
        })?;
        assert_eq!(raw.status, 206);

        let open_ended = Reply::bytes(206, vec![3; 100])
            .header("Content-Range", "bytes 100-199/*")
            .header("Dropbox-API-Result", "{}");
        assert!(ranged(open_ended, Some("bytes=100-"))?.is_ok());
        Ok(())
    }

    #[test]
    fn every_documented_range_failure_is_reported_before_any_byte() -> Result<(), Box<dyn Error>> {
        let ignored = ranged(Reply::bytes(200, vec![3; 500]), Some("bytes=100-"))?;
        assert!(matches!(
            local_failure(&require_failure(ignored)?),
            Some(TransportError::RangeIgnored { requested: 100 })
        ));

        // Every fixture below is consistent except for the one rule it breaks,
        // so no rule can be dropped without a failure here.
        for content_range in [
            "bytes 200-299/500",
            "bytes 101-199/500",
            "bytes 100-199/150",
            "bytes 100-199/199",
            "bytes 100-99/500",
            "bytes 100-199/abc",
            "bytes +100-199/500",
            "bytes 100-+199/500",
            "bytes 100-199/+500",
            "bytes 100-199/18446744073709551616",
            "bytes 100-199",
            "100-199/500",
            "items 100-199/500",
        ] {
            let reply = Reply::bytes(206, vec![3; 100]).header("Content-Range", content_range);
            let outcome = ranged(reply, Some("bytes=100-"))?;
            assert!(
                matches!(
                    local_failure(&require_failure(outcome)?),
                    Some(TransportError::RangeMismatch { requested: 100, .. })
                ),
                "accepted Content-Range {content_range}"
            );
        }

        let absent = ranged(Reply::bytes(206, vec![3; 100]), Some("bytes=100-"))?;
        assert!(matches!(
            local_failure(&require_failure(absent)?),
            Some(TransportError::RangeMismatch { requested: 100, .. })
        ));

        let doubled = Reply::bytes(206, vec![3; 100])
            .header("Content-Range", "bytes 100-199/500")
            .header("Content-Range", "bytes 100-199/500");
        assert!(matches!(
            local_failure(&require_failure(ranged(doubled, Some("bytes=100-"))?)?),
            Some(TransportError::RangeMismatch { requested: 100, .. })
        ));

        let short = Reply::bytes(206, vec![3; 99]).header("Content-Range", "bytes 100-199/500");
        assert!(matches!(
            local_failure(&require_failure(ranged(short, Some("bytes=100-"))?)?),
            Some(TransportError::RangeMismatch { requested: 100, .. })
        ));

        let other = ranged(Reply::empty(204), Some("bytes=100-"))?;
        assert!(matches!(
            local_failure(&require_failure(other)?),
            Some(TransportError::UnexpectedRangeStatus {
                status: 204,
                requested: 100
            })
        ));
        Ok(())
    }

    #[test]
    fn an_unsatisfiable_range_reports_the_length_dropbox_knows() -> Result<(), Box<dyn Error>> {
        let known = Reply::empty(416).header("Content-Range", "bytes */500");
        assert!(matches!(
            local_failure(&require_failure(ranged(known, Some("bytes=100-"))?)?),
            Some(TransportError::RangeUnsatisfiable { length: Some(500) })
        ));

        let unknown = Reply::empty(416);
        assert!(matches!(
            local_failure(&require_failure(ranged(unknown, Some("bytes=100-"))?)?),
            Some(TransportError::RangeUnsatisfiable { length: None })
        ));
        Ok(())
    }

    #[test]
    fn unranged_and_failed_downloads_skip_the_range_rules() -> Result<(), Box<dyn Error>> {
        let whole = ranged(Reply::bytes(200, vec![3; 500]), None)?;
        assert_eq!(
            whole
                .map_err(|failure| io::Error::other(format!("plain download refused: {failure}")))?
                .status,
            200
        );

        let conflict = Reply::json(409, json!({"error": {".tag": "path"}}));
        let outcome = ranged(conflict, Some("bytes=100-"))?;
        assert_eq!(
            outcome
                .map_err(|failure| io::Error::other(format!("409 was not passed: {failure}")))?
                .status,
            409
        );
        Ok(())
    }

    #[test]
    fn a_resume_never_asks_for_a_zero_offset_range() -> Result<(), Box<dyn Error>> {
        let zero = ranged(Reply::bytes(206, vec![3; 1]), Some("bytes=0-"))?;
        assert!(matches!(
            local_failure(&require_failure(zero)?),
            Some(TransportError::ZeroRange)
        ));

        let suffix = ranged(Reply::bytes(206, vec![3; 1]), Some("bytes=-100"))?;
        assert!(matches!(
            local_failure(&require_failure(suffix)?),
            Some(TransportError::UnsupportedRange { .. })
        ));
        Ok(())
    }

    // ------------------------------------------------------------------- tokens

    #[test]
    fn concurrent_callers_share_one_refresh_per_generation() -> Result<(), Box<dyn Error>> {
        const CALLERS: usize = 6;

        let (reply, gate) = Reply::json(
            200,
            json!({"access_token": "access-2", "expires_in": 14_400}),
        )
        .gated();
        let fake = Fake::start(vec![reply])?;
        let store = Arc::new(RecordingStore::new(vec![Ok(())]));
        let transport = Arc::new(with_tokens(
            fake.bases(),
            Deadlines::production(),
            Arc::clone(&store),
        )?);

        assert_eq!(transport.token(), None);

        let entered = Arc::new(Barrier::new(CALLERS + 1));
        let mut callers = Vec::new();
        for _ in 0..CALLERS {
            let transport = Arc::clone(&transport);
            let entered = Arc::clone(&entered);
            callers.push(thread::spawn(move || {
                entered.wait();
                transport.update_token(Arc::new(String::new())).is_ok()
            }));
        }
        entered.wait();
        gate.wait_for_request()?;
        thread::sleep(Duration::from_millis(300));
        gate.release()?;

        for caller in callers {
            let succeeded = caller
                .join()
                .map_err(|_| io::Error::other("refresh caller failed"))?;
            assert!(succeeded, "a shared refresh reported failure");
        }
        assert_eq!(
            transport.token().as_deref().map(String::as_str),
            Some("access-2")
        );
        assert_eq!(fake.finish()?.len(), 1, "more than one refresh was issued");

        assert!(matches!(
            transport.update_token(Arc::new(String::from("access-1"))),
            Ok(true)
        ));
        Ok(())
    }

    #[test]
    fn one_transient_oauth_failure_is_shared_by_its_cohort() -> Result<(), Box<dyn Error>> {
        const CALLERS: usize = 4;

        let (reply, gate) = Reply::json(503, json!({"error_summary": "unavailable"}))
            .header("Retry-After", "9")
            .gated();
        let fake = Fake::start(vec![reply])?;
        let store = Arc::new(RecordingStore::new(Vec::new()));
        let transport = Arc::new(with_tokens(
            fake.bases(),
            Deadlines::production(),
            Arc::clone(&store),
        )?);

        let entered = Arc::new(Barrier::new(CALLERS + 1));
        let mut callers = Vec::new();
        for _ in 0..CALLERS {
            let transport = Arc::clone(&transport);
            let entered = Arc::clone(&entered);
            callers.push(thread::spawn(move || {
                entered.wait();
                match transport.update_token(Arc::new(String::new())) {
                    Ok(refreshed) => format!("refreshed {refreshed}"),
                    Err(failure) => format!("{failure}"),
                }
            }));
        }
        entered.wait();
        gate.wait_for_request()?;
        thread::sleep(Duration::from_millis(300));
        gate.release()?;

        let mut rendered = Vec::new();
        for caller in callers {
            rendered.push(
                caller
                    .join()
                    .map_err(|_| io::Error::other("refresh caller failed"))?,
            );
        }
        assert_eq!(fake.finish()?.len(), 1, "more than one refresh was issued");
        assert!(
            rendered
                .iter()
                .all(|message| message.contains("retry after")),
            "the shared failure lost its delay: {rendered:?}"
        );
        assert_eq!(transport.token(), None);
        Ok(())
    }

    #[test]
    fn a_rotated_refresh_token_is_stored_before_the_new_token_is_published()
    -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(
            200,
            json!({
                "access_token": "access-2",
                "refresh_token": "refresh-2",
                "expires_in": 14_400,
            }),
        )])?;
        let store = Arc::new(RecordingStore::new(vec![Ok(())]));
        let transport = with_tokens(fake.bases(), Deadlines::production(), Arc::clone(&store))?;

        assert!(matches!(
            transport.update_token(Arc::new(String::new())),
            Ok(true)
        ));

        assert_eq!(store.calls(), vec![String::from("refresh-2")]);
        assert_eq!(
            store.observed(),
            vec![None],
            "the rotated token was published before it was stored"
        );
        assert_eq!(
            transport.token().as_deref().map(String::as_str),
            Some("access-2")
        );
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn an_unstored_rotation_stays_usable_and_is_retried() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(
            200,
            json!({
                "access_token": "access-2",
                "refresh_token": "refresh-2",
                "expires_in": 14_400,
            }),
        )])?;
        let store = Arc::new(RecordingStore::new(vec![
            Err(AuthError::CredentialTooLarge),
            Ok(()),
        ]));
        let transport = with_tokens(fake.bases(), Deadlines::production(), Arc::clone(&store))?;

        let failure = transport
            .update_token(Arc::new(String::new()))
            .err()
            .ok_or("an unstored rotation reported success")?;
        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::RotationNotStored { .. })
        ));
        assert_eq!(
            transport.token().as_deref().map(String::as_str),
            Some("access-2"),
            "an unstored rotation left no usable access token"
        );

        assert!(matches!(
            transport.update_token(Arc::new(String::from("access-2"))),
            Ok(true)
        ));
        assert_eq!(
            store.calls(),
            vec![String::from("refresh-2"), String::from("refresh-2")],
            "the pending rotation was not retried"
        );
        assert_eq!(
            transport.token().as_deref().map(String::as_str),
            Some("access-2")
        );
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn an_unrotated_refresh_never_touches_secret_service() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(
            200,
            json!({"access_token": "access-2", "expires_in": 14_400}),
        )])?;
        let store = Arc::new(RecordingStore::new(Vec::new()));
        let transport = with_tokens(fake.bases(), Deadlines::production(), Arc::clone(&store))?;

        assert!(matches!(
            transport.update_token(Arc::new(String::new())),
            Ok(true)
        ));

        assert!(store.calls().is_empty());
        drop(fake.finish());
        Ok(())
    }

    #[test]
    fn a_refused_grant_becomes_a_rejected_token() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(
            400,
            json!({"error": "invalid_grant", "error_description": "refresh token is invalid"}),
        )])?;
        let store = Arc::new(RecordingStore::new(Vec::new()));
        let transport = with_tokens(fake.bases(), Deadlines::production(), Arc::clone(&store))?;

        let failure = transport
            .update_token(Arc::new(String::new()))
            .err()
            .ok_or("an invalid grant reported success")?;
        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::RefreshRejected(RejectCause::InvalidGrant))
        ));

        let failure = transport
            .update_token(Arc::new(String::new()))
            .err()
            .ok_or("a rejected token reported success")?;
        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::RefreshRejected(RejectCause::InvalidGrant))
        ));
        assert_eq!(fake.finish()?.len(), 1, "a rejected token was retried");
        Ok(())
    }

    #[test]
    fn a_rejected_access_token_is_recorded_for_the_daemon() -> Result<(), Box<dyn Error>> {
        let store = Arc::new(RecordingStore::new(Vec::new()));
        let transport = with_tokens(
            Bases::production(),
            Deadlines::production(),
            Arc::clone(&store),
        )?;

        assert!(!transport.tokens().refreshed());
        transport.tokens().reject(RejectCause::InvalidAccessToken);

        assert_eq!(transport.token(), None);
        let failure = transport
            .update_token(Arc::new(String::new()))
            .err()
            .ok_or("a rejected token reported success")?;
        assert!(matches!(
            local_failure(&failure),
            Some(TransportError::RefreshRejected(
                RejectCause::InvalidAccessToken
            ))
        ));
        Ok(())
    }

    #[test]
    fn a_refresh_carries_no_token_and_no_path_root() -> Result<(), Box<dyn Error>> {
        let fake = Fake::start(vec![Reply::json(
            200,
            json!({"access_token": "access-2", "expires_in": 14_400}),
        )])?;
        let store = Arc::new(RecordingStore::new(Vec::new()));
        let transport = with_tokens(fake.bases(), Deadlines::production(), Arc::clone(&store))?;

        let refresher = transport.refresh_client();
        assert_eq!(refresher.token(), None);
        assert_eq!(refresher.path_root(), None);
        assert!(transport.path_root().is_some());

        assert!(matches!(
            transport.update_token(Arc::new(String::new())),
            Ok(true)
        ));

        let recorded = fake.finish()?;
        let first = recorded.first().ok_or("fake server saw no refresh")?;
        assert_eq!(first.path, "/oauth2/token");
        assert!(first.all("authorization").is_empty());
        assert!(first.all("dropbox-api-path-root").is_empty());
        assert!(
            String::from_utf8_lossy(&first.body).contains("grant_type=refresh_token"),
            "the refresh did not post a refresh grant"
        );
        Ok(())
    }

    #[test]
    fn a_shared_oauth_failure_classifies_as_its_cause() {
        for cause in [
            TransportError::RateLimitFailure {
                reason: Some(RateLimitReason::TooManyRequests),
                delay: Duration::from_secs(9),
                body: String::new(),
            },
            TransportError::ServerBusy {
                delay: Duration::from_secs(9),
                body: String::new(),
            },
            TransportError::RefreshRejected(RejectCause::InvalidGrant),
            TransportError::RefreshRejected(RejectCause::InvalidAccessToken),
            TransportError::RotationNotStored {
                source: AuthError::CredentialTooLarge,
            },
        ] {
            let bare = cause.outcome();
            let rendered = cause.to_string();
            let shared = TransportError::SharedRefresh(Arc::new(cause));

            assert_eq!(shared.outcome(), bare, "a shared failure changed its class");
            assert_eq!(shared.to_string(), rendered);
        }

        let nested = TransportError::SharedRefresh(Arc::new(TransportError::SharedRefresh(
            Arc::new(TransportError::ServerBusy {
                delay: Duration::from_secs(3),
                body: String::new(),
            }),
        )));
        assert_eq!(
            nested.outcome(),
            Outcome::Retry {
                delay: Some(Duration::from_secs(3))
            }
        );
    }

    #[test]
    fn every_failure_class_matches_the_documented_table() {
        assert_eq!(
            TransportError::Unreachable {
                source: ureq::Error::HostNotFound,
            }
            .outcome(),
            Outcome::Retry { delay: None }
        );
        assert_eq!(
            TransportError::PathRoot {
                source: PathRootError::NoPermission,
            }
            .outcome(),
            Outcome::UserAction
        );
        assert_eq!(
            TransportError::RotationNotStored {
                source: AuthError::CredentialTooLarge,
            }
            .outcome(),
            Outcome::Environmental
        );
        assert_eq!(TransportError::ZeroRange.outcome(), Outcome::Invariant);
        assert_eq!(
            TransportError::UnsupportedRoute {
                route: String::from("files/permanently_delete"),
            }
            .outcome(),
            Outcome::Invariant
        );
    }

    #[test]
    fn failed_error_body_reads_preserve_server_delays() -> Result<(), Box<dyn Error>> {
        for status in [429, 503] {
            let fake = Fake::start(vec![
                Reply::bytes(status, vec![b'x'; 100])
                    .header("Retry-After", "17")
                    .send_bytes(2),
            ])?;
            let transport = transport(fake.bases(), Deadlines::production())?;
            let failure = require_failure(transport.execute(
                transport.new_request("https://api.dropboxapi.com/2/files/list_folder"),
                b"{}",
            ))?;
            assert!(matches!(local_failure(&failure),
                Some(TransportError::DelayedBodyFailure { delay, .. }) if *delay == Duration::from_secs(17)));
            fake.finish()?;
        }
        Ok(())
    }

    #[test]
    fn oauth_errors_are_classified_without_rendering_response_secrets() {
        for (failure, outcome) in [
            (
                SdkError::BadRequest(String::from("secret-token")),
                Outcome::Invariant,
            ),
            (
                SdkError::UnexpectedResponse(String::from("secret-token")),
                Outcome::Invariant,
            ),
            (
                SdkError::ServerError(String::from("secret-token")),
                Outcome::Retry { delay: None },
            ),
            (
                SdkError::Authentication(dropbox_sdk::types::auth::AuthError::UserSuspended),
                Outcome::UserAction,
            ),
        ] {
            let failure = super::oauth_failure(failure);
            assert_eq!(failure.outcome(), outcome);
            assert!(!format!("{failure:?}").contains("secret-token"));
            let mut cause: &dyn Error = &failure;
            loop {
                assert!(!format!("{cause}").contains("secret-token"));
                match cause.source() {
                    Some(source) => cause = source,
                    None => break,
                }
            }
        }
    }

    #[test]
    fn refresh_keeps_previous_token_available_and_rejection_is_terminal()
    -> Result<(), Box<dyn Error>> {
        let (second, gate) = Reply::json(200, json!({"access_token":"access-2"})).gated();
        let fake = Fake::start(vec![
            Reply::json(200, json!({"access_token":"access-1"})),
            second,
        ])?;
        let transport = Arc::new(transport(fake.bases(), Deadlines::production())?);
        assert!(transport.update_token(Arc::new(String::new()))?);
        let worker = Arc::clone(&transport);
        let refreshing =
            thread::spawn(move || worker.update_token(Arc::new(String::from("access-1"))));
        gate.wait_for_request()?;
        assert_eq!(
            transport.token().as_deref().map(String::as_str),
            Some("access-1")
        );
        transport.tokens().reject(RejectCause::InvalidAccessToken);
        gate.release()?;
        let result = refreshing
            .join()
            .map_err(|_| io::Error::other("refresh caller failed"))?;
        assert!(result.is_err());
        assert!(transport.token().is_none());
        fake.finish()?;
        Ok(())
    }

    // ------------------------------------------------------------------ helpers

    fn binding() -> DropboxBinding {
        DropboxBinding {
            account_id: String::from("dbid:account"),
            root_namespace_id: String::from(NAMESPACE),
            remote_root: String::from("/Omabox"),
        }
    }

    fn quick() -> Deadlines {
        Deadlines {
            connect: Duration::from_secs(5),
            json_request: Duration::from_secs(1),
            body_idle: Duration::from_secs(1),
            upload_response: Duration::from_secs(1),
            session_finish: Duration::from_secs(1),
            long_poll_slack: Duration::ZERO,
            long_poll_grace: Duration::from_secs(1),
        }
    }

    fn transport(bases: Bases, deadlines: Deadlines) -> Result<Transport, Box<dyn Error>> {
        with_tokens(bases, deadlines, Arc::new(RecordingStore::new(Vec::new())))
    }

    fn with_tokens(
        bases: Bases,
        deadlines: Deadlines,
        store: Arc<RecordingStore>,
    ) -> Result<Transport, Box<dyn Error>> {
        let tokens = Arc::new(TokenState::new(
            APP_KEY,
            &RefreshToken::from_secret("refresh-1"),
            binding(),
            Arc::clone(&store) as Arc<dyn RotationStore>,
        )?);
        store.watch(&tokens);
        Ok(Transport::with_deadlines(
            bases,
            &PathRoot::Root(String::from(NAMESPACE)),
            tokens,
            deadlines,
        )?)
    }

    fn local_failure(failure: &SdkError<NoError>) -> Option<&TransportError> {
        match failure {
            SdkError::HttpClient(boxed) => boxed.downcast_ref::<TransportError>(),
            _ => None,
        }
    }

    fn require_failure(
        outcome: Result<HttpRequestResultRaw, SdkError<NoError>>,
    ) -> Result<SdkError<NoError>, io::Error> {
        match outcome {
            Err(failure) => Ok(failure),
            Ok(raw) => Err(io::Error::other(format!(
                "expected a transport failure, got HTTP {}",
                raw.status
            ))),
        }
    }

    fn ranged(
        reply: Reply,
        range: Option<&str>,
    ) -> Result<Result<HttpRequestResultRaw, SdkError<NoError>>, Box<dyn Error>> {
        let fake = Fake::start(vec![reply])?;
        let transport = transport(fake.bases(), Deadlines::production())?;
        let mut request = transport.new_request("https://content.dropboxapi.com/2/files/download");
        if let Some(value) = range {
            request = request.set_header("Range", value);
        }
        let outcome = transport.execute(request, &[]);
        drop(fake.finish());
        Ok(outcome)
    }

    fn rate_limit_delay(reply: Reply) -> Result<Duration, Box<dyn Error>> {
        let fake = Fake::start(vec![reply])?;
        let transport = transport(fake.bases(), Deadlines::production())?;
        let request = transport.new_request("https://api.dropboxapi.com/2/files/list_folder");
        let failure = require_failure(transport.execute(request, b"{}"))?;
        drop(fake.finish());
        match local_failure(&failure) {
            Some(TransportError::RateLimitFailure { delay, .. }) => Ok(*delay),
            other => Err(io::Error::other(format!("unexpected outcome {other:?}")).into()),
        }
    }

    fn path_root_failure(fake: &Fake) -> Result<TransportError, Box<dyn Error>> {
        let transport = transport(fake.bases(), Deadlines::production())?;
        let request = transport.new_request("https://api.dropboxapi.com/2/files/get_metadata");
        let failure = require_failure(transport.execute(request, b"{}"))?;
        match failure {
            SdkError::HttpClient(boxed) => match boxed.downcast::<TransportError>() {
                Ok(failure) => Ok(*failure),
                Err(other) => Err(io::Error::other(format!("unexpected failure {other}")).into()),
            },
            other => Err(io::Error::other(format!("unexpected failure {other}")).into()),
        }
    }

    /// A rotation store that records every call and the token visible during it.
    struct RecordingStore {
        calls: Mutex<Vec<String>>,
        observed: Mutex<Vec<Option<String>>>,
        outcomes: Mutex<VecDeque<Result<(), AuthError>>>,
        tokens: OnceLock<Weak<TokenState>>,
    }

    impl RecordingStore {
        fn new(outcomes: Vec<Result<(), AuthError>>) -> Self {
            Self {
                calls: Mutex::new(Vec::new()),
                observed: Mutex::new(Vec::new()),
                outcomes: Mutex::new(outcomes.into_iter().collect()),
                tokens: OnceLock::new(),
            }
        }

        fn watch(&self, tokens: &Arc<TokenState>) {
            let _ = self.tokens.set(Arc::downgrade(tokens));
        }

        fn calls(&self) -> Vec<String> {
            match self.calls.lock() {
                Ok(calls) => calls.clone(),
                Err(poisoned) => poisoned.into_inner().clone(),
            }
        }

        fn observed(&self) -> Vec<Option<String>> {
            match self.observed.lock() {
                Ok(observed) => observed.clone(),
                Err(poisoned) => poisoned.into_inner().clone(),
            }
        }
    }

    impl RotationStore for RecordingStore {
        fn replace(
            &self,
            _binding: &DropboxBinding,
            refresh: &RefreshToken,
        ) -> Result<(), AuthError> {
            let visible = self
                .tokens
                .get()
                .and_then(Weak::upgrade)
                .and_then(|tokens| tokens.token())
                .map(|token| String::from(token.as_str()));
            match self.observed.lock() {
                Ok(mut observed) => observed.push(visible),
                Err(poisoned) => poisoned.into_inner().push(visible),
            }
            let value = String::from(refresh.expose());
            match self.calls.lock() {
                Ok(mut calls) => calls.push(value),
                Err(poisoned) => poisoned.into_inner().push(value),
            }
            let next = match self.outcomes.lock() {
                Ok(mut outcomes) => outcomes.pop_front(),
                Err(poisoned) => poisoned.into_inner().pop_front(),
            };
            match next {
                Some(outcome) => outcome,
                None => Ok(()),
            }
        }
    }

    // -------------------------------------------------------- minimal HTTP fake

    /// One scripted HTTP response, with the stalls a deadline test needs.
    struct Reply {
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
        read_body: bool,
        delay_head: Duration,
        chunks: usize,
        chunk_delay: Duration,
        hold: Duration,
        send_bytes: Option<usize>,
        gate: Option<GateEnd>,
    }

    struct GateEnd {
        arrived: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
    }

    struct Gate {
        arrived: mpsc::Receiver<()>,
        release: mpsc::Sender<()>,
    }

    impl Gate {
        fn wait_for_request(&self) -> Result<(), io::Error> {
            self.arrived
                .recv_timeout(Duration::from_secs(10))
                .map_err(|_| io::Error::other("the fake server never received the request"))
        }

        fn release(&self) -> Result<(), io::Error> {
            self.release
                .send(())
                .map_err(|_| io::Error::other("the fake server stopped before its release"))
        }
    }

    impl Reply {
        fn new(status: u16, body: Vec<u8>, content_type: &str) -> Self {
            Self {
                status,
                headers: vec![(String::from("Content-Type"), String::from(content_type))],
                body,
                read_body: true,
                delay_head: Duration::ZERO,
                chunks: 1,
                chunk_delay: Duration::ZERO,
                hold: Duration::ZERO,
                send_bytes: None,
                gate: None,
            }
        }

        fn json(status: u16, value: serde_json::Value) -> Self {
            Self::new(status, value.to_string().into_bytes(), "application/json")
        }

        fn bytes(status: u16, body: Vec<u8>) -> Self {
            Self::new(status, body, "application/octet-stream")
        }

        fn empty(status: u16) -> Self {
            Self::new(status, Vec::new(), "application/octet-stream")
        }

        fn header(mut self, name: &str, value: &str) -> Self {
            self.headers.push((String::from(name), String::from(value)));
            self
        }

        fn without_reading_body(mut self) -> Self {
            self.read_body = false;
            self
        }

        fn delay_head(mut self, delay: Duration) -> Self {
            self.delay_head = delay;
            self
        }

        fn in_chunks(mut self, chunks: usize, delay: Duration) -> Self {
            self.chunks = chunks.max(1);
            self.chunk_delay = delay;
            self
        }

        fn send_bytes(mut self, bytes: usize) -> Self {
            self.send_bytes = Some(bytes);
            self
        }

        fn hold(mut self, hold: Duration) -> Self {
            self.hold = hold;
            self
        }

        fn gated(mut self) -> (Self, Gate) {
            let (arrived, wait_for_request) = mpsc::channel();
            let (release, wait_for_release) = mpsc::channel();
            self.gate = Some(GateEnd {
                arrived,
                release: wait_for_release,
            });
            (
                self,
                Gate {
                    arrived: wait_for_request,
                    release,
                },
            )
        }
    }

    /// A request the fake server received.
    struct Recorded {
        path: String,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
    }

    impl Recorded {
        fn all(&self, name: &str) -> Vec<String> {
            self.headers
                .iter()
                .filter(|(header, _)| header == name)
                .map(|(_, value)| value.clone())
                .collect()
        }
    }

    /// A single-threaded HTTP server that answers a scripted list of replies.
    struct Fake {
        base: String,
        address: SocketAddr,
        stop: Arc<AtomicBool>,
        worker: JoinHandle<io::Result<Vec<Recorded>>>,
    }

    impl Fake {
        fn start(replies: Vec<Reply>) -> io::Result<Self> {
            let listener = TcpListener::bind("127.0.0.1:0")?;
            let address = listener.local_addr()?;
            let base = format!("http://{address}");
            let stop = Arc::new(AtomicBool::new(false));
            let worker_stop = Arc::clone(&stop);
            let worker = thread::spawn(move || serve(listener, replies, &worker_stop));
            Ok(Self {
                base,
                address,
                stop,
                worker,
            })
        }

        fn bases(&self) -> Bases {
            Bases::new(
                format!("{}/2/", self.base),
                format!("{}/2/", self.base),
                format!("{}/2/", self.base),
                format!("{}/", self.base),
            )
        }

        fn finish(self) -> io::Result<Vec<Recorded>> {
            self.stop.store(true, Ordering::SeqCst);
            drop(TcpStream::connect(self.address));
            self.worker
                .join()
                .map_err(|_| io::Error::other("fake server thread failed"))?
        }
    }

    fn serve(
        listener: TcpListener,
        replies: Vec<Reply>,
        stop: &AtomicBool,
    ) -> io::Result<Vec<Recorded>> {
        let mut pending: VecDeque<Reply> = replies.into_iter().collect();
        let mut recorded = Vec::new();
        while let Some(reply) = pending.pop_front() {
            let (mut stream, _) = listener.accept()?;
            if stop.load(Ordering::SeqCst) {
                break;
            }
            let (path, headers, length) = read_head(&mut stream)?;
            let mut body = Vec::new();
            if reply.read_body {
                body.resize(length, 0);
                stream.read_exact(&mut body)?;
            }
            recorded.push(Recorded {
                path,
                headers,
                body,
            });
            if let Some(gate) = &reply.gate {
                gate.arrived
                    .send(())
                    .map_err(|_| io::Error::other("test stopped before the request arrived"))?;
                gate.release
                    .recv()
                    .map_err(|_| io::Error::other("test stopped before releasing the reply"))?;
            }
            thread::sleep(reply.delay_head);
            write_reply(&mut stream, &reply)?;
        }
        Ok(recorded)
    }

    type Head = (String, Vec<(String, String)>, usize);

    fn read_head(stream: &mut TcpStream) -> io::Result<Head> {
        let mut received = Vec::new();
        loop {
            if received.len() >= 64 * 1024 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "request head too large",
                ));
            }
            let mut byte = [0_u8; 1];
            stream.read_exact(&mut byte)?;
            received.push(byte[0]);
            if received.ends_with(b"\r\n\r\n") {
                break;
            }
        }
        let text = std::str::from_utf8(&received)
            .map_err(|source| io::Error::new(io::ErrorKind::InvalidData, source))?;
        let mut lines = text.split("\r\n");
        let request_line = lines
            .next()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing request line"))?;
        let path = request_line
            .split_whitespace()
            .nth(1)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing request path"))?;
        let mut headers = Vec::new();
        let mut length = 0_usize;
        for line in lines.filter(|line| !line.is_empty()) {
            let (name, value) = line
                .split_once(':')
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid header"))?;
            let name = name.to_ascii_lowercase();
            let value = String::from(value.trim());
            if name == "content-length" {
                length = value
                    .parse()
                    .map_err(|source| io::Error::new(io::ErrorKind::InvalidData, source))?;
            }
            headers.push((name, value));
        }
        Ok((String::from(path), headers, length))
    }

    fn write_reply(stream: &mut TcpStream, reply: &Reply) -> io::Result<()> {
        write!(stream, "HTTP/1.1 {} Scripted\r\n", reply.status)?;
        write!(stream, "Content-Length: {}\r\n", reply.body.len())?;
        stream.write_all(b"Connection: close\r\n")?;
        for (name, value) in &reply.headers {
            write!(stream, "{name}: {value}\r\n")?;
        }
        stream.write_all(b"\r\n")?;
        stream.flush()?;
        let sendable = (match reply.send_bytes {
            Some(bytes) => bytes,
            None => reply.body.len(),
        })
        .min(reply.body.len());
        let chunk = sendable.div_ceil(reply.chunks).max(1);
        let mut sent = 0;
        while sent < sendable {
            let end = (sent + chunk).min(sendable);
            stream.write_all(&reply.body[sent..end])?;
            stream.flush()?;
            sent = end;
            if sent < sendable {
                thread::sleep(reply.chunk_delay);
            }
        }
        thread::sleep(reply.hold);
        Ok(())
    }
}
