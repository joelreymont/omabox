---
title: Say when Dropbox cannot be reached
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T23:30:30.179388+02:00"
closed-at: "2026-11-18T09:54:22.467246+02:00"
---

Problem: a pass whose Dropbox call got no answer (timeout, DNS, connect) reports 'Dropbox is temporarily unavailable.' (src/daemon.f:76, through RETRY at src/daemon.f:106-107), the text of a 429 or 5xx answer, so a local network outage reads as Dropbox failing (2026-11-17 23:08-23:27, after a resume on weak Wi-Fi). Acceptance: a retry whose last call got no answer reports 'Dropbox could not be reached.' and one Dropbox answered keeps today's text (tests). Depends: none. Claim: agent=reach-worker workspace=.jj-ws.noindex/omabox-reach.
