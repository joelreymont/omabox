---
title: "Print the Rust version's test answers"
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T20:22:00.956351+02:00"
---

Problem: the Habu port must write the journal's JSON byte for byte as serde did and decide as the Rust planner decides (docs/habu-rewrite.md, Tests); hand-written expectations cannot show that. Acceptance: a test-only generator on the rust branch prints every stored value's JSON, the planner's whole table and FOLD over a case corpus, and its output is under src/oracle/ on master. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-oracle-rust and .jj-ws.noindex/omabox-oracle-data.
