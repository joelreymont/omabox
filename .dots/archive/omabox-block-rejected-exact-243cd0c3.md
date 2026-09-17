---
title: Block rejected exact downloads per path instead of exiting
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-09-17T14:29:06.915912+03:00\\\"\""
closed-at: "2026-09-17T14:42:25.666047+03:00"
close-reason: "implemented in main workspace, gates green: cargo fmt --check, cargo clippy --all-targets -D warnings, cargo test (all suites); fake-Dropbox tests cover 400 and unmapped 4xx downloads next to completing siblings"
---

Problem: src/dropbox.rs:2257 classifies every HTTP 400 (SdkError::BadRequest) and every unmapped HTTP status as ApiOutcome::Invariant, src/reconcile.rs:538 leaves those download failures unblocked, so download_worker cancels the pool, the pass fails, daemon.rs maps Invariant to exit 70 and the unit's RestartPreventExitStatus keeps the service down until a manual restart (observed 2026-09-17 11:15 on one CamScanner PDF). src/dropbox.rs:2284 also erases the Dropbox error body before logging, so the cause is unrecoverable from the journal. Acceptance: a 400 or other unmapped 4xx on an exact download blocks only that plan as BlockReason::DownloadUnavailable { status } with the standard retry delay while sibling downloads and uploads finish and the daemon stays up; the worker logs the path, reason and the retained cause at warn; DropboxError::sdk keeps a bounded, control-character-free copy of BadRequest/UnexpectedResponse/ServerError/UnexpectedHttpError bodies instead of clearing them; unit tests cover the classification and the bounded body; a fake-Dropbox test covers a 400 download next to a completing sibling. Files: src/dropbox.rs, src/reconcile.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none. Ownership: download failure classification. Claim: agent=heron workspace=main
