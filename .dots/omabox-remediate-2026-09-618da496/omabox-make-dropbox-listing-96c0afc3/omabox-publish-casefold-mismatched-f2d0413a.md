---
title: Publish casefold-mismatched entries as unsupported
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.578605+02:00"
---

Problem: relative_paths (src/dropbox.rs) fails the whole listing with InvalidEntryPath when an entry's display path does not lowercase to its path_lower. Acceptance: such an entry is an Unknown(Unsupported) record keyed by Dropbox's path_lower and logged once per path, and the rest of the inventory publishes (test). Depends: none. Claim: unassigned.
