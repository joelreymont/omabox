---
title: Upload large files with Dropbox sessions
status: active
priority: 1
issue-type: task
created-at: "\"2026-08-24T23:15:02.284311+02:00\""
---

Problem: uploads above Dropbox’s 150 MiB direct-upload limit fail instead of syncing.
Acceptance: keep direct uploads unchanged through 150 MiB; above that, stream the immutable verified stage through one sequential Dropbox upload session using bounded 32 MiB chunks, documented start/append_v2/finish calls, strict no-autorename and revision-conditional commit fields, the documented maximum size, typed incorrect-offset recovery, and existing ambiguous-finish verification. A crash may safely restart from byte zero; do not persist session state or add journal schema. Never log the session ID.
Files: src/dropbox.rs and focused fake/property/live tests only.
Verify: focused boundary and fake-protocol tests; cargo +nightly fmt --check; cargo +nightly clippy --all-targets --all-features -- -D warnings; cargo +nightly test --all-targets --all-features; forbidden panic/unwrap scan.
Depends: none.
Ownership: Dropbox upload transport for large immutable staged files only; no concurrency, journal, reconciliation, or UI changes.
