---
title: Bind replay to validated sync root
status: active
priority: 1
issue-type: task
created-at: "\"2026-08-24T22:25:41.175379+02:00\""
---

Problem: replay validates sync-root device/inode by path, then destructive operations reopen that path, so a replacement directory can be modified after a root swap. Acceptance: local replay uses one validated root directory handle for validation and every local effect; a deterministic swap-after-validation test leaves the replacement root untouched and the plan pending. Keep the change confined to local replay/effects and focused tests.
