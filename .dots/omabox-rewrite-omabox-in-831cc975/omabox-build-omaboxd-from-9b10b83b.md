---
title: Build omaboxd from DAEMON
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:04:25.537440+02:00"
closed-at: "2026-11-16T19:18:22.701889+02:00"
---

Goal: systemd starts omaboxd and the installer runs omaboxd --self-check, as rust src/bin/omaboxd.rs. Acceptance: the program builds with one documented hb command, and rust tests/daemon_startup.rs's three tests pass under their names against the built program. Depends: omabox-run-the-daemon-deb69953. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
