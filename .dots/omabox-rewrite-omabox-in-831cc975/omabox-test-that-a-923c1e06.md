---
title: "Test that a download's 400 passes up unconverted"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T03:03:36.607357+02:00"
closed-at: "2026-11-16T03:06:11.269867+02:00"
---

Problem: no download case sends a non-parse code through VERIFIED (src/dropbox.f:1217), so converting every code would pass every test. Acceptance: a download answered 400 throws E-BAD-REQUEST and leaves the client usable, in src/dropbox-test.f. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-dropbox-400
