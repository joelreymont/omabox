---
title: Test a failed change whose restart fails
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T17:21:19.871171+02:00"
closed-at: "2026-11-14T17:27:56.595118+02:00"
---

Problem: no test reaches RootChangeAndRestore in set_sync_root, so mapping it to StartAfterChange would tell the user a change that failed was kept. Acceptance: a test fails unless a failed change with a failed restart gives RootChangeAndRestore and keeps the original root. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-show-why-the-d9c6b3c1
