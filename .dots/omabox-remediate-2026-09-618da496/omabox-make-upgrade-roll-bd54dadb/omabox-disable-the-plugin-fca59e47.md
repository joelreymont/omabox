---
title: Disable the plugin on uninstall
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.589572+02:00"
closed-at: "2026-11-15T09:38:46.180623+02:00"
---

Problem: uninstall removes the plugin files but leaves the plugin enabled in the Omarchy shell. Acceptance: uninstall disables local.omabox through omarchy-shell before removal, rescans after, and re-enables it when a later step fails (fake command test). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-disable-the-plugin-fca59e47.
