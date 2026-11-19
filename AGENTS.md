# Omabox

Native, ARM64-first Dropbox sync for Omarchy in Habu, against Dropbox's
documented API and OAuth flow. `docs/habu-rewrite.md` is the plan for the
rewrite and `JOURNAL.md` records it.

## Scope

- Run unattended as a systemd user service after one browser login.
- Keep real local files; do not implement a virtual filesystem.
- Keep the daemon headless and CLI/QML concerns separate.
- Prefer the smallest direct mechanism. Add architecture only for a measured need.

## Safety

- Record sync state in a durable, transactional journal.
- Stage and verify downloads; install with atomic renames.
- Make uploads conditional on the last known Dropbox revision.
- Preserve every conflict payload; never resolve destructively.
- Never infer deletions from uncertain, partial, stale, or inaccessible state.
- Recover automatically; users never manage locks, stale state, or recovery.

## Changes

- Write Habu as Habu's `docs/forth-card.md` says; repository rules may be
  stricter.
- Use `jj`. Make one commit per feature or significant fix and include its dot
  closure in that commit.
- Rebase every open line of work onto `master` periodically, and before it
  merges, so it never drifts far from `master`.
- Before landing, run the tests (`src/*-test.f`) of every package the change
  touches.
- With the user's approval, run the relevant TLC model after changing
  durable replay or concurrency. The tests that check an FSM table
  against its model run TLC themselves, with the user's standing
  approval (2026-11-17); any other TLC run still needs it.
- Keep real Dropbox tests opt-in and separate from unit tests.
- Classify and test every external/filesystem failure. Repeated bad input must
  neither crash-loop nor stop unrelated work.
- Never weaken a safety invariant to make a test pass.
- Never commit credentials, tokens, test accounts, or other secrets.
- Hold growable bytes in Habu's `VEC:vector<u8>`, never in BUF, and read JSON
  with Habu's JSON values (`JSON:value`), never the cursor reader
  (`JSON:READ-*`). Code that still uses either moves once Habu lands the
  replacement.
