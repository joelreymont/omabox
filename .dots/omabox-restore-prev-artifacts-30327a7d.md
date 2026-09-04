---
title: Restore previous artifacts when upgrade restart fails
status: active
priority: 2
issue-type: task
created-at: "\"2026-09-04T21:20:29.463972+02:00\""
---

Problem: a failed upgrade restart calls finish and deletes the saved old installation. Acceptance: restart failure rolls back artifacts, reloads the unit, and restores prior service state; rollback failures preserve recoverable backups and both errors; live plugin is never changed while shell reports locked. Files: src/install.rs. Verify: mocked restart failure with old artifacts and service restoration, rollback failure and lock transition tests, Rust gates. Depends: none. Ownership: Sol upgrade agent in isolated review-upgrade workspace. Scope excludes the broader open install-hardening dot and daemon readiness redesign.
