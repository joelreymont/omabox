---
title: Drive upgrade and uninstall from the unit state
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T17:21:19.874452+02:00"
closed-at: "2026-11-15T06:47:19.222805+02:00"
---

Problem: src/install.rs reads is-active, so upgrade leaves a failed unit failed after installing a possible fix, and uninstall skips the stop of an activating unit, which then restarts after its binary is gone and stays failed; and upgrade's restart counts toward the start limit without clearing it. Acceptance: upgrade clears the failed state and the start-limit counter, then restarts a running unit or starts a failed one; uninstall stops a running or stopping unit and leaves no failed state, and a failure while reading or clearing that state restores the service as a failed disable does; the UserAction paragraph of docs/remediation-2026-09.md names both; tests show each. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-drive-upgrade-and
