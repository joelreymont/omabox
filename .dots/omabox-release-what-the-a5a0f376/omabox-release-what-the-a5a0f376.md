---
title: Release what the idle daemon does not need
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T11:36:07.733136+02:00"
---

Problem: the idle daemon holds 5.2 MB anonymous: relocated pages of the ~33 libraries libcurl loads 1.8 MB (libcrypto 0.5 MB), glibc's main heap 1.2 MB (OpenSSL's setup 0.4 MB, SQLite 0.2 MB), the CURL loop task's malloc arena 0.7 MB (cached TLS connections 0.24 MB), Habu's image data 0.5 MB, task and guarded stacks 0.6 MB, Habu's small blocks 0.24 MB (0.2 MB of it page padding), resolver threads' arenas and cached stacks 0.15 MB. The user expects the daemon to use a megabyte or two. Plan: one child dot per fix, then a live measurement. Acceptance: what the idle daemon does not need is released, measured on the live daemon. Depends: none. Claim: unassigned.
