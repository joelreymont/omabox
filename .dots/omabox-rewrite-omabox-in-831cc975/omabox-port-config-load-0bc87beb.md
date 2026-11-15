---
title: "Port CONFIG: load, prepare, lock"
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T20:22:00.962928+02:00"
---

Problem: the daemon needs its paths, config.toml and the instance lock (rust src/config.rs: resolve_private, load, prepare, InstanceLock). Acceptance: src/config.f loads what the Rust version loads, refuses what it refuses, makes the state directories 0700 and flocks the daemon.lock the Rust daemon flocks. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-config.
