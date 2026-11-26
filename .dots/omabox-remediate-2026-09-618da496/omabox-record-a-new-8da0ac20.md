---
title: Record a new conflict that cannot be placed
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T09:34:58.732781+02:00"
closed-at: "2026-11-26T14:06:12.313878+02:00"
---

Problem: when a new conflict's copy name or staging slot is occupied, the daemon records nothing. Every pass, at least every 30 s, re-stages and re-hashes the whole local file (about four times its size read per pass), and status never shows the path or why it is blocked. Acceptance: the block is saved in the journal with its reason and a retry time an hour later; before that time a pass stages and hashes nothing for the path; status lists the path with its reason; the record goes once the copies are placed or the path no longer conflicts (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-unplaced-conflict.
