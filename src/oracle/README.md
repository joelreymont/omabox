# The Rust version's test answers

- `json.tsv`: `<type>.<variant>`, then serde's JSON for it; `.escapes`
  lines pin string escapes.
- `plan.tsv`: the planner's inputs (baseline, local, remote, subtree) as
  JSON, then its decision.
- `fold.tsv`: a display path in hex, then `CanonicalPath::from_display` of
  it in hex.

Written by `OMABOX_ORACLE=<dir> cargo test oracle -- --ignored` at `rust`
commit `abb0d2fe8ab165983c02714f1338e07eb08ffcf5` (`src/journal/oracle.rs`).
