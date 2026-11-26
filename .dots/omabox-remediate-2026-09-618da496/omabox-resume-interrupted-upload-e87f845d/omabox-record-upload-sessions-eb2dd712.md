---
title: Record upload sessions in the journal
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:35.989338+02:00"
closed-at: "2026-11-26T13:28:10.824380+02:00"
---

Problem: nothing durable records an upload session. Acceptance: the journal durably records each upload session per operation (session id, confirmed offset, length, content), with read, checkpoint and retire calls, updated at each accepted append. The record is deleted in the transactions that complete, conflict, supersede or purge its operation, and is removed when its operation is pruned; blocking and unblocking the operation keep it (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-upload-record.
