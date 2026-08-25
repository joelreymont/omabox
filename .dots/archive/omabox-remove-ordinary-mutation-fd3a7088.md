---
title: Remove ordinary mutation backups
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-08-25T17:22:30.324204+02:00\\\"\""
closed-at: "2026-08-25T21:47:20.229798+02:00"
close-reason: "landed and verified: 1f8c069f removes ordinary preservation work; nightly full suite/clippy/fmt/forbidden scans and all relevant TLC models pass; deployed daemon converges without backup downloads or QuickShell restart"
---

Problem: Omabox creates independent recovery copies for ordinary local/Dropbox delete and replace operations even though Dropbox retains deleted files and prior revisions; remote deletes therefore trigger unnecessary serial downloads. Acceptance: new ReplaceLocal/DeleteLocal/ReplaceRemote/DeleteRemote plans contain no PreserveLocal/PreserveRemote operations and create no recovery copy/record; genuine conflicts still preserve every distinct side; legacy persisted PreserveLocal/PreserveRemote operations remain decodable and retire as no-ops without downloads, copies, or required backup data; existing completed recovery records/files are not purged by upgrade and may age out under existing retention; revision/content preconditions, atomic verified installs, uncertain-deletion protection, and post-effect baseline advancement remain intact; current legacy plans resume without new preservation downloads. Update AGENTS.md, PLAN.md, planner/replay/preparation code, tests, and only relevant formal artifacts. Verify nightly fmt, clippy -D warnings, banned-pattern scan, full tests, snapshots/properties/crash/fake Dropbox, TLC if durable replay changed, release deployment, service convergence, no increase in recovery copies, and no QuickShell regression.
