---
title: Complete Omabox dashboard
status: active
priority: 1
issue-type: task
created-at: "\"2026-08-24T23:35:56.094701+02:00\""
blocks:
  - omabox-make-widget-upgrades-e1eda907
---

Problem: the panel shows transfer status but lacks the requested production settings and visual polish. Acceptance: retain the concurrent transfer list, aggregate progress, speed, and animated progress; add a compact in-memory rolling bandwidth chart, current sync-root display, folder selection with explicit confirmation, service start/stop/restart controls, and concise setup/error actions through the CLI. Keep the Omarchy panel as the tray/dashboard, read runtime status plus omabox settings --json, and perform actions through omabox; no daemon IPC, durable history, unactionable conflicts, or second tray process. Files: packaging/omarchy/plugins/local.omabox QML/manifest/README only. Verify mocked status/settings/action behavior, QML/plugin validation, then publish live only when unlocked with unchanged QuickShell PID and no new coredump.
