---
title: Install downloads in bounded batches
status: active
priority: 2
issue-type: task
created-at: "\"2026-08-24T22:16:05.579867+02:00\""
---

Problem: replay stages every pending Dropbox download before installing any, hiding completed files and allowing staging space to grow with the entire backlog. Acceptance: replay downloads at most the existing worker bound per batch, immediately replays verified installs, repeats until no download is required, preserves deterministic errors/root-generation checks, and never treats a partial batch as inventory evidence. Files: src/reconcile.rs, the smallest selective replay helper in src/recovery.rs, and focused fake/crash tests only. Verify: cargo test --test dropbox_fake pending_exact_downloads; cargo test --test crash_recovery; cargo clippy --all-targets -- -D warnings. Depends: none. Ownership: pending-download replay batching and selective local-plan replay only.
