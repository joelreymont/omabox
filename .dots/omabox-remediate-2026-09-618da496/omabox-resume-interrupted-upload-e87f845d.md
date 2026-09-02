---
title: Resume interrupted upload sessions from the journal
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T17:12:47.641414+02:00"
blocks:
  - omabox-journal-schema-ver-487764f0
  - omabox-move-the-dropbox-cb30bc34
---

Problem: an interrupted large upload restarts from zero after a daemon restart because upload_session state lives only in memory; an ambiguous finish must never be repeated blindly. Design: docs/remediation-2026-09.md section J, 'Durable upload sessions'. Acceptance: after every accepted append the journal records session id, confirmed offset, source fingerprint, expected baseline revision, and hash progress in one transaction keyed by the plan's operation; replay resumes from the record, reconciles incorrect_offset against it and the local bytes, and restarts from zero only when the server no longer knows the session; an ambiguous finish is verified by metadata and never re-issued blindly; a finish that timed out never opens a replacement session; migration adds the table in a v7 step; fake tests: crash after two appends then resume completes with exactly the remaining appends; incorrect_offset below and above the record; unknown session; timed-out finish followed by verification. Files: migrations/0007.sql, src/journal.rs, src/dropbox.rs, src/recovery.rs, tests/dropbox_fake.rs, tests/crash_recovery.rs, formal/MutationLifecycle.tla (if the finish state changes). Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test; TLC MutationLifecycle. Depends: schema, sdk-transport. Ownership: upload session durability. Claim: unassigned.
