---
title: Verify with deleted entries included
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T12:44:12.545945+02:00"
closed-at: "2026-11-16T14:36:12.036987+02:00"
---

Problem: DROPBOX:METADATA (src/dropbox.f:1805) sends get_metadata without include_deleted; Rust's verify sends include_deleted true (dropbox.rs:1359) and takes a deleted entry as absent. Acceptance: rejected_paths_do_not_stop_unrelated_sync_or_report_progress passes with Rust's get_metadata bodies. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-deleted-metadata.
