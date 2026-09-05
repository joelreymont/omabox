---
title: Avoid unchanged inventory writes and repeated account validation
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T10:30:06.414310+03:00\\\"\""
closed-at: "2026-09-05T11:06:04.195189+03:00"
close-reason: "landed and verified: Astra reviewed no-op scan detection and per-session validation cache with journal checks retained; unchanged publication makes zero SQL row changes, stale-root/failed writes preserve prior snapshot, fresh client and failed validation recheck. Release 10k median 138 to 53ms and 50k 496 to 262ms, reproducible harness/results in docs/performance.md. Combined daemon/readiness/idle fmt, clippy all targets -D warnings, full cargo test pass; InventoryPublication TLC 50 states passes."
blocks:
  - omabox-preserve-sync-history-d24798cd
---

Problem: idle scans rewrite complete local inventory/hash tables and each refresh repeats account validation. Acceptance: an unchanged scan performs no observation/hash mutations; changed scans remain atomic and reject stale root binding; a successfully validated immutable client validates account/root once per session while every journal binding remains checked; a fresh client validates anew. Measure current versus new release idle cost on a generated tree and record results. Files: src/journal.rs local scan publication, src/dropbox.rs validation/refresh, focused tests and docs/performance.md. Verify: SQL mutation counts unchanged0, real fake server validates once across multiple refreshes and anew with new client, changed scan rollback/root checks, measured release before/after, Rust gates and InventoryPublication TLC. Depends: root lifecycle fix. Ownership: Sol root lane follow-up. Start with no-op scan detection; no new watcher, transport migration, concurrency or general benchmark framework.
