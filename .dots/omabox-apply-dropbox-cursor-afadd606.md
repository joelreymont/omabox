---
title: Apply Dropbox cursor deltas
status: active
priority: 0
issue-type: task
created-at: "\"2026-08-24T23:42:15.788967+02:00\""
blocks:
  - omabox-synchronize-directories-as-e5c2cb99
---

Measured problem: every changed Dropbox cursor discards the returned delta and performs a full recursive /files/list_folder plus delete/reinsert of the complete inventory. Acceptance: consume all list_folder/continue delta pages, apply them to the durable snapshot, and transactionally publish only changed/deleted rows plus the final cursor after every page validates; an empty delta updates only the cursor. Cursor reset alone rebuilds via full listing. A one-file delta over 10,000 records performs no /files/list_folder request and O(1) row mutations; a later-page error leaves cursor/inventory byte-for-byte unchanged. No schema, background database writer, or SQLite tuning.
