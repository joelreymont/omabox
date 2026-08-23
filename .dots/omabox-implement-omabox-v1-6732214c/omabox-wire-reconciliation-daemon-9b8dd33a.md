---
title: Wire reconciliation, daemon, and CLI
status: active
priority: 2
issue-type: task
created-at: "\"2026-08-23T20:47:57.911113+02:00\""
blocks:
  - omabox-implement-conditional-dropbox-cbf984cd
---

Problem: implemented primitives are not yet an unattended service or usable setup/status flow. Acceptance: one sequential reconcile loop handles startup recovery and wakeups; omaboxd shuts down in a replayable state; omabox setup and status use durable state without a daemon socket and redact secrets; the user unit invokes the daemon correctly. Files: src/reconcile.rs, src/status.rs, src/bin/omabox.rs, src/bin/omaboxd.rs, packaging/systemd/omabox.service. Verify: cargo test reconcile status; cargo check --all-targets. Depends: conditional writes dot. Ownership: orchestration and user-facing service surfaces.
