---
title: Bind test sockets at any path depth
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.214690+02:00"
closed-at: "2026-11-17T00:06:29.318424+02:00"
---

Problem: src/test-client.f SOCKET-AT binds the full path, so reconcile-test and local-test fail when TMPDIR makes it 108 bytes or longer. Acceptance: SOCKET-AT binds through the parent directory's descriptor and both suites pass under a long TMPDIR. Depends: none. Claim: agent=f-socket workspace=.jj-ws.noindex/omabox-f-socket.
