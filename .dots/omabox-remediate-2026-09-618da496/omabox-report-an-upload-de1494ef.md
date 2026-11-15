---
title: Report an upload content mismatch as itself
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T11:01:33.207910+02:00"
---

Problem: while a finish keeps answering ContentHashMismatch, the runtime status says last_error 'Dropbox is temporarily unavailable.', which names the wrong cause and hides which file fails. Acceptance: the status names the upload whose content Dropbox rejected, and the daemon's classification of UploadedContentMismatch matches docs/remediation-2026-09.md section J (test). Depends: omabox-find-why-a-db38ac1e. Claim: unassigned.
