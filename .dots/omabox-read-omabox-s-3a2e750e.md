---
title: "Read Omabox's JSON as Habu's JSON values"
status: open
priority: 2
issue-type: task
created-at: "2026-11-19T16:02:41.330270+02:00"
blocks:
  - omabox-make-a-scanning-df1c89a1
---

Problem: Omabox reads JSON with Habu's cursor reader (JSON:READ-INIT, READ-NEXT, READ-STR-EQ?, READ-FINISH, READ-DISPOSE and the rest, in src/model.f, src/dropbox.f, src/auth.f, src/journal.f, src/omabox.f); the user asked 2026-11-19 to switch to Habu's new JSON package, whose JSON:value and JSON:PARSE replace the cursor reader. Acceptance: no cursor-reader word in Omabox; every package's tests pass on the Habu that carries the package. Depends: omabox-make-a-scanning-df1c89a1, which moves the tree tables off JSON. Claim: unassigned.
