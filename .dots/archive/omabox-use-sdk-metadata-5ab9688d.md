---
title: Use SDK metadata directly and flatten download error handling
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T13:29:47.213946+03:00\\\"\""
closed-at: "2026-09-05T13:34:50.808477+03:00"
close-reason: "landed and verified: jj change zosvysso removes ListEntry/EntryTag and flattens download SDK error matching without changing behavior. Separate Astra review passed. cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test (367 tests), cargo check --all-targets --features dropbox-live, release build and daemon self-check passed. InventoryPublication TLC passed with 50 distinct states. Existing metadata, property, replay and fake-server test scenarios retained."
---

Problem: Dropbox metadata is converted into a second tag-and-optional-fields representation, then validated repeatedly; download_block_reason re-matches an already destructured SDK error. Acceptance: remove ListEntry and EntryTag, convert generated SDK metadata directly into existing engine observations and mutation results while preserving path/hash/revision/restriction validation and listing failure behavior; flatten SDK error classification without changing outcomes. Files: src/dropbox.rs, src/reconcile.rs. Verify: existing metadata/property/fake-server tests, cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test; relevant inventory TLC after conversion. Depends: landed SDK migration and exclusions. Ownership: root Astra implements; separate Astra reviews before landing. Land one behavior-preserving cleanup commit with dot closure, push, and deploy the validated release as requested.
