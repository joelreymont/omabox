---
title: "Make an idle pass cheaper than Rust's"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-23T12:07:23.654389+02:00"
closed-at: "2026-11-26T10:11:24.017462+02:00"
---

Problem: every 44 s, after the long poll comes back empty, a pass walks the whole tree (16,220 entries, 3,459 directories), stages it in SQLite and decides every known path again, decoding its records: 0.92 s of CPU live, 2.1% of a core, with nothing to do. The Rust daemon did the same work in memory for 0.31 s. Local changes wait for the long poll to come back before any pass sees them. The user, 2026-11-23: "we are not 3 times better than rust while being 3 times slower". Acceptance: a pass with nothing changed costs less CPU than the Rust daemon's 0.31 s on this machine, measured live, and the idle daemon's private memory stays within today's 2.27 MB. Depends: none. Claim: agent=bob design=Plan.
