# The rest of the Habu rewrite

Everything above the Dropbox vocabulary (`docs/habu-dropbox.md`). The Habu
`omaboxd` and `omabox` replace the Rust ones in place. They keep the
journal, credential record, `config.toml`, CLI, `status.json` v3, unit and
widget. The Rust version is on the `rust` branch, and every `.rs` path here
names a file there.

## Habu libraries

General code goes into Habu's `src/lib`; sync policy stays here.

- **`SQLITE`:** libsqlite3. A connection belongs to the task that opened it;
  a statement is linear and lives inside `WITH-STATEMENT`; `WITH-TRANSACTION`
  is `BEGIN IMMEDIATE`; the caller sets the busy timeout. Every failure is
  logged once with SQLite's text and throws one of three codes, the classes
  `src/daemon.rs:803-843` tells apart: corrupt (CORRUPT or NOTADB), full, any
  other. The journal passes every failure up, so a result sum would only be
  matched and rethrown; Habu's `pg-rows.f` throws its refusals the same way.
- **`FS-ANCHORED`:** the `*at` calls `src/local.rs` makes, each on one name
  relative to a directory descriptor and never following a symlink: open a
  directory, a file to read or write, or any entry by `O_PATH`; `O_TMPFILE`
  named by linkat; rename with and without replace; remove a file or a
  directory; make a directory; stat. A name is checked as `OPEN-DIR-AT`
  checks one and opened with `O_NOFOLLOW`, which gives what openat2's resolve
  flags give and needs no glibc 2.43. Each answers a bool or an option, with
  errno in `FS:ERRNO`.
- **Descriptor words:** fstat with inode and device, the name length limit,
  chmod, seek, a directory listed by its descriptor, and the errno constants
  `src/local.rs` decides on.
- **`XATTR`:** get, add (create only), set and erase, for the stage and
  partial markers (`src/local.rs:38`).
- **statx:** birth time and subvolume, which the root binding stores.
- **`SECRET`:** write on Linux, as `secret-tool store` writes, under the
  attribute keys and label a program binds once (`src/auth.rs:30`). Nothing
  in the Rust version erases the credential, so there is no erase.
- **`UTF8-LOSSY:REPAIR`:** Rust's `from_utf8_lossy`, for the paths in
  `status.json` (`src/runtime_status.rs:336`).

These take a string as `^u8 n` until Habu's `str` lands; its sweep moves them
with the rest of Habu.

SHA-256 is already in Habu core (`src/core/sha256.f`). Inotify is not added:
the daemon rescans after each 30 s long poll, as the Rust one does, and a
watcher comes only for a measured need.

## Omabox packages

| Package | Does | Rust |
|---|---|---|
| `MODEL` | domain types; stored JSON byte-identical to serde's | `model.rs` |
| `PLANNER` | `PLAN`, a decision table | `planner.rs` |
| `CONFIG` | paths, `config.toml`, the instance lock | `config.rs` |
| `STATUS` | `status.json`, rewritten every 20 s by its own task | `runtime_status.rs` |
| `JOURNAL` | schema 8; a listing publishes in one transaction | `journal.rs` |
| `LOCAL` | scan, hash, stage, install, guarded delete | `local.rs` |
| `AUTH` | the credential record, PKCE | `auth.rs` |
| `REPLAY` | pending plans: intent, guard, effect, complete | `recovery.rs` |
| `RECONCILE` | `PASS`: list, scan, plan, replay, download | `reconcile.rs` |
| `DAEMON` | `RUN`, and one table of failure dispositions | `daemon.rs` |

- **Journal.** Opens schema 8, or creates it from `migrations/`; refuses 1 to
  7. Schema 8 is frozen while the Rust upload-session work stays parked.
- **Values.** `MODEL` holds types, equality and JSON, no state. A display path
  and its Dropbox identity, `FOLD`'s answer, are `DEFTYPE`s over `str`; the
  hash, revision and cursor roles are `DROPBOX`'s. A value travels by value;
  its strings are borrowed, and a reader copies them into the arena the caller
  passes, one per pass. Each stored column type has a writer and a reader of
  serde's bytes; a stored value this version cannot read throws
  `MODEL:E-STORED`.
- **Decisions.** A no-op carries only its baseline, a block is unknown or
  occupied, and an operating decision carries one operation: production reads
  no more (`src/reconcile.rs:1085-1300`). `PLAN` is a nested `MATCH`, its
  exhaustiveness the checker's.
- **`CONFIG`** loads, prepares and locks (flock on the `daemon.lock` the Rust
  daemon locks); its writer comes with the CLI.
- **`STATUS`** keeps one transfer, as one task syncs. Tasks are threads, so
  one `TASK:FACILITY` guards the snapshot the sync task and the heartbeat
  share.
- **One task does the sync.** Downloads and hashing run one at a time, and a
  staged download installs at once. The Rust daemon's four download workers
  and parallel hashing come back only for a measured need.
- **Failures.** A path's failure becomes its plan's block at the call that
  meets it; a transport, journal or root failure ends the pass, and so does a
  local write the system denies, once `LOCAL` has logged the directory that
  denies it and why. One word, `REPLAY:DOWNLOAD-BLOCKAGE`, classifies every
  Dropbox answer that fails a download. One table maps each code and
  `DROPBOX:reply` to a disposition and status text.
- **Machines.** `RECONCILE:PASS`, its listing and its one download, a
  `REPLAY` operation, `DAEMON:RUN`, `SERVICE`'s drive and `DROPBOX`'s
  download and upload session are `fsm.f` tables. Of the `formal/` models,
  `SyncPass` describes the pass's table, `InventoryPublication` the
  listing's, `DownloadExecutor` the download's, `LocalLifecycle` a local
  operation's, `RemoteLifecycle` a remote operation's, `ServiceDrive`
  `SERVICE`'s drive, `DaemonRun` the daemon's run, and `MutationLifecycle`
  what a local operation's apply does; the other tables have none.
- **`RECONCILE:PASS`** answers `complete` with its counts, `fresh` (rescan) or
  `root-changed`; a Dropbox answer that ends it is in the link, as `REPLAY`'s.
  `DAEMON` validates the account, not the pass. Apart from Rust, a download
  refused `locked` blocks its path, and so does a directory collision's copy
  that Dropbox refuses or that fails verification, with every path beneath
  it, for that pass, unplanned, and so does a replayed conflict's remote copy
  whose download fails for its path. An upload Dropbox refuses for a content
  hash mismatch blocks its path too, where Rust ends the pass.
- **Upload progress.** `DROPBOX:UPLOAD` takes a quotation `[ n -- ]`, called
  with the bytes Dropbox has accepted.
- **Install.** An Arch package (`packaging/arch`) replaces Rust's `omabox
  install`, `upgrade` and `uninstall`. Apart from Rust, an upgrade cannot roll
  back: the previous package file makepkg built is the way back. `omabox
  setup` links the Omarchy widget the package installs, before the login.

## Tests

- The tests of `tests/dropbox_fake.rs`, ported under their names, each against
  the fake Dropbox: a pass's through `RECONCILE:PASS`, one word's through that
  word. The four-worker pool's three (:846, :4081, :4194) do not apply; four
  (:7330, :8053, :8073, :8137) are `DAEMON`'s. Three (:3313, :5113, :5220)
  assert what `docs/habu-dropbox.md` changes on purpose: an upload session
  restarts, and REPLAY, not `DROPBOX`, reads back a mutation's conflict or
  5xx.
- The planner's table, every value's JSON and `FOLD` over a case corpus,
  against what the Rust version prints (`src/oracle/`).
- A Habu-made schema against a Rust-made one (`sqlite_master`), and a journal
  the Rust daemon wrote, read back.
- Startup and crash tests of the built `omaboxd`.
- The widget's QML tests, through Qt 6's `qmltestrunner` (README, "Develop").

## Order

1. The vocabulary, JSON header mode, `CURL:RESET`.
2. Habu's libraries; in parallel, `MODEL`, `PLANNER`, `CONFIG`, `STATUS`.
3. One Habu install.
4. `JOURNAL`, `LOCAL`, `AUTH`.
5. `REPLAY`, then `RECONCILE` with the ported tests.
6. `DAEMON` and `omaboxd`.
7. Cutover of the daemon; the Rust CLI keeps working. Reinstalling the Rust
   `omaboxd` is the way back.
8. CLI and service; an Arch package installs them in place of Rust's
   installer.
