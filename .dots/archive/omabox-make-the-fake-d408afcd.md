---
title: Make the fake Dropbox refuse an unescaped tilde in a form
status: closed
priority: 2
issue-type: task
created-at: "2026-11-26T10:52:58.438879+02:00"
closed-at: "2026-11-26T10:52:58.442467+02:00"
---

Problem: src/test-dropbox.f PLAIN? accepted a raw ~, against its comment and against Habu's FORM-KEPT?, so a client that stopped escaping ~ would pass. Acceptance: PLAIN? accepts only letters, digits and *-._; dropbox-test and auth-test pass. Depends: none. Claim: unassigned.
