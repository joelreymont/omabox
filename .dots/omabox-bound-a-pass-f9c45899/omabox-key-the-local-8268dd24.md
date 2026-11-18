---
title: Key the local inventory by canonical path
status: active
priority: 2
issue-type: task
created-at: "2026-11-18T14:18:41.051539+02:00"
---

Problem: local_observations (migrations/0001.sql:6) is keyed only by path, so a pass cannot read the local side in canonical order or look up a path's case variants without loading the whole inventory. The user approved schema 9 on 2026-11-18, which the Rust daemon cannot open. Acceptance: a new journal is created at schema 9 and a schema-8 journal migrates to it in one transaction; local observations carry their canonical path, indexed with path; schemas other than 9 are refused unchanged. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-schema-9
