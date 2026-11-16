---
title: Begin a PKCE login in AUTH
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:55:34.148163+02:00"
closed-at: "2026-11-17T00:06:29.177509+02:00"
---

Problem: the Habu port cannot start a browser login (rust src/auth.rs begin). Acceptance: AUTH:BEGIN gives a verifier and the authorize URL byte for byte as dropbox-sdk 0.20.3 builds it; auth-test passes. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
