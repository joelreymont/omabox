---
title: Hand an incomplete Dropbox file to the caller
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T03:03:36.604666+02:00"
closed-at: "2026-11-16T03:09:19.846675+02:00"
---

Problem: src/dropbox.f LISTED and ENTRY-READ throw E-ANSWER (WHOLE?, :1062) for a downloadable file without a rev or content hash, so one such file in a listing ends every pass; Rust records it as Unknown(Incomplete) (master-dropbox.rs:1763-1776, :1868-1874). Acceptance: LIST and METADATA hand such a file; a public COMPLETE? tells a whole file; tests show each. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-dropbox-incomplete
