---
title: Reject a mutation Dropbox confirms at another path
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.581140+02:00"
closed-at: "2026-11-15T10:28:39.792237+02:00"
---

Problem: validate_mutation_path (src/dropbox.rs) turns a mutation whose confirmed path differs from the requested one into an error instead of a per-path rejection. Acceptance: the mismatch is a MutationRejection variant with its own saved tag, blocking only that plan (test). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-reject-a-mutation-59affec5.
