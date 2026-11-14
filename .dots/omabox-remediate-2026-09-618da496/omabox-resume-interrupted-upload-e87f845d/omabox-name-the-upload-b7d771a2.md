---
title: Name the upload session machine
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T07:54:35.987037+02:00"
---

Problem: upload_file and append_upload_session_chunk (src/dropbox.rs) drive the session with a correction flag, an optional transport failure and branches on offsets Dropbox reports, so no one place shows what happens for every outcome. Acceptance: the session flow is a named machine (states, inputs, a pure transition function) walked by a table test over every state and input; behaviour is unchanged and existing tests pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-name-the-upload-b7d771a2.
