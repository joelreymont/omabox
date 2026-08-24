---
title: Measure verified install barrier
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-24T22:50:19.791524+02:00\\\"\""
closed-at: "2026-08-24T23:08:01.925122+02:00"
close-reason: "verified out of tree: 1 GiB replay spends 1.11 s on two install hashes but only ~1.1% of measured WAN time; tiny-file SQLite costs ~0.2 ms/completion; live failure proves the next action is reset-on-progress download timeout. Synthetic 485 MiB harness removed."
---

Measure the committed bounded-batch pipeline out of tree with large and small files to attribute post-download wall time among verification reads, fsync, journal commits, and connection setup. Do not add examples, benchmarks, or instrumentation to the repository. Acceptance: reproducible aggregate timings and one smallest evidence-backed next action, or explicit evidence that no change is justified.
