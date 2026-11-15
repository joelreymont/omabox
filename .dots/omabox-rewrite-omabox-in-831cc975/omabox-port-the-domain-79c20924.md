---
title: Port the domain values as MODEL
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T20:22:00.958146+02:00"
blocks:
  - omabox-move-omabox-s-12e4286b
---

Problem: omabox has no Habu form of the Rust domain values (rust src/model.rs) that the journal stores and the planner decides on. Acceptance: src/model.f as docs/habu-rewrite.md (Values, Decisions) says, its JSON writers and readers matching src/oracle/json.tsv byte for byte and FOLD matching src/oracle/fold.tsv. Depends: omabox-move-omabox-s-12e4286b. Claim: unassigned.
