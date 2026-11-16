---
title: Keep a wait Dropbox asks of a mutation
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T14:15:39.983566+02:00"
closed-at: "2026-11-16T14:36:12.111313+02:00"
---

Problem: src/dropbox.f answers a mutation's 408 or 5xx refused unverified even when its Retry-After asks a wait, so REPLAY reads back and the pass sends more mutations while Dropbox asked to back off; and a delete or create-folder 2xx that does not parse throws E-ANSWER and ends the pass, where Rust verifies it (SdkError::Json). Acceptance: a mutation answered with a wait answers retry with that wait; one with no wait, lost, or with an unparseable 2xx answers refused unverified. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-keep-asked-wait
