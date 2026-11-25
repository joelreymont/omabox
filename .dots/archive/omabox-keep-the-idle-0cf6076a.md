---
title: Keep the idle daemon within 2.27 MB
status: closed
priority: 2
issue-type: task
created-at: "2026-11-25T18:55:01.672377+02:00"
closed-at: "2026-11-26T09:58:16.730602+02:00"
---

Problem: the live daemon at a634682f, idle after its startup pass, holds 2,336 kB of anonymous memory (smaps Anonymous by mapping kind: heap 1,072, unnamed 528, file-backed 640, stack 96; 3 threads; fds io_uring and inotify), against 2,272 kB for the 21e2bb8b build on 2026-11-23 (heap 1,040, unnamed 480, file-backed 656, stack 96): 64 kB over the budget the watch design promised to keep. Acceptance: the live idle daemon's anonymous memory is within 2,272 kB, or each kB over it is attributed with file:line to something the idle daemon needs and the user accepts it. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-daemon-rest.
