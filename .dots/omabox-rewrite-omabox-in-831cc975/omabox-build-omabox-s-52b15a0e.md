---
title: "Build omabox's path texts without a cap"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:20:55.847829+02:00"
closed-at: "2026-11-17T00:06:29.278273+02:00"
---

Problem: src/omabox.f SETTINGS-LINES, DONE-OUT, DROPBOX-IN, ROOT-DONE and PROMPT build text holding a path, the app key or the login URL in string.f's builder, which holds 1024 bytes and throws E-STR-CAPACITY beyond, so a long sync root or HOME fails settings, set-root and setup where Rust's String has no cap. Acceptance: those texts are built in the run's arena at any length, and a test with a root longer than 1024 bytes passes. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-text
