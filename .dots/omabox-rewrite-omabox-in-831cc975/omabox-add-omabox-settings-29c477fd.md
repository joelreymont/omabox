---
title: Add omabox settings set-root
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T19:29:24.180197+02:00"
closed-at: "2026-11-17T00:06:29.253904+02:00"
---

Problem: omabox cannot change its sync root (rust src/bin/omabox.rs:505-632). Acceptance: omabox settings set-root PATH adopts the root in the journal, writes config.toml and restores the service as Rust does, with Rust's tests ported. Depends: 5bb40924. Claim: agent=worker workspace=.jj-ws.noindex/omabox-cli-setroot.
