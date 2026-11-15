---
title: Reuse a verified stage for the remote conflict copy
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.588012+02:00"
---

Problem: a download plan that ends as a conflict downloads the remote copy again although its verified stage holds those bytes. Acceptance: before the conflict is finished, the verified stage is installed as the remote conflict copy by a no-replace rename within the same directory, with its stage marker cleared and mode 0400; an occupied name still blocks only that path, and no payload is lost (tests). Depends: none. Claim: unassigned.
