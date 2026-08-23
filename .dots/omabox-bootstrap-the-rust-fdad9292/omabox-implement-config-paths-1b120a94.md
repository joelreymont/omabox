---
title: Implement config paths locking and logging
status: open
priority: 2
issue-type: task
created-at: "2026-08-23T20:52:43.501713+02:00"
blocks:
  - omabox-establish-the-rust-a22aa517
---

Problem: the service needs validated XDG paths, non-secret configuration, safe logs, and a kernel-released single-instance lock. Acceptance: config/state/recovery paths are resolved and state-inside-root is rejected; configuration errors are typed and user-facing; logs redact secrets; a second daemon instance fails cleanly without stale lock files. Files: src/config.rs and minimal wiring in src/lib.rs and binaries. Verify: cargo test config; cargo test lock; cargo clippy --all-targets -- -D warnings. Depends: Rust package foundation dot. Ownership: configuration, path validation, locking, and logging.
