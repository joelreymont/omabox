---
title: "Block an upload's path on a content-hash mismatch"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T11:19:08.611430+02:00"
closed-at: "2026-11-17T11:19:08.618734+02:00"
---

Problem: src/replay.f REJECTION ends the pass when Dropbox refuses an upload with content_hash_mismatch, as Rust did, so one file that keeps failing stops every other path: the Rust daemon failed one 201 MB upload 332 times from 2026-11-15 and synced nothing else. Acceptance: the refusal blocks that path's plan as rejected-by-dropbox, retried after JOURNAL:BLOCK-RETRY-SECONDS, and the pass goes on; replay-test's rejection case says so. Depends: none. Claim: lead.
