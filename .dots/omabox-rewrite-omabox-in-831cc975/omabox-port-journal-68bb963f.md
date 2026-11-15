---
title: Port JOURNAL
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T23:11:42.059236+02:00"
closed-at: "2026-11-16T01:20:10.946889+02:00"
---

Problem: omabox has no Habu journal (rust src/journal.rs; docs/habu-rewrite.md:55, :62-63). Acceptance: src/journal.f opens schema 8 or creates it from migrations/, refuses 1 to 7, reads src/oracle/journal.sqlite3 as journal.tsv says, and its sqlite_master equals src/oracle/schema.tsv. Depends: the MODEL dot. Claim: agent=worker workspace=.jj-ws.noindex/omabox-journal-open.
