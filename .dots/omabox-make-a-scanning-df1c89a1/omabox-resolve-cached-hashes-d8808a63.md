---
title: Resolve cached hashes in SQL
status: active
priority: 2
issue-type: task
created-at: "2026-11-24T21:11:40.108328+02:00"
---

Problem: the walk looks up the hash cache once per regular file (local.f COLLECT-FILE -> JOURNAL:CACHED-HASH), one SELECT and record copy each. Acceptance: the walk records every file as a job and one SQL statement after it moves the jobs a cache row covers to the reused hashes; CACHED-HASH and SCAN-REUSE are gone; model, journal, local, reconcile and omabox tests pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-scan-2b.
