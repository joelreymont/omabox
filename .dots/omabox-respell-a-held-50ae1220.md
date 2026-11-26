---
title: Respell a held record when its folder goes
status: open
priority: 2
issue-type: task
created-at: "2026-11-26T15:26:38.244488+02:00"
---

Problem: src/reconcile.f HOLD+ spells a hold's record with the casing its folders had when it was written. When the own-fold folder (/ꭰDir) is deleted while /Ꭰdir stays held, SETTLE keeps showing the held record spelled ꭰDir until /Ꭰdir is listed again (traced by the shared-fold re-review, not run). Acceptance: a test that lists /ꭰDir and /Ꭰdir, then deletes /ꭰDir by delta, shows the held record spelled as the folders that remain (or the key's bytes); it fails before the fix. Depends: none. Claim: unassigned.
