---
title: Attribute the bytes the first remote pass leaves
status: open
priority: 2
issue-type: task
created-at: "2026-11-26T10:43:29.025874+02:00"
---

Problem: the first remote pass after startup leaves 41,440 heap bytes allocated that no one has attributed (sandboxed run of 264 remote passes, 2026-11-26, tcache off: in-use bytes stayed flat at 425,232 after that pass). Acceptance: the 41,440 bytes are attributed to their owner (file:line) and given back unless the idle daemon needs them. Depends: none. Claim: unassigned.
