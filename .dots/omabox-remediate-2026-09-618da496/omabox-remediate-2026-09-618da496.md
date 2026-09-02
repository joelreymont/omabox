---
title: Remediate 2026-09 deep review findings
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:13:29.160804+02:00"
---

Campaign: implement docs/remediation-2026-09.md (the frozen design for all 41 findings of the 2026-09-02 deep review: 3 critical, 14 major, 24 minor). Children are dispatched dependency-ordered in waves per the design's Dot graph section. Acceptance: every child dot landed with gates green (cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test, TLC for touched models) and the review's reproductions (merge order, overlapping downloads, symlink in root) pass as regression tests. Files: docs/remediation-2026-09.md. Verify: dot tree. Depends: none. Ownership: orchestrator. Claim: orchestrator.
