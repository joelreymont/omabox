---
title: Port LOCAL
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T23:47:22.865909+02:00"
---

Problem: the Habu daemon needs local.rs's scan, hash, stage, install and guarded delete (docs/habu-rewrite.md LOCAL row) to sync real files. Acceptance: src/local.f ports local.rs's production words on Habu's anchored file words, one task doing the sync (no SyncRootAccess, no parallel hashing, one download at a time on the Rust daemon's slot pool and xattr markers, which stay compatible); local.rs's tests pass under their names in src/local-test.f, a test of parallel workers or the scan lock dropped with a comment. Depends: none. Claim: unassigned.
