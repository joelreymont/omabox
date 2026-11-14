---
title: Give the legacy upgrade test power over cleared state
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T16:42:36.028414+02:00"
closed-at: "2026-11-14T17:07:43.566317+02:00"
---

Problem: the upgrade test's single-change assertion (journal.rs) holds with an upgrade that clears observations, hash cache or conflicts, because the schema-6 fixture has none. Acceptance: the test seeds rows that a new generation would clear and fails if the upgrade clears them. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-keep-sync-identity-b749771b
