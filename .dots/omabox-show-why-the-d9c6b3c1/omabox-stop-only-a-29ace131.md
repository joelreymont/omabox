---
title: Stop only a unit that can hold the lock
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T17:21:19.869081+02:00"
closed-at: "2026-11-14T17:27:56.592753+02:00"
---

Problem: set-root stops omabox.service unconditionally (src/bin/omabox.rs set_sync_root), but systemctl stop refuses an unloaded unit, which show reports as inactive, so set-root before install fails; UnitState folds deactivating into Stopped. Acceptance: set-root stops only a running or stopping unit; UnitState tells deactivating apart; each UnitState doc is accurate; tests show it. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-show-why-the-d9c6b3c1
