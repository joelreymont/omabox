---
title: Package the systemd user service
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-23T20:52:43.425302+02:00\\\"\""
closed-at: "2026-08-23T21:00:59.550215+02:00"
close-reason: Landed as 8fad48a9; systemd-analyze verification green.
---

Problem: Omabox needs an unattended headless user-service definition independent of application internals. Acceptance: the unit starts omaboxd, restarts on failure, uses a private umask, and permits clean termination without claiming incompatible filesystem sandboxing. Files: packaging/systemd/omabox.service. Verify: systemd-analyze --user verify packaging/systemd/omabox.service. Depends: none. Ownership: systemd unit only.
