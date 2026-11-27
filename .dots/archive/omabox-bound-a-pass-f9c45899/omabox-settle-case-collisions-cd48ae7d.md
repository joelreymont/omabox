---
title: Settle case collisions from the journal
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.053439+02:00"
closed-at: "2026-11-18T15:43:49.596202+02:00"
---

Problem: settling a case collision (src/reconcile.f CASE-VARIANT-SOURCE, DESTINATION, RESOLVED) needs the pass's whole local record list in memory. Acceptance: collisions and destinations are read from the indexed journal, the settling rules unchanged; settling holds only colliding rows. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-settle-collisions.
