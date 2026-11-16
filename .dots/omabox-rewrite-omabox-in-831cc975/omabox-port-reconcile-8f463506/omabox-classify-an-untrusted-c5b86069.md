---
title: Classify an untrusted mutation per path
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T13:33:26.794399+02:00"
closed-at: "2026-11-16T14:36:12.091691+02:00"
---

Problem: src/dropbox.f answers a lost or untrusted mutation whose get_metadata confirmation does not show the intended result as retry (UNCONFIRMED :2159, SESSION's confirming :2902), so REPLAY stops the pass (STOP-PASS) and a repeated bad answer for one path stops every pass. Rust verifies once and classifies that path Pending, Applied or PreconditionChanged (dropbox.rs resolve_ambiguous, classify). Acceptance: the mutation answers refused unverified with no get_metadata and REPLAY reads the path back once, as it does for a conflict; the pass goes on. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-unverified
