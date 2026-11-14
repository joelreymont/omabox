---
title: Remove dead config and journal code
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.602217+02:00"
---

Problem: config::redacted has no caller and Journal::publish_local_inventory is used only by tests. Acceptance: redacted and Redacted are removed and publish_local_inventory compiles only under cfg(test). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-remove-dead-config-6b0963ca.
