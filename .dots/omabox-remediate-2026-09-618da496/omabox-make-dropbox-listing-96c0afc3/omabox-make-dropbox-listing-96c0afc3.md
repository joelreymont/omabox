---
title: "Make Dropbox listing robust and linear"
status: open
priority: 1
issue-type: task
created-at: "\"2026-09-02T11:28:11.359987+02:00\""
---

Problem: one restricted folder, one file without a content hash or revision, one entry whose display path does not lowercase to its lowercase path, or the remote root's own entry aborts the whole Dropbox listing, and building a large listing takes quadratic time. Acceptance: every child closes; one bad listing entry never aborts the listing, the rest of the inventory publishes, and building a listing takes time linear in the number of entries. Depends: none. Claim: unassigned.
