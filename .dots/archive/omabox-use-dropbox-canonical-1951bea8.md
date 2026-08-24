---
title: Use Dropbox canonical path identity
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-08-24T22:49:59.806474+02:00\\\"\""
closed-at: "2026-08-24T23:08:22.479803+02:00"
close-reason: "landed and verified in e3e775ab: v4 canonical/display identity migration, collision safety, case-only convergence, 139 tests, strict Clippy, fmt, forbidden scan, and Sol review all pass"
---

Problem: journal/planner identity follows display casing even though Dropbox paths are case-insensitive, so case-only changes and local Foo/foo collisions can produce destructive misplans. Acceptance: remote observations are keyed by Dropbox canonical path identity while preserving display spelling; local case-fold collisions never produce a destructive plan; case-only remote changes converge safely; focused fake/property/migration tests cover these cases. Avoid generic path abstractions or unrelated Unicode machinery. Files: migrations/0004.sql, src/{dropbox,journal,reconcile,status}.rs, and focused tests. Verify: full Rust gates, migration/reopen tests, fake Dropbox cases, property tests, and forbidden-pattern scan. Depends: none. Ownership: canonical identity, display spelling, and collision detection only; no case-rename operation.
