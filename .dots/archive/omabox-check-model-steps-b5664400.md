---
title: Check model steps that keep the state
status: closed
priority: 2
issue-type: task
created-at: "2026-11-19T14:11:18.867802+02:00"
closed-at: "2026-11-19T14:18:04.880140+02:00"
---

Problem: formal/DownloadingFollows.tla:24-27, and the Follows of DownloadExecutor, InventoryPublication, LocalLifecycle and RemoteLifecycle, require a table line only of a step that changes At, so a model step that keeps At (DownloadingTable's streaming held and buffering chunk) need not be a line of the code's table. Acceptance: each Follows requires every machine step, one that keeps At included, to be a table line; the table-vs-model tests pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-follows-self.
