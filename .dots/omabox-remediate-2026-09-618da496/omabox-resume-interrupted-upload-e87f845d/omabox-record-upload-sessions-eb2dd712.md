---
title: Record upload sessions in the journal
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:35.989338+02:00"
---

Problem: nothing durable records an upload session. Acceptance: schema v8 adds upload_sessions keyed by operation (session id, confirmed offset, length, content), with read, checkpoint and retire calls; the record is deleted in the transactions that complete, conflict, supersede or purge its operation and cascades on prune; block and unblock keep it (tests). Depends: none. Claim: unassigned.
