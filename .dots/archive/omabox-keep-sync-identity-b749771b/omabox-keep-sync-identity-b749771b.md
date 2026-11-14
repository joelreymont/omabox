---
title: Keep sync identity stable across reboots
status: closed
priority: 1
issue-type: task
created-at: "2026-11-14T15:43:41.600184+02:00"
closed-at: "2026-11-14T17:07:43.570996+02:00"
---

Problem: src/journal.rs:246-279 binds the sync root as path, st_dev and st_ino, and src/journal.rs:157 keys each hash-cache fingerprint on st_dev. btrfs assigns each subvolume a new anonymous device number at every mount (0:44 at setup, 0:55 after the 2026-11-14 reboot, same inode 144667), so after a reboot activation returns Unavailable forever (src/journal.rs:2818, retried by src/daemon.rs:665) and every cached hash misses. Design: root identity is inode, birth time and subvolume ID read by statx; persisted state holds no device number; in-process device checks stay. Acceptance: both children land as one commit; installed on this machine, the daemon resumes generation 1 without re-selecting the folder and its first scan reuses the cached hashes. Depends: none. Claim: unassigned.
