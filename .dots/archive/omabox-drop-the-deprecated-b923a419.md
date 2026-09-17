---
title: Drop the deprecated rev field from exact download requests
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-09-17T14:48:13.957310+03:00\\\"\""
closed-at: "2026-09-17T14:54:15.545405+03:00"
close-reason: "implemented, gates green: cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test (257+89+... passed); download argument is path=rev:<rev> only, 7 fake-Dropbox assertions pin the revision through the path"
---

Problem: src/dropbox.rs stage_worker_download_at builds files::DownloadArg::new("rev:<rev>").with_rev(<rev>), sending the deprecated top-level rev field next to the rev: path. Since 2026-09-17 Dropbox rejects that request with HTTP 400 'Rev parameter is deprecated. Please provide rev in path parameter as rev:{rev}', so every exact download is blocked (observed for two CamScanner PDFs after the per-path block landed). Acceptance: the download argument carries only path=rev:<rev> and no rev field; the fake-Dropbox protocol test asserts the Dropbox-API-Arg header has no rev key and still pins the revision through the path; the revision check against the returned metadata is unchanged. Files: src/dropbox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none. Ownership: exact download request. Claim: agent=heron workspace=main
