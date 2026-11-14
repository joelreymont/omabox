---
title: Start a failed service after its fix
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T16:17:49.954385+02:00"
closed-at: "2026-11-14T17:27:56.583427+02:00"
---

Problem: after a fatal exit (78) the user fixes the cause with omabox setup or omabox settings set-root, but neither starts a failed unit (src/bin/omabox.rs:218-254, :407-438), so the service stays stopped and the widget keeps a reason that no longer holds. Acceptance: a successful setup or set-root starts the service when systemd reports it failed; an inactive (paused) service stays stopped. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-show-why-the-d9c6b3c1
