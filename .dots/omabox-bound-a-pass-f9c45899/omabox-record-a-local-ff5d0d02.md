---
title: Record a local scan in the journal
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.057875+02:00"
blocks:
  - omabox-key-the-local-8268dd24
---

Problem: a scan builds its observations, hash cache and jobs in memory and republishes the whole local inventory. Acceptance: JOURNAL words record what a scan confirmed and what differs in the connection's temporary tables and publish only the difference in one transaction. Depends: omabox-key-the-local-8268dd24. Claim: unassigned.
