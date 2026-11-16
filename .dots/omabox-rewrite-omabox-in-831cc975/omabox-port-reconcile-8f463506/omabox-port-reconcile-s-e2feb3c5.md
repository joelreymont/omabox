---
title: "Port RECONCILE's listing"
status: active
priority: 2
issue-type: task
created-at: "2026-11-16T09:55:49.495501+02:00"
---

Problem: RECONCILE needs dropbox.rs's refresh_inventory: a full listing or a cursor delta, published only once complete, with entries turned into inventory changes (dropbox.rs:627-664, :1820-2099) and E-LISTING for a root or entry the listing cannot use (docs/habu-rewrite.md, RECONCILE). Acceptance: the INVENTORY-PUBLICATION machine and those words in src/reconcile.f; tests/dropbox_fake.rs's listing tests (:7363, :7430, :7484, :7542, :7592, :7661, :7706, :7776) pass under their names in src/reconcile-test.f. Depends: none. Claim: workers workspace=.jj-ws.noindex/omabox-listing-machine, omabox-listing-pages, omabox-listing-errors.
