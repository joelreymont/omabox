---
title: "Make a scanning pass cheaper than Rust's"
status: active
priority: 2
issue-type: task
created-at: "2026-11-23T19:32:06.682892+02:00"
---

Problem: a pass that scans (after any local or remote change, and at least hourly once idle passes are skipped) costs Habu 629 ms of CPU over 16,000 files on a performance core and 0.92 s live, where Rust's took 0.31 s over 17,939 entries. Per entry, Habu decodes journal records 35 to 44 times slower than serde: Omabox reads each record several times (src/model.f MEMBER :967, READ-STRING :982, TAGGED :1012), Habu's reader matches keys linearly and costs about 62 ns per token, and the hash-cache lookup re-prepares (JOURNAL.md, 2026-11-23, what one entry costs). The user, 2026-11-23: "rca and troubleshoot. come up with a solution to be faster than rust". Acceptance: a pass that scans every entry of the live tree costs less CPU than Rust's 0.31 s, with idle private memory within 2.27 MB. Depends: none. Claim: agent=bob design=Plan.
