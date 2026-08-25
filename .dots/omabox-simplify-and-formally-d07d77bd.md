---
title: Simplify and formally verify resumed downloads
status: active
priority: 0
issue-type: task
created-at: "\"2026-08-25T09:36:08.091995+02:00\""
---

Problem: live recovery of one 31.9GB verified download caused about 129GB of reads, the resumed-download implementation is large, and the existing TLA+ model does not cover slots/checkpoints/range resume. Acceptance: identify every full-file pass with measured or instrumented evidence; remove redundant reads and code only where atomic verified install and restart recovery remain intact; model four bounded slots, durable checkpoint-before-offset, tail truncation, exact-range continuation, full verification, promotion/install, unknown occupants, root/operation rebinding, and crashes in TLA+ with invariants that unverified bytes are never installed and user/unknown bytes are never overwritten. Keep the pending operation as journal authority and retain cross-filesystem correctness. No cache manager, new database state, generic state machine framework, or speculative optimization. Files: src/local.rs, src/dropbox.rs, minimal reconcile plumbing, formal/DownloadLifecycle.tla/config, focused tests. Verify: targeted read-count evidence before/after; resume/crash/range tests; fmt, Clippy, all tests, forbidden scan; TLC exhaustive run. Depends: landed resume implementation. Ownership: resumed exact-download lifecycle and its formal model only.
