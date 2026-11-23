---
title: Find what keeps the trimmed heap resident
status: active
priority: 2
issue-type: task
created-at: "2026-11-23T10:50:59.363902+02:00"
---

Problem: the live daemon at master 523ca02d calls malloc_trim(0) before each long poll and sleep (src/daemon.f RELEASE-HEAP), yet its [heap] stays fully resident through every pass: 1744 kB of 1744, as the previous build's 2240 kB of 2240. Each heap runs from its start to the next 2 MiB boundary, so its size reflects alignment, not use, and something fills it. A probe on this glibc shows malloc_trim(0) returns freed pages below a live block (1984 kB to 48 kB). Acceptance: a reported cause from a sandboxed run of the daemon's pass over about 16,000 entries: heap bytes in use at the trim, by caller, and what dirties the rest. Depends: none. Claim: agent=bob scratch=/tmp/claude-1000/heap-rca2.
