---
title: Report a completed fix whose service start failed
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T16:47:12.692307+02:00"
closed-at: "2026-11-14T17:27:56.590134+02:00"
---

Problem: when setup or set-root succeeds but starting the failed service then fails, the CLI returns the start's ServiceError as the command's error and never says the change is done, and setup's tail (lock release before the start) has no test. Acceptance: such a run reports the completed change and the failed start separately; a test fails if setup starts the service before releasing its lock or skips the start. Depends: omabox-drive-svc-commands-f5cceaa4. Claim: agent=worker workspace=.jj-ws.noindex/omabox-report-a-completed-da7bfe36
