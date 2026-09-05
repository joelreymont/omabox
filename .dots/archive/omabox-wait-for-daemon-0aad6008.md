---
title: Wait for daemon readiness before finishing upgrades
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T10:30:06.273853+03:00\\\"\""
closed-at: "2026-09-05T10:58:54.432276+03:00"
close-reason: "landed and verified: Astra reviewed readiness boundary, staged binary self-check, notification socket handling and systemd policy. Actual isolated daemon process tests prove self-check without configuration, journal+held lock before READY, and no READY for missing root; pathname/abstract datagrams and self-check rejection preserve old artifacts. Full fmt, clippy all targets -D warnings, cargo test and forbidden scan pass; previous rollback and shell-lock tests retained."
blocks:
  - omabox-recover-environmental-daemon-3dcb7480
---

Problem: upgrade deletes backups after restart command success without a daemon initialization signal. Acceptance: daemon --self-check exits successfully without configuration/credential/state access; staged binary self-check runs before publishing; Type=notify waits for READY=1 after configuration, instance ownership and migrated journal initialization; initialization failures do not signal ready; unit prevents automatic restart for78/70 and removes ephemeral status on stop; previous rollback remains intact and live plugin lock checks retained. Files: src/daemon.rs, src/bin/omaboxd.rs, src/install.rs, packaging/systemd/omabox.service and focused tests. Verify: private Unix notification socket and daemon process tests; staged self-check failure preserves prior artifacts; restart failure rollback; Rust gates. Depends: daemon lifecycle fix. Ownership: Sol daemon lane second commit after its first feature, Astra review. No live install/service manipulation.
