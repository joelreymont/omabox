---
title: Release what the idle daemon does not need
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T11:36:07.733136+02:00"
---

Problem: the idle daemon holds 2.27 MB private: 1040 kB resident of a 1920 kB heap, 656 kB of library data, 480 kB of Habu's own mappings and 96 kB of stack. Part of the heap's resident share is freed memory at its top that glibc 2.43 on aarch64 returns only in 2 MiB steps, which malloc_trim cannot release (reported to libc-alpha on 2026-11-23). The user expects the daemon to use a megabyte or two. Acceptance: what the idle daemon does not need is released, measured on the live daemon. Depends: a glibc fix for the heap top. Claim: unassigned.
