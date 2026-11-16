---
title: Name the ported Dropbox tests after Rust
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T04:23:12.565720+02:00"
closed-at: "2026-11-16T11:21:23.048060+02:00"
---

Problem: nine tests/dropbox_fake.rs tests are covered in src/replay-test.f (:2476, :4467, :9479) and src/dropbox-test.f (:82, :4865, :4907, :4999, :5180, :9569) only under Habu case names (:3313, :5113 and :5220 assert what docs/habu-dropbox.md changes on purpose, as docs/habu-rewrite.md, Tests, records), so docs/habu-rewrite.md's 'ported under their names' is not met for them. Acceptance: each is a test under its Rust name asserting what Rust's asserts. Depends: omabox-check-a-download-a794b434, for :4467. Claim: lead workspace=.jj-ws.noindex/omabox-bad-resumes.
