# Omabox implementation plan

## Goal and first-release scope

Build an ARM64-first, bidirectional Dropbox sync service in Rust nightly. It
keeps ordinary files local, authenticates once through Dropbox's documented
OAuth flow, and then runs unattended as a systemd user service.

The first release supports one Dropbox account, one local/remote root, regular
files and directories, recursive sync, a headless daemon, and a separate
setup/status CLI. The explicit Rust choice supersedes the repository's earlier
Go direction; update `AGENTS.md` before implementation so its development
commands match Rust while preserving its product and safety rules.

Deliberately defer selective sync, multiple accounts or roots, symlinks and
special files, metadata replication, rename optimization, remote folder
deletion, and QML integration. Report unsupported or inaccessible objects as
blocked; never reinterpret them as deletions.

## Minimal architecture

Use one Rust package, not a workspace:

- `src/bin/omaboxd.rs`: headless reconciliation daemon.
- `src/bin/omabox.rs`: browser setup and read-only status CLI.
- `src/{config,auth,dropbox,local,journal,planner,reconcile,recovery,status}.rs`:
  small modules with one concern each.
- `migrations/0001.sql`: the transactional SQLite journal.
- `packaging/systemd/omabox.service`: systemd user unit.
- `tests/`: focused property, snapshot, crash-recovery, fake-API, and live-API
  tests.

Pin a dated nightly toolchain in `rust-toolchain.toml` with the formatter,
linter, and ARM64 target. Keep configuration under the XDG config directory and
the journal, upload staging area, and recovery data under the XDG state directory.
Reject a state directory that is inside the sync root.

Use Dropbox's documented HTTP API and OAuth 2.0 with PKCE. Store the refresh
token in the user's Secret Service, never in configuration, the journal, logs,
fixtures, snapshots, or commits.

Run one reconciliation and mutation loop. Filesystem notifications and Dropbox
long-polling may wake it, but decisions come only from a complete local scan,
durable remote cursor/inventory state, and the last common baseline. Do not add
an IPC service, a multi-crate split, or concurrent mutations until a measured
need requires one.

## Safety contract

These rules are implementation requirements:

- Store baselines, complete observations, Dropbox cursors and revisions,
  planned operations, conflicts, and recovery records in a transactional
  journal. Write an operation and its preconditions before its side effects;
  advance the baseline only after durable completion.
- Represent an observation as present, confirmed absent, or unknown. An
  incomplete scan, inaccessible path or root, API/network failure, partial or
  stale listing, and cursor reset all produce unknown state and cannot produce
  a deletion.
- Download to a same-filesystem staging file, verify the Dropbox content hash,
  fsync it, and install it with an atomic rename. Fsync the containing directory
  before declaring the operation complete.
- Upload immutable staged bytes. Create new remote files with strict
  no-autorename semantics; replace existing files only when the last known
  Dropbox revision still matches.
- Make remote file deletion conditional on the last known revision. Do not
  delete remote folders in this release. Remove a local directory only after an
  explicit remote deletion and only while it remains empty.
- Before deleting or replacing content, save and verify the displaced payload
  in the recovery area. Preserve all distinct local and remote payloads on a
  conflict; never choose one destructively or overwrite a conflict copy.
- On startup, take a kernel-released single-instance lock and automatically
  replay or safely replan every unfinished journaled operation. Users must
  never repair locks, journals, staging files, or recovery data manually.

## Implementation sequence

1. **Bootstrap**

   - Update `AGENTS.md`, add `Cargo.toml`, `rust-toolchain.toml`, the two
     binaries, module skeletons, and the systemd unit.
   - Implement validated XDG paths, configuration loading, instance locking,
     and structured logs with secret redaction.

2. **Journal and pure planner**

   - Add the SQLite migration and typed journal API for the baseline,
     observations, cursor/revisions, operations, conflicts, and recovery
     records.
   - Implement the planner as a pure mapping from baseline plus local and remote
     observations to ordered operations or a blocked reason.
   - Enforce no-delete-from-unknown and revision preconditions in the planner's
     types and persistence boundary.

3. **Crash-safe local filesystem**

   - Scan without following symlinks or escaping the configured root. A scan is
     usable for absence decisions only after the whole root completes.
   - Implement immutable upload staging, verified download staging, atomic
     installation, recovery copies, and durable conflict destinations.
   - Add explicit interruption points around journal commits, filesystem
     changes, and fsyncs so recovery behavior can be tested.

4. **Dropbox authentication and reads**

   - Implement browser OAuth with PKCE, Secret Service token storage and
     refresh, account/root validation, paginated listing, durable cursors,
     long-poll wakeups, and exact-revision downloads.
   - Publish a new remote inventory only after every page is complete. Rebuild
     after a cursor reset without treating temporarily missing entries as
     deleted.

5. **Conditional writes, deletion, and conflicts**

   - Implement strict create, revision-conditional replace, directory creation,
     and revision-conditional remote file deletion.
   - If a precondition fails, preserve the staged local payload, fetch the
     current remote payload, and materialize a deterministic conflict without
     overwriting either side.
   - Make every mutating operation retry-safe through its journal record and
     automatic startup replay.

6. **Service and CLI**

   - Run initial and wake-triggered reconciliation from `omaboxd`; on shutdown,
     finish or leave the current operation in a replayable journal state.
   - Let `omabox` perform setup and read status directly from durable state.
     Status must explain blocked paths, conflicts, and recovery activity without
     exposing secrets.

## Verification

- Use ordinary unit tests for journal transactions, hashing, path validation,
  revision preconditions, and planner examples.
- In `tests/planner_properties.rs`, use `proptest` to generate baselines and
  observation sequences. Assert that unknown state never deletes data,
  replacement/deletion operations retain the expected revision, replay is
  idempotent, and every distinct conflicting payload remains recoverable.
- In `tests/planner_snapshots.rs`, use `insta` only for stable,
  human-readable planner decisions and CLI status. Redact paths, time, IDs, and
  secrets; do not snapshot database rows or other implementation details.
- In `tests/crash_recovery.rs`, use temporary directories and interruption
  points to cover every durability boundary for download install, replacement,
  deletion, conflict materialization, and restart replay.
- In `tests/dropbox_fake.rs`, use a local fake server for pagination, cursor
  reset, revision conflicts, corrupt or interrupted transfers, token refresh,
  rate limiting, and retryable failures.
- Keep `tests/dropbox_live.rs` opt-in and confined to a dedicated Dropbox test
  account and folder. Never store its credentials.
- Before landing a change, run `cargo fmt --check`,
  `cargo clippy --all-targets --all-features -- -D warnings`, and
  `cargo test`. Run the non-live suite on ARM64 and keep `jj` commits small
  and focused.

## Acceptance criteria

- One-time browser authentication followed by the user service synchronizes
  regular files in both directions while keeping real local files.
- Downloads are verified and atomically installed; remote replacements and file
  deletions are revision-conditional.
- Crashes and retries converge automatically without stale locks or recovery
  commands.
- Conflicts, uncertain observations, deletion, and replacement cannot discard
  the only copy of user data.
- Property, snapshot, crash-recovery, fake-API, and isolated live-API tests pass
  in their intended environments without leaking secrets.
