---
title: Build Omabox on Habu master
status: active
priority: 2
issue-type: task
created-at: "2026-11-23T19:25:05.441333+02:00"
---

Problem: Omabox builds on Habu 6c0d2f62 (packaging/arch/PKGBUILD:13), 228 commits behind Habu master, which has since typed string literals as str, merged STRING into STR and added JSON values; the idle-pass design needs Habu's new inotify library, which lands on master. Acceptance: Omabox builds and every package's tests pass on the pinned Habu master commit that carries the inotify library, and PKGBUILD names it. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-repin.
