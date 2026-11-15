---
title: "Find why a large upload's finish reports a hash mismatch"
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T11:01:33.199048+02:00"
---

Problem: the installed daemon uploads a 201752253-byte file in 7 session chunks and the finish call answers ContentHashMismatch on 4 of 6 attempts; the other 2 failed with a send-body timeout. The stage's bytes hash to the content hash sent, each chunk and resend is cut from the right buffer slice, and a connection that failed mid-body is dropped, so the bytes Dropbox stored differ from the bytes the client meant to send. Logging of resent and corrected chunks showed neither in the last two failures, which rules out a chunk landing out of order. Leading hypothesis, unproven: the finish call sends no bytes yet carries the whole file's content hash, a field Dropbox checks against the bytes of that call. The Habu daemon must be checked against the same real exchange. Acceptance: the cause is shown by evidence from the real exchange, and a large multi-chunk upload (about 200 MB) either succeeds against real Dropbox or stops with a typed error naming the cause. Depends: none. Claim: unassigned.
