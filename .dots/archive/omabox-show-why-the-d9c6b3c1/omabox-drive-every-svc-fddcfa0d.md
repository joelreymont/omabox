---
title: Drive every service command through one machine
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T05:46:19.604877+02:00"
closed-at: "2026-11-15T06:47:19.232053+02:00"
---

Problem: service decisions branch on a read-back UnitState in seven places across src/bin/omabox.rs (run_service, start_failed, set_sync_root) and src/install.rs (restore, install launch and report, uninstall), each settling the same states its own way, which hid the unloaded-unit and stopping-unit cases; upgrade and setup leave a deactivating unit that ends failed still failed. Acceptance: one named machine in src/service.rs maps each goal (start, restart, recover, halt, release) and observed ActiveState to systemctl steps; every CLI and install caller drives it; recover stops a stopping unit and observes it again before it decides; an exhaustive test walks every goal and state; the UserAction paragraph of docs/remediation-2026-09.md names what each command does. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-service-machine
