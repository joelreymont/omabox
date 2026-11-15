---
title: Show both chains of compound errors
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.593867+02:00"
closed-at: "2026-11-15T09:32:09.597224+02:00"
---

Problem: RollbackFailed, CleanupFailed and ConfigError::CleanupAfterWrite render the second failure only as Display text, dropping its causes and help. Acceptance: each renders both failures' full chains and help through miette related, and has help itself (render tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-show-both-chains-da085f93.
