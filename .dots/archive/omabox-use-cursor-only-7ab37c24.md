---
title: Use cursor-only query before long polling
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-08-25T12:48:40.627320+02:00\\\"\""
closed-at: "2026-08-25T12:51:30.659979+02:00"
close-reason: "landed and verified: commit 1ca4251f; daemon reads Journal::remote_cursor with no remote_inventory call; nightly fmt, clippy -D warnings, all 204 Rust tests, forbidden-pattern scan, and release build passed"
---

Problem: after every reconciliation pass omaboxd calls Journal::remote_inventory and decodes every remote observation solely to obtain the durable Dropbox cursor, making the wait path O(remote files). Acceptance: expose the existing typed cursor-only journal query to the daemon and use it before long-polling; missing cursor and journal diagnostics remain unchanged; no inventory rows are decoded on this path. Files: src/journal.rs and src/bin/omaboxd.rs only. Verify: cargo +nightly fmt -- --check; cargo +nightly clippy --all-targets -- -D warnings; cargo +nightly test; source check shows omaboxd uses remote_cursor and not remote_inventory. Depends: none; independent of the active QML-only dashboard dot. Ownership: only the named journal API visibility and daemon cursor lookup; no Dropbox protocol, reconciliation, schema, or QML changes.
