---
title: Make active download slot ownership atomic
status: active
priority: 2
issue-type: task
created-at: "\"2026-09-05T10:30:06.055982+03:00\""
---

Problem: leasing only missing downloads can reset an active slot before the pool reservation check. Acceptance: one pool-owned critical section selects and reserves slots from the complete live pending/blocked download bindings plus in-flight bindings; protected slots are never reset or multiply assigned; cancellations release reservations; unknown occupants remain preserved and fallback still works. Files: src/reconcile.rs slot scheduling, src/local.rs slot leasing, focused fake tests and relevant formal model only. Verify: gated overlapping-pass downloads; cancelled queued work followed by retry; protected checkpoint and unknown occupant tests; Rust gates and DownloadLifecycle/DownloadExecutor TLC. Depends: none. Ownership: Sol slot lane in fix-slots workspace; Astra design/review. This scoped fix excludes the old broader slot dot's stage/conflict cleanup and does not absorb its workspace.
