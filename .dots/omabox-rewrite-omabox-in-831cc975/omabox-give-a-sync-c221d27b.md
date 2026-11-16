---
title: "Give a sync root's open or identity failure its own code"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T03:06:43.664293+02:00"
closed-at: "2026-11-16T03:09:09.671732+02:00"
---

Problem: src/journal.f OPENED (:564) and IDENTITY (:586) throw E-FILE, the code of JOURNAL's own database failures, when the sync root cannot be opened or statx fails on it; DAEMON's code table then cannot give it Rust's SYNC_ROOT status (daemon.rs:834-836). Acceptance: those failures throw a JOURNAL code of their own, tested. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-journal-root
