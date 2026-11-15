---
title: Confirm a delete Dropbox answered at another rev
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T01:44:57.328666+02:00"
closed-at: "2026-11-16T02:30:01.845337+02:00"
---

Problem: src/dropbox.f DELETED-READ takes a files/delete_v2 answer as done once its path matches; Rust's delete_file (src/dropbox.rs:960-985, validate_deleted_file) also requires the deleted entry to be a file at the requested rev, and confirms through get_metadata otherwise. Acceptance: a delete_v2 answer whose metadata is not a file at the requested rev is confirmed as a lost answer is; a test shows it. Depends: none. Claim: unassigned.
