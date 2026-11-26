---
title: Hold a sync pass in bounded memory
status: open
priority: 2
issue-type: task
created-at: "2026-11-26T16:01:35.757445+02:00"
---

Problem: on spark the daemon's first pass over a 20,452-entry Dropbox (88 GB) holds memory in proportion to the whole Dropbox for as long as it runs, hours on a first sync: the pass keeps every decision and plan until it ends, about 2.8 KB per listed entry. Planning keeps every decision (src/reconcile.f DECIDE-ALL, ORDER-PATH-DECISIONS) and every plan (DECIDE-EACH, PUSH-PLAN) and records them in one transaction (RECORD-PLANNING); applying loads all pending plans (STEP-AT, src/replay.f REPLAY-LOCAL-PLANS-AT); finishing loads all completed plans (RETIRE-ROOTED). Acceptance: the memory a first pass holds does not grow with the number of entries listed, measured at 2,000 and 20,000 entries, and the daemon is back within AGENTS.md's idle-heap limit once the pass ends. Depends: none. Claim: unassigned.
