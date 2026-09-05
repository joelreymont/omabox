---
title: Durably block rejected remote mutations
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T10:30:06.351519+03:00\\\"\""
closed-at: "2026-09-05T11:09:34.880175+03:00"
close-reason: "landed and verified: Astra reviewed owning-plan durable blockers, exact stage-object classification and retained upload bytes; rejected mutations stay blocked across reopen and retry once when due, changed decisions supersede and Unknown holds. Successful sibling upload/download, original exact-download stage preservation and FIFO safety scenarios retained. On final integrated tree fmt, clippy all targets -D warnings, cargo test 317 nonignored, forbidden scan, MutationLifecycle TLC 48 states and SyncBehavior TLC 102 states pass."
blocks:
  - omabox-make-active-download-cb539616
---

Problem: permanent remote mutation failures remain pending and repeat before/after each scan. Acceptance: rejected mutations, occupied upload stages and confirmed remote-object blockers durably block only their owning plan with bounded retry; sibling operations continue; existing fresh-decision and due-retry logic recovers; local-object replay blockers use same policy where existing classification already identifies them; status counts durable blockers consistently. Files: src/recovery.rs, src/reconcile.rs shared blocker plumbing, src/status.rs only as needed and tests/dropbox_fake.rs. Verify: rejected upload attempted once then held across reopen; sibling upload/download succeeds; due retry and changed-decision supersession; unknown observations retain block; Rust gates and MutationLifecycle/SyncBehavior TLC. Depends: slot scheduling fix; daemon wiring integration. Ownership: Sol slot lane follow-up, no overlap with root/daemon source ownership; excludes general listing/SDK/conflict feature work.
