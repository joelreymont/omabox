---
title: Walk the scan with one stat per name
status: active
priority: 2
issue-type: task
created-at: "2026-11-24T20:45:49.832801+02:00"
---

Problem: the scan's walk opens every entry (O_PATH probe, fstat) and every regular file again (open, fstat, close), about six syscalls per file (src/local.f SCAN-ENTRY, FILE-PRINT). Acceptance: the walk takes one fstatat (no symlink followed) per name and opens no regular file; directories are opened and compared as before; every package's tests passing. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-scan-2d.
