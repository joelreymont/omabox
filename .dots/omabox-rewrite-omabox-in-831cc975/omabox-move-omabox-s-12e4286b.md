---
title: "Move omabox's strings to str"
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T20:09:28.824715+02:00"
---

Problem: omabox passes a string as two items, ^u8 n (src/dropbox.f, src/test-dropbox.f, src/dropbox-test.f, docs/habu-dropbox.md), and a role such as a path or a revision as a bare string, though the user settled that a string is one item, str, with roles as NEWTYPE or DEFTYPE over it (JOURNAL.md, 'The size of ^T'). Acceptance: omabox's files on str, each role a NEWTYPE or DEFTYPE, the dropbox suite passing. Depends: Habu dot habu-spell-pointers-t-9f752b95 (str in Habu, steps 4-7) landing. Claim: unassigned.
