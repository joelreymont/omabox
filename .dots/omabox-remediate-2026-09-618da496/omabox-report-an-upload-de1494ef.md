---
title: Report an upload content mismatch as itself
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T11:01:33.207910+02:00"
closed-at: "2026-11-17T18:04:15.287903+02:00"
---

Problem: Dropbox answers content_hash_mismatch when the bytes a call carried do not hash to the content hash it was sent with; the replay blocks that plan as RemoteRejected under the generic tag rejected_by_dropbox (src/replay.f:1185), so the status names the path but not the cause. Acceptance: such a block records and shows a tag of its own naming the content mismatch, and a test drives an upload answered content_hash_mismatch to that block. Depends: none. Claim: unassigned.
