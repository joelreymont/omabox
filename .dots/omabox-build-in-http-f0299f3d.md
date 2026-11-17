---
title: Build in HTTP, TLS, Unicode and notify as Rust does
status: open
priority: 2
issue-type: task
created-at: "2026-11-17T09:38:02.987847+02:00"
---

Problem: omaboxd loads libcurl with OpenSSL, libunistring and libsystemd at run time (40 libraries, 27.8 MB beyond what the Rust daemon loads), where Rust compiles in its HTTP client and TLS (ureq, rustls), std's Unicode tables, and writes NOTIFY_SOCKET itself (JOURNAL.md, 'binary size and build time, measured twice'). Goal: Habu's own implementations of these, as Rust's; libsecret stays a system library. Acceptance: the running omaboxd maps none of libcurl, libssl, libcrypto, libunistring or libsystemd; every suite passes; the journal records the new size and footprint. Depends: the user's go-ahead (2026-11-17: dot it, implement after the release); the Habu library work it needs, in Habu's repository. Claim: unassigned.
