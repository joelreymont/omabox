---
title: "Keep a pass's local effects on the verified root"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.583510+02:00"
closed-at: "2026-11-26T13:18:09.843350+02:00"
---

Problem: prepare-time effects such as conflict copies open the sync root by path, so if the root is swapped mid-pass they land in the new root, while the root is checked once per planned path. Acceptance: every local effect of a pass opens the sync root through its identity check (LOCAL:OPEN-ACTIVE-ROOT) or acts below the directory it returned, and a test that swaps the root mid-pass shows no effect lands in the new root. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-root-handle.
