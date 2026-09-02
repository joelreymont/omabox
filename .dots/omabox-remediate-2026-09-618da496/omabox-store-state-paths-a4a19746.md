---
title: Store state paths as physical paths and reject config inside the root
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-02T11:28:11.364541+02:00\\\"\""
closed-at: "2026-09-02T12:42:27.410008+02:00"
close-reason: "landed as change xxlosstt (Project private paths and guard config and lock); destruction pass findings fixed; gates green at merged tip: fmt, clippy -D warnings, 221 tests"
---

Problem: src/config.rs:80-92 stores lexically normalized state, staging, and recovery paths while src/local.rs:3064-3078 opens them with RESOLVE_NO_SYMLINKS, so a symlinked ~/.local makes every slot lease fail; src/config.rs:94-112 does not reject the config directory lying inside the sync root. Design: docs/remediation-2026-09.md section L (config-physical and validate_outside items). Acceptance: Paths::resolve stores project_physical_path results for state, journal, staging, recovery, and lock; validate_outside includes PathRole::Config; tests: symlinked XDG_STATE_HOME works end to end through open_private_directory, sync root equal to the config directory's parent is rejected. Files: src/config.rs, src/local.rs (test). Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none. Ownership: configuration path resolution. Claim: agent=worker-physical workspace=.jj-ws/omabox-store-state-paths-a4a19746
