---
title: Build in Unicode case mapping as Rust does
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T09:38:02.987847+02:00"
closed-at: "2026-11-27T08:55:42.985092+02:00"
---

Problem: omaboxd still loads libunistring at run time, because Habu's src/lib/unicode.f maps a non-ASCII name's case through u8_casefold and u8_tolower, where Rust uses std's own Unicode tables. Goal: Habu's own case mapping, as Rust's. Acceptance: the running omaboxd maps no libunistring and the package does not depend on it; every suite passes. Depends: the Habu library work it needs, in Habu's repository. Claim: unassigned.
