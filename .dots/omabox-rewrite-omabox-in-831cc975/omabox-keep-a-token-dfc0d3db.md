---
title: Keep a token answer out of HTTP-STATUS
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T09:55:54.366681+02:00"
closed-at: "2026-11-16T11:21:23.053804+02:00"
---

Problem: DROPBOX:HTTP-STATUS (src/dropbox.f:1772) answers the token route's status when a refresh made during a download fails, so REPLAY:DOWNLOAD-BLOCKAGE would block the path for an authorization failure. Acceptance: HTTP-STATUS answers 0 after a token request's failure; a test through the fake's token route shows it. Depends: the token-route scripts of omabox-name-the-ported-3d567232. Claim: lead workspace=.jj-ws.noindex/omabox-fixes.
