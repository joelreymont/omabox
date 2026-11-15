---
title: Store a rotated Dropbox refresh token
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T23:51:33.285919+02:00"
closed-at: "2026-11-16T00:19:57.333118+02:00"
---

Problem: src/dropbox.f's refresh (FORM :731, ISSUED-MEMBER :742, KEPT-TOKEN :748) reads only access_token, so a refresh reply that rotates the refresh token is dropped; the Rust transport stores the rotated token in Secret Service before it uses the new access token, keeps it usable and retries the store before each call when storing fails (rust src/transport.rs:1009-1140, :1270-1350; src/dropbox.rs:477). Acceptance: DROPBOX hands a rotated refresh token to a store its caller supplies before the new access token is used; a failed store answers Rust's RotationNotStored text, keeps the rotated token and the access token, and is retried before the next call; transport.rs's tests :2879, :2912 and :2959 pass under their names in src/dropbox-test.f; docs/habu-dropbox.md says so. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-dropbox-rotation.
