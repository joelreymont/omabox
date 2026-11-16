---
title: Add the omabox command
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T19:19:33.907125+02:00"
closed-at: "2026-11-17T00:06:29.222624+02:00"
---

Problem: the Habu port has no omabox program (rust src/bin/omabox.rs). Acceptance: omabox parses Rust's forms for help, version, pause, resume, service and logs and runs them through SERVICE, failing as Rust's CliError says; omabox-test and omaboxd-test pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-cli-parse.
