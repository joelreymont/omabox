---
title: Publish restricted folders and incomplete files as Unknown
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.575538+02:00"
blocks:
  - omabox-make-listing-subtree-82fa893c
  - omabox-skip-the-remote-4344af8f
---

Problem: append_entry_changes (src/dropbox.rs) fails the whole listing with RestrictedRemoteInventory for one no_access or traverse_only folder and with IncompleteFileMetadata for one file lacking content_hash or rev, so nothing syncs. Acceptance: such a folder is an Unknown(Inaccessible) record and such a file Unknown(Incomplete), EnsureDirectory never overwrites an Unknown record in the accumulator or in the delta, the rest of the inventory publishes, and nothing beneath an inaccessible folder is ever inferred deleted (tests, including the oracle tree property test with restricted folders). Depends: omabox-make-listing-subtree-82fa893c, omabox-skip-the-remote-4344af8f. Claim: unassigned.
