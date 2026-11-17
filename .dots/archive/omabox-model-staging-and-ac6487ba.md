---
title: Model staging and copies before the plan
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T16:53:28.427920+02:00"
closed-at: "2026-11-17T17:22:14.879598+02:00"
---

Problem: formal/SyncBehavior.tla's BeginPlan records the plan (journal Pending) before StageUpload and before the conflict copies, and JournalAuthorizesEffects (:338) requires it, but the code stages an upload (PREPARE-OPERATION src/reconcile.f:2138) before RECORD-PLANNING (:3537) and makes conflict copies before RECORD-CONFLICT with no plan (:3425-3438), as Rust does; the model claims an order the code does not keep. Acceptance: the model's upload and conflict steps follow the code's order, JournalAuthorizesEffects states what the code keeps, and SyncBehavior.cfg passes TLC as the user approves. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-syncbehavior.
