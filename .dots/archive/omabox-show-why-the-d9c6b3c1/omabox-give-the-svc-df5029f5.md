---
title: Give the service machine a starting state
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T06:23:09.255934+02:00"
closed-at: "2026-11-15T06:47:19.238822+02:00"
---

Problem: src/service.rs:193 maps activating to Running, so upgrade treats a starting or crash-looping unit as a ready old build and rolls back after a failed restart (two TimeoutStartSec waits, then RollbackFailed); a stop of a unit systemd unloads after the observe fails (exit 5); reset-failed's stderr handling and drive's failure propagation have no test; control stays public for start, stop and restart; ServiceState::restore and set_sync_root each decide from a state read back. Acceptance: activating maps to its own Starting state that Halt and Release stop and Recover leaves; a Restore goal starts again a unit observed running or starting; stop and reset-failed of an unloaded unit succeed silently and a real failure forwards systemctl's message; control is private and Enable, Disable and Status have their own methods; drive and the test walk share one transition; tests cover each. Depends: none. Claim: agent=worker-starting-state workspace=.jj-ws.noindex/omabox-give-the-svc.
