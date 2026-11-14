---
title: Reuse a verified stage for the remote conflict copy
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.588012+02:00"
blocks:
  - omabox-survive-an-occupied-a75ddaaa
---

Problem: a download plan that ends as a conflict downloads the remote copy again although its verified stage holds those bytes. Acceptance: the verified stage is renamed (RENAME_NOREPLACE, same directory) to the remote copy name with its stage xattr cleared and mode 0400 before the conflict is finished, an occupied name still blocks only that path, and no payload is lost (tests). Depends: omabox-survive-an-occupied-a75ddaaa. Claim: unassigned.
