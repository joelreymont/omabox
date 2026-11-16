---
title: "Hold a held collision's subtree"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T13:49:49.046562+02:00"
closed-at: "2026-11-16T14:36:12.128156+02:00"
---

Problem: a directory collision whose copy download is blocked is held for the pass (RECONCILE:PASS), but with a file inside the local directory the pass still plans an operation there: create_folder_v2 then get_metadata, and one plan is left blocked. The cause is unknown. Acceptance: the cause is found and the pass plans nothing at or under a held collision's path, while unrelated paths sync. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-hunt-held-subtree
