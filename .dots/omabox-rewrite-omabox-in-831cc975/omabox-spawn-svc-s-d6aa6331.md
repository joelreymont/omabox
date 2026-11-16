---
title: "Spawn SERVICE's children in omabox's group"
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.217075+02:00"
---

Problem: src/service.f SPAWN-WITH leaves PROCESS's default, a process group of the child's own, so Ctrl-C misses systemctl and journalctl; Habu's spawn.f has no public word for the caller's group (report bob-habu-spawn-group.md to jerry and carl). Acceptance: inherited-wiring children run in omabox's process group. Depends: Habu's public word. Claim: unassigned.
