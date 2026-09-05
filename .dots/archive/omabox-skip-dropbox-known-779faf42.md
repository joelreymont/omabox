---
title: Skip Dropbox known excluded names safely
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T13:05:22.583085+03:00\\\"\""
closed-at: "2026-09-05T13:16:43.619590+03:00"
close-reason: "landed and verified: jj change yrtnunwx implements documented exclusions across scan, planning, status and durable replay; separate Astra review passed. cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test (367 tests, including 78 fake Dropbox cases) passed; MutationLifecycle and DownloadExecutor TLC passed. Release build and daemon self-check passed. Regression tests preserve persisted baselines and payloads across journal reopen while ordinary sibling files continue syncing."
---

Problem: Omabox uploads .DS_Store and repeatedly reports Dropbox rejection for a documented exclusion. Acceptance: one documented filename policy skips known metadata names and temporary prefixes, including nested and case variants, before scan/hash, planning, or replay; matching local files and remote payloads are preserved, baseline records cannot infer deletion, old pending/blocked plans are safely superseded, unrelated files continue syncing, and exclusions do not appear as failures. Files: src/exclusions.rs, src/local.rs, src/reconcile.rs, src/recovery.rs, src/status.rs, src/lib.rs, tests/dropbox_fake.rs, README.md. Verify: focused scanner and fake-server regressions for existing baselines and pending/blocked replay, cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test, TLC MutationLifecycle and DownloadExecutor. Depends: landed SDK migration ltnqlvsx. Ownership: root Astra implements integration and scanner; Sol bounded fake-server tests; separate Astra reviews before landing.
