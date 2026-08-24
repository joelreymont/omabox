---
title: Make widget upgrades safe while locked
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-08-24T23:19:29.013864+02:00\\\"\""
closed-at: "2026-08-25T01:03:35.532353+02:00"
close-reason: Landed fail-closed lock recheck at the exact plugin mutation boundary; staged validation stays outside watched tree, rollback restores prior artifacts/service state, focused race test and Sol verification pass.
blocks:
  - omabox-install-and-upgrade-a26fd6eb
---

Problem: writing a local Omarchy plugin while the session is locked triggers a global plugin-service reload; three observed QuickShell SIGABRTs followed the same stranded session-lock recovery path.
Acceptance: the production install/upgrade/uninstall path checks `omarchy-shell lock isLocked` immediately before changing live plugin files and makes no plugin changes while locked; unlocked publication validates a complete staging directory outside the watched tree and replaces the plugin once, with rollback before success. Document the constraint. Do not modify the lock service or QuickShell.
Files: the minimal production installer/upgrade surface and plugin README only.
Verify: locked-path test proves no live file changes; unlocked-path test/validation; `omarchy plugin validate`; no QuickShell restart or new coredump.
Depends: production installer surface.
Ownership: safe widget publication only, not QML behavior or Omarchy lock internals.
