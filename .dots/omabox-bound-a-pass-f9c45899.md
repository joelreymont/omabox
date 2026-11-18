---
title: "Bound a pass's memory independently of the tree's size"
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T11:32:25.585101+02:00"
---

Problem: a no-op pass over N entries needs about 2.9-3.9 kB per entry (63 MB at 16,400): whole inventories read into arena vectors that grow by doubling (src/reconcile.f, src/journal.f, src/local.f), plus a JSON cursor per decode (src/model.f READING). The user expects the daemon to use a megabyte or two. Acceptance: a pass's peak memory stays bounded as the tree grows, measured at 4k and 16k entries. Depends: none. Claim: unassigned.
