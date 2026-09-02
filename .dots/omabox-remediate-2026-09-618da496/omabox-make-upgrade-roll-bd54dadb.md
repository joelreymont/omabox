---
title: Make upgrade roll back on launch failure and harden install paths
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.362911+02:00"
blocks:
  - omabox-classify-daemon-errors-dd34c00a
---

Problem: src/install.rs:174-185 calls transaction.finish() when the service restart fails, deleting the old artifacts instead of rolling back (README promises rollback); Type=simple cannot observe launch; :651-658 treats a symlinked destination as a file and swaps it; :56-63 lets the installed CLI upgrade itself; :198-216 leaves the plugin enabled in the shell on uninstall; :86-91 hard-codes ~/.config; :709-767 lacks help on most variants and hides secondary rollback/cleanup causes; :606-623 and src/config.rs:552-557 never sweep stale temporaries. Design: docs/remediation-2026-09.md section L (install items). Acceptance: restart failure, or an inactive/failed unit within a 10 s is-active poll after restart, runs rollback, daemon-reload, and state restore (tests for both); staged omaboxd is run with --self-check before publishing (flag implemented by the dispositions dot; this dot only invokes it); symlinked destinations and source-equals-destination (same st_dev/st_ino) are refused with typed errors and help (tests); uninstall disables the plugin via omarchy-shell before removal (fake command test); Layout honors XDG_CONFIG_HOME; every InstallError variant has help; RollbackFailed/CleanupFailed expose both chains via miette related; stale .omabox*.install.* and .config.toml.*.tmp siblings with dead PIDs are swept before each transaction (test). Files: src/install.rs, src/bin/omaboxd.rs, src/config.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: dispositions (unit file content). Ownership: install transaction. Claim: unassigned.
