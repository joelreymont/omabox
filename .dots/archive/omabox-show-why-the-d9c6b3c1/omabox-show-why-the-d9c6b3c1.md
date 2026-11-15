---
title: Show why the service stopped
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T16:04:26.928683+02:00"
closed-at: "2026-11-15T06:47:19.244696+02:00"
---

Problem: on a user-action or invariant exit the daemon publishes its fatal status (src/daemon.rs:404-414) and exits 78/70, but packaging/systemd/omabox.service:10 deletes status.json on every stop, so the widget shows 'Service stopped / Omabox has not published a status snapshot.' (Panel.qml:32,47); even a kept file turns stale after 75 s (Status.qml:43) and Panel.qml:49 hides last_error behind staleness. Acceptance: after a fatal exit the widget shows 'Service stopped' with the fatal text indefinitely; a clean stop still removes the snapshot. Depends: none. Claim: unassigned.
