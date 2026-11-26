---
title: Make idle passes cheap
status: closed
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.375257+02:00"
closed-at: "2026-11-26T13:18:09.855486+02:00"
---

Problem: a pass checks the local root once per planned path, while prepare-time effects such as conflict copies open the sync root by path, so after a root swap mid-pass they can land in the new root. The unchanged-scan shortcut and byte-ordered scans have landed; one-join pending plans and a carried canonical path were dropped for lack of a measured need, and account validation stays per pass. Acceptance: every child closes; local effects of a pass never land in a replacement sync root (see omabox-keep-a-pass-9f9b0893). Depends: none. Claim: unassigned.
