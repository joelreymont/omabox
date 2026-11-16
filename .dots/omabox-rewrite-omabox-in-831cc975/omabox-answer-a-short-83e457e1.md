---
title: "Check a download's length as it is read"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T09:55:54.359808+02:00"
closed-at: "2026-11-16T11:21:23.057275+02:00"
---

Problem: DROPBOX checks a download's body length only after its quotation returns (SETTLED, src/dropbox.f:1620). READ-BODY answers 0 at a short body's end, which LOCAL's exact read takes for a failed read (LOCAL:E-STAGE-READ, errno 0), and a long body reaches LOCAL's own length check (E-CHANGED); docs/habu-dropbox.md and Rust's DownloadVerificationFailed say refused unverified. Acceptance: a body one byte short or one byte long answers refused unverified, logged once, and READ-BODY never answers an early 0 or a byte past the file. Depends: none. Claim: lead workspace=.jj-ws.noindex/omabox-fixes.
