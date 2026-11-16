---
title: "Check a download's content hash"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T10:12:35.663922+02:00"
closed-at: "2026-11-16T11:21:23.044655+02:00"
---

Problem: DROPBOX:DOWNLOAD (src/dropbox.f:1982) is told only the rev, and CHECKED (:1336) compares only the rev, where Rust refuses an answer whose content_hash is not the plan's (dropbox.rs:863, DownloadedIdentityChanged); a resume answered with another hash is staged. Acceptance: DOWNLOAD takes the content hash asked, and an answer carrying another answers refused unverified, logged once. Depends: none. Claim: lead workspace=.jj-ws.noindex/omabox-fixes.
