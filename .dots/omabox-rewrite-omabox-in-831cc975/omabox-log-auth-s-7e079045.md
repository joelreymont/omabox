---
title: "Log AUTH's Secret Service failures"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:20:55.850230+02:00"
closed-at: "2026-11-17T00:06:29.269146+02:00"
---

Problem: src/auth.f STORE and LOAD pass SECRET's codes on without a line of AUTH's, though AUTH's header says its failures are logged with Rust's text; where SECRET logs nothing (libsecret not loadable, no value), omabox setup prints only its own Auth line, with no cause. Acceptance: after any line SECRET logged, STORE logs Rust's CredentialSpawn text for SECRET:E-CONFIG and its CredentialStatus text, less the status libsecret lacks, for E-ACCESS and E-UNAVAILABLE; LOAD logs CredentialSpawn's for the E-CONFIG it rethrows; auth-test shows each. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-fix-secret
