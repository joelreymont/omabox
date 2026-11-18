---
title: Release idle connections between passes
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T16:03:45.393978+02:00"
---

Problem: libcurl keeps a pass's TLS connections (0.24 MB) until the next pass, which in a quiet tree comes after libcurl's 118 s reuse limit, so it reconnects anyway. Acceptance: between passes the daemon holds no connection but the longpoll's, and a pass still reuses its connections. Depends: none. Claim: unassigned.
