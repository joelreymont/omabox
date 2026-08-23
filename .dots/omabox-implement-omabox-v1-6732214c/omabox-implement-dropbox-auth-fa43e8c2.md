---
title: Implement Dropbox auth and reads
status: open
priority: 2
issue-type: task
created-at: "2026-08-23T20:47:57.767481+02:00"
blocks:
  - omabox-build-crash-safe-946fe236
---

Problem: Omabox needs documented OAuth and a remote observation stream without turning partial API state into absence. Acceptance: PKCE setup, Secret Service refresh-token storage, refresh, account/root validation, paginated inventory, durable cursor continuation/reset, long-poll wakeups, and exact-revision hash-verified downloads work behind a testable HTTP seam. Files: src/auth.rs, src/dropbox.rs, read/auth portions of tests/dropbox_fake.rs and tests/dropbox_live.rs. Verify: cargo test --test dropbox_fake; cargo test dropbox auth. Depends: local operations dot. Ownership: authentication and Dropbox read protocol.
