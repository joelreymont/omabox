---
title: Tighten Dropbox client timeouts, limits, and encoding
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-02T11:28:11.361223+02:00\\\"\""
closed-at: "2026-09-02T16:44:18.430992+02:00"
close-reason: "superseded by omabox-move-the-dropbox-cb30bc34: the wire layer moves to dropbox-sdk; the lane's change rsxorptv (workspace kept until salvage) contributes chained errors, UploadedContentMismatch, auth child handling, ProgressReader::complete, drop-not-drain and their tests; its per-phase timeout configuration was found regressive by the destruction pass and is not carried"
---

Problem: src/dropbox.rs:45-54 sets no request or response-header timeout on the download agent so a dead connection hangs a worker forever; :1019-1031, :1080-1085, :549-556 build a new agent (fresh TLS) per upload, session, and long poll; :36 allows 2 TiB upload sessions against Dropbox's documented 350 GB; :2178-2192 leaves control bytes below 0x20 and 0x7F unescaped in Dropbox-API-Arg; append_v2 omits content_hash (:1205-1211); a failed append retry discards the first error (:1225-1228); :825-831 drains bodies to a sink; :796-803 misreports unparsable Content-Length; :2141-2149 and src/auth.rs:575-583 ignore HTTP-date Retry-After; :1319-1322 discards the metadata error in resolve_ambiguous; src/auth.rs:138-139, :147, :178-179 discard child cleanup errors. Design: docs/remediation-2026-09.md section J. Acceptance: each item implemented as specified with a unit test per behavior (timeout configuration asserted through the agent config, header escaping vectors, 350 GB boundary, content_hash presence in the append request body, chained errors rendered in Display/source chain, HTTP-date Retry-After parsed); no new crate. Files: src/dropbox.rs, src/auth.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none. Ownership: Dropbox transport configuration. Claim: agent=worker-client workspace=.jj-ws/omabox-tighten-dropbox-client-2a6b649a
