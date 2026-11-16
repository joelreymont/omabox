---
title: Confirm a gone finish only for a complete entry
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T14:15:39.986187+02:00"
closed-at: "2026-11-16T14:36:12.118587+02:00"
---

Problem: src/dropbox.f CONFIRM-SENSE answers same for a file with the upload's content hash without checking that the entry is complete (rev, downloadable), and REPLAY's UPLOADED now records whatever DROPBOX answers done. Acceptance: verifying answers same only for the complete entry; an incomplete one is not done. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-confirm-complete
