---
title: "Port the installer: install, upgrade, uninstall"
status: open
priority: 2
issue-type: task
created-at: "2026-11-17T09:38:02.991183+02:00"
---

Problem: rust src/install.rs (3570 lines; execute :78, install :332, uninstall :409) has no Habu port, so omabox has no install, upgrade or uninstall and README's Install says there is no release build (README.md:18). Acceptance: omabox install, upgrade and uninstall behave as Rust's, its tests ported under their names, and README's Install and Upgrade sections describe the Habu release. Depends: Habu dots habu-swap-two-paths-316201ad and habu-publish-the-running-13cf5846 on Habu master. Claim: unassigned.
