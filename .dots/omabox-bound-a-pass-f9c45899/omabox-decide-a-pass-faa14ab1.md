---
title: Decide a pass one known path at a time
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.056161+02:00"
closed-at: "2026-11-19T17:25:14.540070+02:00"
---

Problem: deciding (src/reconcile.f LOCAL-MAP, REMOTE-MAP, the sides and their merge) copies the baselines and both inventories into the pass's arena. Acceptance: deciding visits the journal's known paths in canonical order, one row in a scratch arena, keeping only paths that are not no-ops; the decisions are unchanged; the pass keeps no local record list (pass.records, LOCAL:SCAN-OBSERVATIONS). Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-decide.
