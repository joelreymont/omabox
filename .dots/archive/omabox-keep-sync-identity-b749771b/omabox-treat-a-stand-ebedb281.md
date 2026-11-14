---
title: Treat a stand-in root as unavailable in every check
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T16:42:36.026229+02:00"
closed-at: "2026-11-14T17:07:43.568973+02:00"
---

Problem: the rule that a directory without birth times at a recorded root's path is a stand-in lives only in daemon.rs root_inspection_failure; open_active_root and the scan's root_binding (local.rs) still turn NoBirthTime into a UserAction exit 78 mid-pass, and a schema-6 record cannot be told from a stand-in because NoBirthTime drops the inode. Acceptance: one predicate decides stand-ins for activation, open_active_root and scan publication; a stand-in gives an Environmental result in each; a test of each check fails without its use of the predicate, including a record for which the predicate is false, and each test name states what it checks. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-treat-a-stand-ebedb281
