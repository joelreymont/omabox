---
title: "Account for the idle daemon's heap"
status: active
priority: 2
issue-type: task
created-at: "2026-11-19T19:05:51.133537+02:00"
---

Problem: the live daemon at master 63b1eb20, idle after one pass, holds 3488 kB anonymous, 2240 kB of it in glibc's main heap; the user expects a megabyte or two. Parsing the system CA bundle costs 352 kB per TLS session, and a pass opens three. Acceptance: a report of the idle heap's bytes still in use by owner (each TLS session's trust chain and buffers, and the rest) and the free bytes glibc keeps, from a sandboxed harness that repeats the daemon's TLS sessions, set against the live [heap]. Depends: none. Claim: agent=bob scratch=/tmp/claude-1000/heap-rca.
