---
title: Block one path on a Dropbox path mismatch
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T01:34:44.973203+02:00"
closed-at: "2026-11-16T02:29:57.020343+02:00"
---

Problem: src/dropbox.f COMMITTED? (:2263-2279) throws E-ANSWER when the committed entry's path_lower is not the upload path's lowercase, which ends every sync pass at that plan and stops unrelated work; Rust confirms the answer through get_metadata and answers Rejected(PathMismatch) for that path alone (rust src/dropbox.rs:1104-1110, :1194-1199, :1333-1338). Acceptance: such an answer, from UPLOAD, DELETE or CREATE-FOLDER, is confirmed as a lost one, and a confirmation whose entry still names another path answers refused path-mismatch; dropbox-test.f shows both. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-dropbox-mismatch.
