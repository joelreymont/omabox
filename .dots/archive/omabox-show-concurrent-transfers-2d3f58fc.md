---
title: Show concurrent transfers in the widget
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-08-24T22:51:33.701111+02:00\\\"\""
closed-at: "2026-08-24T23:07:52.893702+02:00"
close-reason: landed in 66ec4d7e; Rust and QML gates pass; installed files match source; QuickShell PID 1903535 survived hot reload and live panel open without QML errors
---

Problem: runtime status publishes only one arbitrary transfer while four downloads can run, so displayed activity and speed are misleading. Acceptance: a versioned snapshot publishes every active bounded transfer; the QML widget accepts old v1 and new v2 snapshots, lists active paths, shows aggregate progress/speed, and animates progress without crashing QuickShell. Keep JSON atomic/private and avoid daemon IPC or history persistence. Files: src/runtime_status.rs and packaging/omarchy/plugins/local.omabox/{Status,Panel}.qml. Verify: runtime-status tests, strict Clippy, qmlformat parse, qmllint, Omarchy plugin validation, and a monitored hot reload. Depends: none. Ownership: ephemeral transfer snapshot and its QML presentation only.
