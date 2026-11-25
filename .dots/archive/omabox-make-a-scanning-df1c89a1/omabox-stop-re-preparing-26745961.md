---
title: Stop re-preparing the plans query
status: closed
priority: 2
issue-type: task
created-at: "2026-11-23T19:43:35.419787+02:00"
closed-at: "2026-11-24T17:36:12.752971+02:00"
---

Problem: PLAN-QUERY (src/journal.f:2742) joins operations to plans and filters on a bound plans.status = ?1; the partial index one_live_plan_per_path makes the plan depend on the bound value, so each of its 8 uses per pass prepares the statement twice (REPREPARE 8 of 8 over a scanning pass, measured 2026-11-23 with sqlite3_stmt_status in the lookup lane). It is the only statement of a pass that re-prepares. Acceptance: REPREPARE 0 for every statement over a scanning pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-plans.
