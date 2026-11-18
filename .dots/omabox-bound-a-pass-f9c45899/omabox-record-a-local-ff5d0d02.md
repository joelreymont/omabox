---
title: Record a local scan in the journal
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.057875+02:00"
closed-at: "2026-11-19T15:41:15.698914+02:00"
---

Problem: a scan builds its observations, hash cache and jobs in memory and republishes the whole local inventory. To decide whether to write at all, SCAN-UNCHANGED? (src/journal.f:1375) reads and decodes the whole inventory and hash cache again and compares them: 75 ms at 4,000 cached files, 302 ms at 16,000. Acceptance: JOURNAL words record what a scan confirmed and what differs in the connection's temporary tables and publish only the difference in one transaction. It lands together with omabox-scan-the-local-b929e99d, which moves the scan onto these words. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-scan-publish.
