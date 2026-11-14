---
title: Sweep stale install and config temporaries
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.595125+02:00"
---

Problem: install stages and backups and config temporaries left by a killed or failed run are never removed, and a cleanup failure after a successful upgrade reports a bare filesystem error. Acceptance: siblings with Omabox's exact temporary names whose PID is dead are removed, without following symlinks, before each install, uninstall and config write; a cleanup failure after a successful restart says the upgrade completed (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-sweep-stale-install-6dcfcf2b.
