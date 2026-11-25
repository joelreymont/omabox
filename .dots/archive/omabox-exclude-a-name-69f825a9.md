---
title: Exclude a name and its key alike
status: closed
priority: 2
issue-type: task
created-at: "2026-11-25T11:12:45.291481+02:00"
closed-at: "2026-11-25T11:18:24.286921+02:00"
---

Problem: exclusion is decided three ways that disagree on a name whose lowercase differs in ASCII. The scan tests the display name with an ASCII-case suffix match (src/local.f SCAN-NAME, MODEL:EXCLUDED-NAME? src/model.f:530), deciding tests the key (src/reconcile.f EXCLUDED-KEY?, MODEL:EXCLUDED? on the per-component UNICODE:LOWER of FOLD src/model.f:424), and replay tests the plan's display path (src/replay.f RUNNABLE?). U+212A KELVIN SIGN lowers to k, so desktop.ini spelled with it is observed and hashed by the scan, never decided, and not retired by replay; two spellings of one key can get different answers. Rust has the same split (exclusions.rs, reconcile.rs:1137, local.rs:2728). Acceptance: every spelling of a key gets the key's answer, at every check; a test shows the Kelvin spelling excluded. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-exclusion.
