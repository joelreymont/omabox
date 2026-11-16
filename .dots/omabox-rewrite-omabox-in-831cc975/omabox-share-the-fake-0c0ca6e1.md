---
title: "Share the fake client's test helpers"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T10:50:19.008810+02:00"
closed-at: "2026-11-16T15:44:11.461014+02:00"
---

Problem: src/replay-test.f and src/reconcile-test.f each define the fake Dropbox client's helpers (OPENED, CURL-READY, ACCOUNTED, NEW-LINK, RETRY?, FAILED); every fix lands twice. src/reconcile-test.f also copies src/replay-test.f's checkpointed-partial helpers (HASHING, REMAINING, XS-SIZE, XS, FILL-XS, CHECKPOINT, FAILING, READY-PARTIAL, CHECKPOINTED, SERVES-PAST and its hash) and src/local-test.f's BOUND, as SOCKET-AT. Acceptance: one test-support file defines them, the suites load it, and none defines its own copy. Depends: the REPLAY stack and RECONCILE's listing commits landed (both files change in open lanes). Claim: agent=worker workspace=.jj-ws.noindex/omabox-share-helpers.
