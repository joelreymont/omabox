---
title: Keep an unreadable recovery payload in a prune
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T02:49:10.510370+02:00"
closed-at: "2026-11-16T02:51:46.342586+02:00"
---

Problem: src/replay.f's KEEPS? (:475) keeps an expired recovery payload whose verification fails with E-CORRUPT, E-UNSUPPORTED, E-CHANGED, E-OCCUPIED, E-CONTENT-HASH or E-UNSAFE-PATH, but not LOCAL:E-UNREADABLE, so one unreadable payload throws out of PRUNE-COMPLETED-RECOVERIES and ends every reconcile pass (reconcile.rs:1320), against AGENTS.md's rule that repeated bad input must not stop unrelated work. Rust's prune_completed_recoveries_at (recovery.rs:248-256) has the same gap. Acceptance: an expired unreadable payload is kept and its record stays while the prune goes on to the next record, logging nothing; a test shows it. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-replay-unreadable.
