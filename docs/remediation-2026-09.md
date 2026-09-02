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
- Partial index `remote_directories ON remote_observations(canonical_path)
  WHERE observation_json = '"Directory"'`.

Nothing else changes: `canonical_path` stays nullable in the schema and
non-null by construction in every Rust write path; conflicts need no new
columns because copy names are deterministic (section H).

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

Mount points (M11): the sync root is one filesystem. A directory whose
`st_dev` differs from the sync root's device is published as
`Unknown(Unsupported)` and nothing beneath it is scanned, exactly like a
symlink. Content on another volume is therefore never synchronized, so an
unmounted mount point is an ordinary empty directory with no baselines beneath
it and nothing to infer. This also keeps the same-filesystem atomic-rename
install guarantee true for the whole root. `omabox status` lists such
directories as unsupported.

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
  credential or journal binding changed, refresh token rejected (400 on
  refresh). The daemon publishes the fatal status and exits 78.
- Invariant: `InvalidJournalState` and other bugs exit 70.
- `last_error` is cleared only when a pass completes with zero sync errors.
- Launch observability without a readiness protocol: the unit becomes
  `Type=exec`, so `systemctl start`/`restart` fails when the binary cannot be
  executed; `omaboxd --self-check` prints the version and exits 0 without
  touching state, and `install` runs it on the staged binary before
  publishing; after a restart, `install` polls `is-active` for up to 10 s and
  treats an inactive or failed unit as a launch failure. Credential and
  account problems surface through the published status, not the launch.
- Unit: `RestartPreventExitStatus=70 78`, `StartLimitIntervalSec=10min`,
  `StartLimitBurst=5`, `After=graphical-session.target`,
  `ExecStopPost=-/usr/bin/rm -f %t/omabox/status.json`. The daemon removes
  `status.json` on clean exit.
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
  record; the root itself restricted stays `RemoteRootRestricted`.
- Downloadable file without `content_hash` or `rev`: `Unknown(Incomplete)`.
- `display.to_lowercase() != path_lower`: `Unknown(Unsupported)` record keyed
  by Dropbox's `path_lower`, logged once per path; never an error.
  `validate_mutation_path` compares against the canonical form the same way and
  reports `MutationRejection` rather than an error.
- An entry whose `path_lower` equals the root is skipped; a `deleted` entry for
  the root is `RemoteRootUnavailable`.
- `remove_subtree` deletes the key and the `key/`…`key/\u{10FFFF}` range;
  `normalize_inventory_records` runs once after the last page.

## J. Client hygiene (M9, minors)

- Download agent: `timeout_send_request` and `timeout_recv_response` =
  `JSON_REQUEST_SECONDS`, `timeout_recv_body` = 60 s idle.
- One content agent and one long-poll agent per `DropboxClient`; per-request
  timeouts via ureq's request-level config.
- `UPLOAD_SESSION_MAX_BYTES` = 350 GB (decimal, documented).
- `ascii_json` escapes bytes below 0x20 and 0x7F as `\u00XX`.
- `append_v2` sends the chunk's `content_hash`; a failed append retry chains
  the first error as context; already-staged download outcomes drop the
  response instead of draining it; an unparsable `Content-Length` is a header
  error; `Retry-After` accepts the HTTP-date form; `resolve_ambiguous` chains
  the verification error.
- `auth.rs`: child cleanup errors are chained into the primary error; `EPIPE`
  on write reports the child's exit status.

## K. Idle pass cost (M6)

- `publish_local_scan` reads the existing inventory and hash cache in canonical
  order, merges with the new scan, and writes only inserted, updated, or
  deleted rows.
- `pending_plans` is one join and is loaded once per pass and passed through.
- `validate_account` runs once per session and after a 401; `refresh_inventory`
  no longer calls it.
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
  with the root on `/tmp` and staging on `/dev/shm`; an `#[ignore]`d test that
  runs `qmltestrunner` against the plugin tests, documented in README under
  Develop.
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
Wave 1 (after A): B, C, E, G, I, J, L-install, L-config-physical, M, N-planner-and-fixtures.
Wave 2: D (B, C, E, G), F (B, E), H (B, G), K (B, J), L-cli (F), N-daemon-tests (D, E, F, H, I).
Wave 3: O.

## Simplifications after review

Compared with the first draft: no readiness protocol (`Type=exec` plus a
self-check and an `is-active` poll observe launch); no per-directory device
history or adopt command (mount points are unsupported, like symlinks); no
journal-recorded conflict names (deterministic readable names keep the
existing idempotence); no WAL switch and no NOT NULL table rebuilds (the
migration touches only `plans`/`operations` and adds one index); fixed
one-second wait instead of an escalating schedule for fresh observations.
