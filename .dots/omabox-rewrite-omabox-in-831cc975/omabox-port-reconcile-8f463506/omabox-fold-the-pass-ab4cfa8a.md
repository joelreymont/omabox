---
title: "Fold the pass tests' duplicate helpers"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T12:46:37.199567+02:00"
closed-at: "2026-11-16T14:36:12.050565+02:00"
---

Problem: ten pass-test lanes wrote src/reconcile-test.f and src/test-dropbox.f in parallel. The fake gained overlapping request recorders (ARGS-SENT$, BODY-SENT$, DELETE-SENT$, DELETES$, UPLOAD-BODIES$, METADATA-BODIES$, UPLOAD-PATHS$), each a buffer with its own RESET line, and the test file holds helpers that do one thing under several names (PLANNED-OPERATION beside PLANNED-OPERATIONS, SEEDED-NOOP beside SEED-BASELINE, several request-list and request-count words). Acceptance: the fake records each request's route, Dropbox-API-Arg and body once, read through one set of words; each Rust helper has one port in src/reconcile-test.f; reconcile-test and every suite that loads test-dropbox.f pass. Depends: the RECONCILE pass-test lanes merged. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fold-recorders and .jj-ws.noindex/omabox-fold-helpers.
