---
title: Report a full disk by code, not by errno
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:42:29.761545+02:00"
closed-at: "2026-11-16T19:18:22.711961+02:00"
---

Problem: DAEMON decides a full disk and a missing config.toml from FS:ERRNO after the failure unwinds (SPACE-OR and CONFIG-READ, src/daemon.f:110-117), and cleanup on the way up clears it (FS:CLOSE-DIR in a pass's finally, STATUS's publish, FS-FAILS), so a full disk during replay or a download reports the sync folder unavailable. Acceptance: LOCAL, JOURNAL and CONFIG throw E-DISK-FULL on ENOSPC and CONFIG throws E-MISSING for an absent config.toml; DAEMON maps them by code and reads no FS:ERRNO. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-disk-full.
