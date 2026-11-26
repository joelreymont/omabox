---
title: "Skip a pass's scan, listing and decisions while unchanged"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-23T19:25:05.456971+02:00"
closed-at: "2026-11-26T10:11:24.001613+02:00"
---

Problem: a pass rescans, relists and redecides 16,220 entries every 44 s with nothing changed, and a local edit waits for the long poll to return before it is noticed. Approach (the user, 2026-11-25, "do it"): "Rescan only the folders the events name, a few microseconds each. Wake the daemon as soon as a local change happens. Do a full scan only at startup, after a queue overflow, and as an hourly backstop." Acceptance: a live pass with nothing changed costs less CPU than the Rust daemon's 0.31 s and idle private memory stays within 2.27 MB; a local change starts a pass without waiting for the long poll; a change on either side is synced as today. Depends: none. Claim: agent=bob design=Plan.
