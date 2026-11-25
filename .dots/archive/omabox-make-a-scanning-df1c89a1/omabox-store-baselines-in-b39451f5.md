---
title: Store baselines in typed columns
status: closed
priority: 2
issue-type: task
created-at: "2026-11-24T17:33:35.601747+02:00"
closed-at: "2026-11-25T13:15:22.157245+02:00"
---

Problem: every baseline read decodes JSON (src/journal.f DECODE-BASELINE :2279, KNOWN-BASELINE :2565) at Habu's 35x cost per record; the scan design (dot df1c89a1, approach A) moves the four tree-sized tables to typed columns in schema 10. Acceptance: schema 10 stores a baseline as kind, content and revision with CHECK constraints; 9 and 8 migrate to it in one transaction; an unconvertible row is refused at open with its path; no baseline read or write touches JSON. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-scan-1a.
