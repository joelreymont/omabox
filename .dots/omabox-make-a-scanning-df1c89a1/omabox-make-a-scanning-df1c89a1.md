---
title: "Make a scanning pass cheaper than Rust's"
status: active
priority: 2
issue-type: task
created-at: "2026-11-23T19:32:06.682892+02:00"
---

Problem: a pass that scans every entry (after a restart, after an overflow of change notices, and as a backstop) costs Habu 425 ms of CPU on the live-shaped harness tree on a performance core where Rust's costs 131 ms (2026-11-24). Most of it is staging two or three scratch rows per file in SQLite on every pass and deciding every path in Habu. The user, 2026-11-23: "rca and troubleshoot. come up with a solution to be faster than rust". Approach (approved 2026-11-25): one walk in path byte order merged against the stored rows, staging only differences; deciding skips settled keys in SQL; main's page cache at 128 KiB; no end-of-scan recheck (the user: "Drop it"). Acceptance: a pass that scans every entry of the live tree costs less CPU than Rust's 0.31 s, and the harness pass less than Rust's on a performance and an efficiency core, with idle private memory within 2.27 MB. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-scan.
