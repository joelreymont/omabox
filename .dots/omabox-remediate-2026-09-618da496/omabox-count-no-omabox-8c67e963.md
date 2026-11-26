---
title: Count no Omabox stage as a blocked path
status: closed
priority: 2
issue-type: task
created-at: "2026-11-26T13:37:15.056082+02:00"
closed-at: "2026-11-26T13:42:16.661440+02:00"
---

Problem: the scan records Omabox's own reserved .omabox-download-<sha> stage as an unsupported local observation (src/local.f SCAN-REGULAR), the planner holds it as blocked (src/planner.f FROM-ABSENT) and HELD-COUNT (src/reconcile.f) counts it, so a pass that finds a verified stage reports blocked=1 though nothing of the user's is blocked. Acceptance: a pass with only Omabox's own stage and guard files beside synced files reports blocked 0, and those files are still never uploaded or deleted by sync (reconcile-test). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-own-stages.
