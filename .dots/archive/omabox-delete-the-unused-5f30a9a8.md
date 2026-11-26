---
title: Delete the unused FROM-STATX
status: closed
priority: 2
issue-type: task
created-at: "2026-11-26T19:09:15.783067+02:00"
closed-at: "2026-11-26T19:09:46.477756+02:00"
---

Problem: src/journal.f:852 FROM-STATX is public but nothing calls it; INSPECT-ROOT-AT's comment (:1012) describes itself through it. Acceptance: FROM-STATX is gone, INSPECT-ROOT-AT's comment stands alone, journal-test passes and both binaries build. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-dead-statx.
