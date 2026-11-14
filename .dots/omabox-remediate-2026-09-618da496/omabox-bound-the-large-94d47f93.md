---
title: Bound the large listing test by work, not wall time
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T11:08:13.113100+02:00"
---

Problem: tests/dropbox_fake.rs large_full_listing_builds_its_inventory_in_linear_time asserts a 20000-entry refresh_inventory finishes within 5 s of wall time; with 12 test binaries running on 12 CPUs it failed 14 of 673 runs at 5.05-6.84 s, because wall time includes waiting for the CPU and for fsync. Acceptance: the test fails a listing that rescans the inventory per page or per entry, and does not fail under that load (reproducer run). Depends: none. Claim: unassigned.
