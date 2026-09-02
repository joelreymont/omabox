# Remediation design: 2026-09 deep review

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
- Idle passes are cheap: write only what changed, validate the account once.
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
- `EACCES`/`EPERM`/`EIO`/`ENXIO` on probe, open, stat, or read of an entry:
  `Unknown(Inaccessible)` record for that entry, continue. For a directory the
  record is the directory itself; nothing beneath it is published.
- A directory whose before/after stat differs: `Unknown(Incomplete)` record for
  the directory; every observation already collected beneath it is discarded
  from this publication. The scan still publishes.
- Failures on the root directory itself remain `LocalError` (environmental).

Hash stage: a file that fails with `EIO`/`EACCES` during hashing becomes
`Unknown(Inaccessible)`; changed-during-read stays `Unknown(Incomplete)`.

Reconciler ancestor rule, applied to both sides in `reconcile_published`:
when a visited canonical path has no record on one side, the observation for
that side is the nearest ancestor record's `Unknown(reason)` if that ancestor
is `Unknown`, otherwise `ConfirmedAbsent`. Lookup is a binary search per
ancestor over the side's sorted records, performed only for paths lacking a
record. `FreshObservationRequired` is no longer produced by directory churn;
the remaining producers (case renames, destination races) are rare, and the
daemon waits one second before re-entering the pass after one.

Mount points (M11): a directory whose `st_dev` differs from the sync root's
device is published as `Unknown(Unsupported)` and nothing beneath it is
scanned, exactly like a symlink. Content on another volume is therefore never
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
  the inventory), more than one consecutive session ending in 401. The daemon
  publishes `DaemonPhase::Error` with a fixed message per condition, keeps the
  instance lock, and waits with the same escalating schedule.
- UserAction: setup required, account changed, root namespace changed,
  credential or journal binding changed, refresh token rejected (the SDK's
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
pub fn adopt_local_root(&mut self, binding) -> Result<LocalRootRecord, JournalError>;
```

`activate_local_root`: same canonical path with different device or inode is
`Unavailable` and writes nothing (daemon: Environmental). A different canonical
path (configuration changed) supersedes every pending and blocked plan and
retires pending recovery intents in the same transaction, then starts a new
generation. `Busy` is removed. `adopt_local_root` starts a new generation
unconditionally and is used by `setup` and `settings set-root`, which is
allowed for the same path when the identity differs.

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

Decision (2026-09-02): the wire layer moves to the `dropbox-sdk` crate
(0.20.x, Apache-2.0, generated by Dropbox's Stone tooling from the official
spec) so that every request, response, and error is a typed value instead of a
hand-written struct or a string tag. The HTTP transport, timeouts, endpoint
selection, header encoding, range validation, hashing, and every policy stay
ours; the SDK never retries or sleeps on our behalf except one automatic
re-issue after `ExpiredAccessToken` through our own `update_token`.

Dependency: `dropbox-sdk = { version = "0.20", default-features = false,
features = ["dbx_files", "dbx_users", "sync_routes"] }`. No bundled HTTP
client. This brings `ring` (PKCE SHA-256), `url`, `futures`, `async-lock`,
`bytes`, `log`; `Cargo.lock` is committed with the change. Our own `base64`
use is removed if the SDK's PKCE replaces it.

`src/transport.rs` (new) implements the SDK's `HttpClient` plus the
`UserAuthClient` and `NoauthClient` markers over two `ureq` 3 agents:

```rust
pub struct Transport { content: ureq::Agent, poll: ureq::Agent, bases: DropboxEndpoints,
                       tokens: Mutex<Session>, path_root: Option<String> /* serialized PathRoot */ }
pub struct Request { url: String, headers: Vec<(HeaderName, String)>, kind: RequestKind }
impl HttpClient for Transport {
    type Request = Request;
    fn new_request(&self, url: &str) -> Request;          // maps the SDK's hardcoded
        // https://{api,content,notify}.dropboxapi.com/2/ and /oauth2/ prefixes onto
        // DropboxEndpoints, so the fake server is reachable; classifies the request
        // kind (Rpc, Upload, Download, LongPoll, OAuth) from the mapped prefix and
        // route name for timeout selection.
    fn execute(&self, request: Request, body: &[u8]) -> Result<HttpRequestResultRaw, Error>;
    fn token(&self) -> Option<Arc<String>>;              // current access token
    fn update_token(&self, old: Arc<String>) -> Result<bool, Error>; // refresh via oauth2
    fn path_root(&self) -> Option<&str>;
}
```

Rules the transport enforces (each with a unit test through `execute`):
- `set_header("Dropbox-API-Arg", json)` escapes every byte outside
  `0x20..=0x7E` as `\uXXXX` (surrogate pairs for astral characters); this is
  where `ascii_json` moves.
- Timeouts are chosen per request kind, not per phase, because ureq composes
  phase timeouts (a preceding phase's deadline still binds a later one): Rpc
  and OAuth use one global bound (`JSON_REQUEST_SECONDS`); Upload (direct,
  session start/append/finish) uses a body-idle bound with no
  send-request bound and a finish-specific response bound of one hour;
  Download uses a header bound of `JSON_REQUEST_SECONDS` and a body-idle
  bound of 60 s; LongPoll uses a global bound of the requested timeout plus
  the server's 90 s jitter plus grace. Each rule is proven by a behavioral test
  against the fake server with injected short constants, never by asserting
  configuration.
- The response status is returned unchanged for every code; the
  `Dropbox-API-Result` header and `Content-Length` are copied; the body is
  returned as a stream, never drained.
- For a request that carried `Range`, a `200` response or a `Content-Range`
  that does not start at the requested offset is a typed transport error
  (`RangeIgnored`, `RangeMismatch`) before any byte reaches the caller; a
  `206` without `Content-Range` likewise. The existing `Content-Length`
  cross-check stays in `dropbox.rs`.
- `update_token` refreshes through the SDK's `oauth2::Authorization` using
  the transport itself as the `NoauthClient`; a refresh rejected by Dropbox
  surfaces as a typed authentication failure that the daemon classifies as
  UserAction (section E). The daemon no longer restarts a session on 401.

`src/dropbox.rs` keeps the engine-facing API (`DropboxClient`, inventory
construction, mutation classification, exact downloads, upload sessions) and
calls the SDK's `sync_routes::files` and `users` functions. Deleted: every
hand-written request/response struct, `post_api`, `authorized_post`,
`find_mutation_rejection` and all string-tag matching, `status_failure`,
`ascii_json` (moved), `http.rs`. `MutationRejection` and every classification
match typed SDK enums exhaustively (`WriteError`, `WriteConflictError`,
`LookupError`, `UploadSessionAppendError`, `DownloadError`, `ListFolderError`,
`ListFolderContinueError::Reset`, `AuthError`, `RateLimitReason`), with no
`_ =>` arm except for the SDK's `Other` variants, which map to a dedicated
`Unknown` rejection. `DropboxError` becomes the classification surface the
daemon consumes: `Transport`, `RateLimited { retry_after }` (from the SDK's
`retry_after_seconds`, zero meaning the default delay), `Authentication`
(expired vs revoked vs scope), `ServerError`, `Api(...)` per route, plus the
engine-level variants that survive: `UnverifiedMutation` and
`RetriedTransport` (chained, original as source), `UploadedContentMismatch`
on the direct upload and finish path only, `DownloadedIdentityChanged`,
`CursorDidNotAdvance`, `ResetDuringFreshListing`.

Uploads: SDK bodies are `&[u8]`, so files larger than `UPLOAD_SESSION_CHUNK_BYTES`
(32 MiB) go through sessions and smaller files through `upload`, both from one
reused 32 MiB buffer per upload; nothing reads more than one chunk into memory.
`UploadSessionAppendArg::with_content_hash` exists, so the per-chunk hash
follow-up becomes a small change once block digests are persisted.

Downloads: `files::download(client, arg, Some(offset), None)` for resume; the
SDK parses `Dropbox-API-Result` into `FileMetadata`; `rev`, `content_hash`,
`size` checks and whole-file hashing stay in `dropbox.rs`.

`src/auth.rs` keeps Secret Service storage (`secret-tool` over pipes, child
handling with chained cleanup errors, EPIPE reporting the exit status) and
drives OAuth through the SDK: `AuthorizeUrlBuilder` with `Oauth2Type::PKCE`
and `TokenType::ShortLivedAndRefresh`, `Authorization::from_auth_code`,
`obtain_access_token` through the transport, `from_refresh_token` on startup.
The stored secret stays our versioned record holding the raw refresh token.

Fake server: `Metadata`'s deserializer requires `.tag` as the first key; the
fake emits it first (serde_json's default map ordering already does).
Upload session limits: `UPLOAD_SESSION_MAX_BYTES` = 350 GB.

Everything in the superseded client-hygiene change that is not transport
(chained `RetriedTransport`/`UnverifiedMutation`, `UploadedContentMismatch`,
`auth.rs` child handling and its tests, dropping instead of draining an
unneeded response, `ProgressReader::complete`) is carried into this lane; the
per-phase timeout configuration, `http.rs`, and `HeaderNumber` are not.

## K. Idle pass cost (M6)

- `publish_local_scan` reads the existing inventory and hash cache in canonical
  order, merges with the new scan, and writes only inserted, updated, or
  deleted rows.
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
  future and re-records the kept spelling's baseline.
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
