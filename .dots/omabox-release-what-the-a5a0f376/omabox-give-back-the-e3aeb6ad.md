---
title: Give back the heap bytes the idle daemon keeps
status: open
priority: 2
issue-type: task
created-at: "2026-11-26T10:43:29.025874+02:00"
---

Problem: the idle daemon's heap holds bytes it does not need. glibc 2.43's per-thread cache (tcache) keeps chunks the daemon freed, and malloc_trim does not return them: in a sandboxed run of 264 remote passes (2026-11-26), in-use bytes stayed at 425,232 with tcache off but rose to 537,824 with it, so about 110 kB more stays resident. The first remote pass after startup also leaves 41,440 bytes allocated that no one has attributed. Acceptance: the 41,440 bytes are attributed to their owner (file:line) and given back unless the idle daemon needs them; after 200 passes the daemon's in-use bytes at rest are the tcache-off figure within one page, by the mechanism the user chooses. Depends: the user's choice of mechanism. Claim: unassigned.
