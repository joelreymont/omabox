---
title: Protect in-flight download slots during leasing
status: active
priority: 1
issue-type: task
created-at: "\"2026-09-02T11:28:11.358335+02:00\""
blocks:
  - omabox-order-canonical-paths-6ffaf324
---

Problem: src/local.rs:1266-1362 protects only the identities being leased and truncates every other owned slot; src/reconcile.rs:535-580 passes only missing downloads, so planning a second download while one is in flight truncates the in-flight slot and schedule (:296-304) fails with 'resumable download slot was assigned twice' (reproduced). Verified stages are orphaned when a plan is superseded or finishes as a conflict (only install_download_at removes a stage, src/local.rs:3660-3676). Design: docs/remediation-2026-09.md section G. Acceptance: lease_download_slots takes a protected binding set and never resets a protected slot; ExactDownloadPool::schedule_downloads leases under the slot mutex with protected = in-flight bindings (tracked as bindings in DownloadSlots) union all pending download plan bindings; duplicate-slot check becomes a debug assertion; a slot is reset only when its binding belongs to no pending plan; supersede_pending_plan removes the verified stage for the superseded target/content; finish_pending_conflict renames the verified stage to the recorded remote conflict copy when present (until the conflict-lifecycle dot lands, use the current hash-named copy name); fake-Dropbox test gates one download and plans a second in the next pass, asserting both install and no error; unit test that a protected slot keeps its bytes and binding; formal/DownloadLifecycle.tla DiscardStaleSlot guard documented as the protected set and TLC re-run. Files: src/local.rs, src/reconcile.rs, tests/dropbox_fake.rs, formal/DownloadLifecycle.tla, formal/README.md. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test; java -jar ~/.local/share/tla/tla2tools.jar -config DownloadLifecycle.cfg DownloadLifecycle.tla in formal/. Depends: canonical. Ownership: download slot ownership. Claim: agent=worker-slots workspace=.jj-ws/omabox-protect-in-flight-34128729
