---
title: Resume interrupted exact downloads
status: active
priority: 0
issue-type: task
created-at: "\"2026-08-24T23:22:18.522452+02:00\""
blocks:
  - omabox-upload-large-files-3cbecd7a
---

Problem: exact downloads use O_TMPFILE until EOF, so any daemon/network interruption discards all transferred bytes; this is production-critical for multi-gigabyte files.
Acceptance: keep the pending file operation as the only journal authority; use four fixed owner-marked slots in the private XDG staging directory, bound to root generation and pending operation identity, so partial artifacts cannot grow with revisions, paths, or root changes. Checkpoint data and durable offset every 64 MiB aligned to Dropbox’s 4 MiB hash blocks, truncate uncheckpointed tails on restart, and resume exact `rev:` downloads with `Range`. Append only after validating 206, exact Content-Range start/total, metadata revision/hash/size, and response length. Rehash the durable prefix rather than persisting hasher internals. Promote exact-size, full-hash-verified bytes through the existing atomic verified-stage/install path; copy and rehash once only when the staging and sync filesystems differ. Preserve unknown slot occupants and fall back to unnamed staging. Pre-plan conflict/recovery downloads remain unnamed and disposable. No SQLite schema, dynamic overflow names, age scavenger, scheduler, or TLA expansion.
Files: src/local.rs, src/dropbox.rs, minimal reconcile plumbing, focused fake/crash/property tests.
Verify: interruption/resume and malformed-range fake tests; crash checkpoints; four-slot bound, stale reclaim, root/operation binding, unknown occupants, checkpoint properties; all Rust gates and existing TLC model.
Depends: large-upload change.
Ownership: persistent exact-download partial lifecycle only, not upload sessions or new retry policy.
