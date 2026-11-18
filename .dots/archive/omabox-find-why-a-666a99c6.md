---
title: Find why a pass with cached hashes is slower
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T11:32:25.586807+02:00"
closed-at: "2026-11-18T15:31:04.135442+02:00"
---

Problem: with files older than RACY-WINDOW (src/local.f) a no-op pass that reuses the hash cache takes 1,150 ms at 16,400 entries, twice the 572 ms of one that hashes every small file. Each pass decodes every hash-cache row's JSON twice (src/local.f:1829 and src/journal.f:1320-1321, the second only to decide whether to write), and one decode costs 18 µs because src/model.f:1117 and :1127 parse the whole object once per member (src/model.f:957). Acceptance: a hash-cache row decodes in one pass over its JSON, with today's acceptance rules, measured per row and per pass at about 4,000 and 16,000 entries; the second read goes with omabox-bound-a-pass-f9c45899's scan. Depends: Habu's JSON:READ-LISTED skipping members its list does not name (a trailing `*`). Claim: agent=worker workspace=/home/joel/Work/habu/.jj-ws.noindex/bob-json-members (Habu half)
