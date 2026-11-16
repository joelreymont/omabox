---
title: "Test the self-check write and STALE's directory sweep"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.212886+02:00"
closed-at: "2026-11-17T00:06:29.326534+02:00"
---

Problem: no test shows omaboxd --self-check failing on a lost write (src/omaboxd.f SELF-CHECK), and STALE's directory branch (src/stale.f) is untested. Acceptance: omaboxd-test runs the self-check with stdout on /dev/full and sees a nonzero exit; stale-test sweeps a dead process's directory. Depends: none. Claim: agent=f-tests workspace=.jj-ws.noindex/omabox-f-tests.
