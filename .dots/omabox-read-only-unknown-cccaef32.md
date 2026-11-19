---
title: Read only unknown observations for attention
status: open
priority: 2
issue-type: task
created-at: "2026-11-19T16:16:07.565974+02:00"
---

Problem: src/attention.f LOCAL-ENTRIES and REMOTE-ENTRIES (:304-320) read the whole local and remote inventories (JOURNAL:LOCAL-INVENTORY, JOURNAL:REMOTE-INVENTORY) into the arena to list the few observations that are unknown, so omabox status grows with the tree. Acceptance: attention reads only the unknown observations from the journal; its entries are unchanged. Depends: none. Claim: unassigned.
