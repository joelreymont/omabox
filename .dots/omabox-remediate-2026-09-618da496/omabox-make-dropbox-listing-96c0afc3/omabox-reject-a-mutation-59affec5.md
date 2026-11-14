---
title: Reject a mutation Dropbox confirms at another path
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.581140+02:00"
---

Problem: validate_mutation_path (src/dropbox.rs) turns a mutation whose confirmed path differs from the requested one into an error instead of a per-path rejection. Acceptance: the mismatch is a MutationRejection variant with its own saved tag, blocking only that plan (test). Depends: none. Claim: unassigned.
