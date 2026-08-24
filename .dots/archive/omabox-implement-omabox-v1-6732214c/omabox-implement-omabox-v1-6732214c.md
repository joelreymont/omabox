---
title: Implement Omabox v1
status: closed
priority: 2
issue-type: task
created-at: "\"2026-08-23T20:47:22.119251+02:00\""
closed-at: "2026-08-24T02:12:26.025283+02:00"
close-reason: all implementation dots landed; final acceptance reviews and non-live verification pass
---

Problem: PLAN.md defines the first ARM64-first Rust nightly Dropbox sync release. Acceptance: every child dot lands, all non-live checks pass, and the safety contract remains intact. Files: repository-wide. Verify: cargo fmt --check; cargo clippy --all-targets --all-features -- -D warnings; cargo test. Depends: none. Ownership: campaign parent; do not claim directly.
