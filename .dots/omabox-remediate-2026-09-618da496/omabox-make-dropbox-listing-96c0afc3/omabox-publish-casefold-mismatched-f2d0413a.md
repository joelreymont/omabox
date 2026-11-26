---
title: "Keep a Dropbox entry that shares its fold apart"
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T08:12:23.578605+02:00"
---

Problem: a Dropbox entry whose path_lower part beneath the root is not its own fold (U+13A0, which Dropbox keeps and Habu lowercases) is published unsupported at its fold, which it shares with the entry whose path_lower part is that fold (src/reconcile.f APPEND-MISMATCHED). In one listing the later of the two replaces the other's record, and a delete of the own-fold entry removes the other's unsupported record. Acceptance: a key is held unsupported exactly while an entry whose path_lower part is not its own fold folds to it, whatever the listing and delete order, and deleting either entry leaves the other's effect in place (test). Depends: none. Claim: unassigned.
