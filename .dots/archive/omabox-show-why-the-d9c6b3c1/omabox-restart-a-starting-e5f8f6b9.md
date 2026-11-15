---
title: Restart a starting service on upgrade
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T06:23:14.992575+02:00"
closed-at: "2026-11-15T06:47:19.241097+02:00"
---

Problem: src/install.rs:186-215 rolls back only a running unit but cannot tell a starting one, src/bin/omabox.rs:463 restarts after a root change only a unit seen running, and both StartAfterChange errors say the service did not start when reading or clearing its state failed. Acceptance: upgrade restarts a ready service with rollback, restarts a starting service onto the new build and keeps it, and recovers any other; set-root restores what Release stopped then recovers; each StartAfterChange says the service could not be started or checked; README and docs/remediation-2026-09.md describe the starting case; tests cover each. Depends: omabox-give-the-svc-df5029f5. Claim: agent=worker-upgrade-starting workspace=.jj-ws.noindex/omabox-restart-a-starting.
