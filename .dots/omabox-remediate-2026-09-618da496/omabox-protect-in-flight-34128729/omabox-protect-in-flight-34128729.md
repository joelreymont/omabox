---
title: "Retire or reuse verified download stages"
status: open
priority: 1
issue-type: task
created-at: "\"2026-09-02T11:28:11.358335+02:00\""
---

Problem: superseding a download plan or finishing it as a conflict retires the journal work without removing or reusing its verified download stage, so stages accumulate and a conflict downloads the remote copy again. Protected leasing and in-flight slot ownership have landed. Acceptance: every child closes; a verified download stage is removed when its plan is superseded or ends, and a plan that ends as a conflict reuses the stage's bytes instead of downloading the remote copy again. Depends: none. Claim: unassigned.
