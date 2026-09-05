---
title: Preserve sync history across root identity drift
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T10:30:06.132487+03:00\\\"\""
closed-at: "2026-09-05T10:47:55.979956+03:00"
close-reason: "landed and verified: Astra reviewed root identity guard and CLI config-before-adoption ordering; same-path total_changes=0 and full journal preservation, pending/blocked/recovery retirement with payload preservation, unavailable-root selection, explicit adoption and failed config write regressions pass. Combined root+slot fmt, clippy all targets -D warnings and full cargo test pass; MutationLifecycle TLC 48 distinct states passes."
---

Problem: the same configured path with a changed device/inode can clear history or produce an unrecoverable Busy state. Acceptance: same-path identity drift returns Unavailable without any journal writes; intentional different-path changes and explicit same-path adoption transactionally retire stale intent and start a fresh generation; CLI root selection works when the prior root is unavailable and explicitly adopts the selected root under the daemon lock; payloads are preserved. Files: src/journal.rs root lifecycle, src/config.rs loading only as necessary, src/bin/omabox.rs root selection and focused tests. Verify: rename-and-replace root preserves baselines/plans; changed root retires pending/blocked intents without deleting files; same-path CLI re-adoption; Rust gates and MutationLifecycle TLC. Depends: daemon integration must handle Unavailable before landing combined tree. Ownership: Sol root lane in fix-root workspace; daemon wiring belongs to daemon lane. Excludes unrelated old journal-hygiene and CLI backlog.
