---
title: Decode a journal record at the cost of its parse
status: open
priority: 2
issue-type: task
created-at: "2026-11-23T12:07:23.654389+02:00"
blocks:
  - omabox-read-omabox-s-3a2e750e
---

Problem: an idle pass over 16,217 entries costs 0.92 s of CPU live, three times the Rust daemon's 0.31 s over 17,939. A third of it is decoding 64,000 journal records per pass with Habu's JSON cursor reader, about 4.3 us each; Rust decodes more records per entry, faster. The rest traces to the bounded-memory design (the scan staged in SQLite, the trust chain parsed per TLS session) or matches Rust's own cost (the walk). Acceptance: with Omabox reading JSON as Habu's JSON values, an idle pass is timed by phase again, and decoding a record costs no more than parsing it does on its own. Depends: omabox-read-omabox-s-3a2e750e. Claim: unassigned.
