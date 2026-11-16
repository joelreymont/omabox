---
title: "Add SERVICE, the unit's state machine"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:55:34.143797+02:00"
closed-at: "2026-11-17T00:06:29.213435+02:00"
---

Problem: the Habu port cannot drive the systemd user unit (rust src/service.rs, src/spawn.rs Launch), which install, uninstall and the CLI need. Acceptance: SERVICE drives the unit as service.rs does, as an fsm.f machine, with service.rs's ten tests ported; service-test passes. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
