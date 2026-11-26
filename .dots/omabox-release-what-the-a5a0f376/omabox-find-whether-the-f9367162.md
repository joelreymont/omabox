---
title: "Find whether the daemon's heap grows per pass"
status: active
priority: 2
issue-type: task
created-at: "2026-11-26T09:41:53.271589+02:00"
---

Problem: the live daemon's resident heap rose from 1,072 kB after its startup pass (a634682f, 2026-11-25 18:47) to 1,104 kB at 19:01 and 1,120 kB at 09:37 the next day, over 32 passes with nothing planned. At 16 kB pages a leak under about 500 bytes a pass hides in that, and an always-on daemon would grow by megabytes a year. Acceptance: a sandboxed run of at least 200 passes over the live-shaped tree reports heap bytes in use per pass; if they grow, the growth's allocators as file:line. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-heap-creep.
