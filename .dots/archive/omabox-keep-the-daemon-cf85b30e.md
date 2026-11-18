---
title: "Keep the daemon's memory at its idle floor"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T10:14:21.187927+02:00"
closed-at: "2026-11-18T11:02:57.158538+02:00"
---

Problem: src/dropbox.f:2813-2822 ARGUED hands each upload chunk to libcurl with CURL:BODY!, i.e. CURLOPT_COPYPOSTFIELDS, so an upload holds the chunk twice: Habu's buffer, plus libcurl's malloc copy of up to 32 MiB. Freeing that copy raises glibc's dynamic mmap threshold, and the heap then keeps what it frees. The live daemon reached 92 MB of private memory after a day of uploads. In the reproducer, one 30 MB upload leaves a 50 MB heap with 0.48 MB in use. Acceptance: after uploads, the daemon's private memory returns to its idle floor, and during an upload it peaks at most one chunk above that floor. Depends: the Habu commit that adds CURL:BORROW-BODY!. Claim: agent=worker workspace=.jj-ws.noindex/omabox-borrow.
