# The rest of the Habu rewrite

Everything above the Dropbox vocabulary (`docs/habu-dropbox.md`). The Habu
`omaboxd` and `omabox` replace the Rust ones in place. They keep the
journal, credential record, `config.toml`, CLI, `status.json` v3, unit and
widget.

## Habu libraries

General code goes into Habu's `src/lib`; sync policy stays here.

- **`SQLITE`:** libsqlite3 on Habu's database model (Habu `docs/design.md`,
  "Databases"): result types, one connection per task, a busy timeout,
  `BEGIN IMMEDIATE`.
- **`FS-ANCHORED`:** the openat2 calls `src/local.rs` makes, each relative to
  a directory descriptor and never following a symlink. They open, create,
  rename (with and without replace), unlink, make and remove directories, list,
  stat, fsync and chmod, plus O_TMPFILE named by linkat.
- **`XATTR`:** get, set and erase, for the stage and partial markers
  (`src/local.rs:38`).
- **statx:** birth time and subvolume, which the root binding stores.
- **`SECRET`:** write and erase on Linux, on omabox's attributes
  (`src/auth.rs:30`).

SHA-256 is already in Habu core (`src/core/sha256.f`). Inotify is not added:
the Rust daemon rescans after each 30 s long poll, and a watcher waits for the
rule in `docs/remediation-2026-09.md` K.

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
- **One task does the sync.** Downloads and hashing run one at a time. The
  Rust daemon's four download workers and parallel hashing come back only for a
  measured need.
- **Failures.** Each pending plan runs under one catch: a path's failure
  blocks that plan; a transport, journal or root failure ends the pass. One
  table maps each code and `DROPBOX:reply` to a disposition and status text.
- **Machines.** `DAEMON:RUN`, `RECONCILE:PASS` and a `REPLAY` operation are
  `fsm.f` tables named after their `formal/` models.
- **Upload progress.** `DROPBOX:UPLOAD` takes a quotation `[ n -- ]`, called
  with the bytes Dropbox has accepted.

## Tests

- The 105 tests of `tests/dropbox_fake.rs`, ported under their names, each
  running `RECONCILE:PASS` against the fake Dropbox.
- The planner's table against Rust's.
- A Habu-made schema against a Rust-made one (`sqlite_master`), and a journal
  the Rust daemon wrote, read back.
- Startup and crash tests of the built `omaboxd`.

## Order

1. The vocabulary, JSON header mode, `CURL:RESET`.
2. Habu's libraries; in parallel, `MODEL`, `PLANNER`, `CONFIG`, `STATUS`.
3. One Habu install.
4. `JOURNAL`, `LOCAL`, `AUTH`.
5. `REPLAY`, then `RECONCILE` with the ported tests.
6. `DAEMON`, `omaboxd`, `build.f`.
7. Cutover of the daemon; the Rust CLI keeps working. Reinstalling the Rust
   `omaboxd` is the way back.
8. CLI, installer, service; then the Rust tree goes.
