---
title: Drop the device from hash-cache fingerprints
status: closed
priority: 1
issue-type: task
created-at: "2026-11-14T15:43:41.610566+02:00"
closed-at: "2026-11-14T17:07:43.562533+02:00"
---

Problem: src/journal.rs:157 and src/local.rs:3228 store st_dev in each fingerprint, so a reboot invalidates every cached hash (14,761 here) and the next scan re-hashes the whole root. Acceptance: fingerprints hold inode, size, mtime and ctime only; a cached row written with a device field decodes and is reused. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-keep-sync-identity-b749771b
