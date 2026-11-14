---
title: Bind the sync root by inode, birth time and subvolume
status: closed
priority: 1
issue-type: task
created-at: "2026-11-14T15:43:41.607728+02:00"
closed-at: "2026-11-14T17:07:43.559728+02:00"
---

Problem: src/journal.rs:246-279 and src/local.rs:1135-1141 build the root binding from st_dev, which btrfs reassigns at every mount. Acceptance: the binding is canonical path, inode, birth time and subvolume ID from statx; schema 7 drops the device column; a schema-6 binding is upgraded in place, keeping its generation, when path and inode match; a root whose filesystem records no birth time is refused; docs/remediation-2026-09.md:268 states the new identity. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-keep-sync-identity-b749771b
