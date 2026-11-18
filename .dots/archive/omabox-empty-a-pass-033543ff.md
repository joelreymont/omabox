---
title: "Empty a pass's arena when the pass ends"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T11:32:25.582514+02:00"
closed-at: "2026-11-18T11:42:36.133462+02:00"
---

Problem: src/daemon.f ROOT-ACTIVE reset the pass's arena only when the next pass started, so the idle daemon held a whole pass's chunks (57 MB on a 16,216-entry tree). Acceptance: after a pass the idle daemon's anonymous memory no longer includes the pass's chunks. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-lead
