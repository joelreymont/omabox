---
title: Hold the daemon to one malloc arena
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T16:03:45.391600+02:00"
---

Problem: libcurl resolves names on a new thread each pass, and glibc gives such threads and the CURL loop task their own malloc arenas, whose free tops it never returns (0.7 MB for the loop, 48 kB per resolver arena). Acceptance: omaboxd limits glibc to one arena before its first thread starts, and the live idle daemon's maps show no thread arena. Depends: none. Claim: unassigned.
