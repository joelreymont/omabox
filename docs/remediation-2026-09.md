# Remediation design: 2026-09 deep review

The focused corrections authorized on 2026-09-05 are tracked in their own
dots. Slot ownership, daemon recovery/readiness, root identity, durable
mutation blocking, and idle-cost fixes landed independently of section J.
Section J now replaces the handwritten OAuth and route layer in the main
checkout. Its original dot is `omabox-move-the-dropbox-cb30bc34`; the superseded
workspace was retired after integration in change `ltnqlvsx`. Durable
upload-session resumption remains its separate J-resume dot.

Baseline: commit `672301cf6366`. This document is the implementation contract
for every dot in the remediation campaign. Workers code to it; deviations are
design feedback, not improvisation.

## Principles

- One total order for canonical paths, enforced by a type.
- Every local or remote anomaly that concerns one path is an observation or a
  durable per-path state, never a process exit. The planner already blocks on
  `Unknown`; production code must produce it.
- The daemon exits only for conditions that need the user; everything else is
  retried in-process with bounded backoff and a published status.
- Staging-slot ownership is decided under one lock from the complete set of
  pending downloads.
- Idle passes are cheap: avoid unchanged inventory writes, validate the account once.
- Tests prove the production path. Fakes track documented Dropbox behavior.

## A. Canonical path identity (C1, hash cache)

`src/model.rs` gains:

```rust
/// Dropbox-canonical path relative to the sync root, ordered bytewise so in-memory
/// order always equals SQLite BLOB order.
#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct CanonicalPath(PathBuf);
impl Ord for CanonicalPath   // compares as_os_str().as_bytes()
impl CanonicalPath {
    pub fn from_display(path: &Path) -> Self;        // current dropbox_canonical_path
    pub(crate) fn from_bytes(bytes: Vec<u8>) -> Self; // journal decode
    pub fn as_path(&self) -> &Path;
    pub fn as_bytes(&self) -> &[u8];
    /// True when `self` is strictly beneath `ancestor` (ancestor + "/" prefix).
    pub fn is_beneath(&self, ancestor: &CanonicalPath) -> bool;
}
```

`BaselineRecord.canonical_path`, `RemoteObservationRecord.canonical_path`,
the local map key in `reconcile::local_map`, `pending`/`conflict_paths` map
keys, and `RemoteInventoryChange::DeleteSubtree` all use `CanonicalPath`.
`dropbox_canonical_path` is deleted; callers use `CanonicalPath::from_display`
and compute it once per record. `for_each_known_path`, `find_local`,
`find_remote`, `remote_map`, `local_map`, `order_path_decisions` compare
through `CanonicalPath::cmp`. The journal keeps `ORDER BY canonical_path`
(BLOB) and gains a debug assertion that rows arrive sorted.

Hash cache: `read_local_hash_cache` keeps `ORDER BY cache.path`; `cached_hash`
binary-searches by `as_os_str().as_bytes()`. A unit test seeds `x.txt` and
`x/y.txt` and asserts zero hash jobs on an unchanged rescan.

Tests: the merge property test generates multi-component names from the
alphabet `[a-z./ -]` and loads baselines through a real `Journal`; a
fake-Dropbox test with `report/x` beside `report.txt` covers local delete,
remote delete, and local edit.

## B. Journal schema version 6

`migrations/0006.sql`, applied in the existing single migration transaction,
followed by `PRAGMA user_version = 6`:

- `plans`: `status TEXT NOT NULL CHECK (status IN ('pending','blocked','completed'))`,
  `blocked_json TEXT` (serialized `BlockReason`, NULL unless blocked),
  `retry_at INTEGER` (unix seconds, NULL unless blocked). Unique partial index
  `one_live_plan_per_path ON plans(canonical_path) WHERE status IN ('pending','blocked')`
  replaces `one_pending_plan_per_path`. Because `operations.plan_id`
  references `plans(id) ON DELETE RESTRICT` and foreign keys are enabled during
  migration, `plans` and `operations` are rebuilt together: create `plans_v6`
  and `operations_v6` (the child referencing the new parent), copy rows
  preserving ids, ordinals, and statuses, drop `operations` then `plans`,
  rename both, recreate `operations_by_plan`, and run `PRAGMA foreign_key_check`
  before `user_version` is set.
- `baselines`, `remote_observations`, `conflicts`: rebuilt STRICT with
  `canonical_path BLOB NOT NULL` (rows with a NULL canonical path are
  backfilled from `path` in Rust first, using the existing
  `populate_canonical_paths`); `plans_v6` carries the same constraint. The
  database enforces the identity invariant; Rust write paths stop being the
  only guard.
- Partial index `remote_directories ON remote_observations(canonical_path)
  WHERE observation_json = '"Directory"'`.

Conflicts need no new columns because copy names are deterministic
(section H).

Connection setup keeps rollback journal mode and `synchronous = FULL`, and adds
an explicit `busy_timeout = 5000` and `foreign_keys = ON`. The database file
is created with `OpenOptions::mode(0o600).create_new(true)` before
`Connection::open` (ignore `AlreadyExists`); the lock file likewise.

Journal API additions (all transactional, `BEGIN IMMEDIATE`):

```rust
pub enum PlanStatus { Pending, Blocked { reason: BlockReason, retry_at: u64 }, Completed }
#[derive(Serialize, Deserialize)] pub enum BlockReason {
    RemoteRejected { tag: String },          // MutationRejection
    DownloadUnavailable { status: u16 },     // 4xx on exact download
    DownloadVerificationFailed,              // hash/size/revision mismatch
    StageOccupied,                           // unrelated bytes at the stage path
    LocalObjectInWay,                        // ENOTDIR/ELOOP/special file at target or parent
    RemoteObject,                            // folder or unsupported object at a file path
    UnsupportedFileSize,                     // above UPLOAD_SESSION_MAX_BYTES (section J)
}
pub fn block_plan(&mut self, id: PlanId, reason: &BlockReason, retry_at: u64) -> Result<PlanBlock, JournalError>;
pub fn blocked_plans(&self) -> Result<Vec<PlanRecord>, JournalError>;
pub fn unblock_plan(&mut self, id: PlanId) -> Result<PlanUnblock, JournalError>; // back to pending
```

`PlanRecord.status: PlanStatus`. `pending_plans()` returns pending only, in
one joined query ordered by `(plan_id, ordinal)`. `pending_upload_content`
includes blocked plans (their stages stay referenced).


## C. Scan observations instead of scan failures (C3 local, M7)

`scan_directory`:

- Symlink, FIFO, socket, device, unknown type: `Unknown(Unsupported)` record,
  continue.
- Every error raised while observing one entry (probe, open, stat, read,
  hash, reopen) is scoped to that entry: `ENOENT`, `ENOTDIR`, `ELOOP`, and
  `ESTALE` mean the object changed between two steps of its own observation
  and become `Unknown(Incomplete)`; every other errno becomes
  `Unknown(Inaccessible)`; only resource exhaustion (`EMFILE`, `ENFILE`,
  `ENOMEM`, `ENOSPC`) and root-level failures propagate as `LocalError`. For
  a directory the record is the directory itself; nothing beneath it is
  published. Cache rows validated in this pass beneath a discarded subtree are
  retained, so churn never forces a rehash.
- A directory whose before/after stat differs: `Unknown(Incomplete)` record for
  the directory; every observation already collected beneath it is discarded
  from this publication. The scan still publishes.
- Failures on the root directory itself remain `LocalError` (environmental).

Hash stage: a file that fails with `EIO`/`EACCES` during hashing becomes
`Unknown(Inaccessible)`; changed-during-read stays `Unknown(Incomplete)`.

Reconciler ancestor rule, applied to both sides in `reconcile_published`:
when a visited canonical path has no record on one side, the observation for
that side is `Unknown(reason)` if ANY recorded ancestor on that side is
`Unknown` (the nearest such ancestor supplies the reason), otherwise
`ConfirmedAbsent`. The rule walks every ancestor to the root so its safety
never depends on a producer keeping records out from under an `Unknown`
directory. Lookup is a binary search per ancestor over the side's sorted
records, performed only for paths lacking a record. `FreshObservationRequired` is no longer produced by directory churn;
the remaining producers (case renames, destination races) are rare, and the
daemon waits one second before re-entering the pass after one.

Mount points (M11): a directory or file whose `st_dev` differs from the sync
root's device is published as `Unknown(Unsupported)` and nothing beneath a
directory is scanned, exactly like a symlink. Content on another volume is therefore never
synchronized, so an unmounted mount point is an ordinary empty directory with
no baselines beneath it and nothing to infer. This is a scope decision, not a
technical necessity: installs already stage beside their target, so
cross-device subtrees would install atomically; what they cannot do safely is
distinguish "unmounted" from "emptied" without per-directory device history
and an explicit re-adoption action. Until that machinery is wanted, a subtree
on another volume is unsupported and `omabox status` says so.

## D. Per-path failure isolation and blocked plans (C3 remote, M1)

`ExactDownloadPool` distinguishes per-path outcomes from pool failures. Worker
results become:

```rust
enum DownloadResult { Staged { path }, Blocked { path, reason: BlockReason }, Failed { path, error: ReconcileError } }
```

`Blocked` results never cancel the pool and are recorded via `block_plan`
with `retry_at = now + BLOCKED_RETRY_SECONDS` (3600). `Failed` (transport,
5xx, local I/O other than the classified cases) cancels the batch as today and
surfaces as a retryable daemon error. Classification lives in one function
`classify_download_error(&DropboxError | &LocalError) -> Option<BlockReason>`.

Replay: `MutationOutcome::Rejected` and `ReplayBlocked::{StageDestinationOccupied,
RemoteObject}` block the plan instead of leaving it pending. `ENOTDIR`/`ELOOP`
or a special file at a target or parent during a local effect is
`BlockReason::LocalObjectInWay`; the effect primitives probe with
`O_PATH|O_NOFOLLOW` and open with `O_NONBLOCK` so a FIFO cannot hang the
reconciler.

Reconciler: a path with a blocked plan is re-planned every pass. If the fresh
decision's operations differ from the blocked plan's (content or revision
changed on either side), the plan is superseded and the new decision recorded.
If they match and `retry_at` has passed, `unblock_plan` makes it pending for
one more attempt. Otherwise the path counts as blocked in the report. A pending
plan whose fresh decision no longer matches is likewise superseded (not only
for conflicts and directory collisions).

`omabox status` lists blocked paths with their reason; the runtime snapshot
gains `blocked: u32`. `settings set-root` counts only pending plans and
pending recoveries as pending work.

## E. Daemon dispositions and the unit (C3 daemon, M4 401, unit)

```rust
enum Disposition {
    Retry(Duration),        // transient: rate limit (capped), transport, 5xx
    Environmental,          // wait with escalating backoff, publish status, retry
    UserAction(u8),         // exit code 78: needs setup/reauthorization
    Invariant,              // exit code 70: programming error
}
impl DaemonError { fn disposition(&self) -> Disposition }
```

- Retry delays escalate 5 s → 10 s → … → 5 min across consecutive failures and
  reset after a successful pass. `Retry-After` is honored up to
  `MAX_RETRY_AFTER` (15 min).
- Environmental: credentials unavailable (keyring locked), sync root
  unavailable or identity drift (see F), root-level scan failure, `ENOSPC`,
  `SQLITE_BUSY`/`SQLITE_FULL`, missing remote cursor (the next pass rebuilds
  the inventory), a refresh-token store failure after rotation (section J). The daemon
  publishes `DaemonPhase::Error` with a fixed message per condition, keeps the
  instance lock, and waits with the same escalating schedule.
- UserAction: setup required, a sync root whose filesystem records no
  creation time, account changed, root namespace changed, credential or
  journal binding changed, refresh token rejected (the SDK's
  `AuthError::InvalidAccessToken` after a refresh attempt, or an OAuth
  `invalid_grant`). An expired access token is refreshed inside the transport
  and re-issued once by the SDK; the daemon never restarts a session for it. The daemon publishes the fatal status and exits 78.
- Invariant: `InvalidJournalState` and other bugs exit 70.
- `last_error` is cleared only when a pass completes with zero sync errors.
- Readiness: the daemon sends `READY=1` over `NOTIFY_SOCKET` using
  `std::os::unix::net::UnixDatagram` (abstract addresses via
  `SocketAddrExt::from_abstract_name`; no new crate) as soon as the
  configuration is loaded, the instance lock is held, and the journal is open
  and migrated. Credential loading and account validation happen after
  readiness: a UserAction outcome there exits 78 from the active service; a
  Retry or Environmental outcome runs as an active degraded service with its
  status published; Invariant failures before readiness exit 70. The unit
  becomes `Type=notify` with `TimeoutStartSec=5min` (migrations run before
  readiness). Because `systemctl restart` of a notify unit returns only after
  readiness or failure, `install` learns whether the new daemon launched from
  that exit status alone; there is no polling. `omaboxd --self-check` prints
  the version and exits 0 without touching state, and `install` runs it on the
  staged binary before publishing, so a binary that cannot execute is caught
  before anything live changes.
- Unit: `RestartPreventExitStatus=70 78`, `StartLimitIntervalSec=10min`,
  `StartLimitBurst=5`, `After=graphical-session.target`,
  `ExecStopPost=-/usr/bin/rm -f %t/omabox/status.json`, with the start-limit
  keys in `[Unit]`. `ExecStopPost` is the only removal of `status.json`: the
  daemon has no shutdown path by design, because every effect is crash-safe
  (checkpointed stages, transactional journal), so SIGTERM may end it at any
  instruction. A corrupt journal (`SQLITE_CORRUPT`, `SQLITE_NOTADB`) is
  UserAction; busy, full, and other SQLite failures are Environmental.
- The session loop, dispositions, and schedule live in a library module
  `src/daemon.rs`; `src/bin/omaboxd.rs` becomes the thin entry point, so tests
  can drive a session against the fake server.

## F. Root activation (M2)

```rust
pub enum LocalRootActivation {
    Current(LocalRootRecord),
    Activated(LocalRootRecord),
    Unavailable { recorded: LocalRootBinding, actual: LocalRootBinding },
}
pub fn activate_local_root(&mut self, binding) -> Result<LocalRootActivation, JournalError>;
pub fn adopt_local_root(&mut self, binding) -> Result<LocalRootActivation, JournalError>;
```

`activate_local_root`: same canonical path whose inode, birth time or subvolume
differs is `Unavailable` and writes nothing (daemon: Environmental). The device
number is not part of the identity because btrfs assigns each subvolume a new
one at every mount. A schema-6 binding, which has no birth time, is upgraded in
place when its path and inode match. A root whose filesystem records no
creation time is refused as a user action (`JournalError::NoBirthTime`).
At the path of a recorded root that has a birth time, or a schema-6 root
whose inode differs, the daemon treats that refusal as the root being
unavailable (Environmental), at activation and during a pass: a directory
stands in for it, such as the mount point under an absent mount.
A different canonical
path (configuration changed) supersedes every pending and blocked plan and
retires pending recovery intents in the same transaction, then starts a new
generation. `Busy` is removed. `adopt_local_root` returns the current record
when the path and identity are unchanged, upgrades a schema-6 binding in place when its
path and inode match, and otherwise starts a new generation, including for the
same path when the identity differs; it is used by `settings set-root`.

## G. Staging-slot ownership (C2, orphaned stages)

`lease_download_slots(staging, wanted: &[DownloadSlotIdentity], protected: &BTreeSet<[u8; 32]>)`
never resets a slot whose binding is in `protected`. `ExactDownloadPool`
owns leasing: `schedule_downloads(&mut self, downloads, pending_bindings)`
takes the slot mutex, unions the bindings of in-flight jobs (tracked in
`DownloadSlots` as bindings, not indices) with the bindings of every pending
download plan, leases with that set as `protected`, and schedules. The
duplicate-slot check becomes a debug assertion. A slot is reset only when its
binding belongs to no pending plan.

Verified stages are removed when their plan is superseded; when a plan
finishes as a conflict, the verified stage is renamed to the deterministic
remote conflict copy name (section H) instead of downloading again.

## H. Conflict lifecycle (M8)

Conflict copies keep deterministic names so the existing crash-safety
(idempotent materialization, `AlreadyPresent` on replay) is unchanged, but the
names become readable: `<stem> (conflicted copy, <side>, <hash8>)<ext>` with
`<side>` = `local` or `Dropbox` and `<hash8>` the first eight hex digits of
the existing `internal_name` digest over (side, path, content). Two different
payloads never share a name, and the same payload maps to the same name, so no
suffix negotiation or journal-recorded names are needed. The journal's
conflict record is unchanged. A conflict is prepared once: later passes skip a
path whose conflict record exists and whose copies are present at their
deterministic names.

`omabox status` lists conflicts with both copy names. The runtime snapshot
gains `conflicts: Vec<String>` (bounded to 20 display paths) and
`conflict_count: u32`; the widget shows the count and the paths.

## I. Dropbox listing robustness and cost (M4, M5)

- Restricted folder (`no_access` or `traverse_only`): `Unknown(Inaccessible)`
  record; the root itself restricted stays `RemoteRootRestricted`. An
  `EnsureDirectory` change (an ancestor materialized from a listed child)
  never overwrites an `Unknown` observation, in the listing accumulator and in
  `apply_remote_inventory_delta` alike; otherwise a restricted folder with one
  listable child would read as `Directory` and its invisible children as
  absent. A mutation whose confirmed identity differs from the requested path
  is a dedicated `MutationRejection` variant, not an error.
- Downloadable file without `content_hash` or `rev`: `Unknown(Incomplete)`.
- `display.to_lowercase() != path_lower`: `Unknown(Unsupported)` record keyed
  by Dropbox's `path_lower`, logged once per path; never an error.
  `validate_mutation_path` compares against the canonical form the same way and
  reports `MutationRejection` rather than an error.
- An entry whose `path_lower` equals the root is skipped; a `deleted` entry for
  the root is `RemoteRootUnavailable`.
- `remove_subtree` deletes the key and the `key/`…`key/\u{10FFFF}` range;
  `normalize_inventory_records` runs once after the last page.
- Listing entries are the SDK's `Metadata` enum (`File`, `Folder`, `Deleted`)
  and `FolderSharingInfo { traverse_only, no_access }`; classification matches
  those types, never `.tag` strings.

## J. Transport on `dropbox-sdk` (replaces the hand-written wire layer)

Decision (2026-09-02): the generated types and routes of the `dropbox-sdk`
crate replace the hand-written request/response structs and string-tag
matching, so every route argument, result, and route error is a typed value.
The SDK is a generated-type and route layer, not a complete wire layer: its
client boundary discards response headers other than `Dropbox-API-Result`,
hardcodes origins, buffers upload bodies, and owns exactly one automatic
retry (`ExpiredAccessToken`). Everything the boundary cannot express is an
explicit local adapter inside our transport, listed below; nothing is assumed.

Dependency: `dropbox-sdk = { version = "=0.20.3", default-features = false,
features = ["dbx_files", "dbx_users", "sync_routes"] }`, pinned because the
adapters depend on this version's parser, retry, and trait behavior; an
upgrade requires re-running the transport conformance tests. No bundled HTTP
client. Brings `ring`, `url`, `futures`, `async-lock`, `bytes`, `log`;
`Cargo.lock` is committed with the change. Our `base64` use is removed if the
SDK's PKCE replaces it. Fallible OS randomness and `base64` remain because
the SDK's random PKCE constructor panics on entropy-source failure. Both agents are configured with
`http_status_as_error(false)` so every status reaches the SDK's parser.

### Transport

`src/transport.rs` implements `HttpClient` plus the `UserAuthClient` and
`NoauthClient` markers over two `ureq` 3 agents (content, poll):

```rust
pub struct Transport { content: ureq::Agent, poll: ureq::Agent, bases: Bases,
                       tokens: Arc<TokenState>, path_root: String /* serialized PathRoot */ }
pub struct Request { target: Result<Target, RequestError>, headers: Vec<(String, String)> }
struct Target { kind: RequestKind /* Rpc, Upload, Finish, Download, LongPoll, OAuth */, url: String }
```

- `new_request(url)` matches the SDK's four hardcoded prefixes exactly
  (scheme, host, port, path boundary) and maps them onto `DropboxEndpoints`;
  any other URL becomes a deferred typed error returned by `execute`.
  Non-production bases are only constructible through the test-only
  `DropboxEndpoints::new`. Rebasing preserves the route path, so the
  `Authorization` header can never travel to an unintended origin.
- `set_header` stores raw name/value pairs (it cannot fail); `execute`
  validates them into ureq headers with typed errors and replaces
  case-insensitively so a duplicate `Range` or `Dropbox-API-Arg` is a
  replacement, never a second header.
- `Dropbox-API-Arg` values are re-encoded per Unicode scalar value: `U+0020`
  through `U+007E` unchanged except existing JSON escapes, which are kept;
  every other scalar as `\uXXXX`, with UTF-16 surrogate pairs above `U+FFFF`;
  a value that is not valid JSON is a typed error. Never bytewise.
- Timeouts are per request kind and follow ureq's composition rule (a
  preceding phase's deadline still binds the next; an expired deadline floors
  the socket timeout at one second):

  | Kind | ureq settings (all others unset) |
  |---|---|
  | Rpc, OAuth | `global = JSON_REQUEST_SECONDS` |
  | Download | `send_request = JSON_REQUEST_SECONDS`, `recv_body = BODY_IDLE_SECONDS` |
  | Upload (direct, session start, append) | `send_body = BODY_IDLE_SECONDS`, `recv_response = UPLOAD_RESPONSE_SECONDS` |
  | Finish | `recv_response = SESSION_FINISH_SECONDS` (one hour); the finish body is always empty because every byte was appended first |
  | LongPoll | `global = timeout + 90 s + LONG_POLL_GRACE_SECONDS`, where `timeout` is parsed from the request body (absent means 30) with checked arithmetic |

  `BODY_IDLE_SECONDS = 60` and `UPLOAD_RESPONSE_SECONDS = 60`: a dead
  connection fails within one idle minute, and the upload response bound never
  exceeds the body-idle bound, which ureq's composition requires for it to
  bind at all; the long-poll server slack (90 s) is a named field of the
  deadline set so the row can be proven with an injected zero. Both agents
  follow no redirects, so `Authorization` can never leave the mapped origin.
  Each row is proven by a behavioral test against the fake server with
  injected constants and delays above the one-second floor.
- Responses: the status is returned unchanged; `Dropbox-API-Result` and
  `Content-Length` are copied; the body is streamed and never drained, with
  three bounded exceptions where `execute` must read the body to build a
  typed error: 429, retryable 5xx carrying `Retry-After`, and 422.
- Rate limits: on 429 `execute` reads the bounded body, parses the typed
  reason and `retry_after`, combines it with a valid `Retry-After` header
  (delta-seconds or IMF-fixdate) taking the greater, caps at
  `MAX_RETRY_AFTER`, and returns a local `RateLimitFailure` through
  `Error::HttpClient` carrying reason, delay, and the raw body. A 5xx with
  `Retry-After` yields `ServerBusy { delay }` the same way.
- Path root: `Transport` is constructed only after root activation with a
  serialized `PathRoot::Root(namespace)`; a home-rooted operation is an
  explicit variant, never an accidental `None`. On 422 `execute` parses
  `Dropbox-API-Path-Root-Error` into `PathRootError` and returns a local typed
  error; `InvalidRoot` and `NoPermission` are UserAction (section E).
- Range: `Request` stores the parsed range the SDK asked for (only `bytes=N-`
  is used; a fresh download sends no range, never `bytes=0-`). Before any byte
  reaches the caller: ranged 200 is `RangeIgnored`; ranged 206 requires
  exactly one `Content-Range: bytes S-E/(L|*)` with `S == N`, `E >= S`,
  numeric `L > E`, and `Content-Length == E-S+1` when present, else
  `RangeMismatch`; another ranged 2xx is `UnexpectedRangeStatus`; 416 becomes
  `RangeUnsatisfiable { length }` so staging can verify or restart; non-2xx
  responses skip range checks. `Accept-Encoding: identity` is sent on every
  download so offsets, lengths, and hashes refer to one representation.
- Poisoning: shared state is accessed with an explicit non-panicking poison
  policy (`Err(poisoned) => poisoned.into_inner()` by `match`, never an
  `unwrap*` name).

### Tokens

`TokenState` is a single-flight refresh keyed by access-token generation:
`Ready(gen, token)`, `Refreshing(gen)`, `PendingPersistence(gen, auth)`,
`Rejected(cause)`.

- `token()` returns the current token without blocking on a refresh.
- `update_token(old)`: if `old` is not the current generation, return
  `Ok(true)` (a peer already refreshed). Otherwise exactly one thread performs
  the refresh while peers wait on a condition variable and share its result;
  the `token() == None` startup path is the same generation. Network and
  Secret Service work happen without holding the lock `token()` uses.
- The refresh goes through `oauth2::Authorization::obtain_access_token`
  using a by-value `RefreshClient<'a>` (implements `HttpClient +
  NoauthClient`, delegates to the poll agent, exposes no token and no path
  root). OAuth `invalid_grant` arrives as `Error::BadRequest(body)`; it is
  parsed into a local typed OAuth error.
- Rotation: after a successful refresh, if `Authorization::save()` differs
  from the stored record, the versioned Secret Service record is replaced
  before the new access token is published; a storage failure leaves the
  state `PendingPersistence` (the new token is usable, storage is retried,
  OAuth is not) and surfaces as Environmental with the storage cause.
- Transient refresh failures (transport, 429, 5xx) are cached for the waiting
  cohort as one Retry outcome; `invalid_grant`, or `InvalidAccessToken` on
  a request re-issued after a successful refresh, is `Rejected` and
  UserAction. An `InvalidAccessToken` before any refresh in this process
  triggers one explicit refresh and re-issue outside the SDK's automatic path.

### Routes and arguments

`src/dropbox.rs` keeps `DropboxClient`'s engine-facing API and calls
`sync_routes::files` and `users`. Arguments are explicit:

- Create: `UploadArg::new(path)` with `WriteMode::Add`, `autorename = false`,
  `strict_conflict = true`, `content_hash = Some(staged hash)`.
- Replace: `WriteMode::Update(last_known_rev)`, `strict_conflict = true`,
  `content_hash` set; on session finishes the same `CommitInfo` plus
  `UploadSessionFinishArg::with_content_hash`.
- Delete: `DeleteArg::new(path).with_parent_rev(last_known_rev)`.
- Create folder: `CreateFolderArg` with `autorename = false`.
- Download: `DownloadArg::new("rev:<rev>").with_rev(rev)` preserves the
  engine's exact-revision API without treating a staging path as a remote path; range `Some(offset)`
  on resume; `rev`, `content_hash`, `size` checks and whole-file hashing stay
  ours.
- Batch mode (`upload_session/finish_batch`) is not used and never was; every
  mutation is a single revision-conditioned call.
- Uploads: files above `UPLOAD_SESSION_CHUNK_BYTES` (32 MiB) use sessions, all
  data appended before an empty finish; smaller files use `upload`. One
  buffer of `min(file_size, 32 MiB)` per active upload; uploads are sequential
  in replay, so the process-wide peak is one buffer.
- Oversized: `UPLOAD_SESSION_MAX_BYTES = 350_000_000_000`; a larger file is
  rejected before any session opens and its plan is blocked with
  `BlockReason::UnsupportedFileSize` (added to section B's enum), never
  retried, never inferring anything remote.

Error mapping is a per-operation table covering every current SDK variant.
`Other` and the compiler-required fallback for non-exhaustive SDK enums map
to a dedicated `Unknown` outcome; every high-level variant that extracts
information keeps the SDK or local error as its source:

| Operation | SDK error | Outcome |
|---|---|---|
| upload / finish | `WriteError::Conflict(_)` | definitive `MutationRejection` (precondition failed) |
| upload / finish | `WriteError::{NoWritePermission, InsufficientSpace, DisallowedName, TeamFolder, OperationSuppressed, AccessRestricted, MalformedPath}` | definitive `MutationRejection` |
| upload / finish | `TooManyWriteOperations`, `PayloadTooLarge` | Retry |
| upload / finish | `ContentHashMismatch` | `UploadedContentMismatch` (transport-class retry) |
| append | `IncorrectOffset(correct_offset)` | offset reconciliation (existing) |
| append | `NotFound`, `Closed`, `TooLarge` | session restart from durable state (section J-resume) |
| delete | `PathLookup(NotFound)` | `Absent` (already gone) |
| delete | `PathWrite(Conflict)` | definitive `MutationRejection` |
| download | `Path(NotFound)` | `DownloadUnavailable` → blocked plan |
| download | `Path(RestrictedContent)`, `UnsupportedFile` | blocked plan |
| list_folder / continue | `Path(_)` | inventory refresh failure (Environmental) |
| continue / longpoll | `Reset` | cursor reset (existing rebuild) |
| any | `Error::Authentication(ExpiredAccessToken)` | SDK refresh (Tokens) |
| any | `Error::Authentication(InvalidAccessToken)` | Tokens rule above |
| any | `Error::Authentication(MissingScope)` | UserAction |
| any | `RateLimitFailure`, `ServerBusy`, `Error::ServerError` | Retry with delay |
| any | `Error::HttpClient(transport)` | Retry |
| any | `Error::BadRequest`, `UnexpectedResponse`, `UnexpectedHttpError`, `Json` | Invariant (a bug on one side) |
| any | `PathRootError` | UserAction |

`DropboxError` remains the daemon's classification surface with the engine
variants that survive: `UnverifiedMutation`, `RetriedTransport`,
`UploadedContentMismatch`, `DownloadedIdentityChanged`,
`CursorDidNotAdvance`, `ResetDuringFreshListing`.

Longpoll: after any response the daemon waits at least the typed `backoff`
before the next longpoll (existing behavior, now typed).

### Durable upload sessions (J-resume, its own dot)

Upload sessions become durable so an interrupted large upload resumes instead
of restarting: after every accepted append the journal records session id,
confirmed offset, source fingerprint, expected baseline revision, and hash
progress in one transaction keyed by the plan's operation; replay reconciles
`incorrect_offset` against that record and the local bytes; a session the
server no longer knows restarts from zero. An ambiguous finish is verified by
metadata exactly as today (`resolve_ambiguous`) and never repeated blindly; a
finish that merely timed out never opens a replacement session.

### Auth

`src/auth.rs` keeps Secret Service storage (`secret-tool` over pipes, child
handling with chained cleanup errors, EPIPE reporting the exit status) and
drives OAuth through the SDK: `AuthorizeUrlBuilder` with `Oauth2Type::PKCE`
and `TokenType::ShortLivedAndRefresh`, `Authorization::from_auth_code`
through `RefreshClient`, `from_refresh_token` on startup. The stored secret
stays our versioned record holding the raw refresh token, replaced on
rotation.

### Fake server

`Metadata` deserialization requires `.tag` as the first key: the fake writes
tagged objects through an explicit writer that emits `.tag` first and asserts
it. Documented 409 bodies (`path/conflict/file`, `path_write/conflict/file`,
`path_lookup/not_found`, `reset`) replace the ad-hoc `{"error":{".tag":"path"}}`
where tests need them.

### Carried over from the superseded client change

`RetriedTransport`/`UnverifiedMutation` chained errors with the original as
source, `UploadedContentMismatch` on the direct upload/finish path,
`auth.rs` child handling and its tests, dropping instead of draining an
unneeded response, `ProgressReader::complete`. Not carried: per-phase timeout
configuration, `http.rs`, `HeaderNumber`.

### Integrated verification notes

All original fake-server scenarios remain. SDK fixtures use documented shapes
and omit arguments whose generated defaults already encode the requested value.
The stage-race test now verifies that an existing verified stage is preserved
and installed while the unused response is dropped, as required above. The old
ASCII and timeout configuration assertions are covered by the adapter's Unicode
and behavioral deadline tests. Token rejection policy tests replace daemon-side
401 session reconstruction tests; SDK refresh/reissue and unauthenticated
longpoll are exercised through generated routes. HTTP 416 restart and oversized
plan persistence have explicit regressions.

### Upstream follow-ups (reference)

Response-header exposure, configurable endpoints, and streaming upload bodies
would remove the adapters above; they are candidate upstream changes to
`dropbox-sdk-rust`, tracked as a low-priority dot, not assumed.

## K. Idle pass cost (M6)

- `publish_local_scan` compares the existing inventory and hash cache with the
  new scan inside the active-root write transaction. An identical scan writes
  no observation or hash-cache rows; a changed scan replaces both collections
  atomically. The comparison still acquires the write lock. This deliberately
  replaces the proposed row-diff merge with the smaller implementation landed
  in `ac273d7b`. [Measurements](performance.md) showed a 62% idle-pass reduction
  at 10k files and 47% at 50k files. These measurements justify the unchanged-scan
  shortcut; they do not establish changed-scan performance or a lock-free read.
- `pending_plans` is one join and is loaded once per pass and passed through.
- The scanner computes `CanonicalPath` once per entry and
  `LocalObservationRecord` carries it, so `local_map` only sorts and the
  per-pass fold disappears; every ordered `LocalHashRecord` collection uses
  byte order.
- `validate_account` runs once per session; `refresh_inventory` no longer
  calls it. Agent reuse is a property of the transport (section J).
- `require_active_local_root` runs once before planning and once before the
  completion batch; effects go through the held root descriptor.
- `ensure_remote_parents` runs only after a `path/not_found` rejection.

## L. Install, CLI, config

- `install`: restart failure runs rollback, `daemon-reload`, and state restore;
  before publishing, the staged `omaboxd` is executed with `--self-check`
  (prints version, exits 0 without touching state); symlinked destinations and
  source-equals-destination are refused with typed errors; uninstall disables
  the plugin through `omarchy-shell` before removal; `Layout` honors
  `XDG_CONFIG_HOME`; every `InstallError` has help; `RollbackFailed` and
  `CleanupFailed` expose both chains via `#[related]`; stale
  `.omabox*.install.*` and `.config.toml.*.tmp` siblings whose PID is dead are
  swept before each transaction.
- `config`: `ConfigDocument` loads without filesystem checks; `Config::validate`
  is separate. `settings set-root` validates only the replacement and calls
  `adopt_local_root`; `status` and `settings` render an unresolvable root as a
  line. The config directory is added to `validate_outside`. State, staging,
  and recovery paths are stored as projected physical paths.
- `setup` stops and restores the service like `set-root`; the lock error names
  `omabox pause`. The authorization code read is bounded with `take` and
  trimmed. README: setup prints a URL; live tests need
  `--features dropbox-live -- --ignored`.

## M. Journal hygiene

- `invalidate_case_collision_baselines` invalidates only the renamed spelling's
  future and re-records the kept spelling's baseline. Whether a spelling
  "stays behind" is an existence check against the active root descriptor at
  the moment of invalidation, never a lookup in a previously published
  inventory, which can be stale after a crash or an early return. When a
  baseline exists, the automatic rename moves a spelling other than the one
  the baseline names, so history stays attached to the file it was recorded
  for.
- Legacy adoption of a v1 journal starts a fresh generation instead of binding
  existing baselines to whatever root is configured.
- `config::redacted` is removed; `Journal::publish_local_inventory` moves under
  `cfg(test)`.

## N. Tests and models

- Planner strategies draw the baseline first and derive local and remote content
  from `prop_oneof![Just(baseline), fresh]` over a two-letter alphabet, with a
  coverage assertion that every operation variant appears in a run.
- The fake server validates `list_folder/continue` cursors, derives 409
  conflicts from the request's `parent_rev`/update rev with the documented
  `path/conflict/file` body, includes the root folder entry in recursive
  listings, and returns `error_summary`.
- New tests: daemon-level `run_session` against the fake for a socket, a
  symlink, a mode-000 file, a 409 download, a restricted folder, a revoked
  token, and a locked keyring, each asserting unrelated paths still sync;
  crash tests for remote effect then crash, conflict recorded then crash, and
  baseline invalidation then rename crash; a cross-filesystem promotion test
  with the root on `/tmp` and staging on `/dev/shm`; an integration test that
  runs `qmltestrunner` (part of `qt6-declarative`, which quickshell already
  requires on Omarchy) against the plugin tests and fails when the runner is
  absent, with the requirement stated in README under Develop.
- Subprocess fixtures are spawned through `/bin/sh <path>`.
- `formal/DownloadExecutor.tla` gains a permanent per-job failure state that
  never cancels siblings; `DownloadLifecycle.tla` `DiscardStaleSlot` guards on
  the protected set; models re-run.

## O. Measurements

`examples/scan_bench.rs` times a generated 50k-file tree across 1, 4, 8, and 12
hash workers; `examples/inventory_bench.rs` times inventory application at
10k, 50k, and 100k entries. Numbers are recorded in `docs/performance.md` and
justify `MAX_PARALLEL_HASHES`. Idle pass cost on a 100k-file tree is measured
after K lands; inotify wake-ups are implemented only if the idle pass exceeds
200 ms CPU.

## Dot graph

Wave 0: A.
Wave 1 (after A): B, C, G, J-transport, L-install, L-config-physical, M, N-planner-and-fixtures.
Wave 2: E (J), I (J), D (B, C, E, G), F (B, E), H (B, G), K (B, J), L-cli (F).
Wave 3: N-daemon-tests (D, E, F, H, I), TLA reconciliation, O.

## Simplifications after review

Compared with the first draft: no per-directory device history or adopt
command (mount points are unsupported, like symlinks; a scope decision, see
section C); no journal-recorded conflict names (deterministic readable names
keep the existing idempotence); no WAL switch (rollback mode with an explicit
busy timeout satisfies every invariant, and a busy commit is a retried pass
under section E); fixed one-second wait instead of an escalating schedule for
fresh observations. Kept after a second look: the `Type=notify` readiness
handshake (the structural signal that the daemon launched; polling is a
timing heuristic), the NOT NULL rebuilds (the database enforces the identity
invariant), and a real QML test rather than an ignored one (the runner is
present on the target platform).
