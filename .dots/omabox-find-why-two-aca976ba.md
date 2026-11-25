---
title: Show a local deletion that Dropbox entries hold
status: active
priority: 2
issue-type: task
created-at: "2026-11-25T11:22:47.427898+02:00"
---

Problem: PLANNER DELETE-FOLDER (src/planner.f:96) holds a folder deleted locally while its Dropbox folder still holds entries, since Dropbox would delete them with it. The hold makes no plan, so `omabox status` (src/attention.f, which lists blocked plans, unknown observations and recovery copies) never says the deletion is held; it shows only as the log's blocked=. Live 2026-11-25: a folder deleted locally holds a folder with 22 entries of an unsupported kind on Dropbox; both are held every pass and the user is not told. Acceptance: `omabox status` lists each such folder and why it is held; a test with a locally deleted folder whose Dropbox folder holds an entry shows it, and one whose Dropbox folder is empty does not. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-blocked-dirs.
