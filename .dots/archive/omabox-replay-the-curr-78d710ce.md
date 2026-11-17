---
title: Replay the current plan record at install
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T16:46:51.598061+02:00"
closed-at: "2026-11-17T16:53:10.863813+02:00"
---

Problem: INSTALL (src/reconcile.f:2703) replays the plan record PENDING-NOW read in STEP-AT (:2882) before LOCAL-REPORT (:2885) replayed that plan, so a legacy plan with a preservation before an install that downloads applies the completed preservation again and counts it twice in replayed_operations. Acceptance: INSTALL replays the journal's current record of the plan; a test with a [preserve-local, install-local] plan whose install downloads reports 2 replayed operations. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-stale-install.
