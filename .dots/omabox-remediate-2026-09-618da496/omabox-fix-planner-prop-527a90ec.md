---
title: Fix planner property strategies, fixtures, and models
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.367544+02:00"
blocks:
  - omabox-order-canonical-paths-6ffaf324
---

Problem: tests/planner_properties.rs:8-10 draws content independently from [a-z]{1,8}, so ReplaceRemote and DeleteLocal are never generated (0 of 20 runs); subprocess fixtures written then exec'd (src/auth.rs:834-843, src/install.rs:862-867, src/service.rs:252-273, src/bin/omabox.rs:638-652) race with ETXTBSY under parallel tests (3 of 10 runs); formal/DownloadExecutor.tla models every failure as transient; the QML tests under packaging/omarchy/plugins/local.omabox/tests never run. Design: docs/remediation-2026-09.md section N (planner strategies, fixtures, models, QML runner). Acceptance: strategies draw the baseline first and derive local and remote from prop_oneof![Just(baseline), fresh] over a two-letter alphabet with a coverage assertion that every Operation variant and NoOp reason appears at least once per run; fixtures spawn via /bin/sh <path>; DownloadExecutor.tla gains a permanent per-job failure state that never cancels siblings and its cfg checks it (TLC passes); an #[ignore]d integration test runs qmltestrunner against tests/mocks, documented in README under Develop. Files: tests/planner_properties.rs, src/auth.rs, src/install.rs, src/service.rs, src/bin/omabox.rs, formal/DownloadExecutor.tla, formal/DownloadExecutor.cfg, formal/README.md, tests/qml_widget.rs, README.md. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test; TLC on DownloadExecutor. Depends: canonical. Ownership: test strategies and fixtures. Claim: unassigned.
