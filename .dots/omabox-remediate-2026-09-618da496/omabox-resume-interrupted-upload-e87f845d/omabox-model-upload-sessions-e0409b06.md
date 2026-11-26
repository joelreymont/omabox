---
title: Model upload sessions in TLA+
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:35.996948+02:00"
---

Problem: once omabox-record-upload-sessions-eb2dd712 records upload sessions in the journal, a crash no longer loses a session, and formal/UploadSession.tla models only the session without that record. Acceptance: formal/UploadSession.tla and its cfg model the journal record as eb2dd712 builds it, with crash, lost append and finish answers, session expiry and concurrent remote edits; the model checks its invariants, TLC runs it clean, and formal/README.md says so. Depends: none. Claim: unassigned.
