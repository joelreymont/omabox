---
title: Restore the service when its release fails midway
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:07:55.285950+02:00"
blocks:
  - omabox-release-the-svc-33846ca0
---

Problem: change_while_released (src/bin/omabox.rs) returns early when the Release drive fails after systemctl stop ran, dropping the observed state, so setup or set-root leaves a running service stopped. Acceptance: a Release that fails after stopping the service still restores the state observed before it (test with a systemctl that stops and then fails). Depends: omabox-release-the-svc-33846ca0. Claim: unassigned.
