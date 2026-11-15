---
title: "Render the primary failure's help in compound errors"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T08:07:55.284697+02:00"
closed-at: "2026-11-15T10:03:10.452079+02:00"
---

Problem: RollbackFailed, CleanupFailed (src/install.rs) and CleanupAfterWrite (src/config.rs) hold the primary failure as a plain #[source], so miette prints its text without its help; e.g. a cleanup failure after ShellLocked omits 'Unlock the session...'. Acceptance: the rendered report shows the primary failure's help and the second failure's help for each compound variant (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-render-the-primary-b269e165.
