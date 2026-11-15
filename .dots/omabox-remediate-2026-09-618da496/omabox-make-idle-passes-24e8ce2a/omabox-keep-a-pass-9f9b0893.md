---
title: "Keep a pass's local effects on the verified root"
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.583510+02:00"
---

Problem: prepare-time effects such as conflict copies open the sync root by path, so if the root is swapped mid-pass they land in the new root, while the root is checked once per planned path. Acceptance: every local effect of a pass goes through the root handle held since the root was verified, the root is checked once before planning and once before the completion batch, and a test that swaps the root mid-pass shows no effect lands in the new root. Depends: none. Claim: unassigned.
