---
title: Implement conditional Dropbox writes
status: active
priority: 2
issue-type: task
created-at: "\"2026-08-23T20:47:57.830429+02:00\""
blocks:
  - omabox-implement-dropbox-auth-fa43e8c2
---

Problem: uploads, remote file deletion, and conflicts must preserve every payload and obey the last known revision. Acceptance: strict create, revision-conditional replace/delete, directory creation, deterministic conflict materialization, recovery of displaced content, and retry-safe ambiguous-result handling are implemented; remote folder deletion remains blocked. Files: write/conflict portions of src/dropbox.rs, src/recovery.rs, tests/dropbox_fake.rs, tests/dropbox_live.rs. Verify: cargo test --test dropbox_fake; cargo test conflict revision. Depends: Dropbox auth and reads dot. Ownership: Dropbox writes and remote conflict behavior.
