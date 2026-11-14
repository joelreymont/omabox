---
title: Make idle passes cheap
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T11:28:11.375257+02:00"
blocks:
  - omabox-journal-schema-ver-487764f0
  - omabox-move-the-dropbox-cb30bc34
---

Problem: a pass checks the local root once per planned path, while prepare-time effects such as conflict copies open the sync root by path, so after a root swap mid-pass they can land in the new root. The unchanged-scan shortcut and byte-ordered scans have landed; one-join pending plans and a carried CanonicalPath were dropped for lack of a measured need, and account validation stays per pass. Design: docs/remediation-2026-09.md section K. Acceptance: every child closes. Depends: none. Claim: unassigned.
