---
title: Key root generations on configuration, not inode drift
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.370486+02:00"
blocks:
  - omabox-classify-daemon-errors-dd34c00a
---

Problem: src/journal.rs:721-812 starts a new generation whenever device or inode differ, so an unmounted external drive downloads the whole tree into the mount point; with pending work it returns Busy and the daemon exits (src/bin/omaboxd.rs:247). Design: docs/remediation-2026-09.md section F. Acceptance: LocalRootActivation::Unavailable for same path with different identity (nothing written; daemon treats it as Environmental with a fixed status message); a different canonical path supersedes pending and blocked plans and pending recoveries and starts a new generation; Busy removed; adopt_local_root starts a new generation unconditionally and is used by setup and set-root; set-root accepts the same path when identity differs; tests: unmounted-root simulation (rename the root away and create an empty directory at the same path) asserts Unavailable and no baseline loss, path change with pending work asserts supersede then Activated, set-root same-path re-adoption. Files: src/journal.rs, src/bin/omaboxd.rs, src/bin/omabox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: schema, dispositions. Ownership: root generation policy. Claim: unassigned.
