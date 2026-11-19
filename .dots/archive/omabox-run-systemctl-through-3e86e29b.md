---
title: "Run systemctl through Habu's capture words"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T15:06:58.706138+02:00"
closed-at: "2026-11-19T15:30:15.285570+02:00"
---

Problem: src/service.f:244-330 spawns systemctl with its own descriptor, pipe, drain and wait words (SHUT, HELD-CELL, DEV-NULL, CHANNEL, PLACE, SPAWN-WITH, DRAINED), a copy of what Habu's process library does (src/lib/process-env.f RUN-ARGV-ENV-*-CAPTURE). Acceptance: SERVICE runs systemctl through Habu's capture words and keeps no spawn code of its own; its failures classified and tested as today. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-svc-run.
