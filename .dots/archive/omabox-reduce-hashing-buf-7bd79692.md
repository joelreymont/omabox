---
title: Reduce hashing buffer memory
status: closed
priority: 2
issue-type: task
created-at: '2026-08-25T22:32:56.202560+02:00'
closed-at: "2026-08-25T22:39:38.272836+02:00"
close-reason: RSS fell 41% with unchanged throughput; full Rust gates, resumable properties, live sync, and DownloadLifecycle TLC passed
---

Problem: Each local hash or exact-download worker allocates a full 4 MiB Dropbox block, so 12 scan workers plus four download workers can retain roughly 64 MiB of anonymous memory. Acceptance: stream each logical 4 MiB Dropbox hash block through a 64 KiB buffer without changing hashes, checkpoint boundaries, exact-download validation, or atomic staging; existing fragmentation property tests and full nightly gates pass; live active-download RSS drops materially without a material throughput regression. Files: src/local.rs. Verify: focused local property/unit tests, full nightly gates, then before/after live RSS and transfer throughput. Depends: none. Ownership: hashing I/O buffer size and loops only.
