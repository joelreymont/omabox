---
title: Reconcile every TLA+ model with the landed code
status: open
priority: 2
issue-type: task
created-at: "2026-09-02T16:37:10.456324+02:00"
blocks:
  - omabox-isolate-per-path-3600f60c
  - omabox-record-readable-conflict-9224fe0a
  - omabox-publish-unsupported-and-8439e183
  - omabox-protect-in-flight-34128729
  - omabox-fix-planner-prop-527a90ec
  - omabox-classify-daemon-errors-dd34c00a
---

Problem: formal/*.tla were written against the pre-remediation code; the campaign changes slot ownership (DownloadLifecycle DiscardStaleSlot guard), per-job permanent failures (DownloadExecutor; its Crash action currently returns a Blocked job to Pending, which must change to a durable Blocked once section B's PlanStatus::Blocked is consumed), blocked plans and supersede-on-divergence (MutationLifecycle, SyncBehavior), Unknown observations for restricted or inaccessible entries and the ancestor rule (InventoryPublication, SyncBehavior), and the notify/disposition daemon loop (ScanCoordination assumptions). formal/README.md must state what each model proves and which code function realizes each action. Acceptance: every model updated where the code's guards or states changed, with a comment per action naming the Rust function it abstracts; every .cfg checks the stated invariants and, where a liveness claim is made in README, a fairness constraint and a PROPERTY; all six models pass TLC from a clean states directory with recorded state counts; formal/README.md gains an action-to-code table and the exact commands; any model that no longer matches the code is fixed in the model or the code, never by weakening an invariant. Files: formal/*.tla, formal/*.cfg, formal/README.md. Verify: for each model, cd formal && java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar -config <M>.cfg <M>.tla. Depends: blocked, conflicts, scanunknown, slots, prooftests, dispositions. Ownership: formal models. Claim: unassigned.
