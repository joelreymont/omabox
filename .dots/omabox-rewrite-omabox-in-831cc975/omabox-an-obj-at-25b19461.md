---
title: "An object at a download stage's name blocks only its plan"
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T01:45:31.226079+02:00"
---

Problem: src/local.f INSPECT-DOWNLOAD-STAGE throws E-UNSUPPORTED or E-UNREADABLE (path the stage's) for a non-regular object or an unreadable file at a stage's internal name, as Rust's inspect_download_stage (src/local.rs:3714) does, which fails the whole pass; and Habu throws carry no path, so REPLAY cannot tell that from the same codes at a conflict copy's own name (src/recovery.rs:1197 copy_name_occupied). Acceptance: the stage answers destination-occupied, kept as it was, for those objects, so an install answers stage-destination-occupied and its plan blocks as stage-occupied; E-UNSUPPORTED and E-UNREADABLE from INSTALL-DOWNLOAD-AT and MATERIALIZE-CONFLICT-AT concern only the target's own name; tests show both. Depends: none. Claim: unassigned.
