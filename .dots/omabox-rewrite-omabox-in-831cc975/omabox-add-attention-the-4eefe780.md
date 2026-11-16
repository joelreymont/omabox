---
title: "Add ATTENTION, the status command's text"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:55:34.145924+02:00"
closed-at: "2026-11-17T00:06:29.198510+02:00"
---

Problem: the Habu port cannot print 'omabox status' (rust src/status.rs). Acceptance: ATTENTION renders a journal as status.rs does, with the journal named [Omabox journal] in its logs; status.rs's tests and dropbox_fake.rs:5708's assertion ported; attention-test, journal-test and reconcile-test pass. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
