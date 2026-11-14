---
title: "Journal hygiene: case collisions and dead code"
status: open
priority: 3
issue-type: task
created-at: "\"2026-09-02T11:28:11.365981+02:00\""
---

Problem: invalidate_case_collision_baselines still invalidates the kept spelling's baseline, which can cause a spurious InitialCollision. config::redacted has no production caller, and Journal::publish_local_inventory is only used by tests. Safe legacy-root adoption already landed in 8098526 and is no longer work for this dot.

Design: docs/remediation-2026-09.md section M, remaining case-collision and dead-code items. Acceptance: invalidate_case_collision_baselines re-records the kept spelling's baseline in the same transaction, using the active root descriptor as section M specifies; a regression asserts a later differing remote yields ReplaceLocal rather than a conflict. Remove config::redacted and put publish_local_inventory under cfg(test).

Files: src/journal.rs, src/config.rs, src/status.rs, src/reconcile.rs as needed for the existing case-collision path. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none; journal schema and safe root adoption are landed. Ownership: journal hygiene. Claim: unassigned. The old workspace is retained as historical work only.
