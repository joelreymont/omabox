---
title: Install the v0.1.0 package on this machine
status: active
priority: 2
issue-type: task
created-at: "2026-11-17T09:52:19.053405+02:00"
---

Problem: the Arch package (packaging/arch, v0.1.0) builds with makepkg, but no install has shown that installing it, then omabox setup and omabox service enable and start, give a running service and the widget; that an upgrade puts the running daemon on the new program with no user action; or that removal keeps configuration, credentials, journal and files. This machine still runs the hand-installed build (~/.config/systemd/user/omabox.service, which shadows the packaged unit, ~/.local/bin/omabox and omaboxd, and a copied widget folder). Acceptance: on this machine, with the hand-installed files removed and the v0.1.0 package installed, the service runs the packaged omaboxd and the widget is a link to the packaged one; a reinstall restarts the running daemon on the package's program; removal stops the service and leaves ~/.config/omabox, the keyring token, the journal and ~/Dropbox, and installing again resumes. Depends: none. Claim: agent=bob workspace=.jj-ws.noindex/omabox-lead.
