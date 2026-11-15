---
title: Port the planner as PLAN
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T20:22:00.960353+02:00"
blocks:
  - omabox-port-the-domain-79c20924
  - omabox-print-the-rust-aa067d25
---

Problem: omabox has no Habu planner (rust src/planner.rs). Acceptance: src/planner.f's PLAN answers every line of src/oracle/plan.tsv. Depends: the MODEL dot, the oracle dot. Claim: unassigned.
