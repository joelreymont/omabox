---
title: Verify a refused conflict once
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T12:44:12.543823+02:00"
closed-at: "2026-11-16T14:36:12.024498+02:00"
---

Problem: after a delete_v2 409 conflict, DROPBOX's DELETE-REFUSED (src/dropbox.f:2152) and REPLAY's STATE (src/replay.f:1238) each send get_metadata, and FOLDER-REFUSED and the upload machine's conflict arm do the same; Rust verifies a conflict once (resolve_explicit_conflict, dropbox.rs:1325-1336). Acceptance: changed_dropbox_file_during_directory_conversion_replans_without_a_conflict_row passes with Rust's requests. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-conflict-once.
