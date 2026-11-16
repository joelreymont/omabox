---
title: Validate the Dropbox account in DAEMON
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T15:56:11.503054+02:00"
closed-at: "2026-11-16T19:18:22.691389+02:00"
---

Goal: before syncing, the daemon checks once per client that the token still belongs to the bound account, namespace and remote root, and checks the journal's binding every time, as rust dropbox.rs:597-621, :1410-1428 do. Acceptance: the fake tests dropbox_fake.rs:7330, :8053, :8073, :8137 pass under their names. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-daemon-account.
