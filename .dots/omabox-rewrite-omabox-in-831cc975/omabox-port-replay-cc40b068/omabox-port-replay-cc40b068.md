---
title: Port REPLAY
status: active
priority: 2
issue-type: task
created-at: "2026-11-16T01:31:32.508973+02:00"
---

Problem: the Habu daemon cannot replay pending plans (rust src/recovery.rs; docs/habu-rewrite.md REPLAY row and "Machines"). Acceptance: src/replay.f ports recovery.rs's production words (retention, local and remote replay, conflict copies), each pending operation run by an fsm.f table named after formal/MutationLifecycle.tla; recovery.rs's tests pass under their names in src/replay-test.f. Depends: omabox-port-local-6d1e8438. Claim: agent=workers workspace=.jj-ws.noindex/omabox-replay-*.
