---
title: Prove failure isolation at the daemon level
status: open
priority: 1
issue-type: task
created-at: "2026-09-02T11:28:11.377939+02:00"
blocks:
  - omabox-isolate-per-path-3600f60c
  - omabox-record-readable-conflict-9224fe0a
  - omabox-make-dropbox-listing-96c0afc3
---

Problem: no test drives the whole daemon against the fake Dropbox for any failure class, and no crash test covers a remote effect that succeeded before its completion was recorded or a case-collision rename after baseline invalidation. Cross-filesystem promotion of a stage is tested only through a helper. Acceptance: tests run the daemon against the fake Dropbox for a socket, a symlink, a mode-000 file, a 409 download, a restricted folder, a revoked refresh token and a locked keyring, each asserting that unrelated paths still sync and the session does not exit except where designed. A revoked refresh token gives the exit that asks the user to act; a locked keyring is an environmental failure. Crash tests show that a remote create, then a crash, then replay completes by get_metadata, and that a baseline invalidation, then a crash before the rename, never plans a delete. A cross-filesystem test with the root on /home and staging under /dev/shm exercises the real promotion branches. Each test fails, or cannot be written, before its fix. Depends: omabox-isolate-per-path-3600f60c, omabox-record-readable-conflict-9224fe0a, omabox-make-dropbox-listing-96c0afc3. Claim: unassigned.
