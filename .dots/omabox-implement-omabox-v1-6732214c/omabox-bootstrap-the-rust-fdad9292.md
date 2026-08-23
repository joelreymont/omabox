---
title: Bootstrap the Rust service
status: closed
priority: 2
issue-type: task
created-at: "\"2026-08-23T20:47:57.478539+02:00\""
closed-at: "2026-08-23T21:19:00.787258+02:00"
close-reason: All bootstrap children landed; Rust package, configuration, locking, logging, ARM64 check, and systemd verification green.
---

Problem: the repository still declares Go and has no Rust package or service shell. Acceptance: AGENTS.md names Rust nightly checks; one Cargo package builds omabox and omaboxd; dated nightly, XDG config/state validation, secret-safe logging, kernel-released instance locking, and the systemd user unit exist. Files: AGENTS.md, Cargo.toml, Cargo.lock, rust-toolchain.toml, src/lib.rs, src/config.rs, src/bin/omabox.rs, src/bin/omaboxd.rs, packaging/systemd/omabox.service. Verify: cargo fmt --check; cargo check --all-targets; cargo test config. Depends: none. Ownership: bootstrap and configuration surface.
