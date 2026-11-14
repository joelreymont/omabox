---
title: Report each daemon failure under its own cause
status: active
priority: 2
issue-type: task
created-at: "2026-11-14T15:43:41.612270+02:00"
---

Problem: src/daemon.rs:350-353 maps sync-root inspection failures to DaemonError::Journal, so a missing folder reads 'The sync journal is temporarily unavailable.' (src/daemon.rs:761); src/daemon.rs:939-942 gives DownloadWorkerStopped and the reconcile clock failure the sync-folder text, and src/daemon.rs:908 gives the recovery clock failure the per-file text. Acceptance: each of these publishes a status naming its own cause; dispositions are unchanged except that a root whose filesystem records no birth time needs user action. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-report-each-daemon-cfb09cac.
