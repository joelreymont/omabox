---
title: "Scan the local tree onto the journal's scan words"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.060654+02:00"
closed-at: "2026-11-19T15:41:23.071792+02:00"
---

Problem: src/local.f's scan keeps every observation of the tree in the pass's arena. Acceptance: the scan uses the journal's scan words with every scan rule unchanged, a directory's listing lives only until the directory ends, and a scan with every hash cached takes no longer than master's before omabox-record-a-local-ff5d0d02 at about 4,000 and 16,000 files. Depends: omabox-record-a-local-ff5d0d02. Claim: unassigned.
