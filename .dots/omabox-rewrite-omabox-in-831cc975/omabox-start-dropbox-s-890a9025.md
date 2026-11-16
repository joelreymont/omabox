---
title: "Start DROPBOX's loops in one word"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.204406+02:00"
closed-at: "2026-11-17T00:06:29.304506+02:00"
---

Problem: src/omabox.f CURLING/LOOP-FAILED repeat src/daemon.f LOOPED/LOOP-FAILED, and every DROPBOX program must start AIO's and CURL's loops itself. Acceptance: one public DROPBOX word runs a step under both loops and throws a DROPBOX code when the curl loop cannot start; the daemon and omabox use it. Depends: none. Claim: agent=f-loops workspace=.jj-ws.noindex/omabox-f-loops.
