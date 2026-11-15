---
title: Model upload sessions in TLA+
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:35.996948+02:00"
---

Problem: no model covers upload sessions; MutationLifecycle has no upload or finish. Acceptance: formal/UploadSession.tla and its cfg model the upload session as the Habu daemon has it, the session machine in docs/habu-dropbox.md plus the journal record of omabox-record-upload-sessions-eb2dd712, with crash, lost append and finish answers, session expiry and concurrent remote edits; the model checks its invariants, TLC runs it clean, and formal/README.md lists it. Depends: none. Claim: unassigned.
