---
title: "Guard SERVICE's stderr write and its child"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.210822+02:00"
closed-at: "2026-11-17T00:06:29.310871+02:00"
---

Problem: src/service.f SETTLE-IN writes stderr outside FD:WITH-NOSIGPIPE, so a closed stderr kills omabox between a stop and its start; INHERITED and QUIET allocate after the spawn, so a failed allocation loses the child; eleven comments run past two lines. Acceptance: the write holds SIGPIPE off, the cell exists before the spawn, service-test passes. Depends: none. Claim: agent=f-service workspace=.jj-ws.noindex/omabox-f-service.
