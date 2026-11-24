---
title: Store local observations in typed columns
status: active
priority: 2
issue-type: task
created-at: "2026-11-24T20:27:00.382299+02:00"
---

Problem: a scanning pass decodes local_observations' JSON per row (src/journal.f LOCAL-OBSERVATION-OF), part of the 314 of 629 ms the pass spends decoding. Acceptance: schema 10 holds local observations in typed columns with no JSON, read and written by SQL, an unconvertible stored row kept as unknown, with every package's tests passing. Depends: omabox-store-remote-observations-c2666b48. Claim: agent=worker workspace=.jj-ws.noindex/omabox-scan-1c.
