---
title: Spell operation paths from local ancestors, never remote casing
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-09-17T14:29:06.923423+03:00\\\"\""
closed-at: "2026-09-17T14:43:16.909625+03:00"
close-reason: "implemented in main workspace, gates green: cargo fmt --check, cargo clippy --all-targets -D warnings, cargo test (all suites); fake-Dropbox test shows a miscased delta folder created inside the local tree, unit tests cover ancestor spelling and non-override"
---

Problem: src/reconcile.rs:1070 picks the display spelling for an operation as local, then remote, then baseline; when a path is absent locally and the remote inventory row carries Dropbox path_display parents whose casing differs from the existing local directories (Dropbox documents only the last component as reliably cased), CreateLocalDirectory and InstallLocal build a parallel lowercase tree on case-sensitive filesystems, the next scan treats it as a case collision and renames it to '(case variant N)', and the rename is pushed to Dropbox; observed 2026-09-16 11:36 as 54 junk directories on both sides. src/dropbox.rs:1898 additionally lets a delta folder Upsert override the recorded casing of an existing directory, diverging from rows not in the delta. Acceptance: the operation spelling is local record, else baseline, else remote, else live plan, and every ancestor component is replaced by the spelling of the local directory observed at that canonical prefix; a delta never changes the recorded spelling of a directory that already exists in the inventory (only a delete followed by a re-create may); unit tests cover the ancestor spelling and the non-override; a fake-Dropbox test shows a delta folder entry with miscased parents being created inside the existing local tree with no case-variant rename and no create_folder_v2 request. Files: src/reconcile.rs, src/dropbox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none. Ownership: reconcile path spelling, remote inventory casing. Claim: agent=heron workspace=main
