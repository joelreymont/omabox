---
title: Verify atomic remote inventory
status: closed
priority: 2
issue-type: task
created-at: '2026-08-25T22:40:54.273709+02:00'
closed-at: "2026-08-25T22:43:56.103375+02:00"
close-reason: Reset/rebuild failure regression, full nightly gates, and exhaustive InventoryPublication TLC passed
---

Problem: Remote inventory safety spans cursor deltas, reset-triggered full rebuilds, multi-page validation, and one atomic SQLite publication; the reset-plus-failed-rebuild path lacks a real integration regression and the state machine is not formally modeled. Acceptance: a finite TLA+ model checks that partial pages, validation failures, crashes, and resets never change the durable inventory/cursor; only a complete validated delta or full listing publishes atomically; a fake-Dropbox test proves a failed rebuild after cursor reset retains the exact prior inventory and cursor. Files: formal/{InventoryPublication.tla,InventoryPublication.cfg,README.md} and tests/dropbox_fake.rs. Verify: focused fake test, full nightly gates, exhaustive TLC. Depends: none. Ownership: remote inventory publication model and reset/rebuild regression only.
