---
title: "Fail omaboxd's self-check on a lost write"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T22:50:51.613851+02:00"
closed-at: "2026-11-17T00:06:29.286661+02:00"
---

Problem: src/omaboxd.f SELF-CHECK prints the version with type, which drops write failures (EPIPE, ENOSPC), so --self-check exits 0 with its line lost; Rust's println! fails the process. Acceptance: a failed self-check write exits nonzero. Depends: none. Claim: unassigned.
