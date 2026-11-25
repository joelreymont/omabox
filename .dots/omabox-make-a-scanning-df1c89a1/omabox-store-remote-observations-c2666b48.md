---
title: Store remote observations in typed columns
status: closed
priority: 2
issue-type: task
created-at: "2026-11-24T20:12:40.124952+02:00"
closed-at: "2026-11-25T13:15:22.168384+02:00"
---

Problem: a scanning pass decodes remote_observations' JSON per row (src/journal.f REMOTE-OBSERVATION-OF), part of the 314 of 629 ms the pass spends decoding. Acceptance: schema 10 holds remote observations in typed columns with no JSON, read and written by SQL, with every package's tests passing. Depends: omabox-store-baselines-in-b39451f5. Claim: agent=worker workspace=.jj-ws.noindex/omabox-scan-1b.
