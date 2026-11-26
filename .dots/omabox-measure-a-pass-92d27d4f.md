---
title: Measure a pass over pending uploads and conflicts
status: open
priority: 2
issue-type: task
created-at: "2026-11-26T20:15:13.001964+02:00"
---

Problem: the bounded-memory pass was measured over N downloads only. A pass over N pending uploads or N unresolved conflicts takes paths the download measurement never reaches: each upload's conditional write and its strike, each conflict's copy and block (src/reconcile.f, src/replay.f), any of which may still hold memory per entry. Acceptance: the memory a pass holds over 2,000 and over 20,000 pending uploads, and over 2,000 and 20,000 conflicts, is measured, and either does not grow with the count or each growing piece is named with its words and size per entry. Depends: none. Claim: unassigned.
