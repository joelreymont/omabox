---
title: "Keep the kept spelling's baseline"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.604540+02:00"
closed-at: "2026-11-15T09:32:09.609036+02:00"
---

Problem: invalidate_case_collision_baselines deletes every baseline under the canonical path, including the kept spelling's, which later yields a spurious conflict; the rename can move the spelling the baseline names. Acceptance: only baselines of the renamed spelling or of spellings absent under the active root are deleted, in one transaction; the rename moves a spelling other than the baseline's; a later differing remote yields ReplaceLocal (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-keep-the-kept-ee1ccbba.
