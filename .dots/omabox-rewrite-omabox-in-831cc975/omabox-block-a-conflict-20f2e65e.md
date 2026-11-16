---
title: Block a conflict copy whose download answers 4xx
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T04:23:12.563816+02:00"
closed-at: "2026-11-16T11:21:23.038709+02:00"
---

Problem: REPLAY's REMOTE-CONFLICT-AT blocks a conflict copy only for a Dropbox refusal; a download answered 400 or another unmapped 4xx throws DROPBOX:E-BAD-REQUEST or E-STATUS and ends every pass at that plan, while Rust's download_block_reason blocks the path (reconcile.rs:571-585). Acceptance: one public REPLAY:DOWNLOAD-BLOCKAGE over a caught code and the link classifies every download failure; REMOTE-CONFLICT-AT uses it; tests show a 400 and a 404 copy download block only their plan. Depends: omabox-mark-restricted-folders-3c83248f. Claim: agent=worker workspace=.jj-ws.noindex/omabox-c2-classify.
