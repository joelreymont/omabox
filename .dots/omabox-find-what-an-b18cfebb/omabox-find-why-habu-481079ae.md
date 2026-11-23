---
title: "Find why Habu's per-entry work is slower than Rust's"
status: active
priority: 2
issue-type: task
created-at: "2026-11-23T19:07:56.259427+02:00"
---

Problem: the same idle pass costs Habu 0.92 s over 16,217 entries and Rust 0.31 s over 17,939. Per entry Habu decodes a journal record in about 4.3 us, looks up a cached hash with SQLite in about 4 us and stages about 3 rows, where Rust does the same work in memory with serde; nobody has timed one such step on each side. The user, 2026-11-23: "rca and troubleshoot. come up with a solution to be faster than rust". Acceptance: each per-entry step is timed on both sides on one core, and every Habu step slower than Rust's has a named cause, in Omabox or in Habu, with path:line. Depends: none. Claim: agent=bob scratch=/tmp/claude-1000/prim-rca.
