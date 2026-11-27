---
title: Resume interrupted upload sessions from the journal
status: closed
priority: 2
issue-type: task
created-at: "2026-09-02T17:12:47.641414+02:00"
closed-at: "2026-11-27T19:39:15.656670+02:00"
---

Problem: an interrupted large upload restarts from zero after a restart because the upload session lives only in memory, and finish failures that leave the session unknown are retried without verification. Acceptance: every child closes; an interrupted large upload resumes from its last confirmed offset after a restart, and when the outcome of a finish call is unknown the daemon verifies the remote file's metadata before finishing again. Depends: none. Claim: unassigned.
