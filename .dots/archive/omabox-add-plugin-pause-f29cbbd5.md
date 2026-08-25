---
title: Add pause and resume controls
status: closed
priority: 2
issue-type: task
created-at: "2026-08-25T22:03:35.562727+02:00"
closed-at: "2026-08-25T22:11:18.560011+02:00"
close-reason: "landed and verified: nightly tests, Clippy, fmt, forbidden scan, Qt 6 QML tests, release upgrade, QuickShell survival, and installed pause/resume service transition all pass"
---

Problem: Omabox exposes service mechanics instead of explicit sync Pause/Resume controls for bandwidth-sensitive use. Acceptance: `omabox pause` stops the enabled user service without disabling it; `omabox resume` starts it; the plugin calls those commands, immediately presents a non-error paused state, and removes Start/Stop/Restart controls; docs describe interruption-safe resume. Files: src/bin/omabox.rs and packaging/omarchy/plugins/local.omabox/{Status.qml,Panel.qml,README.md,tests/tst_Status.qml}. Verify: CLI and QML tests pass and repository gates remain clean. Depends: none. Ownership: these CLI and plugin files only.
