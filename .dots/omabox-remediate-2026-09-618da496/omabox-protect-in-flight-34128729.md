---
title: "Retire verified stages when download plans end"
status: open
priority: 1
issue-type: task
created-at: "\"2026-09-02T11:28:11.358335+02:00\""
---

Problem: supersede_pending_plan and finish_pending_conflict retire journal work without collecting or reusing its verified download stage. Protected leasing and in-flight slot ownership already landed in 120cdf7 and the focused slot fix; they are no longer work for this dot.

Design: docs/remediation-2026-09.md section G, remaining stage lifecycle items. Acceptance: superseding a download plan removes only its verified owned stage when no live plan retains it; finishing a conflict reuses the verified stage for the recorded remote conflict copy when present, preserving every conflict payload and unrelated occupant. Tests cover superseded-stage retirement, conflict-stage reuse, and preservation of stages still retained by live work. Do not reintroduce the superseded duplicate-slot debug-assertion requirement.

Files: src/local.rs, src/reconcile.rs, tests/dropbox_fake.rs, formal/DownloadLifecycle.tla, formal/README.md. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test; TLC DownloadLifecycle. Depends: none; canonical paths and protected leasing are landed. Ownership: verified download-stage retirement and conflict reuse. Claim: unassigned. The old workspace is retained as historical work only.
