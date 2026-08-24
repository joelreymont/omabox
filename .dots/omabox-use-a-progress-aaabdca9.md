---
title: Use a progress-resetting download timeout
status: active
priority: 0
issue-type: task
created-at: "\"2026-08-24T23:10:01.755709+02:00\""
---

Problem: a live progressing download was killed exactly at the one-hour global deadline, discarding its unnamed staging file.
Acceptance: exact downloads retain the 15-second connect timeout, replace the end-to-end deadline with a one-hour receive-body inactivity timeout, and have a focused configuration test. No journal, retry, or protocol changes.
Files: src/dropbox.rs and focused tests there.
Verify: cargo +nightly fmt --check; focused test; cargo +nightly clippy --all-targets --all-features -- -D warnings; cargo +nightly test --all-targets --all-features; forbidden panic/unwrap scan.
Depends: none.
Ownership: download timeout semantics only; resumable downloads are separate work.
