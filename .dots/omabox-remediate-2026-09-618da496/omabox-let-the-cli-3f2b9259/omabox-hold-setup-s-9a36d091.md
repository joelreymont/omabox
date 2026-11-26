---
title: "Hold setup's recovery drive in a machine"
status: open
priority: 2
issue-type: task
created-at: "2026-11-26T13:37:15.053033+02:00"
---

Problem: src/omabox.f DECIDED re-branches on the change's code, the restore's code and launched, and RECOVERED then runs RECOVER's drive (reset-failed, start) after the signal window has closed, outside both machines; a SIGINT, SIGTERM or SIGHUP during that drive takes its default and can stop it between reset-failed and start, leaving the service stopped. Acceptance: what setup and set-root tell and the recovery drive after the window are states of a named machine with its model, and a signal during the recovery drive is deferred until the drive ends, then the CLI dies of it (test). Depends: none. Claim: unassigned.
