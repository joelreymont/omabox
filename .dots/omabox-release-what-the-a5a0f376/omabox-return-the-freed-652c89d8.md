---
title: Return the freed heap before each wait
status: active
priority: 2
issue-type: task
created-at: "2026-11-19T19:22:10.166983+02:00"
---

Problem: the idle daemon's [heap] is 2240 kB, all of it dirty, while a sandboxed harness of its TLS sessions holds 80 to 170 kB in use and about 2 MB free that glibc keeps (dot b9187fe7's measurement). glibc returns freed pages only at the heap's top; malloc_trim(0) returns those under live blocks too (a probe: 1968 kB to 32 kB). Acceptance: the daemon calls malloc_trim(0) before each long poll and each sleep, and daemon-test passes. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-heap-trim.
