---
title: Make idle passes cheap
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.375257+02:00"
blocks:
  - omabox-tighten-dropbox-client-2a6b649a
---

Problem: src/journal.rs:887-943 deletes and reinserts every local row under synchronous FULL on every pass; pending_plans (:1450-1474) is N+1 and called five times per pass; src/dropbox.rs:504 validates the account every pass; :549-556 builds a fresh agent per long poll; src/reconcile.rs:839, :872 verify the root per planned path; src/recovery.rs:598-652 creates every ancestor per file. Design: docs/remediation-2026-09.md section K. Acceptance: publish_local_scan writes only inserted, updated, or deleted rows (test: unchanged rescan performs zero row writes, asserted via sqlite3_total_changes or a data_version check); pending plans loaded once per pass and passed through; the scanner computes CanonicalPath once per entry and LocalObservationRecord carries it so local_map only sorts (no per-pass fold); validate_account once per session and after 401; long-poll agent reused; root verified once before planning and once before the completion batch; ensure_remote_parents only after a path/not_found rejection (fake test counts create_folder_v2 calls for a nested upload); all existing tests still pass. Files: src/journal.rs, src/reconcile.rs, src/recovery.rs, src/dropbox.rs, src/bin/omaboxd.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: schema, client. Ownership: per-pass cost. Claim: unassigned.
