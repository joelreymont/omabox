---
title: Isolate unavailable downloads with durable per-path retry
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-09-04T21:20:46.161126+02:00\\\"\""
closed-at: "2026-09-04T21:53:55.564074+02:00"
close-reason: "landed and verified: Astra reviewed worker identity, fresh-observation retry ordering, blocked checkpoint retention and preserved malformed-response coverage; cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test (290 tests) and forbidden Rust scan passed; DownloadExecutor TLC (1548 distinct states), SyncBehavior TLC (102) and DownloadLifecycle TLC (543401) passed"
blocks:
  - omabox-retire-obsolete-installs-5bc2d6f3
---

Problem: a download 409, verification mismatch, or occupied stage cancels the pool and aborts all sync, while its plan survives restart. Acceptance: expected permanent download failures durably block only their plan with a bounded retry deadline; auth, rate-limit, transport and server failures retain their existing global disposition; blocked plans survive reopen, do not retry early, retry when due, and supersede on changed fresh decisions; sibling upload and download complete; blocked paths are visible in CLI status. Files: src/reconcile.rs, src/status.rs, tests/dropbox_fake.rs, focused status tests; src/recovery.rs only if a shared blocker requires it. Verify: real pool/reconciler fake tests for 409 with sibling work, persistence, no early retry, due retry and changed-decision recovery; Rust gates; DownloadExecutor and SyncBehavior TLC. Depends: omabox-retire-obsolete-installs-5bc2d6f3 and omabox-keep-local-replay-f17c6df3 (fan-in). Ownership: Sol download agent in isolated review-download workspace; excludes the broader open per-path-remediation dot and existing slot-leasing work.
