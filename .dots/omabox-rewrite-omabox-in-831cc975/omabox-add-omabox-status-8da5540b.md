---
title: Add omabox status and settings
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T19:29:24.171529+02:00"
closed-at: "2026-11-17T00:06:29.228940+02:00"
---

Problem: omabox has no status or settings command (rust src/bin/omabox.rs:419-503). Acceptance: omabox status prints ATTENTION's text and settings prints the stored root and app key, as text or JSON, with Rust's tests ported. Depends: 5bb40924. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
