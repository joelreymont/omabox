---
title: Keep an upgrade whose failed service still fails
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T05:46:19.614680+02:00"
closed-at: "2026-11-15T06:47:19.236141+02:00"
---

Problem: src/install.rs install rolls an upgrade back whenever starting a failed unit fails, including when the daemon fails again for the cause the user has yet to fix, and reports only a systemctl failure with help that says retry. Acceptance: an upgrade of a failed or stopping unit keeps the new build when the start fails and reports that the upgrade completed and the service did not start, naming omabox logs; a running unit's failed restart still rolls back; a test shows the kept build. Depends: omabox-drive-every-svc-fddcfa0d. Claim: unassigned.
