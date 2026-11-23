---
title: "Skip a pass's scan, listing and decisions while unchanged"
status: open
priority: 2
issue-type: task
created-at: "2026-11-23T19:25:05.456971+02:00"
---

Problem: a pass rescans, relists and redecides 16,220 entries every 44 s with nothing changed. Design: each of the three stands on a fact for the session: an inotify watch on every listed directory that has reported nothing (rescanned at least hourly), Dropbox's long poll answering changes false for the journal's cursor, and a last pass that decided only no-ops. Acceptance: a live pass with nothing changed costs less CPU than the Rust daemon's 0.31 s and idle private memory stays within 2.27 MB; a change on either side is synced as today. Depends: none. Claim: unassigned.
