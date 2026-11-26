---
title: Retire verified stages when download plans end
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.585840+02:00"
closed-at: "2026-11-26T13:55:37.262386+02:00"
---

Problem: superseding or ending a download plan leaves its verified download stage in the staging directory forever. Acceptance: after a plan's reconciliation is recorded, the verified stages of ended or superseded download plans are removed with a sync of the parent directory, unless a live pending or blocked plan for the same path and content, or an in-flight job, still holds them; startup pruning keeps stages of download plans until then; the download lifecycle model in formal/ covers the retirement and TLC runs it clean (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-stage-retire.
