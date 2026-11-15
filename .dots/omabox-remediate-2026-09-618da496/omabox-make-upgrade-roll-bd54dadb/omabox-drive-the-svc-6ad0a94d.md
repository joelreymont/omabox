---
title: Drive the service before removing replaced files
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:07:55.282795+02:00"
---

Problem: in execute's Starting and Failed/Stopping/Stopped branches (src/install.rs) and in uninstall, transaction.finish() runs before the service is driven and its error is returned bare, so a cleanup failure after the files were replaced skips the restart or recover and reports a plain filesystem error. Acceptance: every branch drives the service before finish(), and a finish failure reports what was done and the service's real state, with help (tests). Depends: none. Claim: unassigned.
