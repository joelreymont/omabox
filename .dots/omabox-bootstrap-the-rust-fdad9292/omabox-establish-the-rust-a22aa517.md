---
title: Establish the Rust package foundation
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-23T20:52:43.344521+02:00\\\"\""
closed-at: "2026-08-23T21:00:59.549263+02:00"
close-reason: Landed as bb179c04; combined fmt, check, clippy, and tests green.
---

Problem: Omabox has no compiling Rust package or typed error surface. Acceptance: one dated-nightly Cargo package builds omabox and omaboxd; production crates deny unwrap_used, expect_used, and panic; library errors use thiserror and binaries render them with miette; no production unwrap/expect/panic exists. Files: Cargo.toml, Cargo.lock, rust-toolchain.toml, src/lib.rs, src/bin/omabox.rs, src/bin/omaboxd.rs. Verify: cargo fmt --check; cargo check --all-targets; cargo clippy --all-targets -- -D warnings. Depends: none. Ownership: package manifest, crate root, and binary skeletons.
