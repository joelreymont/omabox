---
title: Coalesce staging writes
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-24T23:42:23.603190+02:00\\\"\""
closed-at: "2026-08-25T12:44:11.816559+02:00"
close-reason: Landed as 86c67929. Existing 4 MiB Dropbox hash buffer now writes once per filled block with unchanged hash, byte, error, progress, and durability behavior. Direct strace of 1 GiB delivered in 16 KiB fragments measured 266 total writes (target <=300). Verified fragmentation property coverage, exact-download length handling, fmt, clippy -D warnings, 204 tests, diff/forbidden scans, and independent Sol review CLEAN.
blocks:
  - omabox-resume-interrupted-exact-08dc4996
---

Measured problem: existing verified-stage copy_and_hash writes each ~16KiB reader fragment despite already assembling 4MiB Dropbox hash blocks (~726 writes/s in the live transfer). Acceptance: write each filled hash block once while preserving byte-for-byte output, Dropbox hash, short/overlong detection, durability, and progress behavior. Out-of-tree strace on 1GiB fragmented input should show roughly <=300 writes. No new buffers, async I/O, direct I/O, or cache manager.
