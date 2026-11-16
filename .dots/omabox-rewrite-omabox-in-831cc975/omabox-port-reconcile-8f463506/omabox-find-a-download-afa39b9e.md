---
title: "Find a download's plan without a scan"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T13:33:26.819181+02:00"
closed-at: "2026-11-16T14:36:12.065036+02:00"
---

Problem: src/reconcile.f RUN-DOWNLOAD and RECORD-BLOCK call FIND-PLAN, a linear scan of every pending plan, once per download or block, so a replay step costs the square of its pending downloads: the first sync of a large account. Rust uses a map. Acceptance: one sort per step and a binary search per lookup. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-find-plan
