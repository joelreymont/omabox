---
title: Let the CLI repair a missing root and tidy setup
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.376382+02:00"
blocks:
  - omabox-key-root-generations-0f6e6082
  - omabox-store-state-paths-a4a19746
---

Problem: src/config.rs:205-243 canonicalizes the stored root on every load, so set-root, status, and settings all fail when the old root is missing (src/bin/omabox.rs:364); setup takes the daemon lock without stopping the service and the lock error names a manual daemon (:215-216, :500-508); the authorization code read is unbounded and untrimmed (:437-452); README says setup opens a browser and omits the live-test flags. Design: docs/remediation-2026-09.md section L (config split, setup, auth code, README). Acceptance: ConfigDocument loads without filesystem checks and Config::validate is separate; set-root validates only the replacement and calls adopt_local_root; status and settings render an unresolvable root as a line instead of failing; setup stops and restores the service like set-root; the lock error help names omabox pause; the code read uses take(limit+1) and trim; README corrected; tests for missing-root set-root/status/settings, oversized and whitespace-padded codes. Files: src/config.rs, src/bin/omabox.rs, README.md. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: rootgen, physical. Ownership: CLI configuration flow. Claim: unassigned.
