---
title: Resume upload sessions from the journal
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:35.994582+02:00"
---

Problem: replay always opens a new session from zero and may finish blindly after a lost answer. Acceptance: the upload machine checkpoints each accepted append, resumes from the recorded session sending only the remaining bytes, verifies by metadata before finishing a full record, and replaces a session only as the session machine in docs/habu-dropbox.md says. On a content hash mismatch or a too-large file the upload blocks instead of looping. Fake tests: a crash after two appends then resume sends only the rest; an offset mismatch below and above the record; an unknown session; a lost finish answer then verification. Depends: none. Claim: unassigned.
