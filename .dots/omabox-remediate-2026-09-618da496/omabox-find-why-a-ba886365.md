---
title: Find why a resumed download test fails under load
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T10:18:24.720175+02:00"
---

Problem: tests/dropbox_fake.rs:8418 unsatisfiable_resume_restarts_only_the_owned_partial failed once in a full cargo test --test dropbox_fake run (lane 2db1e172 at a8abe243, while other cargo builds and test runs loaded the machine) and passed 5 of 5 alone; the failing assertion was not captured. Acceptance: a reproducer that shows the failure rate, and a cause proven by evidence, not inferred. Depends: none. Claim: unassigned.
