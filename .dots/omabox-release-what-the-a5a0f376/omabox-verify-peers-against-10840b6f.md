---
title: Verify peers against the certificate directory
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T14:32:53.991431+02:00"
closed-at: "2026-11-18T15:17:06.542717+02:00"
---

Problem: libcurl parses its whole built-in CA bundle and keeps it cached for the daemon's life. Acceptance: Habu's CURL can verify peers against a hashed certificate directory instead of the bundle, and Omabox's Dropbox requests use /etc/ssl/certs that way, verified against Dropbox. Depends: none. Claim: agent=worker workspace=/home/joel/Work/habu/.jj-ws.noindex/bob-curl-capath (Habu half)
