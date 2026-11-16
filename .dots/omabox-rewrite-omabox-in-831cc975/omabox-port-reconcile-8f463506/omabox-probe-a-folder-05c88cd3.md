---
title: Probe a folder as Rust does before deleting it
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T12:44:12.539257+02:00"
closed-at: "2026-11-16T14:36:12.005973+02:00"
---

Problem: REPLAY's PROBED (src/replay.f:1422) lists the folder through DROPBOX:LIST, recursive, with no limit and every page; Rust's probe_folder (dropbox.rs:1052-1089) lists it non-recursive with limit 1, stops at the first entry other than the folder, and takes a continue page whose cursor did not advance as Interrupted, so the delete stays pending. Acceptance: the pass's directory deletion tests pass with Rust's probe asserts (limit 1, not recursive). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-probe.
