---
title: Check the upload session table against its model
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T14:11:50.129317+02:00"
closed-at: "2026-11-18T09:51:04.978048+02:00"
---

Problem: SESSION (src/dropbox.f:3090) has no model, so the table and what it promises can drift apart unseen. Acceptance: formal/UploadSession.tla models the upload session as the daemon runs it today, its steps SESSION's lines, with the invariants the table's words rely on; TLC runs its cfg clean once the user approves that run; and the listing check's mechanism applied to the table and that model passes. Depends: none. Claim: agent=session-worker workspace=.jj-ws.noindex/omabox-session-e9b6134c.
