---
title: Retire obsolete installs after matching observations
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-09-04T21:20:29.451070+02:00\\\"\""
closed-at: "2026-09-04T21:32:40.710642+02:00"
close-reason: "landed and verified: Astra reviewed complete-observation retirement, pending-only path merge, remaining operations and in-flight/unknown guards; Rust format, clippy and full tests passed after integration; SyncBehavior TLC 102 distinct states and MutationLifecycle 48 distinct states passed"
---

Problem: a pending install survives after current local and remote contents agree, permanently blocking the path. Acceptance: fresh matching observations retire stale intent and record the observed baseline; changed safe operation decisions replace stale plans; unknown observations never retire intent and in-flight downloads remain protected. Files: src/reconcile.rs, tests/dropbox_fake.rs. Verify: regression through reconcile_once across repeated passes, Rust gates, SyncBehavior and MutationLifecycle TLC. Depends: none. Ownership: Sol stale-plan agent in isolated review-stale workspace; excludes slot scheduling and other existing remediation ownership.
