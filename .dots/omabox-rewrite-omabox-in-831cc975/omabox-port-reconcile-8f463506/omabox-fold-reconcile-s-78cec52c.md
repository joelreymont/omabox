---
title: "Fold RECONCILE's tie-breaks and name split"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T13:33:26.811286+02:00"
closed-at: "2026-11-16T14:36:12.058827+02:00"
---

Problem: ENTRY<, REMOTE<, BEFORE?, CHANGE< and CASING< in src/reconcile.f each hand-write the index tie-break STABLE< holds; SPLIT-NAME repeats PARENT-BYTES' separator scan with a literal 47. Acceptance: one tie-break and one separator scan. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fold-orders
