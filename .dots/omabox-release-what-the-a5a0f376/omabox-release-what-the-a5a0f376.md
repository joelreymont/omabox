---
title: Release what the idle daemon does not need
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T11:36:07.733136+02:00"
---

Problem: after a pass the idle daemon still holds 8.6 MB anonymous: glibc main heap 3.1 MB, a 2 MB glibc thread arena with 1.4 MB touched beside three GLib threads (pool-spawner, gmain, gdbus), Habu's reservation 0.5 MB, libcrypto relro 0.5 MB, stacks. The user expects the daemon to use a megabyte or two. Plan: the keyring through secret-tool, the CA store from the certificate directory, a small journal page cache, then a live measurement; one child dot per fix. Acceptance: every idle anonymous mapping is attributed to its owner, and what the idle daemon does not need is released, measured on the live daemon. Depends: none. Claim: unassigned.
