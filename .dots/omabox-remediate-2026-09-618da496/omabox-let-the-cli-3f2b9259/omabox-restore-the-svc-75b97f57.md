---
title: Restore the service when setup is interrupted
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:07:55.288362+02:00"
---

Problem: an interrupt (Ctrl-C, SIGTERM) between releasing and restoring the service in setup or set-root, a window that includes the Secret Service store, exits with the service stopped. Acceptance: an interrupt (SIGINT or SIGTERM) in that window still restores the service to the state observed before it was released (test sending SIGINT to the CLI while the service is released). Depends: none. Claim: unassigned.
