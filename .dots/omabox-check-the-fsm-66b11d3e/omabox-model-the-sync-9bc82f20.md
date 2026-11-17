---
title: Model the sync pass table
status: open
priority: 2
issue-type: task
created-at: "2026-11-17T14:11:50.122214+02:00"
---

Problem: SYNC-BEHAVIOR (src/reconcile.f:3806) is one pass over every path; formal/SyncBehavior.tla models one path, with no root and no pass that ends early. Acceptance: a formal/ model whose steps are the table's lines, with the invariants its words rely on, passes TLC as the user approves and the listing check's mechanism applied to the table. Depends: none. Claim: unassigned.
