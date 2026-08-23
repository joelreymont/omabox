---
title: Implement Dropbox auth and reads
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-23T20:47:57.767481+02:00\\\"\""
closed-at: "2026-08-24T00:38:26.361421+02:00"
close-reason: landed 0b0a2e5e, 4f90459f, 376dfb6a, and ab087781; two Sol verification passes; fmt, strict Clippy, all-target/all-feature tests, docs, and ARM64 check passed
blocks:
  - omabox-build-crash-safe-946fe236
---

Problem: Omabox needs documented OAuth and a remote observation stream without turning partial API state into absence. Acceptance: PKCE setup, Secret Service refresh-token storage, refresh, account/root validation, paginated inventory, durable cursor continuation/reset, long-poll wakeups, and exact-revision hash-verified downloads work behind a testable HTTP seam. Files: src/auth.rs, src/dropbox.rs, read/auth portions of tests/dropbox_fake.rs and tests/dropbox_live.rs. Verify: cargo test --test dropbox_fake; cargo test dropbox auth. Depends: local operations dot. Ownership: authentication and Dropbox read protocol.
