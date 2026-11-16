---
title: "Port RECONCILE's case-collision rename"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T04:23:12.561395+02:00"
closed-at: "2026-11-16T14:36:11.969582+02:00"
---

Problem: RECONCILE needs reconcile.rs's case-collision rename (resolve_case_collision :987-1030, case_variant_* :1946-2060, supersede_pending_plan :1609). Acceptance: those words in src/reconcile.f; reconcile.rs's case-variant unit tests pass under their names; dot omabox-journal-hygiene-case-8cc63437 closes with it. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-reconcile-case.
