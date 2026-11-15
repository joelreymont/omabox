---
title: Publish casefold-mismatched entries as unsupported
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.578605+02:00"
---

Problem: a listing entry whose display path does not lowercase to Dropbox's lowercase path fails the whole listing. Acceptance: such an entry becomes an unsupported record keyed by Dropbox's lowercase path and is logged once per path, and the rest of the inventory publishes (test). Depends: none. Claim: unassigned.
