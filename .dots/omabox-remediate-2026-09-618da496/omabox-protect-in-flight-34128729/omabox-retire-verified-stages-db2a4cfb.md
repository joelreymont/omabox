---
title: Retire verified stages when download plans end
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.585840+02:00"
blocks:
  - omabox-survive-an-occupied-a75ddaaa
---

Problem: superseding or ending a download plan leaves its verified download stage in the staging directory forever. Acceptance: after record_reconciliation, verified stages of ended download plans are removed with a parent fsync unless a live pending or blocked plan for the same path and content or an in-flight job holds them, startup pruning keeps download plans until then, DownloadLifecycle.tla models the retirement and passes TLC, and doc G names what landed (tests). Depends: omabox-survive-an-occupied-a75ddaaa. Claim: unassigned.
