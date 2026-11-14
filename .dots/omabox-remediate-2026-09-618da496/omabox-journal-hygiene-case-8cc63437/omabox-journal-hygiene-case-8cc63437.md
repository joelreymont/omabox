---
title: "Journal hygiene: case collisions and dead code"
status: open
priority: 3
issue-type: task
created-at: "\"2026-09-02T11:28:11.365981+02:00\""
---

Problem: resolving a local case collision forgets the kept spelling's baseline, which can turn a later remote edit into a spurious conflict, and a collision no spelling of which can be renamed makes the daemon rescan forever. The dead config and journal code is removed. Design: docs/remediation-2026-09.md section M. Acceptance: every child closes. Depends: none. Claim: unassigned.
