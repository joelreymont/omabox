---
title: "Mark restricted folders; read a download's status"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T04:23:12.557896+02:00"
closed-at: "2026-11-16T11:21:23.030489+02:00"
---

Problem: src/dropbox.f's entry has no restricted flag, so a folder whose sharing_info says no_access or traverse_only lists as an ordinary empty directory and its baselined children would plan as remote deletions (rust dropbox.rs:1590-1595); and a download answered with an unmapped 4xx cannot be told from a status that ends the pass, because the status is private (CLIENT-STATUS). Acceptance: entry.restricted and DROPBOX:HTTP-STATUS, tested in src/dropbox-test.f. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-reconcile-dropbox.
