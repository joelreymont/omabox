---
title: Make the transport test set up its connection
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T12:58:49.957168+02:00"
closed-at: "2026-11-16T14:36:12.044326+02:00"
---

Problem: GARBLED-CASE (src/dropbox-test.f) asserts CURLE_UNSUPPORTED_PROTOCOL, which libcurl gives a non-HTTP line only on a fresh connection; on a reused one it gives CURLE_WEIRD_SERVER_REPLY. The case got a fresh connection only because the case before it left its body unread, so a fake that reads every get_metadata body made it fail. Acceptance: the case sets up the connection it asserts, and passes whatever ran before it. Depends: none. Claim: lead.
