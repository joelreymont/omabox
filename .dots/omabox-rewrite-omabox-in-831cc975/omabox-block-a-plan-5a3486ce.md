---
title: Block a plan whose download fails verification
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T01:52:07.751169+02:00"
closed-at: "2026-11-16T14:36:11.986943+02:00"
---

Problem: src/dropbox.f's DOWNLOAD answers refused unverified for an answer that fails its checks or does not parse; nothing maps that reply to a block yet, so it would end the pass, and the next pass meets the same plan. The Rust daemon blocks that plan alone as DownloadVerificationFailed (src/reconcile.rs:585-613), and does the same for downloaded bytes whose content changed (RemoteContentChanged). Acceptance: the download job's caller blocks such a plan as download-verification-failed; unrelated plans proceed; tests show each. Depends: none. Claim: unassigned.
