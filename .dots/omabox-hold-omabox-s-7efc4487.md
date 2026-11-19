---
title: "Hold Omabox's bytes in Habu's vectors"
status: open
priority: 2
issue-type: task
created-at: "2026-11-19T16:02:41.328154+02:00"
---

Problem: Omabox holds growable bytes in BUF (src/dropbox.f, src/status.f, src/journal.f and their tests) and hands JSON:WRITE-OPEN-BUF a BUF header; the user asked 2026-11-19 to switch to Habu's merged vector and drop buffers. Habu has not finished the merge: byte-buffer.f remains and JSON's writer still takes a BUF (JSON:WRITE-OPEN-BUF). Acceptance: no BUF: word in Omabox; UNDONE-CASE (src/dropbox-test.f) shows that a failed OPEN leaves none of the client's vectors allocated, as its BUF:LIVE? checks do for buffers today (the values vector has no such check); every package's tests pass on the Habu that carries the merge. Depends: Habu's BUF-into-vector cutover on master. Claim: unassigned.
