---
title: Rewrite omabox in Habu
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T11:54:52.679749+02:00"
---

Goal: a drop-in Habu replacement for the Rust daemon (same journal schema, credential record, CLI, status output and systemd unit), starting from the approved Dropbox vocabulary in docs/habu-dropbox.md; the rest of the plan comes from the design. Acceptance: the Habu build takes over the live state and passes the ported tests. Depends: none. Claim: unassigned.
