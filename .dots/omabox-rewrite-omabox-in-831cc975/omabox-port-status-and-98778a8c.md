---
title: Port STATUS and its heartbeat
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T20:22:00.967463+02:00"
blocks:
  - omabox-port-the-domain-79c20924
---

Problem: the widget reads status.json v3, which the Rust daemon rewrites on each change and every 20 s (rust src/runtime_status.rs). Acceptance: src/status.f writes what the Rust version writes for the same snapshot, under one TASK:FACILITY, with a heartbeat task. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-status.
