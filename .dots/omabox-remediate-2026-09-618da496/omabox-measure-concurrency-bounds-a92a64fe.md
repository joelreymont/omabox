---
title: Measure concurrency bounds and idle pass cost
status: open
priority: 3
issue-type: task
created-at: "2026-09-02T11:28:11.379585+02:00"
blocks:
  - omabox-publish-unsupported-and-8439e183
---

Problem: MAX_PARALLEL_HASHES=12 and MAX_PARALLEL_DOWNLOADS=4 have no recorded measurement; the perf commits carry no numbers; PLAN.md requires profiling around performance changes. Design: docs/remediation-2026-09.md section O. Acceptance: examples/scan_bench.rs generates a 50k-file tree and times scans at 1, 4, 8, 12 workers; examples/inventory_bench.rs times application at 10k, 50k, 100k entries; idle pass CPU on a 100k-file tree measured; docs/performance.md records the numbers, the chosen constants, and the inotify decision (implement only if idle pass exceeds 200 ms CPU); if inotify is needed, open a follow-up dot with the measured number. Files: examples/scan_bench.rs, examples/inventory_bench.rs, docs/performance.md, src/local.rs (constants if measurement changes them). Verify: cargo run --release --example scan_bench; cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: passcost, scanunknown. Ownership: performance evidence. Claim: unassigned.
