---
title: Preflight install artifact directories
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T08:33:25.548705+02:00"
closed-at: "2026-11-15T10:03:10.439212+02:00"
---

Problem: an artifact directory that can be searched but not read (mode 0300) lets an upgrade write its artifacts, then fails at sync_directory (src/install.rs:769-772, 'sync an artifact directory', EACCES); the rollback needs the same sync, so it fails too and the user gets RollbackFailed with the old build half restored. The cause is that preflight (src/install.rs:495) never opens the directories the transaction will sync. Acceptance: preflight opens every artifact parent directory the transaction syncs before any effect, so an unreadable one refuses the install with nothing changed (test, skipped as root). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-preflight-install-artifact-a7ec1f54.
