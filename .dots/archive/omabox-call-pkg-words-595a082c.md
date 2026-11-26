---
title: Call package words by prefix only
status: closed
priority: 2
issue-type: task
created-at: "2026-11-26T10:36:36.917635+02:00"
closed-at: "2026-11-26T10:47:51.888572+02:00"
---

Problem: six Omabox files import a package with using (src/dropbox-test.f:245, src/daemon-test.f:815, src/reconcile-test.f:256 and src/replay-test.f:197 TEST-CLIENT; src/planner.f:17 and src/planner-test.f:18 MODEL), though the user chose always prefix (2026-11-25) and Habu is removing using (Habu dot habu-remove-using-529a28aa). Acceptance: no using in Omabox; each word those imports resolved is called as NAME:WORD; the tests of the packages touched pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-prefix.
