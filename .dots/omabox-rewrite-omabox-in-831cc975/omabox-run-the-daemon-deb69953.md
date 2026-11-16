---
title: Run the daemon as a machine
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T17:37:45.678763+02:00"
closed-at: "2026-11-16T19:18:22.695388+02:00"
---

Goal: the daemon prepares, locks, opens the journal, notifies systemd, then loops over sync passes and long polls, every failure going through the failure policy, as rust daemon.rs:108-500 does. Acceptance: DAEMON:RUN answers 78 or 70 only when it stops, and daemon.rs's recovery and binding tests pass under their names. Depends: omabox-add-daemon-s-269353be, omabox-validate-the-dropbox-fccb654a. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fold-run, agent=worker workspace=.jj-ws.noindex/omabox-fold-cycle.
