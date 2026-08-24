---
title: Use a progress-resetting download timeout
status: closed
priority: 0
issue-type: task
created-at: "\"\\\"2026-08-24T23:10:01.755709+02:00\\\"\""
closed-at: "2026-08-24T23:12:11.461693+02:00"
close-reason: Exact downloads now use a 15s connect timeout and a 1h progress-resetting receive-body timeout; focused test, full suite, Clippy, fmt, doctests, forbidden scan, and Sol review are clean.
---

Problem: a live progressing download was killed exactly at the one-hour global deadline, discarding its unnamed staging file.
Acceptance: exact downloads retain the 15-second connect timeout, replace the end-to-end deadline with a one-hour receive-body inactivity timeout, and have a focused configuration test. No journal, retry, or protocol changes.
Files: src/dropbox.rs and focused tests there.
Verify: cargo +nightly fmt --check; focused test; cargo +nightly clippy --all-targets --all-features -- -D warnings; cargo +nightly test --all-targets --all-features; forbidden panic/unwrap scan.
Depends: none.
Ownership: download timeout semantics only; resumable downloads are separate work.
