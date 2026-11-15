---
title: "Skip the remote root's own listing entry"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:36.012800+02:00"
closed-at: "2026-11-15T08:23:44.647966+02:00"
---

Problem: relative_paths (src/dropbox.rs) turns the remote root's own entry into InvalidEntryPath, so a recursive listing of a non-root remote root that includes the root folder fails every pass. Acceptance: a folder entry at the root is skipped, a deleted root entry is RemoteRootUnavailable with the inventory and cursor unchanged, a restricted root stays RemoteRootRestricted, and the fake /Sync fixture includes its root entry (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-skip-the-remote-4344af8f.
