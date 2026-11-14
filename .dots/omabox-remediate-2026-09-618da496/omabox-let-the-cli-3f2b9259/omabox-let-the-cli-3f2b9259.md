---
title: Let the CLI repair a missing root and tidy setup
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.376382+02:00"
blocks:
  - omabox-store-state-paths-a4a19746
---

Problem: status, settings and set-root fail when the stored sync root is missing, because loading the configuration resolves the root; setup takes the daemon lock while the service may hold it; and a failed or interrupted release can leave the service stopped. The bounded authorization code read and the README corrections have landed. Design: docs/remediation-2026-09.md section L (config split, setup). Acceptance: every child closes. Depends: none. Claim: unassigned.
