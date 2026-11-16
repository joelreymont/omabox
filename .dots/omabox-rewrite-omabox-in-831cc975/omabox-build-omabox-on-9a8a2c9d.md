---
title: Build Omabox on Habu master c643bda0
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T18:29:07.830980+02:00"
closed-at: "2026-11-16T19:18:22.705650+02:00"
---

Problem: Omabox's tests ran on a bin/hb built before its own Habu tree (engine-provided libraries win over the source), and Habu master has moved 115 commits since; on an engine built from master c643bda0, daemon-test stops at src/replay.f:2235, where create is now a reserved name. Acceptance: every src/*-test.f passes on an hb built from Habu master c643bda0, with no workaround of a Habu defect. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-habu-c643.
