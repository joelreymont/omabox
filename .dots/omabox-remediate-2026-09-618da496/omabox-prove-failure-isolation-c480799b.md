---
title: Prove failure isolation at the daemon level
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.377939+02:00"
blocks:
  - omabox-isolate-per-path-3600f60c
  - omabox-record-readable-conflict-9224fe0a
  - omabox-make-dropbox-listing-96c0afc3
---

Problem: no test drives run_session against the fake for any failure class; no crash test covers a remote effect that succeeded before completion was recorded or the case-collision rename after baseline invalidation; cross-filesystem promotion is tested only through a helper (src/local.rs:5138). Design: docs/remediation-2026-09.md section N (daemon-level, crash, EXDEV tests). Acceptance: session-level tests through omabox::daemon against the fake for a socket, a symlink, a mode-000 file, a 409 download, a restricted folder, a revoked refresh token (exit disposition UserAction), and a locked keyring (Environmental), each asserting unrelated paths still sync and the session does not exit except where designed; crash tests: remote create then crash then replay completes via get_metadata, baseline invalidation then crash before rename never plans a delete; EXDEV test with root under a TempDir on /home and staging under /dev/shm exercising the real promotion branches; all fail or are impossible before their fixes. Files: tests/dropbox_fake.rs, tests/crash_recovery.rs, src/local.rs (tests), src/daemon.rs (test hooks only if needed). Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: blocked, rootgen, conflicts, inventory. Ownership: daemon-level proofs. Claim: unassigned.
