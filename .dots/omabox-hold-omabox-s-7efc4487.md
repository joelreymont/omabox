---
title: "Hold Omabox's bytes in Habu's vectors"
status: open
priority: 2
issue-type: task
created-at: "2026-11-19T16:02:41.328154+02:00"
---

Problem: Omabox holds growable bytes in BUF (src/dropbox.f, src/status.f, src/journal.f and their tests) and hands JSON:WRITE-OPEN-BUF a BUF header; the user asked 2026-11-19 to switch to Habu's merged vector and drop buffers. Habu has not landed the merge (VEC:APPEND, VEC:CAP, VEC:TRIM; byte-buffer.f deleted; JSON's writer taking a vector). Acceptance: no BUF: word in Omabox; every package's tests pass on the Habu that carries the merge. Depends: Habu's BUF-into-vector cutover on master. Claim: unassigned.
