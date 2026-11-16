---
title: "Check a content hash's form in one word"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T03:09:36.006467+02:00"
closed-at: "2026-11-16T03:11:46.612717+02:00"
---

Problem: the 64-lowercase-hex form of a Dropbox content hash is checked three times: DROPBOX's private HASH? (src/dropbox.f), JOURNAL's HEX-DIGIT? and DROPBOX-CONTENT-HASH? (src/journal.f:1038-1046) and LOCAL's HEX-LOWER? and VALID-CONTENT-HASH? (src/local.f:455-461). Acceptance: one public DROPBOX word, called by all three; tests pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-hash-form
