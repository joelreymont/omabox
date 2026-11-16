---
title: Read a captured log whole
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T10:57:43.476490+02:00"
closed-at: "2026-11-16T11:47:12.108567+02:00"
---

Problem: the test files capture stderr into fixed buffers: dropbox-test.f LOGGED (512 bytes), auth-test.f:140-142, config-test.f:172-174, status-test.f:207-211 and :344-348, journal-test.f:96-98 and :109-111, local-test.f:449-451, :1552-1555 and :1748, and replay-test.f's STDERR-OF. A capture longer than its buffer throws E-FS-CAPACITY out of the test, so a regression that logs twice crashes the suite and leaves stderr.txt in TMPDIR instead of failing one test. Acceptance: one shared word reads a capture whole; every test file uses it; a doubled log line fails as one TFAIL. Depends: the REPLAY stack lands (replay-test.f). Claim: unassigned.
