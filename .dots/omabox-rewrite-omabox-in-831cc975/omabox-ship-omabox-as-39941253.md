---
title: Ship Omabox as an Arch package
status: open
priority: 2
issue-type: task
created-at: "2026-11-17T09:52:19.053405+02:00"
---

Problem: the Habu build has no install path: README's Install and Upgrade sections (README.md:16-37, :79-91) describe Rust's omabox install, upgrade and uninstall (rust src/install.rs, 1150 lines and 2280 of tests), which is not ported. The user settled on 2026-11-17 an Arch package in its place: pacman installs, upgrades and removes /usr/bin/omabox, /usr/bin/omaboxd, /usr/lib/systemd/user/omabox.service and the widget under /usr/share/omabox, and omabox setup links ~/.config/omarchy/plugins/local.omabox to the widget, as superwhisper's package does. To settle in its design before dispatch: how the package gets Habu (built at a pinned commit, or prebuilt programs); how a running daemon moves to an upgraded program without user action; moving an install from ~/.local/bin. Acceptance: makepkg builds the package; installing it and running omabox setup gives a running service and the widget; an upgrade puts the running daemon on the new program with no user action; removal keeps configuration, credentials, journal and files; README describes install, upgrade and removal. Depends: none. Claim: unassigned.
