---
title: "Use Habu's STR-ALNUM? for copy identities"
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T11:07:55.632150+02:00"
---

Problem: src/reconcile.f's file-copy names (wuykskww) define a private ALNUM? because Habu's string.f had no ASCII letter-or-digit test; Habu is gaining STR-ALNUM? (workspace habu-alnum). Acceptance: ALNUM? is deleted and COPY-IDENTITY's helper calls STR-ALNUM?, on an omabox engine built from the Habu master that holds it; reconcile-test passes. Depends: STR-ALNUM? on Habu master. Claim: unassigned.
