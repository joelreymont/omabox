---
title: Restore the service when setup is interrupted
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:07:55.288362+02:00"
---

Problem: an interrupt (Ctrl-C, SIGTERM) between Release and Restore in setup or set-root, a window that now includes the Secret Service store, exits with the service stopped. Acceptance: an interrupt in that window still restores the service state observed before Release (test sending SIGINT to the CLI while released). Depends: none. Claim: unassigned.
