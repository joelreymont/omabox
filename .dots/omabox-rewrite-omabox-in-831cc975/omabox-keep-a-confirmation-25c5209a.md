---
title: "Keep a confirmation's wait in a mutation's answer"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T02:15:22.280596+02:00"
closed-at: "2026-11-16T02:30:12.349204+02:00"
---

Problem: src/dropbox.f's SESSION machine answers an upload whose confirmation (get_metadata) Dropbox asks to wait with the upload's own reply, retry 0, dropping the wait; in verifying it restarts the upload instead. DELETE-REFUSED and FOLDER-REFUSED answer a conflict whose confirmation must wait as refused conflict. Rust propagates a confirmation's error with its wait (resolve_ambiguous, resolve_explicit_conflict). Also the finishing row's elsewhere DISTRUST has no test. Acceptance: an upload, finish, DELETE or CREATE-FOLDER whose confirmation answers retry n answers retry n, the upload in confirming and verifying; tests show both and the finishing row's DISTRUST. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-dropbox-wait.
