---
title: Size the answer values to each answer
status: closed
priority: 2
issue-type: task
created-at: "2026-11-23T11:09:58.881950+02:00"
closed-at: "2026-11-23T11:10:31.506099+02:00"
---

Problem: the client's CLIENT-VALUES vector (src/dropbox.f:381, reserved in READ-ANSWER) keeps the room of the largest answer for the session's life: 972 kB after a 486 kB listing page in the heap hunt's harness. Acceptance: READ-ANSWER gives each answer a block of its own size and frees the one before; dropbox-test passes. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-heap-fixes.
