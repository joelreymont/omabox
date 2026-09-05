---
title: Avoid unchanged inventory writes and repeated account validation
status: active
priority: 2
issue-type: task
created-at: "\"2026-09-05T10:30:06.414310+03:00\""
blocks:
  - omabox-preserve-sync-history-d24798cd
---

Problem: idle scans rewrite complete local inventory/hash tables and each refresh repeats account validation. Acceptance: an unchanged scan performs no observation/hash mutations; changed scans remain atomic and reject stale root binding; a successfully validated immutable client validates account/root once per session while every journal binding remains checked; a fresh client validates anew. Measure current versus new release idle cost on a generated tree and record results. Files: src/journal.rs local scan publication, src/dropbox.rs validation/refresh, focused tests and docs/performance.md. Verify: SQL mutation counts unchanged0, real fake server validates once across multiple refreshes and anew with new client, changed scan rollback/root checks, measured release before/after, Rust gates and InventoryPublication TLC. Depends: root lifecycle fix. Ownership: Sol root lane follow-up. Start with no-op scan detection; no new watcher, transport migration, concurrency or general benchmark framework.
