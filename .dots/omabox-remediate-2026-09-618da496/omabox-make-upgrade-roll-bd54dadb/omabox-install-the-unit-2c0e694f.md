---
title: Install the unit under XDG_CONFIG_HOME
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.591019+02:00"
closed-at: "2026-11-15T07:49:37.085497+02:00"
---

Problem: Layout hard-codes ~/.config for the systemd unit, which systemd reads from XDG_CONFIG_HOME. Acceptance: the unit goes under XDG_CONFIG_HOME/systemd/user by config.rs's resolution rule; the plugin stays under ~/.config/omarchy, the only place Omarchy reads plugins (test). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-install-the-unit-2c0e694f.
