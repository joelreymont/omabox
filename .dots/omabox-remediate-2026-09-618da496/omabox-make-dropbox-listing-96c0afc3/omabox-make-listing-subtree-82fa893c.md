---
title: Make listing subtree removal linear
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.606770+02:00"
closed-at: "2026-11-15T08:23:44.643241+02:00"
---

Problem: remove_subtree scans the whole map with retain for every file entry, and full listings normalize on every page, so a full listing costs quadratic time. Acceptance: subtree removal uses the canonical range, normalization runs once after the last page of full and delta listings, and a 20k-entry full listing test runs within a generous bound. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-make-listing-subtree-82fa893c.
