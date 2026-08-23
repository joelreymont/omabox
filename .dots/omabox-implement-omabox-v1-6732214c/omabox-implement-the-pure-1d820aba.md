---
title: Implement the pure sync planner
status: open
priority: 2
issue-type: task
created-at: "2026-08-23T20:47:57.557478+02:00"
blocks:
  - omabox-bootstrap-the-rust-fdad9292
---

Problem: reconciliation decisions need one explicit model that cannot delete from unknown state or write without the expected revision. Acceptance: typed baseline/observation/operation models and a deterministic pure planner cover initial sync, one-side changes, explicit deletion, blocked state, and conflicts; proptest and insta prove the safety invariants without snapshotting internals. Files: src/model.rs, src/planner.rs, tests/planner_properties.rs, tests/planner_snapshots.rs, snapshots owned by those tests. Verify: cargo test --test planner_properties; cargo test --test planner_snapshots. Depends: bootstrap dot. Ownership: sync model and planner.
