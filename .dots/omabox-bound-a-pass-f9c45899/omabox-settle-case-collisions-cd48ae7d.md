---
title: Settle case collisions from the journal
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.053439+02:00"
---

Problem: settling a case collision (src/reconcile.f CASE-VARIANT-SOURCE, DESTINATION, RESOLVED) needs the pass's whole local record list in memory. Acceptance: collisions and destinations are read from the indexed journal, the settling rules unchanged; the pass keeps no local record list. Depends: none. Claim: unassigned.
