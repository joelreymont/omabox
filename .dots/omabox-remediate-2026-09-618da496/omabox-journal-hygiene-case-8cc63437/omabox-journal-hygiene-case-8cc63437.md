---
title: "Journal hygiene: case collisions"
status: open
priority: 3
issue-type: task
created-at: "\"2026-09-02T11:28:11.365981+02:00\""
---

Problem: resolving a local case collision forgets the kept spelling's baseline, which can turn a later remote edit into a spurious conflict, and a collision no spelling of which can be renamed makes the daemon rescan forever. Acceptance: every child closes; resolving a local case collision keeps the kept spelling's baseline so a later remote edit is not a spurious conflict, and a collision where no spelling can be renamed is recorded and causes no endless rescanning. Depends: none. Claim: unassigned.
