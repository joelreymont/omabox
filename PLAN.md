# Omabox production plan

## Outcome

Ship an ARM64-first personal Dropbox client in Rust nightly. It keeps ordinary
files local, authenticates once through Dropbox OAuth, runs unattended as a
systemd user service, and exposes useful CLI and Omarchy widget status.

## Boundaries

- One Rust package with separate `omaboxd` and `omabox` binaries.
- One account, one local root, and one Dropbox root.
- Regular files and directories; no virtual filesystem, selective sync,
  multi-account service, updater daemon, or daemon IPC.
- Bounded local concurrency only where measurement shows benefit.

## Non-negotiable safety

- Persist sync intent and baseline state transactionally in SQLite.
- Never infer deletion from incomplete, inaccessible, uncertain, or stale data.
- Stage and hash downloads, then install them by same-filesystem atomic rename.
- Stage immutable uploads and condition replacement/deletion on the known
  Dropbox revision.
- Preserve every genuinely divergent local and Dropbox payload as synchronized
  conflict copies; never choose a conflict side destructively.
- Treat a newly configured empty local root as a new root generation, not as
  evidence that remote content was deleted.

## Implementation sequence

1. Finish exact-revision interrupted-download resume and replay the verified
   large staged download already on disk.
2. Keep scanning and remote refresh responsive during transfers with one
   daemon-owned pool capped at four workers. Reuse one Dropbox content agent and
   coalesce staging writes. Add concurrency only after profiling.
3. Synchronize directories with parents before children and safe, non-recursive
   removal on both sides; a Dropbox folder is deleted only once its inventory
   subtree is empty and a listing immediately before the delete agrees. Apply Dropbox cursor deltas transactionally; reserve recursive
   relisting for initial state and cursor reset.
4. Finish rootless install, upgrade, and uninstall for the two binaries, user
   unit, and packaged Omarchy plugin. Preserve service state, roll back before a
   replacement daemon launches, retain all user data on uninstall, and never
   publish live plugin files while the shell is locked.
5. Complete the Omarchy dashboard: current transfers, aggregate progress and
   speed, a short in-memory bandwidth chart, sync-root selection, setup/help,
   and service controls. Do not expose states that have no user action.
6. Build release artifacts, install them atomically, replay pending work, and
   verify service health, widget status, and upgrade/uninstall behavior.

## Verification

- Property tests cover planner invariants and generated state transitions.
- Snapshot tests cover stable human-readable decisions and status only.
- Crash tests cover journal/effect boundaries and automatic replay.
- Fake Dropbox tests cover pagination, cursor reset, rate limits, revision
  conflicts, corruption, and interrupted/resumed transfers.
- Live Dropbox tests remain opt-in and isolated from committed credentials.
- Run formatting, Clippy with warnings denied, the full test suite, and TLC
  after durable download replay changes. Profile release builds before and
  after performance changes.
