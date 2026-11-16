---
title: Release the service around a change
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T22:47:58.744667+02:00"
closed-at: "2026-11-17T00:06:29.238093+02:00"
---

Problem: omabox set-root and setup must stop the service, change, then restore it (rust src/bin/omabox.rs:531-597). Acceptance: RELEASED runs a change with the service released and restores it, with Rust's tests ported. Depends: 5bb40924. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
