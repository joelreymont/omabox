---
title: "Scan the local tree onto the journal's scan words"
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.060654+02:00"
blocks:
  - omabox-record-a-local-ff5d0d02
---

Problem: src/local.f's scan keeps every observation of the tree in the pass's arena. Acceptance: the scan uses the journal's scan words with every scan rule unchanged, and a directory's listing lives only until the directory ends. Depends: omabox-record-a-local-ff5d0d02. Claim: unassigned.
