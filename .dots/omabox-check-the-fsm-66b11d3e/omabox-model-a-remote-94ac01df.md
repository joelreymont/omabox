---
title: "Model a remote operation's replay table"
status: open
priority: 2
issue-type: task
created-at: "2026-11-17T14:11:50.120714+02:00"
blocks:
  - omabox-check-the-listing-28b9d181
---

Problem: REMOTE-LIFECYCLE (src/replay.f:2595) replays Dropbox operations and has no model. Acceptance: a formal/ model whose steps are the table's lines, with the invariants its words rely on, passes TLC as the user approves and the listing check's mechanism applied to the table. Depends: omabox-check-the-listing-28b9d181. Claim: unassigned.
