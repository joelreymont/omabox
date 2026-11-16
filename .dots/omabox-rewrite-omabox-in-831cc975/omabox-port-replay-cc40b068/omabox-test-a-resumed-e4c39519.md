---
title: "Test a resumed download's bytes"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T03:22:41.109469+02:00"
closed-at: "2026-11-16T04:12:05.135006+02:00"
---

Problem: src/test-dropbox.f keeps at most TEXT-CAP (1024) bytes per rev (:711-720, CONTENT! :1364), and a download slot resumes only from a 64 MiB checkpoint, so no test serves bytes past a partial's offset: REPLAY's resume arm (RESUME-INTO, src/replay.f) is shown only by the Range it sends. Acceptance: the fake serves a rev whose leading bytes it does not keep, from an offset at or past them; a replay test loses a download's answer after a checkpoint, and the next call resumes from the checkpoint and stages the file with its content hash. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-replay-resume
