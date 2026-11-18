---
title: Reach the keyring through secret-tool
status: closed
priority: 2
issue-type: task
created-at: "2026-11-18T14:32:53.987854+02:00"
closed-at: "2026-11-19T15:19:50.745856+02:00"
---

Problem: Habu's SECRET Linux store loads libsecret, which starts three GLib threads and keeps them for the daemon's life, for a credential read at start and written rarely. Acceptance: AUTH runs /usr/bin/secret-tool per credential read or write with the Rust version's arguments, libsecret is never loaded, and the failures keep their meaning. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-secret-tool
