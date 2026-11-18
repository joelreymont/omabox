---
title: Find why a pass with cached hashes is slower
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T11:32:25.586807+02:00"
---

Problem: with files older than RACY-WINDOW (src/local.f) a no-op pass that reuses the hash cache takes 1,146 ms at 16,400 entries, twice the 570 ms of one that re-hashes every small file. Acceptance: the cause is found and fixed; a cached pass is no slower than re-hashing. Depends: none. Claim: unassigned.
