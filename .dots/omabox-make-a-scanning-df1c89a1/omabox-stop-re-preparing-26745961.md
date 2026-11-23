---
title: Stop re-preparing the plans query
status: open
priority: 2
issue-type: task
created-at: "2026-11-23T19:43:35.419787+02:00"
---

Problem: PLAN-QUERY (src/journal.f:2742) joins operations to plans and filters on a bound plans.status = ?1; under the system SQLite's STAT4 the bound value expires the plan, so each of its 8 uses per pass prepares the statement twice (REPREPARE 8 of 8 over a scanning pass, measured 2026-11-23 with sqlite3_stmt_status in the lookup lane). It is the only statement of a pass that re-prepares. Acceptance: REPREPARE 0 for every statement over a scanning pass. Depends: none. Claim: unassigned.
