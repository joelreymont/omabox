---
title: Answer a short resumed body as unverified
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T09:55:54.359808+02:00"
---

Problem: a resumed download whose body is one byte short, through REPLAY's bridge, throws LOCAL:E-STAGE-READ, logged with errno 0 ('could not read stage input during read resumed download'), where docs/habu-dropbox.md and Rust's DownloadVerificationFailed say refused unverified; the plan then ends every pass instead of blocking. Reproducer: in src/replay-test.f BAD-RESUMES, TEST-DROPBOX:SHORTEN then STAGED-AT throws LOCAL:E-STAGE-READ. Acceptance: that body answers refused unverified, logged once; the 'valid range, empty body' step of interrupted_exact_download_resumes_only_from_a_valid_range is ported. Depends: none. Claim: unassigned.
