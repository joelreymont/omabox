---
title: "Reach Dropbox through Habu's HTTPS client"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T16:33:56.113425+02:00"
closed-at: "2026-11-19T18:40:36.583284+02:00"
---

Problem: src/dropbox.f reaches Dropbox through Habu's CURL, so the daemon loads libcurl and its dependencies (1.8 MB relocated pages idle) and keeps a pass's TLS connections until the next pass. Acceptance: Omabox reaches Dropbox only through Habu's HTTPS client (Habu dot habu-speak-https-without-478be362), libcurl is no longer loaded or a package dependency, every request keeps its meaning and failure classes, and between passes the daemon holds no connection but the longpoll's while a pass still reuses its connections. Depends: Habu's habu-speak-https-without-478be362. Claim: agent=bob workspace=.jj-ws.noindex/omabox-https.
