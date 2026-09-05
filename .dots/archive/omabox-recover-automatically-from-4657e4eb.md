---
title: Recover automatically from corrupt private upload stages
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T14:13:58.623349+03:00\\\"\""
closed-at: "2026-09-05T14:21:23.122175+03:00"
close-reason: "landed and verified in change xpntkrlm: corrupt regular private upload stages rebuild automatically; fake-Dropbox regressions cover fresh uploads and due StageOccupied plans after journal reopen; special-object isolation and verified download-stage preservation still pass. Separate Astra review found no blockers. cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test and forbidden-Rust scan pass; MutationLifecycle TLC passes with 48 distinct states."
---

Problem: a mismatched regular file at a content-addressed private upload stage is preserved and blocked on every retry forever. Acceptance: stage_upload_at removes a confirmed corrupt regular private cache entry and rebuilds verified immutable staging from the current source; non-regular occupants remain preserved and block only their path; verified stages and sync-root download/conflict stages retain existing protection; due blocked uploads recover after journal reopen without user cleanup. Files: src/local.rs, tests/dropbox_fake.rs. Verify: regression through new and previously blocked upload paths, existing special-object isolation tests, cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test, TLC MutationLifecycle. Depends: landed durable-block fix mlmzszxt. Ownership: root Astra implementation; separate Astra review before landing.
