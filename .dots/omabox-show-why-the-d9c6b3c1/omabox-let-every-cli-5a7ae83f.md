---
title: Let every CLI start pass the start limit
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T17:21:19.872540+02:00"
closed-at: "2026-11-14T17:27:56.597362+02:00"
---

Problem: StartLimitBurst=5 counts manual starts, but the CLI clears the start-limit counter only for a failed unit, so the sixth resume, service start or restart, or set-root restart in ten minutes is refused. Acceptance: each of those starts clears the failed state and the start-limit counter first; tests show each. Depends: omabox-stop-only-a-29ace131. Claim: agent=worker workspace=.jj-ws.noindex/omabox-let-every-cli-start
