---
title: Keep local replay responsive to substituted special files
status: active
priority: 1
issue-type: task
created-at: "\"2026-09-04T21:20:29.458984+02:00\""
---

Problem: a FIFO substituted for a pending local effect target blocks open before type checking. Acceptance: local effect opens never wait on special files; special objects and ENOTDIR/ELOOP become a per-path replay blocker, preserving bytes and allowing unrelated operations; ordinary regular-file replay and crash recovery remain intact. Files: src/local.rs, src/recovery.rs local replay only, tests/crash_recovery.rs. Verify: bounded FIFO regression through replay plus unrelated effect, symlink and parent-object cases, Rust gates, MutationLifecycle TLC. Depends: none. Ownership: Sol FIFO agent in isolated review-fifo workspace; excludes download slot leasing and remote mutation replay.
