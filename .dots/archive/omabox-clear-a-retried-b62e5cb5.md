---
title: "Clear a retried failure's error once it is over"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T23:44:59.303911+02:00"
closed-at: "2026-11-18T10:41:59.611846+02:00"
---

Problem: a failure the daemon retries sets last_error (src/daemon.f:859, WAITED), which only a clean pass clears (src/status.f:592-595 via CLEANED, src/daemon.f:759-762); the widget shows red while last_error is set (local.omabox Status.qml hasError). A retried pass with a long backlog runs for hours, so after a network outage on 2026-11-17 the widget stayed red, saying Dropbox was unavailable, from 23:27 while the daemon synced normally. Acceptance: once the retried work shows the failure is over, last_error clears, while a path that failed to sync still shows until a clean pass (tests). Depends: none. Claim: agent=fault-worker workspace=.jj-ws.noindex/omabox-fault.
