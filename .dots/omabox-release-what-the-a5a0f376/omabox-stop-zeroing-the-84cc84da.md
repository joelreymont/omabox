---
title: "Stop zeroing the temp scan tables' pages"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-23T11:09:58.876464+02:00"
closed-at: "2026-11-23T11:10:12.246629+02:00"
---

Problem: Arch's SQLite is built with SECURE_DELETE, so each pass's DELETE FROM of the temp scan tables (src/journal.f SCAN-TABLES) journals every freed page into the in-memory journal. A 16,217-row table's delete peaks SQLite at 3.4 MB, against 301 kB with temp.secure_delete off. The heap hunt saw 2.59 MB of 1 KB journal blocks a pass dirty the heap's top, which glibc here returns only in 2 MiB steps. Acceptance: writable journals set temp.secure_delete off and journal-test checks it. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-heap-fixes.
