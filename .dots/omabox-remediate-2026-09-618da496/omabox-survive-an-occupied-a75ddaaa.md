---
title: Survive an occupied remote conflict copy name
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.614267+02:00"
---

Problem: when the remote conflict copy's name holds different bytes, ensure_exact_copy_at returns DestinationChanged and require_exact_copy raises InvalidJournalState, so the daemon exits as an invariant failure and restarts into the same state. Acceptance: that case affects only its own path and never stops the daemon or other work (test). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-survive-an-occupied-a75ddaaa.
