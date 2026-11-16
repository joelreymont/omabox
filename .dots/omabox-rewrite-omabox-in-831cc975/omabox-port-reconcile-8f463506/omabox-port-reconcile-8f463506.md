---
title: Port RECONCILE
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T04:23:12.555467+02:00"
---

Problem: the Habu daemon has no sync pass (rust src/reconcile.rs reconcile_once; docs/habu-rewrite.md RECONCILE row). Acceptance: src/reconcile.f ports reconcile_once as RECONCILE:PASS per the settled design in docs/habu-rewrite.md; the tests of tests/dropbox_fake.rs that run a pass, and reconcile.rs's unit tests, pass under their names in src/reconcile-test.f. Depends: omabox-port-replay-cc40b068. Claim: unassigned.
