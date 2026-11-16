---
title: Order paths once, in MODEL
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T19:11:28.824130+02:00"
closed-at: "2026-11-17T00:06:29.204410+02:00"
---

Problem: RECONCILE's PATH-CMP (src/reconcile.f:234-251) and ATTENTION's sort keys each implement Rust's Path::cmp, one only for normalized paths. Acceptance: one public MODEL:PATH-CMP, Rust's Path::cmp over any path, used by both; model-test, attention-test and reconcile-test pass. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-lead.
