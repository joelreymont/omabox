---
title: Diagnose a denied local write
status: active
priority: 2
issue-type: task
created-at: "2026-11-16T09:55:54.374204+02:00"
---

Problem: a local write the system denies (EACCES, EPERM, EROFS) under the sync root ends the pass, as the user decided on 2026-11-16, but LOCAL's line names only the operation, the path and the errno (src/local.f IO-FAILS), so the user cannot tell what to fix. Acceptance: the line also names the nearest directory that denies the write with its mode and owner, or the read-only filesystem; a test with a read-only parent shows it. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-denied-local (DW2a, then DW2b).
