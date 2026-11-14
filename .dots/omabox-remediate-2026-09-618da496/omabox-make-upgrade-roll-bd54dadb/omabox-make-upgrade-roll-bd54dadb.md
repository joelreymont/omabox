---
title: Make upgrade roll back on launch failure and harden install paths
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.362911+02:00"
blocks:
  - omabox-classify-daemon-errors-dd34c00a
---

Problem: install, upgrade and uninstall still follow symlinked or self destinations, leave the widget enabled in the shell after uninstall, hide the second failure of a compound error and the primary failure's help, never sweep temporaries a killed run left behind, and remove replaced files before driving the service. Rollback on a failed restart, the staged daemon self-check, XDG_CONFIG_HOME and help on every error have landed. Design: docs/remediation-2026-09.md section L (install items). Acceptance: every child closes. Depends: none. Claim: unassigned.
