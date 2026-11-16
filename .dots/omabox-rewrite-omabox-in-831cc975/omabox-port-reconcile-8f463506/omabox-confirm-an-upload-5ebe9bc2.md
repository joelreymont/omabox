---
title: Confirm an upload answer Omabox cannot accept
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T12:44:12.541215+02:00"
closed-at: "2026-11-16T14:36:12.017426+02:00"
---

Problem: a 2xx answer of upload or upload_session/finish that does not parse or is incomplete throws E-ANSWER out of DROPBOX:UPLOAD (COMMITTED-AT?, src/dropbox.f:2601), and one with another content hash is refused content-hash-mismatch (COMMITTED?); Rust takes any such answer as a mutation that may have applied and verifies it (dropbox.rs:1200-1205, 1339-1352, 2438). Acceptance: local_directory_preserves_a_dropbox_file_under_a_synchronized_name passes with Rust's requests. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-upload-answer.
