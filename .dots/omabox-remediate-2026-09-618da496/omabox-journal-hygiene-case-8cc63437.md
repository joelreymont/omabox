---
title: "Journal hygiene: case collisions, legacy adoption, dead code"
status: open
priority: 3
issue-type: task
created-at: "2026-09-02T11:28:11.365981+02:00"
blocks:
  - omabox-journal-schema-ver-487764f0
---

Problem: src/journal.rs:1372-1374 invalidates the kept spelling's baseline too, causing a spurious InitialCollision; :745-763 binds legacy v1 baselines to whatever root is configured, which can plan DeleteRemote for every file when the root is new; config::redacted (src/config.rs:729-748) has no production caller; Journal::publish_local_inventory is test-only. Design: docs/remediation-2026-09.md section M. Acceptance: invalidate_case_collision_baselines re-records the kept spelling's baseline in the same transaction (test asserts a later differing remote yields ReplaceLocal, not a conflict); legacy adoption starts a fresh generation (migration test from a v1 fixture with a different root asserts no DeleteRemote is ever planned); config::redacted removed; publish_local_inventory under cfg(test). Files: src/journal.rs, src/config.rs, src/status.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: schema. Ownership: journal hygiene. Claim: unassigned.
