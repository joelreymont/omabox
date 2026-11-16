---
title: Check the root before installing a download
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T11:39:08.846962+02:00"
closed-at: "2026-11-16T14:36:11.995288+02:00"
---

Problem: src/reconcile.f RUN-DOWNLOADS checks LOCAL:CONFIGURED-ROOT-IS-ACTIVE? once before the replay step's downloads, then DOWNLOAD-EXECUTOR's INSTALL installs each staged download at once. A root swapped while a download runs gets the install in the old root and a completed plan, where Rust (reconcile.rs:836-845, test dropbox_fake.rs:4667) checks the root before every install and leaves the plan pending. Acceptance: a staged download installs only while the root is still active; otherwise it stays staged, its plan pending, and the step answers root-changed. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-step-root
