---
title: Find what slows the upload session tests
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T13:16:00.420100+02:00"
closed-at: "2026-11-16T14:36:12.148136+02:00"
---

Problem: dropbox-test takes 27 s at master 1efa0087 and 28 s at the RECONCILE line's tip, against 1-4 s for every other suite. Its log's timestamps put about 17 s in the upload-session cases around append_v2's incorrect_offset and closed refusals (src/dropbox-test.f). Rust's fake sends the same 32 MiB chunks, and SHA256-FEED is the engine's, so the cost is elsewhere and unmeasured. Acceptance: the cause measured and fixed at its root, and dropbox-test's time before and after. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-slow-session.
