---
title: Let the CLI repair a missing root and tidy setup
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.376382+02:00"
---

Problem: a setup interrupted after it released the service can leave the service stopped. Acceptance: every child closes; setup never leaves the sync service stopped after an interruption, and the service returns to the state observed before setup stopped it. Depends: none. Claim: unassigned.
