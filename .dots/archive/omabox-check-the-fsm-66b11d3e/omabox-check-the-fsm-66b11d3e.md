---
title: Check the FSM tables against the TLA+ models
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T11:44:47.582142+02:00"
closed-at: "2026-11-18T09:51:04.985222+02:00"
---

Problem: an FSM:DEFINE table that names its formal/ model only in a comment can change while the model stays as it was, or the other way round. The user asked for a mechanical check and, on 2026-11-17, for a model of every table; each child brings one table under the check. Acceptance: every child closes, so each FSM:DEFINE table has a formal/ model and a check that fails when table and model disagree. Depends: none. Claim: unassigned.
