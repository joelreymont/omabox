---
title: Clear a failed state only on a loaded unit
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T05:46:19.611430+02:00"
closed-at: "2026-11-15T06:47:19.229832+02:00"
---

Problem: src/service.rs reset_failed runs systemctl reset-failed, which exits 1 on a unit systemd has unloaded (a disabled, stopped omabox.service), and every start runs it first, so after omabox service disable and a pause, resume, start and restart fail every time, set-root leaves a running service stopped, and an uninstall rollback cannot restart the service. Acceptance: a start, restart or rollback start of a disabled, stopped service starts it; reset-failed failing on an unloaded unit counts as nothing to clear and any other failure is reported; tests show both. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-service-machine
