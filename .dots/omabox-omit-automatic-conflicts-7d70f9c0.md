---
title: Omit automatic conflicts from user status
status: active
priority: 2
issue-type: task
created-at: "\"2026-08-25T12:53:28.372959+02:00\""
---

Problem: omabox status renders durable conflict records as "different versions are being preserved automatically" even though preservation and convergence are automatic and the user has no action; this violates the requested no-unactionable-conflicts UI. Acceptance: durable conflicts remain recorded and preserved but are neither queried nor rendered by the CLI status path; pending sync/recovery and unknown observations remain unchanged; the status snapshot proves conflict paths/details and payload secrets are omitted. Files: src/status.rs only. Verify: focused status tests plus nightly fmt, clippy -D warnings, full tests, and forbidden-pattern scan. Depends: none; independent of the active QML-only dashboard dot. Ownership: CLI status rendering/tests only; no planner, journal schema, recovery, daemon log, or QML changes.
