---
title: "Make Dropbox listing robust and linear"
status: open
priority: 1
issue-type: task
created-at: "\"2026-09-02T11:28:11.359987+02:00\""
---

Problem: one restricted folder, one file without a content hash or revision, one entry whose display path does not casefold to its path_lower, or the remote root's own entry aborts the whole Dropbox listing, and building a large listing is quadratic. Design: docs/remediation-2026-09.md section I. Acceptance: every child closes. Depends: none. Claim: unassigned.
