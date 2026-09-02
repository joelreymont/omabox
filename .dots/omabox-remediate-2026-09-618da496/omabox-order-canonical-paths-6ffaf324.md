---
title: Order canonical paths bytewise everywhere
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-09-02T11:28:11.346952+02:00\\\"\""
closed-at: "2026-09-02T12:55:30.802501+02:00"
close-reason: "landed as change rkxzprnr (Order canonical paths by bytes with a newtype); destruction pass items fixed incl. subtree range bound; gates green at merged tip: fmt, clippy -D warnings, 231 tests"
---

Problem: src/journal.rs:1302-1309 returns baselines in SQLite BLOB (byte) order while src/reconcile.rs:1317-1321, :1431-1434 and for_each_known_path (:1448-1502) use component-wise Path order; src/local.rs:2692 binary-searches a byte-ordered hash cache with Path::cmp. Files under a directory with a sibling like notes.txt lose their baseline every pass (deletions resurrect, edits become conflicts) and are re-hashed every scan. Design: docs/remediation-2026-09.md section A. Acceptance: CanonicalPath newtype in src/model.rs with bytewise Ord replaces PathBuf canonical fields in BaselineRecord, RemoteObservationRecord, local map keys, pending/conflict maps, RemoteInventoryChange::DeleteSubtree; dropbox_canonical_path deleted; cached_hash compares bytes; merge proptest generates multi-component names over [a-z./ -] with baselines loaded through a real Journal; fake-Dropbox test with report/x beside report.txt covers local delete (expects delete_v2 with parent_rev), remote delete, and local edit (expects upload, no conflict); hash-cache test with x.txt and x/y.txt asserts zero hash jobs on unchanged rescan; all new tests fail before the fix. Files: src/model.rs, src/journal.rs, src/reconcile.rs, src/local.rs, src/dropbox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none. Ownership: reconcile merge and canonical identity. Claim: agent=worker-canonical workspace=.jj-ws/omabox-order-canonical-paths-6ffaf324
