---
title: "Port RECONCILE's known-path merge"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T04:23:12.559848+02:00"
closed-at: "2026-11-16T14:36:11.961469+02:00"
---

Problem: RECONCILE needs reconcile.rs's known-path merge: the local and remote maps, the unobserved rule, ancestor spelling, the merge over every known path, decision order and the remaining-operations match (reconcile.rs:1344-1386, :1769-1945, :2061-2185). Acceptance: those words in src/reconcile.f; reconcile.rs's unit tests for them pass under their names. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-reconcile-paths.
