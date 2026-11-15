---
title: Signal readiness without the sync root
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.611776+02:00"
closed-at: "2026-11-15T11:09:39.529090+02:00"
---

Problem: the daemon resolves the sync root before READY=1, so with the root unavailable a start or upgrade restart blocks until TimeoutStartSec and an upgrade rolls back a working build. Acceptance: readiness follows the config document, lock and journal; root availability is reported through status after readiness (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-signal-readiness-without-f4e22b1b.
