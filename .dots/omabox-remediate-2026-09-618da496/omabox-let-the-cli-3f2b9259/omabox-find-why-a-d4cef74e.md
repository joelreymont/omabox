---
title: Release the instance lock when it is dropped
status: closed
priority: 2
issue-type: task
created-at: "2026-11-15T09:40:52.072702+02:00"
closed-at: "2026-11-15T10:58:44.269640+02:00"
---

Problem: cargo test --bin omabox failed once with tests::failed_initial_setup_leaves_no_config_and_same_command_can_retry returning Lock { source: AlreadyRunning } on its second setup run, and passed on a rerun; the test calls no service code. Unverified hypothesis: InstanceLock (src/config.rs:787-817) uses flock, and a child that another test thread forks between dropping and re-taking the lock holds a copy of the lock's open file description until it execs. Cause, shown by the hunt: flock belongs to the open file description, and a child forked by a sibling test thread holds a copy of it until exec, so InstanceLock (src/config.rs:780-822), which releases the lock only by closing its file, stays locked after drop (13 failures in 1000 parallel runs, 0 in 1000 single-threaded; a 20 ms pre_exec sleep gave 18 in 150 with the holder caught each time). Acceptance: dropping InstanceLock releases the lock even while another descriptor of its open file description stays open (test), and the reproducer shows no failure in 500 parallel runs. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-find-why-a-d4cef74e.
