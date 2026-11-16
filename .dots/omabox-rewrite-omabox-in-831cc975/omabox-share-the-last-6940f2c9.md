---
title: Share the last duplicate test words
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T15:56:11.504930+02:00"
closed-at: "2026-11-16T15:57:46.969504+02:00"
---

Problem: src/replay-test.f OPENED-WITH copies TEST-CLIENT:CLIENT-ON, and src/local-test.f copies TEST-CLIENT's UNPROTECTED and LEASED, so a fix to one copy misses the other. Acceptance: one definition of each; replay-test and local-test keep their counts. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
