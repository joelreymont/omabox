---
title: Install downloads in bounded batches
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-24T22:16:05.579867+02:00\\\"\""
closed-at: "2026-08-24T22:25:09.201301+02:00"
close-reason: "landed and verified in c9b528ab: bounded four-download batches install before continuing; full fmt, strict Clippy, 132 tests, doctests, forbidden-pattern scan, and diff check pass"
---

Problem: replay stages every pending Dropbox download before installing any, hiding completed files and allowing staging space to grow with the entire backlog. Acceptance: replay downloads at most the existing worker bound per batch, immediately replays verified installs, repeats until no download is required, preserves deterministic errors/root-generation checks, and never treats a partial batch as inventory evidence. Files: src/reconcile.rs, the smallest selective replay helper in src/recovery.rs, and focused fake/crash tests only. Verify: cargo test --test dropbox_fake pending_exact_downloads; cargo test --test crash_recovery; cargo clippy --all-targets -- -D warnings. Depends: none. Ownership: pending-download replay batching and selective local-plan replay only.
