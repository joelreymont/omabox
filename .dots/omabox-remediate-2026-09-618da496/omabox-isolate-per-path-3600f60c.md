---
title: Isolate per-path failures as blocked plans
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.369247+02:00"
blocks:
  - omabox-journal-schema-ver-487764f0
  - omabox-publish-unsupported-and-8439e183
  - omabox-classify-daemon-errors-dd34c00a
  - omabox-protect-in-flight-34128729
---

Problem: src/reconcile.rs:386-388 and :249-274 cancel the whole pool and fail the pass on any worker error; src/recovery.rs:505-570 propagates every per-path Dropbox error; rejected uploads stay pending and are re-uploaded twice per pass (tests/dropbox_fake.rs:3421-3428); :797-818 supersedes a pending plan only for conflicts and directory collisions so stale download plans survive remote changes; src/bin/omabox.rs:398-423 counts blocked work as pending; a local permission failure at one plan's path, such as a read-only conflict copy parent (src/recovery.rs copy_name_occupied), fails the pass, so later pending plans and the scan never run. Design: docs/remediation-2026-09.md section D. Acceptance: DownloadResult::{Staged, Blocked, Failed}; classify_download_error maps 4xx, verification mismatch, occupied stage, ENOTDIR/ELOOP/special file to BlockReason and everything else to Failed; Blocked never cancels the pool and calls block_plan with retry_at now+3600; MutationOutcome::Rejected, StageDestinationOccupied, RemoteObject block the plan; local effect primitives probe with O_PATH|O_NOFOLLOW and open with O_NONBLOCK (FIFO test must not hang); every pass re-plans blocked paths: differing decision supersedes and re-records, matching decision past retry_at unblocks, otherwise counted as blocked; pending plans with a differing fresh decision are superseded; omabox status lists blocked paths with reason; snapshot gains blocked count; set-root counts only pending plans and recoveries; fake-Dropbox tests: 409 download plus unrelated upload in one pass (upload completes, plan blocked, daemon-level error absent), rejected upload uploaded exactly once then blocked, blocked plan superseded after local content changes, retry after retry_at, a conflicting upload under a read-only directory plus an unrelated upload under a writable one in one pass (the unrelated upload completes). Files: src/reconcile.rs, src/recovery.rs, src/local.rs, src/journal.rs, src/status.rs, src/runtime_status.rs, src/bin/omabox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: schema, scanunknown, dispositions, slots. Ownership: per-path failure lifecycle. Claim: unassigned.
