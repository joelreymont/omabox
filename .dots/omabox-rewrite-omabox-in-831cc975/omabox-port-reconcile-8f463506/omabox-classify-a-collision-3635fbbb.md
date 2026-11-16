---
title: "Classify a collision copy's failure in REPLAY"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T13:33:26.803332+02:00"
closed-at: "2026-11-16T14:36:12.079333+02:00"
---

Problem: src/reconcile.f COPY-REMOTE and COPY-FAILED catch MATERIALIZE-REMOTE-COPY-AT's failure and repeat REPLAY's REMOTE-CONFLICT-AT classification. Acceptance: REPLAY:MATERIALIZE-REMOTE-COPY-AT answers a blocked download as an outcome; RECONCILE's catch and its helper words are gone; a blocked collision copy is logged once with its reason (src/replay.f's header), and a refused and an unverified copy each have a test. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-collision-copy
