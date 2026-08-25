---
title: Verify automatic sync behavior
status: closed
priority: 2
issue-type: task
created-at: '2026-08-25T22:19:00.211638+02:00'
closed-at: "2026-08-25T22:30:30.723740+02:00"
---

Problem: Basic post-baseline sync behavior is split across planner, protocol, and replay tests, and no top-level formal model checks automatic convergence after edits, deletions, or conflict materialization. Acceptance: real fake-Dropbox reconciliation tests cover later local and remote edits, both deletion directions, and divergent edits through observation, durable planning, conditional effects, exact download, baseline updates, and conflict-side preservation; a finite TLA+ model covers creates, edits, deletions, deletion/edit conflicts, automatic wakeup, verified transfers, and conflict materialization with safety and liveness properties. Files: tests/dropbox_fake.rs and formal/{SyncBehavior.tla,SyncBehavior.cfg,README.md}. Verify: targeted fake-Dropbox tests, full nightly gates, and exhaustive TLC pass. Depends: none. Ownership: these behavior tests and the new formal model only.
