---
title: Keep syncing during transfers
status: closed
priority: 0
issue-type: task
created-at: "\"\\\"2026-08-24T23:42:04.711741+02:00\\\"\""
closed-at: "2026-08-25T11:41:56.926537+02:00"
close-reason: landed a833087e; 184 Rust tests, clippy/fmt, forbidden-pattern scan, Sol verification, and full TLC model check all clean
blocks:
  - omabox-resume-interrupted-exact-08dc4996
---

Measured problem: replay_pending joins every download, so one 31.9GB transfer freezes local scans, remote cursor refresh, installs, and journal progress for tens of minutes. Acceptance: add one daemon-owned fixed pool of at most four exact-download staging workers; the main thread remains the only journal writer and continues complete scans, remote refresh/long-poll, verified installs, and commits. Track only an in-memory in-flight path set; workers use the validated root fd, return typed results, and crashes reconstruct from pending plans/owned partials. Share one persistent content HTTP agent across workers so sequential requests reuse keep-alive and eight concurrent downloads use at most four connections. A gated long download must not prevent an unrelated local/remote change from being observed and scheduled within one 30s poll cycle; root swaps stay bound to the old fd. No Tokio, generic scheduler, daemon IPC, second DB connection/writer, or persistent queue.
