---
title: Resume upload sessions from the journal
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:35.994582+02:00"
blocks:
  - omabox-name-the-upload-b7d771a2
  - omabox-record-upload-sessions-eb2dd712
---

Problem: replay always opens a new session from zero and may finish blindly after a lost answer. Acceptance: the machine checkpoints each accepted append, resumes from the record, verifies by metadata before finishing a full record, replaces a session only per section J, and blocks instead of looping on hash mismatch or TooLarge; fake tests: crash after two appends then resume sends only the rest, incorrect_offset below and above the record, unknown session, lost finish answer then verification. Depends: Name the upload session machine; Record upload sessions in the journal. Claim: unassigned.
