---
title: Recover environmental daemon failures in process
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-09-05T10:30:06.209829+03:00\\\"\""
closed-at: "2026-09-05T10:51:17.087235+03:00"
close-reason: "landed and verified: Astra reviewed typed recovery/exit policy and retained-session loop; required fixes preserve active pools on network retries, reconstruct stopped workers, and escalate repeated long-poll failures after clean scans. Held-lock, 401, bounded delay, error persistence and exit-code tests pass; fmt, clippy all targets -D warnings, full cargo test on integrated root/slot base and forbidden scan pass."
---

Problem: local storage/keyring/root failures terminate the daemon, retries do not escalate or cap server delays, and phase changes clear errors before successful sync. Acceptance: one typed disposition policy distinguishes retry/environmental wait/user action/invariant; retry 5s doubling to5min, Retry-After capped15min; environmental failure retains instance ownership and recovers in-process; repeated401 session refresh cannot busy-loop; setup/credential binding rejection exits78, invariants70; safe status persists until successful pass. Files: src/daemon.rs, src/bin/omaboxd.rs, src/lib.rs, src/runtime_status.rs and focused tests. Verify: real production control-path failure/recovery with injected waits, every error-class mapping, bounded401/backoff, status tests, Rust gates. Depends: root lane API before final checks; current Dropbox API, no SDK migration. Ownership: Sol daemon lane in fix-daemon workspace; root journal/CLI belongs to root lane. Existing unfinished disposition workspace is read-only reference.
