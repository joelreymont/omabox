---
title: Bind replay to validated sync root
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-08-24T22:25:41.175379+02:00\\\"\""
closed-at: "2026-08-24T22:49:19.002824+02:00"
close-reason: "landed and verified in 53bd6346: one journal-validated root fd confines every replay effect; deterministic post-validation swap test, full Rust gates, forbidden-pattern scan, and TLC pass"
---

Problem: replay validates sync-root device/inode by path, then destructive operations reopen that path, so a replacement directory can be modified after a root swap. Acceptance: local replay uses one validated root directory handle for validation and every local effect; a deterministic swap-after-validation test leaves the replacement root untouched and the plan pending. Keep the change confined to local replay/effects and focused tests.
