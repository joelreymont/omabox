---
title: Refuse symlinked and self install destinations
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.587731+02:00"
closed-at: "2026-11-15T09:32:09.604366+02:00"
---

Problem: install path_kind treats a symlink as a file, so install swaps out a user's symlink, and the installed CLI can upgrade onto itself. Acceptance: install and uninstall refuse a symlink at any destination (final component only; symlinked ancestors still work) and a source that is its destination (same device and inode), each with a typed error and help, changing nothing (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-refuse-symlinked-and-aa343628.
