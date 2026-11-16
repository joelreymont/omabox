---
title: Classify a failed mutation per path
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T13:49:49.043751+02:00"
closed-at: "2026-11-16T14:36:12.104575+02:00"
---

Problem: src/dropbox.f answers a 5xx, a 408, a lost session start, an append lost twice or a session gone twice in a mutation (MUTATE, SESSION) as retry, so REPLAY stops the pass and one path whose mutation keeps failing stops every pass. Rust treats every mutation failure but a rate limit as possibly applied (dropbox.rs mutation_may_have_applied :2429) and verifies that one path. Acceptance: UPLOAD, DELETE and CREATE-FOLDER answer retry only when Dropbox asks to wait (429, too_many_write_operations) and refused unverified otherwise; REPLAY reads the path back and the pass goes on. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-failed-mutation
