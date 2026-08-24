---
title: Install and upgrade user service
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-08-24T23:35:35.883379+02:00\\\"\""
closed-at: "2026-08-25T00:59:17.365208+02:00"
close-reason: Landed rootless install/upgrade/uninstall with staged validation, atomic exchange/rollback, lock-safe plugin publication, retained-data uninstall, concise docs, clean Sol verification and release smoke.
blocks:
  - omabox-finish-prod-cli-4bbd8004
---

Problem: production installation, upgrade, uninstall, and packaging are manual and inconsistent. Acceptance: add rootless install/upgrade/uninstall commands for ~/.local/bin, the per-user systemd unit, and the Omarchy plugin; fix packaged ExecStart to %h/.local/bin/omaboxd; stage and validate complete artifacts, atomically publish, daemon-reload, preserve enabled/running state, and roll back failures before a replacement daemon launches. Uninstall removes only installed program/unit/plugin artifacts and retains config, journal, recovery, credentials, and synced files with a clear report. No updater daemon or package framework. Files: one small install module, CLI wiring, packaging/systemd/omabox.service, README, concise PLAN.md correction, focused temporary-home/fake-systemd tests. Verify release smoke test and full Rust gates.
