---
title: Name the ported Dropbox tests after Rust
status: active
priority: 2
issue-type: task
created-at: "2026-11-16T04:23:12.565720+02:00"
---

Problem: twelve tests/dropbox_fake.rs tests are covered in src/replay-test.f (:2476, :4467, :9479) and src/dropbox-test.f (:82, :3313, :4865, :4907, :4999, :5113, :5180, :5220, :9569) only under Habu case names, so docs/habu-rewrite.md's 'ported under their names' is not met for them. Acceptance: each is a test under its Rust name asserting what Rust's asserts. Depends: none. Claim: agent=workers workspace=.jj-ws.noindex/omabox-names-*.
