---
title: Default the setup sync root to ~/Dropbox
status: closed
priority: 2
issue-type: task
created-at: "2026-11-13T21:51:07.520403+02:00"
closed-at: "2026-11-13T21:51:07.520403+02:00"
---

Goal: the user settled that ~/Dropbox is the default sync root; flag-driven setup required --sync-root every time and the folder had to exist. Acceptance: `omabox setup --app-key KEY` syncs $HOME/Dropbox, creating it with mode 0700 when missing and only after refusing an already configured machine; an explicit --sync-root must still name an existing directory; help, README, and the plugin README describe the default. Depends: none. Claim: agent=lead workspace=main
