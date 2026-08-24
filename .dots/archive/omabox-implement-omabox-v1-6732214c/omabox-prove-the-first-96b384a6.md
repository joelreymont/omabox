---
title: Prove the first-release acceptance path
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-23T20:47:57.992059+02:00\\\"\""
closed-at: "2026-08-24T02:12:20.434455+02:00"
close-reason: acceptance safety fixes and integrated proof landed; all host and ARM64 checks pass
blocks:
  - omabox-wire-reconciliation-daemon-9b8dd33a
---

Problem: the complete service needs integrated evidence for crash recovery, API uncertainty, conflict preservation, and ARM64 packaging. Acceptance: fake-server and temporary-directory scenarios cover the PLAN.md acceptance criteria; the live suite stays opt-in and isolated; format, clippy, and all non-live tests pass with no secrets. Files: tests/dropbox_fake.rs, tests/crash_recovery.rs, tests/dropbox_live.rs, any minimal shared test support. Verify: cargo fmt --check; cargo clippy --all-targets --all-features -- -D warnings; cargo test. Depends: service integration dot. Ownership: end-to-end acceptance tests only.
