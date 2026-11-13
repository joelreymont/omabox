---
title: Reject a malformed setup root before authorization
status: closed
priority: 2
issue-type: task
created-at: "2026-11-13T21:49:09.968597+02:00"
closed-at: "2026-11-13T21:49:09.968597+02:00"
---

Problem: src/bin/omabox.rs parse_setup accepted any UTF-8 Dropbox root, and only DropboxRoot::new in src/dropbox.rs rejected a malformed one, after setup had sent the user through browser authorization and exchanged the code; `omabox setup -h` took "-h" as the root. Acceptance: setup rejects a root that is neither empty nor a normalized absolute Dropbox path as a usage error before any authorization, through the same syntax DropboxRoot::new enforces; valid roots parse as before. Depends: none. Claim: agent=lead workspace=main
