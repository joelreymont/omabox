---
title: Stop re-preparing the hash-cache lookup
status: open
priority: 2
issue-type: task
created-at: "2026-11-23T19:32:11.426718+02:00"
---

Problem: CACHED-SCAN (src/journal.f:1511) joins local_root_binding to the cache; the system SQLite is built with STAT4, under which binding ?1 of that join expires the plan, so each of a pass's 16,000 lookups prepares the statement again (REPREPARE 112,000 of 112,000 in the per-entry hunt) and costs 3.6 us where SQLite answers the lookup without the join in 0.45 us: 7% of a scanning pass. Other statements a pass runs per entry may share the cause. Acceptance: no statement a pass runs per entry re-prepares, measured with sqlite3_stmt_status over a pass, and the lookup costs under 1 us. Depends: none. Claim: unassigned.
