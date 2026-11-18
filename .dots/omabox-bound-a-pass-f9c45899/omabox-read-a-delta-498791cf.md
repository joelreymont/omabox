---
title: "Read a delta's directory casings by key"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T11:56:51.466448+02:00"
closed-at: "2026-11-18T14:31:28.986894+02:00"
close-reason: landed
---

Problem: src/reconcile.f:2000 APPLY-DELTA reads every remote directory (src/journal.f:1217 REMOTE-DIRECTORY-PATHS) and builds a casing for each (:1886 NORMALIZE-INVENTORY-CHANGES) on every pass, an empty delta included, so a pass's memory and time grow with the tree. Acceptance: a delta reads only the journal directories its changes' prefixes name; an empty delta reads none; the casing rules are unchanged. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-delta-casing
