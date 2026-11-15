---
title: Restore the service when its release fails midway
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T08:07:55.285950+02:00"
closed-at: "2026-11-15T10:58:44.252886+02:00"
---

Problem: change_while_released (src/bin/omabox.rs) returns early when the Release drive fails after systemctl stop ran, dropping the observed state, so setup or set-root leaves a running service stopped. Acceptance: a Release that fails after stopping the service still restores the state observed before it (test with a systemctl that stops and then fails). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-restore-the-svc-2db1e172.
