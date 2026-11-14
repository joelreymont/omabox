---
title: Key root generations on configuration, not inode drift
status: closed
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.370486+02:00"
closed-at: "2026-11-14T15:43:30.221118+02:00"
close-reason: "landed with omabox-preserve-sync-history-d24798cd: same-path Unavailable without writes (src/journal.rs:3670), path change retires prior work (src/journal.rs:3846), same-path set-root adoption (src/bin/omabox.rs:1135), Busy removed"
blocks:
  - omabox-journal-schema-ver-487764f0
  - omabox-classify-daemon-errors-dd34c00a
---

Problem: src/journal.rs:721-812 starts a new generation whenever device or inode differ, so an unmounted external drive downloads the whole tree into the mount point; with pending work it returns Busy and the daemon exits (src/bin/omaboxd.rs:247). Design: docs/remediation-2026-09.md section F. Acceptance: LocalRootActivation::Unavailable for same path with different identity (nothing written; daemon treats it as Environmental with a fixed status message); a different canonical path supersedes pending and blocked plans and pending recoveries and starts a new generation; the legacy v1 adoption branch (which the hygiene lane turned into a fresh generation but left pending v1 plans untouched) applies the same supersede-and-retire step so no stale v1 plan can replay against a new root; Busy removed; adopt_local_root starts a new generation unconditionally and is used by setup and set-root; set-root accepts the same path when identity differs; tests: unmounted-root simulation (rename the root away and create an empty directory at the same path) asserts Unavailable and no baseline loss, path change with pending work asserts supersede then Activated, set-root same-path re-adoption. Files: src/journal.rs, src/bin/omaboxd.rs, src/bin/omabox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: schema, dispositions. Ownership: root generation policy. Claim: unassigned.
