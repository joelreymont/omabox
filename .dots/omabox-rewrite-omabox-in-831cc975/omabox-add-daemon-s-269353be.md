---
title: "Add DAEMON's failure policy"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T15:56:11.497035+02:00"
closed-at: "2026-11-16T19:18:22.684823+02:00"
---

Goal: the daemon decides after each failure whether to retry, wait for the machine, or stop with an exit code systemd will not restart, as rust daemon.rs:64-90, :699-1049 do. Acceptance: DAEMON maps every Habu code and Dropbox reply to Rust's disposition and status text, with Rust's retry schedule and exit codes, and daemon.rs's policy tests pass under their names. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fold-policy.
