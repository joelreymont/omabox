---
title: Add the transactional journal
status: open
priority: 2
issue-type: task
created-at: "2026-08-23T20:47:57.627049+02:00"
blocks:
  - omabox-implement-the-pure-1d820aba
---

Problem: baselines, complete observations, cursors, revisions, operations, conflicts, and recovery records must survive crashes transactionally. Acceptance: SQLite migration and typed journal API persist those records, journal intent before effects, commit baselines only with completed operations, reject secrets, and reopen cleanly after interruption. Files: migrations/0001.sql, src/journal.rs, journal-focused tests. Verify: cargo test journal. Depends: planner dot. Ownership: SQLite schema and journal API.
