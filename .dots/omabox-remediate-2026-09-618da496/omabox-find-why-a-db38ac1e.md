---
title: "Find why a large upload's finish reports a hash mismatch"
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T11:01:33.199048+02:00"
---

Problem: the installed daemon (master at 06:49 on 2026-11-15) uploads Business/Stegos/KYC and contracts.zip (201752253 bytes, 7 session chunks) and upload_session/finish answers ContentHashMismatch on 4 of 6 attempts since 08:07 UTC; the other 2 failed with 'timeout: send body'. The stage's bytes hash to the content hash sent (95745df6...), each chunk and resend is cut from the right buffer slice (src/dropbox.rs upload_file, append_upload_session_chunk), and ureq drops a connection that failed mid-body, so the bytes Dropbox stored differ from the bytes the client meant to send. Logging of resent and corrected chunks showed neither in the last two failures, which rules out a chunk landing out of order. Leading hypothesis, unproven: upload_session/finish sends no bytes yet carries the whole file's content_hash (src/dropbox.rs upload_file), a field Dropbox checks against the bytes of that call. Acceptance: the cause shown by evidence from the real exchange, and a fix that makes the file upload or stop with a typed error naming the cause. Depends: none. Claim: unassigned.
