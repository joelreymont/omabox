---
title: Send per-chunk content hashes on upload_session/append
status: open
priority: 3
issue-type: task
created-at: "2026-09-02T12:59:01.979111+02:00"
blocks:
  - omabox-move-the-dropbox-cb30bc34
  - omabox-make-idle-passes-24e8ce2a
---

Problem: append_v2 requests carry no content_hash (src/dropbox.rs append_upload_session_chunk), so Dropbox cannot verify a chunk server-side; corruption is only detected after commit as UploadedContentMismatch and retried in full. Computing the hash at send time would re-read every 32 MiB chunk (rejected: doubles upload I/O). Design: extend docs/remediation-2026-09.md section J: the upload stage already hashes every 4 MiB block while staging (src/local.rs stage_upload_at); persist the per-block digests beside the immutable stage (one 32-byte digest per block, stored in the stage's xattr or a sibling file created with the stage, verified by the whole-file hash), expose them through StagedUpload, and send the chunk's Dropbox content hash (SHA-256 over the chunk's block digests) in each append and the final finish. Acceptance: stage_upload records block digests once with zero extra reads; append and finish requests carry content_hash (fake test asserts the header value equals dropbox_content_hash over the captured chunk body); a stage without digests (pre-existing) is re-hashed once and upgraded; no new crate. Files: src/local.rs, src/dropbox.rs, tests/dropbox_fake.rs, docs/remediation-2026-09.md. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: client, passcost. Ownership: upload staging digests. Claim: unassigned.
