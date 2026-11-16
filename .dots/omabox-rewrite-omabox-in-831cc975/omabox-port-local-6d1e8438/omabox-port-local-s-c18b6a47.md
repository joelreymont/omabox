---
title: "Port LOCAL's renames and root binding"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T02:32:58.645992+02:00"
closed-at: "2026-11-16T03:07:44.080890+02:00"
---

Problem: src/local.f lacks local.rs's rename_case_variant (:1035), rename_file_copy (:1044), parent_name_max (:1126), configured_root_is_active (:996), open_active_root (:1004) and scan_and_publish (:948), which the daemon reaches (reconcile.rs:744, :958, :1004-1024, :1453-1472, :1748); src/local-test.f's Dropped comment defers six tests to them. Acceptance: those words ported; case_variant_rename_preserves_tree_and_retries_races, case_variant_rename_preserves_a_swapped_source, scan_of_a_stand_in_publishes_nothing, unchanged_tree_beside_a_same_named_directory_republishes_nothing, switching_local_root_clears_the_hash_cache and slots_lease_through_a_symlinked_state_home pass under their names. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-local-renames and .jj-ws.noindex/omabox-local-binding.
