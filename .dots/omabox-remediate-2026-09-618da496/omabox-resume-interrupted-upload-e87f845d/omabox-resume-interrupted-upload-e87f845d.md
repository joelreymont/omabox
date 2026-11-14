---
title: Resume interrupted upload sessions from the journal
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T17:12:47.641414+02:00"
---

Problem: an interrupted large upload restarts from zero after a restart because the upload session lives only in memory, and finish failures that leave the session unknown are retried without verification. Design: docs/remediation-2026-09.md section J, 'Durable upload sessions'. Acceptance: every child closes. Depends: none. Claim: unassigned.
