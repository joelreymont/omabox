---
title: "Test setup's exchange, link and bind"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.208373+02:00"
closed-at: "2026-11-17T00:06:29.352976+02:00"
---

Problem: src/omabox.f EXCHANGED, LINKED and BIND are reached by no test, so a regression in the reply-to-failure mapping or in refusing a journal bound to another account passes the suite. Acceptance: omabox-test covers BIND's three arms and EXCHANGED's and LINKED's failures against the fake Dropbox. Depends: none. Claim: agent=f-tests-setup workspace=.jj-ws.noindex/omabox-f-tests-setup.
