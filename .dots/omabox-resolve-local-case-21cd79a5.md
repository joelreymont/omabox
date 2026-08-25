---
title: Resolve local case collisions automatically
status: active
priority: 0
issue-type: task
created-at: "\"2026-08-25T10:27:22.713851+02:00\""
---

Problem: a complete local scan containing two paths with one Dropbox case-insensitive identity currently returns fatal LocalCaseCollision and systemd restart-loops. Acceptance: before remote refresh or planning, deterministically keep one spelling and atomically rename one colliding local sibling to a Dropbox-canonically unique ' (case variant [N])' name under the active root; preserve files, directories, and all bytes; never overwrite a raced or unknown destination; fsync the parent; retry from a fresh complete scan; and allow both trees to sync. Resolve one collision per pass so nested collisions converge. Crash before or after the rename must recover automatically with no new journal state or user command. Tests: files, directory trees, existing suffix/canonical collision, source and destination races, restart/idempotence, no plan before a clean rescan, and a Credit/credit-style fixture. No conflict UI, quarantine, generic rename framework, DB schema, or user recovery command. Files: src/local.rs, src/reconcile.rs, focused tests. Verify: cargo fmt --check; focused Rust tests; cargo clippy --all-targets -- -D warnings; cargo test; forbidden-pattern scan. Depends: existing active-root validation and transactional scan publication. Ownership: this dot owns only automatic local case-collision detection and rename recovery.
