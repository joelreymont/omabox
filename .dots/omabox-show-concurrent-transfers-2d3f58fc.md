---
title: Show concurrent transfers in the widget
status: active
priority: 1
issue-type: task
created-at: "\"2026-08-24T22:51:33.701111+02:00\""
---

Problem: runtime status publishes only one arbitrary transfer while four downloads can run, so displayed activity and speed are misleading. Acceptance: a versioned snapshot publishes every active bounded transfer; the QML widget accepts old v1 and new v2 snapshots, lists active paths, shows aggregate progress/speed, and animates progress without crashing QuickShell. Keep JSON atomic/private and avoid daemon IPC or history persistence. Files: src/runtime_status.rs and packaging/omarchy/plugins/local.omabox/{Status,Panel}.qml. Verify: runtime-status tests, strict Clippy, qmlformat parse, qmllint, Omarchy plugin validation, and a monitored hot reload. Depends: none. Ownership: ephemeral transfer snapshot and its QML presentation only.
