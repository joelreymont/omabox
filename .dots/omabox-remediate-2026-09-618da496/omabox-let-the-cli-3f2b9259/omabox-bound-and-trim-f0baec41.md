---
title: Bound and trim the authorization code
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.601059+02:00"
closed-at: "2026-11-15T07:49:37.083981+02:00"
---

Problem: read_authorization_code reads an unbounded line and trims only the line ending. Acceptance: at most AUTHORIZATION_CODE_LIMIT+1 bytes are read, surrounding whitespace is trimmed, and oversized, empty and padded codes are tested. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-bound-and-trim-f0baec41.
