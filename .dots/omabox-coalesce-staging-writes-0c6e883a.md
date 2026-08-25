---
title: Coalesce staging writes
status: active
priority: 2
issue-type: task
created-at: "\"2026-08-24T23:42:23.603190+02:00\""
blocks:
  - omabox-resume-interrupted-exact-08dc4996
---

Measured problem: existing verified-stage copy_and_hash writes each ~16KiB reader fragment despite already assembling 4MiB Dropbox hash blocks (~726 writes/s in the live transfer). Acceptance: write each filled hash block once while preserving byte-for-byte output, Dropbox hash, short/overlong detection, durability, and progress behavior. Out-of-tree strace on 1GiB fragmented input should show roughly <=300 writes. No new buffers, async I/O, direct I/O, or cache manager.
