---
title: "Report glibc's 2 MiB heap top upstream"
status: open
priority: 2
issue-type: task
created-at: "2026-11-23T11:15:08.802807+02:00"
---

Problem: since glibc 2.43 (321e1fc73f53, 1c588a2187a4) aarch64 sets a 2 MiB thp_pagesize even without kernel THP, so systrim returns the heap top only in 2 MiB units and malloc_trim(0) leaves a freed top under 2 MiB resident (probe: 784 of 784 kB, 1456 of 1456 kB). Acceptance: the report reaches glibc's maintainers with its reproducer. Depends: the user's approval of the message. Claim: unassigned.
