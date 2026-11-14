---
title: Sort scans by path bytes
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.609053+02:00"
---

Problem: the scan sorts by Path order while the journal returns byte order, so a tree holding a pair like x/ beside x.txt never matches the stored scan and every idle pass rewrites every row. Acceptance: observations are sorted by path bytes and a repeated scan of such a tree changes no rows (test). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-sort-scans-by-715e4603.
