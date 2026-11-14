---
title: "Drive service commands from the unit's state"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T16:47:12.690606+02:00"
closed-at: "2026-11-14T17:27:56.586119+02:00"
---

Problem: the CLI infers the unit's state from is-active and is-failed reads in several places (src/bin/omabox.rs start_if_failed, set_sync_root, the service dispatch). After 5 starts in 10 minutes systemd refuses the start a fix asks for, so the old reason stays; and pausing a failed unit leaves it failed, so the next setup or set-root starts a service the user paused. Acceptance: one UnitState read from ActiveState decides every CLI service transition; a fix or resume of a failed unit clears it (reset-failed) and starts it; pause leaves the unit inactive; tests show each. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-show-why-the-d9c6b3c1
