---
title: "Bound a pass's memory independently of the tree's size"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T11:32:25.585101+02:00"
closed-at: "2026-11-27T07:19:45.764490+02:00"
---

Problem: a no-op pass over N entries needs about 2.9-3.9 kB per entry (63 MB at 16,400): whole inventories read into arena vectors that grow by doubling (src/reconcile.f, src/journal.f, src/local.f), plus a JSON cursor per decode (src/model.f READING). The user expects the daemon to use a megabyte or two. Plan (schema 9 approved by the user 2026-11-18): the pass stops copying the journal into its arena and reads it row by row: local observations are keyed by canonical path; deciding visits one known path at a time and keeps only what is not a no-op; case collisions are read from the journal; a scan records what it confirmed and what differs in temporary tables and publishes only the difference; a hash-cache row decodes in one pass. One child dot per commit. Acceptance: a pass's peak memory stays bounded as the tree grows, measured at 4k and 16k entries. Depends: the children. Claim: unassigned.
