---
title: "Add STALE and CONFIG's writer"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:55:34.136628+02:00"
closed-at: "2026-11-17T00:06:29.162071+02:00"
---

Problem: the Habu port has no stale-binary check (rust src/stale.rs) and CONFIG cannot write config.toml (rust src/config.rs write, write_new), which install and the CLI need. Acceptance: STALE and CONFIG WRITE/WRITE-NEW behave as the Rust versions, with config.rs's and stale.rs's tests ported; config-test and stale-test pass. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
