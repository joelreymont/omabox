---
title: Journal schema version 6 with blocked plans and conflict names
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.353238+02:00"
blocks:
  - omabox-order-canonical-paths-6ffaf324
---

Problem: plans cannot record a permanent per-path failure (src/recovery.rs:867-873 leaves rejected plans pending forever); the journal file is created under the ambient umask (src/journal.rs:493-504); busy_timeout is implicit. Design: docs/remediation-2026-09.md section B (exact DDL and API). Acceptance: migrations/0006.sql rebuilds baselines, remote_observations, and conflicts STRICT with canonical_path NOT NULL (NULL rows backfilled from path in Rust first via populate_canonical_paths), and rebuilds plans (also NOT NULL) and operations together (child referencing the new parent, ids and ordinals preserved, old child dropped before old parent, index recreated, PRAGMA foreign_key_check run) because operations.plan_id has an ON DELETE RESTRICT foreign key and foreign keys are on during migration; plans gains status 'blocked', blocked_json, retry_at and the one_live_plan_per_path partial index replacing one_pending_plan_per_path; remote_directories partial index; PRAGMA user_version = 6 inside the migration transaction; rollback journal mode and synchronous FULL kept, explicit busy_timeout 5000 and foreign_keys ON; database and lock files created with mode 0600 create_new before opening; PlanStatus/BlockReason types, block_plan, blocked_plans, unblock_plan, pending_plans as one join (pending only), pending_upload_content includes blocked plans; migration test from a populated v5 database with pending plans and operations, a NULL canonical_path baseline row, and a conflict asserts ids, ordinals, statuses, backfilled canonical paths, and foreign_key_check survive; existing tests updated. Files: migrations/0006.sql, src/journal.rs, src/config.rs (lock file mode), src/status.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: canonical. Ownership: journal schema and API. Claim: unassigned.
