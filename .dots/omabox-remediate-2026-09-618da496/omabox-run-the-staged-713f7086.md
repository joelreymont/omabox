---
title: Run the staged daemon self-check without a retry
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T11:09:30.450605+02:00"
closed-at: "2026-11-15T11:16:58.978041+02:00"
---

Problem: src/install.rs validate_daemon_with retries ETXTBSY five times with 10 ms waits. Only the parallel test binary produces ETXTBSY there (a sibling test's fork holds the staged file's write descriptor until it execs); the installer CLI never forks while it holds one, so the retry is a test workaround in production code, and a slow fork still fails the test. Acceptance: no retry or wait in the self-check; tests run the staged daemon the way src/spawn.rs runs every stand-in script, so no test executes a file it wrote. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-run-the-staged-713f7086.
