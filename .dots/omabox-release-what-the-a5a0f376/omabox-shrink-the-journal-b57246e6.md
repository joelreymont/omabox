---
title: "Shrink the journal's page cache"
status: open
priority: 2
issue-type: task
created-at: "2026-11-18T14:32:53.994383+02:00"
---

Problem: each journal connection keeps SQLite's default page cache of about 2 MB, which an idle daemon does not need. Acceptance: journal connections use a small page cache, a pass's time unchanged, measured on the live daemon. Depends: none. Claim: unassigned.
