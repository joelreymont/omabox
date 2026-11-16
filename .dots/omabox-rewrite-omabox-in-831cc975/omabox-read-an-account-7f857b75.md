---
title: "Read an account's root by its tag"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T17:39:56.413247+02:00"
closed-at: "2026-11-16T19:18:22.676935+02:00"
---

Problem: src/dropbox.f:1042-1061 ACCOUNT-READ reads root_namespace_id under any root_info tag and throws E-ANSWER without one, where rust dropbox.rs:1597-1603 takes it only from user or team and treats another tag as a changed binding. Acceptance: another tag answers an empty namespace, which DAEMON's VALIDATE answers as root-changed. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-root-tag.
