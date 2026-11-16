---
title: "Read NOTIFY_SOCKET with Habu's listener"
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T18:24:57.169014+02:00"
---

Problem: src/omaboxd-test.f binds and reads a unix datagram socket through its own socket, bind and recv FFI words (SOCKET-CALL..RECEIVED), copied from Habu's private systemd-test.f:49-141; Habu was asked on 2026-11-16 for a library word that does this. Acceptance: omaboxd-test reads the readiness datagram through that Habu word and defines no socket FFI of its own. Depends: the Habu word landing on Habu master. Claim: unassigned.
