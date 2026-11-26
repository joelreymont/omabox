---
title: Read the Dropbox credential from a systemd credential
status: closed
priority: 2
issue-type: task
created-at: "2026-11-26T14:59:01.497841+02:00"
closed-at: "2026-11-26T16:14:29.326619+02:00"
---

Problem: on a headless host (spark) the Secret Service's login keyring stays locked, so setup cannot store the Dropbox credential and the daemon cannot load it (src/auth.f BIND binds only secret-tool); Omabox cannot run unattended there, while the host's other services read TPM-sealed secrets as systemd credentials. Acceptance: omaboxd loads the credential record from $CREDENTIALS_DIRECTORY/dropbox-credentials-v1 when its unit passes a credentials directory, else from the Secret Service; omabox setup --credential-file PATH writes the record to a new owner-only file instead of the Secret Service (tests); the README says how to run headless. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-credential.
