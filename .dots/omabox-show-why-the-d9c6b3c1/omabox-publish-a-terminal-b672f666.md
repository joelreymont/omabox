---
title: Publish a terminal stopped status
status: active
priority: 2
issue-type: task
created-at: "2026-11-14T16:04:26.930784+02:00"
---

Problem: the daemon has no terminal phase and the unit removes status.json on failed stops. Acceptance: fatal exits publish phase stopped (status schema 3) with the fatal text, and the unit removes status.json only when SERVICE_RESULT is success. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-publish-a-terminal-b672f666
