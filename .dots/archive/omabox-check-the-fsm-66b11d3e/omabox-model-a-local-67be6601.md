---
title: "Model a local operation's replay table"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T14:11:50.118313+02:00"
closed-at: "2026-11-17T17:21:46.954215+02:00"
---

Problem: LOCAL-LIFECYCLE (src/replay.f:836) has no model its lines are steps of; formal/MutationLifecycle.tla describes what APPLY does inside one line. Acceptance: a formal/ model whose steps are the table's lines, with the invariants its words rely on, passes TLC as the user approves and the listing check's mechanism applied to the table. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-local-67be6601.
