---
title: "Retire a remote conflict copy's stage when its conflict ends"
status: open
priority: 2
issue-type: task
created-at: "2026-11-26T10:54:13.278073+02:00"
---

Problem: a remote conflict copy is staged at the copy's own name (replay.f FETCH-COPY, STAGE-COPY). When the copy's install is refused the stage stays for the next attempt, but no plan records the copy's target, so once the conflict ends some other way nothing removes that stage. Acceptance: when a conflict ends without its remote copy installed, the copy's verified stage is removed with a parent-directory sync, and a crash at any point leaves it findable for removal on the next pass. Depends: none. Claim: unassigned.
