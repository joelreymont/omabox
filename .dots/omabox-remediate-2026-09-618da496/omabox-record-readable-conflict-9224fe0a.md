---
title: Record readable conflict copies and surface them
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.372056+02:00"
blocks:
  - omabox-protect-in-flight-34128729
---

Problem: conflict copies are hidden files named .omabox-conflict-<side>-<sha256> (src/local.rs:3917-3952) that status never lists (src/status.rs:37-104) and the snapshot cannot show; prepare_conflict re-runs every pass (src/reconcile.rs:842-856) re-hashing the file about six times. Design: docs/remediation-2026-09.md section H. Acceptance: deterministic names '<stem> (conflicted copy, <side>, <hash8>)<ext>' where hash8 is the first eight hex digits of the existing internal_name digest, side is local or Dropbox; crash-safety unchanged (replay yields exactly one copy per side, test); a verified download stage is renamed into the remote copy name; a path whose conflict record exists and whose copies are present is skipped (test asserts no re-hashing or download on the second pass); omabox status lists conflicts with copy names; snapshot gains conflicts (bounded 20) and conflict_count; Panel.qml and Status.qml show the count and paths with the QML mocks updated. Files: src/local.rs, src/reconcile.rs, src/recovery.rs, src/status.rs, src/runtime_status.rs, packaging/omarchy/plugins/local.omabox/Panel.qml, packaging/omarchy/plugins/local.omabox/Status.qml, packaging/omarchy/plugins/local.omabox/tests, tests/crash_recovery.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: schema, slots. Ownership: conflict lifecycle. Claim: unassigned.
