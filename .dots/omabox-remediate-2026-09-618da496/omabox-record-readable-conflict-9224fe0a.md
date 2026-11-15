---
title: Record readable conflict copies and surface them
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.372056+02:00"
blocks:
  - omabox-protect-in-flight-34128729
---

Problem: conflict copies are hidden files named by side and content digest that status never lists and the runtime snapshot cannot show. Acceptance: a conflict copy has the visible deterministic name '<stem> (conflicted copy, <side>, <hash8>)<ext>', where side is local or Dropbox and hash8 is the first eight hex digits of the content digest; replay after a crash yields exactly one copy per side (test); status lists conflicts with their copy names; the runtime snapshot carries a conflict count and up to 20 conflict paths; the panel and status views show the count and paths, with the QML mocks updated. Depends: omabox-protect-in-flight-34128729. Claim: unassigned.
