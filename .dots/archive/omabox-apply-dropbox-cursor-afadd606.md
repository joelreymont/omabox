---
title: Apply Dropbox cursor deltas
status: closed
priority: 0
issue-type: task
created-at: "\"\\\"2026-08-24T23:42:15.788967+02:00\\\"\""
closed-at: "2026-08-25T12:40:30.189155+02:00"
close-reason: Landed as cfe58325. All cursor continuation pages validate before one atomic ordered delta/cursor transaction; empty deltas mutate only the cursor; reset alone rebuilds. A 10,000-row one-file delta performs three row mutations, uses the canonical-path index with no table scan, and makes no full-list request. Later-page failures preserve the previous snapshot. Verified fmt, clippy -D warnings, 204 tests, diff/forbidden scans, and independent Sol review CLEAN.
blocks:
  - omabox-synchronize-directories-as-e5c2cb99
---

Measured problem: every changed Dropbox cursor discards the returned delta and performs a full recursive /files/list_folder plus delete/reinsert of the complete inventory. Acceptance: consume all list_folder/continue delta pages, apply them to the durable snapshot, and transactionally publish only changed/deleted rows plus the final cursor after every page validates; an empty delta updates only the cursor. Cursor reset alone rebuilds via full listing. A one-file delta over 10,000 records performs no /files/list_folder request and O(1) row mutations; a later-page error leaves cursor/inventory byte-for-byte unchanged. No schema, background database writer, or SQLite tuning.
