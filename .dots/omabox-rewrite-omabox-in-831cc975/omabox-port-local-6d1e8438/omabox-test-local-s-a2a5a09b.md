---
title: "Test LOCAL's untested failures"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T02:32:58.654209+02:00"
closed-at: "2026-11-16T02:49:34.179947+02:00"
---

Problem: src/local-test.f has no test of RESTART-PARTIAL, VERIFY-PRIVATE-COPY or RECOVERY-FILE-NAME, never asserts E-CORRUPT, E-CONTENT-HASH or E-HASH-READ, never runs RESTORE-OR-PRESERVE-CHANGED-GUARD's preserve arm (the one place a raced-in local payload is kept), and never checks that a scan's converted entry failure logs nothing and a rethrown one logs one line; AGENTS.md asks that every filesystem failure be tested. Acceptance: a test of each, failing without the behaviour it checks. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-local-tests.
