---
title: Check the FSM tables against the TLA+ models
status: open
priority: 2
issue-type: task
created-at: "2026-11-17T11:44:47.582142+02:00"
---

Problem: the Habu code's nine FSM:DEFINE tables (src/daemon.f:879, src/dropbox.f:1542, :3057, src/service.f:793, src/replay.f:836, :2595, src/reconcile.f:2019, :2735, :3806) name the formal/ models they follow only in comments, five of them; nothing checks a table against its model, so either can change and the other stay as it was. The user asked for a mechanical check and, on 2026-11-17, for a model of every table: src/reconcile-test.f checks INVENTORY-PUBLICATION and DOWNLOAD-EXECUTOR against their models; the other seven tables have no model their lines follow. Acceptance: every child closes, so each of the nine tables has a formal/ model and a check that fails when table and model disagree. Depends: none. Claim: unassigned.
