# The Rust version's test answers

- `json.tsv`: `<type>.<variant>`, then serde's JSON for it; `.escapes`
  lines pin string escapes.
- `plan.tsv`: the planner's inputs (baseline, local, remote, subtree) as
  JSON, then its decision.
- `fold.tsv`: a display path in hex, then `CanonicalPath::from_display` of
  it in hex.
- `schema.tsv`: a fresh journal's `sqlite_master` in `rowid` order (`type`,
  `name`, `tbl_name`, `sql`; NULL empty; `\n`, `\t`, `\\` escaped), then
  `user_version`.
- `journal.sqlite3`: a schema-8 journal written through `Journal`, a row in
  every table but `legacy_local_root_adoption`, which only a migration fills.
  `recovery_records.retained_at` holds the clock (`unixepoch()`).
- `journal.tsv`: each public read of `journal.sqlite3`, then its answer as
  Rust's `{:?}`; `completed_recoveries` carries that clock.

Written by `OMABOX_ORACLE=<dir> cargo test oracle -- --ignored` at `rust`
commit `e3c161352d0ddca750059a1ef7aea4f7c7cce811` (`src/journal/oracle.rs`).
