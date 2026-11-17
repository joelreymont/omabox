---
title: "Model the download's root check in DownloadExecutor"
status: open
priority: 2
issue-type: task
created-at: "2026-11-17T12:08:05.703983+02:00"
---

Problem: DOWNLOAD-EXECUTOR's line staged changed - >unrooted (src/reconcile.f:2742) has no step in formal/DownloadExecutor.tla, which has no root: Install is the only step out of Staged (StagedStable, :199). So the model does not describe a download whose root changed before install. Acceptance: the model has the root check, keeps the download staged and its plan pending when the root changed, and states that nothing installs under a root that is no longer active; a TLC run the user approves passes. Depends: none. Claim: unassigned.
