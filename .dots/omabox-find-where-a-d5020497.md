---
title: Find where a cache-reuse pass spends its time
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T15:06:58.712798+02:00"
---

Problem: at 4,000 small files a local scan that reuses every cached hash takes about 124 ms, 2.5 times the 49 ms of one that hashes every file; decoding the cache's rows explains about 39 ms (bench scripts from the decode-once lane). Acceptance: the remaining time attributed to its causes by measurement, each cause fixed or dotted. Depends: none. Claim: unassigned.
