---
title: Release the service during setup
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.599615+02:00"
closed-at: "2026-11-15T08:23:44.635704+02:00"
---

Problem: setup takes the instance lock while the service may hold it, so it refuses and the user must stop the service by hand. Acceptance: setup authorizes first, then releases, changes and restores the service through the function set-root uses; a lock still held after the release is reported as a manually started daemon (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-release-the-svc-33846ca0.
