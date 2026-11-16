---
title: Link a Dropbox login in DROPBOX
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:58:54.605378+02:00"
closed-at: "2026-11-17T00:06:29.188314+02:00"
---

Problem: the Habu port cannot link a new login to its account and root (rust src/dropbox.rs link_authorized :516), which omabox setup needs; the remote-root check exists only inside DAEMON. Acceptance: DROPBOX:LINK and CHECK-ROOT behave as Rust's link and validate_remote_root, DAEMON uses CHECK-ROOT; dropbox-test, reconcile-test and daemon-test pass. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
