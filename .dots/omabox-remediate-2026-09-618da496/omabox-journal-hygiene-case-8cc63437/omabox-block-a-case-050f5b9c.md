---
title: Block a case collision no spelling can rename
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:05:10.140685+02:00"
blocks:
  - omabox-keep-the-kept-ee1ccbba
---

Problem: when no observed spelling of a local case collision is a file or directory (two symlinks, a symlink and a FIFO), rename_case_variant_with (src/local.rs:1090-1094) refuses each one, resolve_case_collision reports Changed and the daemon rescans every second forever while superseding the path's plans. Acceptance: such a collision blocks only its canonical path, the pass continues and plans other paths, and nothing is renamed or deleted (test). Depends: omabox-keep-the-kept-ee1ccbba. Claim: unassigned.
