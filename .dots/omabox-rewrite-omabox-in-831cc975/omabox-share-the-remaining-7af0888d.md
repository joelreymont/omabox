---
title: Share the remaining duplicate test words
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T15:44:28.997753+02:00"
closed-at: "2026-11-16T15:52:56.058472+02:00"
---

Problem: src/replay-test.f and src/reconcile-test.f still both define UNPROTECTED, DISPLAY, RECORD, GONE, DOWNLOADS$ and LEASED, and src/dropbox-test.f defines its own CFG, MAIN, CURL-READY and OPENED beside src/test-client.f's; a fix to one copy misses the other. Acceptance: each word whose copies do the same is defined once in src/test-client.f and the suites keep their check counts; copies that differ stay, named apart. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-share-rest.
