---
title: "Accept Omabox's own widget folder in setup"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-26T15:47:13.715124+02:00"
closed-at: "2026-11-26T16:14:33.434310+02:00"
---

Problem: src/omabox.f WIDGET-THERE? treats any folder at ~/.config/omarchy/plugins/local.omabox as WIDGET-TAKEN, but Rust's setup installed the widget there as a folder and the user's dotfiles keep it, so setup fails on every host Rust set up (seen on spark). Acceptance: setup leaves a folder whose manifest.json names id local.omabox in place and goes on; any other folder, file or link is still refused. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-widget.
