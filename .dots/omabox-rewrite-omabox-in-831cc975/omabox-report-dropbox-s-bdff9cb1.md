---
title: "Report DROPBOX's root checks as Rust does"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.197019+02:00"
closed-at: "2026-11-17T00:06:29.332440+02:00"
---

Problem: src/dropbox.f LINK and CHECK-ROOT answer failed without naming the Dropbox operation, so omabox setup prints only a validation help for a network fault (Rust: Dropbox operation `inspect authorized Dropbox account` failed); ENTRY-CHECK calls a deleted root not-folder where Rust says unavailable; CHECK-ROOT unavailable and LINK E-ROOT-PATH are untested; src/reconcile.f repeats E-ROOT-PATH's text. Acceptance: a failed LINK or CHECK-ROOT logs the operation line; a deleted root answers unavailable; dropbox-test covers each. Depends: none. Claim: agent=f-root workspace=.jj-ws.noindex/omabox-f-root.
