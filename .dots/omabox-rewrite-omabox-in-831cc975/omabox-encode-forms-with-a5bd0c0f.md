---
title: "Encode forms with Habu's form encoder"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T19:00:49.742612+02:00"
closed-at: "2026-11-26T10:47:51.851193+02:00"
---

Problem: Omabox has two private percent encoders, AUTH's form_urlencoded one (QUERY's FORM-BYTE, in the AUTH:BEGIN commit) and DROPBOX's ENCODED+ (src/dropbox.f:796-807), whose RFC 3986 set writes token bodies unlike Rust's form_urlencoded bytes (~ and * and space). Acceptance: AUTH's URL and DROPBOX's token bodies use Habu's library form encoder; neither private encoder remains; auth-test and dropbox-test pass. Depends: Habu's form-encoding word on master (requested of Habu's owners, /tmp/bob-habu-lib-request.md on spark). Claim: agent=worker workspace=.jj-ws.noindex/omabox-form-encode.
