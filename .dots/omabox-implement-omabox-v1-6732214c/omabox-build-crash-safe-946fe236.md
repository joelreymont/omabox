---
title: Build crash-safe local operations
status: open
priority: 2
issue-type: task
created-at: "2026-08-23T20:47:57.699622+02:00"
blocks:
  - omabox-add-the-transactional-c8256b3a
---

Problem: local scans and mutations must not escape the root, infer uncertain deletion, or lose displaced payloads. Acceptance: root-confined complete scans, immutable upload staging, same-filesystem verified download staging, atomic install, verified recovery copies, deterministic conflict destinations, interruption points, and automatic replay are implemented. Files: src/local.rs, src/recovery.rs, tests/crash_recovery.rs. Verify: cargo test --test crash_recovery; cargo test local recovery. Depends: journal dot. Ownership: local filesystem and recovery engine.
