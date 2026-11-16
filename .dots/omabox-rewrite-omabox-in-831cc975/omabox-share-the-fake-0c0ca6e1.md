---
title: "Share the fake client's test helpers"
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T10:50:19.008810+02:00"
---

Problem: src/replay-test.f and src/reconcile-test.f each define the fake Dropbox client's helpers (OPENED, CURL-READY, ACCOUNTED, NEW-LINK, RETRY?, FAILED); every fix lands twice. Acceptance: one test-support file defines them, both suites load it, and neither defines its own copy. Depends: the REPLAY stack and RECONCILE's listing commits landed (both files change in open lanes). Claim: unassigned.
