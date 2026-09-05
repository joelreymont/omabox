---
title: Durably block rejected remote mutations
status: open
priority: 2
issue-type: task
blocks:
  - omabox-make-active-download-cb539616
created-at: "2026-09-05T10:30:06.351519+03:00"
---

Problem: permanent remote mutation failures remain pending and repeat before/after each scan. Acceptance: rejected mutations, occupied upload stages and confirmed remote-object blockers durably block only their owning plan with bounded retry; sibling operations continue; existing fresh-decision and due-retry logic recovers; local-object replay blockers use same policy where existing classification already identifies them; status counts durable blockers consistently. Files: src/recovery.rs, src/reconcile.rs shared blocker plumbing, src/status.rs only as needed and tests/dropbox_fake.rs. Verify: rejected upload attempted once then held across reopen; sibling upload/download succeeds; due retry and changed-decision supersession; unknown observations retain block; Rust gates and MutationLifecycle/SyncBehavior TLC. Depends: slot scheduling fix; daemon wiring integration. Ownership: Sol slot lane follow-up, no overlap with root/daemon source ownership; excludes general listing/SDK/conflict feature work.
