---
title: "Copy strings into an arena with Habu's word"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-24T21:21:15.099725+02:00"
closed-at: "2026-11-26T14:04:02.052566+02:00"
---

Problem: six files define the same five-line copy of a str into an arena (src/stale.f COPY :128, src/journal.f COPIED :151, src/config.f COPY :177, src/omabox.f KEPT :636, src/test-client.f COPIED :45, src/omabox-test.f COPIED :136) because Habu's ARENA has no such word. Acceptance: Omabox defines no copy of its own and calls Habu's; every package's tests pass. Depends: Habu's arena string copy on master. Claim: agent=worker workspace=.jj-ws.noindex/omabox-arena-copy.
