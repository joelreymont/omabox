---
title: Synchronize directories as first-class state
status: closed
priority: 0
issue-type: task
created-at: "\"\\\"2026-08-24T23:26:41.605487+02:00\\\"\""
closed-at: "2026-08-25T12:26:31.445848+02:00"
close-reason: Landed as 2a11f6b6. Schema v5 journals directories; local effects are descriptor-relative, nonrecursive, and race-safe; Dropbox folders are first-class without remote folder deletion; file/directory collisions preserve exact file bytes under deterministic synchronized names. Verified fmt, clippy -D warnings, 201 tests including crash/fake/property/snapshot coverage, diff/forbidden scans, and independent Sol review CLEAN.
blocks:
  - omabox-keep-syncing-during-d75d1f5f
---

Problem: ordinary local and Dropbox directories are persisted as unsupported unknowns, flooding status and preventing empty-directory sync or safe folder-deletion replay.
Acceptance: persist Directory observations/baselines (schema v5) and only CreateLocalDirectory, CreateRemoteDirectory, and nonrecursive DeleteLocalDirectory operations. Create parents before children; remove local directories deepest-first only after complete remote absence; ENOTEMPTY/type races reobserve and supersede stale pending plans without advancing baseline. Never call remote folder delete because Dropbox has no revision-conditional folder deletion. Resolve file/directory collisions automatically with directory winning and the exact file preserved under a deterministic synchronized filename, without a permanent conflict row or user action. No directory metadata/rename optimization.
Files: model/planner/local/dropbox/journal migration/recovery/reconcile/status plus focused tests.
Verify: empty/nested dirs both directions; deepest-first and nonrecursive deletion; type transitions preserve bytes; stale-plan replan; properties forbid remote folder deletion; crash/fake/full Rust gates.
Depends: resumable download change because the files overlap.
Ownership: directory state and transitions only.
