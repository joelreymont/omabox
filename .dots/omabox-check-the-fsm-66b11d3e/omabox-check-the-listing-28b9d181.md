---
title: Check the listing table against its model
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T14:11:50.114072+02:00"
closed-at: "2026-11-17T15:16:10.189793+02:00"
---

Problem: nothing fails when INVENTORY-PUBLICATION (src/reconcile.f:2019) and formal/InventoryPublication.tla disagree. Acceptance: a reconcile-test case keeps a TLA+ copy of the table's lines in formal/ equal to the table, read through fsm.f's own reader; a Follows module maps the model's states to the table's and states that every model step between table states is a table line and every line such a step; the test runs TLC on the Follows module, and a deliberate disagreement on each side fails it. Depends: Habu's FSM:LINES (Habu 6391c0b4). Claim: agent=worker workspace=.jj-ws.noindex/omabox-listing-28b9d181.
