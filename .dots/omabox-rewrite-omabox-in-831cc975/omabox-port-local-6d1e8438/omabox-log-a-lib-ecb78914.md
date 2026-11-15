---
title: Log a library-logged LOCAL failure once
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T00:28:49.297998+02:00"
---

Problem: Habu's XATTR words (and FS-STATX's) log a failure before they throw, as forth-card's rule says (the library that saw it logs once), and LOCAL's FS-FAILS/IO-FAILURE then log the same failure again with Rust's text (seen in the LOCAL stage lane's test output: an fsetxattr EEXIST logged by xattr and by local). Acceptance: a failure a Habu library already logged gets no second LOCAL line; LOCAL still throws its own code; FS's words, which log nothing, keep LOCAL's line. Depends: none. Claim: unassigned.
