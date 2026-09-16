---
title: Propagate local directory deletions to Dropbox
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-09-16T12:19:36.620922+03:00\\\"\""
closed-at: "2026-09-16T12:53:53.674850+03:00"
close-reason: "implemented, reviewed by a separate reviewer (3 medium findings fixed), gates green: cargo fmt --check, cargo clippy --all-targets -D warnings, cargo test (all suites), TLC DirectoryDeletion/SyncBehavior/MutationLifecycle"
---

Problem: src/planner.rs:80 re-creates a local directory when baseline and Dropbox both hold a directory and the local side is confirmed absent, so a user's local directory deletion is undone every pass; there is no remote directory delete operation. Acceptance: a locally deleted directory whose Dropbox folder is observed empty is deleted on Dropbox with a non-recursive guarantee (list the folder immediately before delete_v2, retire the plan when it holds entries); a directory whose inventory still holds descendants is reported blocked and is never re-created locally; planner property, snapshot, fake-Dropbox, and replay tests cover empty, occupied, stale-check, and already-absent cases; a TLA+ model checks the two-path parent/child deletion with a concurrent remote edit. Files: src/model.rs, src/planner.rs, src/reconcile.rs, src/dropbox.rs, src/recovery.rs, src/journal.rs, tests/planner_properties.rs, tests/planner_snapshots.rs, tests/dropbox_fake.rs, tests/crash_recovery.rs, formal/DirectoryDeletion.tla, formal/README.md, README.md. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test; TLC on DirectoryDeletion, SyncBehavior, MutationLifecycle. Depends: none. Ownership: planner, reconcile, dropbox, recovery. Claim: agent=heron workspace=main
