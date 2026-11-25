---
title: Store the hash cache in typed columns
status: closed
priority: 2
issue-type: task
created-at: "2026-11-24T20:45:49.806541+02:00"
closed-at: "2026-11-25T13:15:22.173156+02:00"
---

Problem: a scanning pass decodes a hash cache row's JSON per file (src/journal.f CACHED-HASH, HASH-OF; MODEL:JSON>HASH-VALUE), about 166 of the 629 ms idle pass with the lookup. Acceptance: schema 10 holds local_hash_cache in typed columns with no JSON, read and written by SQL, an unconvertible stored row dropped, MODEL's hash value codec gone, every package's tests passing. Depends: omabox-store-local-observations-095aa078. Claim: agent=worker workspace=.jj-ws.noindex/omabox-scan-2a.
