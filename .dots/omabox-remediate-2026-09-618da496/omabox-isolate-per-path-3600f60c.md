---
title: Isolate per-path failures as blocked plans
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.369247+02:00"
blocks:
  - omabox-protect-in-flight-34128729
---

Problem: the Habu daemon must not let a failure at one path cancel the pass. A 4xx download, a verification mismatch, an occupied stage, a rejected upload, a local permission failure (such as a read-only parent of a conflict copy) or a special file at one path must not stop unrelated paths, and the old behaviour stopped the whole pass on any worker error, left rejected uploads pending and uploaded them twice per pass, kept stale pending plans after remote changes, and counted blocked work as pending. Acceptance: a failure at one path blocks only that path's plan with a reason and a retry time one hour later; unrelated paths in the same pass still complete (tests against the fake Dropbox: a 409 download plus an unrelated upload in one pass; a conflicting upload under a read-only directory plus an unrelated upload under a writable one). A rejected upload is attempted once, then blocked. Every pass re-plans blocked paths: a differing fresh decision supersedes the plan and re-records it, a matching decision past its retry time unblocks it, otherwise it counts as blocked. A pending plan whose fresh decision differs is superseded. Opening a FIFO or other special file never hangs (test). Status lists blocked paths with their reasons, the runtime snapshot counts them separately from pending work, and set-root counts only pending plans and recoveries. Depends: omabox-protect-in-flight-34128729. Claim: unassigned.
