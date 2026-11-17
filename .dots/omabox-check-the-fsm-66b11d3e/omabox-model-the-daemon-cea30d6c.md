---
title: "Model the daemon's table"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T14:11:50.123838+02:00"
closed-at: "2026-11-17T17:22:45.655780+02:00"
---

Problem: DAEMON-RUN (src/daemon.f:879) has no model, and its RESUMED line picks its next state at run time, which the check cannot read. Acceptance: a formal/ model whose steps are the table's lines, with the invariants its words rely on, passes TLC as the user approves and the listing check's mechanism applied to the table. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-daemon-cea30d6c.
