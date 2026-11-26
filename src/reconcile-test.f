\ reconcile-test.f - RECONCILE's words, each case in a directory of its
\ own under TMPDIR, which it removes.
\ Known paths, Rust's tests of the same names:
\ - absent_paths_are_spelled_with_local_ancestor_casing
\ - local_case_variants_never_collapse_into_one_observation, over
\   sampled names written as local rows, deciding them logging the
\   collision once naming both spellings, then renamed alike in either
\   order, to a path neither spelling holds
\ - known_path_merge_matches_set_union, over sampled path sets written
\   as baselines and local and remote directories, which
\   JOURNAL:EACH-UNSETTLED-PATH visits but the paths all three hold,
\   which it counts settled
\ - DECIDING-SKIPS-ONLY-SETTLED-KEYS: one key for each combination of
\   baseline (none, file, directory), local (none, the baseline's file,
\   another, a directory, two spellings), remote (none, a file of equal
\   or other content and revision, a directory), live plan, conflict
\   and a remote directory beneath: JOURNAL:EACH-UNSETTLED-PATH visits
\   only held keys, not one only a conflict holds, which deciding finds
\   no spelling for; every held key it skips is a no-op deciding only
\   counts,
\   four are settled, and their count plus the visited keys' counted
\   no-ops is the count of deciding every held key.
\ - remaining_operation_comparison_ignores_a_completed_prefix
\ - pending_only_paths_are_visited_as_absent_without_creating_a_baseline,
\   deciding a journal that holds only the pending plan
\ - a_path_below_an_unknown_directory_inherits_its_reason
\ - a_record_below_an_unknown_directory_cannot_restore_absence
\ - names_that_neighbor_the_separator_are_not_ancestors
\ - an_unknown_ancestor_blocks_a_deletion_on_either_side
\ - baseline_only_paths_are_included_in_confirmed_absence
\ - ORDER-PATH-DECISIONS puts an upload at depth 3 first, then local
\   directory deletes at depths 2 and 1, deepest first.
\ - AN-EXCLUDED-ANCESTOR-LENDS-NO-REASON-OR-SPELLING: an unknown local
\   record at Cache.dropbox leaves cache.dropbox/x absent and spelled
\   as the candidate, where one at Locked lends both.
\ - A-WALK-COUNTS-EVERY-KEPT-BASELINE: Docs, Docs/Notes and Music, each
\   a directory on both sides and in the baseline: the walk keeps no
\   key, and deciding files no decision and no no-op record and counts
\   three no-ops.
\ - DECIDING-KEEPS-THE-RUN-RULE, Rust's
\   local_map_keeps_one_unsupported_spelling: unsupported link and Link
\   decide Link alone.
\ Case collisions:
\ - Rust's case_variant_name_skips_existing_suffixes,
\   case_variant_name_fits_a_maximum_length_component,
\   file_copy_name_is_deterministic_and_fits_the_parent_limit,
\   case_variant_moves_converge_from_parent_to_child,
\   case_variant_source_keeps_the_recorded_spelling,
\   case_variant_source_leaves_unsupported_spellings and
\   case_variant_source_skips_an_unsupported_collision.
\ - RESOLVE-CASE-COLLISION below a bound root holding Dir/a.txt and
\   dir/b.txt, as its journal's local inventory does, renames dir, the
\   spelling CASE-VARIANT-SOURCE picks, to its case-variant name and
\   retires the plans at both spellings, which share its identity,
\   leaving one at another path pending.
\ - With the root replaced by another directory it answers
\   root-changed, renaming nothing and retiring no plan.
\ Listing changes, Rust's tests of the same names:
\ - folders_are_directories_and_non_downloadable_files_are_unknown
\ - directory_records_normalize_inconsistent_child_ancestor_casing
\ - delta_never_respells_a_directory_that_still_exists
\ - listing_classifies_the_remote_roots_own_entry, each refusal's one
\   line logged
\ - LISTING-KEEPS-MISMATCHED-PATHS-UNSUPPORTED: a file and a folder
\   whose display path does not lowercase to the lower one are
\   unsupported at the lower path, their ancestors respelled, each handed
\   on once with its key; a deleted one deletes there, handed on to
\   none.
\ - MISMATCHED-RESTRICTED-FOLDER-DROPS-ITS-CHILDREN: a restricted folder
\   whose display path folds elsewhere is unsupported and its listed
\   children go.
\ - TWO-SPELLINGS-SHARE-ONE-KEY: /U+13A0.txt, uppercase in Habu's tables,
\   as both its paths, then /U+AB70.txt, its lowercase: the first is
\   handed on with the key U+AB70.txt, which the second's record holds;
\   a delete of the first keeps the key's record, unsupported, and a
\   delete of the second removes its own.
\ - LISTING-REJECTS-AN-INVALID-CONFIGURED-ROOT: a/b, /a/, /a//b and a
\   root that is not UTF-8 each throw E-LISTING, one line logged.
\ - LISTING-REJECTS-AN-ENTRY-WITHOUT-PATHS and
\   LISTING-REJECTS-A-PATH-THAT-IS-NOT-UTF-8, an 0xFF byte: E-LISTING,
\   one line logged, naming no path for the first.
\ - LISTING-REJECTS-AN-INVALID-OR-OUT-OF-ROOT-ENTRY: /a//b.txt, and
\   /other/x below the root /Sync: E-LISTING, one line logged.
\ The listing against the fake Dropbox, Rust's tests of the same names,
\ the fake's requests standing for Rust's refresh result:
\ - cursor_reset_rebuilds_before_one_complete_publication
\ - failed_rebuild_after_cursor_reset_preserves_durable_inventory
\ - listing_applies_ordered_tree_mutations_across_pages
\ - failed_later_page_cannot_publish_partial_listing_as_absence
\ - one_file_cursor_delta_updates_a_large_inventory_without_a_full_listing,
\   over 10 000 records
\ - large_full_listing_builds_its_inventory_in_linear_time: 20 000
\   entries in pages of 2 000 within 5 s, the time printed
\ - incomplete_downloadable_metadata_publishes_as_unknown_incomplete
\ - restricted_later_page_publishes_as_unknown_inaccessible
\ - MISMATCHED-ENTRY-PUBLISHES-AS-UNSUPPORTED: a full listing of a good
\   file and one whose display path does not lowercase to its lower
\   path, then a delta listing the second again: the good one is
\   present, the other unsupported at its lower path, and one line
\   logged names it.
\ - UNLOWERED-PATH-PUBLISHES-AT-ITS-FOLD: two deltas each list /U+13A0.txt,
\   uppercase in Habu's tables, as both its display and lower path; each
\   publishes it unsupported at the key U+AB70.txt, and one line logged
\   names it.
\ - MISMATCH-LOGGED-ONCE-AFTER-A-FAILED-PAGE: a delta whose later page
\   fails lists a mismatched file, then the next delta lists it and
\   publishes: it is unsupported, and one line logged names it.
\ - EXTRA-COMPONENT-PUBLISHES-AS-UNSUPPORTED: a full listing of a good
\   file and one whose display path has a component more than its lower
\   path: the good one is present, the other unsupported at its lower
\   path, and one line logged names it.
\ - UNLOWERED-ROOT-LISTS-ITS-ENTRIES: a full listing of the root
\   /U+13A0, its lower path unlowered as well, with its own entry, a
\   file and a folder: both are published beneath it.
\ The replay step against the fake Dropbox, Rust's tests of the same
\ names, one REPLAY-STEP standing for one drive_replay:
\ - worker_verification_mismatch_durably_blocks_its_plan
\ - worker_auth_rate_limit_and_server_failures_remain_global, its 401,
\   429 and 500 answers, the code thrown and the reply kept in the link
\   standing for the SDK error; the 401 on a client of its own, which
\   refreshes and sends again once before it answers unlinked
\ - occupied_download_stage_is_durably_blocked_without_overwrite_or_request
\ - completed_download_batch_is_installed_before_the_next_batch_fails
\ - unknown_download_slots_are_preserved_with_disposable_fallback
\ - root_swap_after_replay_validation_never_touches_the_replacement, the
\   fake swapping the root on its task as the download arrives
\ - later_planned_download_does_not_reclaim_an_active_slot, plan a held
\   blocked an hour where Rust holds its download, its slot holding a
\   checkpoint that a second step resumes once a is unblocked
\ - legacy_preservation_before_a_download_replays_once, Omabox's own: a
\   legacy [preserve-local, install-local] plan whose install waits on
\   its download counts its preservation once
\ - retry_error_stays_when_no_install_completes, Omabox's own: a
\   download whose destination is written as it arrives completes
\   nothing, so the retry's error stays in status.json
\ The pass against the fake Dropbox, Rust's test of the same name:
\ - one_reconciliation_pass_synchronizes_files_in_both_directions, with
\   replayed 2 and blocked 0 as its download installs in the pass, no
\   account request, and the upload's argument as DROPBOX writes it
\ Stale installs against the fake Dropbox, Rust's tests of the same
\ names, with no account request and the fake's upload taking rev 01701
\ where Rust scripts one:
\ - matching_observations_retire_a_stale_install_and_later_edits_sync
\ - a_changed_safe_operation_replaces_a_stale_install_in_the_same_pass,
\   the upload's argument, whose hash the fake checks, for its body
\ - an_unknown_observation_does_not_retire_a_stale_install
\ - a_pending_only_path_retires_without_fetching_obsolete_bytes
\ Then that the pass retires the verified stage of a superseded download
\ plan, of one that ended before it and of an ended replace-local plan,
\ forgetting each plan; keeps a stage a blocked plan for the same path
\ and content holds, but not one for other content; and keeps a plan
\ whose stage's directory refuses the removal, one line logged for its
\ path in each of two passes, while other.txt downloads:
\ - a_superseded_download_plan_retires_its_verified_stage
\ - an_ended_download_plan_retires_its_verified_stage
\ - an_ended_replace_plan_retires_its_verified_stage
\ - a_live_plan_keeps_the_stage_of_its_path_and_content
\ - a_live_plan_for_other_content_does_not_keep_the_stage
\ - a_failed_retirement_keeps_its_plan_while_the_pass_goes_on
\ Download blocks against the fake Dropbox, Rust's tests of the same
\ names, each download installing in the pass and no account request:
\ - unavailable_download_blocks_only_its_plan_while_siblings_finish
\ - rejected_download_request_blocks_only_its_plan_while_siblings_finish
\ - unmapped_download_status_blocks_only_its_plan_while_siblings_finish
\ - due_unchanged_download_retries_after_fresh_observation
\ - due_download_stays_blocked_when_the_fresh_local_path_is_unknown
\ - changed_revision_supersedes_blocked_plan_before_or_after_deadline
\ - blocked_plan_is_retired_when_both_sides_are_absent
\ Uploads against the fake Dropbox, Rust's tests of the same names, with
\ no account request and the revs the fake's uploads take, 0170<n>, for
\ the ones Rust scripts:
\ - corrupt_upload_stage_is_rebuilt_and_uploaded
\ - corrupt_upload_stage_recovers_from_durable_block_after_reopen
\ - special_upload_stage_blocks_only_its_plan
\ - changed_upload_supersedes_a_rejected_plan_before_deadline
\ - unknown_local_state_keeps_a_rejected_upload_blocked
\ - stale_upload_is_superseded_and_current_bytes_sync
\ Conflicts against the fake Dropbox, Rust's tests of the same names,
\ d-unrelated.txt's rev the one the fake's upload answers:
\ - replay_blocks_a_conflict_whose_local_copy_name_is_occupied
\ - replay_blocks_a_conflict_whose_local_copy_name_is_unreadable,
\   skipped as root, who opens any file
\ - recorded_conflict_leaves_an_edited_copy_alone
\ - occupied_dropbox_conflict_copy_name_blocks_only_its_path
\ - conflict_on_a_plan_blocked_for_its_size_is_prepared_at_once
\ - directory_at_dropbox_conflict_copy_name_blocks_only_its_path
\ Conflicts against the fake Dropbox that Rust has no test for:
\ - A-CONFLICTED-DOWNLOAD-REUSES-ITS-STAGE: a staged download plan whose
\   install finds new local bytes ends as their conflict, its stage
\   becomes the remote copy, read-only and unmarked, with no download.
\ - NEW-CONFLICT-WAITS-OUT-ITS-TAKEN-COPY-NAME: a new divergent
\   conflict whose local copy name an unreadable file holds records one
\   block, why and a retry time an hour after its pass; the next pass,
\   the name free and the edit's hash kept, reads and writes
\   less than the 1 MiB local edit, as /proc/self/io counts, places
\   nothing and keeps the block; once it is due, both copies are placed
\   and recorded and the block goes. Root skips it.
\ - A-PATH-NO-LONGER-CONFLICTING-LOSES-ITS-BLOCK: its local edit made
\   Dropbox's, the path's block goes, the occupant kept. Root skips it.
\ - A-PATH-HELD-OTHERWISE-LOSES-ITS-BLOCK: a blocked path made unknown,
\   a dangling symlink, is held and its block goes. Root skips it.
\ - A-REFUSED-NEW-CONFLICT-WRITES-NO-BLOCK: a new divergent conflict
\   whose Dropbox copy's download answers 409 is held with no block and
\   no copies recorded; the next pass, the download served, places both.
\ Restricted and same-named entries against the fake Dropbox, Rust's
\ tests of the same names, with no account request and the fake's own
\ delete_v2 and upload answers, its upload at rev 01701:
\ - inaccessible_folder_deletes_nothing_beneath_it
\ - newly_restricted_folder_drops_stale_child_records
\ - restricted_folder_spells_its_listed_children
\ - file_beside_a_same_named_directory_still_deletes_on_dropbox
\ - file_beside_a_same_named_directory_still_deletes_locally
\ - file_beside_a_same_named_directory_still_uploads_a_local_edit
\ - inaccessible_directory_never_deletes_its_dropbox_contents
\ Edits and directories against the fake Dropbox, Rust's tests of the
\ same names, each download installed in its pass and no account
\ request:
\ - later_edits_sync_and_divergence_preserves_both_sides, the upload
\   taking the fake's rev
\ - later_deletions_sync_in_both_directions
\ - one_reconciliation_pass_synchronizes_empty_and_nested_directories,
\   create_folder_v2 answered as Rust scripts it
\ - fresh_download_uses_parent_directory_casing_without_remote_writes
\ - delta_folder_with_miscased_parents_is_created_inside_the_local_tree
\ Case collisions against the fake Dropbox, Rust's tests of the same
\ names, the fake's requests standing for Rust's finish, with no account
\ request, and fresh for FreshObservationRequired, which names a path:
\ - case_only_remote_spelling_change_is_a_stable_noop
\ - local_case_collision_is_renamed_before_planning_and_then_syncs, its
\   journal closed and opened again between the passes
\ - automatic_case_rename_never_becomes_a_dropbox_delete and
\   case_collision_keeps_the_baselined_spelling_and_its_history, each
\   download installed in the pass that plans it
\ - local_case_collision_preserves_both_directory_trees
\ - case_collision_spares_the_recorded_greater_spelling
\ - case_collision_beside_a_symlink_renames_the_baselined_file
\ - case_collision_of_symlinks_stays_in_place
\ Directory collisions in the pass against the fake Dropbox, Rust's
\ tests of the same names, with no account request and a fresh
\ observation naming no path:
\ - remote_directory_preserves_a_local_file_under_a_synchronized_name
\ - local_directory_preserves_a_dropbox_file_under_a_synchronized_name
\ - directory_collision_copy_stays_bound_to_the_verified_root, the
\   fake swapping the root on its task as the download arrives
\ - directory_collision_destination_race_requests_a_fresh_scan, the
\   fake writing the copy's destination as the download arrives
\ - occupied_collision_stage_uses_the_next_synchronized_name
\ - changed_dropbox_file_during_directory_conversion_replans_without_a_conflict_row
\ - A-REFUSED-COLLISION-COPY-HOLDS-ITS-PATH and
\   AN-UNVERIFIED-COLLISION-COPY-HOLDS-ITS-PATH: the copy's download
\   refused 409 or its bytes failing the listing's hash hold the local
\   directory for the pass, untouched, unplanned and with no copy, its one
\   line logged, while other.txt syncs in the same pass.
\ - A-HELD-COLLISION-HOLDS-THE-PATHS-BENEATH-IT: the refused copy also
\   holds the local file node/inner.txt, unplanned and unstaged.
\ - A-REFUSED-CONFLICT-COPY-PREVENTS-REST: a new divergent conflict whose
\   Dropbox copy's download is refused 409 records no conflict, and the
\   pass does not rest.
\ Directory deletions against the fake Dropbox, Rust's tests of the same
\ names, with no account request:
\ - remote_directory_deletion_removes_local_directories_deepest_first
\ - local_directory_deletion_removes_dropbox_directories_after_their_entries,
\   the listing and probe pages in one queue in the order Rust's requests
\   take them
\ - local_directory_deletion_waits_for_unsynchronized_dropbox_entries
\ - dropbox_directory_that_gained_an_entry_is_not_deleted_from_a_stale_inventory
\ - child_created_after_scan_forces_an_immediate_directory_rescan, the
\   fake's listing hook writing the child where Rust's gate does
\ - nonempty_directory_delete_reobserves_and_syncs_the_new_child
\ The root and exclusions against the fake Dropbox, Rust's tests of the
\ same names:
\ - replaced_local_root_never_replays_pending_deletion
\ - NEW-CONFLICT-ANSWERS-A-REPLACED-ROOT: NEW-CONFLICT, the root replaced
\   after its file is written, answers root-changed, recording no conflict
\   and copying nothing into the replacement.
\ - ROOT-SWAP-DURING-PLANNING-STAGES-NOTHING-FROM-THE-STAND-IN: a pass
\   whose root is swapped while a conflict's Dropbox copy downloads
\   records the conflict, then ends root-changed at the next path's
\   upload, the stand-in as the swap left it and nothing staged from it.
\ - rejected_paths_do_not_stop_unrelated_sync_or_report_progress, with
\   replayed 2 as its download installs in the pass, and no account
\   request
\ - documented_exclusions_preserve_payloads_while_ordinary_siblings_sync,
\   with no account request
\ - excluded_pending_and_blocked_work_is_retired_across_reopen_without_effects
\ - A-VERIFIED-DOWNLOAD-STAGE-IS-NO-BLOCKED-PATH: a pass beside a synced
\   file holds Omabox's verified download stage, yet reports blocked 0,
\   uploads nothing and keeps the stage.
\ The tables against their models, through TEST-FORMAL:HOLDS:
\ - formal_holds_the_listing_table, INVENTORY-PUBLICATION and
\   formal/InventoryPublication.tla
\ - formal_holds_the_download_table, DOWNLOAD-EXECUTOR and
\   formal/DownloadExecutor.tla
\ - formal_holds_the_pass_table, SYNC-PASS and formal/SyncPass.tla
\ - formal_holds_the_placement_table, CONFLICT-PLACEMENT and
\   formal/ConflictPlacement.tla
\ Run from the repository root: hb --load src/reconcile-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test/assert.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/lib/vector.f
require src/lib/adt/option.f
require src/lib/fs-anchored.f
require src/lib/fs-list.f
require src/lib/span.f
require src/lib/xattr.f
require src/lib/aio.f
require src/lib/time.f
require src/lib/task.f
require src/lib/json/pointer.f
require src/lib/json/equal.f
require src/test-formal.f
require src/dropbox.f
require src/test-dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f
require src/local.f
require src/planner.f
require src/status.f
require src/replay.f
require src/reconcile.f
require src/attention.f
require src/test-client.f

\ RECONCILE reopened for the private words the tests call.
package RECONCILE
private

\ ---- known paths: helpers -----------------------------------------

\ A case's directory, made under TMPDIR, and its journal.
: CASE-JOURNAL ( ^ARENA:arena -- str JOURNAL:journal )
   {: ar :}
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   SB-RESET d SB-APPEND s" /journal.sqlite3" SB-APPEND
   d SB$ ar ARENA:COPY JOURNAL:OPEN ;

: GONE ( str JOURNAL:journal -- )
   JOURNAL:CLOSE FS:REMOVE-TREE ;

: ACTIVATED-BINDING
   ( JOURNAL:local-root-activation -- JOURNAL:local-root-binding )
   MATCH JOURNAL:local-root-activation
      activated OF JOURNAL-LOCAL--ROOT--RECORD:UNMAKE drop ENDOF
      current OF JOURNAL-LOCAL--ROOT--RECORD:UNMAKE drop ENDOF
      unavailable OF
         drop drop s" reconcile-test: the root is unavailable" TEST-CLIENT:FAILED
      ENDOF
   ;MATCH ;

\ The directory at r made the journal's root, and the binding its
\ activation answers.
: ROOTED
   ( JOURNAL:journal str ^ARENA:arena -- JOURNAL:local-root-binding )
   {: j r:str ar :}
   j r JOURNAL:INSPECT ar JOURNAL:ACTIVATE-LOCAL-ROOT
   ACTIVATED-BINDING ;

\ The records made the journal's local inventory, with no hashes.
: LOCALS-PUBLISHED
   ( JOURNAL:journal JOURNAL:local-root-binding
     ^VEC:vector<MODEL:local-record> ^ARENA:arena -- )
   {: j b v ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:hash-record VEC:NEW {: none :}
   j b v none JOURNAL:PUBLISH-LOCAL-SCAN TTRUE ;

\ The body runs on a case's directory and its journal, rooted at the
\ directory, which is removed after.
: WITH-ROOTED
   ( [ str JOURNAL:journal JOURNAL:local-root-binding -- ] ^ARENA:arena
     -- )
   {: body ar :}
   ar CASE-JOURNAL {: d:str j :}
   [: d j j d ar ROOTED body execute ;] [: d j GONE ;] finally ;

\ Rust's CanonicalPath::from_display of the bytes.
: CANONICAL ( str ^ARENA:arena -- MODEL:key )
   {: p:str ar :}
   p TEST-CLIENT:DISPLAY ar MODEL:FOLD ;

\ Rust's identity: dropbox_content_hash of the bytes, from a pipe.
: IDENTITY ( str ^ARENA:arena -- DROPBOX:hash )
   {: b:str ar :}
   FD:PIPE {: r:fd w:fd :}
   w b FD:WRITE-FULL w FS:CLOSE-DIR
   r ar LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR ;

: REMOTE-FILE ( str str ^ARENA:arena -- MODEL:remote )
   {: b:str r:str ar :}
   b ar IDENTITY r DROPBOX:>REV MODEL-REMOTE:MAKE ;

: LOCAL-RECORDS ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   ARENA:ALLOCATOR 0 [type] MODEL:local-record VEC:NEW ;

: REMOTE-RECORDS ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW ;

: LOCAL-DIRECTORY ( -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:DIRECTORY ;

: REMOTE-DIRECTORY ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:DIRECTORY ;

: LOCAL-PRESENT ( MODEL:local -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:PRESENT ;

: REMOTE-PRESENT ( MODEL:remote -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:PRESENT ;

: LOCAL-UNKNOWN ( MODEL:unknown-reason -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:UNKNOWN ;

: REMOTE-UNKNOWN
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:UNKNOWN ;

: LOCAL-ABSENT ( -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:ABSENT ;

: REMOTE-ABSENT ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:ABSENT ;

: LOCAL+
   ( ^VEC:vector<MODEL:local-record> str
     MODEL:observation<MODEL:local> -- )
   {: v p:str o :}
   p TEST-CLIENT:DISPLAY o MODEL-LOCAL--RECORD:MAKE v VEC:PUSH ! ;

\ Rust's local_records: a directory at the path.
: DIRECTORY+ ( ^VEC:vector<MODEL:local-record> str -- )
   LOCAL-DIRECTORY LOCAL+ ;

\ Rust's unsupported_records: unknown unsupported at the path.
: UNSUPPORTED+ ( ^VEC:vector<MODEL:local-record> str -- )
   MODEL-UNKNOWN--REASON:UNSUPPORTED LOCAL-UNKNOWN LOCAL+ ;

\ Rust's present_locally.
: PRESENT+
   ( ^VEC:vector<MODEL:local-record> str str ^ARENA:arena -- )
   {: v p:str b:str ar :}
   v p b ar IDENTITY MODEL-LOCAL:MAKE LOCAL-PRESENT
   LOCAL+ ;

\ Rust's remote_side for one record.
: REMOTE+
   ( ^VEC:vector<MODEL:remote-record> str
     MODEL:observation<MODEL:remote> ^ARENA:arena -- )
   {: v p:str o ar :}
   p ar CANONICAL p TEST-CLIENT:DISPLAY o MODEL-REMOTE--RECORD:MAKE
   v VEC:PUSH ! ;

\ The records published as the journal's local inventory and its remote
\ one, then the body run on it.
: SIDES-IN
   ( str JOURNAL:journal JOURNAL:local-root-binding
     ^VEC:vector<MODEL:local-record> ^VEC:vector<MODEL:remote-record>
     [ JOURNAL:journal -- ] ^ARENA:arena -- )
   {: d:str j b ls rs body ar :}
   j b ls ar LOCALS-PUBLISHED
   j s" cursor" DROPBOX:>CURSOR rs JOURNAL:PUBLISH-REMOTE-INVENTORY
   j body execute ;

\ The body runs on a rooted case journal holding the records as its
\ local inventory and its remote one, which is removed after.
: WITH-SIDES
   ( ^VEC:vector<MODEL:local-record> ^VEC:vector<MODEL:remote-record>
     [ JOURNAL:journal -- ] ^ARENA:arena -- )
   {: ls rs body ar :}
   [: ls rs body ar SIDES-IN ;] ar WITH-ROOTED ;

\ A planning over the journal, in a run that holds only it, a blind
\ watch and ar.
: PLANNING-OVER ( JOURNAL:journal ^ARENA:arena -- ^planning )
   {: j ar :}
   ar RUNS-NEW {: x :}
   j x RUN-JOURNAL ! ar LOCAL:NEW-WATCH x RUN-WATCH ! ar x RUN-ARENA !
   x NEW-PLANNING ;

\ The planning over the journal once the records are its local
\ inventory.
: LOCALS-PLANNING
   ( JOURNAL:journal JOURNAL:local-root-binding
     ^VEC:vector<MODEL:local-record> ^ARENA:arena -- ^planning )
   {: j b ls ar :}
   j b ls ar LOCALS-PUBLISHED
   j ar PLANNING-OVER ;

\ The local observation the journal holds at the path, else unobserved.
: LOCAL-AT
   ( JOURNAL:journal MODEL:key ^ARENA:arena
     -- MODEL:observation<MODEL:local> )
   {: j k ar :}
   j k ar JOURNAL:LOCAL-AT
   MATCH option
      none OF j k ar LOCAL-UNOBSERVED ENDOF
      some OF MODEL-LOCAL--RECORD:UNMAKE {: p o :} o ENDOF
   ;MATCH ;

: REMOTE-AT
   ( JOURNAL:journal MODEL:key ^ARENA:arena
     -- MODEL:observation<MODEL:remote> )
   {: j k ar :}
   j k ar JOURNAL:REMOTE-AT
   MATCH option
      none OF j k ar REMOTE-UNOBSERVED ENDOF
      some OF REMOTE-OBSERVATION ENDOF
   ;MATCH ;

: LOCAL-UNOBSERVED= ( JOURNAL:journal str
     MODEL:observation<MODEL:local> ^ARENA:arena -- )
   {: j p:str want ar :}
   j p ar CANONICAL ar LOCAL-UNOBSERVED want MODEL:LOCAL-OBSERVATION=
   TTRUE ;

: REMOTE-UNOBSERVED= ( JOURNAL:journal str
     MODEL:observation<MODEL:remote> ^ARENA:arena -- )
   {: j p:str want ar :}
   j p ar CANONICAL ar REMOTE-UNOBSERVED want
   MODEL:REMOTE-OBSERVATION= TTRUE ;

\ A plan of the one operation, or of two.
: OPERATIONS ( ^ARENA:arena -- ^VEC:vector<MODEL:operation> )
   ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW ;

: TWO-PLAN
   ( MODEL:operation MODEL:operation ^ARENA:arena
     -- JOURNAL:operation-plan )
   {: o o2 ar :}
   ar OPERATIONS {: ops :}
   o ops VEC:PUSH ! o2 ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

: RECORDED ( JOURNAL:plan-write -- JOURNAL:plan-record )
   MATCH JOURNAL:plan-write
      recorded OF true TTRUE ENDOF
      already-live OF false TTRUE ENDOF
   ;MATCH ;

: OPERATION-COMPLETED? ( JOURNAL:operation-completion -- bool )
   MATCH JOURNAL:operation-completion
      not-found OF false ENDOF
      already-completed OF false ENDOF
      waiting-for-earlier-operation OF drop false ENDOF
      baseline-required OF false ENDOF
      unexpected-baseline OF false ENDOF
      baseline-mismatch OF false ENDOF
      operation-completed OF true ENDOF
      plan-completed OF false ENDOF
   ;MATCH ;

: NOOP-RECORDED? ( JOURNAL:noop-write -- bool )
   MATCH JOURNAL:noop-write
      recorded OF true ENDOF
      live-plan OF drop false ENDOF
   ;MATCH ;

\ A no-op decision's baseline; any other decision fails the case.
: NOOP-BASELINE ( MODEL:decision -- MODEL:baseline )
   MATCH MODEL:decision
      noop OF ENDOF
      operate OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
      blocked OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
      conflicted OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
      collided OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
   ;MATCH ;

: NOOP? ( MODEL:decision -- bool )
   MATCH MODEL:decision
      noop OF drop true ENDOF
      operate OF drop false ENDOF
      blocked OF drop false ENDOF
      conflicted OF drop false ENDOF
      collided OF drop false ENDOF
   ;MATCH ;

: BASELINE-SOME? ( option<JOURNAL:path-baseline> -- bool )
   MATCH option none OF false ENDOF some OF drop true ENDOF ;MATCH ;

: LOCAL-SOME? ( option<MODEL:local-record> -- bool )
   MATCH option none OF false ENDOF some OF drop true ENDOF ;MATCH ;

: REMOTE-SOME? ( option<MODEL:remote-record> -- bool )
   MATCH option none OF false ENDOF some OF drop true ENDOF ;MATCH ;

: STORED-SOME? ( option<MODEL:baseline> -- bool )
   MATCH option none OF false ENDOF some OF drop true ENDOF ;MATCH ;

\ ---- known paths: sampled inputs -----------------------------------

variable SEED

\ A sample below n from a fixed linear congruential sequence.
: RANDOM ( n -- n )
   SEED @ 6364136223846793005 * 1442695040888963407 + dup SEED !
   33 rshift swap mod ;

\ n random bytes of the alphabet, in the arena.
: SAMPLE ( str n ^ARENA:arena -- str )
   {: s:str k:n ar :}
   s str> {: a:^ au:n :}
   ar k ARENA:ALLOC drop {: dst:^ :}
   k 0 ?do a au RANDOM + c@ dst i + c! loop
   dst k >str ;

\ ---- known paths: cases ---------------------------------------------

: RESPELLED
   ( JOURNAL:journal str str ^ARENA:arena -- str )
   {: j p:str q:str ar :}
   j p ar CANONICAL q TEST-CLIENT:DISPLAY ar SPELL-WITH-LOCAL-ANCESTORS PATH$ ;

: RESPELLINGS ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   j s" apps/day one/journal" s" apps/day one/Journal" ar RESPELLED
   s" Apps/Day One/Journal" T$=
   j s" apps/day one/journal/entries" s" APPS/Day one/journal/Entries"
   ar RESPELLED s" Apps/Day One/journal/Entries" T$=
   j s" docs/report.txt" s" Docs/Report.txt" ar RESPELLED
   s" Docs/Report.txt" T$=
   j s" notes" s" NOTES" ar RESPELLED s" NOTES" T$= ;

: ABSENT-PATHS-ARE-SPELLED-WITH-LOCAL-ANCESTOR-CASING ( ^ARENA:arena -- )
   {: ar :}
   s" absent_paths_are_spelled_with_local_ancestor_casing" T-LABEL
   ar LOCAL-RECORDS {: rs :}
   rs s" Apps" DIRECTORY+
   rs s" Apps/Day One" DIRECTORY+
   rs s" Notes" DIRECTORY+
   rs ar REMOTE-RECORDS [: ar RESPELLINGS ;] ar WITH-SIDES ;

\ The text a pass logs for a collision of the two spellings.
: COLLISION$ ( str str -- str )
   {: a:str b:str :}
   SB-RESET s" local paths `" SB-APPEND a SB-APPEND
   s" ` and `" SB-APPEND b SB-APPEND
   s" ` have the same Dropbox path identity" SB-APPEND SB$ ;

\ What q writes to fd 2, captured in the case's directory d, in the
\ arena.
: LOGGED ( str [ -- ] ^ARENA:arena -- str )
   {: d:str q ar :}
   SB-RESET d SB-APPEND s" /stderr.txt" SB-APPEND
   q SB$ ar ARENA:COPY ar STDERR:CAPTURING {: code:n t:str :}
   code 0<> if code throw then
   t ;

: NO-SPELLING ( MODEL:key -- option<MODEL:path> ) drop NO-PATH ;

\ Rust's case_variant_move, max 255, of case_variant_source's unbased pick,
\ the records published first; a collision with no source fails the case.
: RENAME
   ( JOURNAL:journal JOURNAL:local-root-binding
     ^VEC:vector<MODEL:local-record> ^ARENA:arena -- case-variant-move )
   {: j b rs ar :}
   rs [: NO-SPELLING ;] ar CASE-VARIANT-SOURCE MATCH option
      none OF
         false TTRUE s" " TEST-CLIENT:DISPLAY dup CASE-VARIANT-MOVE-MAKE
      ENDOF
      some OF {: src :}
         j b rs ar LOCALS-PUBLISHED
         j src 255 ar CASE-VARIANT-MOVE
      ENDOF
   ;MATCH ;

: MOVES= ( case-variant-move case-variant-move -- )
   CASE-VARIANT-MOVE-UNMAKE {: s2 d2 :}
   CASE-VARIANT-MOVE-UNMAKE {: s1 d1 :}
   s1 PATH$ s2 PATH$ T$=
   d1 PATH$ d2 PATH$ T$= ;

\ Neither spelling's identity is the destination's.
: UNIQUE ( case-variant-move str str ^ARENA:arena -- )
   {: mv a:str b:str ar :}
   mv CASE-VARIANT-MOVE-UNMAKE {: s d :}
   d ar MODEL:FOLD {: k :}
   k a ar CANONICAL MODEL:KEY= TFALSE
   k b ar CANONICAL MODEL:KEY= TFALSE ;

\ The records in reverse order rename alike, to a unique path.
: RENAMES-AGREE
   ( JOURNAL:journal JOURNAL:local-root-binding
     ^VEC:vector<MODEL:local-record> str str ^ARENA:arena -- )
   {: j b rs lower:str upper:str ar :}
   ar LOCAL-RECORDS {: sr :}
   sr upper DIRECTORY+ sr lower DIRECTORY+
   j b rs ar RENAME {: fwd :}
   fwd j b sr ar RENAME MOVES=
   fwd lower upper ar UNIQUE ;

\ One sample of the proptest: a lowercase name and its uppercase.
: CASE-VARIANTS
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   s" abcdefghijklmnopqrstuvwxyz" 24 RANDOM 1+ ar SAMPLE {: stem:str :}
   SB-RESET stem SB-APPEND s" .txt" SB-APPEND
   SB$ ar ARENA:COPY {: lower:str :}
   lower ar ARENA:COPY {: upper:str :}
   upper str> 0 ?do dup i + c@ STR:ASCII-UPPER over i + c! loop drop
   ar LOCAL-RECORDS {: rs :}
   rs lower DIRECTORY+ rs upper DIRECTORY+
   j b rs ar LOCALS-PLANNING {: pl :}
   d [: [: pl DECIDE-ALL ;] E-CASE-COLLISION TTHROWSQ ;] ar
   LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t upper lower COLLISION$ STR:CONTAINS? TTRUE
   j b rs lower upper ar RENAMES-AGREE ;

: SAMPLED-VARIANTS
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   1 SEED !
   16 0 ?do d j b ar CASE-VARIANTS loop ;

: LOCAL-CASE-VARIANTS-NEVER-COLLAPSE-INTO-ONE-OBSERVATION
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_case_variants_never_collapse_into_one_observation" T-LABEL
   [: ar SAMPLED-VARIANTS ;] ar WITH-ROOTED ;

\ For MERGE-PATH: the piece from at, kept unless empty, "." or "..";
\ the index after it, or -1 past the last.
: MERGE-PIECE ( str n ^VEC:vector<str> -- n )
   {: p:str at:n kept :}
   p SEPARATOR at STR:SPLIT-NEXT 0= if 2drop -1 exit then
   {: q:str next:n :}
   q NAME? q s" .." STR:= 0= and if q kept VEC:PUSH ! then
   next ;

\ Rust's merge_path: the pieces between separators but empty, "."
\ and "..", joined.
: MERGE-PATH ( str ^ARENA:arena -- option<str> )
   {: raw:str ar :}
   ar ARENA:ALLOCATOR 0 [type] str VEC:NEW {: kept :}
   0 begin raw swap kept MERGE-PIECE dup 0< until drop
   kept VEC:COUNT 0= if OPTION:NONE exit then
   kept ar JOINED OPTION:SOME ;

: HOLDS? ( ^VEC:vector<str> str -- bool )
   {: v p:str :}
   false v VEC:COUNT 0 ?do v i VEC:AT @ p STR:= or loop ;

\ Rust's merge_paths over up to 23 sampled names, without repeats.
: MERGE-PATHS ( ^ARENA:arena -- ^VEC:vector<str> )
   {: ar :}
   ar ARENA:ALLOCATOR 0 [type] str VEC:NEW {: v :}
   24 RANDOM 0 ?do
      s" abcdefghijklmnopqrstuvwxyz./ -" 12 RANDOM 1+ ar SAMPLE
      ar MERGE-PATH
      MATCH option
         none OF ENDOF
         some OF dup v swap HOLDS? if drop else v VEC:PUSH ! then
         ENDOF
      ;MATCH
   loop
   v ;

\ Rust's seed_directory_baselines.
: SEED-DIRECTORY-BASELINES
   ( JOURNAL:journal ^VEC:vector<str> ^ARENA:arena -- )
   {: j paths ar :}
   MODEL-BASELINE:DIRECTORY LOCAL-DIRECTORY REMOTE-DIRECTORY
   MODEL-SUBTREE:EMPTY PLANNER:PLAN
   NOOP-BASELINE {: b :}
   paths VEC:COUNT 0 ?do
      j paths i VEC:AT @ MODEL:>PATH b ar JOURNAL:RECORD-NOOP
      NOOP-RECORDED? TTRUE
   loop ;

\ Which sides hold the known path's key, against the samples; the key
\ is copied into ar, as the walk resets its own arena before each row.
: CHECK-VISIT
   ( JOURNAL:known-path ^VEC:vector<str> ^VEC:vector<str>
     ^VEC:vector<str> ^VEC:vector<MODEL:key> ^ARENA:arena -- )
   {: kp bp lp rp merged ar :}
   kp JOURNAL-KNOWN--PATH:UNMAKE {: k br lr n:n rr t live:bool :}
   k KEY-BYTES {: p:str :}
   br BASELINE-SOME? bool>n bp p HOLDS? bool>n T=
   lr LOCAL-SOME? bool>n lp p HOLDS? bool>n T=
   rr REMOTE-SOME? bool>n rp p HOLDS? bool>n T=
   p ar ARENA:COPY MODEL:>KEY merged VEC:PUSH ! ;

\ A directory at the path on all three sides is settled.
: SETTLED?
   ( ^VEC:vector<str> ^VEC:vector<str> ^VEC:vector<str> str -- bool )
   {: bp lp rp p:str :}
   bp p HOLDS? lp p HOLDS? and rp p HOLDS? and ;

\ The paths all three samples hold.
: SETTLED-COUNT
   ( ^VEC:vector<str> ^VEC:vector<str> ^VEC:vector<str> -- n )
   {: bp lp rp :}
   0 bp VEC:COUNT 0 ?do
      bp lp rp bp i VEC:AT @ SETTLED? if 1+ then
   loop ;

\ The keys of the paths but the settled.
: KEYS-INTO
   ( ^VEC:vector<str> ^VEC:vector<MODEL:key> ^VEC:vector<str>
     ^VEC:vector<str> ^VEC:vector<str> ^ARENA:arena -- )
   {: paths keys bp lp rp ar :}
   paths VEC:COUNT 0 ?do
      bp lp rp paths i VEC:AT @ SETTLED? 0= if
         paths i VEC:AT @ ar CANONICAL keys VEC:PUSH !
      then
   loop ;

\ Key x sorts before key y.
: KEY< ( n n ^VEC:vector<MODEL:key> -- bool )
   {: x:n y:n v :}
   v x VEC:AT @ v y VEC:AT @ MODEL:KEY-CMP 0 < ;

\ Pushes the key unless it repeats the last one pushed.
: PUSH-NEW ( MODEL:key ^VEC:vector<MODEL:key> -- )
   {: k out :}
   out VEC:COUNT 0 > if
      out out VEC:COUNT 1- VEC:AT @ k MODEL:KEY= if exit then
   then
   k out VEC:PUSH ! ;

\ The union's keys but the settled, sorted by bytes, without repeats.
: EXPECTED
   ( ^VEC:vector<str> ^VEC:vector<str> ^VEC:vector<str> ^ARENA:arena
     -- ^VEC:vector<MODEL:key> )
   {: bp lp rp ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: all :}
   bp all bp lp rp ar KEYS-INTO lp all bp lp rp ar KEYS-INTO
   rp all bp lp rp ar KEYS-INTO
   all VEC:COUNT [: all KEY< ;] ar ORDER {: idx :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: out :}
   idx VEC:COUNT 0 ?do all idx i VEC:AT @ VEC:AT @ out PUSH-NEW loop
   out ;

: SAME-KEYS ( ^VEC:vector<MODEL:key> ^VEC:vector<MODEL:key> -- )
   {: a b :}
   a VEC:COUNT b VEC:COUNT T=
   a VEC:COUNT b VEC:COUNT min 0 ?do
      a i VEC:AT @ b i VEC:AT @ MODEL:KEY= TTRUE
   loop ;

: REMOTE-DIRECTORIES
   ( ^VEC:vector<str> ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: paths ar :}
   ar REMOTE-RECORDS {: v :}
   paths VEC:COUNT 0 ?do
      v paths i VEC:AT @ REMOTE-DIRECTORY ar REMOTE+
   loop
   v ;

: LOCAL-DIRECTORIES
   ( ^VEC:vector<str> ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: paths ar :}
   ar LOCAL-RECORDS {: v :}
   paths VEC:COUNT 0 ?do v paths i VEC:AT @ DIRECTORY+ loop
   v ;

\ The keys JOURNAL:EACH-UNSETTLED-PATH visits, in order, each checked,
\ and the settled count it answers.
: WALKED
   ( JOURNAL:journal ^VEC:vector<str> ^VEC:vector<str>
     ^VEC:vector<str> ^ARENA:arena -- ^VEC:vector<MODEL:key> n )
   {: j bp lp rp ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: merged :}
   [: j swap [: bp lp rp merged ar CHECK-VISIT ;]
      JOURNAL:EACH-UNSETTLED-PATH ;] ARENA:WITH {: n:n :}
   merged n ;

\ One sample of the proptest, written into the rooted journal.
: MERGE-SAMPLE
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   ar MERGE-PATHS {: bp :}
   ar MERGE-PATHS {: lp :}
   ar MERGE-PATHS {: rp :}
   j bp ar SEED-DIRECTORY-BASELINES
   j ar JOURNAL:BASELINE-PATHS VEC:COUNT bp VEC:COUNT T=
   d j b lp ar LOCAL-DIRECTORIES rp ar REMOTE-DIRECTORIES
   [: bp lp rp ar WALKED bp lp rp SETTLED-COUNT T=
      bp lp rp ar EXPECTED SAME-KEYS ;]
   ar SIDES-IN ;

: KNOWN-PATH-MERGE-MATCHES-SET-UNION ( ^ARENA:arena -- )
   {: ar :}
   s" known_path_merge_matches_set_union" T-LABEL
   7 SEED !
   24 0 ?do [: ar MERGE-SAMPLE ;] ar WITH-ROOTED loop ;

\ ---- deciding skips only settled keys -----------------------------

720 constant COMBOS

variable SETTLED-N
variable YIELD-NOOPS
variable ALL-NOOPS

\ The prefix, the combination's index and the suffix, in ar.
: COMBO$ ( str n str ^ARENA:arena -- str )
   {: pre:str x:n post:str ar :}
   SB-RESET pre SB-APPEND x FMT:INT$ SB-APPEND post SB-APPEND
   SB$ ar ARENA:COPY ;

: COMBO-PATH ( n ^ARENA:arena -- str ) {: x:n ar :} s" k" x s" " ar COMBO$ ;

: ALPHA ( ^ARENA:arena -- DROPBOX:hash ) {: ar :} s" alpha" ar IDENTITY ;
: BETA ( ^ARENA:arena -- DROPBOX:hash ) {: ar :} s" beta" ar IDENTITY ;

\ Combination x's fields: the baseline below 3, the local below 5, the
\ remote below 6, then live, conflict and beneath, each below 2.
: BASE-KIND ( n -- n ) 3 mod ;
: LOCAL-KIND ( n -- n ) 3 / 5 mod ;
: REMOTE-KIND ( n -- n ) 15 / 6 mod ;
: LIVE-COMBO? ( n -- bool ) 90 / 2 mod 0<> ;
: CONFLICT-COMBO? ( n -- bool ) 180 / 2 mod 0<> ;
: BENEATH-COMBO? ( n -- bool ) 360 / 2 mod 0<> ;

\ Alpha or beta at rev-a or rev-b, by y's bits.
: REMOTE-COMBO ( n ^ARENA:arena -- MODEL:remote )
   {: y:n ar :}
   y 2 / 0= if ar ALPHA else ar BETA then
   y 2 mod 0= if s" rev-a" else s" rev-b" then DROPBOX:>REV
   MODEL-REMOTE:MAKE ;

\ No baseline, alpha at rev-a, or a directory.
: COMBO-BASELINE ( JOURNAL:journal n ^ARENA:arena -- )
   {: j x:n ar :}
   x BASE-KIND 0= if exit then
   x BASE-KIND 1 = if
      0 ar REMOTE-COMBO MODEL-BASELINE:PRESENT
   else MODEL-BASELINE:DIRECTORY then {: base :}
   j x ar COMBO-PATH TEST-CLIENT:DISPLAY base ar JOURNAL:RECORD-NOOP
   NOOP-RECORDED? TTRUE ;

\ A live plan creating the remote directory.
: COMBO-PLAN ( JOURNAL:journal n ^ARENA:arena -- )
   {: j x:n ar :}
   x LIVE-COMBO? 0= if exit then
   ar OPERATIONS {: ops :}
   MODEL-OPERATION:CREATE-REMOTE-DIRECTORY ops VEC:PUSH !
   j x ar COMBO-PATH TEST-CLIENT:DISPLAY ops JOURNAL-OPERATION--PLAN:MAKE ar
   JOURNAL:RECORD-PLAN RECORDED drop ;

: COMBO-CONFLICT ( JOURNAL:journal n ^ARENA:arena -- )
   {: j x:n ar :}
   x CONFLICT-COMBO? 0= if exit then
   j x ar COMBO-PATH TEST-CLIENT:DISPLAY ar ALPHA MODEL-LOCAL:MAKE
   MODEL-CONFLICT:REMOTE-DELETED ar JOURNAL:RECORD-CONFLICT drop ;

: ALPHA+ ( ^VEC:vector<MODEL:local-record> str ^ARENA:arena -- )
   {: ls p:str ar :}
   ls p ar ALPHA MODEL-LOCAL:MAKE LOCAL-PRESENT LOCAL+ ;

\ No local row, alpha, beta, a directory, or alpha at two spellings.
: COMBO-LOCALS
   ( ^VEC:vector<MODEL:local-record> n ^ARENA:arena -- )
   {: ls x:n ar :}
   x ar COMBO-PATH {: p:str :}
   x LOCAL-KIND {: k:n :}
   k 1 = if ls p ar ALPHA+ exit then
   k 2 = if ls p ar BETA MODEL-LOCAL:MAKE LOCAL-PRESENT LOCAL+ exit then
   k 3 = if ls p DIRECTORY+ exit then
   k 4 = if ls p ar ALPHA+ ls s" K" x s" " ar COMBO$ ar ALPHA+ then ;

\ No remote row, a file of REMOTE-COMBO's, or a directory; and a
\ directory beneath.
: COMBO-REMOTES
   ( ^VEC:vector<MODEL:remote-record> n ^ARENA:arena -- )
   {: rs x:n ar :}
   x BENEATH-COMBO? if
      rs s" k" x s" /c" ar COMBO$ REMOTE-DIRECTORY ar REMOTE+
   then
   x REMOTE-KIND {: k:n :}
   k 0= if exit then
   x ar COMBO-PATH {: p:str :}
   k 5 = if rs p REMOTE-DIRECTORY ar REMOTE+ exit then
   rs p k 1- ar REMOTE-COMBO REMOTE-PRESENT ar REMOTE+ ;

\ The keys the journal held before the statement skipped the settled: a
\ baseline's, a local or remote row's, or a live plan's.
: COMBO-KEYS ( ^VEC:vector<MODEL:key> n ^ARENA:arena -- )
   {: held x:n ar :}
   x BASE-KIND 0<> x LOCAL-KIND 0<> or x REMOTE-KIND 0<> or
   x LIVE-COMBO? or if
      x ar COMBO-PATH ar CANONICAL held VEC:PUSH !
   then
   x BENEATH-COMBO? if
      s" k" x s" /c" ar COMBO$ ar CANONICAL held VEC:PUSH !
   then ;

\ Every combination written into the rooted journal, its held keys in
\ held.
: WRITE-COMBOS
   ( JOURNAL:journal JOURNAL:local-root-binding ^VEC:vector<MODEL:key>
     ^ARENA:arena -- )
   {: j b held ar :}
   ar LOCAL-RECORDS {: ls :}
   ar REMOTE-RECORDS {: rs :}
   COMBOS 0 ?do
      j i ar COMBO-BASELINE j i ar COMBO-PLAN j i ar COMBO-CONFLICT
      ls i ar COMBO-LOCALS rs i ar COMBO-REMOTES held i ar COMBO-KEYS
   loop
   j b ls ar LOCALS-PUBLISHED
   j s" cursor" DROPBOX:>CURSOR rs JOURNAL:PUBLISH-REMOTE-INVENTORY ;

\ Whether deciding the known path only counts a no-op; a case collision
\ decides nothing, so it does not.
: COUNTED-NOOP? ( JOURNAL:known-path ^planning ^ARENA:arena -- bool )
   {: kp pl ar :}
   false [: drop kp kp pl ar KNOWN-DECISION pl COUNTED? ;] catch
   {: code:n :}
   code 0<> if
      code E-CASE-COLLISION <> if code throw then
      drop false
   then ;

\ The vector holds the key.
: KEY-IN? ( ^VEC:vector<MODEL:key> MODEL:key -- bool )
   {: v k :}
   false v VEC:COUNT 0 ?do v i VEC:AT @ k MODEL:KEY= or loop ;

\ A key the statement yields, one held, kept in the planning's arena.
: YIELD-STEP
   ( JOURNAL:known-path ^planning ^VEC:vector<MODEL:key>
     ^VEC:vector<MODEL:key> ^ARENA:arena -- )
   {: kp pl seen held ar :}
   kp KNOWN-KEY KEY-BYTES pl ARENA-OF ARENA:COPY MODEL:>KEY {: k :}
   held k KEY-IN? TTRUE
   k seen VEC:PUSH !
   kp pl ar COUNTED-NOOP? if 1 YIELD-NOOPS +! then ;

\ The scratch arena first, as ARENA:WITH passes it.
: YIELD-IN
   ( ^ARENA:arena ^planning ^VEC:vector<MODEL:key>
     ^VEC:vector<MODEL:key> -- )
   {: scratch pl seen held :}
   pl JOURNAL-OF scratch [: pl seen held scratch YIELD-STEP ;]
   JOURNAL:EACH-UNSETTLED-PATH SETTLED-N ! ;

\ A held key decided as the walk before did; one the statement skipped
\ must be a counted no-op.
: DECIDE-HELD
   ( ^planning MODEL:key ^VEC:vector<MODEL:key> ^ARENA:arena -- )
   {: pl k seen ar :}
   pl JOURNAL-OF k ar JOURNAL:KNOWN-PATH-AT pl ar COUNTED-NOOP?
   {: c:bool :}
   seen k KEY-IN? 0= if c TTRUE then
   c if 1 ALL-NOOPS +! then ;

: SETTLED-CHECKS
   ( JOURNAL:journal ^VEC:vector<MODEL:key> ^ARENA:arena -- )
   {: j held ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: seen :}
   0 YIELD-NOOPS ! 0 ALL-NOOPS !
   j ar PLANNING-OVER {: walk :}
   [: walk seen held YIELD-IN ;] ARENA:WITH
   j ar PLANNING-OVER {: all :}
   held VEC:COUNT 0 ?do all held i VEC:AT @ seen ar DECIDE-HELD loop ;

\ Both passes log each of the 144 two-spelling keys' collision once.
: SKIPS-ONLY-SETTLED
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: held :}
   j b held ar WRITE-COMBOS
   d [: j held ar SETTLED-CHECKS ;] ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 288 T=
   SETTLED-N @ 4 T=
   SETTLED-N @ YIELD-NOOPS @ + ALL-NOOPS @ T= ;

: DECIDING-SKIPS-ONLY-SETTLED-KEYS ( ^ARENA:arena -- )
   {: ar :}
   s" deciding skips only settled keys" T-LABEL
   [: ar SKIPS-ONLY-SETTLED ;] ar WITH-ROOTED ;

: NO-BASELINE ( -- option<MODEL:baseline> ) OPTION:NONE ;

: FIRST-OPERATION-ID ( JOURNAL:plan-record -- JOURNAL:operation-id )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops 0 VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE {: oid at o st :}
   oid ;

: REMAINING-OPERATION-COMPARISON-IGNORES-A-COMPLETED-PREFIX
   ( ^ARENA:arena -- )
   {: ar :}
   s" remaining_operation_comparison_ignores_a_completed_prefix" T-LABEL
   ar CASE-JOURNAL {: d:str j :}
   s" preserved" ar IDENTITY MODEL-LOCAL:MAKE {: local :}
   s" replacement" s" replacement-revision" ar REMOTE-FILE {: remote :}
   local MODEL-OPERATION:PRESERVE-LOCAL
   remote MODEL-OPERATION:INSTALL-LOCAL ar TWO-PLAN {: original :}
   j s" file.txt" TEST-CLIENT:DISPLAY original ar JOURNAL:RECORD-PLAN RECORDED
   {: recorded :}
   recorded JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops VEC:COUNT 2 T=
   j recorded FIRST-OPERATION-ID NO-BASELINE ar
   JOURNAL:COMPLETE-OPERATION OPERATION-COMPLETED? TTRUE
   j ar JOURNAL:PENDING-PLANS {: pending :}
   pending VEC:COUNT 1 T=
   pending 0 VEC:AT @ {: plan :}
   remote MODEL-OPERATION:INSTALL-LOCAL ar TEST-CLIENT:ONE-PLAN {: fresh :}
   plan fresh REMAINING-OPERATIONS-MATCH? TTRUE
   plan original REMAINING-OPERATIONS-MATCH? TFALSE
   d j GONE ;

: PENDING-ONLY-PATHS-ARE-VISITED-AS-ABSENT-WITHOUT-CREATING-A-BASELINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" pending_only_paths_are_visited_as_absent_without_creating_a_baseline"
   T-LABEL
   ar CASE-JOURNAL {: d:str j :}
   s" removed.txt" TEST-CLIENT:DISPLAY {: path :}
   s" obsolete" s" obsolete-revision" ar REMOTE-FILE
   MODEL-OPERATION:INSTALL-LOCAL ar TEST-CLIENT:ONE-PLAN {: plan :}
   j path plan ar JOURNAL:RECORD-PLAN RECORDED drop
   j ar PLANNING-OVER {: pl :}
   pl DECIDE-ALL
   pl PLANNING-DECISIONS @ {: decisions :}
   decisions VEC:COUNT 1 T=
   decisions 0 VEC:AT @ PATH-DECISION-UNMAKE
   {: k shown same dec :}
   k path ar MODEL:FOLD MODEL:KEY= TTRUE
   dec MODEL-BASELINE:ABSENT LOCAL-ABSENT REMOTE-ABSENT
   MODEL-SUBTREE:EMPTY PLANNER:PLAN MODEL:DECISION= TTRUE
   dec NOOP? TTRUE
   j path ar JOURNAL:BASELINE STORED-SOME? TFALSE
   d j GONE ;

: INHERITED ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   MODEL-UNKNOWN--REASON:INACCESSIBLE LOCAL-UNKNOWN {: locked :}
   j s" locked/secret.txt" locked ar LOCAL-UNOBSERVED=
   j s" Locked/Deep/Deeper.TXT" locked ar LOCAL-UNOBSERVED=
   j s" gone.txt" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   j s" open/gone.txt" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   j s" open/kept.txt/below" LOCAL-ABSENT ar LOCAL-UNOBSERVED= ;

: A-PATH-BELOW-AN-UNKNOWN-DIRECTORY-INHERITS-ITS-REASON
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_path_below_an_unknown_directory_inherits_its_reason" T-LABEL
   ar LOCAL-RECORDS {: rs :}
   rs s" locked" MODEL-UNKNOWN--REASON:INACCESSIBLE LOCAL-UNKNOWN LOCAL+
   rs s" open" DIRECTORY+
   rs s" open/kept.txt" s" kept" ar PRESENT+
   rs ar REMOTE-RECORDS [: ar INHERITED ;] ar WITH-SIDES ;

: VOLUME-UNKNOWN ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN {: why :}
   j s" volume/gone.txt" why ar REMOTE-UNOBSERVED=
   j s" volume/listed/gone.txt" why ar REMOTE-UNOBSERVED=
   j s" volume/listed/deeper/gone.txt" why ar REMOTE-UNOBSERVED= ;

: VOLUME-LISTED ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   j s" volume/gone.txt" REMOTE-ABSENT ar REMOTE-UNOBSERVED=
   j s" volume/listed/deeper/gone.txt" REMOTE-ABSENT ar
   REMOTE-UNOBSERVED= ;

: A-RECORD-BELOW-AN-UNKNOWN-DIRECTORY-CANNOT-RESTORE-ABSENCE
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_record_below_an_unknown_directory_cannot_restore_absence" T-LABEL
   ar REMOTE-RECORDS {: rs :}
   rs s" volume" MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN ar
   REMOTE+
   rs s" volume/listed" REMOTE-DIRECTORY ar REMOTE+
   ar LOCAL-RECORDS rs [: ar VOLUME-UNKNOWN ;] ar WITH-SIDES
   ar REMOTE-RECORDS {: cs :}
   cs s" volume" REMOTE-DIRECTORY ar REMOTE+
   cs s" volume/listed" REMOTE-DIRECTORY ar REMOTE+
   ar LOCAL-RECORDS cs [: ar VOLUME-LISTED ;] ar WITH-SIDES ;

: NEIGHBORS ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   MODEL-UNKNOWN--REASON:INCOMPLETE LOCAL-UNKNOWN {: why :}
   j s" report/x" why ar LOCAL-UNOBSERVED=
   j s" REPORT/x/y" why ar LOCAL-UNOBSERVED=
   j s\" unreadable\xFF/x" MODEL-UNKNOWN--REASON:INACCESSIBLE
   LOCAL-UNKNOWN ar LOCAL-UNOBSERVED=
   j s" report.txt/x" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   j s" report0/x" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   j s" reportx/y" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   j s" report" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   j s" unreadable/x" LOCAL-ABSENT ar LOCAL-UNOBSERVED= ;

: NAMES-THAT-NEIGHBOR-THE-SEPARATOR-ARE-NOT-ANCESTORS
   ( ^ARENA:arena -- )
   {: ar :}
   s" names_that_neighbor_the_separator_are_not_ancestors" T-LABEL
   ar LOCAL-RECORDS {: rs :}
   rs s" report" MODEL-UNKNOWN--REASON:INCOMPLETE LOCAL-UNKNOWN LOCAL+
   rs s" report.txt" s" report" ar PRESENT+
   rs s" report0" DIRECTORY+
   rs s\" unreadable\xFF" MODEL-UNKNOWN--REASON:INACCESSIBLE
   LOCAL-UNKNOWN LOCAL+
   rs ar REMOTE-RECORDS [: ar NEIGHBORS ;] ar WITH-SIDES ;

: LENDS-NOTHING ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   MODEL-UNKNOWN--REASON:INACCESSIBLE LOCAL-UNKNOWN {: why :}
   j s" cache.dropbox/x" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   j s" cache.dropbox/x" s" cache.dropbox/x" ar RESPELLED
   s" cache.dropbox/x" T$=
   j s" locked/x" why ar LOCAL-UNOBSERVED=
   j s" locked/x" s" locked/x" ar RESPELLED s" Locked/x" T$= ;

: AN-EXCLUDED-ANCESTOR-LENDS-NO-REASON-OR-SPELLING ( ^ARENA:arena -- )
   {: ar :}
   s" an excluded ancestor lends no reason or spelling" T-LABEL
   MODEL-UNKNOWN--REASON:INACCESSIBLE LOCAL-UNKNOWN {: why :}
   ar LOCAL-RECORDS {: rs :}
   rs s" Cache.dropbox" why LOCAL+
   rs s" Locked" why LOCAL+
   rs ar REMOTE-RECORDS [: ar LENDS-NOTHING ;] ar WITH-SIDES ;

: BLOCKED-UNKNOWN ( -- MODEL:decision )
   MODEL-BLOCKED--REASON:UNKNOWN MODEL-DECISION:BLOCKED ;

: BELOW ( ^ARENA:arena -- MODEL:key )
   {: ar :} s" locked/secret.txt" ar CANONICAL ;

\ The local side below the unknown directory.
: LOCAL-BLOCKS
   ( JOURNAL:journal MODEL:unknown-reason MODEL:baseline ^ARENA:arena
     -- )
   {: j why baseline ar :}
   j ar BELOW ar LOCAL-UNOBSERVED {: lo :}
   j ar BELOW ar REMOTE-AT {: ro :}
   lo why LOCAL-UNKNOWN MODEL:LOCAL-OBSERVATION= TTRUE
   baseline lo ro MODEL-SUBTREE:EMPTY PLANNER:PLAN BLOCKED-UNKNOWN
   MODEL:DECISION= TTRUE ;

\ The remote side below the unknown directory.
: REMOTE-BLOCKS
   ( JOURNAL:journal MODEL:unknown-reason MODEL:baseline ^ARENA:arena
     -- )
   {: j why baseline ar :}
   j ar BELOW ar LOCAL-AT {: lo :}
   j ar BELOW ar REMOTE-UNOBSERVED {: ro :}
   ro why REMOTE-UNKNOWN MODEL:REMOTE-OBSERVATION= TTRUE
   baseline lo ro MODEL-SUBTREE:EMPTY PLANNER:PLAN BLOCKED-UNKNOWN
   MODEL:DECISION= TTRUE ;

\ One reason of an_unknown_ancestor_blocks_a_deletion_on_either_side:
\ the observation each side reads below the unknown directory is
\ unknown for that reason, and the plan is blocked.
: BLOCKS-EITHER-SIDE
   ( MODEL:unknown-reason MODEL:remote ^ARENA:arena -- )
   {: why file ar :}
   file MODEL-BASELINE:PRESENT {: baseline :}
   ar LOCAL-RECORDS {: ul :}
   ul s" locked" why LOCAL-UNKNOWN LOCAL+
   ar REMOTE-RECORDS {: lr :}
   lr s" locked" REMOTE-DIRECTORY ar REMOTE+
   lr s" locked/secret.txt" file REMOTE-PRESENT ar REMOTE+
   ul lr [: why baseline ar LOCAL-BLOCKS ;] ar WITH-SIDES
   ar LOCAL-RECORDS {: sl :}
   sl s" locked" DIRECTORY+
   sl s" locked/secret.txt" s" secret" ar PRESENT+
   ar REMOTE-RECORDS {: ur :}
   ur s" locked" why REMOTE-UNKNOWN ar REMOTE+
   sl ur [: why baseline ar REMOTE-BLOCKS ;] ar WITH-SIDES ;

: AN-UNKNOWN-ANCESTOR-BLOCKS-A-DELETION-ON-EITHER-SIDE ( ^ARENA:arena -- )
   {: ar :}
   s" an_unknown_ancestor_blocks_a_deletion_on_either_side" T-LABEL
   s" secret" s" rev-secret" ar REMOTE-FILE {: file :}
   MODEL-UNKNOWN--REASON:INACCESSIBLE file ar BLOCKS-EITHER-SIDE
   MODEL-UNKNOWN--REASON:UNSUPPORTED file ar BLOCKS-EITHER-SIDE
   MODEL-UNKNOWN--REASON:INCOMPLETE file ar BLOCKS-EITHER-SIDE ;

\ Rust's record_matching_baseline.
: RECORD-MATCHING-BASELINE
   ( JOURNAL:journal MODEL:path MODEL:remote ^ARENA:arena -- )
   {: j path remote ar :}
   remote MODEL-REMOTE:UNMAKE {: c rev :}
   MODEL-BASELINE:ABSENT c MODEL-LOCAL:MAKE LOCAL-PRESENT
   remote REMOTE-PRESENT MODEL-SUBTREE:EMPTY PLANNER:PLAN
   NOOP-BASELINE {: b :}
   j path b ar JOURNAL:RECORD-NOOP NOOP-RECORDED? TTRUE ;

: STORED-BASELINE ( option<MODEL:baseline> -- MODEL:baseline )
   MATCH option
      none OF false TTRUE MODEL-BASELINE:ABSENT ENDOF
      some OF ENDOF
   ;MATCH ;

: BASELINE-ONLY-PATHS-ARE-INCLUDED-IN-CONFIRMED-ABSENCE
   ( ^ARENA:arena -- )
   {: ar :}
   s" baseline_only_paths_are_included_in_confirmed_absence" T-LABEL
   ar CASE-JOURNAL {: d:str j :}
   s" gone.txt" TEST-CLIENT:DISPLAY {: path :}
   s" old" s" rev-old" ar REMOTE-FILE {: remote :}
   j path remote ar RECORD-MATCHING-BASELINE
   j ar JOURNAL:BASELINE-PATHS {: paths :}
   paths VEC:COUNT 1 T=
   paths 0 VEC:AT @ PATH$ s" gone.txt" T$=
   j path ar JOURNAL:BASELINE STORED-BASELINE
   LOCAL-ABSENT REMOTE-ABSENT MODEL-SUBTREE:EMPTY PLANNER:PLAN
   MODEL-BASELINE:ABSENT MODEL-DECISION:NOOP MODEL:DECISION= TTRUE
   d j GONE ;

\ Rust's remote_directory.
: REMOTE-DIRECTORY+
   ( ^VEC:vector<MODEL:remote-record> str ^ARENA:arena -- )
   {: v p:str ar :}
   v p REMOTE-DIRECTORY ar REMOTE+ ;

\ A directory at the path on both sides and in the baseline.
: KEPT-DIRECTORY+
   ( JOURNAL:journal ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:remote-record> str ^ARENA:arena -- )
   {: j ls rs p:str ar :}
   ls p DIRECTORY+ rs p ar REMOTE-DIRECTORY+
   j p TEST-CLIENT:DISPLAY MODEL-BASELINE:DIRECTORY ar JOURNAL:RECORD-NOOP
   NOOP-RECORDED? TTRUE ;

: KEPT-DIRECTORIES
   ( JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   ar LOCAL-RECORDS {: ls :}
   ar REMOTE-RECORDS {: rs :}
   j ls rs s" Docs" ar KEPT-DIRECTORY+
   j ls rs s" Docs/Notes" ar KEPT-DIRECTORY+
   j ls rs s" Music" ar KEPT-DIRECTORY+
   j b ls ar LOCALS-PUBLISHED
   j s" cursor" DROPBOX:>CURSOR rs
   JOURNAL:PUBLISH-REMOTE-INVENTORY ;

: NOOPS-WALKED
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   j b ar KEPT-DIRECTORIES
   j ar PLANNING-OVER {: pl :}
   pl KNOWN-WALK VEC:COUNT 0 T=
   pl PLANNING-NOOP-COUNT @ 3 T=
   j ar PLANNING-OVER {: all :}
   all DECIDE-ALL
   all PLANNING-DECISIONS @ VEC:COUNT 0 T=
   all PLANNING-NOOPS @ VEC:COUNT 0 T=
   all PLANNING-NOOP-COUNT @ 3 T= ;

: A-WALK-COUNTS-EVERY-KEPT-BASELINE ( ^ARENA:arena -- )
   {: ar :}
   s" a walk counts every kept baseline" T-LABEL
   [: ar NOOPS-WALKED ;] ar WITH-ROOTED ;

: DECISION-PATH$ ( path-decision -- str )
   PATH-DECISION-UNMAKE {: k path same dec :} path PATH$ ;

: UNSUPPORTED-PAIR
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   ar LOCAL-RECORDS {: ls :}
   ls s" link" UNSUPPORTED+ ls s" Link" UNSUPPORTED+
   j b ls ar LOCALS-PLANNING {: pl :}
   pl DECIDE-ALL
   pl PLANNING-DECISIONS @ {: v :}
   v VEC:COUNT 1 T=
   v 0 VEC:AT @ DECISION-PATH$ s" Link" T$= ;

: DECIDING-KEEPS-THE-RUN-RULE ( ^ARENA:arena -- )
   {: ar :}
   s" deciding keeps the run rule" T-LABEL
   [: ar UNSUPPORTED-PAIR ;] ar WITH-ROOTED ;

\ A path decision at the path, its key folded.
: DECIDED ( str MODEL:decision ^ARENA:arena -- path-decision )
   {: p:str d ar :}
   p ar CANONICAL p TEST-CLIENT:DISPLAY false d PATH-DECISION-MAKE ;

: DECISION-PATH ( path-decision -- str )
   PATH-DECISION-UNMAKE {: k path same d :} path PATH$ ;

: DECISION< ( n n ^VEC:vector<path-decision> -- bool )
   {: x:n y:n v :}
   v x VEC:AT @ v y VEC:AT @ ORDER-PATH-DECISIONS 0 < ;

: PATH-DECISIONS-ORDER-DELETES-LAST-AND-DEEPEST-FIRST ( ^ARENA:arena -- )
   {: ar :}
   s" path decisions order deletes last and deepest first" T-LABEL
   ar ARENA:ALLOCATOR 0 [type] path-decision VEC:NEW {: v :}
   MODEL-OPERATION:DELETE-LOCAL-DIRECTORY MODEL-DECISION:OPERATE {: del :}
   s" a" del ar DECIDED v VEC:PUSH !
   s" a/b" del ar DECIDED v VEC:PUSH !
   s" a/b/c.txt" s" c" ar IDENTITY MODEL-OPERATION:CREATE-REMOTE
   MODEL-DECISION:OPERATE ar DECIDED v VEC:PUSH !
   v VEC:COUNT [: v DECISION< ;] ar ORDER {: idx :}
   v idx 0 VEC:AT @ VEC:AT @ DECISION-PATH s" a/b/c.txt" T$=
   v idx 1 VEC:AT @ VEC:AT @ DECISION-PATH s" a/b" T$=
   v idx 2 VEC:AT @ VEC:AT @ DECISION-PATH s" a" T$= ;


\ ---- case collisions ------------------------------------------------

: NEW-RECORDS ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   ARENA:ALLOCATOR 0 [type] MODEL:local-record VEC:NEW ;

: DIRECTORY ( -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:DIRECTORY ;

: UNKNOWN ( MODEL:unknown-reason -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:UNKNOWN ;

: PRESENT ( MODEL:local -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:PRESENT ;

: OBSERVED
   ( ^VEC:vector<MODEL:local-record> str
     MODEL:observation<MODEL:local> -- )
   {: v p:str o :}
   p TEST-CLIENT:DISPLAY o MODEL-LOCAL--RECORD:MAKE v VEC:PUSH ! ;

\ Rust's local_records: each path a directory.
: DIR+ ( ^VEC:vector<MODEL:local-record> str -- )
   DIRECTORY OBSERVED ;

: UNSUPPORTED-SPELLING+ ( ^VEC:vector<MODEL:local-record> str -- )
   MODEL-UNKNOWN--REASON:UNSUPPORTED UNKNOWN OBSERVED ;

: INACCESSIBLE+ ( ^VEC:vector<MODEL:local-record> str -- )
   MODEL-UNKNOWN--REASON:INACCESSIBLE UNKNOWN OBSERVED ;

\ Rust's identity: dropbox_content_hash of the bytes, read from a pipe.
: HASH-OF ( str ^ARENA:arena -- DROPBOX:hash )
   {: b:str ar :}
   FD:PIPE {: r:fd w:fd :}
   w b FD:WRITE-FULL w FS:CLOSE-DIR
   r ar LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR ;

\ A file at the path holding the bytes b.
: FILE+
   ( ^VEC:vector<MODEL:local-record> str str ^ARENA:arena -- )
   {: v p:str b:str ar :}
   b ar HASH-OF MODEL-LOCAL:MAKE PRESENT {: o :}
   v p o OBSERVED ;

: RECORDED-FOO ( MODEL:key -- option<MODEL:path> )
   drop s" FOO.txt" TEST-CLIENT:DISPLAY OPTION:SOME ;

: RECORDED-NOTES ( MODEL:key -- option<MODEL:path> )
   drop s" notes.txt" TEST-CLIENT:DISPLAY OPTION:SOME ;

: SOURCE$ ( option<MODEL:path> -- str )
   MATCH option
      none OF s" (none)" ENDOF
      some OF PATH$ ENDOF
   ;MATCH ;

\ The source, failing the case when there is none.
: SOME-PATH ( option<MODEL:path> -- MODEL:path )
   MATCH option
      none OF false TTRUE s" " TEST-CLIENT:DISPLAY ENDOF
      some OF ENDOF
   ;MATCH ;

: UNBASED-SOURCE
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena -- MODEL:path )
   [: NO-SPELLING ;] swap CASE-VARIANT-SOURCE SOME-PATH ;

: MOVE-SOURCE$ ( case-variant-move -- str )
   CASE-VARIANT-MOVE-UNMAKE {: s d :} s PATH$ ;

: MOVE-DESTINATION ( case-variant-move -- MODEL:path )
   CASE-VARIANT-MOVE-UNMAKE {: s d :} d ;

\ CASE-VARIANT-MOVE, max 255, of the records' source with no baseline,
\ the records published first.
: UNBASED-MOVE
   ( JOURNAL:journal JOURNAL:local-root-binding
     ^VEC:vector<MODEL:local-record> ^ARENA:arena -- case-variant-move )
   {: j b v ar :}
   j b v ar LOCALS-PUBLISHED
   j v ar UNBASED-SOURCE 255 ar CASE-VARIANT-MOVE ;

: SKIPS-EXISTING-SUFFIXES
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   ar NEW-RECORDS {: v :}
   v s" Credit" DIR+
   v s" credit" DIR+
   v s" credit (case variant)" DIR+
   v s" CREDIT (CASE VARIANT 2)" DIR+
   j b v ar UNBASED-MOVE {: mv :}
   mv MOVE-SOURCE$ s" credit" T$=
   mv MOVE-DESTINATION PATH$ s" credit (case variant 3)" T$= ;

: CASE-VARIANT-NAME-SKIPS-EXISTING-SUFFIXES ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_name_skips_existing_suffixes" T-LABEL
   [: ar SKIPS-EXISTING-SUFFIXES ;] ar WITH-ROOTED ;

: REPEATED ( u8 n ^ARENA:arena -- str )
   {: c:u8 u:n ar :}
   ar u ARENA:ALLOC drop {: p:^ :}
   u 0 ?do c p i + c! loop
   p u >str ;

: FITS-A-MAXIMUM-LENGTH-COMPONENT
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   ar NEW-RECORDS {: v :}
   v 65 255 ar REPEATED DIR+
   v 97 255 ar REPEATED DIR+
   j b v ar UNBASED-MOVE MOVE-DESTINATION
   PATH$ SPLIT-NAME {: dir:str name:str :}
   name str> nip 255 T=
   name s"  (case variant)" STR:ENDS-WITH? TTRUE ;

: CASE-VARIANT-NAME-FITS-A-MAXIMUM-LENGTH-COMPONENT ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_name_fits_a_maximum_length_component" T-LABEL
   [: ar FITS-A-MAXIMUM-LENGTH-COMPONENT ;] ar WITH-ROOTED ;

\ The name, failing the case when none fits.
: SOME-NAME ( option<str> -- str )
   MATCH option
      none OF false TTRUE s" " ENDOF
      some OF ENDOF
   ;MATCH ;

: FILE-COPY-NAME-IS-DETERMINISTIC-AND-FITS-THE-PARENT-LIMIT
   ( ^ARENA:arena -- )
   {: ar :}
   s" file_copy_name_is_deterministic_and_fits_the_parent_limit"
   T-LABEL
   97 255 ar REPEATED {: name:str :}
   98 64 ar REPEATED DROPBOX:>HASH {: h :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:path VEC:NEW {: none :}
   none construct file-copy-origin dropbox {: o :}
   name h o 0 255 ar FILE-COPY-NAME SOME-NAME {: a:str :}
   name h o 0 255 ar FILE-COPY-NAME SOME-NAME {: b:str :}
   a b T$=
   a str> nip 255 T=
   a s"  (Dropbox file bbbbbbbbbbbb)" STR:ENDS-WITH? TTRUE ;

: CONVERGE-FROM-PARENT-TO-CHILD
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   ar NEW-RECORDS {: v :}
   v s" Credit" DIR+
   v s" credit" DIR+
   v s" credit/Expenses" DIR+
   v s" credit/expenses" DIR+
   j b v ar UNBASED-MOVE {: parent :}
   parent MOVE-SOURCE$ s" credit" T$=
   parent MOVE-DESTINATION PATH$ s" credit (case variant)" T$=
   ar NEW-RECORDS {: after :}
   after s" Credit" DIR+
   after s" credit (case variant)" DIR+
   after s" credit (case variant)/Expenses" DIR+
   after s" credit (case variant)/expenses" DIR+
   j b after ar UNBASED-MOVE {: child :}
   child MOVE-SOURCE$ s" credit (case variant)/expenses" T$=
   child MOVE-DESTINATION PATH$
   s" credit (case variant)/expenses (case variant)" T$=
   ar NEW-RECORDS {: converged :}
   converged s" Credit" DIR+
   converged s" credit (case variant)" DIR+
   converged s" credit (case variant)/Expenses" DIR+
   converged child MOVE-DESTINATION PATH$ DIR+
   converged [: NO-SPELLING ;] ar CASE-VARIANT-SOURCE SOURCE$
   s" (none)" T$= ;

: CASE-VARIANT-MOVES-CONVERGE-FROM-PARENT-TO-CHILD ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_moves_converge_from_parent_to_child" T-LABEL
   [: ar CONVERGE-FROM-PARENT-TO-CHILD ;] ar WITH-ROOTED ;

: CASE-VARIANT-SOURCE-KEEPS-THE-RECORDED-SPELLING ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_source_keeps_the_recorded_spelling" T-LABEL
   ar NEW-RECORDS {: v :}
   v s" Foo.txt" DIR+
   v s" foo.txt" DIR+
   v [: RECORDED-FOO ;] ar CASE-VARIANT-SOURCE SOURCE$ s" foo.txt" T$=
   \ An unreadable spelling can still be renamed, so it moves and the
   \ recorded one keeps its history.
   ar NEW-RECORDS {: w :}
   w s" Notes.txt" INACCESSIBLE+
   w s" notes.txt" s" notes" ar FILE+
   w [: RECORDED-NOTES ;] ar CASE-VARIANT-SOURCE SOURCE$
   s" Notes.txt" T$= ;

: UNSUPPORTED-RECORDS ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   NEW-RECORDS {: v :}
   v s" Link" UNSUPPORTED-SPELLING+
   v s" link" UNSUPPORTED-SPELLING+
   v ;

: CASE-VARIANT-SOURCE-LEAVES-UNSUPPORTED-SPELLINGS ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_source_leaves_unsupported_spellings" T-LABEL
   ar UNSUPPORTED-RECORDS [: NO-SPELLING ;] ar CASE-VARIANT-SOURCE
   SOURCE$ s" (none)" T$= ;

: CASE-VARIANT-SOURCE-SKIPS-AN-UNSUPPORTED-COLLISION ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_source_skips_an_unsupported_collision" T-LABEL
   ar UNSUPPORTED-RECORDS {: v :}
   v s" Notes.txt" s" Notes.txt" ar FILE+
   v s" notes.txt" s" notes.txt" ar FILE+
   v [: NO-SPELLING ;] ar CASE-VARIANT-SOURCE SOURCE$ s" notes.txt" T$= ;

\ The journal's first collision, Link and link, is unsupported, so
\ COLLIDING passes it for the notes.
: FIRST-COLLISION-SKIPS-UNSUPPORTED
   ( str JOURNAL:journal JOURNAL:local-root-binding ^ARENA:arena -- )
   {: d:str j b ar :}
   ar UNSUPPORTED-RECORDS {: v :}
   v s" Notes.txt" s" Notes.txt" ar FILE+
   v s" notes.txt" s" notes.txt" ar FILE+
   j b v ar LOCALS-PUBLISHED
   j ar COLLIDING [: NO-SPELLING ;] ar CASE-VARIANT-SOURCE SOURCE$
   s" notes.txt" T$= ;

: JOURNAL-FIRST-COLLISION-SKIPS-AN-UNSUPPORTED-ONE ( ^ARENA:arena -- )
   {: ar :}
   s" journal_first_collision_skips_an_unsupported_one" T-LABEL
   [: ar FIRST-COLLISION-SKIPS-UNSUPPORTED ;] ar WITH-ROOTED ;

\ ---- RESOLVE-CASE-COLLISION

: TREE-GONE ( str -- ) FS:REMOVE-TREE ;

: MAKE-AT ( str str ^ARENA:arena -- )
   TEST-CLIENT:INSIDE FS:MAKE-DIR ;

: WRITE-AT ( str str str ^ARENA:arena -- )
   {: r:str p:str b:str ar :}
   r p ar TEST-CLIENT:INSIDE b FS:WRITE-ALL ;

: THERE? ( str str ^ARENA:arena -- bool ) TEST-CLIENT:INSIDE FS:EXISTS? ;

\ A case's directory under TMPDIR and the sync root in it, holding
\ Dir/a.txt and dir/b.txt.
: FIXTURE ( ^ARENA:arena -- str str )
   {: ar :}
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   d s" root" ar TEST-CLIENT:INSIDE {: r:str :}
   r FS:MAKE-DIR
   r s" Dir" ar MAKE-AT
   r s" dir" ar MAKE-AT
   r s" Dir/a.txt" s" a" ar WRITE-AT
   r s" dir/b.txt" s" b" ar WRITE-AT
   d r ;

\ The fixture's tree as a scan observes it.
: TREE ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: ar :}
   ar NEW-RECORDS {: v :}
   v s" Dir" DIR+
   v s" Dir/a.txt" s" a" ar FILE+
   v s" dir" DIR+
   v s" dir/b.txt" s" b" ar FILE+
   v ;

\ The journal in d, bound to the root r and holding the fixture's tree,
\ with a pending plan below each spelling and one beside them.
: BOUND ( str str ^ARENA:arena -- JOURNAL:journal )
   {: d:str r:str ar :}
   d s" journal.sqlite3" ar TEST-CLIENT:INSIDE JOURNAL:OPEN {: j :}
   j r ar ROOTED {: b :}
   j b ar TREE ar LOCALS-PUBLISHED
   j s" Dir/a.txt" ar TEST-CLIENT:RECORD
   j s" dir/b.txt" ar TEST-CLIENT:RECORD
   j s" other.txt" ar TEST-CLIENT:RECORD
   j ;

: RESOLUTION$ ( case-collision-resolution ^ARENA:arena -- str )
   {: ar :}
   MATCH case-collision-resolution
      none OF s" none" ENDOF
      renamed OF s" renamed " swap PATH$ ar JOIN-BYTES ENDOF
      changed OF s" changed " swap PATH$ ar JOIN-BYTES ENDOF
      root-changed OF s" root-changed" ENDOF
   ;MATCH ;

: PLAN-PATH$ ( ^VEC:vector<JOURNAL:plan-record> n -- str )
   VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} p PATH$ ;

: RENAMES-ONE ( str str ^ARENA:arena -- )
   {: d:str r:str ar :}
   d r ar BOUND {: j :}
   ar TREE {: v :}
   v ar UNBASED-SOURCE PATH$ s" dir" T$=
   j r ar RESOLVE-CASE-COLLISION ar RESOLUTION$
   s" renamed dir" T$=
   r s" dir (case variant)/b.txt" ar THERE? TTRUE
   r s" dir" ar THERE? TFALSE
   r s" Dir/a.txt" ar THERE? TTRUE
   j ar JOURNAL:PENDING-PLANS {: pending :}
   pending VEC:COUNT 1 T=
   pending 0 PLAN-PATH$ s" other.txt" T$=
   j JOURNAL:CLOSE ;

: RESOLVE-CASE-COLLISION-RENAMES-ONE-SPELLING ( ^ARENA:arena -- )
   {: ar :}
   s" resolve case collision renames one spelling" T-LABEL
   ar FIXTURE {: d:str r:str :}
   [: d r ar RENAMES-ONE ;] [: d TREE-GONE ;] finally ;

: KEEPS-A-REPLACED-ROOT ( str str ^ARENA:arena -- )
   {: d:str r:str ar :}
   d r ar BOUND {: j :}
   d s" old" ar TEST-CLIENT:INSIDE {: old:str :}
   r old FS:RENAME-FILE
   r FS:MAKE-DIR
   j r ar RESOLVE-CASE-COLLISION ar RESOLUTION$
   s" root-changed" T$=
   old s" dir/b.txt" ar THERE? TTRUE
   old s" dir (case variant)" ar THERE? TFALSE
   r s" dir (case variant)" ar THERE? TFALSE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 3 T=
   j JOURNAL:CLOSE ;

: RESOLVE-CASE-COLLISION-ANSWERS-A-REPLACED-ROOT ( ^ARENA:arena -- )
   {: ar :}
   s" resolve case collision answers a replaced root" T-LABEL
   ar FIXTURE {: d:str r:str :}
   [: d r ar KEEPS-A-REPLACED-ROOT ;] [: d TREE-GONE ;] finally ;

: CASE-COLLISION-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar CASE-VARIANT-NAME-SKIPS-EXISTING-SUFFIXES
   ar CASE-VARIANT-NAME-FITS-A-MAXIMUM-LENGTH-COMPONENT
   ar FILE-COPY-NAME-IS-DETERMINISTIC-AND-FITS-THE-PARENT-LIMIT
   ar CASE-VARIANT-MOVES-CONVERGE-FROM-PARENT-TO-CHILD
   ar CASE-VARIANT-SOURCE-KEEPS-THE-RECORDED-SPELLING
   ar CASE-VARIANT-SOURCE-LEAVES-UNSUPPORTED-SPELLINGS
   ar CASE-VARIANT-SOURCE-SKIPS-AN-UNSUPPORTED-COLLISION
   ar JOURNAL-FIRST-COLLISION-SKIPS-AN-UNSUPPORTED-ONE
   ar RESOLVE-CASE-COLLISION-RENAMES-ONE-SPELLING
   ar RESOLVE-CASE-COLLISION-ANSWERS-A-REPLACED-ROOT ;


\ ---- listing changes -------------------------------------------------

ARENA LISTED DROPBOX:entry

: ENTRY-AT
   ( DROPBOX:kind str str ^ARENA:arena -- ^DROPBOX:entry )
   {: kind l:str d:str ar :}
   ar LISTED-NEW {: e :}
   kind e DROPBOX-ENTRY:KIND !
   l str> SPAN:MAKE e DROPBOX-ENTRY:LOWER !
   d str> SPAN:MAKE e DROPBOX-ENTRY:DISPLAY !
   true e DROPBOX-ENTRY:DOWNLOADABLE !
   e ;

\ Rust's folder_metadata.
: FOLDER-ENTRY ( str str ^ARENA:arena -- ^DROPBOX:entry )
   {: l:str d:str ar :}
   DROPBOX-KIND:FOLDER l d ar ENTRY-AT ;

\ Rust's file_metadata: a revision and a well-formed content hash.
: FILE-ENTRY ( str str ^ARENA:arena -- ^DROPBOX:entry )
   {: l:str d:str ar :}
   DROPBOX-KIND:FILE l d ar ENTRY-AT {: e :}
   s" test-revision" str> SPAN:MAKE e DROPBOX-ENTRY:REV !
   s" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
   str> SPAN:MAKE e DROPBOX-ENTRY:CONTENT-HASH !
   e ;

: DELETED-ENTRY ( str str ^ARENA:arena -- ^DROPBOX:entry )
   {: l:str d:str ar :}
   DROPBOX-KIND:DELETED l d ar ENTRY-AT ;

: LISTING-AT ( str ^ARENA:arena -- listing-root )
   {: p:str ar :}
   p ar NEW-LISTING-ROOT ;

\ A text that grows in the arena.
: NO-TEXT ( ^ARENA:arena -- ^VEC:vector<u8> )
   ARENA:ALLOCATOR 0 [type] u8 VEC:NEW ;

: TEXT+ ( ^VEC:vector<u8> str -- )
   {: v s:str :}
   s str> {: a:^ u:n :}
   v VEC:COUNT {: at:n :}
   v at u + VEC:RESIZE
   a v at VEC:AT u BYTE-COPY ;

: TEXT>STR ( ^VEC:vector<u8> -- str )
   {: v :}
   v 0 VEC:AT v VEC:COUNT >str ;

: NO-CHANGES
   ( ^ARENA:arena -- ^VEC:vector<JOURNAL:remote-inventory-change> )
   ARENA:ALLOCATOR 0 [type] JOURNAL:remote-inventory-change VEC:NEW ;

\ The entry's changes; a mismatched entry is not logged.
: APPENDED
   ( ^DROPBOX:entry listing-root
     ^VEC:vector<JOURNAL:remote-inventory-change> ^ARENA:arena -- )
   [: 2drop ;] APPEND-ENTRY-CHANGES ;

\ The record at the key in a listing's records.
: RECORD-IN
   ( ^VEC:vector<MODEL:remote-record> MODEL:key
     -- option<MODEL:remote-record> )
   {: rs k :}
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ REMOTE-KEY k MODEL:KEY= if
         rs i VEC:AT @ OPTION:SOME unloop exit
      then
   loop
   OPTION:NONE ;

\ The observation of the record at the key in a listing's records; no
\ record fails the case.
: OBSERVED-IN
   ( ^VEC:vector<MODEL:remote-record> MODEL:key
     -- MODEL:observation<MODEL:remote> )
   RECORD-IN MATCH option
      none OF false TTRUE REMOTE-ABSENT ENDOF
      some OF REMOTE-OBSERVATION ENDOF
   ;MATCH ;

\ The record's path at the key's display bytes, else empty.
: PATH-OF
   ( ^VEC:vector<MODEL:remote-record> str ^ARENA:arena -- str )
   {: rs p:str ar :}
   rs p ar CANONICAL RECORD-IN MATCH option
      none OF s" " ENDOF
      some OF MODEL-REMOTE--RECORD:UNMAKE {: k q o :} q PATH$ ENDOF
   ;MATCH ;

\ The records' paths, each followed by "|".
: RECORD-PATHS$ ( ^VEC:vector<MODEL:remote-record> -- str )
   {: rs :}
   SB-RESET
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k q o :}
      q PATH$ SB-APPEND s" |" SB-APPEND
   loop
   SB$ ;

\ Rust's change_paths: the writes' paths, each followed by "|".
: CHANGE-PATHS
   ( ^VEC:vector<JOURNAL:remote-inventory-change> -- str )
   {: cs :}
   SB-RESET
   cs VEC:COUNT 0 ?do
      cs i VEC:AT @ CHANGE-RECORD MATCH option
         none OF ENDOF
         some OF MODEL-REMOTE--RECORD:UNMAKE {: k q o :}
            q PATH$ SB-APPEND s" |" SB-APPEND
         ENDOF
      ;MATCH
   loop
   SB$ ;

: FOLDERS-ARE-DIRECTORIES-AND-NON-DOWNLOADABLE-FILES-ARE-UNKNOWN
   ( ^ARENA:arena -- )
   {: ar :}
   s" folders_are_directories_and_non_downloadable_files_are_unknown"
   T-LABEL
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /folder" s" /Folder" ar FOLDER-ENTRY root v ar APPENDED
   s" /paper" s" /Paper" ar FILE-ENTRY {: paper :}
   false paper DROPBOX-ENTRY:DOWNLOADABLE !
   s" " str> SPAN:MAKE paper DROPBOX-ENTRY:CONTENT-HASH !
   paper root v ar APPENDED
   v ar INVENTORY-RECORDS {: rs :}
   rs VEC:COUNT 2 T=
   rs s" folder" ar CANONICAL OBSERVED-IN REMOTE-DIRECTORY
   MODEL:REMOTE-OBSERVATION= TTRUE
   rs s" paper" ar CANONICAL OBSERVED-IN
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   MODEL:REMOTE-OBSERVATION= TTRUE ;

: DIRECTORY-RECORDS-NORMALIZE-INCONSISTENT-CHILD-ANCESTOR-CASING
   ( ^ARENA:arena -- )
   {: ar :}
   s" directory_records_normalize_inconsistent_child_ancestor_casing"
   T-LABEL
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /apps" s" /apps" ar FOLDER-ENTRY root v ar APPENDED
   s" /apps/day one/entry.doentry" s" /Apps/day one/Entry.doentry"
   ar FILE-ENTRY root v ar APPENDED
   s" /apps/day one" s" /Apps/Day One" ar FOLDER-ENTRY
   root v ar APPENDED
   v ar INVENTORY-RECORDS {: rs :}
   rs s" apps" ar PATH-OF s" apps" T$=
   rs s" apps/day one" ar PATH-OF s" apps/Day One" T$=
   rs s" apps/day one/entry.doentry" ar PATH-OF
   s" apps/Day One/Entry.doentry" T$= ;

\ Rust's existing directories, Apps and Apps/Day One, in the journal.
: EXISTING ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   ar REMOTE-RECORDS {: rs :}
   rs s" Apps" REMOTE-DIRECTORY ar REMOTE+
   rs s" Apps/Day One" REMOTE-DIRECTORY ar REMOTE+
   j s" cursor" DROPBOX:>CURSOR rs
   JOURNAL:PUBLISH-REMOTE-INVENTORY ;

: DELTA-PATHS
   ( ^VEC:vector<JOURNAL:remote-inventory-change> JOURNAL:journal
     ^ARENA:arena -- str )
   NORMALIZE-INVENTORY-CHANGES CHANGE-PATHS ;

: DELTA-NEVER-RESPELLS-A-DIRECTORY-THAT-STILL-EXISTS ( ^ARENA:arena -- )
   {: ar :}
   s" delta_never_respells_a_directory_that_still_exists" T-LABEL
   ar CASE-JOURNAL {: d:str j :}
   j ar EXISTING
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /apps" s" /apps" ar FOLDER-ENTRY root v ar APPENDED
   s" /apps/day one/journal" s" /apps/day one/Journal" ar FOLDER-ENTRY
   root v ar APPENDED
   v j ar DELTA-PATHS s" Apps|Apps|Apps/Day One|Apps/Day One/Journal|" T$=
   ar NO-CHANGES {: w :}
   s" /apps/day one" s" /apps/day one" ar DELETED-ENTRY
   root w ar APPENDED
   s" /apps/day one" s" /apps/DAY ONE" ar FOLDER-ENTRY
   root w ar APPENDED
   w j ar DELTA-PATHS s" Apps|Apps/DAY ONE|" T$=
   ar NO-CHANGES {: x :}
   s" /apps" s" /apps" ar DELETED-ENTRY root x ar APPENDED
   s" /apps/day one/journal" s" /APPS/DAY ONE/Journal" ar FOLDER-ENTRY
   root x ar APPENDED
   x j ar DELTA-PATHS s" APPS|APPS/DAY ONE|APPS/DAY ONE/Journal|" T$=
   ar NO-CHANGES {: y :}
   s" /apps" s" /apps" ar FOLDER-ENTRY root y ar APPENDED
   y j ar DELTA-PATHS s" Apps|" T$=
   d j GONE ;

\ The keys a mismatched entry was handed on with, each then |.
: MISMATCHED+ ( ^DROPBOX:entry MODEL:key ^VEC:vector<u8> -- )
   {: e k t :}
   t k KEY-BYTES TEXT+ t s" |" TEXT+ ;

: LISTING-KEEPS-MISMATCHED-PATHS-UNSUPPORTED ( ^ARENA:arena -- )
   {: ar :}
   s" listing keeps mismatched paths unsupported" T-LABEL
   s" " ar LISTING-AT {: root :}
   ar NO-TEXT {: t :}
   ar NO-CHANGES {: v :}
   s" /docs" s" /Docs" ar FOLDER-ENTRY root v ar APPENDED
   s" /report.txt" s" /Different.txt" ar FILE-ENTRY
   root v ar [: t MISMATCHED+ ;] APPEND-ENTRY-CHANGES
   s" /docs/odd" s" /Docs/Even" ar FOLDER-ENTRY
   root v ar [: t MISMATCHED+ ;] APPEND-ENTRY-CHANGES
   s" /docs/good.txt" s" /Docs/Good.txt" ar FILE-ENTRY root v ar APPENDED
   t TEXT>STR s" report.txt|docs/odd|" T$=
   v ar INVENTORY-RECORDS {: rs :}
   rs RECORD-PATHS$ s" Docs|Docs/Good.txt|Docs/odd|report.txt|" T$=
   rs s" report.txt" ar CANONICAL OBSERVED-IN
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   MODEL:REMOTE-OBSERVATION= TTRUE
   rs s" docs/odd" ar CANONICAL OBSERVED-IN
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   MODEL:REMOTE-OBSERVATION= TTRUE
   s" /report.txt" s" /Gone.txt" ar DELETED-ENTRY
   root v ar [: t MISMATCHED+ ;] APPEND-ENTRY-CHANGES
   t TEXT>STR s" report.txt|docs/odd|" T$=
   v ar INVENTORY-RECORDS RECORD-PATHS$
   s" Docs|Docs/Good.txt|Docs/odd|" T$= ;

: MISMATCHED-RESTRICTED-FOLDER-DROPS-ITS-CHILDREN ( ^ARENA:arena -- )
   {: ar :}
   s" mismatched restricted folder drops its children" T-LABEL
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /docs/odd" s" /Docs/odd" ar FOLDER-ENTRY root v ar APPENDED
   s" /docs/odd/a.txt" s" /Docs/odd/A.txt" ar FILE-ENTRY
   root v ar APPENDED
   s" /docs/odd" s" /Docs/Even" ar FOLDER-ENTRY {: e :}
   true e DROPBOX-ENTRY:RESTRICTED !
   e root v ar APPENDED
   v ar INVENTORY-RECORDS {: rs :}
   rs RECORD-PATHS$ s" Docs|Docs/odd|" T$=
   rs s" docs/odd" ar CANONICAL OBSERVED-IN
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   MODEL:REMOTE-OBSERVATION= TTRUE ;

\ /U+13A0.txt, uppercase in Habu's tables, and /U+AB70.txt, its
\ lowercase, whose key is U+AB70.txt.
: UNLOWERED$ ( -- str ) S\" /\xe1\x8e\xa0.txt" ;
: LOWERED$ ( -- str ) S\" /\xea\xad\xb0.txt" ;
: LOWERED-KEY$ ( -- str ) S\" \xea\xad\xb0.txt" ;

\ Changes for /U+13A0.txt, then /U+AB70.txt, each as both its paths;
\ the keys handed on go to t.
: BOTH-SPELLINGS
   ( ^VEC:vector<u8> listing-root ^ARENA:arena
     -- ^VEC:vector<JOURNAL:remote-inventory-change> )
   {: t root ar :}
   ar NO-CHANGES {: v :}
   UNLOWERED$ UNLOWERED$ ar FILE-ENTRY
   root v ar [: t MISMATCHED+ ;] APPEND-ENTRY-CHANGES
   LOWERED$ LOWERED$ ar FILE-ENTRY
   root v ar [: t MISMATCHED+ ;] APPEND-ENTRY-CHANGES
   v ;

\ The changes' one record is at U+AB70.txt; whether it is unsupported.
: LOWERED-UNSUPPORTED?
   ( ^VEC:vector<JOURNAL:remote-inventory-change> ^ARENA:arena
     -- bool )
   {: v ar :}
   v ar INVENTORY-RECORDS {: rs :}
   rs RECORD-PATHS$ S\" \xea\xad\xb0.txt|" T$=
   rs LOWERED-KEY$ ar CANONICAL OBSERVED-IN
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   MODEL:REMOTE-OBSERVATION= ;

: TWO-SPELLINGS-SHARE-ONE-KEY ( ^ARENA:arena -- )
   {: ar :}
   s" two spellings share one key" T-LABEL
   s" " ar LISTING-AT {: root :}
   ar NO-TEXT {: t :}
   t root ar BOTH-SPELLINGS {: v :}
   v ar LOWERED-UNSUPPORTED? TFALSE
   UNLOWERED$ UNLOWERED$ ar DELETED-ENTRY
   root v ar [: t MISMATCHED+ ;] APPEND-ENTRY-CHANGES
   v ar LOWERED-UNSUPPORTED? TTRUE
   t root ar BOTH-SPELLINGS {: w :}
   LOWERED$ LOWERED$ ar DELETED-ENTRY
   root w ar [: t MISMATCHED+ ;] APPEND-ENTRY-CHANGES
   w ar INVENTORY-RECORDS VEC:COUNT 0 T=
   t TEXT>STR
   S\" \xea\xad\xb0.txt|\xea\xad\xb0.txt|\xea\xad\xb0.txt|" T$= ;

\ The configured root p refused: E-LISTING and its one line.
: ROOT-PATH-REFUSED ( str str ^ARENA:arena -- )
   {: p:str d:str ar :}
   d [: [: p ar LISTING-AT ROOT-DEPTH drop ;] E-LISTING TTHROWSQ ;]
   ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t
   s" configured Dropbox root must be empty or a normalized absolute Dropbox path"
   STR:CONTAINS? TTRUE ;

: LISTING-REJECTS-AN-INVALID-CONFIGURED-ROOT ( ^ARENA:arena -- )
   {: ar :}
   s" listing rejects an invalid configured root" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   s" a/b" d ar ROOT-PATH-REFUSED
   s" /a/" d ar ROOT-PATH-REFUSED
   s" /a//b" d ar ROOT-PATH-REFUSED
   s\" /a\xFF" d ar ROOT-PATH-REFUSED
   d FS:REMOVE-TREE ;

\ The entry e refused below the root as an invalid path: E-LISTING, its
\ one line, nothing listed; the line's text.
: ENTRY-REFUSED-AT
   ( ^DROPBOX:entry listing-root str ^ARENA:arena -- str )
   {: e root d:str ar :}
   ar NO-CHANGES {: v :}
   d [: [: e root v ar APPENDED ;] E-LISTING TTHROWSQ ;]
   ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t s" Dropbox listing contained an invalid or out-of-root path"
   STR:CONTAINS? TTRUE
   v ar INVENTORY-RECORDS VEC:COUNT 0 T=
   t ;

: ENTRY-REFUSED ( ^DROPBOX:entry str ^ARENA:arena -- str )
   {: e d:str ar :}
   e s" " ar LISTING-AT d ar ENTRY-REFUSED-AT ;

: LISTING-REJECTS-AN-ENTRY-WITHOUT-PATHS ( ^ARENA:arena -- )
   {: ar :}
   s" listing rejects an entry without paths" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   s" " s" " ar FILE-ENTRY d ar ENTRY-REFUSED {: t:str :}
   t s" `" STR:CONTAINS? TFALSE
   d FS:REMOVE-TREE ;

: LISTING-REJECTS-A-PATH-THAT-IS-NOT-UTF-8 ( ^ARENA:arena -- )
   {: ar :}
   s" listing rejects a path that is not UTF-8" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   s\" /report\xFF.txt" s\" /report\xFF.txt" ar FILE-ENTRY
   d ar ENTRY-REFUSED drop
   d FS:REMOVE-TREE ;

: LISTING-REJECTS-AN-INVALID-OR-OUT-OF-ROOT-ENTRY ( ^ARENA:arena -- )
   {: ar :}
   s" listing rejects an invalid or out-of-root entry" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   s" /a//b.txt" s" /a//b.txt" ar FILE-ENTRY d ar ENTRY-REFUSED drop
   s" /other/x" s" /other/x" ar FILE-ENTRY s" /Sync" ar LISTING-AT
   d ar ENTRY-REFUSED-AT drop
   d FS:REMOVE-TREE ;

\ The root's own entry e refused with its text t: E-LISTING, one line
\ naming t, and nothing listed after Old.
: ROOT-REFUSED ( ^DROPBOX:entry str str ^ARENA:arena -- )
   {: e t:str d:str ar :}
   s" /Sync" ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /sync/old" s" /Sync/Old" ar FOLDER-ENTRY
   root v ar APPENDED
   s" /sync/child" s" /Sync/Child" ar FOLDER-ENTRY {: child :}
   d [: [: e root v ar APPENDED
         child root v ar APPENDED ;] E-LISTING TTHROWSQ ;]
   ar LOGGED {: g:str :}
   g 10 STR:COUNT-CHAR 1 T=
   g t STR:CONTAINS? TTRUE
   v ar INVENTORY-RECORDS {: rs :}
   rs RECORD-PATHS$ s" Old|" T$=
   rs s" old" ar CANONICAL OBSERVED-IN REMOTE-DIRECTORY
   MODEL:REMOTE-OBSERVATION= TTRUE ;

: ROOT-ACCEPTED ( ^ARENA:arena -- )
   {: ar :}
   s" /Sync" ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /sync" s" /Sync" ar FOLDER-ENTRY root v ar APPENDED
   s" /sync/child" s" /Sync/Child" ar FOLDER-ENTRY
   root v ar APPENDED
   v ar INVENTORY-RECORDS RECORD-PATHS$ s" Child|" T$= ;

: LISTING-CLASSIFIES-THE-REMOTE-ROOTS-OWN-ENTRY ( ^ARENA:arena -- )
   {: ar :}
   s" listing_classifies_the_remote_roots_own_entry" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   ar ROOT-ACCEPTED
   s" /sync" s" /Sync" ar DELETED-ENTRY
   s" configured Dropbox root is unavailable" d ar ROOT-REFUSED
   s" /sync" s" /Sync" ar FOLDER-ENTRY {: r :}
   true r DROPBOX-ENTRY:RESTRICTED !
   r s" configured Dropbox root cannot be traversed completely" d ar
   ROOT-REFUSED
   s" /sync" s" /Sync" ar FILE-ENTRY
   s" configured Dropbox root is not a folder" d ar ROOT-REFUSED
   d FS:REMOVE-TREE ;

\ ---- the listing against the fake Dropbox ---------------------------

: PATHS+ ( str str -- )
   {: l:str d:str :}
   S\" ,\qpath_lower\q:" SB-APPEND l TEST-CLIENT:QUOTED+
   S\" ,\qpath_display\q:" SB-APPEND d TEST-CLIENT:QUOTED+ ;

\ Rust's folder_metadata, deleted_metadata and file_metadata, each
\ appended to SB.
: FOLDER-JSON+ ( str str -- )
   S\" {\q.tag\q:\qfolder\q" SB-APPEND PATHS+ s" }" SB-APPEND ;

: DELETED-JSON+ ( str str -- )
   S\" {\q.tag\q:\qdeleted\q" SB-APPEND PATHS+ s" }" SB-APPEND ;

: FILE-JSON+ ( str str str DROPBOX:hash -- )
   {: l:str d:str r:str h:DROPBOX:hash :}
   S\" {\q.tag\q:\qfile\q" SB-APPEND l d PATHS+
   S\" ,\qrev\q:" SB-APPEND r TEST-CLIENT:QUOTED+
   S\" ,\qsize\q:0,\qcontent_hash\q:" SB-APPEND
   h DROPBOX:HASH>STR TEST-CLIENT:QUOTED+ s" }" SB-APPEND ;

: COMMA+ ( -- ) s" ," SB-APPEND ;

\ The entries q appends, as a JSON array in the arena.
: ENTRIES ( [ -- ] ^ARENA:arena -- str )
   {: q ar :}
   SB-RESET s" [" SB-APPEND q execute s" ]" SB-APPEND SB$ ar ARENA:COPY ;

: PAGE ( str str bool -- )
   {: e:str k:str more:bool :}
   e k more TEST-DROPBOX:PAGE! ;

: CONTINUE$ ( -- str ) s" /2/files/list_folder/continue" ;

\ Rust's 503 answer, which only a continuation gets.
: UNAVAILABLE! ( -- )
   CONTINUE$ 503 s" " s" "
   S\" {\qerror\q:{\q.tag\q:\qother\q}}" TEST-DROPBOX:ROUTE-SCRIPT! ;

\ Rust's Old.txt at rev-old with the identity h.
: OLD-RECORD ( DROPBOX:hash ^ARENA:arena -- MODEL:remote-record )
   {: h:DROPBOX:hash ar :}
   s" old.txt" ar CANONICAL s" Old.txt" TEST-CLIENT:DISPLAY
   h s" rev-old" DROPBOX:>REV MODEL-REMOTE:MAKE REMOTE-PRESENT
   MODEL-REMOTE--RECORD:MAKE ;

\ The journal's inventory: the record o, published with the cursor.
: PUBLISHED
   ( JOURNAL:journal str MODEL:remote-record ^ARENA:arena -- )
   {: j k:str o ar :}
   ar REMOTE-RECORDS {: rs :} o rs VEC:PUSH !
   j k DROPBOX:>CURSOR rs JOURNAL:PUBLISH-REMOTE-INVENTORY ;

: CURSOR-IS? ( option<DROPBOX:cursor> str -- bool )
   {: a:str :}
   MATCH option
      none OF false ENDOF
      some OF DROPBOX:CURSOR>STR a STR:= ENDOF
   ;MATCH ;

: KIND$ ( MODEL:observation<MODEL:remote> -- str )
   MATCH MODEL:observation
      present OF drop s" present" ENDOF
      directory OF s" directory" ENDOF
      absent OF s" absent" ENDOF
      unknown OF drop s" unknown" ENDOF
   ;MATCH ;

\ Rust's observation: the kind of the record at the display path, else
\ none.
: OBSERVED$ ( ^VEC:vector<MODEL:remote-record> str -- str )
   {: rs p:str :}
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k q o :}
      q PATH$ p STR:= if o KIND$ unloop exit then
   loop
   s" none" ;

: REFRESHED ( JOURNAL:journal ^REPLAY:link ^ARENA:arena -- )
   {: j l ar :}
   j l s" " ar LISTING-AT ar REFRESH-INVENTORY ;

\ The journal's one record is o, with the cursor k.
: KEPT ( JOURNAL:journal str MODEL:remote-record ^ARENA:arena -- )
   {: j k:str o ar :}
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   cur k CURSOR-IS? TTRUE
   rs VEC:COUNT 1 T=
   rs 0 VEC:AT @ o MODEL:REMOTE-RECORD= TTRUE ;

: CURSOR-RESET-REBUILDS-BEFORE-ONE-COMPLETE-PUBLICATION
   ( ^ARENA:arena -- )
   {: ar :}
   s" cursor_reset_rebuilds_before_one_complete_publication" T-LABEL
   TEST-DROPBOX:RESET
   s" replacement" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   j s" stale" s" old" DROPBOX:>HASH ar OLD-RECORD ar
   PUBLISHED
   TEST-DROPBOX:PAGE-RESET!
   [: s" /folder" s" /Folder" FOLDER-JSON+ ;] ar ENTRIES
   s" fresh-a" true PAGE
   [: s" /new.txt" s" /New.txt" s" rev-new" h FILE-JSON+ ;] ar ENTRIES
   s" fresh-b" false PAGE
   j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   cur s" fresh-b" CURSOR-IS? TTRUE
   rs s" Old.txt" OBSERVED$ s" none" T$=
   rs s" New.txt" OBSERVED$ s" present" T$=
   rs s" Folder" OBSERVED$ s" directory" T$=
   \ Rust's RebuiltAfterCursorReset: the reset, then a full listing.
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder /2/files/list_folder/continue"
   T$=
   d j GONE ;

: FAILED-REBUILD-AFTER-CURSOR-RESET-PRESERVES-DURABLE-INVENTORY
   ( ^ARENA:arena -- )
   {: ar :}
   s" failed_rebuild_after_cursor_reset_preserves_durable_inventory"
   T-LABEL
   TEST-DROPBOX:RESET
   s" durable old bytes" ar IDENTITY ar OLD-RECORD {: old :}
   s" uncommitted replacement" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   j s" durable-cursor" old ar PUBLISHED
   \ The continuations take the scripts in order; list_folder the page.
   CONTINUE$ 409 s" " s" "
   S\" {\qerror_summary\q:\qreset/\q,\qerror\q:{\q.tag\q:\qreset\q}}"
   TEST-DROPBOX:ROUTE-SCRIPT!
   UNAVAILABLE!
   [: s" /replacement.txt" s" /Replacement.txt" s" rev-partial" h
      FILE-JSON+ ;] ar ENTRIES
   s" fresh-partial" true PAGE
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: l :}
   [: j l ar REFRESHED ;] REPLAY:E-DROPBOX TTHROWSQ
   l REPLAY-LINK:REPLY @ TEST-CLIENT:RETRY? TTRUE
   j s" durable-cursor" old ar KEPT
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder /2/files/list_folder/continue"
   T$=
   d j GONE ;

: TREE-JSON+ ( str str DROPBOX:hash -- )
   {: l:str d:str h:DROPBOX:hash :}
   l d s" tree-revision" h FILE-JSON+ ;

: LISTING-APPLIES-ORDERED-TREE-MUTATIONS-ACROSS-PAGES
   ( ^ARENA:arena -- )
   {: ar :}
   s" listing_applies_ordered_tree_mutations_across_pages" T-LABEL
   TEST-DROPBOX:RESET
   s" tree payload" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   [: s" /node" s" /Node" FOLDER-JSON+ COMMA+
      s" /node/child" s" /Node/Child" h TREE-JSON+ COMMA+
      s" /gone" s" /Gone" FOLDER-JSON+ COMMA+
      s" /gone/child" s" /Gone/Child" h TREE-JSON+ COMMA+
      s" /ancestor" s" /Ancestor" h TREE-JSON+ COMMA+
      s" /keep/child" s" /Keep/Child" h TREE-JSON+ ;] ar ENTRIES
   s" tree-a" true PAGE
   [: s" /node" s" /Node" h TREE-JSON+ COMMA+
      s" /gone" s" /Gone" DELETED-JSON+ COMMA+
      s" /ancestor/leaf" s" /Ancestor/Leaf" h TREE-JSON+ COMMA+
      s" /keep" s" /Keep" FOLDER-JSON+ COMMA+
      s" /phantom/leaf" s" /Phantom/Leaf" DELETED-JSON+ ;] ar ENTRIES
   s" tree-b" false PAGE
   j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   rs VEC:COUNT 5 T=
   rs s" Node" OBSERVED$ s" present" T$=
   rs s" Node/Child" OBSERVED$ s" none" T$=
   rs s" Gone" OBSERVED$ s" none" T$=
   rs s" Gone/Child" OBSERVED$ s" none" T$=
   rs s" Ancestor" OBSERVED$ s" directory" T$=
   rs s" Keep" OBSERVED$ s" directory" T$=
   rs s" Ancestor/Leaf" OBSERVED$ s" present" T$=
   rs s" Keep/Child" OBSERVED$ s" present" T$=
   rs s" Phantom" OBSERVED$ s" none" T$=
   \ Rust's Published: one full listing.
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/list_folder/continue" T$=
   d j GONE ;

: FAILED-LATER-PAGE-CANNOT-PUBLISH-PARTIAL-LISTING-AS-ABSENCE
   ( ^ARENA:arena -- )
   {: ar :}
   s" failed_later_page_cannot_publish_partial_listing_as_absence"
   T-LABEL
   TEST-DROPBOX:RESET
   s" changed" ar IDENTITY {: h:DROPBOX:hash :}
   s" durable-old" DROPBOX:>HASH ar OLD-RECORD {: old :}
   ar CASE-JOURNAL {: d:str j :}
   j s" durable-cursor" old ar PUBLISHED
   [: s" /old.txt" s" /Old.txt" s" rev-changed" h FILE-JSON+ ;] ar ENTRIES
   {: e:str :}
   \ Both pages are continuations, so the first is a script too.
   SB-RESET S\" {\qentries\q:" SB-APPEND e SB-APPEND
   S\" ,\qcursor\q:\qnext\q,\qhas_more\q:true}" SB-APPEND
   CONTINUE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT!
   UNAVAILABLE!
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: l :}
   [: j l ar REFRESHED ;] REPLAY:E-DROPBOX TTHROWSQ
   l REPLAY-LINK:REPLY @ TEST-CLIENT:RETRY? TTRUE
   j s" durable-cursor" old ar KEPT
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   d j GONE ;

\ ---- the listing against the fake Dropbox: large and partial pages --

20000 constant BULK-SIZE
2000 constant BULK-PAGE-SIZE
BULK-SIZE BULK-PAGE-SIZE / constant BULK-PAGES
\ Rust's bound: a linear listing takes about 1 s, a quadratic one 13 s.
5000000000 constant LISTING-BOUND-NS

\ Rust's RemoteObservationRecord at the display path.
: RECORD-AT
   ( str MODEL:observation<MODEL:remote> ^ARENA:arena
     -- MODEL:remote-record )
   {: p:str o ar :}
   p ar CANONICAL p TEST-CLIENT:DISPLAY o MODEL-REMOTE--RECORD:MAKE ;

: STALE ( -- MODEL:observation<MODEL:remote> )
   MODEL-UNKNOWN--REASON:STALE REMOTE-UNKNOWN ;

: PRESENT-AT
   ( DROPBOX:hash str -- MODEL:observation<MODEL:remote> )
   {: h:DROPBOX:hash r:str :}
   h r DROPBOX:>REV MODEL-REMOTE:MAKE REMOTE-PRESENT ;

\ Rust's {index:05}, appended to SB.
: INDEX+ ( n -- )
   {: x:n :}
   10000 begin dup 0 > while
      x over / 10 mod [char] 0 + SB-APPEND-C 10 /
   repeat drop ;

\ The bulk name at the index below the prefix: <prefix>/00042.txt.
: BULK$ ( str n -- str )
   {: p:str x:n :}
   SB-RESET p SB-APPEND s" /" SB-APPEND x INDEX+
   s" .txt" SB-APPEND SB$ ;

\ Rust's large inventory: Bulk, then Bulk/00001.txt on at rev-old with
\ the identity h, u records in all.
: BULK-RECORDS
   ( DROPBOX:hash n ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: h:DROPBOX:hash u:n ar :}
   ar REMOTE-RECORDS {: rs :}
   s" Bulk" REMOTE-DIRECTORY ar RECORD-AT rs VEC:PUSH !
   u 1 ?do
      s" Bulk" i BULK$ ar ARENA:COPY h s" rev-old" PRESENT-AT
      ar RECORD-AT rs VEC:PUSH !
   loop
   rs ;

\ Rust's observation: the record at the display path is o.
: OBSERVED?
   ( ^VEC:vector<MODEL:remote-record> str
     MODEL:observation<MODEL:remote> -- bool )
   {: rs p:str o :}
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k q w :}
      q PATH$ p STR:= if w o MODEL:REMOTE-OBSERVATION= unloop exit then
   loop
   false ;

\ The journal's inventory, sorted by key as Rust sorts it, is the
\ cursor k and the records want.
: HOLDS
   ( JOURNAL:journal str ^VEC:vector<MODEL:remote-record>
     ^ARENA:arena -- )
   {: j k:str want ar :}
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   cur k CURSOR-IS? TTRUE
   rs VEC:COUNT want VEC:COUNT T=
   rs VEC:COUNT want VEC:COUNT min 0 ?do
      rs i VEC:AT @ want i VEC:AT @ MODEL:REMOTE-RECORD= TTRUE
   loop ;

\ Rust's large listing's entry at the index: the folder /bulk, then
\ /bulk/00001.txt on at rev-bulk with the identity h; in SB.
: BULK-ENTRY ( n DROPBOX:hash ^ARENA:arena -- str )
   {: x:n h:DROPBOX:hash ar :}
   x 0= if SB-RESET s" /bulk" s" /Bulk" FOLDER-JSON+ SB$ exit then
   s" /bulk" x BULK$ ar ARENA:COPY {: l:str :}
   s" /Bulk" x BULK$ ar ARENA:COPY {: d:str :}
   SB-RESET l d s" rev-bulk" h FILE-JSON+ SB$ ;

\ Rust's page k of the large listing: its entries' JSON array.
: BULK-PAGE ( n DROPBOX:hash ^ARENA:arena -- str )
   {: k:n h:DROPBOX:hash ar :}
   k BULK-PAGE-SIZE * {: from:n :}
   ar NO-TEXT {: v :}
   v s" [" TEXT+
   from BULK-PAGE-SIZE + from ?do
      i from <> if v s" ," TEXT+ then
      v i h ar BULK-ENTRY TEXT+
   loop
   v s" ]" TEXT+
   v TEXT>STR ;

\ The fake's pages: the large listing's, cursor-0 on.
: BULK-PAGES! ( DROPBOX:hash ^ARENA:arena -- )
   {: h:DROPBOX:hash ar :}
   BULK-PAGES 0 ?do
      i h ar BULK-PAGE
      SB-RESET s" cursor-" SB-APPEND i FMT:SB-INT SB$
      i 1+ BULK-PAGES < PAGE
   loop ;

\ A full listing's requests: list_folder, then its continuations.
: LISTED$ ( n -- str )
   {: u:n :}
   SB-RESET s" /2/files/list_folder" SB-APPEND
   u 1 ?do s"  " SB-APPEND CONTINUE$ SB-APPEND loop
   SB$ ;

\ Rust's incomplete_file_metadata: downloadable, with no content hash.
: INCOMPLETE-JSON+ ( str str str -- )
   {: l:str d:str r:str :}
   S\" {\q.tag\q:\qfile\q" SB-APPEND l d PATHS+
   S\" ,\qrev\q:" SB-APPEND r TEST-CLIENT:QUOTED+
   S\" ,\qsize\q:0,\qis_downloadable\q:true}" SB-APPEND ;

\ Rust's restricted_folder_metadata with traverse_only.
: TRAVERSE-ONLY-JSON+ ( str str -- )
   S\" {\q.tag\q:\qfolder\q" SB-APPEND PATHS+
   S\" ,\qsharing_info\q:{\qread_only\q:false," SB-APPEND
   S\" \qtraverse_only\q:true}}" SB-APPEND ;

: ONE-FILE-CURSOR-DELTA-UPDATES-A-LARGE-INVENTORY-WITHOUT-A-FULL-LISTING
   ( ^ARENA:arena -- )
   {: ar :}
   s" one_file_cursor_delta_updates_a_large_inventory_without_a_full_listing"
   T-LABEL
   TEST-DROPBOX:RESET
   s" old inventory bytes" ar IDENTITY {: old:DROPBOX:hash :}
   s" new inventory bytes" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   j s" cursor-old" DROPBOX:>CURSOR old 10000 ar BULK-RECORDS
   JOURNAL:PUBLISH-REMOTE-INVENTORY
   [: s" /bulk/05000.txt" s" /Bulk/05000.txt" s" rev-new" h
      FILE-JSON+ ;] ar ENTRIES
   s" cursor-new" false PAGE
   j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   cur s" cursor-new" CURSOR-IS? TTRUE
   rs VEC:COUNT 10000 T=
   rs s" Bulk/05000.txt" h s" rev-new" PRESENT-AT OBSERVED? TTRUE
   \ Rust's Published: one continuation and no full listing.
   TEST-DROPBOX:SEEN$ CONTINUE$ T$=
   d j GONE ;

: LARGE-FULL-LISTING-BUILDS-ITS-INVENTORY-IN-LINEAR-TIME
   ( ^ARENA:arena -- )
   {: ar :}
   s" large_full_listing_builds_its_inventory_in_linear_time" T-LABEL
   TEST-DROPBOX:RESET
   s" bulk listing bytes" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   h ar BULK-PAGES!
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: l :}
   TIME:MONO-NS {: t0:n :}
   j l ar REFRESHED
   TIME:MONO-NS t0 - {: took:n :}
   s" a " type BULK-SIZE FMT:.INT s" -entry listing took " type
   took 1000000 / FMT:.INT s"  ms" type cr
   took LISTING-BOUND-NS < TTRUE
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   rs VEC:COUNT BULK-SIZE T=
   rs s" Bulk/19999.txt" h s" rev-bulk" PRESENT-AT OBSERVED? TTRUE
   \ Rust's Published: one full listing.
   TEST-DROPBOX:SEEN$ BULK-PAGES LISTED$ T$=
   d j GONE ;

: INCOMPLETE-DOWNLOADABLE-METADATA-PUBLISHES-AS-UNKNOWN-INCOMPLETE
   ( ^ARENA:arena -- )
   {: ar :}
   s" incomplete_downloadable_metadata_publishes_as_unknown_incomplete"
   T-LABEL
   TEST-DROPBOX:RESET
   s" validated first page" ar IDENTITY {: h:DROPBOX:hash :}
   s" Old.txt" STALE ar RECORD-AT {: old :}
   ar CASE-JOURNAL {: d:str j :}
   j s" durable" old ar PUBLISHED
   [: s" /partial.txt" s" /Partial.txt" s" rev-partial" h
      FILE-JSON+ ;] ar ENTRIES
   s" partial" true PAGE
   [: s" /incomplete.txt" s" /Incomplete.txt" s" rev-incomplete"
      INCOMPLETE-JSON+ ;] ar ENTRIES
   s" new" false PAGE
   j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED
   ar REMOTE-RECORDS {: want :}
   s" Incomplete.txt" MODEL-UNKNOWN--REASON:INCOMPLETE REMOTE-UNKNOWN
   ar RECORD-AT want VEC:PUSH !
   old want VEC:PUSH !
   s" Partial.txt" h s" rev-partial" PRESENT-AT ar RECORD-AT
   want VEC:PUSH !
   j s" new" want ar HOLDS
   \ Rust's Published: the delta's two pages.
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   d j GONE ;

: RESTRICTED-LATER-PAGE-PUBLISHES-AS-UNKNOWN-INACCESSIBLE
   ( ^ARENA:arena -- )
   {: ar :}
   s" restricted_later_page_publishes_as_unknown_inaccessible" T-LABEL
   TEST-DROPBOX:RESET
   s" partial tree" ar IDENTITY {: h:DROPBOX:hash :}
   s" Durable.txt" STALE ar RECORD-AT {: durable :}
   ar CASE-JOURNAL {: d:str j :}
   j s" durable" durable ar PUBLISHED
   [: s" /partial.txt" s" /Partial.txt" s" partial-revision" h
      FILE-JSON+ ;] ar ENTRIES
   s" partial" true PAGE
   [: s" /restricted" s" /Restricted" TRAVERSE-ONLY-JSON+ ;] ar ENTRIES
   s" restricted" false PAGE
   j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED
   ar REMOTE-RECORDS {: want :}
   durable want VEC:PUSH !
   s" Partial.txt" h s" partial-revision" PRESENT-AT ar RECORD-AT
   want VEC:PUSH !
   s" Restricted" MODEL-UNKNOWN--REASON:INACCESSIBLE REMOTE-UNKNOWN
   ar RECORD-AT want VEC:PUSH !
   j s" restricted" want ar HOLDS
   \ Rust's Published: the delta's two pages.
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   d j GONE ;

: MISMATCHED-ENTRY-PUBLISHES-AS-UNSUPPORTED ( ^ARENA:arena -- )
   {: ar :}
   s" mismatched entry publishes as unsupported" T-LABEL
   TEST-DROPBOX:RESET
   s" good bytes" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   [: s" /good.txt" s" /Good.txt" s" rev-good" h FILE-JSON+ COMMA+
      s" /report.txt" s" /Different.txt" s" rev-odd" h FILE-JSON+ ;]
   ar ENTRIES s" first" false PAGE
   [: s" /report.txt" s" /Different.txt" s" rev-odd" h FILE-JSON+ ;]
   ar ENTRIES s" second" false PAGE
   d [: j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED
        j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED ;]
   ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t s" `/Different.txt` does not fold to `/report.txt`"
   STR:CONTAINS? TTRUE
   ar REMOTE-RECORDS {: want :}
   s" Good.txt" h s" rev-good" PRESENT-AT ar RECORD-AT want VEC:PUSH !
   s" report.txt" MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   ar RECORD-AT want VEC:PUSH !
   j s" second" want ar HOLDS
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/list_folder/continue" T$=
   d j GONE ;

\ /U+13A0.txt, in SB as JSON at the revision r.
: UNLOWERED-JSON+ ( str DROPBOX:hash -- )
   {: r:str h:DROPBOX:hash :}
   S\" /\xe1\x8e\xa0.txt" S\" /\xe1\x8e\xa0.txt" r h FILE-JSON+ ;

\ The journal holds Old.txt and U+AB70.txt unsupported, with the
\ cursor k.
: UNLOWERED-HELD
   ( JOURNAL:journal str MODEL:remote-record ^ARENA:arena -- )
   {: j k:str old ar :}
   ar REMOTE-RECORDS {: want :}
   old want VEC:PUSH !
   LOWERED-KEY$ MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   ar RECORD-AT want VEC:PUSH !
   j k want ar HOLDS ;

: UNLOWERED-PATH-PUBLISHES-AT-ITS-FOLD ( ^ARENA:arena -- )
   {: ar :}
   s" unlowered path publishes at its fold" T-LABEL
   TEST-DROPBOX:RESET
   s" cherokee bytes" ar IDENTITY {: h:DROPBOX:hash :}
   s" Old.txt" STALE ar RECORD-AT {: old :}
   ar CASE-JOURNAL {: d:str j :}
   j s" durable" old ar PUBLISHED
   [: s" rev-a" h UNLOWERED-JSON+ ;] ar ENTRIES s" first" false PAGE
   [: s" rev-b" h UNLOWERED-JSON+ ;] ar ENTRIES s" second" false PAGE
   d [: j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED
        j s" first" old ar UNLOWERED-HELD
        j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED ;]
   ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t S\" `/\xe1\x8e\xa0.txt` is not its own lowercase; it is kept"
   STR:CONTAINS? TTRUE
   j s" second" old ar UNLOWERED-HELD
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder/continue" T$=
   d j GONE ;

: MISMATCH-LOGGED-ONCE-AFTER-A-FAILED-PAGE ( ^ARENA:arena -- )
   {: ar :}
   s" mismatch logged once after a failed page" T-LABEL
   TEST-DROPBOX:RESET
   s" odd bytes" ar IDENTITY {: h:DROPBOX:hash :}
   s" Old.txt" STALE ar RECORD-AT {: old :}
   ar CASE-JOURNAL {: d:str j :}
   j s" durable" old ar PUBLISHED
   [: s" /report.txt" s" /Different.txt" s" rev-odd" h FILE-JSON+ ;]
   ar ENTRIES {: e:str :}
   SB-RESET S\" {\qentries\q:" SB-APPEND e SB-APPEND
   S\" ,\qcursor\q:\qnext\q,\qhas_more\q:true}" SB-APPEND
   CONTINUE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT!
   UNAVAILABLE!
   e s" second" false PAGE
   d [: [: j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED ;]
        REPLAY:E-DROPBOX TTHROWSQ
        j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED ;]
   ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t s" `/Different.txt` does not fold to `/report.txt`"
   STR:CONTAINS? TTRUE
   ar REMOTE-RECORDS {: want :}
   old want VEC:PUSH !
   s" report.txt" MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   ar RECORD-AT want VEC:PUSH !
   j s" second" want ar HOLDS
   d j GONE ;

: EXTRA-COMPONENT-PUBLISHES-AS-UNSUPPORTED ( ^ARENA:arena -- )
   {: ar :}
   s" extra component publishes as unsupported" T-LABEL
   TEST-DROPBOX:RESET
   s" good bytes" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   [: s" /good.txt" s" /Good.txt" s" rev-good" h FILE-JSON+ COMMA+
      s" /report.txt" s" /Extra/Report.txt" s" rev-odd" h FILE-JSON+ ;]
   ar ENTRIES s" first" false PAGE
   d [: j TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK ar REFRESHED ;]
   ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t s" `/Extra/Report.txt` does not fold to `/report.txt`"
   STR:CONTAINS? TTRUE
   ar REMOTE-RECORDS {: want :}
   s" Good.txt" h s" rev-good" PRESENT-AT ar RECORD-AT want VEC:PUSH !
   s" report.txt" MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   ar RECORD-AT want VEC:PUSH !
   j s" first" want ar HOLDS
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d j GONE ;

\ The root /U+13A0, uppercase in Habu's tables.
: UNLOWERED-ROOT$ ( -- str ) S\" /\xe1\x8e\xa0" ;

: UNLOWERED-ROOT-LISTS-ITS-ENTRIES ( ^ARENA:arena -- )
   {: ar :}
   s" unlowered root lists its entries" T-LABEL
   TEST-DROPBOX:RESET
   s" cherokee root bytes" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   [: UNLOWERED-ROOT$ UNLOWERED-ROOT$ FOLDER-JSON+ COMMA+
      S\" /\xe1\x8e\xa0/a.txt" S\" /\xe1\x8e\xa0/A.txt" s" rev-a" h
      FILE-JSON+ COMMA+
      S\" /\xe1\x8e\xa0/docs" S\" /\xe1\x8e\xa0/Docs" FOLDER-JSON+ ;]
   ar ENTRIES s" first" false PAGE
   j TEST-CLIENT:MAIN @ UNLOWERED-ROOT$ ar TEST-CLIENT:NEW-LINK
   UNLOWERED-ROOT$ ar LISTING-AT ar REFRESH-INVENTORY
   ar REMOTE-RECORDS {: want :}
   s" A.txt" h s" rev-a" PRESENT-AT ar RECORD-AT want VEC:PUSH !
   s" Docs" REMOTE-DIRECTORY ar RECORD-AT want VEC:PUSH !
   j s" first" want ar HOLDS
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d j GONE ;

: REFRESH-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar CURSOR-RESET-REBUILDS-BEFORE-ONE-COMPLETE-PUBLICATION
   ar FAILED-REBUILD-AFTER-CURSOR-RESET-PRESERVES-DURABLE-INVENTORY
   ar LISTING-APPLIES-ORDERED-TREE-MUTATIONS-ACROSS-PAGES
   ar FAILED-LATER-PAGE-CANNOT-PUBLISH-PARTIAL-LISTING-AS-ABSENCE
   ar ONE-FILE-CURSOR-DELTA-UPDATES-A-LARGE-INVENTORY-WITHOUT-A-FULL-LISTING
   ar LARGE-FULL-LISTING-BUILDS-ITS-INVENTORY-IN-LINEAR-TIME
   ar INCOMPLETE-DOWNLOADABLE-METADATA-PUBLISHES-AS-UNKNOWN-INCOMPLETE
   ar RESTRICTED-LATER-PAGE-PUBLISHES-AS-UNKNOWN-INACCESSIBLE
   ar MISMATCHED-ENTRY-PUBLISHES-AS-UNSUPPORTED
   ar UNLOWERED-PATH-PUBLISHES-AT-ITS-FOLD
   ar MISMATCH-LOGGED-ONCE-AFTER-A-FAILED-PAGE
   ar EXTRA-COMPONENT-PUBLISHES-AS-UNSUPPORTED
   ar UNLOWERED-ROOT-LISTS-ITS-ENTRIES ;


\ ---- the replay step against the fake Dropbox ---------------------

4096 constant READ-CAP
READ-CAP BUFFER: READ-BUF

\ A link whose transfers a status below the directory d shows.
: STEP-LINK ( str ^ARENA:arena -- ^REPLAY:link )
   {: d:str ar :}
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: l :}
   d ar STATUS:NEW l REPLAY-LINK:STATUS !
   l ;

\ A case's directory under TMPDIR, holding root, staging and a journal
\ bound to the root, and a pass over them with its own watch in ar.
: STEP-RUN ( ^ARENA:arena -- str ^run )
   {: ar :}
   s" reconcile-test" FS:MKTEMP-DIR ar ARENA:COPY {: d:str :}
   d s" root" ar TEST-CLIENT:INSIDE {: r:str :}
   d s" staging" ar TEST-CLIENT:INSIDE {: s:str :}
   r FS:MAKE-DIR s FS:MAKE-DIR
   d s" journal.sqlite3" ar TEST-CLIENT:INSIDE JOURNAL:OPEN {: j :}
   j r JOURNAL:INSPECT ar JOURNAL:ACTIVATE-LOCAL-ROOT drop
   ar RUNS-NEW {: x :}
   j x RUN-JOURNAL ! d ar STEP-LINK x RUN-LINK !
   ar LOCAL:NEW-WATCH x RUN-WATCH !
   r x RUN-ROOT ! s x RUN-STAGING ! ar x RUN-ARENA !
   d x ;

\ Removes the case: its watch goes blind, closing its inotify instance,
\ then its journal closes and its directory goes.
: STEP-GONE ( str ^run -- )
   {: d:str x :}
   x RUN-JOURNAL @ x RUN-WATCH @ LOCAL:WATCH-DOUBT
   d x RUN-JOURNAL @ GONE ;

: PENDING-OF ( ^run -- ^VEC:vector<JOURNAL:plan-record> )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:PENDING-PLANS ;

: BLOCKED-OF ( ^run -- ^VEC:vector<JOURNAL:plan-record> )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:BLOCKED-PLANS ;

: WRITTEN ( JOURNAL:plan-write -- JOURNAL:plan-record bool )
   MATCH JOURNAL:plan-write
      recorded OF true ENDOF
      already-live OF false ENDOF
   ;MATCH ;

\ Rust's plan(Absent, ConfirmedAbsent, Present(remote), Empty): one
\ install-local operation, recorded pending at path a.
: INSTALLING ( ^run str MODEL:remote -- JOURNAL:plan-record )
   {: x a:str rem :}
   x RUN-ARENA @ {: ar :}
   rem MODEL-OPERATION:INSTALL-LOCAL ar TEST-CLIENT:ONE-PLAN {: plan :}
   x RUN-JOURNAL @ a TEST-CLIENT:DISPLAY plan ar JOURNAL:RECORD-PLAN
   WRITTEN TTRUE ;

: NUMBERED ( str n ^ARENA:arena -- str )
   {: a:str k:n ar :}
   SB-RESET a SB-APPEND k FMT:SB-INT SB$ ar ARENA:COPY ;

\ The fake's file /<p> at rev v with b's identity and size.
: FILE-AT ( str str str ^ARENA:arena -- )
   {: p:str v:str b:str ar :}
   b ar IDENTITY DROPBOX:HASH>STR {: h:str :}
   SB-RESET s" /" SB-APPEND p SB-APPEND SB$ ar ARENA:COPY {: l:str :}
   l l v h b str> nip TEST-DROPBOX:FILE! ;

\ The fake serves b as rev v of /<p>.
: SERVES ( str str str ^ARENA:arena -- )
   {: p:str v:str b:str ar :}
   p v b ar FILE-AT
   v b TEST-DROPBOX:CONTENT! ;

: DOWNLOAD$ ( -- str ) s" /2/files/download" ;

: REPORTED ( replay-step -- ^REPLAY:replay-report )
   MATCH replay-step
      root-changed OF s" the replay step lost its root" TEST-CLIENT:FAILED ENDOF
      report OF ENDOF
   ;MATCH ;

: STEPPED ( ^run -- ) REPLAY-STEP REPORTED drop ;

: COMPLETED ( ^REPLAY:replay-report -- n )
   REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS @ ;

\ A blockage's variant, then an unavailable download's status, in SB.
: REASON+ ( MODEL:blockage -- )
   MATCH MODEL:blockage
      unsupported-file-size OF s" unsupported-file-size" SB-APPEND ENDOF
      remote-rejected OF drop s" remote-rejected" SB-APPEND ENDOF
      download-unavailable OF {: st:n :}
         s" download-unavailable " SB-APPEND st FMT:SB-INT
      ENDOF
      download-verification-failed OF
         s" download-verification-failed" SB-APPEND
      ENDOF
      stage-occupied OF s" stage-occupied" SB-APPEND ENDOF
      local-object-in-way OF s" local-object-in-way" SB-APPEND ENDOF
      remote-object OF s" remote-object" SB-APPEND ENDOF
      conflict-copy-occupied OF
         s" conflict-copy-occupied" SB-APPEND
      ENDOF
   ;MATCH ;

\ A plan's status: pending, completed, or the reason it is blocked.
: HELD-FOR$ ( JOURNAL:plan-record -- str )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   SB-RESET
   s MATCH JOURNAL:plan-status
      pending OF s" pending" SB-APPEND ENDOF
      blocked OF drop REASON+ ENDOF
      completed OF s" completed" SB-APPEND ENDOF
   ;MATCH SB$ ;

\ A report entry in SB: durable-plan <path> <reason>, or
\ stage-destination-occupied <plan id> <stage>, else its variant.
: BLOCKED+ ( REPLAY:replay-blocked -- )
   MATCH REPLAY:replay-blocked
      durable-plan OF {: p why :}
         s" durable-plan " SB-APPEND p PATH$ SB-APPEND
         s"  " SB-APPEND why REASON+
      ENDOF
      local-object OF drop s" local-object" SB-APPEND ENDOF
      fresh-observation-required OF
         drop s" fresh-observation-required" SB-APPEND
      ENDOF
      download-required OF drop drop s" download-required" SB-APPEND ENDOF
      stage-destination-occupied OF {: id p:str :}
         s" stage-destination-occupied " SB-APPEND
         id JOURNAL:PLAN-ID>N FMT:SB-INT
         s"  " SB-APPEND p SB-APPEND
      ENDOF
      precondition-changed OF
         drop drop s" precondition-changed" SB-APPEND
      ENDOF
      remote-operation OF drop s" remote-operation" SB-APPEND ENDOF
      remote-pending OF drop s" remote-pending" SB-APPEND ENDOF
      remote-object OF drop s" remote-object" SB-APPEND ENDOF
      sync-error OF drop drop s" sync-error" SB-APPEND ENDOF
   ;MATCH ;

\ Whether the report holds the entry e, which is not in SB.
: REPORTS? ( ^REPLAY:replay-report str -- bool )
   {: rep e:str :}
   rep BLOCKS {: bs :}
   bs VEC:COUNT 0 ?do
      SB-RESET bs i VEC:AT @ BLOCKED+
      SB$ e STR:= if true unloop exit then
   loop
   false ;

\ The reply's variant, then a retry's wait, else 0.
: REPLY$ ( DROPBOX:reply -- str n )
   MATCH DROPBOX:reply
      done OF s" done" 0 ENDOF
      refused OF drop s" refused" 0 ENDOF
      retry OF {: ms:n :} s" retry" ms ENDOF
      unlinked OF s" unlinked" 0 ENDOF
   ;MATCH ;

: MISMATCH$ ( -- str ) s" correct body with mismatched metadata" ;

\ Rust's wrong_revision: the bytes answered as another rev.
: MISREVISED ( ^ARENA:arena -- )
   {: ar :}
   s" mismatch.txt" s" different-revision" MISMATCH$ ar SERVES
   s" different-revision" TEST-DROPBOX:MISFILE ;

: UNPARSABLE ( -- )
   DOWNLOAD$ 200 s" Dropbox-API-Result" s" {invalid metadata"
   MISMATCH$ TEST-DROPBOX:ROUTE-SCRIPT! ;

: FUTURE-ERROR ( -- )
   DOWNLOAD$ 409 s" " s" "
   S\" {\qerror_summary\q:\qfuture/...\q,\qerror\q:{\q.tag\q:\qfuture_download_error\q}}"
   TEST-DROPBOX:ROUTE-SCRIPT! ;

\ The answer q scripts blocks mismatch.txt durably for the reason w,
\ and a second step sends nothing.
: BLOCKS-MISMATCH ( [ -- ] str ^ARENA:arena -- )
   {: q w:str ar :}
   TEST-DROPBOX:RESET q execute
   ar STEP-RUN {: d:str x :}
   MISMATCH$ s" expected-revision" ar REMOTE-FILE {: rem :}
   x s" mismatch.txt" rem INSTALLING drop
   SB-RESET s" durable-plan mismatch.txt " SB-APPEND w SB-APPEND
   SB$ ar ARENA:COPY {: e:str :}
   x REPLAY-STEP REPORTED e REPORTS? TTRUE
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ HELD-FOR$ w T$=
   x REPLAY-STEP REPORTED COMPLETED 0 T=
   TEST-DROPBOX:SEEN$ DOWNLOAD$ T$=
   d x STEP-GONE ;

: WORKER-VERIFICATION-MISMATCH-DURABLY-BLOCKS-ITS-PLAN
   ( ^ARENA:arena -- )
   {: ar :}
   s" worker_verification_mismatch_durably_blocks_its_plan" T-LABEL
   [: ar MISREVISED ;] s" download-verification-failed" ar
   BLOCKS-MISMATCH
   [: UNPARSABLE ;] s" download-verification-failed" ar
   BLOCKS-MISMATCH
   [: FUTURE-ERROR ;] s" download-unavailable 409" ar BLOCKS-MISMATCH ;

: RATE-LIMITED ( -- )
   DOWNLOAD$ 429 s" Retry-After" s" 7"
   S\" {\qerror_summary\q:\qtoo_many_requests/...\q,\qerror\q:{\qreason\q:{\q.tag\q:\qtoo_many_requests\q},\qretry_after\q:1}}"
   TEST-DROPBOX:ROUTE-SCRIPT! ;

: SERVER-ERROR ( -- )
   DOWNLOAD$ 500 s" " s" " s" {}" TEST-DROPBOX:ROUTE-SCRIPT! ;

\ A case's pass on the client c over a pending plan of status st's
\ file.
: GLOBAL-RUN ( ^DROPBOX:client n ^ARENA:arena -- str ^run )
   {: c st:n ar :}
   ar STEP-RUN {: d:str x :}
   c x RUN-LINK @ REPLAY-LINK:CLIENT !
   s" global-" st ar NUMBERED
   s" revision-" st ar NUMBERED ar REMOTE-FILE {: rem :}
   x s" global.txt" rem INSTALLING drop
   d x ;

\ The step ends with E-DROPBOX, the reply w with the wait ms kept in
\ the link and the plan still pending; the fake saw the requests s.
: ENDS-STEP ( ^run str n str -- )
   {: x w:str ms:n s:str :}
   [: x STEPPED ;] REPLAY:E-DROPBOX TTHROWSQ
   x RUN-LINK @ REPLAY-LINK:REPLY @ REPLY$ ms T= w T$=
   x PENDING-OF VEC:COUNT 1 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s T$= ;

\ The answer q scripts for status st ends the step.
: STAYS-GLOBAL ( [ -- ] n str n ^ARENA:arena -- )
   {: q st:n w:str ms:n ar :}
   TEST-DROPBOX:RESET q execute
   TEST-CLIENT:MAIN @ st ar GLOBAL-RUN {: d:str x :}
   x w ms DOWNLOAD$ ENDS-STEP
   d x STEP-GONE ;

\ The client c, holding its first token, refreshes on a 401 and sends
\ again once, so a revoked token ends the step unlinked.
: REVOKED ( ^DROPBOX:client ^ARENA:arena -- )
   {: c ar :}
   c TEST-CLIENT:ACCOUNT-OF
   TEST-DROPBOX:RESET TEST-DROPBOX:REVOKE
   c 401 ar GLOBAL-RUN {: d:str x :}
   x s" unlinked" 0
   s" /2/files/download /oauth2/token /2/files/download" ENDS-STEP
   d x STEP-GONE ;

\ A client of its own, so MAIN stays linked.
: UNAUTHORIZED ( ^ARENA:arena -- )
   {: ar :}
   ar TEST-CLIENT:OPENED {: c :}
   [: c ar REVOKED ;] [: c DROPBOX:CLOSE ;] finally ;

: WORKER-AUTH-RATE-LIMIT-AND-SERVER-FAILURES-REMAIN-GLOBAL
   ( ^ARENA:arena -- )
   {: ar :}
   s" worker_auth_rate_limit_and_server_failures_remain_global" T-LABEL
   ar UNAUTHORIZED
   [: RATE-LIMITED ;] 429 s" retry" 7000 ar STAYS-GLOBAL
   [: SERVER-ERROR ;] 500 s" retry" 0 ar STAYS-GLOBAL ;

: EXPECTED$ ( -- str ) s" expected download bytes" ;
: OCCUPANT$ ( -- str ) s" unrelated occupant bytes" ;

: STAGED? ( LOCAL:stage-outcome<n> -- bool )
   MATCH LOCAL:stage-outcome
      staged OF drop true ENDOF
      already-staged OF drop false ENDOF
      content-changed OF drop false ENDOF
      destination-occupied OF drop false ENDOF
   ;MATCH ;

\ Runs q on the run's root, opened as the journal's active root.
: IN-ACTIVE-ROOT ( R ^run [ R fd -- S ] -- S )
   {: x q :}
   x RUN-JOURNAL @ x ROOT$ LOCAL:OPEN-ACTIVE-ROOT MATCH option
      none OF s" test expected the run's root active" 1 die ENDOF
      some OF {: root:fd :}
         [: root q execute ;] [: root FS:CLOSE-DIR ;] finally
      ENDOF
   ;MATCH ;

\ The pipe's bytes, of identity c, staged as target t's download.
: STAGE-FROM ( fd ^run str DROPBOX:hash fd -- bool )
   {: root:fd x t:str c:DROPBOX:hash rd:fd :}
   root x ROOT$ t c [: rd -rot LOCAL:FD-READ ;] x RUN-ARENA @
   LOCAL:STAGE-DOWNLOAD-AT STAGED? ;

\ Rust's stage_download: b staged as target t's download.
: PRESTAGED ( fd ^run str str -- )
   {: root:fd x t:str b:str :}
   b x RUN-ARENA @ IDENTITY {: c:DROPBOX:hash :}
   FD:PIPE {: rd:fd w:fd :}
   w b FD:WRITE-FULL w FS:CLOSE-DIR
   [: root x t c rd STAGE-FROM TTRUE ;] [: rd FS:CLOSE-DIR ;]
   finally ;

: ONE-NAME? ( str -- bool )
   10 STR:INDEX-OF MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

\ The root's one entry, the stage PRESTAGED made.
: STAGE-PATH ( ^run -- str )
   {: x :}
   x ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str ONE-NAME? TTRUE
   READ-BUF u >str s" .omabox-download-" STR:STARTS-WITH? TTRUE
   x RUN-ROOT @ READ-BUF u >str x RUN-ARENA @ TEST-CLIENT:INSIDE ;

: HOLDS-BYTES ( str str -- )
   {: f:str b:str :}
   f READ-BUF READ-CAP FS:READ-ALL {: u:n :}
   READ-BUF u >str b T$= ;

\ The stage of occupied.txt's download, holding other bytes, and the
\ plan to install it.
: OCCUPIED ( ^run -- str JOURNAL:plan-record )
   {: x :}
   x [: x s" occupied.txt" EXPECTED$ PRESTAGED ;] IN-ACTIVE-ROOT
   x STAGE-PATH {: sp:str :}
   sp FS:REMOVE-FILE sp OCCUPANT$ FS:WRITE-ALL
   EXPECTED$ s" occupied-stage-revision" x RUN-ARENA @ REMOTE-FILE
   {: rem :}
   sp x s" occupied.txt" rem INSTALLING ;

\ Rust's StageDestinationOccupied for the plan p at the stage sp.
: OCCUPIED-ENTRY ( JOURNAL:plan-record str ^ARENA:arena -- str )
   {: p sp:str ar :}
   SB-RESET s" stage-destination-occupied " SB-APPEND
   p ID-OF JOURNAL:PLAN-ID>N FMT:SB-INT
   s"  " SB-APPEND sp SB-APPEND SB$ ar ARENA:COPY ;

: OCCUPIED-DOWNLOAD-STAGE-IS-DURABLY-BLOCKED-WITHOUT-OVERWRITE-OR-REQUEST
   ( ^ARENA:arena -- )
   {: ar :}
   s" occupied_download_stage_is_durably_blocked_without_overwrite_or_request"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   x OCCUPIED {: sp:str p :}
   p sp ar OCCUPIED-ENTRY {: e:str :}
   x REPLAY-STEP REPORTED e REPORTS? TTRUE
   sp OCCUPANT$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ HELD-FOR$ s" stage-occupied" T$=
   TEST-DROPBOX:SEEN$ s" " T$=
   d x STEP-GONE ;

5 constant DOWNLOAD-COUNT
4 constant COMPLETED-BATCH

: BATCH$ ( -- str ) s" install each bounded batch" ;

\ batch-<k>.txt and its own rev, batch-<k>.
: BATCH ( n ^ARENA:arena -- str str )
   {: k:n ar :}
   s" batch-" k ar NUMBERED {: v:str :}
   SB-RESET v SB-APPEND s" .txt" SB-APPEND SB$ ar ARENA:COPY v ;

\ The fake serves batch file k's bytes, the last's only past a byte it
\ does not keep, so its download from the start answers 500.
: BATCH-SERVED ( str str n ^ARENA:arena -- )
   {: p:str v:str k:n ar :}
   p v BATCH$ ar FILE-AT
   BATCH$ {: b:str :}
   k COMPLETED-BATCH < if v b TEST-DROPBOX:CONTENT! exit then
   v 1 b 1 b str> nip PART TEST-DROPBOX:CONTENT-TAIL! ;

\ Batch file k, served, and its pending plan.
: BATCHED ( ^run n -- )
   {: x k:n :}
   x RUN-ARENA @ {: ar :}
   k ar BATCH {: p:str v:str :}
   p v k ar BATCH-SERVED
   BATCH$ v ar REMOTE-FILE {: rem :}
   x p rem INSTALLING drop ;

\ Whether batch file k is installed, holding the batch's bytes.
: INSTALLED? ( ^run n -- bool )
   {: x k:n :}
   k x RUN-ARENA @ BATCH drop {: p:str :}
   x RUN-ROOT @ p x RUN-ARENA @ TEST-CLIENT:INSIDE {: f:str :}
   f FS:FILE? 0= if false exit then
   f BATCH$ HOLDS-BYTES true ;

: INSTALLED ( ^run -- n )
   {: x :}
   0 DOWNLOAD-COUNT 0 ?do x i INSTALLED? if 1+ then loop ;

: COMPLETED-DOWNLOAD-BATCH-IS-INSTALLED-BEFORE-THE-NEXT-BATCH-FAILS
   ( ^ARENA:arena -- )
   {: ar :}
   s" completed_download_batch_is_installed_before_the_next_batch_fails"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   DOWNLOAD-COUNT 0 ?do x i BATCHED loop
   [: x STEPPED ;] REPLAY:E-DROPBOX TTHROWSQ
   x INSTALLED COMPLETED-BATCH T=
   x PENDING-OF {: pending :}
   pending VEC:COUNT 1 T=
   x RUN-ROOT @ pending 0 PLAN-PATH$ ar TEST-CLIENT:INSIDE FS:EXISTS? TFALSE
   TEST-DROPBOX:SEEN$ DOWNLOAD-COUNT TEST-CLIENT:DOWNLOADS$ T$=
   d x STEP-GONE ;

: FALLBACK$ ( -- str ) s" fallback download" ;

\ S_IFSOCK, the file type of a socket.
$C000 constant S-IFSOCK
\ Mode 0400, read-only to its owner.
$100 constant MODE-0400
\ LOCAL's slots, 0 to 3.
4 constant SLOTS

\ The run's slot k, as LOCAL names it.
: SLOT-AT ( ^run n -- str )
   {: x k:n :}
   x RUN-ARENA @ {: ar :}
   s" .omabox-download-slot-" k ar NUMBERED {: nm:str :}
   x RUN-STAGING @ nm ar TEST-CLIENT:INSIDE ;

: UNKNOWN$ ( n ^ARENA:arena -- str )
   {: k:n ar :}
   s" unknown-" k ar NUMBERED ;

\ Rust's unknown slots: a bound socket at slot 0, files holding
\ unknown-<k> at the others, slot 1 read-only; the socket.
: UNKNOWN-SLOTS ( ^run -- fd )
   {: x :}
   SLOTS 1 ?do
      x i SLOT-AT i x RUN-ARENA @ UNKNOWN$ FS:WRITE-ALL
   loop
   x 1 SLOT-AT MODE-0400 FS:CHMOD-MODE
   x 0 SLOT-AT TEST-CLIENT:SOCKET-AT ;

\ Slot 0 is still a socket, and the others hold their bytes.
: SLOTS-KEPT ( ^run -- )
   {: x :}
   x 0 SLOT-AT FS:TRY-LSTAT TTRUE
   FS:STAT-MODE@ FS:S-IFMT and S-IFSOCK T=
   SLOTS 1 ?do
      x i SLOT-AT i x RUN-ARENA @ UNKNOWN$ HOLDS-BYTES
   loop ;

: UNKNOWN-DOWNLOAD-SLOTS-ARE-PRESERVED-WITH-DISPOSABLE-FALLBACK
   ( ^ARENA:arena -- )
   {: ar :}
   s" unknown_download_slots_are_preserved_with_disposable_fallback"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   x UNKNOWN-SLOTS {: sock:fd :}
   s" fallback.txt" s" fallback-revision" FALLBACK$ ar SERVES
   FALLBACK$ s" fallback-revision" ar REMOTE-FILE {: rem :}
   x s" fallback.txt" rem INSTALLING drop
   s" Dropbox could not be reached."
   x RUN-LINK @ REPLAY-LINK:STATUS @ STATUS:ERROR
   x REPLAY-STEP REPORTED COMPLETED 1 T=
   d s" omabox/status.json" ar TEST-CLIENT:INSIDE READ-BUF READ-CAP FS:READ-ALL
   {: u:n :}
   READ-BUF u >str S\" \qlast_error\q:null" STR:CONTAINS? TTRUE
   x RUN-ROOT @ s" fallback.txt" ar TEST-CLIENT:INSIDE FALLBACK$ HOLDS-BYTES
   x SLOTS-KEPT
   TEST-DROPBOX:SEEN$ 1 TEST-CLIENT:DOWNLOADS$ T$=
   TEST-DROPBOX:RANGE-SENT? TFALSE
   sock FS:CLOSE-DIR
   d x STEP-GONE ;

\ The root swap's paths: it runs on the fake's task.
TYPED-VARIABLE LIVE-ROOT str
TYPED-VARIABLE OLD-ROOT str
TYPED-VARIABLE CANARY str

: CANARY$ ( -- str ) s" replacement bytes" ;
: SWAPPED$ ( -- str ) s" descriptor-bound download" ;

\ Rust's swap: the root renamed old-root, and a new root holding
\ canary.txt.
: SWAP-ROOT ( -- )
   LIVE-ROOT @ OLD-ROOT @ FS:RENAME-FILE
   LIVE-ROOT @ FS:MAKE-DIR
   CANARY @ CANARY$ FS:WRITE-ALL ;

\ The swap's paths for the run x in the case directory d.
: SWAP-AT ( str ^run -- )
   {: d:str x :}
   x RUN-ARENA @ {: ar :}
   x RUN-ROOT @ LIVE-ROOT !
   d s" old-root" ar TEST-CLIENT:INSIDE OLD-ROOT !
   x RUN-ROOT @ s" canary.txt" ar TEST-CLIENT:INSIDE CANARY ! ;

: ROOT-CHANGED? ( replay-step -- bool )
   MATCH replay-step
      root-changed OF true ENDOF
      report OF drop false ENDOF
   ;MATCH ;

\ The new root holds canary.txt alone, with its bytes.
: REPLACEMENT-KEPT ( ^run -- )
   {: x :}
   x ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str s" canary.txt" T$=
   CANARY @ CANARY$ HOLDS-BYTES ;

\ Whether a name in the list starts with .omabox-download-.
: STAGE-LISTED? ( str -- bool )
   {: l:str :}
   l s" .omabox-download-" STR:STARTS-WITH? if true exit then
   l 10 STR:INDEX-OF MATCH option
      none OF false ENDOF
      some OF IDX>N 1+ {: k:n :} l k l str> nip PART RECURSE ENDOF
   ;MATCH ;

\ old-root holds no download.txt, and a download's stage.
: OLD-ROOT-STAGED ( ^ARENA:arena -- )
   {: ar :}
   OLD-ROOT @ s" download.txt" ar TEST-CLIENT:INSIDE FS:EXISTS? TFALSE
   OLD-ROOT @ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str STAGE-LISTED? TTRUE ;

: NO-BASELINE? ( ^run str -- bool )
   {: x p:str :}
   x RUN-JOURNAL @ p TEST-CLIENT:DISPLAY x RUN-ARENA @ JOURNAL:BASELINE
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: ROOT-SWAP-AFTER-REPLAY-VALIDATION-NEVER-TOUCHES-THE-REPLACEMENT
   ( ^ARENA:arena -- )
   {: ar :}
   s" root_swap_after_replay_validation_never_touches_the_replacement"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x SWAP-AT
   s" download.txt" s" root-swap-revision" SWAPPED$ ar SERVES
   SWAPPED$ s" root-swap-revision" ar REMOTE-FILE {: rem :}
   x s" download.txt" rem INSTALLING drop
   [: SWAP-ROOT ;] TEST-DROPBOX:DURING-DOWNLOAD!
   x REPLAY-STEP ROOT-CHANGED? TTRUE
   x REPLACEMENT-KEPT
   x PENDING-OF VEC:COUNT 1 T=
   x s" download.txt" NO-BASELINE? TTRUE
   ar OLD-ROOT-STAGED
   TEST-DROPBOX:SEEN$ 1 TEST-CLIENT:DOWNLOADS$ T$=
   d x STEP-GONE ;

: HELD$ ( -- str ) s" first download held open by the fake server" ;
: NEXT$ ( -- str ) s" download introduced by the next pass" ;

: GENERATION ( ^run -- n )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:LOCAL-ROOT-BINDING
   MATCH option
      none OF s" reconcile-test: the root is not bound" TEST-CLIENT:FAILED ENDOF
      some OF JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b gen:n :} gen ENDOF
   ;MATCH ;

\ The slot identity the step computes for plan p's download.
: STEP-IDENTITY
   ( ^run JOURNAL:plan-record -- LOCAL:download-slot-identity )
   {: x p :}
   x GENERATION {: gen:n :}
   p PENDING-DOWNLOAD MATCH option
      none OF s" reconcile-test: no download" TEST-CLIENT:FAILED ENDOF
      some OF {: d :} gen p PLAN-PATH d SLOT-IDENTITY ENDOF
   ;MATCH ;

\ Plan p's slot, leased as the step leases it, holding a checkpoint of
\ its content c.
: HELD-SLOT ( ^run JOURNAL:plan-record DROPBOX:hash -- )
   {: x p c:DROPBOX:hash :}
   x p STEP-IDENTITY {: id :}
   x STAGING$ id [: TEST-CLIENT:UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT TEST-CLIENT:LEASED
   {: l :}
   x [: x RUN-ROOT @ s" a.bin" c l x RUN-ARENA @ TEST-CLIENT:CHECKPOINTED ;]
   IN-ACTIVE-ROOT ;

: PLAN-BLOCKED? ( JOURNAL:plan-block -- bool )
   MATCH JOURNAL:plan-block
      not-found OF false ENDOF
      already-completed OF false ENDOF
      blocked OF true ENDOF
   ;MATCH ;

\ Plan id blocked for the reason until the second at.
: BLOCKED-UNTIL ( ^run JOURNAL:plan-id MODEL:blockage n -- )
   {: x id why at:n :}
   x RUN-JOURNAL @ id why at x RUN-ARENA @ JOURNAL:BLOCK-PLAN
   PLAN-BLOCKED? TTRUE ;

\ Holds plan p live, blocked until an hour from now.
: BLOCKED-AHEAD ( ^run JOURNAL:plan-record -- )
   {: x p :}
   x p ID-OF 503 MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE
   epoch-seconds JOURNAL:BLOCK-RETRY-SECONDS + BLOCKED-UNTIL ;

: UNBLOCKED ( ^run JOURNAL:plan-record -- )
   {: x p :}
   x RUN-JOURNAL @ p ID-OF x RUN-ARENA @ JOURNAL:UNBLOCK-PLAN
   MATCH JOURNAL:plan-unblock
      not-found OF false ENDOF
      not-blocked OF false ENDOF
      unblocked OF true ENDOF
   ;MATCH TTRUE ;

\ Plan a, served past a checkpoint, blocked, and its slot holding the
\ checkpoint; its content.
: HELD-PLAN ( ^run -- JOURNAL:plan-record DROPBOX:hash )
   {: x :}
   x RUN-ARENA @ {: ar :}
   HELD$ ar TEST-CLIENT:PAST-HASH {: c:DROPBOX:hash :}
   s" /a.bin" s" rev-held-slot" HELD$ c TEST-CLIENT:SERVES-PAST
   c s" rev-held-slot" DROPBOX:>REV MODEL-REMOTE:MAKE {: rem :}
   x s" a.bin" rem INSTALLING {: p :}
   x p BLOCKED-AHEAD
   x p c HELD-SLOT
   p c ;

\ The staging directory's one entry, the slot HELD-SLOT leased.
: HELD-SLOT-PATH ( ^run -- str )
   {: x :}
   x STAGING$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str ONE-NAME? TTRUE
   READ-BUF u >str s" .omabox-download-slot-" STR:STARTS-WITH? TTRUE
   x RUN-STAGING @ READ-BUF u >str x RUN-ARENA @ TEST-CLIENT:INSIDE ;

: IN-ROOT ( ^run str -- str )
   {: x p:str :}
   x RUN-ROOT @ p x RUN-ARENA @ TEST-CLIENT:INSIDE ;

\ Plan b pending, and one step installing it, from the start.
: NEXT-STEPPED ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   s" b.bin" s" rev-next-slot" NEXT$ ar SERVES
   NEXT$ s" rev-next-slot" ar REMOTE-FILE {: rem :}
   x s" b.bin" rem INSTALLING drop
   x STEPPED
   x s" b.bin" IN-ROOT NEXT$ HOLDS-BYTES
   TEST-DROPBOX:SEEN$ 1 TEST-CLIENT:DOWNLOADS$ T$=
   TEST-DROPBOX:RANGE-SENT? TFALSE ;

: RESUMED-RANGE ( -- )
   TEST-DROPBOX:RANGE-SENT? TTRUE
   SB-RESET s" bytes=" SB-APPEND TEST-CLIENT:CHECKPOINT FMT:SB-INT s" -" SB-APPEND
   SB$ TEST-DROPBOX:RANGE-SENT$ T$= ;

\ The file f holds content c, of size u.
: HOLDS-CONTENT ( str DROPBOX:hash n ^ARENA:arena -- )
   {: f:str c:DROPBOX:hash u:n ar :}
   f FS:FILE-SIZE u T=
   f FS:OPEN-SIZED TTRUE drop {: h:fd :}
   h ar LOCAL:DROPBOX-CONTENT-HASH h FS:CLOSE-DIR {: got:DROPBOX:hash :}
   got DROPBOX:HASH>STR c DROPBOX:HASH>STR T$= ;

\ Whether f is a file of u bytes.
: SIZED? ( str n -- bool )
   {: f:str u:n :}
   f FS:FILE? 0= if false exit then
   f FS:FILE-SIZE u = ;

\ Plan a unblocked, and a step resuming its download from its slot.
: HELD-STEPPED ( ^run JOURNAL:plan-record DROPBOX:hash -- )
   {: x p c:DROPBOX:hash :}
   x p UNBLOCKED
   x STEPPED
   x s" a.bin" IN-ROOT c TEST-CLIENT:CHECKPOINT HELD$ str> nip + x RUN-ARENA @
   HOLDS-CONTENT
   RESUMED-RANGE
   TEST-DROPBOX:SEEN$ 2 TEST-CLIENT:DOWNLOADS$ T$= ;

: LATER-PLANNED-DOWNLOAD-DOES-NOT-RECLAIM-AN-ACTIVE-SLOT
   ( ^ARENA:arena -- )
   {: ar :}
   s" later_planned_download_does_not_reclaim_an_active_slot" T-LABEL
   TEST-DROPBOX:RESET TEST-CLIENT:FILL-XS
   ar STEP-RUN {: d:str x :}
   x HELD-PLAN {: p c:DROPBOX:hash :}
   x HELD-SLOT-PATH {: slot:str :}
   x NEXT-STEPPED
   x s" a.bin" IN-ROOT FS:EXISTS? TFALSE
   slot TEST-CLIENT:CHECKPOINT SIZED? TTRUE
   x p c HELD-STEPPED
   d x STEP-GONE ;

\ The bytes legacy.txt's download installs.
: LEGACY$ ( -- str ) s" legacy download" ;

: LEGACY-PRESERVATION-BEFORE-A-DOWNLOAD-REPLAYS-ONCE ( ^ARENA:arena -- )
   {: ar :}
   s" legacy_preservation_before_a_download_replays_once" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   s" legacy.txt" s" legacy-revision" LEGACY$ ar SERVES
   s" preserved" ar IDENTITY MODEL-LOCAL:MAKE {: local :}
   LEGACY$ s" legacy-revision" ar REMOTE-FILE {: rem :}
   local MODEL-OPERATION:PRESERVE-LOCAL
   rem MODEL-OPERATION:INSTALL-LOCAL ar TWO-PLAN {: plan :}
   x RUN-JOURNAL @ s" legacy.txt" TEST-CLIENT:DISPLAY plan ar JOURNAL:RECORD-PLAN
   WRITTEN TTRUE drop
   x REPLAY-STEP REPORTED COMPLETED 2 T=
   x s" legacy.txt" IN-ROOT LEGACY$ HOLDS-BYTES
   d x STEP-GONE ;

: FETCHED$ ( -- str ) s" Dropbox bytes the install never places" ;
: WRITTEN$ ( -- str ) s" local bytes written during the download" ;

\ The install's destination the race writes; it runs on the fake's task.
TYPED-VARIABLE RACED-INSTALL str

: RACE-INSTALL ( -- ) RACED-INSTALL @ WRITTEN$ FS:WRITE-ALL ;

: RETRY-ERROR-STAYS-WHEN-NO-INSTALL-COMPLETES ( ^ARENA:arena -- )
   {: ar :}
   s" retry_error_stays_when_no_install_completes" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   s" raced.txt" s" raced-revision" FETCHED$ ar SERVES
   FETCHED$ s" raced-revision" ar REMOTE-FILE {: rem :}
   x s" raced.txt" rem INSTALLING drop
   x s" raced.txt" IN-ROOT RACED-INSTALL !
   [: RACE-INSTALL ;] TEST-DROPBOX:DURING-DOWNLOAD!
   s" Dropbox could not be reached."
   x RUN-LINK @ REPLAY-LINK:STATUS @ STATUS:ERROR
   x REPLAY-STEP REPORTED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 1 T=
   d s" omabox/status.json" ar TEST-CLIENT:INSIDE READ-BUF READ-CAP FS:READ-ALL
   {: u:n :}
   READ-BUF u >str s" Dropbox could not be reached." STR:CONTAINS? TTRUE
   x s" raced.txt" IN-ROOT WRITTEN$ HOLDS-BYTES
   d x STEP-GONE ;

: STEP-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar WORKER-VERIFICATION-MISMATCH-DURABLY-BLOCKS-ITS-PLAN
   ar WORKER-AUTH-RATE-LIMIT-AND-SERVER-FAILURES-REMAIN-GLOBAL
   ar OCCUPIED-DOWNLOAD-STAGE-IS-DURABLY-BLOCKED-WITHOUT-OVERWRITE-OR-REQUEST
   ar COMPLETED-DOWNLOAD-BATCH-IS-INSTALLED-BEFORE-THE-NEXT-BATCH-FAILS
   ar UNKNOWN-DOWNLOAD-SLOTS-ARE-PRESERVED-WITH-DISPOSABLE-FALLBACK
   ar ROOT-SWAP-AFTER-REPLAY-VALIDATION-NEVER-TOUCHES-THE-REPLACEMENT
   ar LATER-PLANNED-DOWNLOAD-DOES-NOT-RECLAIM-AN-ACTIVE-SLOT
   ar LEGACY-PRESERVATION-BEFORE-A-DOWNLOAD-REPLAYS-ONCE
   ar RETRY-ERROR-STAYS-WHEN-NO-INSTALL-COMPLETES ;

\ ---- the pass against the fake Dropbox -----------------------------

: LIST$ ( -- str ) s" /2/files/list_folder" ;
: UPLOAD-ROUTE$ ( -- str ) s" /2/files/upload" ;
: METADATA-ROUTE$ ( -- str ) s" /2/files/get_metadata" ;
: DELETE$ ( -- str ) s" /2/files/delete_v2" ;
: UPLOAD-SEEN$ ( -- str ) s" /2/files/list_folder /2/files/upload" ;
: PASS-SEEN$ ( -- str )
   s" /2/files/list_folder /2/files/download /2/files/upload" ;

: UPLOAD$ ( -- str ) s" local upload" ;
: REMOTE$ ( -- str ) s" remote download" ;

\ The pass's report; any other outcome ends the run.
: COMPLETE ( outcome -- report )
   MATCH outcome
      complete OF ENDOF
      fresh OF s" the stable fixture asked a fresh observation" TEST-CLIENT:FAILED ENDOF
      root-changed OF s" the stable fixture changed its root" TEST-CLIENT:FAILED ENDOF
   ;MATCH ;

\ The recovery directory made in the case's directory d, and the link's
\ Dropbox root set to the whole account, as every pass test needs.
: PASS-READY ( str ^run -- str )
   {: d:str x :}
   d s" recovery" x RUN-ARENA @ TEST-CLIENT:INSIDE {: rec:str :}
   rec FS:MAKE-DIR
   s" " x RUN-LINK @ REPLAY-LINK:ROOT !
   rec ;

\ PASS over the run, with the recovery directory rec.
: PASSED ( ^run str -- outcome )
   {: x rec:str :}
   x RUN-JOURNAL @ x RUN-LINK @ x RUN-WATCH @ x RUN-ROOT @ x RUN-STAGING @
   rec x RUN-ARENA @ PASS ;

\ The one listing page, cursor k: /<p> at rev v with b's identity.
: LISTED-ALONE ( str str str str ^ARENA:arena -- )
   {: p:str v:str b:str k:str ar :}
   b ar IDENTITY {: h:DROPBOX:hash :}
   SB-RESET s" /" SB-APPEND p SB-APPEND SB$ ar ARENA:COPY {: l:str :}
   [: l l v h FILE-JSON+ ;] ar ENTRIES k false PAGE ;

\ Rust's fixture: upload.txt in the root, download.txt served and on
\ the one listing page; answers the recovery directory.
: BOTH-WAYS ( str ^run -- str )
   {: d:str x :}
   x RUN-ARENA @ {: ar :}
   d x PASS-READY {: rec:str :}
   x s" upload.txt" IN-ROOT UPLOAD$ FS:WRITE-ALL
   s" download.txt" s" rev-download" REMOTE$ ar SERVES
   s" download.txt" s" rev-download" REMOTE$ s" cursor-complete" ar
   LISTED-ALONE
   rec ;

: REPORTS ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   replayed 2 T= planned 2 T= blocked 0 T= conflicts 0 T=
   rested TFALSE ;

: RESTED-IN ( report -- bool )
   RECONCILE-REPORT:UNMAKE {: r:n o:n p:n b:n e:n c:n s:bool :} s ;

\ The baseline at path p is present as rem.
: BASELINE-AT ( ^run str MODEL:remote -- )
   {: x p:str rem :}
   x RUN-JOURNAL @ p TEST-CLIENT:DISPLAY x RUN-ARENA @ JOURNAL:BASELINE
   STORED-BASELINE rem MODEL-BASELINE:PRESENT MODEL:BASELINE= TTRUE ;

\ An add upload's argument as DROPBOX writes it for b at path p, in SB.
: ADD-ARG$ ( str str ^ARENA:arena -- str )
   {: p:str b:str ar :}
   b ar IDENTITY DROPBOX:HASH>STR {: h:str :}
   SB-RESET S\" {\qpath\q:\q" SB-APPEND p SB-APPEND
   S\" \q,\qmode\q:\qadd\q,\qautorename\q:false," SB-APPEND
   S\" \qstrict_conflict\q:true,\qcontent_hash\q:\q" SB-APPEND
   h SB-APPEND S\" \q}" SB-APPEND SB$ ;

\ The last upload's argument is ADD-ARG$'s. The fake commits only a body
\ that hashes to it: Rust's body assert.
: UPLOAD-SENT ( str str ^ARENA:arena -- )
   ADD-ARG$ TEST-DROPBOX:ARG-SENT$ swap T$= ;

: ONE-RECONCILIATION-PASS-SYNCHRONIZES-FILES-IN-BOTH-DIRECTIONS
   ( ^ARENA:arena -- )
   {: ar :}
   s" one_reconciliation_pass_synchronizes_files_in_both_directions"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x BOTH-WAYS {: rec:str :}
   x rec PASSED COMPLETE REPORTS
   x REPLAY-STEP REPORTED COMPLETED 0 T=
   x s" download.txt" IN-ROOT REMOTE$ HOLDS-BYTES
   x s" download.txt" REMOTE$ s" rev-download" ar REMOTE-FILE BASELINE-AT
   x s" upload.txt" UPLOAD$ s" 01701" ar REMOTE-FILE BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   x RUN-JOURNAL @ ar JOURNAL:CONFLICTS VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ PASS-SEEN$ T$=
   s" /upload.txt" UPLOAD$ ar UPLOAD-SENT
   s" upload.txt" s" 01701" UPLOAD$ s" cursor-rested" ar LISTED-ALONE
   x rec PASSED COMPLETE RESTED-IN TTRUE
   d x STEP-GONE ;

: PASS-CASES ( ^ARENA:arena -- )
   ONE-RECONCILIATION-PASS-SYNCHRONIZES-FILES-IN-BOTH-DIRECTIONS ;

\ ---- stale installs against the fake Dropbox -----------------------

: OBSOLETE$ ( -- str ) s" obsolete Dropbox bytes" ;
: MATCHING$ ( -- str ) s" matching current bytes" ;
: LOCAL-EDIT$ ( -- str ) s" later local edit" ;
: STALE-LOCAL$ ( -- str ) s" current local bytes" ;
: UNRELATED-STAGE$ ( -- str ) s" unrelated stage bytes" ;

\ Rust's stale: the obsolete bytes at stale-revision.
: STALE-REMOTE ( ^ARENA:arena -- MODEL:remote )
   {: ar :}
   OBSOLETE$ s" stale-revision" ar REMOTE-FILE ;

\ Rust's stale_install, recorded pending at path p.
: STALE-INSTALL ( ^run str -- )
   {: x p:str :}
   x p x RUN-ARENA @ STALE-REMOTE INSTALLING drop ;

\ A case's run with file.txt holding b and a stale install pending
\ there; answers the recovery directory.
: STALE-FILE ( str ^ARENA:arena -- str ^run str )
   {: b:str ar :}
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" file.txt" IN-ROOT b FS:WRITE-ALL
   x s" file.txt" STALE-INSTALL
   d x rec ;

: EMPTY-PAGE ( str ^ARENA:arena -- )
   {: k:str ar :}
   [: ;] ar ENTRIES k false PAGE ;

\ Rust's unsupported_file_metadata: not downloadable, export only.
: UNSUPPORTED-FILE-JSON+ ( str str str -- )
   {: l:str d:str r:str :}
   S\" {\q.tag\q:\qfile\q" SB-APPEND l d PATHS+
   S\" ,\qrev\q:" SB-APPEND r TEST-CLIENT:QUOTED+
   S\" ,\qsize\q:0,\qis_downloadable\q:false," SB-APPEND
   S\" \qexport_info\q:{\qexport_as\q:\qhtml\q}}" SB-APPEND ;

: STALE-NOOPED ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   noops 1 T= blocked 0 T= ;

\ The report's planned, replayed and blocked counts are p, r and b.
: COUNTED ( report n n n -- )
   {: p:n r:n b:n :}
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned p T= replayed r T= blocked b T= ;

\ Nothing planned or replayed, yet the kept plan stays live: no rest.
: STALE-BLOCKED ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 0 T= replayed 0 T= blocked 1 T= rested TFALSE ;

\ Rust's listings: file.txt current on the first page, then two
\ empty continuations; the fake holds it for the upload.
: MATCHING-PAGES ( ^ARENA:arena -- )
   {: ar :}
   s" file.txt" s" current-revision" MATCHING$ s" matching-current" ar
   LISTED-ALONE
   s" matching-stable" ar EMPTY-PAGE
   s" after-local-edit" ar EMPTY-PAGE
   s" file.txt" s" current-revision" MATCHING$ ar FILE-AT ;

: MATCHING-SEEN$ ( -- str )
   SB-RESET s" /2/files/list_folder " SB-APPEND
   CONTINUE$ SB-APPEND s"  " SB-APPEND CONTINUE$ SB-APPEND
   s"  /2/files/upload" SB-APPEND SB$ ;

: MATCHING-OBSERVATIONS-RETIRE-A-STALE-INSTALL-AND-LATER-EDITS-SYNC
   ( ^ARENA:arena -- )
   {: ar :}
   s" matching_observations_retire_a_stale_install_and_later_edits_sync"
   T-LABEL
   TEST-DROPBOX:RESET
   MATCHING$ ar STALE-FILE {: d:str x rec:str :}
   ar MATCHING-PAGES
   x rec PASSED COMPLETE STALE-NOOPED
   x PENDING-OF VEC:COUNT 0 T=
   x s" file.txt" MATCHING$ s" current-revision" ar REMOTE-FILE
   BASELINE-AT
   x rec PASSED COMPLETE STALE-NOOPED
   x s" file.txt" IN-ROOT LOCAL-EDIT$ FS:WRITE-ALL
   x rec PASSED COMPLETE 1 1 0 COUNTED
   x PENDING-OF VEC:COUNT 0 T=
   x s" file.txt" LOCAL-EDIT$ s" 01701" ar REMOTE-FILE BASELINE-AT
   TEST-DROPBOX:SEEN$ MATCHING-SEEN$ T$=
   d x STEP-GONE ;

: A-CHANGED-SAFE-OPERATION-REPLACES-A-STALE-INSTALL-IN-THE-SAME-PASS
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_changed_safe_operation_replaces_a_stale_install_in_the_same_pass"
   T-LABEL
   TEST-DROPBOX:RESET
   STALE-LOCAL$ ar STALE-FILE {: d:str x rec:str :}
   s" remote-absent" ar EMPTY-PAGE
   x rec PASSED COMPLETE 1 1 0 COUNTED
   x PENDING-OF VEC:COUNT 0 T=
   x s" file.txt" STALE-LOCAL$ s" 01701" ar REMOTE-FILE BASELINE-AT
   TEST-DROPBOX:SEEN$ UPLOAD-SEEN$ T$=
   s" /file.txt" STALE-LOCAL$ ar UPLOAD-SENT
   d x STEP-GONE ;

: AN-UNKNOWN-OBSERVATION-DOES-NOT-RETIRE-A-STALE-INSTALL
   ( ^ARENA:arena -- )
   {: ar :}
   s" an_unknown_observation_does_not_retire_a_stale_install" T-LABEL
   TEST-DROPBOX:RESET
   STALE-LOCAL$ ar STALE-FILE {: d:str x rec:str :}
   [: s" /file.txt" s" /file.txt" s" unsupported-revision"
      UNSUPPORTED-FILE-JSON+ ;]
   ar ENTRIES s" remote-unknown" false PAGE
   x rec PASSED COMPLETE STALE-BLOCKED
   x PENDING-OF VEC:COUNT 1 T=
   x s" file.txt" NO-BASELINE? TTRUE
   TEST-DROPBOX:SEEN$ 1 LISTED$ T$=
   d x STEP-GONE ;

\ The stage of removed.txt's obsolete download, holding other bytes.
: OBSOLETE-STAGE ( ^run -- str )
   {: x :}
   x [: x s" removed.txt" OBSOLETE$ PRESTAGED ;] IN-ACTIVE-ROOT
   x STAGE-PATH {: sp:str :}
   sp $180 FS:CHMOD-MODE
   sp UNRELATED-STAGE$ FS:WRITE-ALL
   sp ;

: A-PENDING-ONLY-PATH-RETIRES-WITHOUT-FETCHING-OBSOLETE-BYTES
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_pending_only_path_retires_without_fetching_obsolete_bytes"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x OBSOLETE-STAGE {: sp:str :}
   x s" removed.txt" STALE-INSTALL
   s" both-absent" ar EMPTY-PAGE
   x rec PASSED COMPLETE drop
   x PENDING-OF VEC:COUNT 0 T=
   x s" removed.txt" NO-BASELINE? TTRUE
   sp FS:EXISTS? TTRUE
   TEST-DROPBOX:SEEN$ 1 LISTED$ T$=
   DOWNLOAD$ TEST-DROPBOX:CALLS 0 T=
   d x STEP-GONE ;

\ The verified stage PRESTAGED made of b for path p, the root empty
\ before it.
: VERIFIED-STAGE ( ^run str str -- str )
   {: x p:str b:str :}
   x [: x p b PRESTAGED ;] IN-ACTIVE-ROOT
   x STAGE-PATH ;

: DOWNLOADS-ENDED ( ^run -- n )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:COMPLETED-DOWNLOAD-PLANS
   VEC:COUNT ;

\ The stale install a matching observation supersedes leaves no stage.
: A-SUPERSEDED-DOWNLOAD-PLAN-RETIRES-ITS-VERIFIED-STAGE
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_superseded_download_plan_retires_its_verified_stage" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" file.txt" OBSOLETE$ VERIFIED-STAGE {: sp:str :}
   x s" file.txt" IN-ROOT MATCHING$ FS:WRITE-ALL
   x s" file.txt" STALE-INSTALL
   ar MATCHING-PAGES
   x rec PASSED COMPLETE drop
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   sp FS:EXISTS? TFALSE
   x DOWNLOADS-ENDED 0 T=
   x s" file.txt" IN-ROOT MATCHING$ HOLDS-BYTES
   d x STEP-GONE ;

\ The pending download of plan p completed with its source as baseline.
: ENDED ( ^run JOURNAL:plan-record MODEL:remote -- )
   {: x p rem :}
   p PENDING-DOWNLOAD MATCH option
      none OF s" reconcile-test: the plan downloads nothing" TEST-CLIENT:FAILED ENDOF
      some OF DOWNLOAD-OPERATION-UNMAKE {: id src :}
         x RUN-JOURNAL @ id rem MODEL-BASELINE:PRESENT OPTION:SOME
         x RUN-ARENA @ JOURNAL:COMPLETE-OPERATION drop
      ENDOF
   ;MATCH ;

\ A download plan completed before the pass, its verified stage still
\ beside its target, loses the stage in the next pass.
: AN-ENDED-DOWNLOAD-PLAN-RETIRES-ITS-VERIFIED-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" an_ended_download_plan_retires_its_verified_stage" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" ended.txt" OBSOLETE$ VERIFIED-STAGE {: sp:str :}
   ar STALE-REMOTE {: rem :}
   x x s" ended.txt" rem INSTALLING rem ENDED
   x DOWNLOADS-ENDED 1 T=
   s" both-absent" ar EMPTY-PAGE
   x rec PASSED COMPLETE drop
   sp FS:EXISTS? TFALSE
   x DOWNLOADS-ENDED 0 T=
   DOWNLOAD$ TEST-DROPBOX:CALLS 0 T=
   d x STEP-GONE ;

\ Rust's plan of one replace-local operation of rem over content e,
\ recorded pending at path a.
: REPLACING
   ( ^run str MODEL:remote DROPBOX:hash -- JOURNAL:plan-record )
   {: x a:str rem e :}
   x RUN-ARENA @ {: ar :}
   rem e MODEL-OPERATION:REPLACE-LOCAL ar TEST-CLIENT:ONE-PLAN {: plan :}
   x RUN-JOURNAL @ a TEST-CLIENT:DISPLAY plan ar JOURNAL:RECORD-PLAN
   WRITTEN TTRUE ;

\ A replace-local plan completed before the pass loses its verified
\ stage as an install-local one does.
: AN-ENDED-REPLACE-PLAN-RETIRES-ITS-VERIFIED-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" an_ended_replace_plan_retires_its_verified_stage" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" replaced.txt" OBSOLETE$ VERIFIED-STAGE {: sp:str :}
   ar STALE-REMOTE {: rem :}
   x x s" replaced.txt" rem STALE-LOCAL$ ar IDENTITY REPLACING rem ENDED
   x DOWNLOADS-ENDED 1 T=
   s" both-absent" ar EMPTY-PAGE
   x rec PASSED COMPLETE drop
   sp FS:EXISTS? TFALSE
   x DOWNLOADS-ENDED 0 T=
   DOWNLOAD$ TEST-DROPBOX:CALLS 0 T=
   d x STEP-GONE ;

\ A superseded plan's stage that a blocked plan for the same path and
\ content holds stays, the superseded plan forgotten.
: A-LIVE-PLAN-KEEPS-THE-STAGE-OF-ITS-PATH-AND-CONTENT
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_live_plan_keeps_the_stage_of_its_path_and_content" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" held.txt" OBSOLETE$ VERIFIED-STAGE {: sp:str :}
   ar STALE-REMOTE {: rem :}
   x s" held.txt" rem INSTALLING {: old :}
   x RUN-JOURNAL @ old ID-OF ar JOURNAL:SUPERSEDE-PLAN drop
   x s" held.txt" rem INSTALLING {: live :}
   x live BLOCKED-AHEAD
   s" held.txt" s" stale-revision" OBSOLETE$ s" held-listed" ar
   LISTED-ALONE
   x rec PASSED COMPLETE drop
   x BLOCKED-OF VEC:COUNT 1 T=
   sp FS:EXISTS? TTRUE
   sp OBSOLETE$ HOLDS-BYTES
   x DOWNLOADS-ENDED 0 T=
   DOWNLOAD$ TEST-DROPBOX:CALLS 0 T=
   d x STEP-GONE ;

\ A superseded plan's stage stays no longer for a blocked plan at the
\ same path with other content: the stage is removed, the superseded
\ plan forgotten.
: A-LIVE-PLAN-FOR-OTHER-CONTENT-DOES-NOT-KEEP-THE-STAGE
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_live_plan_for_other_content_does_not_keep_the_stage" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" held.txt" OBSOLETE$ VERIFIED-STAGE {: sp:str :}
   ar STALE-REMOTE {: rem :}
   x s" held.txt" rem INSTALLING {: old :}
   x RUN-JOURNAL @ old ID-OF ar JOURNAL:SUPERSEDE-PLAN drop
   MATCHING$ s" current-revision" ar REMOTE-FILE {: now :}
   x s" held.txt" now INSTALLING {: live :}
   x live BLOCKED-AHEAD
   s" held.txt" s" current-revision" MATCHING$ s" held-listed" ar
   LISTED-ALONE
   x rec PASSED COMPLETE drop
   x BLOCKED-OF VEC:COUNT 1 T=
   sp FS:EXISTS? TFALSE
   x DOWNLOADS-ENDED 0 T=
   DOWNLOAD$ TEST-DROPBOX:CALLS 0 T=
   d x STEP-GONE ;

: REFUSED$ ( -- str ) s" Dropbox bytes beside the refused stage" ;

\ The one entry of the root's directory p, the stage PRESTAGED made.
: STAGE-IN ( ^run str -- str )
   {: x p:str :}
   x p IN-ROOT {: dir:str :}
   dir READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str ONE-NAME? TTRUE
   READ-BUF u >str s" .omabox-download-" STR:STARTS-WITH? TTRUE
   dir READ-BUF u >str x RUN-ARENA @ TEST-CLIENT:INSIDE ;

\ The one listing page, cursor k: the folder /ro and /other.txt at
\ rev-other with REFUSED$'s identity.
: REFUSED-PAGE ( str ^ARENA:arena -- )
   {: k:str ar :}
   REFUSED$ ar IDENTITY {: h:DROPBOX:hash :}
   [: s" /ro" s" /ro" FOLDER-JSON+ COMMA+
      s" /other.txt" s" /other.txt" s" rev-other" h FILE-JSON+ ;]
   ar ENTRIES k false PAGE ;

\ The warning the pass logs for ro/ended.txt's refused stage.
: REFUSED-LINE ( -- str )
   SB-RESET
   s" could not retire the verified download stage of `ro/ended.txt`, errno "
   SB-APPEND FS:EACCES FMT:SB-INT SB$ ;

\ A pass over the run logs one line, the refused retirement's, and
\ keeps the ended plan and its stage at sp.
: REFUSED-PASS ( str ^run str str -- )
   {: d:str x rec:str sp:str :}
   d [: x rec PASSED COMPLETE drop ;] x RUN-ARENA @ LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t REFUSED-LINE STR:CONTAINS? TTRUE
   x DOWNLOADS-ENDED 1 T=
   sp FS:EXISTS? TTRUE ;

\ A stage whose directory refuses its removal, as DENIED-RETIREMENT in
\ local-test sets up, keeps its ended plan for the next pass, one line
\ logged for its path in each of two passes; other.txt downloads in the
\ first pass all the same.
: A-FAILED-RETIREMENT-KEEPS-ITS-PLAN-WHILE-THE-PASS-GOES-ON
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_failed_retirement_keeps_its_plan_while_the_pass_goes_on" T-LABEL
   FS:EUID 0= if exit then
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" ro" IN-ROOT {: ro:str :}
   ro FS:MAKE-DIR
   x [: x s" ro/ended.txt" OBSOLETE$ PRESTAGED ;] IN-ACTIVE-ROOT
   x s" ro" STAGE-IN {: sp:str :}
   ar STALE-REMOTE {: rem :}
   x x s" ro/ended.txt" rem INSTALLING rem ENDED
   s" other.txt" s" rev-other" REFUSED$ ar SERVES
   s" ro-listed" ar REFUSED-PAGE
   s" ro-again" ar EMPTY-PAGE
   ro $140 FS:CHMOD-MODE
   [: d x rec sp REFUSED-PASS
      x s" other.txt" IN-ROOT REFUSED$ HOLDS-BYTES
      d x rec sp REFUSED-PASS ;]
   [: ro FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;] finally
   d x STEP-GONE ;

: STALE-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar MATCHING-OBSERVATIONS-RETIRE-A-STALE-INSTALL-AND-LATER-EDITS-SYNC
   ar A-CHANGED-SAFE-OPERATION-REPLACES-A-STALE-INSTALL-IN-THE-SAME-PASS
   ar AN-UNKNOWN-OBSERVATION-DOES-NOT-RETIRE-A-STALE-INSTALL
   ar A-PENDING-ONLY-PATH-RETIRES-WITHOUT-FETCHING-OBSOLETE-BYTES
   ar A-SUPERSEDED-DOWNLOAD-PLAN-RETIRES-ITS-VERIFIED-STAGE
   ar AN-ENDED-DOWNLOAD-PLAN-RETIRES-ITS-VERIFIED-STAGE
   ar AN-ENDED-REPLACE-PLAN-RETIRES-ITS-VERIFIED-STAGE
   ar A-LIVE-PLAN-KEEPS-THE-STAGE-OF-ITS-PATH-AND-CONTENT
   ar A-LIVE-PLAN-FOR-OTHER-CONTENT-DOES-NOT-KEEP-THE-STAGE
   ar A-FAILED-RETIREMENT-KEEPS-ITS-PLAN-WHILE-THE-PASS-GOES-ON ;

\ ---- download blocks against the fake Dropbox ----------------------

: REPLAYED-IN ( report -- n )
   RECONCILE-REPORT:UNMAKE {: r:n o:n p:n b:n e:n c:n s:bool :} r ;
: PLANNED-IN ( report -- n )
   RECONCILE-REPORT:UNMAKE {: r:n o:n p:n b:n e:n c:n s:bool :} p ;
: BLOCKED-IN ( report -- n )
   RECONCILE-REPORT:UNMAKE {: r:n o:n p:n b:n e:n c:n s:bool :} b ;

: BLOCKED-STATUS? ( JOURNAL:plan-record -- bool )
   STATUS-OF MATCH JOURNAL:plan-status
      pending OF false ENDOF
      blocked OF drop drop true ENDOF
      completed OF false ENDOF
   ;MATCH ;

\ Rust's record_blocked_install: INSTALLING's plan at path a, held as
\ download-unavailable 409 until at, in seconds since the epoch.
: RECORD-BLOCKED-INSTALL
   ( ^run str MODEL:remote n -- JOURNAL:plan-record )
   {: x a:str rem at:n :}
   x a rem INSTALLING {: p :}
   x p ID-OF 409 MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE at BLOCKED-UNTIL
   p ;

: INDEPENDENT-UPLOAD$ ( -- str ) s" independent upload" ;
: INDEPENDENT-DOWNLOAD$ ( -- str ) s" independent download" ;
: UNAVAILABLE-DOWNLOAD$ ( -- str ) s" unavailable download" ;

\ Rust's lookup_error("not_found").
: LOOKUP-NOT-FOUND$ ( -- str )
   S\" {\qerror_summary\q:\qpath/not_found/...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnot_found\q}}}" ;

: UNDECODABLE-ARG$ ( -- str )
   S\" Error in call to API function \qfiles/download\q: HTTP header \qDropbox-API-Arg\q: could not decode input as JSON" ;

\ Rust's failure, status st with body b, which only the download of
\ rev-blocked gets.
: BLOCKED-ANSWER ( n str -- )
   {: st:n b:str :}
   DOWNLOAD$ s" rev-blocked" st s" " s" " b
   TEST-DROPBOX:ARG-SCRIPT! ;

\ Rust's listing: blocked.txt and good.txt, each at its own rev.
: ISOLATION-PAGE ( ^ARENA:arena -- )
   {: ar :}
   UNAVAILABLE-DOWNLOAD$ ar IDENTITY {: hb:DROPBOX:hash :}
   INDEPENDENT-DOWNLOAD$ ar IDENTITY {: hg:DROPBOX:hash :}
   [: s" /blocked.txt" s" /blocked.txt" s" rev-blocked" hb FILE-JSON+
      COMMA+ s" /good.txt" s" /good.txt" s" rev-good" hg FILE-JSON+ ;]
   ar ENTRIES s" cursor-download-isolation" false PAGE ;

\ Rust's fixture: upload.txt in the root, good.txt served, both
\ downloads listed; answers the recovery directory.
: ISOLATED ( str ^run -- str )
   {: d:str x :}
   x RUN-ARENA @ {: ar :}
   d x PASS-READY {: rec:str :}
   x s" upload.txt" IN-ROOT INDEPENDENT-UPLOAD$ FS:WRITE-ALL
   s" good.txt" s" rev-good" INDEPENDENT-DOWNLOAD$ ar SERVES
   ar ISOLATION-PAGE
   rec ;

: ISOLATION-FILES ( ^run -- )
   {: x :}
   x s" good.txt" IN-ROOT INDEPENDENT-DOWNLOAD$ HOLDS-BYTES
   x s" upload.txt" IN-ROOT INDEPENDENT-UPLOAD$ HOLDS-BYTES
   x s" blocked.txt" IN-ROOT FS:EXISTS? TFALSE ;

\ No plan pending, and blocked.txt's alone blocked for status st.
: BLOCKED-ALONE ( ^run n -- )
   {: x st:n :}
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 PLAN-PATH$ s" blocked.txt" T$=
   s" download-unavailable " st x RUN-ARENA @ NUMBERED {: w:str :}
   held 0 VEC:AT @ HELD-FOR$ w T$= ;

: UNAVAILABLE-ENTRY ( n ^ARENA:arena -- str )
   {: st:n ar :}
   s" durable-plan blocked.txt download-unavailable " st ar NUMBERED ;

\ Rust's five requests but the account call; the fake serves good.txt's
\ bytes only to an argument naming rev-good.
: ISOLATION-SEEN$ ( -- str )
   s" /2/files/list_folder /2/files/download /2/files/download /2/files/upload" ;

\ The run's journal file in d.
: JOURNAL-FILE ( str ^run -- str )
   {: d:str x :}
   d s" journal.sqlite3" x RUN-ARENA @ TEST-CLIENT:INSIDE ;

\ The run's journal opened again from its file in d. Its new connection
\ holds no watch records, as after a restart, so the run's watch is doubted.
: OPENED-AGAIN ( str ^run -- )
   {: d:str x :}
   d x JOURNAL-FILE JOURNAL:OPEN x RUN-JOURNAL !
   x RUN-JOURNAL @ x RUN-WATCH @ LOCAL:WATCH-DOUBT ;

\ The run's journal closed and opened again from its file in d.
: REOPENED ( str ^run -- )
   {: d:str x :}
   x RUN-JOURNAL @ JOURNAL:CLOSE
   d x OPENED-AGAIN ;

\ Over a reopened journal, a step reports the block and sends nothing.
: BLOCK-KEPT ( str ^run n -- )
   {: d:str x st:n :}
   d x REOPENED
   TEST-DROPBOX:RESET
   x REPLAY-STEP REPORTED st x RUN-ARENA @ UNAVAILABLE-ENTRY
   REPORTS? TTRUE
   TEST-DROPBOX:SEEN$ s" " T$= ;

\ Rust's assert_download_failure_blocks_only_its_plan: the answer q
\ scripts blocks blocked.txt for status st while its siblings finish.
: ASSERT-DOWNLOAD-FAILURE-BLOCKS-ONLY-ITS-PLAN
   ( n [ -- ] ^ARENA:arena -- )
   {: st:n q ar :}
   TEST-DROPBOX:RESET q execute
   ar STEP-RUN {: d:str x :}
   d x ISOLATED {: rec:str :}
   \ Rust counts the upload; good.txt's download installs in the pass.
   x rec PASSED COMPLETE REPLAYED-IN 2 T=
   x REPLAY-STEP REPORTED {: settled :}
   x ISOLATION-FILES
   x st BLOCKED-ALONE
   settled st ar UNAVAILABLE-ENTRY REPORTS? TTRUE
   TEST-DROPBOX:SEEN$ ISOLATION-SEEN$ T$=
   d x st BLOCK-KEPT
   d x STEP-GONE ;

: UNAVAILABLE-DOWNLOAD-BLOCKS-ONLY-ITS-PLAN-WHILE-SIBLINGS-FINISH
   ( ^ARENA:arena -- )
   {: ar :}
   s" unavailable_download_blocks_only_its_plan_while_siblings_finish"
   T-LABEL
   409 [: 409 LOOKUP-NOT-FOUND$ BLOCKED-ANSWER ;] ar
   ASSERT-DOWNLOAD-FAILURE-BLOCKS-ONLY-ITS-PLAN ;

: REJECTED-DOWNLOAD-REQUEST-BLOCKS-ONLY-ITS-PLAN-WHILE-SIBLINGS-FINISH
   ( ^ARENA:arena -- )
   {: ar :}
   s" rejected_download_request_blocks_only_its_plan_while_siblings_finish"
   T-LABEL
   400 [: 400 UNDECODABLE-ARG$ BLOCKED-ANSWER ;] ar
   ASSERT-DOWNLOAD-FAILURE-BLOCKS-ONLY-ITS-PLAN ;

: UNMAPPED-DOWNLOAD-STATUS-BLOCKS-ONLY-ITS-PLAN-WHILE-SIBLINGS-FINISH
   ( ^ARENA:arena -- )
   {: ar :}
   s" unmapped_download_status_blocks_only_its_plan_while_siblings_finish"
   T-LABEL
   418 [: 418 s" {}" BLOCKED-ANSWER ;] ar
   ASSERT-DOWNLOAD-FAILURE-BLOCKS-ONLY-ITS-PLAN ;

: DUE$ ( -- str ) s" download available on retry" ;

\ due.txt served and listed, and its plan blocked with its retry due.
: DUE-BLOCKED ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   s" due.txt" s" rev-due" DUE$ ar SERVES
   s" due.txt" s" rev-due" DUE$ s" cursor-due" ar LISTED-ALONE
   DUE$ s" rev-due" ar REMOTE-FILE {: rem :}
   x s" due.txt" rem 0 RECORD-BLOCKED-INSTALL drop ;

: DUE-UNCHANGED-DOWNLOAD-RETRIES-AFTER-FRESH-OBSERVATION
   ( ^ARENA:arena -- )
   {: ar :}
   s" due_unchanged_download_retries_after_fresh_observation" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x DUE-BLOCKED
   \ Rust's later replay completes it; it installs in the pass.
   x rec PASSED COMPLETE REPLAYED-IN 1 T=
   x REPLAY-STEP REPORTED COMPLETED 0 T=
   x s" due.txt" IN-ROOT DUE$ HOLDS-BYTES
   x BLOCKED-OF VEC:COUNT 0 T=
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download" T$=
   d x STEP-GONE ;

: UNKNOWN-REMOTE$ ( -- str ) s" remote bytes" ;

\ unknown.txt listed, a dangling symlink in the root, and its plan
\ blocked with its retry due.
: UNKNOWN-BLOCKED ( ^run -- JOURNAL:plan-record )
   {: x :}
   x RUN-ARENA @ {: ar :}
   s" unknown.txt" s" rev-unknown" UNKNOWN-REMOTE$ s" cursor-unknown" ar
   LISTED-ALONE
   s" missing-target" x s" unknown.txt" IN-ROOT FS:MAKE-SYMLINK
   UNKNOWN-REMOTE$ s" rev-unknown" ar REMOTE-FILE {: rem :}
   x s" unknown.txt" rem 0 RECORD-BLOCKED-INSTALL ;

: DUE-DOWNLOAD-STAYS-BLOCKED-WHEN-THE-FRESH-LOCAL-PATH-IS-UNKNOWN
   ( ^ARENA:arena -- )
   {: ar :}
   s" due_download_stays_blocked_when_the_fresh_local_path_is_unknown"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x UNKNOWN-BLOCKED {: p :}
   x rec PASSED COMPLETE drop
   x BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ ID-OF JOURNAL:PLAN-ID>N p ID-OF JOURNAL:PLAN-ID>N T=
   held 0 VEC:AT @ BLOCKED-STATUS? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d x STEP-GONE ;

: NEW-REMOTE$ ( -- str ) s" new remote bytes" ;

\ changed.txt served and listed at rev-new-current, and the plan for
\ rev-old-blocked held until at.
: CHANGED-BLOCKED ( ^run n -- )
   {: x at:n :}
   x RUN-ARENA @ {: ar :}
   s" changed.txt" s" rev-new-current" NEW-REMOTE$ ar SERVES
   s" changed.txt" s" rev-new-current" NEW-REMOTE$ s" cursor-changed" ar
   LISTED-ALONE
   s" old remote bytes" s" rev-old-blocked" ar REMOTE-FILE {: old :}
   x s" changed.txt" old at RECORD-BLOCKED-INSTALL drop ;

: NEW-REV-ARG$ ( -- str ) S\" {\qpath\q:\qrev:rev-new-current\q}" ;

\ Rust's changed_revision_supersedes_blocked_download.
: CHANGED-REVISION-SUPERSEDES-BLOCKED-DOWNLOAD ( n ^ARENA:arena -- )
   {: at:n ar :}
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x at CHANGED-BLOCKED
   x rec PASSED COMPLETE {: rep :}
   \ Rust's one pending plan, not the old one: a plan recorded in its
   \ place, its download installed in the pass.
   rep PLANNED-IN 1 T= rep REPLAYED-IN 1 T=
   x REPLAY-STEP REPORTED drop
   x s" changed.txt" IN-ROOT NEW-REMOTE$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download" T$=
   TEST-DROPBOX:ARG-SENT$ NEW-REV-ARG$ T$=
   d x STEP-GONE ;

: CHANGED-REVISION-SUPERSEDES-BLOCKED-PLAN-BEFORE-OR-AFTER-DEADLINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" changed_revision_supersedes_blocked_plan_before_or_after_deadline"
   T-LABEL
   0 ar CHANGED-REVISION-SUPERSEDES-BLOCKED-DOWNLOAD
   4000000000 ar CHANGED-REVISION-SUPERSEDES-BLOCKED-DOWNLOAD ;

\ vanished.txt on neither side, and its plan held far ahead.
: VANISHED-BLOCKED ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   [: ;] ar ENTRIES s" cursor-absent" false PAGE
   s" vanished bytes" s" rev-vanished" ar REMOTE-FILE {: old :}
   x s" vanished.txt" old 4000000000 RECORD-BLOCKED-INSTALL drop ;

: BLOCKED-PLAN-IS-RETIRED-WHEN-BOTH-SIDES-ARE-ABSENT
   ( ^ARENA:arena -- )
   {: ar :}
   s" blocked_plan_is_retired_when_both_sides_are_absent" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x VANISHED-BLOCKED
   x rec PASSED COMPLETE BLOCKED-IN 0 T=
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d x STEP-GONE ;

: DOWNLOAD-BLOCKS-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar UNAVAILABLE-DOWNLOAD-BLOCKS-ONLY-ITS-PLAN-WHILE-SIBLINGS-FINISH
   ar REJECTED-DOWNLOAD-REQUEST-BLOCKS-ONLY-ITS-PLAN-WHILE-SIBLINGS-FINISH
   ar UNMAPPED-DOWNLOAD-STATUS-BLOCKS-ONLY-ITS-PLAN-WHILE-SIBLINGS-FINISH
   ar DUE-UNCHANGED-DOWNLOAD-RETRIES-AFTER-FRESH-OBSERVATION
   ar DUE-DOWNLOAD-STAYS-BLOCKED-WHEN-THE-FRESH-LOCAL-PATH-IS-UNKNOWN
   ar CHANGED-REVISION-SUPERSEDES-BLOCKED-PLAN-BEFORE-OR-AFTER-DEADLINE
   ar BLOCKED-PLAN-IS-RETIRED-WHEN-BOTH-SIDES-ARE-ABSENT ;

\ ---- uploads against the fake Dropbox ------------------------------


\ Rust's planned_operations: the decision's operation as a plan.
: PLANNED-OPERATIONS
   ( MODEL:decision ^ARENA:arena -- JOURNAL:operation-plan )
   {: ar :}
   MATCH MODEL:decision
      noop OF drop s" test expected planned operations" TEST-CLIENT:FAILED ENDOF
      operate OF ar TEST-CLIENT:ONE-PLAN ENDOF
      blocked OF drop s" test expected planned operations" TEST-CLIENT:FAILED ENDOF
      conflicted OF
         drop s" test expected planned operations" TEST-CLIENT:FAILED
      ENDOF
      collided OF drop s" test expected planned operations" TEST-CLIENT:FAILED ENDOF
   ;MATCH ;

\ Rust's record_fixture_plan: plan(b, l, r, Empty) recorded at path p.
: RECORD-FIXTURE-PLAN
   ( ^run str MODEL:baseline MODEL:observation<MODEL:local>
     MODEL:observation<MODEL:remote> -- JOURNAL:plan-record )
   {: x p:str b l r :}
   x RUN-ARENA @ {: ar :}
   b l r MODEL-SUBTREE:EMPTY PLANNER:PLAN ar PLANNED-OPERATIONS
   {: plan :}
   x RUN-JOURNAL @ p TEST-CLIENT:DISPLAY plan ar JOURNAL:RECORD-PLAN
   WRITTEN TTRUE ;

\ Rust's plan(Absent, Present(c), ConfirmedAbsent, Empty) at path p.
: UPLOAD-PLANNED ( ^run str DROPBOX:hash -- JOURNAL:plan-record )
   {: x p:str c:DROPBOX:hash :}
   x p MODEL-BASELINE:ABSENT c MODEL-LOCAL:MAKE LOCAL-PRESENT
   REMOTE-ABSENT RECORD-FIXTURE-PLAN ;

\ Rust's RemoteRejected { tag }.
: REJECTED-AS ( str -- MODEL:blockage )
   MODEL-BLOCKAGE:REMOTE-REJECTED ;

: UPLOAD-STAGED? ( LOCAL:stage-outcome<^LOCAL:staged-upload> -- bool )
   MATCH LOCAL:stage-outcome
      staged OF drop true ENDOF
      already-staged OF drop false ENDOF
      content-changed OF drop false ENDOF
      destination-occupied OF drop false ENDOF
   ;MATCH ;

\ Rust's stage_upload of path p's content c; answers the stage.
: UPLOAD-STAGE ( ^run str DROPBOX:hash -- str )
   {: x p:str c:DROPBOX:hash :}
   x [: p x STAGING$ c x RUN-ARENA @ LOCAL:STAGE-UPLOAD-AT ;]
   IN-ACTIVE-ROOT
   UPLOAD-STAGED? TTRUE
   x RUN-STAGING @ c DROPBOX:HASH>STR x RUN-ARENA @ TEST-CLIENT:INSIDE ;

: REPAIR$ ( -- str ) s" expected upload bytes" ;
: CORRUPT$ ( -- str ) s" corrupt private cache bytes" ;

: REPAIR-SEEN$ ( -- str )
   s" /2/files/list_folder /2/files/upload /2/files/list_folder/continue" ;

\ The listing's pages: none, then occupied.txt as the fake's first
\ upload commits it.
: REPAIR-PAGES ( ^ARENA:arena -- )
   {: ar :}
   s" occupied-upload-stage" ar EMPTY-PAGE
   s" occupied.txt" s" 01701" REPAIR$ s" repaired-upload-stage" ar
   LISTED-ALONE ;

\ occupied.txt in the root, its upload stage holding other bytes.
: CORRUPT-STAGED ( ^run -- )
   {: x :}
   x s" occupied.txt" IN-ROOT REPAIR$ FS:WRITE-ALL
   x s" occupied.txt" REPAIR$ x RUN-ARENA @ IDENTITY UPLOAD-STAGE
   {: sp:str :}
   sp FS:REMOVE-FILE sp CORRUPT$ FS:WRITE-ALL ;

\ occupied.txt's upload plan, blocked for its occupied stage and due,
\ as a journal opened again finds it.
: STAGE-BLOCKED ( str ^run -- )
   {: d:str x :}
   x s" occupied.txt" REPAIR$ x RUN-ARENA @ IDENTITY UPLOAD-PLANNED
   {: p :}
   x p ID-OF MODEL-BLOCKAGE:STAGE-OCCUPIED 0 BLOCKED-UNTIL
   d x REOPENED
   x BLOCKED-OF VEC:COUNT 1 T= ;

\ The first pass rebuilds the stage, uploads and settles occupied.txt.
: REPAIRED ( ^run str -- )
   {: x rec:str :}
   x RUN-ARENA @ {: ar :}
   x rec PASSED COMPLETE drop
   x s" occupied.txt" IN-ROOT REPAIR$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   x s" occupied.txt" REPAIR$ s" 01701" ar REMOTE-FILE BASELINE-AT ;

: SETTLED-REPORT ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   blocked 0 T= errors 0 T= ;

\ Rust's assert_corrupt_upload_stage_recovers, the plan blocked before
\ the pass when before is true.
: ASSERT-CORRUPT-UPLOAD-STAGE-RECOVERS ( bool ^ARENA:arena -- )
   {: before:bool ar :}
   TEST-DROPBOX:RESET ar REPAIR-PAGES
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x CORRUPT-STAGED
   before if d x STAGE-BLOCKED then
   x rec REPAIRED
   x rec PASSED COMPLETE SETTLED-REPORT
   TEST-DROPBOX:SEEN$ REPAIR-SEEN$ T$=
   s" /occupied.txt" REPAIR$ ar UPLOAD-SENT
   d x STEP-GONE ;

: CORRUPT-UPLOAD-STAGE-IS-REBUILT-AND-UPLOADED ( ^ARENA:arena -- )
   s" corrupt_upload_stage_is_rebuilt_and_uploaded" T-LABEL
   false swap ASSERT-CORRUPT-UPLOAD-STAGE-RECOVERS ;

: CORRUPT-UPLOAD-STAGE-RECOVERS-FROM-DURABLE-BLOCK-AFTER-REOPEN
   ( ^ARENA:arena -- )
   s" corrupt_upload_stage_recovers_from_durable_block_after_reopen"
   T-LABEL
   true swap ASSERT-CORRUPT-UPLOAD-STAGE-RECOVERS ;

: BLOCKED-UPLOAD$ ( -- str ) s" blocked upload" ;
: SIBLING$ ( -- str ) s" sibling upload" ;
\ blocked.txt and good.txt in the root, and a symlink at blocked.txt's
\ upload stage; answers the stage.
: SPECIAL-STAGED ( ^run -- str )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x s" blocked.txt" IN-ROOT BLOCKED-UPLOAD$ FS:WRITE-ALL
   x s" good.txt" IN-ROOT SIBLING$ FS:WRITE-ALL
   BLOCKED-UPLOAD$ ar IDENTITY DROPBOX:HASH>STR {: h:str :}
   x RUN-STAGING @ h ar TEST-CLIENT:INSIDE {: sp:str :}
   s" foreign-stage-target" sp FS:MAKE-SYMLINK
   sp ;

: SPECIAL-REPORT ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   blocked 1 T= errors 1 T= ;

\ The one blocked plan is blocked.txt's, for its occupied stage.
: STAGE-HELD ( ^run -- )
   {: x :}
   x BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ PLAN-PATH PATH$ s" blocked.txt" T$=
   held 0 VEC:AT @ HELD-FOR$ s" stage-occupied" T$= ;

: SPECIAL-UPLOAD-STAGE-BLOCKS-ONLY-ITS-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" special_upload_stage_blocks_only_its_plan" T-LABEL
   TEST-DROPBOX:RESET s" special-upload-stage" ar EMPTY-PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x SPECIAL-STAGED {: sp:str :}
   x rec PASSED COMPLETE SPECIAL-REPORT
   sp FS:SYMLINK? TTRUE
   x s" good.txt" SIBLING$ s" 01701" ar REMOTE-FILE BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   x STAGE-HELD
   TEST-DROPBOX:SEEN$ UPLOAD-SEEN$ T$=
   s" /good.txt" SIBLING$ ar UPLOAD-SENT
   d x STEP-GONE ;

: OLD-UPLOAD$ ( -- str ) s" old rejected upload" ;
: NEW-UPLOAD$ ( -- str ) s" new upload decision" ;

\ changed.txt's upload of its old bytes, rejected until long after the
\ pass, and the new bytes in its place.
: REJECTED-CHANGE ( ^run -- )
   {: x :}
   x s" changed.txt" IN-ROOT {: f:str :}
   f OLD-UPLOAD$ FS:WRITE-ALL
   x s" changed.txt" OLD-UPLOAD$ x RUN-ARENA @ IDENTITY UPLOAD-PLANNED
   {: p :}
   x p ID-OF s" disallowed_name" REJECTED-AS 4000000000
   BLOCKED-UNTIL
   f NEW-UPLOAD$ FS:WRITE-ALL ;

: CHANGED-REPORT ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   replayed 1 T= ;

: CHANGED-UPLOAD-SUPERSEDES-A-REJECTED-PLAN-BEFORE-DEADLINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" changed_upload_supersedes_a_rejected_plan_before_deadline" T-LABEL
   TEST-DROPBOX:RESET s" changed-upload" ar EMPTY-PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x REJECTED-CHANGE
   x rec PASSED COMPLETE CHANGED-REPORT
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   x s" changed.txt" NEW-UPLOAD$ s" 01701" ar REMOTE-FILE BASELINE-AT
   TEST-DROPBOX:SEEN$ UPLOAD-SEEN$ T$=
   s" /changed.txt" NEW-UPLOAD$ ar UPLOAD-SENT
   d x STEP-GONE ;

\ unknown.txt a dangling symlink, and its upload's plan rejected and
\ due; answers the plan.
: UNKNOWN-REJECTED ( ^run -- JOURNAL:plan-record )
   {: x :}
   s" missing-target" x s" unknown.txt" IN-ROOT FS:MAKE-SYMLINK
   x s" unknown.txt" s" unreadable upload" x RUN-ARENA @ IDENTITY
   UPLOAD-PLANNED {: p :}
   x p ID-OF s" disallowed_name" REJECTED-AS 0 BLOCKED-UNTIL
   p ;

: UNKNOWN-LOCAL-STATE-KEEPS-A-REJECTED-UPLOAD-BLOCKED ( ^ARENA:arena -- )
   {: ar :}
   s" unknown_local_state_keeps_a_rejected_upload_blocked" T-LABEL
   TEST-DROPBOX:RESET s" unknown-rejected-upload" ar EMPTY-PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x UNKNOWN-REJECTED {: p :}
   x rec PASSED COMPLETE STALE-BLOCKED
   x BLOCKED-OF 0 VEC:AT @ ID-OF JOURNAL:PLAN-ID>N
   p ID-OF JOURNAL:PLAN-ID>N T=
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d x STEP-GONE ;

: PLANNED-BYTES$ ( -- str ) s" planned bytes" ;
: CHANGED-BYTES$ ( -- str ) s" changed bytes" ;
: OTHER-BYTES$ ( -- str ) s" other bytes" ;

: STALE-SEEN$ ( -- str )
   s" /2/files/upload /2/files/list_folder /2/files/upload" ;

\ The listing's one page: other.txt as the fake's first upload commits
\ it.
: STALE-PAGE ( ^ARENA:arena -- )
   {: ar :}
   s" other.txt" s" 01701" OTHER-BYTES$ s" stale-upload" ar
   LISTED-ALONE ;

\ file.txt and other.txt in the root, each with an upload plan,
\ file.txt's for bytes it no longer holds.
: STALE-PLANNED ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x s" file.txt" IN-ROOT CHANGED-BYTES$ FS:WRITE-ALL
   x s" other.txt" IN-ROOT OTHER-BYTES$ FS:WRITE-ALL
   x s" file.txt" PLANNED-BYTES$ ar IDENTITY UPLOAD-PLANNED drop
   x s" other.txt" OTHER-BYTES$ ar IDENTITY UPLOAD-PLANNED drop ;

\ Rust's replay_remote_operations below the run's root.
: REMOTE-REPLAYED ( ^run -- ^REPLAY:replay-report )
   {: x :}
   x [: x RUN-JOURNAL @ x RUN-LINK @ rot x ROOT$ x STAGING$
      x RUN-ARENA @ REPLAY:REPLAY-REMOTE-OPERATIONS-AT ;] IN-ACTIVE-ROOT ;

\ The path a fresh-observation entry names, else the empty string.
: FRESH-AT$ ( REPLAY:replay-blocked -- str )
   MATCH REPLAY:replay-blocked
      durable-plan OF drop drop s" " ENDOF
      local-object OF drop s" " ENDOF
      fresh-observation-required OF PATH$ ENDOF
      download-required OF drop drop s" " ENDOF
      stage-destination-occupied OF drop drop s" " ENDOF
      precondition-changed OF drop drop s" " ENDOF
      remote-operation OF drop s" " ENDOF
      remote-pending OF drop s" " ENDOF
      remote-object OF drop s" " ENDOF
      sync-error OF drop drop s" " ENDOF
   ;MATCH ;

\ The remote replay uploads other.txt and asks a fresh look at
\ file.txt.
: STALE-REPLAYED ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x REMOTE-REPLAYED {: rep :}
   rep COMPLETED 1 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep BLOCKS 0 VEC:AT @ FRESH-AT$ s" file.txt" T$=
   x PENDING-OF VEC:COUNT 0 T=
   x s" other.txt" OTHER-BYTES$ s" 01701" ar REMOTE-FILE BASELINE-AT ;

: STALE-UPLOAD-IS-SUPERSEDED-AND-CURRENT-BYTES-SYNC ( ^ARENA:arena -- )
   {: ar :}
   s" stale_upload_is_superseded_and_current_bytes_sync" T-LABEL
   TEST-DROPBOX:RESET ar STALE-PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x STALE-PLANNED
   x STALE-REPLAYED
   s" /other.txt" OTHER-BYTES$ ar UPLOAD-SENT
   x rec PASSED COMPLETE 1 1 0 COUNTED
   x PENDING-OF VEC:COUNT 0 T=
   x s" file.txt" CHANGED-BYTES$ s" 01702" ar REMOTE-FILE BASELINE-AT
   TEST-DROPBOX:SEEN$ STALE-SEEN$ T$=
   s" /file.txt" CHANGED-BYTES$ ar UPLOAD-SENT
   d x STEP-GONE ;

: UPLOADS-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar CORRUPT-UPLOAD-STAGE-IS-REBUILT-AND-UPLOADED
   ar CORRUPT-UPLOAD-STAGE-RECOVERS-FROM-DURABLE-BLOCK-AFTER-REOPEN
   ar SPECIAL-UPLOAD-STAGE-BLOCKS-ONLY-ITS-PLAN
   ar CHANGED-UPLOAD-SUPERSEDES-A-REJECTED-PLAN-BEFORE-DEADLINE
   ar UNKNOWN-LOCAL-STATE-KEEPS-A-REJECTED-UPLOAD-BLOCKED
   ar STALE-UPLOAD-IS-SUPERSEDED-AND-CURRENT-BYTES-SYNC ;

\ ---- conflicts against the fake Dropbox ----------------------------

: COMMON$ ( -- str ) s" common bytes" ;
: NEW-LOCAL$ ( -- str ) s" new local bytes" ;
: USER-FILE$ ( -- str ) s" a file the user made" ;
: SHARED$ ( -- str ) s" shared baseline" ;
: DIVERGED-LOCAL$ ( -- str ) s" divergent local edit" ;
: DIVERGED-REMOTE$ ( -- str ) s" divergent Dropbox edit" ;
: EDITED-COPY$ ( -- str ) s" the user edited the Dropbox copy" ;
: UNRELATED$ ( -- str ) s" an unrelated new file" ;

\ Rust's CopyOccupant: what sits at a local conflict copy's name.
ENUM copy-occupant different-file unreadable-file ;ENUM

: UNREADABLE? ( copy-occupant -- bool )
   MATCH copy-occupant
      different-file OF false ENDOF
      unreadable-file OF true ENDOF
   ;MATCH ;

\ The no-op decision's baseline, recorded at p.
: SEEDED-NOOP ( ^run str MODEL:decision -- )
   {: x p:str dec :}
   dec NOOP-BASELINE {: b :}
   x RUN-JOURNAL @ p TEST-CLIENT:DISPLAY b x RUN-ARENA @ JOURNAL:RECORD-NOOP
   NOOP-RECORDED? TTRUE ;

\ Rust's seed_baseline: path p in sync at rem.
: SEED-BASELINE ( ^run str MODEL:remote -- )
   {: x p:str rem :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   rem MODEL-BASELINE:PRESENT c MODEL-LOCAL:MAKE LOCAL-PRESENT
   rem REMOTE-PRESENT MODEL-SUBTREE:EMPTY PLANNER:PLAN {: dec :}
   x p dec SEEDED-NOOP ;

\ Rust's plan(Present(old), Present(local c), Present(old), Empty),
\ recorded at path p: one upload over old.
: UPLOAD-OVER
   ( ^run str MODEL:remote DROPBOX:hash -- JOURNAL:plan-record )
   {: x p:str old c:DROPBOX:hash :}
   x p old MODEL-BASELINE:PRESENT c MODEL-LOCAL:MAKE LOCAL-PRESENT
   old REMOTE-PRESENT RECORD-FIXTURE-PLAN ;

\ Rust's conflict_copy_path: p's copy of bytes b for side, relative to
\ the root.
: CONFLICT-COPY-PATH
   ( str LOCAL:conflict-side str ^ARENA:arena -- str )
   {: p:str side b:str ar :}
   p side b ar IDENTITY ar LOCAL:CONFLICT-RELATIVE-PATH ;

\ The copy CONFLICT-COPY-PATH names, below the run's root.
: COPY-IN-ROOT ( ^run str LOCAL:conflict-side str -- str )
   {: x p:str side b:str :}
   x p side b x RUN-ARENA @ CONFLICT-COPY-PATH IN-ROOT ;

: COPY-CONFLICTS ( report -- n )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   conflicts ;

: CONFLICTS-OF ( ^run -- ^VEC:vector<JOURNAL:conflict-record> )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:CONFLICTS ;

: CONFLICT-RECORD= ( JOURNAL:conflict-record JOURNAL:conflict-record
     -- bool )
   {: a b :}
   a JOURNAL-CONFLICT--RECORD:UNMAKE {: id path c :}
   b JOURNAL-CONFLICT--RECORD:UNMAKE {: id2 path2 c2 :}
   id id2 = path PATH$ path2 PATH$ STR:= and
   c c2 MODEL:CONFLICT= and ;

\ Rust's == of two conflicts() answers.
: CONFLICTS= ( ^VEC:vector<JOURNAL:conflict-record>
     ^VEC:vector<JOURNAL:conflict-record> -- bool )
   {: v w :}
   v VEC:COUNT w VEC:COUNT <> if false exit then
   v VEC:COUNT 0 ?do
      v i VEC:AT @ w i VEC:AT @ CONFLICT-RECORD= 0= if
         false unloop exit
      then
   loop
   true ;

\ The one conflict recorded is at replace.txt.
: REPLACE-CONFLICTED ( ^run -- )
   CONFLICTS-OF {: recorded :}
   recorded VEC:COUNT 1 T=
   recorded 0 VEC:AT @ JOURNAL-CONFLICT--RECORD:UNMAKE
   {: id path c :}
   path PATH$ s" replace.txt" T$= ;

\ The one blocked plan, held for its occupied copy name.
: COPY-HELD ( ^run -- JOURNAL:plan-record )
   BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ {: p :}
   p HELD-FOR$ s" conflict-copy-occupied" T$=
   p ;


\ The fake serves new remote bytes as replace.txt's current-rev, on one
\ listing page with the cursor k.
: REPLACE-LISTED ( str ^ARENA:arena -- )
   {: k:str ar :}
   s" replace.txt" s" current-rev" NEW-REMOTE$ ar SERVES
   s" replace.txt" s" current-rev" NEW-REMOTE$ k ar LISTED-ALONE ;

\ replace.txt holds new local bytes over a baseline at old-rev, and its
\ upload is planned; the plan.
: REPLACE-PLANNED ( ^run -- JOURNAL:plan-record )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x s" replace.txt" IN-ROOT NEW-LOCAL$ FS:WRITE-ALL
   COMMON$ s" old-rev" ar REMOTE-FILE {: old :}
   x s" replace.txt" old SEED-BASELINE
   x s" replace.txt" old NEW-LOCAL$ ar IDENTITY UPLOAD-OVER ;

: LOCAL-COPY ( ^run -- str )
   s" replace.txt" LOCAL-CONFLICT--SIDE:LOCAL NEW-LOCAL$
   COPY-IN-ROOT ;

: REMOTE-COPY ( ^run -- str )
   s" replace.txt" LOCAL-CONFLICT--SIDE:REMOTE NEW-REMOTE$
   COPY-IN-ROOT ;

\ replace.txt's conflict prepared: both copies placed beside its local
\ bytes, recorded, and no plan left.
: REPLACE-PREPARED ( ^run -- )
   {: x :}
   x LOCAL-COPY NEW-LOCAL$ HOLDS-BYTES
   x REMOTE-COPY NEW-REMOTE$ HOLDS-BYTES
   x s" replace.txt" IN-ROOT NEW-LOCAL$ HOLDS-BYTES
   x REPLACE-CONFLICTED
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T= ;

\ The occupant at the local copy's name, unreadable for
\ unreadable-file.
: OCCUPANT-PLACED ( ^run copy-occupant -- )
   {: x o :}
   x LOCAL-COPY USER-FILE$ FS:WRITE-ALL
   o UNREADABLE? if x LOCAL-COPY 0 FS:CHMOD-MODE then ;

\ The remote replay blocks replace.txt for its local copy's name; the
\ occupant and replace.txt are kept.
: COPY-REPLAY-BLOCKED ( ^run copy-occupant -- JOURNAL:plan-record )
   {: x o :}
   x REMOTE-REPLAYED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep s" durable-plan replace.txt conflict-copy-occupied" REPORTS?
   TTRUE
   x COPY-HELD
   x CONFLICTS-OF VEC:COUNT 0 T=
   o UNREADABLE? if x LOCAL-COPY $180 FS:CHMOD-MODE then
   x LOCAL-COPY USER-FILE$ HOLDS-BYTES
   x s" replace.txt" IN-ROOT NEW-LOCAL$ HOLDS-BYTES ;

\ The occupant is gone, but the block is not yet due.
: COPY-WAITS ( ^run str -- )
   {: x rec:str :}
   x LOCAL-COPY FS:REMOVE-FILE
   x rec PASSED COMPLETE {: waiting :}
   waiting COPY-CONFLICTS 0 T=
   waiting BLOCKED-IN 1 T=
   x COPY-HELD drop
   x LOCAL-COPY FS:EXISTS? TFALSE
   x CONFLICTS-OF VEC:COUNT 0 T= ;

\ Rust's replay_blocks_an_occupied_copy_name.
: REPLAY-BLOCKS-AN-OCCUPIED-COPY-NAME
   ( copy-occupant ^ARENA:arena -- )
   {: o ar :}
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   s" cursor-retry" ar REPLACE-LISTED
   [: ;] ar ENTRIES s" cursor-retry" false PAGE
   x o OCCUPANT-PLACED
   x REPLACE-PLANNED drop
   x o COPY-REPLAY-BLOCKED ID-OF {: id :}
   x rec COPY-WAITS
   \ A due block is prepared again and places both copies.
   x id MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED 0 BLOCKED-UNTIL
   x rec PASSED COMPLETE COPY-CONFLICTS 1 T=
   x REPLACE-PREPARED
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata "
   STR:STARTS-WITH? TTRUE
   DOWNLOAD$ TEST-DROPBOX:CALLS 1 T=
   d x STEP-GONE ;

: REPLAY-BLOCKS-A-CONFLICT-WHOSE-LOCAL-COPY-NAME-IS-OCCUPIED
   ( ^ARENA:arena -- )
   {: ar :}
   s" replay_blocks_a_conflict_whose_local_copy_name_is_occupied"
   T-LABEL
   construct copy-occupant different-file ar
   REPLAY-BLOCKS-AN-OCCUPIED-COPY-NAME ;

: REPLAY-BLOCKS-A-CONFLICT-WHOSE-LOCAL-COPY-NAME-IS-UNREADABLE
   ( ^ARENA:arena -- )
   {: ar :}
   s" replay_blocks_a_conflict_whose_local_copy_name_is_unreadable"
   T-LABEL
   \ Root opens a file whatever its mode.
   FS:EUID 0 = if exit then
   construct copy-occupant unreadable-file ar
   REPLAY-BLOCKS-AN-OCCUPIED-COPY-NAME ;

\ c-diverged.txt holds a local edit over a baseline at rev-old, and the
\ fake lists Dropbox's edit at rev-remote on one page with cursor k.
: DIVERGED ( ^run str -- )
   {: x k:str :}
   x RUN-ARENA @ {: ar :}
   s" c-diverged.txt" s" rev-remote" DIVERGED-REMOTE$ ar FILE-AT
   s" c-diverged.txt" s" rev-remote" DIVERGED-REMOTE$ k ar
   LISTED-ALONE
   x s" c-diverged.txt" IN-ROOT DIVERGED-LOCAL$ FS:WRITE-ALL
   x s" c-diverged.txt" SHARED$ s" rev-old" ar REMOTE-FILE
   SEED-BASELINE ;

: DIVERGED-COPY ( ^run LOCAL:conflict-side str -- str )
   {: x side b:str :}
   x s" c-diverged.txt" side b COPY-IN-ROOT ;

: UNRELATED-WRITTEN ( ^run -- )
   s" d-unrelated.txt" IN-ROOT UNRELATED$ FS:WRITE-ALL ;

\ d-unrelated.txt's baseline at rev v, the rev the fake's upload
\ answered; it numbers revs in upload order.
: UNRELATED-SYNCED ( ^run str -- )
   {: x v:str :}
   x s" d-unrelated.txt" UNRELATED$ v x RUN-ARENA @ REMOTE-FILE
   BASELINE-AT ;

: RECORDED-CONFLICT-LEAVES-AN-EDITED-COPY-ALONE ( ^ARENA:arena -- )
   {: ar :}
   s" recorded_conflict_leaves_an_edited_copy_alone" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-conflict" DIVERGED
   s" rev-remote" DIVERGED-REMOTE$ TEST-DROPBOX:CONTENT!
   [: ;] ar ENTRIES s" cursor-conflict" false PAGE
   x LOCAL-CONFLICT--SIDE:LOCAL DIVERGED-LOCAL$ DIVERGED-COPY
   {: lc:str :}
   x LOCAL-CONFLICT--SIDE:REMOTE DIVERGED-REMOTE$ DIVERGED-COPY
   {: rc:str :}
   x rec PASSED COMPLETE COPY-CONFLICTS 1 T=
   x CONFLICTS-OF {: recorded :}
   recorded VEC:COUNT 1 T=
   rc DIVERGED-REMOTE$ HOLDS-BYTES
   \ The copy is read-only; the user makes it writable to edit it.
   rc $180 FS:CHMOD-MODE
   rc EDITED-COPY$ FS:WRITE-ALL
   x UNRELATED-WRITTEN
   x rec PASSED COMPLETE {: second :}
   second COPY-CONFLICTS 0 T=
   second BLOCKED-IN 0 T=
   rc EDITED-COPY$ HOLDS-BYTES
   lc DIVERGED-LOCAL$ HOLDS-BYTES
   x CONFLICTS-OF recorded CONFLICTS= TTRUE
   \ The two copies' uploads come first.
   x s" 01703" UNRELATED-SYNCED
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   DOWNLOAD$ TEST-DROPBOX:CALLS 1 T=
   d x STEP-GONE ;

\ c-diverged.txt blocked alone: its bytes and baseline kept and no
\ conflict recorded, while d-unrelated.txt syncs as rev v.
: DIVERGED-HELD ( ^run report str -- )
   {: x rep v:str :}
   rep BLOCKED-IN 1 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   x s" c-diverged.txt" IN-ROOT DIVERGED-LOCAL$ HOLDS-BYTES
   x s" c-diverged.txt" SHARED$ s" rev-old" x RUN-ARENA @ REMOTE-FILE
   BASELINE-AT
   x v UNRELATED-SYNCED
   DOWNLOAD$ TEST-DROPBOX:CALLS 0 T= ;

: OCCUPIED-DROPBOX-CONFLICT-COPY-NAME-BLOCKS-ONLY-ITS-PATH
   ( ^ARENA:arena -- )
   {: ar :}
   s" occupied_dropbox_conflict_copy_name_blocks_only_its_path" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-occupied" DIVERGED
   x LOCAL-CONFLICT--SIDE:REMOTE DIVERGED-REMOTE$ DIVERGED-COPY
   {: rc:str :}
   rc USER-FILE$ FS:WRITE-ALL
   x UNRELATED-WRITTEN
   x rec PASSED COMPLETE {: rep :}
   rep COPY-CONFLICTS 0 T=
   rc USER-FILE$ HOLDS-BYTES
   \ The occupant's upload comes first.
   x rep s" 01702" DIVERGED-HELD
   d x STEP-GONE ;

: CONFLICT-ON-A-PLAN-BLOCKED-FOR-ITS-SIZE-IS-PREPARED-AT-ONCE
   ( ^ARENA:arena -- )
   {: ar :}
   s" conflict_on_a_plan_blocked_for_its_size_is_prepared_at_once"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   s" cursor-size" ar REPLACE-LISTED
   x REPLACE-PLANNED ID-OF {: id :}
   x id MODEL-BLOCKAGE:UNSUPPORTED-FILE-SIZE $7FFFFFFFFFFFFFFF
   BLOCKED-UNTIL
   x rec PASSED COMPLETE {: rep :}
   rep COPY-CONFLICTS 1 T=
   rep BLOCKED-IN 0 T=
   x REPLACE-PREPARED
   UPLOAD-ROUTE$ TEST-DROPBOX:CALLS 0 T=
   d x STEP-GONE ;

: DIRECTORY-AT-DROPBOX-CONFLICT-COPY-NAME-BLOCKS-ONLY-ITS-PATH
   ( ^ARENA:arena -- )
   {: ar :}
   s" directory_at_dropbox_conflict_copy_name_blocks_only_its_path"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-occupied-directory" DIVERGED
   x LOCAL-CONFLICT--SIDE:REMOTE DIVERGED-REMOTE$ DIVERGED-COPY
   {: rc:str :}
   rc FS:MAKE-DIR
   x UNRELATED-WRITTEN
   x rec PASSED COMPLETE {: rep :}
   rc FS:DIR? TTRUE
   rc READ-BUF READ-CAP FS-LIST:NAMES 0 T=
   x rep s" 01701" DIVERGED-HELD
   d x STEP-GONE ;

: STAGE-XATTR$ ( -- str ) s" user.omabox.download-stage-v1" ;

: MARKER-ABSENT? ( XATTR:got -- bool )
   MATCH XATTR:got
      absent OF true ENDOF
      value OF drop false ENDOF
      oversize OF false ENDOF
   ;MATCH ;

\ The file at p is read-only to its owner alone and carries no stage
\ marker, the attribute LOCAL marks an owned download stage with.
: SEALED ( str -- )
   {: p:str :}
   p FS:TRY-STAT TTRUE FS:STAT-MODE@ $1FF and MODE-0400 T=
   p FS:OPEN-SIZED TTRUE drop {: f:fd :}
   f STAGE-XATTR$ READ-BUF READ-CAP SPAN:MAKE XATTR:GET
   MARKER-ABSENT? TTRUE
   f FS:CLOSE-DIR ;

: STAGE-KEPT? ( option<LOCAL:stage-outcome<n>> -- bool )
   MATCH option
      none OF false ENDOF
      some OF MATCH LOCAL:stage-outcome
            staged OF drop false ENDOF
            already-staged OF drop true ENDOF
            content-changed OF drop false ENDOF
            destination-occupied OF drop false ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ Whether replace.txt's verified stage of the new remote bytes is there.
: REPLACE-STAGED? ( ^run -- bool )
   {: x :}
   x [: x ROOT$ s" replace.txt" NEW-REMOTE$ x RUN-ARENA @ IDENTITY
      x RUN-ARENA @ LOCAL:EXISTING-DOWNLOAD-STAGE-AT STAGE-KEPT? ;]
   IN-ACTIVE-ROOT ;

\ replace.txt's download, planned and staged, finds new local bytes
\ there when it installs, so the pass that replays it plans a conflict.
: DOWNLOAD-OVERTAKEN ( ^run str -- )
   {: x k:str :}
   x RUN-ARENA @ {: ar :}
   k ar REPLACE-LISTED
   x s" replace.txt" NEW-REMOTE$ s" current-rev" ar REMOTE-FILE
   INSTALLING drop
   x [: x s" replace.txt" NEW-REMOTE$ PRESTAGED ;] IN-ACTIVE-ROOT
   x s" replace.txt" IN-ROOT NEW-LOCAL$ FS:WRITE-ALL ;

: A-CONFLICTED-DOWNLOAD-REUSES-ITS-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" a download plan that ends as a conflict reuses its stage" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-reuse" DOWNLOAD-OVERTAKEN
   x rec PASSED COMPLETE COPY-CONFLICTS 1 T=
   x REPLACE-PREPARED
   x REMOTE-COPY SEALED
   x REPLACE-STAGED? TFALSE
   DOWNLOAD$ TEST-DROPBOX:CALLS 0 T=
   d x STEP-GONE ;

\ ---- a new conflict whose copies cannot be placed -----------------

1048576 constant BIG-SIZE
512 constant IO-CAP
IO-CAP BUFFER: IO-BUF

\ The decimal number the bytes start with.
: DIGITS ( ^u8 n -- n )
   {: a:^ u:n :}
   0 u 0 ?do
      a i + c@ dup 48 < over 57 > or if drop unloop exit then
      48 - swap 10 * +
   loop ;

\ The count after name in /proc/self/io, the bytes this process has
\ read or written through system calls; -1 when it is missing.
: IO-COUNT ( str -- n )
   {: name:str :}
   s" /proc/self/io" IO-BUF IO-CAP FS:READ-ALL {: u:n :}
   name str> {: na:^ nu:n :}
   u nu - 0 ?do
      IO-BUF i + nu >str name STR:= if
         IO-BUF i + nu + u i - nu - DIGITS unloop exit
      then
   loop
   -1 ;

: READ-COUNT ( -- n ) s" rchar: " IO-COUNT ;
: WRITE-COUNT ( -- n ) s" wchar: " IO-COUNT ;

\ BIG-SIZE bytes, each B.
: BIG$ ( ^ARENA:arena -- str )
   BIG-SIZE ARENA:ALLOC {: a:^ u:n :}
   u 0 ?do 66 a i + c! loop
   a u >str ;

\ The content hash of the file at path f; IDENTITY's pipe holds no
\ more than 64 KiB.
: FILE-IDENTITY ( str ^ARENA:arena -- DROPBOX:hash )
   {: f:str ar :}
   f FS:OPEN-SIZED {: fd:fd n:n ok:bool :}
   ok TTRUE
   fd ar LOCAL:DROPBOX-CONTENT-HASH fd FS:CLOSE-DIR ;

\ c-diverged.txt diverged with cursor k and local edit b, a file Omabox
\ cannot read at its local copy's name; the copy's path.
: TAKEN-DIVERGED ( ^run str str -- str )
   {: x k:str b:str :}
   x RUN-ARENA @ {: ar :}
   x k DIVERGED
   x s" c-diverged.txt" IN-ROOT {: p:str :}
   p b FS:WRITE-ALL
   s" c-diverged.txt" LOCAL-CONFLICT--SIDE:LOCAL p ar FILE-IDENTITY ar
   LOCAL:CONFLICT-RELATIVE-PATH {: rel:str :}
   x rel IN-ROOT {: lc:str :}
   lc USER-FILE$ FS:WRITE-ALL
   lc 0 FS:CHMOD-MODE
   lc ;

: BLOCKS-OF ( ^run -- ^VEC:vector<JOURNAL:conflict-block> )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:CONFLICT-BLOCKS ;

\ The run's one conflict block, c-diverged.txt's for its taken copy
\ name; its retry time.
: ONE-BLOCK ( ^run -- n )
   BLOCKS-OF {: v :}
   v VEC:COUNT 1 T=
   v VEC:COUNT 1 <> if 0 exit then
   v 0 VEC:AT @ JOURNAL-CONFLICT--BLOCK:UNMAKE {: path why at:n :}
   path MODEL:PATH>STR s" c-diverged.txt" T$=
   SB-RESET why REASON+ SB$ s" conflict-copy-occupied" T$=
   at ;

\ c-diverged.txt's block due now.
: BLOCK-DUE ( ^run -- )
   {: x :}
   x RUN-JOURNAL @ s" c-diverged.txt" MODEL:>PATH
   MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED 0 x RUN-ARENA @
   JOURNAL:BLOCK-NEW-CONFLICT ;

\ The first pass records the block an hour after it ran; it holds the
\ path and the unreadable occupant.
: BLOCKED-ONCE ( ^run str -- n )
   {: x rec:str :}
   epoch-seconds {: t0:n :}
   x rec PASSED COMPLETE {: rep :}
   epoch-seconds {: t1:n :}
   rep COPY-CONFLICTS 0 T=
   rep BLOCKED-IN 2 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   x ONE-BLOCK {: at:n :}
   at t0 JOURNAL:BLOCK-RETRY-SECONDS + >= TTRUE
   at t1 JOURNAL:BLOCK-RETRY-SECONDS + <= TTRUE
   at ;

\ Before its retry time a pass reads and writes less than the edit's
\ size, though the copy's name is free; the block stays.
: WAITS-UNREAD ( ^run str str n -- )
   {: x rec:str lc:str at:n :}
   lc FS:REMOVE-FILE
   READ-COUNT {: r0:n :}  WRITE-COUNT {: w0:n :}
   r0 0 >= TTRUE
   x rec PASSED COMPLETE {: rep :}
   READ-COUNT r0 - BIG-SIZE < TTRUE
   WRITE-COUNT w0 - BIG-SIZE < TTRUE
   rep BLOCKED-IN 1 T=
   rep COPY-CONFLICTS 0 T=
   x ONE-BLOCK at T=
   lc FS:EXISTS? TFALSE
   x CONFLICTS-OF VEC:COUNT 0 T= ;

: NEW-CONFLICT-WAITS-OUT-ITS-TAKEN-COPY-NAME ( ^ARENA:arena -- )
   {: ar :}
   s" a new conflict whose copy name is taken waits for its retry time"
   T-LABEL
   \ Root reads a mode-000 file.
   FS:EUID 0 = if exit then
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   ar BIG$ {: b:str :}
   x s" cursor-taken" b TAKEN-DIVERGED {: lc:str :}
   \ Its change time past LOCAL's racy window, the first pass's scan
   \ keeps its hash and a later scan reuses it.
   4100 >MS TASK:SLEEP
   s" rev-remote" DIVERGED-REMOTE$ TEST-DROPBOX:CONTENT!
   [: ;] ar ENTRIES s" cursor-taken" false PAGE
   [: ;] ar ENTRIES s" cursor-taken" false PAGE
   x rec BLOCKED-ONCE {: at:n :}
   x rec lc at WAITS-UNREAD
   \ Due, both copies are placed and recorded, and the block goes.
   x BLOCK-DUE
   x rec PASSED COMPLETE {: rep :}
   rep COPY-CONFLICTS 1 T=
   rep BLOCKED-IN 0 T=
   lc FS:FILE-SIZE BIG-SIZE T=
   x LOCAL-CONFLICT--SIDE:REMOTE DIVERGED-REMOTE$ DIVERGED-COPY
   DIVERGED-REMOTE$ HOLDS-BYTES
   x CONFLICTS-OF VEC:COUNT 1 T=
   x BLOCKS-OF VEC:COUNT 0 T=
   d x STEP-GONE ;

: A-PATH-NO-LONGER-CONFLICTING-LOSES-ITS-BLOCK ( ^ARENA:arena -- )
   {: ar :}
   s" a path no longer conflicting loses its conflict block" T-LABEL
   FS:EUID 0 = if exit then
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-settled" DIVERGED-LOCAL$ TAKEN-DIVERGED {: lc:str :}
   [: ;] ar ENTRIES s" cursor-settled" false PAGE
   x rec BLOCKED-ONCE drop
   \ The local edit now matches Dropbox's.
   x s" c-diverged.txt" IN-ROOT DIVERGED-REMOTE$ FS:WRITE-ALL
   x rec PASSED COMPLETE {: rep :}
   \ Only the unreadable occupant is held.
   rep BLOCKED-IN 1 T=
   rep COPY-CONFLICTS 0 T=
   x BLOCKS-OF VEC:COUNT 0 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   lc $180 FS:CHMOD-MODE
   lc USER-FILE$ HOLDS-BYTES
   d x STEP-GONE ;

: A-PATH-HELD-OTHERWISE-LOSES-ITS-BLOCK ( ^ARENA:arena -- )
   {: ar :}
   s" a path held for another reason loses its conflict block" T-LABEL
   FS:EUID 0 = if exit then
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-unknown" DIVERGED-LOCAL$ TAKEN-DIVERGED {: lc:str :}
   [: ;] ar ENTRIES s" cursor-unknown" false PAGE
   x rec BLOCKED-ONCE drop
   \ A dangling symlink makes the path unknown, held before it conflicts.
   x s" c-diverged.txt" IN-ROOT {: p:str :}
   p FS:REMOVE-FILE
   s" missing-target" p FS:MAKE-SYMLINK
   x rec PASSED COMPLETE {: rep :}
   rep BLOCKED-IN 2 T=
   rep COPY-CONFLICTS 0 T=
   x BLOCKS-OF VEC:COUNT 0 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   d x STEP-GONE ;

: A-REFUSED-NEW-CONFLICT-WRITES-NO-BLOCK ( ^ARENA:arena -- )
   {: ar :}
   s" a refused new conflict is held and writes no block" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-refused" DIVERGED
   s" rev-remote" DIVERGED-REMOTE$ TEST-DROPBOX:CONTENT!
   \ The first download of rev-remote alone answers 409.
   DOWNLOAD$ s" rev-remote" 409 s" " s" " LOOKUP-NOT-FOUND$
   TEST-DROPBOX:ARG-SCRIPT!
   [: ;] ar ENTRIES s" cursor-refused" false PAGE
   x rec PASSED COMPLETE {: rep :}
   rep BLOCKED-IN 1 T=
   rep COPY-CONFLICTS 0 T=
   x BLOCKS-OF VEC:COUNT 0 T=
   x rec PASSED COMPLETE {: second :}
   second COPY-CONFLICTS 1 T=
   x LOCAL-CONFLICT--SIDE:LOCAL DIVERGED-LOCAL$ DIVERGED-COPY
   DIVERGED-LOCAL$ HOLDS-BYTES
   x LOCAL-CONFLICT--SIDE:REMOTE DIVERGED-REMOTE$ DIVERGED-COPY
   DIVERGED-REMOTE$ HOLDS-BYTES
   d x STEP-GONE ;

: CONFLICTS-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar REPLAY-BLOCKS-A-CONFLICT-WHOSE-LOCAL-COPY-NAME-IS-OCCUPIED
   ar REPLAY-BLOCKS-A-CONFLICT-WHOSE-LOCAL-COPY-NAME-IS-UNREADABLE
   ar RECORDED-CONFLICT-LEAVES-AN-EDITED-COPY-ALONE
   ar OCCUPIED-DROPBOX-CONFLICT-COPY-NAME-BLOCKS-ONLY-ITS-PATH
   ar CONFLICT-ON-A-PLAN-BLOCKED-FOR-ITS-SIZE-IS-PREPARED-AT-ONCE
   ar DIRECTORY-AT-DROPBOX-CONFLICT-COPY-NAME-BLOCKS-ONLY-ITS-PATH
   ar NEW-CONFLICT-WAITS-OUT-ITS-TAKEN-COPY-NAME
   ar A-PATH-NO-LONGER-CONFLICTING-LOSES-ITS-BLOCK
   ar A-PATH-HELD-OTHERWISE-LOSES-ITS-BLOCK
   ar A-REFUSED-NEW-CONFLICT-WRITES-NO-BLOCK
   ar A-CONFLICTED-DOWNLOAD-REUSES-ITS-STAGE ;

\ ---- restricted and same-named entries against the fake Dropbox ----

\ Rust's seed_directory_baseline.
: SEED-DIRECTORY-BASELINE ( ^run str -- )
   {: x p:str :}
   MODEL-BASELINE:DIRECTORY LOCAL-DIRECTORY REMOTE-DIRECTORY
   MODEL-SUBTREE:EMPTY PLANNER:PLAN {: dec :}
   x p dec SEEDED-NOOP ;

: FOLDER-BASELINE-AT ( ^run str -- )
   {: x p:str :}
   x RUN-JOURNAL @ p TEST-CLIENT:DISPLAY x RUN-ARENA @ JOURNAL:BASELINE
   STORED-BASELINE MODEL-BASELINE:DIRECTORY MODEL:BASELINE= TTRUE ;

: NO-CONFLICT-RECORD ( ^run -- )
   CONFLICTS-OF VEC:COUNT 0 T= ;

\ Rust's restricted_folder_metadata with no_access.
: NO-ACCESS-JSON+ ( str str -- )
   S\" {\q.tag\q:\qfolder\q" SB-APPEND PATHS+
   S\" ,\qsharing_info\q:{\qread_only\q:false," SB-APPEND
   S\" \qno_access\q:true}}" SB-APPEND ;

\ The listing's one page: /Shared, which the user cannot access.
: NO-ACCESS-PAGE ( str ^ARENA:arena -- )
   {: k:str ar :}
   [: s" /shared" s" /Shared" NO-ACCESS-JSON+ ;] ar ENTRIES
   k false PAGE ;

: MKDIR-IN ( ^run str -- ) IN-ROOT FS:MAKE-DIR ;

: WRITE-IN ( ^run str str -- )
   {: x p:str b:str :}
   x p IN-ROOT b FS:WRITE-ALL ;

: BENEATH$ ( -- str ) s" notes kept beneath an inaccessible folder" ;

: INACCESSIBLE-FOLDER-DELETES-NOTHING-BENEATH-IT ( ^ARENA:arena -- )
   {: ar :}
   s" inaccessible_folder_deletes_nothing_beneath_it" T-LABEL
   TEST-DROPBOX:RESET
   BENEATH$ s" rev-notes" ar REMOTE-FILE {: notes :}
   s" cursor-inaccessible" ar NO-ACCESS-PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" Shared" MKDIR-IN
   x s" Shared/notes.txt" BENEATH$ WRITE-IN
   x s" Shared/notes.txt" notes SEED-BASELINE
   x rec PASSED COMPLETE drop
   x s" Shared/notes.txt" IN-ROOT BENEATH$ HOLDS-BYTES
   x s" Shared/notes.txt" notes BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   \ Departure 5: no account request.
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d x STEP-GONE ;

: BEFORE-NOTES$ ( -- str ) s" notes observed before the restriction" ;
: BEFORE-KEEP$ ( -- str ) s" keep observed before the restriction" ;
: EDITED-KEEP$ ( -- str ) s" keep edited locally" ;

\ Shared, its notes and keep, published with cursor-accessible.
: ACCESSIBLE ( ^run MODEL:remote MODEL:remote -- )
   {: x notes keep :}
   x RUN-ARENA @ {: ar :}
   ar REMOTE-RECORDS {: rs :}
   rs s" Shared" REMOTE-DIRECTORY ar REMOTE+
   rs s" Shared/notes.txt" notes REMOTE-PRESENT ar REMOTE+
   rs s" Shared/keep.txt" keep REMOTE-PRESENT ar REMOTE+
   x RUN-JOURNAL @ s" cursor-accessible" DROPBOX:>CURSOR rs
   JOURNAL:PUBLISH-REMOTE-INVENTORY ;

\ Shared's notes and keep, observed on both sides, then notes removed
\ and keep edited in the root.
: OBSERVED-BEFORE ( ^run MODEL:remote MODEL:remote -- )
   {: x notes keep :}
   x s" Shared" MKDIR-IN
   x s" Shared/notes.txt" BEFORE-NOTES$ WRITE-IN
   x s" Shared/keep.txt" BEFORE-KEEP$ WRITE-IN
   x s" Shared" SEED-DIRECTORY-BASELINE
   x s" Shared/notes.txt" notes SEED-BASELINE
   x s" Shared/keep.txt" keep SEED-BASELINE
   x notes keep ACCESSIBLE
   x s" Shared/notes.txt" IN-ROOT FS:REMOVE-FILE
   x s" Shared/keep.txt" EDITED-KEEP$ WRITE-IN ;

: NEWLY-RESTRICTED-FOLDER-DROPS-STALE-CHILD-RECORDS ( ^ARENA:arena -- )
   {: ar :}
   s" newly_restricted_folder_drops_stale_child_records" T-LABEL
   TEST-DROPBOX:RESET
   BEFORE-NOTES$ s" rev-notes" ar REMOTE-FILE {: notes :}
   BEFORE-KEEP$ s" rev-keep" ar REMOTE-FILE {: keep :}
   \ The journal's cursor makes the page a continuation's.
   s" cursor-restricted" ar NO-ACCESS-PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x notes keep OBSERVED-BEFORE
   x rec PASSED COMPLETE drop
   x s" Shared/notes.txt" notes BASELINE-AT
   x s" Shared/keep.txt" keep BASELINE-AT
   x s" Shared/notes.txt" IN-ROOT FS:EXISTS? TFALSE
   x s" Shared/keep.txt" IN-ROOT EDITED-KEEP$ HOLDS-BYTES
   \ Departure 5: no account request.
   TEST-DROPBOX:SEEN$ CONTINUE$ T$=
   d x STEP-GONE ;

\ The directory's names, newline-separated in byte order, are w.
: NAMES-ARE ( str str -- )
   {: p:str w:str :}
   p READ-BUF READ-CAP FS-LIST:NAMES {: k:n :}
   READ-BUF k >str w T$= ;

: FOLDER-IN? ( ^run str -- bool ) IN-ROOT FS:DIR? ;

: RESTRICTED-FOLDER-SPELLS-ITS-LISTED-CHILDREN ( ^ARENA:arena -- )
   {: ar :}
   s" restricted_folder_spells_its_listed_children" T-LABEL
   TEST-DROPBOX:RESET
   [: s" /shared" s" /Shared" TRAVERSE-ONLY-JSON+ COMMA+
      s" /shared/a" s" /shared/A" FOLDER-JSON+ COMMA+
      s" /shared/b" s" /SHARED/B" FOLDER-JSON+ ;] ar ENTRIES
   s" cursor-spelled" false PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x rec PASSED COMPLETE drop
   x ROOT$ s" Shared" NAMES-ARE
   x s" Shared" FOLDER-IN? TTRUE
   x s" Shared" IN-ROOT S\" A\nB" NAMES-ARE
   x s" Shared/A" FOLDER-IN? TTRUE
   x s" Shared/B" FOLDER-IN? TTRUE
   \ Departure 5: Rust's two requests but the account's.
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d x STEP-GONE ;

: SHARED-SIBLING$ ( -- str ) s" shared sibling baseline" ;
: SIBLING-EDIT$ ( -- str ) s" sibling child edited locally" ;

\ Rust's sibling_fixture: report/ and report.txt in the root, and the
\ baselines report, report.txt and report/x; answers the recovery.
: SIBLINGS ( str ^run MODEL:remote -- str )
   {: d:str x shared :}
   d x PASS-READY {: rec:str :}
   x s" report" MKDIR-IN
   x s" report.txt" SHARED-SIBLING$ WRITE-IN
   x s" report" SEED-DIRECTORY-BASELINE
   x s" report.txt" shared SEED-BASELINE
   x s" report/x" shared SEED-BASELINE
   rec ;

: SIBLING-FILE+ ( str DROPBOX:hash -- )
   {: p:str h:DROPBOX:hash :}
   p p s" rev-sibling" h FILE-JSON+ ;

\ Rust's sibling_listing, its files' identity h; with child, report/x.
: SIBLING-PAGE ( DROPBOX:hash bool ^ARENA:arena -- )
   {: h:DROPBOX:hash child:bool ar :}
   [: s" /report" s" /report" FOLDER-JSON+ COMMA+
      s" /report.txt" h SIBLING-FILE+
      child if COMMA+ s" /report/x" h SIBLING-FILE+ then ;]
   ar ENTRIES s" cursor-after-sibling" false PAGE ;

: SIBLING-REPORTS ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 1 T= replayed 1 T= conflicts 0 T= blocked 0 T= ;

: SIBLING-DELETE$ ( -- str )
   S\" {\qpath\q:\q/report/x\q,\qparent_rev\q:\qrev-sibling\q}" ;

: FILE-BESIDE-A-SAME-NAMED-DIRECTORY-STILL-DELETES-ON-DROPBOX
   ( ^ARENA:arena -- )
   {: ar :}
   s" file_beside_a_same_named_directory_still_deletes_on_dropbox"
   T-LABEL
   TEST-DROPBOX:RESET
   SHARED-SIBLING$ s" rev-sibling" ar REMOTE-FILE {: shared :}
   SHARED-SIBLING$ ar IDENTITY true ar SIBLING-PAGE
   \ The fake's delete_v2 answers report/x as Rust's script does.
   s" report/x" s" rev-sibling" SHARED-SIBLING$ ar FILE-AT
   ar STEP-RUN {: d:str x :}
   d x shared SIBLINGS {: rec:str :}
   x rec PASSED COMPLETE SIBLING-REPORTS
   x s" report/x" NO-BASELINE? TTRUE
   x s" report.txt" shared BASELINE-AT
   x s" report/x" IN-ROOT FS:EXISTS? TFALSE
   x NO-CONFLICT-RECORD
   x PENDING-OF VEC:COUNT 0 T=
   DELETE$ TEST-DROPBOX:BODIES-TO$ SIBLING-DELETE$ T$=
   d x STEP-GONE ;

: FILE-BESIDE-A-SAME-NAMED-DIRECTORY-STILL-DELETES-LOCALLY
   ( ^ARENA:arena -- )
   {: ar :}
   s" file_beside_a_same_named_directory_still_deletes_locally" T-LABEL
   TEST-DROPBOX:RESET
   SHARED-SIBLING$ s" rev-sibling" ar REMOTE-FILE {: shared :}
   SHARED-SIBLING$ ar IDENTITY false ar SIBLING-PAGE
   ar STEP-RUN {: d:str x :}
   d x shared SIBLINGS {: rec:str :}
   x s" report/x" SHARED-SIBLING$ WRITE-IN
   x rec PASSED COMPLETE SIBLING-REPORTS
   x s" report/x" IN-ROOT FS:EXISTS? TFALSE
   x s" report/x" NO-BASELINE? TTRUE
   x s" report.txt" shared BASELINE-AT
   x NO-CONFLICT-RECORD
   x PENDING-OF VEC:COUNT 0 T=
   \ Departure 5: Rust's two requests but the account's.
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d x STEP-GONE ;

\ Rust's conflict_bytes of the root is empty.
: NO-CONFLICT-COPY ( ^run -- )
   ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   SB-RESET S\" \n" SB-APPEND READ-BUF u >str SB-APPEND
   SB$ S\" \n.omabox-conflict-" STR:CONTAINS? TFALSE ;

\ report/x's update argument as DROPBOX writes it, for content h.
: SIBLING-ARG$ ( DROPBOX:hash -- str )
   {: h:DROPBOX:hash :}
   SB-RESET S\" {\qpath\q:\q/report/x\q,\qmode\q:{\q.tag\q:" SB-APPEND
   S\" \qupdate\q,\qupdate\q:\qrev-sibling\q}," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND
   h DROPBOX:HASH>STR SB-APPEND S\" \q}" SB-APPEND SB$ ;

: FILE-BESIDE-A-SAME-NAMED-DIRECTORY-STILL-UPLOADS-A-LOCAL-EDIT
   ( ^ARENA:arena -- )
   {: ar :}
   s" file_beside_a_same_named_directory_still_uploads_a_local_edit"
   T-LABEL
   TEST-DROPBOX:RESET
   SHARED-SIBLING$ s" rev-sibling" ar REMOTE-FILE {: shared :}
   SHARED-SIBLING$ ar IDENTITY true ar SIBLING-PAGE
   \ The fake's upload updates rev-sibling and answers rev 01701, which
   \ stands for Rust's scripted rev-sibling-upload.
   s" report/x" s" rev-sibling" SHARED-SIBLING$ ar FILE-AT
   ar STEP-RUN {: d:str x :}
   d x shared SIBLINGS {: rec:str :}
   x s" report/x" SIBLING-EDIT$ WRITE-IN
   x rec PASSED COMPLETE SIBLING-REPORTS
   x NO-CONFLICT-RECORD
   x NO-CONFLICT-COPY
   x s" report/x" IN-ROOT SIBLING-EDIT$ HOLDS-BYTES
   x s" report/x" SIBLING-EDIT$ s" 01701" ar REMOTE-FILE BASELINE-AT
   UPLOAD-ROUTE$ TEST-DROPBOX:BODIES-TO$ SIBLING-EDIT$ T$=
   TEST-DROPBOX:ARG-SENT$ SIBLING-EDIT$ ar IDENTITY SIBLING-ARG$ T$=
   d x STEP-GONE ;

: SECRET$ ( -- str ) s" secret baseline bytes" ;
\ 0700, Rust's allow_owner_access.
$1C0 constant OWNER-ACCESS

\ PASS with locked/ unsearchable, then locked/ opened to its owner
\ whatever the pass did.
: LOCKED-PASSED ( ^run str -- outcome )
   {: x rec:str :}
   x s" locked" IN-ROOT {: l:str :}
   l 0 FS:CHMOD-MODE
   [: x rec PASSED ;] [: l OWNER-ACCESS FS:CHMOD-MODE ;] finally ;

\ locked/secret.txt and open.txt in the root and on the page, and the
\ baselines locked and locked/secret.txt.
: LOCKED-SIBLINGS ( ^run MODEL:remote ^ARENA:arena -- )
   {: x secret ar :}
   SECRET$ ar IDENTITY {: h:DROPBOX:hash :}
   [: s" /locked" s" /locked" FOLDER-JSON+ COMMA+
      s" /locked/secret.txt" s" /locked/secret.txt" s" rev-secret" h
      FILE-JSON+ ;] ar ENTRIES s" cursor-locked" false PAGE
   x s" locked" MKDIR-IN
   x s" locked/secret.txt" SECRET$ WRITE-IN
   x s" open.txt" SIBLING$ WRITE-IN
   x s" locked" SEED-DIRECTORY-BASELINE
   x s" locked/secret.txt" secret SEED-BASELINE ;

: LOCKED-REPORTS ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 1 T= replayed 1 T= blocked 2 T= conflicts 0 T= ;

: INACCESSIBLE-DIRECTORY-NEVER-DELETES-ITS-DROPBOX-CONTENTS
   ( ^ARENA:arena -- )
   {: ar :}
   s" inaccessible_directory_never_deletes_its_dropbox_contents" T-LABEL
   TEST-DROPBOX:RESET
   SECRET$ s" rev-secret" ar REMOTE-FILE {: secret :}
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x secret ar LOCKED-SIBLINGS
   x rec LOCKED-PASSED COMPLETE LOCKED-REPORTS
   x s" locked" FOLDER-BASELINE-AT
   x s" locked/secret.txt" secret BASELINE-AT
   \ The fake's upload answers rev 01701 for Rust's scripted rev-open.
   x s" open.txt" SIBLING$ s" 01701" ar REMOTE-FILE BASELINE-AT
   x s" locked/secret.txt" IN-ROOT SECRET$ HOLDS-BYTES
   x NO-CONFLICT-RECORD
   DELETE$ TEST-DROPBOX:CALLS 0 T=
   UPLOAD-ROUTE$ TEST-DROPBOX:CALLS 0 > TTRUE
   d x STEP-GONE ;

: RESTRICTED-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar INACCESSIBLE-FOLDER-DELETES-NOTHING-BENEATH-IT
   ar NEWLY-RESTRICTED-FOLDER-DROPS-STALE-CHILD-RECORDS
   ar RESTRICTED-FOLDER-SPELLS-ITS-LISTED-CHILDREN
   ar FILE-BESIDE-A-SAME-NAMED-DIRECTORY-STILL-DELETES-ON-DROPBOX
   ar FILE-BESIDE-A-SAME-NAMED-DIRECTORY-STILL-DELETES-LOCALLY
   ar FILE-BESIDE-A-SAME-NAMED-DIRECTORY-STILL-UPLOADS-A-LOCAL-EDIT
   ar INACCESSIBLE-DIRECTORY-NEVER-DELETES-ITS-DROPBOX-CONTENTS ;

\ ---- edits and directories against the fake Dropbox ---------------

: REMOTE-EDIT$ ( -- str ) s" later Dropbox edit" ;

\ For CONFLICT-BYTES: the name from at in the root's names ns, its
\ bytes kept in v when it is a conflict copy; the index after it, or
\ -1 past the last.
: CONFLICT-COPY+ ( str n ^run ^VEC:vector<str> -- n )
   {: ns:str at:n x v :}
   ns 10 at STR:SPLIT-NEXT 0= if 2drop -1 exit then
   {: q:str next:n :}
   q s" .omabox-conflict-" STR:STARTS-WITH? if
      x RUN-ROOT @ q x RUN-ARENA @ TEST-CLIENT:INSIDE
      READ-BUF READ-CAP FS:READ-ALL READ-BUF swap >str
      x RUN-ARENA @ ARENA:COPY v VEC:PUSH !
   then
   next ;

: BYTES-BEFORE? ( str str -- bool )
   {: a:str b:str :}
   a b STR:< ;

\ Swaps the strings at k-1 and k if they are out of byte order; whether
\ it did.
: COPY-SWAPPED? ( ^VEC:vector<str> n -- bool )
   {: v k:n :}
   v k 1 - VEC:AT {: a:^ :}
   v k VEC:AT {: b:^ :}
   b @ a @ BYTES-BEFORE? 0= if false exit then
   a @ b @ a ! b ! true ;

\ Moves the string at k down to its place among those before it.
: COPY-SETTLE ( ^VEC:vector<str> n -- )
   {: v k:n :}
   k 0 > if v k COPY-SWAPPED? if v k 1 - RECURSE then then ;

\ Sorts the strings in byte order, by insertion.
: COPIES-SORTED ( ^VEC:vector<str> -- )
   {: v :}
   v VEC:COUNT 1 ?do v i COPY-SETTLE loop ;

\ Rust's conflict_bytes: the bytes of each conflict copy in the root,
\ sorted.
: CONFLICT-BYTES ( ^run -- ^VEC:vector<str> )
   {: x :}
   x RUN-ARENA @ {: ar :}
   ar ARENA:ALLOCATOR 0 [type] str VEC:NEW {: v :}
   x ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str ar ARENA:COPY {: ns:str :}
   0 begin ns swap x v CONFLICT-COPY+ dup 0< until drop
   v COPIES-SORTED v ;

\ The directory d holds no entry.
: NOTHING-IN ( str -- ) READ-BUF READ-CAP FS-LIST:NAMES 0 T= ;

\ No request created, uploaded or deleted on Dropbox.
: UNWRITTEN ( -- )
   s" /2/files/create_folder_v2" TEST-DROPBOX:CALLS 0 T=
   UPLOAD-ROUTE$ TEST-DROPBOX:CALLS 0 T=
   DELETE$ TEST-DROPBOX:CALLS 0 T= ;

\ Rust's local files: a edited here, b as the baseline, c diverged;
\ each path's baseline the shared one at rev-old.
: EDITS-LOCAL ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x s" a-local-update.txt" IN-ROOT LOCAL-EDIT$ FS:WRITE-ALL
   x s" b-remote-update.txt" IN-ROOT SHARED$ FS:WRITE-ALL
   x s" c-diverged.txt" IN-ROOT DIVERGED-LOCAL$ FS:WRITE-ALL
   SHARED$ s" rev-old" ar REMOTE-FILE {: old :}
   x s" a-local-update.txt" old SEED-BASELINE
   x s" b-remote-update.txt" old SEED-BASELINE
   x s" c-diverged.txt" old SEED-BASELINE ;

\ Rust's Dropbox: a as the baseline, b edited, c diverged, on the one
\ listing page; b and c served.
: EDITS-REMOTE ( ^ARENA:arena -- )
   {: ar :}
   s" a-local-update.txt" s" rev-old" SHARED$ ar FILE-AT
   s" b-remote-update.txt" s" rev-remote-update" REMOTE-EDIT$ ar SERVES
   s" c-diverged.txt" s" rev-remote-conflict" DIVERGED-REMOTE$ ar SERVES
   SHARED$ ar IDENTITY {: ho:DROPBOX:hash :}
   REMOTE-EDIT$ ar IDENTITY {: hb:DROPBOX:hash :}
   DIVERGED-REMOTE$ ar IDENTITY {: hc:DROPBOX:hash :}
   [: s" /a-local-update.txt" dup s" rev-old" ho FILE-JSON+ COMMA+
      s" /b-remote-update.txt" dup s" rev-remote-update" hb FILE-JSON+
      COMMA+
      s" /c-diverged.txt" dup s" rev-remote-conflict" hc FILE-JSON+ ;]
   ar ENTRIES s" cursor-after-edits" false PAGE ;

: EDITS-REPORTED ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 2 T=
   \ Departure 2: b's download installs in the pass, so it is replayed
   \ and not blocked.
   replayed 2 T= blocked 0 T= conflicts 1 T= ;

\ The one conflict, Rust's DivergentEdits at c-diverged.txt.
: DIVERGENT-CONFLICT ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x RUN-JOURNAL @ ar JOURNAL:CONFLICTS {: cs :}
   cs VEC:COUNT 1 T=
   cs 0 VEC:AT @ JOURNAL-CONFLICT--RECORD:UNMAKE {: id p c :}
   p PATH$ s" c-diverged.txt" T$=
   DIVERGED-LOCAL$ ar IDENTITY MODEL-LOCAL:MAKE
   DIVERGED-REMOTE$ s" rev-remote-conflict" ar REMOTE-FILE
   MODEL-CONFLICT:DIVERGENT c MODEL:CONFLICT= TTRUE ;

\ Both conflict copies: Dropbox's side sorts before the local one.
: BOTH-SIDES ( ^run -- )
   CONFLICT-BYTES {: v :}
   v VEC:COUNT 2 T=
   v 0 VEC:AT @ DIVERGED-REMOTE$ T$=
   v 1 VEC:AT @ DIVERGED-LOCAL$ T$= ;

\ The upload's argument as DROPBOX writes it: a over rev-old.
: UPDATE-ARG$ ( DROPBOX:hash -- str )
   {: h:DROPBOX:hash :}
   SB-RESET S\" {\qpath\q:\q/a-local-update.txt\q," SB-APPEND
   S\" \qmode\q:{\q.tag\q:\qupdate\q,\qupdate\q:\qrev-old\q}," SB-APPEND
   S\" \qautorename\q:false,\qstrict_conflict\q:true," SB-APPEND
   S\" \qcontent_hash\q:\q" SB-APPEND
   h DROPBOX:HASH>STR SB-APPEND S\" \q}" SB-APPEND SB$ ;

\ Rust's requests, the account's aside: one listing, two downloads and
\ the upload, nothing deleted.
: EDITS-SEEN$ ( -- str )
   SB-RESET s" /2/files/list_folder /2/files/download " SB-APPEND
   s" /2/files/download /2/files/upload" SB-APPEND SB$ ;

: EDITS-SENT ( ^ARENA:arena -- )
   {: ar :}
   TEST-DROPBOX:SEEN$ EDITS-SEEN$ T$=
   DELETE$ TEST-DROPBOX:CALLS 0 T=
   UPLOAD-ROUTE$ TEST-DROPBOX:CALLS 1 T=
   UPLOAD-ROUTE$ TEST-DROPBOX:ARGS-TO$
   LOCAL-EDIT$ ar IDENTITY UPDATE-ARG$ STR:CONTAINS? TTRUE
   DOWNLOAD$ TEST-DROPBOX:CALLS 2 T=
   DOWNLOAD$ TEST-DROPBOX:ARGS-TO$
   S\" {\qpath\q:\qrev:rev-remote-update\q}" STR:CONTAINS? TTRUE
   DOWNLOAD$ TEST-DROPBOX:ARGS-TO$
   S\" {\qpath\q:\qrev:rev-remote-conflict\q}" STR:CONTAINS? TTRUE ;

: LATER-EDITS-SYNC-AND-DIVERGENCE-PRESERVES-BOTH-SIDES
   ( ^ARENA:arena -- )
   {: ar :}
   s" later_edits_sync_and_divergence_preserves_both_sides" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x EDITS-LOCAL ar EDITS-REMOTE
   x rec PASSED COMPLETE EDITS-REPORTED
   \ Departure 2: no download is left for a later step to complete.
   x REPLAY-STEP REPORTED COMPLETED 0 T=
   x s" a-local-update.txt" IN-ROOT LOCAL-EDIT$ HOLDS-BYTES
   x s" b-remote-update.txt" IN-ROOT REMOTE-EDIT$ HOLDS-BYTES
   x s" c-diverged.txt" IN-ROOT DIVERGED-LOCAL$ HOLDS-BYTES
   \ The fake's upload takes the rev 01701.
   x s" a-local-update.txt" LOCAL-EDIT$ s" 01701" ar REMOTE-FILE
   BASELINE-AT
   x s" b-remote-update.txt" REMOTE-EDIT$ s" rev-remote-update" ar
   REMOTE-FILE BASELINE-AT
   x s" c-diverged.txt" SHARED$ s" rev-old" ar REMOTE-FILE BASELINE-AT
   x DIVERGENT-CONFLICT x BOTH-SIDES
   x PENDING-OF VEC:COUNT 0 T=
   x RUN-JOURNAL @ ar JOURNAL:PENDING-RECOVERIES VEC:COUNT 0 T=
   x RUN-JOURNAL @ ar JOURNAL:COMPLETED-RECOVERIES VEC:COUNT 0 T=
   rec NOTHING-IN
   ar EDITS-SENT
   d x STEP-GONE ;

: DELETE-BASE$ ( -- str ) s" shared deletion baseline" ;

\ Rust's fixture: dropbox-deleted.txt here, local-deleted.txt on
\ Dropbox and its one listing page, both with the shared baseline.
: DELETIONS ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x s" dropbox-deleted.txt" IN-ROOT DELETE-BASE$ FS:WRITE-ALL
   DELETE-BASE$ s" rev-delete-baseline" ar REMOTE-FILE {: old :}
   x s" local-deleted.txt" old SEED-BASELINE
   x s" dropbox-deleted.txt" old SEED-BASELINE
   s" local-deleted.txt" s" rev-delete-baseline" DELETE-BASE$ ar FILE-AT
   s" local-deleted.txt" s" rev-delete-baseline" DELETE-BASE$
   s" cursor-after-deletions" ar LISTED-ALONE ;

: DELETE-BODY$ ( -- str )
   SB-RESET S\" {\qpath\q:\q/local-deleted.txt\q," SB-APPEND
   S\" \qparent_rev\q:\qrev-delete-baseline\q}" SB-APPEND SB$ ;

: LATER-DELETIONS-SYNC-IN-BOTH-DIRECTIONS ( ^ARENA:arena -- )
   {: ar :}
   s" later_deletions_sync_in_both_directions" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x DELETIONS
   x rec PASSED COMPLETE REPORTS
   x s" local-deleted.txt" IN-ROOT FS:EXISTS? TFALSE
   x s" dropbox-deleted.txt" IN-ROOT FS:EXISTS? TFALSE
   x s" local-deleted.txt" NO-BASELINE? TTRUE
   x s" dropbox-deleted.txt" NO-BASELINE? TTRUE
   x PENDING-OF VEC:COUNT 0 T=
   x RUN-JOURNAL @ ar JOURNAL:CONFLICTS VEC:COUNT 0 T=
   rec NOTHING-IN
   \ Rust's three requests less the account's.
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/delete_v2" T$=
   DELETE$ TEST-DROPBOX:BODIES-TO$ DELETE-BODY$ T$=
   DELETE$ TEST-DROPBOX:CALLS 1 T=
   d x STEP-GONE ;

\ Rust's create_folder_v2 answer: the folder p as its metadata.
: FOLDER-MADE ( str -- )
   {: p:str :}
   SB-RESET S\" {\qmetadata\q:" SB-APPEND p dup FOLDER-JSON+
   s" }" SB-APPEND
   s" /2/files/create_folder_v2" 200 s" " s" " SB$
   TEST-DROPBOX:ROUTE-SCRIPT! ;

\ The directory p is in the root, with a directory baseline.
: SYNCED-DIRECTORY ( ^run str -- )
   {: x p:str :}
   x p IN-ROOT FS:DIR? TTRUE
   x p FOLDER-BASELINE-AT ;

\ Rust's five requests less the account's.
: NESTED-SEEN$ ( -- str )
   SB-RESET s" /2/files/list_folder /2/files/create_folder_v2 " SB-APPEND
   s" /2/files/create_folder_v2 /2/files/create_folder_v2" SB-APPEND SB$ ;

: ONE-RECONCILIATION-PASS-SYNCHRONIZES-EMPTY-AND-NESTED-DIRECTORIES
   ( ^ARENA:arena -- )
   {: ar :}
   s" one_reconciliation_pass_synchronizes_empty_and_nested_directories"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" local" IN-ROOT FS:MAKE-DIR
   x s" local/child" IN-ROOT FS:MAKE-DIR
   [: s" /remote" dup FOLDER-JSON+ COMMA+
      s" /remote/child" dup FOLDER-JSON+ ;]
   ar ENTRIES s" directories" false PAGE
   s" /local" FOLDER-MADE s" /local" FOLDER-MADE
   s" /local/child" FOLDER-MADE
   x rec PASSED COMPLETE 4 4 0 COUNTED
   x s" local" SYNCED-DIRECTORY
   x s" local/child" SYNCED-DIRECTORY
   x s" remote" SYNCED-DIRECTORY
   x s" remote/child" SYNCED-DIRECTORY
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ NESTED-SEEN$ T$=
   s" /2/files/create_folder_v2" TEST-DROPBOX:CALLS 3 T=
   d x STEP-GONE ;

: ENTRY-BYTES$ ( -- str ) s" Dropbox source bytes" ;

\ The fake's file at path_lower l and path_display p, rev v, holding
\ ENTRY-BYTES$.
: ENTRY-SERVED ( str str str ^ARENA:arena -- )
   {: l:str p:str v:str ar :}
   ENTRY-BYTES$ ar IDENTITY DROPBOX:HASH>STR {: h:str :}
   l p v h ENTRY-BYTES$ str> nip TEST-DROPBOX:FILE!
   v ENTRY-BYTES$ TEST-DROPBOX:CONTENT! ;

\ Rust's two pages, each a file below /apps that Dropbox spells /Apps,
\ and their downloads, which spell the folder apps.
: FRESH-CASED ( ^ARENA:arena -- )
   {: ar :}
   ENTRY-BYTES$ ar IDENTITY {: h:DROPBOX:hash :}
   s" /apps/entry.doentry" s" /apps/Entry.doentry" s" remote-rev" ar
   ENTRY-SERVED
   s" /apps/second.doentry" s" /apps/Second.doentry" s" remote-rev-2"
   ar ENTRY-SERVED
   [: s" /apps" dup FOLDER-JSON+ COMMA+
      s" /apps/entry.doentry" s" /Apps/Entry.doentry" s" remote-rev" h
      FILE-JSON+ ;]
   ar ENTRIES s" fresh-case" false PAGE
   [: s" /apps/second.doentry" s" /Apps/Second.doentry" s" remote-rev-2"
      h FILE-JSON+ ;]
   ar ENTRIES s" fresh-case-2" false PAGE ;

: PASS-ANY ( outcome -- )
   MATCH outcome
      complete OF drop ENDOF
      fresh OF ENDOF
      root-changed OF ENDOF
   ;MATCH ;

: FRESH-DOWNLOAD-USES-PARENT-DIRECTORY-CASING-WITHOUT-REMOTE-WRITES
   ( ^ARENA:arena -- )
   {: ar :}
   s" fresh_download_uses_parent_directory_casing_without_remote_writes"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   ar FRESH-CASED
   x rec PASSED PASS-ANY
   \ Departure 2: the download installed in the pass, so the step that
   \ follows completes none.
   x REPLAY-STEP REPORTED COMPLETED 0 T=
   x s" apps/Entry.doentry" IN-ROOT ENTRY-BYTES$ HOLDS-BYTES
   x s" Apps" IN-ROOT FS:EXISTS? TFALSE
   x rec PASSED COMPLETE drop
   \ Departure 2, as above.
   x REPLAY-STEP REPORTED COMPLETED 0 T=
   x s" apps/Second.doentry" IN-ROOT ENTRY-BYTES$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   UNWRITTEN
   d x STEP-GONE ;

\ Rust's three pages: /apps and /apps/day one as Dropbox spells them,
\ then day one re-created with its child spelled in lower case, then
\ none.
: MISCASED ( ^ARENA:arena -- )
   {: ar :}
   [: s" /apps" s" /Apps" FOLDER-JSON+ COMMA+
      s" /apps/day one" s" /Apps/Day One" FOLDER-JSON+ ;]
   ar ENTRIES s" miscased-parents" false PAGE
   [: s" /apps/day one" dup DELETED-JSON+ COMMA+
      s" /apps/day one" dup FOLDER-JSON+ COMMA+
      s" /apps/day one/journal" s" /apps/day one/Journal" FOLDER-JSON+ ;]
   ar ENTRIES s" miscased-parents-2" false PAGE
   [: ;] ar ENTRIES s" miscased-parents-2" false PAGE ;

\ A pass that planned nothing and left k paths as they were.
: SETTLED ( report n -- )
   {: k:n :}
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   noops k T= planned 0 T= ;

: JOURNAL-CREATED ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 1 T= replayed 1 T= ;

: DELTA-FOLDER-WITH-MISCASED-PARENTS-IS-CREATED-INSIDE-THE-LOCAL-TREE
   ( ^ARENA:arena -- )
   {: ar :}
   s" delta_folder_with_miscased_parents_is_created_inside_the_local_tree"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" Apps" IN-ROOT FS:MAKE-DIR
   x s" Apps/Day One" IN-ROOT FS:MAKE-DIR
   ar MISCASED
   x rec PASSED COMPLETE 2 SETTLED
   x rec PASSED COMPLETE JOURNAL-CREATED
   x s" Apps/Day One/Journal" IN-ROOT FS:DIR? TTRUE
   x s" Apps/day one" IN-ROOT FS:EXISTS? TFALSE
   x s" Apps" IN-ROOT READ-BUF READ-CAP FS-LIST:NAMES
   READ-BUF swap >str s" Day One" T$=
   x s" apps/day one/journal" FOLDER-BASELINE-AT
   x rec PASSED COMPLETE 3 SETTLED
   x PENDING-OF VEC:COUNT 0 T=
   UNWRITTEN
   d x STEP-GONE ;

: EDITS-AND-DIRECTORIES-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar LATER-EDITS-SYNC-AND-DIVERGENCE-PRESERVES-BOTH-SIDES
   ar LATER-DELETIONS-SYNC-IN-BOTH-DIRECTIONS
   ar ONE-RECONCILIATION-PASS-SYNCHRONIZES-EMPTY-AND-NESTED-DIRECTORIES
   ar FRESH-DOWNLOAD-USES-PARENT-DIRECTORY-CASING-WITHOUT-REMOTE-WRITES
   ar DELTA-FOLDER-WITH-MISCASED-PARENTS-IS-CREATED-INSIDE-THE-LOCAL-TREE ;

\ ---- case collisions against the fake Dropbox ----------------------

: OUTCOME-FRESH? ( outcome -- bool )
   MATCH outcome
      complete OF {: rep :} false ENDOF
      fresh OF true ENDOF
      root-changed OF false ENDOF
   ;MATCH ;

: EXISTS-IN? ( ^run str -- bool ) IN-ROOT FS:EXISTS? ;

\ The symlink at path p in the root points at the text t.
: LINKS-TO ( ^run str str -- )
   {: x p:str t:str :}
   t x p IN-ROOT FS:MAKE-SYMLINK ;

\ The target the symlink at f holds.
: LINK-TARGET$ ( str -- str )
   FS:>PATHZ READ-BUF READ-CAP readlink {: u:n :}
   u 0< if s" the symlink did not read" TEST-CLIENT:FAILED then
   READ-BUF u >str ;

\ The root's names in byte order, one per line.
: ROOT-NAMES$ ( ^run -- str )
   ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str ;

\ The journal's baseline paths, joined by spaces.
: BASELINED$ ( ^run -- str )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:BASELINE-PATHS {: ps :}
   SB-RESET
   ps VEC:COUNT 0 ?do
      i 0<> if s"  " SB-APPEND then ps i VEC:AT @ PATH$ SB-APPEND
   loop
   SB$ ;

\ Rust's scan_and_publish of the run's root, which publishes.
: SCAN-PUBLISHED ( ^run -- ^VEC:vector<MODEL:local-record> )
   {: x :}
   x RUN-JOURNAL @ x ROOT$ x RUN-WATCH @ x RUN-ARENA @
   LOCAL:SCAN-AND-PUBLISH
   MATCH LOCAL:scan-publication
      published OF
         x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:LOCAL-INVENTORY
      ENDOF
      root-changed OF
         s" the stable fixture changed its root" TEST-CLIENT:FAILED
      ENDOF
   ;MATCH ;

\ The last replay step's report holds no blocked entry.
: STEP-UNBLOCKED ( ^run -- )
   REPLAY-STEP REPORTED BLOCKS VEC:COUNT 0 T= ;

: SAME$ ( -- str ) s" same bytes across a case-only change" ;

\ Rust's fixture: Report.TXT in the root and baselined, report.txt on
\ the one listing page; answers the remote file.
: CASE-ONLY ( ^run ^ARENA:arena -- MODEL:remote )
   {: x ar :}
   SAME$ s" rev-same" ar REMOTE-FILE {: rem :}
   s" report.txt" s" rev-same" SAME$ s" case-only" ar LISTED-ALONE
   x s" Report.TXT" SAME$ WRITE-IN
   x s" Report.TXT" rem SEED-BASELINE
   rem ;

: NOOP-REPORTS ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   noops 1 T= planned 0 T= replayed 0 T= ;

\ The inventory's one record, keyed and spelled report.txt.
: REPORT-LISTED ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x RUN-JOURNAL @ ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   rs VEC:COUNT 1 <> if
      s" expected one canonical remote observation" TEST-CLIENT:FAILED
   then
   rs 0 VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k p o :}
   k s" report.txt" ar CANONICAL MODEL:KEY= TTRUE
   p PATH$ s" report.txt" T$= ;

: CASE-ONLY-REMOTE-SPELLING-CHANGE-IS-A-STABLE-NOOP
   ( ^ARENA:arena -- )
   {: ar :}
   s" case_only_remote_spelling_change_is_a_stable_noop" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x ar CASE-ONLY {: rem :}
   x rec PASSED COMPLETE NOOP-REPORTS
   x PENDING-OF VEC:COUNT 0 T=
   x s" report.txt" rem BASELINE-AT
   x s" Report.TXT" IN-ROOT FS:FILE? TTRUE
   x s" report.txt" EXISTS-IN? TFALSE
   x REPORT-LISTED
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   d x STEP-GONE ;

: FIRST$ ( -- str ) s" first" ;
: SECOND$ ( -- str ) s" second" ;

\ Rust's fixture: Foo.txt and foo.txt in the root, an empty listing.
: TWO-SPELLINGS ( ^run ^ARENA:arena -- )
   {: x ar :}
   [: ;] ar ENTRIES s" empty" false PAGE
   x s" Foo.txt" FIRST$ WRITE-IN
   x s" foo.txt" SECOND$ WRITE-IN ;

\ The first pass renamed foo.txt apart and recorded nothing.
: VARIANT-RENAMED ( ^run -- )
   {: x :}
   x PENDING-OF VEC:COUNT 0 T=
   x BASELINED$ s" " T$=
   x s" Foo.txt" IN-ROOT FIRST$ HOLDS-BYTES
   x s" foo.txt" EXISTS-IN? TFALSE
   x s" foo.txt (case variant)" IN-ROOT SECOND$ HOLDS-BYTES ;

: TWO-UPLOADS$ ( -- str )
   s" /2/files/list_folder /2/files/upload /2/files/upload" ;

: LOCAL-CASE-COLLISION-IS-RENAMED-BEFORE-PLANNING-AND-THEN-SYNCS
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_case_collision_is_renamed_before_planning_and_then_syncs"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x ar TWO-SPELLINGS
   x rec PASSED OUTCOME-FRESH? TTRUE
   x VARIANT-RENAMED
   d x REOPENED
   x rec PASSED COMPLETE 2 2 0 COUNTED
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ TWO-UPLOADS$ T$=
   d x STEP-GONE ;

: ASSOCIATED$ ( -- str ) s" remote-associated local bytes" ;

\ Rust's two answers creating /apps (case variant), as FolderMetadata.
: VARIANT-MADE ( -- )
   2 0 do
      s" /2/files/create_folder_v2" 200 s" " s" "
      S\" {\qmetadata\q:{\qname\q:\qapps (case variant)\q,\qid\q:\qid:fixture_apps (case variant)\q,\qpath_lower\q:\q/apps (case variant)\q,\qpath_display\q:\q/apps (case variant)\q}}"
      TEST-DROPBOX:ROUTE-SCRIPT!
   loop ;

\ Rust's fixture: Apps and apps/entry.doentry in the root, the file's
\ baseline at Apps/entry.doentry, Apps listed with it and served.
: TWO-APPS ( ^run ^ARENA:arena -- MODEL:remote )
   {: x ar :}
   ASSOCIATED$ s" rev-original" ar REMOTE-FILE {: rem :}
   ASSOCIATED$ ar IDENTITY {: h:DROPBOX:hash :}
   s" Apps/entry.doentry" s" rev-original" ASSOCIATED$ ar SERVES
   [: s" /apps" s" /Apps" FOLDER-JSON+ COMMA+
      s" /apps/entry.doentry" s" /Apps/entry.doentry"
      s" rev-original" h FILE-JSON+ ;]
   ar ENTRIES s" case-collision" false PAGE
   VARIANT-MADE
   x s" Apps" MKDIR-IN x s" apps" MKDIR-IN
   x s" apps/entry.doentry" ASSOCIATED$ WRITE-IN
   x s" Apps/entry.doentry" rem SEED-BASELINE
   rem ;

\ Rust's stale_delete: the plan for the local file confirmed absent
\ under baseline and remote rem, recorded at Apps/entry.doentry.
: STALE-DELETE ( ^run MODEL:remote -- )
   {: x rem :}
   x s" Apps/entry.doentry" rem MODEL-BASELINE:PRESENT LOCAL-ABSENT
   rem REMOTE-PRESENT RECORD-FIXTURE-PLAN drop ;

\ Rust's two folder creations, its upload and its download.
: APPS-SEEN$ ( -- str )
   SB-RESET s" /2/files/list_folder /2/files/download " SB-APPEND
   s" /2/files/create_folder_v2 /2/files/create_folder_v2 " SB-APPEND
   s" /2/files/upload" SB-APPEND SB$ ;

\ Both spellings' files hold the bytes, and no third spelling is made.
: APPS-KEPT ( ^run -- )
   {: x :}
   x s" Apps/entry.doentry" IN-ROOT ASSOCIATED$ HOLDS-BYTES
   x s" apps (case variant)/entry.doentry" IN-ROOT ASSOCIATED$
   HOLDS-BYTES
   x s" apps" EXISTS-IN? TFALSE
   x s" apps (case variant 2)" EXISTS-IN? TFALSE ;

: AUTOMATIC-CASE-RENAME-NEVER-BECOMES-A-DROPBOX-DELETE
   ( ^ARENA:arena -- )
   {: ar :}
   s" automatic_case_rename_never_becomes_a_dropbox_delete" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x ar TWO-APPS {: rem :}
   x SCAN-PUBLISHED drop
   x rem STALE-DELETE
   x rec PASSED OUTCOME-FRESH? TTRUE
   x rec PASSED drop
   \ The download installs in the second pass, so the step finds none.
   x STEP-UNBLOCKED
   x APPS-KEPT
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" STR:CONTAINS? TFALSE
   TEST-DROPBOX:SEEN$ APPS-SEEN$ T$=
   d x STEP-GONE ;

\ Rust's fixture: Credit/statements/april.pdf, credit/Expenses/
\ invoice.pdf and credit/expenses/receipt.pdf in the root.
: CREDIT-TREES ( ^run -- )
   {: x :}
   x s" Credit" MKDIR-IN x s" Credit/statements" MKDIR-IN
   x s" credit" MKDIR-IN x s" credit/Expenses" MKDIR-IN
   x s" credit/expenses" MKDIR-IN
   x s" Credit/statements/april.pdf" s" statement" WRITE-IN
   x s" credit/Expenses/invoice.pdf" s" invoice" WRITE-IN
   x s" credit/expenses/receipt.pdf" s" receipt" WRITE-IN ;

\ The first pass renames credit apart.
: CREDIT-RENAMED ( ^run str -- )
   {: x rec:str :}
   x rec PASSED OUTCOME-FRESH? TTRUE
   x s" Credit/statements/april.pdf" IN-ROOT s" statement" HOLDS-BYTES
   x s" credit (case variant)/expenses/receipt.pdf" IN-ROOT
   s" receipt" HOLDS-BYTES
   x s" credit" EXISTS-IN? TFALSE
   x PENDING-OF VEC:COUNT 0 T= ;

\ The second pass renames credit (case variant)/expenses apart.
: EXPENSES-RENAMED ( ^run str -- )
   {: x rec:str :}
   x rec PASSED OUTCOME-FRESH? TTRUE
   x s" credit (case variant)/Expenses/invoice.pdf" IN-ROOT
   s" invoice" HOLDS-BYTES
   x s" credit (case variant)/expenses (case variant)/receipt.pdf"
   IN-ROOT s" receipt" HOLDS-BYTES ;

\ Rust's to_lowercase of each path is its key here: no two records'
\ paths fold to one.
: FOLDS-APART?
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena -- bool )
   {: rs ar :}
   ar [type] str NEW-VECTOR {: v :}
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ MODEL-LOCAL--RECORD:UNMAKE {: p o :}
      p ar MODEL:FOLD MODEL:KEY>STR v VEC:PUSH !
   loop
   v ar DISTINCT rs VEC:COUNT = ;

: LOCAL-CASE-COLLISION-PRESERVES-BOTH-DIRECTORY-TREES
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_case_collision_preserves_both_directory_trees" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x CREDIT-TREES
   x rec CREDIT-RENAMED
   x rec EXPENSES-RENAMED
   x SCAN-PUBLISHED ar FOLDS-APART? TTRUE
   TEST-DROPBOX:SEEN$ s" " T$=
   d x STEP-GONE ;

: KEPT$ ( -- str ) s" kept local bytes" ;
: VARIANT$ ( -- str ) s" variant local bytes" ;
: NEWER$ ( -- str ) s" newer remote bytes" ;

\ Rust's fixture: Foo.txt baselined at rev-old and foo.txt in the root,
\ foo.txt listed as Foo.txt at rev-new and served.
: KEPT-SPELLING ( ^run ^ARENA:arena -- )
   {: x ar :}
   NEWER$ ar IDENTITY {: h:DROPBOX:hash :}
   s" Foo.txt" s" rev-new" NEWER$ ar SERVES
   [: s" /foo.txt" s" /Foo.txt" s" rev-new" h FILE-JSON+ ;]
   ar ENTRIES s" kept-spelling" false PAGE
   x s" Foo.txt" KEPT$ WRITE-IN
   x s" foo.txt" VARIANT$ WRITE-IN
   x s" Foo.txt" KEPT$ s" rev-old" ar REMOTE-FILE SEED-BASELINE ;

\ The first pass renames foo.txt apart and keeps Foo.txt's baseline.
: VARIANT-APART ( ^run str -- )
   {: x rec:str :}
   x rec PASSED OUTCOME-FRESH? TTRUE
   x BASELINED$ s" Foo.txt" T$=
   x s" Foo.txt" IN-ROOT KEPT$ HOLDS-BYTES
   x s" foo.txt (case variant)" IN-ROOT VARIANT$ HOLDS-BYTES ;

: KEPT-REPORTS ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 2 T= conflicts 0 T= ;

\ Foo.txt replaced by the newer bytes, the variant kept.
: KEPT-REPLACED ( ^run -- )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:CONFLICTS VEC:COUNT 0 T=
   x PENDING-OF VEC:COUNT 0 T=
   x s" Foo.txt" IN-ROOT NEWER$ HOLDS-BYTES
   x s" foo.txt (case variant)" IN-ROOT VARIANT$ HOLDS-BYTES ;

: CASE-COLLISION-KEEPS-THE-BASELINED-SPELLING-AND-ITS-HISTORY
   ( ^ARENA:arena -- )
   {: ar :}
   s" case_collision_keeps_the_baselined_spelling_and_its_history"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x ar KEPT-SPELLING
   x rec VARIANT-APART
   x rec PASSED COMPLETE KEPT-REPORTS
   \ Rust's pending ReplaceLocal of rev-new over the kept bytes runs in
   \ this pass: rev-new downloaded, then installed with no conflict.
   DOWNLOAD$ TEST-DROPBOX:ARGS-TO$
   S\" {\qpath\q:\qrev:rev-new\q}" STR:CONTAINS? TTRUE
   x STEP-UNBLOCKED
   x KEPT-REPLACED
   TEST-DROPBOX:SEEN$ PASS-SEEN$ T$=
   d x STEP-GONE ;

: UPPER$ ( -- str ) s" upper local bytes" ;
: LOWER$ ( -- str ) s" lower local bytes" ;

: CASE-COLLISION-SPARES-THE-RECORDED-GREATER-SPELLING
   ( ^ARENA:arena -- )
   {: ar :}
   s" case_collision_spares_the_recorded_greater_spelling" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" Foo.txt" UPPER$ WRITE-IN
   x s" foo.txt" LOWER$ WRITE-IN
   x s" foo.txt" LOWER$ s" rev-old" ar REMOTE-FILE SEED-BASELINE
   x rec PASSED OUTCOME-FRESH? TTRUE
   x BASELINED$ s" foo.txt" T$=
   x s" foo.txt" IN-ROOT LOWER$ HOLDS-BYTES
   x s" Foo.txt (case variant)" IN-ROOT UPPER$ HOLDS-BYTES
   x s" Foo.txt" EXISTS-IN? TFALSE
   TEST-DROPBOX:SEEN$ s" " T$=
   d x STEP-GONE ;

: NOTES$ ( -- str ) s" synced notes" ;

\ Rust's fixture: notes.txt baselined and listed at rev-synced, and the
\ symlink Notes.txt beside it.
: NOTES-BESIDE-LINK ( ^run ^ARENA:arena -- )
   {: x ar :}
   s" notes.txt" s" rev-synced" NOTES$ s" symlink-variant" ar
   LISTED-ALONE
   x s" notes.txt" NOTES$ WRITE-IN
   x s" Notes.txt" s" symlink-target" LINKS-TO
   x s" notes.txt" NOTES$ s" rev-synced" ar REMOTE-FILE SEED-BASELINE ;

: CASE-COLLISION-BESIDE-A-SYMLINK-RENAMES-THE-BASELINED-FILE
   ( ^ARENA:arena -- )
   {: ar :}
   s" case_collision_beside_a_symlink_renames_the_baselined_file"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x ar NOTES-BESIDE-LINK
   x rec PASSED OUTCOME-FRESH? TTRUE
   x BASELINED$ s" " T$=
   x s" notes.txt (case variant)" IN-ROOT NOTES$ HOLDS-BYTES
   x s" notes.txt" EXISTS-IN? TFALSE
   x rec PASSED OUTCOME-FRESH? TFALSE
   TEST-DROPBOX:SEEN$ UPLOAD-SEEN$ T$=
   d x STEP-GONE ;

: OTHER$ ( -- str ) s" other notes" ;

\ Rust's fixture: other.txt and the symlinks Link and link in the root,
\ an empty listing, then a continuation listing other.txt as its
\ upload answers it.
: TWO-LINKS ( ^run ^ARENA:arena -- )
   {: x ar :}
   OTHER$ ar IDENTITY {: h:DROPBOX:hash :}
   [: s" /other.txt" s" /other.txt" s" rev-other" h FILE-JSON+ ;]
   ar ENTRIES {: up:str :}
   [: ;] ar ENTRIES s" symlink-collision" false PAGE
   SB-RESET s" /other.txt" s" /other.txt" s" rev-other" h FILE-JSON+
   UPLOAD-ROUTE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT!
   up s" symlink-collision-after" false PAGE
   x s" other.txt" OTHER$ WRITE-IN
   x s" Link" s" upper-target" LINKS-TO
   x s" link" s" lower-target" LINKS-TO ;

: LINKS-SEEN$ ( -- str )
   SB-RESET s" /2/files/list_folder /2/files/upload " SB-APPEND
   s" /2/files/list_folder/continue" SB-APPEND SB$ ;

: CASE-COLLISION-OF-SYMLINKS-STAYS-IN-PLACE ( ^ARENA:arena -- )
   {: ar :}
   s" case_collision_of_symlinks_stays_in_place" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x ar TWO-LINKS
   x rec PASSED OUTCOME-FRESH? TFALSE
   x rec PASSED OUTCOME-FRESH? TFALSE
   TEST-DROPBOX:SEEN$ LINKS-SEEN$ T$=
   x s" Link" IN-ROOT LINK-TARGET$ s" upper-target" T$=
   x s" link" IN-ROOT LINK-TARGET$ s" lower-target" T$=
   x ROOT-NAMES$ S\" Link\nlink\nother.txt" T$=
   d x STEP-GONE ;

: CASE-COLLISION-PASS-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar CASE-ONLY-REMOTE-SPELLING-CHANGE-IS-A-STABLE-NOOP
   ar LOCAL-CASE-COLLISION-IS-RENAMED-BEFORE-PLANNING-AND-THEN-SYNCS
   ar AUTOMATIC-CASE-RENAME-NEVER-BECOMES-A-DROPBOX-DELETE
   ar LOCAL-CASE-COLLISION-PRESERVES-BOTH-DIRECTORY-TREES
   ar CASE-COLLISION-KEEPS-THE-BASELINED-SPELLING-AND-ITS-HISTORY
   ar CASE-COLLISION-SPARES-THE-RECORDED-GREATER-SPELLING
   ar CASE-COLLISION-BESIDE-A-SYMLINK-RENAMES-THE-BASELINED-FILE
   ar CASE-COLLISION-OF-SYMLINKS-STAYS-IN-PLACE ;

\ ---- directory collisions against the fake Dropbox ----------------

\ Rust's file-copy name for node: node (<origin> <the first 12
\ characters of the bytes' identity><suffix>).
: NODE-COPY ( str str str ^ARENA:arena -- str )
   {: o:str b:str s:str ar :}
   b ar IDENTITY DROPBOX:HASH>STR 0 12 PART {: h:str :}
   SB-RESET s" node (" SB-APPEND o SB-APPEND s"  " SB-APPEND
   h SB-APPEND s SB-APPEND s" )" SB-APPEND SB$ ar ARENA:COPY ;

: NODE-DIR ( ^run -- ) s" node" IN-ROOT FS:MAKE-DIR ;

\ Dropbox's file /node, served as rev v of the bytes b and alone on
\ the next listing page, at cursor k.
: NODE-LISTED ( str str str ^ARENA:arena -- )
   {: v:str b:str k:str ar :}
   s" node" v b ar SERVES
   s" node" v b k ar LISTED-ALONE ;

\ The next listing page, at cursor k, holding Dropbox's folder /node.
: NODE-FOLDER-PAGE ( str ^ARENA:arena -- )
   {: k:str ar :}
   [: s" /node" s" /node" FOLDER-JSON+ ;] ar ENTRIES k false PAGE ;

: OUTCOME-KIND$ ( outcome -- str )
   MATCH outcome
      complete OF {: rep :} s" complete" ENDOF
      fresh OF s" fresh" ENDOF
      root-changed OF s" root-changed" ENDOF
   ;MATCH ;

\ The complete pass's replayed and planned counts.
: REPLAYED-PLANNED ( outcome -- n n )
   COMPLETE RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   replayed planned ;

: KIND-OF ( MODEL:baseline -- str )
   MATCH MODEL:baseline
      absent OF s" absent" ENDOF
      present OF {: rem :} s" present" ENDOF
      directory OF s" directory" ENDOF
   ;MATCH ;

\ The baseline's variant at path p, none for no row.
: BASELINE-KIND$ ( ^run str -- str )
   {: x p:str :}
   x RUN-JOURNAL @ p TEST-CLIENT:DISPLAY x RUN-ARENA @ JOURNAL:BASELINE
   MATCH option
      none OF s" none" ENDOF
      some OF KIND-OF ENDOF
   ;MATCH ;

: LOCAL-FILE$ ( -- str ) s" local file preserved beside directory" ;

: REMOTE-DIRECTORY-PRESERVES-A-LOCAL-FILE-UNDER-A-SYNCHRONIZED-NAME
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_directory_preserves_a_local_file_under_a_synchronized_name"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   s" local file" LOCAL-FILE$ s" " ar NODE-COPY {: v:str :}
   s" directory-file-collision" ar NODE-FOLDER-PAGE
   [: ;] ar ENTRIES s" directory-file-collision" false PAGE
   x s" node" IN-ROOT LOCAL-FILE$ FS:WRITE-ALL
   x rec PASSED OUTCOME-KIND$ s" fresh" T$=
   x s" node" IN-ROOT FS:EXISTS? TFALSE
   x v IN-ROOT LOCAL-FILE$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   x rec PASSED REPLAYED-PLANNED {: replayed:n planned:n :}
   planned 2 T= replayed 2 T=
   x s" node" IN-ROOT FS:DIR? TTRUE
   x v IN-ROOT LOCAL-FILE$ HOLDS-BYTES
   x s" node" BASELINE-KIND$ s" directory" T$=
   x v BASELINE-KIND$ s" present" T$=
   x CONFLICTS-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/list_folder/continue /2/files/upload"
   T$=
   d x STEP-GONE ;

: DROPBOX-FILE$ ( -- str ) s" Dropbox file preserved beside directory" ;

\ The first pass: Dropbox's file copied beside the local directory,
\ then deleted there and replaced by a directory.
: DROPBOX-FILE-COPIED ( ^run str str -- )
   {: x rec:str v:str :}
   x RUN-ARENA @ {: ar :}
   x rec PASSED REPLAYED-PLANNED {: replayed:n planned:n :}
   planned 1 T= replayed 2 T=
   x s" node" IN-ROOT FS:DIR? TTRUE
   x v IN-ROOT DROPBOX-FILE$ HOLDS-BYTES
   x s" node" BASELINE-KIND$ s" directory" T$=
   x PENDING-OF VEC:COUNT 0 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   x RUN-JOURNAL @ ar JOURNAL:COMPLETED-RECOVERIES VEC:COUNT 0 T= ;

\ Rust's server answers in order, so its upload of the copy gets a
\ listing page, which does not parse, and get_metadata finds the copy.
: COPY-UPLOAD-UNREAD ( ^ARENA:arena -- )
   {: ar :}
   s" dropbox file" DROPBOX-FILE$ s" " ar NODE-COPY {: low:str :}
   s" Dropbox file" DROPBOX-FILE$ s" " ar NODE-COPY {: v:str :}
   DROPBOX-FILE$ ar IDENTITY DROPBOX:HASH>STR {: h:str :}
   SB-RESET S\" {\qentries\q:[" SB-APPEND
   s" /node" s" /node" FOLDER-JSON+
   S\" ],\qcursor\q:\qremote-directory\q,\qhas_more\q:false}" SB-APPEND
   SB$ ar ARENA:COPY {: page:str :}
   s" /2/files/upload" 200 s" " s" " page TEST-DROPBOX:ROUTE-SCRIPT!
   s" /" low ar JOIN-BYTES s" /" v ar JOIN-BYTES
   s" rev-dropbox-copy" h DROPBOX-FILE$ str> nip TEST-DROPBOX:FILE! ;

: LOCAL-DIRECTORY-PRESERVES-A-DROPBOX-FILE-UNDER-A-SYNCHRONIZED-NAME
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_directory_preserves_a_dropbox_file_under_a_synchronized_name"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x NODE-DIR
   s" Dropbox file" DROPBOX-FILE$ s" " ar NODE-COPY {: v:str :}
   s" rev-remote-file" DROPBOX-FILE$ s" remote-file" ar NODE-LISTED
   s" remote-directory" ar NODE-FOLDER-PAGE
   ar COPY-UPLOAD-UNREAD
   x rec v DROPBOX-FILE-COPIED
   x rec PASSED REPLAYED-PLANNED {: replayed:n planned:n :}
   planned 1 T= replayed 1 T=
   x v IN-ROOT DROPBOX-FILE$ HOLDS-BYTES
   x v BASELINE-KIND$ s" present" T$=
   x CONFLICTS-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download "
   s" /2/files/delete_v2 /2/files/create_folder_v2 " ar JOIN-BYTES
   s" /2/files/list_folder/continue /2/files/upload " ar JOIN-BYTES
   s" /2/files/get_metadata" ar JOIN-BYTES T$=
   d x STEP-GONE ;

: BOUND-COPY$ ( -- str ) s" descriptor-bound Dropbox file copy" ;

: DIRECTORY-COLLISION-COPY-STAYS-BOUND-TO-THE-VERIFIED-ROOT
   ( ^ARENA:arena -- )
   {: ar :}
   s" directory_collision_copy_stays_bound_to_the_verified_root" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x NODE-DIR
   d x SWAP-AT
   s" Dropbox file" BOUND-COPY$ s" " ar NODE-COPY {: v:str :}
   s" rev-root-swap" BOUND-COPY$ s" root-swap-directory-copy" ar
   NODE-LISTED
   [: SWAP-ROOT ;] TEST-DROPBOX:DURING-DOWNLOAD!
   x rec PASSED OUTCOME-KIND$ s" root-changed" T$=
   OLD-ROOT @ v ar TEST-CLIENT:INSIDE BOUND-COPY$ HOLDS-BYTES
   x v IN-ROOT FS:EXISTS? TFALSE
   CANARY @ CANARY$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   x s" node" BASELINE-KIND$ s" none" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download" T$=
   d x STEP-GONE ;

: EXACT$ ( -- str ) s" Dropbox bytes that must remain exact" ;
: RACED$ ( -- str ) s" local file created after observation" ;

\ The copy's destination the race writes; it runs on the fake's task.
TYPED-VARIABLE RACED-COPY str

: RACE-COPY ( -- ) RACED-COPY @ RACED$ FS:WRITE-ALL ;

: DIRECTORY-COLLISION-DESTINATION-RACE-REQUESTS-A-FRESH-SCAN
   ( ^ARENA:arena -- )
   {: ar :}
   s" directory_collision_destination_race_requests_a_fresh_scan"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x NODE-DIR
   s" Dropbox file" EXACT$ s" " ar NODE-COPY {: v:str :}
   x v IN-ROOT RACED-COPY !
   s" rev-destination-race" EXACT$ s" directory-copy-destination-race"
   ar NODE-LISTED
   [: RACE-COPY ;] TEST-DROPBOX:DURING-DOWNLOAD!
   x rec PASSED OUTCOME-KIND$ s" fresh" T$=
   x v IN-ROOT RACED$ HOLDS-BYTES
   x s" node" IN-ROOT FS:DIR? TTRUE
   x PENDING-OF VEC:COUNT 0 T=
   x s" node" BASELINE-KIND$ s" none" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download" T$=
   d x STEP-GONE ;

: OCCUPIED-COPY$ ( -- str )
   s" Dropbox bytes preserved beside an occupied stage" ;
\ Mode 0600, read and write to its owner.
$180 constant MODE-0600

\ The first name in the newline-separated list l that starts with
\ .omabox-download-, else its last name.
: STAGE-NAMED ( str -- str )
   {: l:str :}
   l str> nip {: u:n :}
   l 10 STR:INDEX-OF MATCH option
      none OF l ENDOF
      some OF IDX>N {: k:n :}
         l 0 k PART s" .omabox-download-" STR:STARTS-WITH? if l 0 k PART
         else l k 1+ u PART RECURSE then
      ENDOF
   ;MATCH ;

\ The root's stage PRESTAGED made, beside node.
: STAGE-AMONG ( ^run -- str )
   {: x :}
   x ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u >str STAGE-NAMED {: s:str :}
   s s" .omabox-download-" STR:STARTS-WITH? TTRUE
   x RUN-ROOT @ s x RUN-ARENA @ TEST-CLIENT:INSIDE ;

\ The first variant's stage, staged with the copy's bytes, then
\ holding other bytes; its path.
: OCCUPIED-COPY-STAGE ( ^run str -- str )
   {: x v:str :}
   x [: x v OCCUPIED-COPY$ PRESTAGED ;] IN-ACTIVE-ROOT
   x STAGE-AMONG {: sp:str :}
   sp MODE-0600 FS:CHMOD-MODE
   sp UNRELATED-STAGE$ FS:WRITE-ALL
   sp ;

: OCCUPIED-COLLISION-STAGE-USES-THE-NEXT-SYNCHRONIZED-NAME
   ( ^ARENA:arena -- )
   {: ar :}
   s" occupied_collision_stage_uses_the_next_synchronized_name" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x NODE-DIR
   s" Dropbox file" OCCUPIED-COPY$ s" " ar NODE-COPY {: first:str :}
   s" Dropbox file" OCCUPIED-COPY$ s"  2" ar NODE-COPY {: second:str :}
   s" rev-occupied-stage" OCCUPIED-COPY$
   s" occupied-directory-copy-stage" ar NODE-LISTED
   x first OCCUPIED-COPY-STAGE {: sp:str :}
   x rec PASSED REPLAYED-PLANNED {: replayed:n planned:n :}
   planned 1 T= replayed 2 T=
   x first IN-ROOT FS:EXISTS? TFALSE
   x second IN-ROOT OCCUPIED-COPY$ HOLDS-BYTES
   sp UNRELATED-STAGE$ HOLDS-BYTES
   x s" node" BASELINE-KIND$ s" directory" T$=
   x PENDING-OF VEC:COUNT 0 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download "
   s" /2/files/delete_v2 /2/files/create_folder_v2" ar JOIN-BYTES T$=
   d x STEP-GONE ;

: OLD-FILE$ ( -- str ) s" old Dropbox file" ;
: NEW-FILE$ ( -- str ) s" new Dropbox file" ;

\ The first entry of the newline-separated list l in the directory r
\ that is a file, else its last entry.
: FILE-NAMED ( str str ^ARENA:arena -- str )
   {: r:str l:str ar :}
   l str> nip {: u:n :}
   l 10 STR:INDEX-OF MATCH option
      none OF r l ar TEST-CLIENT:INSIDE ENDOF
      some OF IDX>N {: k:n :}
         r l 0 k PART ar TEST-CLIENT:INSIDE {: f:str :}
         f FS:FILE? if f
         else r l k 1+ u PART ar RECURSE then
      ENDOF
   ;MATCH ;

: CHANGED-DROPBOX-FILE-DURING-DIRECTORY-CONVERSION-REPLANS-WITHOUT-A-CONFLICT-ROW
   ( ^ARENA:arena -- )
   {: ar :}
   s" changed_dropbox_file_during_directory_conversion_replans_without_a_conflict_row"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x NODE-DIR
   \ Dropbox's /node is at rev-new, and rev-old stays downloadable.
   s" node" s" rev-new" NEW-FILE$ ar FILE-AT
   s" rev-old" OLD-FILE$ s" old-file" ar NODE-LISTED
   x rec PASSED OUTCOME-KIND$ s" fresh" T$=
   x s" node" IN-ROOT FS:DIR? TTRUE
   x ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   x RUN-ROOT @ READ-BUF u >str ar FILE-NAMED OLD-FILE$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   x s" node" BASELINE-KIND$ s" none" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download "
   s" /2/files/delete_v2 /2/files/get_metadata" ar JOIN-BYTES T$=
   d x STEP-GONE ;

: BESIDE$ ( -- str ) s" unrelated Dropbox file" ;
\ One length: the fake serves a rev's bytes at the size FILE! gave it.
: COLLIDED$ ( -- str ) s" Dropbox bytes held" ;
: FORGED$ ( -- str ) s" forged bytes, held" ;

\ The one listing page, cursor k: /node at rev-held with COLLIDED$'s
\ identity, and /other.txt at rev-other.
: HELD-PAGE ( str ^ARENA:arena -- )
   {: k:str ar :}
   COLLIDED$ ar IDENTITY {: h:DROPBOX:hash :}
   BESIDE$ ar IDENTITY {: o:DROPBOX:hash :}
   [: s" /node" s" /node" s" rev-held" h FILE-JSON+ COMMA+
      s" /other.txt" s" /other.txt" s" rev-other" o FILE-JSON+ ;]
   ar ENTRIES k false PAGE ;

\ The empty local directory node; Dropbox's file /node and other.txt,
\ served, on the one listing page.
: HELD-COLLISION ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   x NODE-DIR
   s" node" s" rev-held" COLLIDED$ ar FILE-AT
   s" other.txt" s" rev-other" BESIDE$ ar SERVES
   s" held-collision-copy" ar HELD-PAGE ;

\ The pass completes, other.txt planned and replayed.
: OTHER-SYNCED ( ^run str -- )
   PASSED REPLAYED-PLANNED 1 T= 1 T= ;

\ REPLAY's line for node's copy, blocked for the reason r.
: HELD-LINE ( str -- str )
   SB-RESET s" exact download blocked for its path `node`: "
   SB-APPEND SB-APPEND SB$ ;

\ The pass held node, its copy blocked for the reason r and logged
\ once, and synced other.txt.
: COLLISION-HELD ( str ^run str str -- )
   {: d:str x rec:str r:str :}
   x RUN-ARENA @ {: ar :}
   d [: x rec OTHER-SYNCED ;] ar LOGGED {: t:str :}
   t 10 STR:COUNT-CHAR 1 T=
   t r HELD-LINE STR:CONTAINS? TTRUE
   s" Dropbox file" COLLIDED$ s" " ar NODE-COPY {: v:str :}
   x v IN-ROOT FS:EXISTS? TFALSE
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   x CONFLICTS-OF VEC:COUNT 0 T=
   x s" node" BASELINE-KIND$ s" none" T$=
   x s" other.txt" IN-ROOT BESIDE$ HOLDS-BYTES
   x s" other.txt" BASELINE-KIND$ s" present" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/download /2/files/download" T$= ;

\ COLLISION-HELD, with node left empty.
: NODE-HELD ( str ^run str str -- )
   {: d:str x rec:str r:str :}
   d x rec r COLLISION-HELD
   x s" node" IN-ROOT READ-BUF READ-CAP FS-LIST:NAMES 0 T= ;

\ Dropbox's 409 for the next API call, the copy's download.
: REFUSE-COPY ( -- )
   409 s" " s" " LOOKUP-NOT-FOUND$ TEST-DROPBOX:SCRIPT! ;

\ Nothing planned or replayed, node alone held: the held collision
\ is all that prevents rest.
: STILL-HELD ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 0 T= replayed 0 T= blocked 1 T= conflicts 0 T=
   rested TFALSE ;

: A-REFUSED-COLLISION-COPY-HOLDS-ITS-PATH ( ^ARENA:arena -- )
   {: ar :}
   s" a refused collision copy holds its path" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x HELD-COLLISION
   s" rev-held" COLLIDED$ TEST-DROPBOX:CONTENT!
   [: REFUSE-COPY ;] TEST-DROPBOX:DURING-LISTING!
   d x rec s" download_unavailable 409" NODE-HELD
   [: REFUSE-COPY ;] TEST-DROPBOX:DURING-LISTING!
   s" held-again" ar EMPTY-PAGE
   x rec PASSED COMPLETE STILL-HELD
   d x STEP-GONE ;

\ Nothing planned, replayed or recorded: the new conflict's held copy is
\ all that prevents rest.
: COPY-UNRESTED ( report -- )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 0 T= replayed 0 T= conflicts 0 T= rested TFALSE ;

: A-REFUSED-CONFLICT-COPY-PREVENTS-REST ( ^ARENA:arena -- )
   {: ar :}
   s" a refused conflict copy prevents rest" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" cursor-refused" DIVERGED
   s" rev-remote" DIVERGED-REMOTE$ TEST-DROPBOX:CONTENT!
   [: REFUSE-COPY ;] TEST-DROPBOX:DURING-LISTING!
   x rec PASSED COMPLETE COPY-UNRESTED
   d x STEP-GONE ;

: AN-UNVERIFIED-COLLISION-COPY-HOLDS-ITS-PATH ( ^ARENA:arena -- )
   {: ar :}
   s" an unverified collision copy holds its path" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x HELD-COLLISION
   s" rev-held" FORGED$ TEST-DROPBOX:CONTENT!
   d x rec s" download_verification_failed" NODE-HELD
   d x STEP-GONE ;

: INNER$ ( -- str ) s" local file beneath a held collision" ;

: A-HELD-COLLISION-HOLDS-THE-PATHS-BENEATH-IT ( ^ARENA:arena -- )
   {: ar :}
   s" a held collision holds the paths beneath it" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x HELD-COLLISION
   x RUN-ROOT @ s" node/inner.txt" INNER$ ar WRITE-AT
   s" rev-held" COLLIDED$ TEST-DROPBOX:CONTENT!
   [: REFUSE-COPY ;] TEST-DROPBOX:DURING-LISTING!
   d x rec s" download_unavailable 409" COLLISION-HELD
   x STAGING$ READ-BUF READ-CAP FS-LIST:NAMES 0 T=
   x s" node/inner.txt" IN-ROOT INNER$ HOLDS-BYTES
   d x STEP-GONE ;

: DIRECTORY-COLLISION-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar REMOTE-DIRECTORY-PRESERVES-A-LOCAL-FILE-UNDER-A-SYNCHRONIZED-NAME
   ar LOCAL-DIRECTORY-PRESERVES-A-DROPBOX-FILE-UNDER-A-SYNCHRONIZED-NAME
   ar DIRECTORY-COLLISION-COPY-STAYS-BOUND-TO-THE-VERIFIED-ROOT
   ar DIRECTORY-COLLISION-DESTINATION-RACE-REQUESTS-A-FRESH-SCAN
   ar OCCUPIED-COLLISION-STAGE-USES-THE-NEXT-SYNCHRONIZED-NAME
   ar CHANGED-DROPBOX-FILE-DURING-DIRECTORY-CONVERSION-REPLANS-WITHOUT-A-CONFLICT-ROW
   ar A-REFUSED-COLLISION-COPY-HOLDS-ITS-PATH
   ar A-REFUSED-CONFLICT-COPY-PREVENTS-REST
   ar AN-UNVERIFIED-COLLISION-COPY-HOLDS-ITS-PATH
   ar A-HELD-COLLISION-HOLDS-THE-PATHS-BENEATH-IT ;

\ ---- directory deletions against the fake Dropbox -----------------

: PRESENT-BASELINE? ( MODEL:baseline -- bool )
   MATCH MODEL:baseline
      absent OF false ENDOF
      present OF drop true ENDOF
      directory OF false ENDOF
   ;MATCH ;

\ Rust's FakeResponse::json for the route r, any API call when r is
\ empty: the JSON q appends.
: ANSWERS ( [ -- ] str -- )
   {: q r:str :}
   SB-RESET q execute
   r 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT! ;

\ ANSWERS of {"metadata": the entry q appends}.
: METADATA-ANSWERS ( [ -- ] str -- )
   {: q r:str :}
   [: S\" {\qmetadata\q:" SB-APPEND q execute s" }" SB-APPEND ;]
   r ANSWERS ;

\ The words of a, which single spaces part: the first, then the rest.
: FIRST-WORD ( str -- str )
   {: a:str :}
   a 32 STR:INDEX-OF MATCH option
      none OF a ENDOF
      some OF IDX>N {: k:n :} a 0 k PART ENDOF
   ;MATCH ;

: REST-WORDS ( str -- str )
   {: a:str :}
   a str> nip {: u:n :}
   a 32 STR:INDEX-OF MATCH option
      none OF a u u PART ENDOF
      some OF IDX>N 1+ {: k:n :} a k u PART ENDOF
   ;MATCH ;

: WORD-AT ( str n -- str )
   {: k:n :}
   k 0 ?do REST-WORDS loop FIRST-WORD ;

\ Rust's probes' bodies: those of the list_folder requests after the
\ first.
: PROBE-ARGS ( ^ARENA:arena -- ^VEC:vector<str> )
   {: ar :}
   ar [type] str NEW-VECTOR {: v :}
   LIST$ TEST-DROPBOX:CALLS 1 ?do
      LIST$ TEST-DROPBOX:BODIES-TO$ i WORD-AT ar ARENA:COPY v VEC:PUSH !
   loop
   v ;

\ The JSON value at the pointer p in b, null for none, as Rust's
\ value[...] reads it.
: MEMBER$ ( str str -- str )
   {: b:str p:str :}
   b p JSON:POINTER-SPAN 0= if 2drop s" null" exit then
   {: off:n len:n :}
   b off off len + PART ;

: MEMBER= ( str str str -- bool )
   {: b:str p:str v:str :}
   b p MEMBER$ v JSON:VALUE= ;

\ Rust's probe of the folder p: at most one entry, neither recursive
\ nor with deleted entries.
: PROBED-AS ( str str -- )
   {: b:str p:str :}
   SB-RESET p TEST-CLIENT:QUOTED+
   b s" /path" SB$ MEMBER= TTRUE
   b s" /limit" s" 1" MEMBER= TTRUE
   b s" /recursive" s" true" MEMBER= TFALSE
   b s" /include_deleted" s" true" MEMBER= TFALSE ;

: REMOTE-DIRECTORY-DELETION-REMOVES-LOCAL-DIRECTORIES-DEEPEST-FIRST
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_directory_deletion_removes_local_directories_deepest_first"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" gone" IN-ROOT FS:MAKE-DIR
   x s" gone/child" IN-ROOT FS:MAKE-DIR
   x s" gone" SEED-DIRECTORY-BASELINE
   x s" gone/child" SEED-DIRECTORY-BASELINE
   s" directories-deleted" ar EMPTY-PAGE
   x rec PASSED COMPLETE RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   planned 2 T= replayed 2 T=
   x s" gone" IN-ROOT FS:EXISTS? TFALSE
   x s" gone" NO-BASELINE? TTRUE
   x s" gone/child" NO-BASELINE? TTRUE
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ LIST$ T$=
   d x STEP-GONE ;

: LEAF-JSON+ ( DROPBOX:hash -- )
   {: h:DROPBOX:hash :}
   s" /gone/child/leaf.txt" s" /Gone/Child/leaf.txt" s" rev-leaf" h
   FILE-JSON+ ;

\ Rust's first pass over the tree: its listing, then the leaf's delete.
: TREE-LISTED ( DROPBOX:hash ^ARENA:arena -- )
   {: h:DROPBOX:hash ar :}
   [: s" /gone" s" /Gone" FOLDER-JSON+ COMMA+
      s" /gone/child" s" /Gone/Child" FOLDER-JSON+ COMMA+
      h LEAF-JSON+ ;] ar ENTRIES s" cursor-tree" false PAGE
   [: h LEAF-JSON+ ;] DELETE$ METADATA-ANSWERS ;

\ The second: the delta shows the leaf gone, so the child folder is
\ probed and deleted.
: LEAF-GONE ( ^ARENA:arena -- )
   {: ar :}
   [: s" /gone/child/leaf.txt" s" /Gone/Child/leaf.txt" DELETED-JSON+ ;]
   ar ENTRIES s" cursor-after-leaf" false PAGE
   s" probe-child" ar EMPTY-PAGE
   [: s" /gone/child" s" /Gone/Child" FOLDER-JSON+ ;]
   DELETE$ METADATA-ANSWERS ;

\ The third: the delta shows the child gone, so the parent is probed
\ and deleted.
: CHILD-GONE ( ^ARENA:arena -- )
   {: ar :}
   [: s" /gone/child" s" /Gone/Child" DELETED-JSON+ ;]
   ar ENTRIES s" cursor-after-child" false PAGE
   s" probe-gone" ar EMPTY-PAGE
   [: s" /gone" s" /Gone" FOLDER-JSON+ ;] DELETE$ METADATA-ANSWERS ;

\ Whether the k-th delete_v2 body holds the JSON value v.
: DELETED-AS? ( n str -- bool )
   {: k:n v:str :}
   DELETE$ TEST-DROPBOX:BODIES-TO$ k WORD-AT v JSON:VALUE= ;

: TREE-DELETED ( -- )
   DELETE$ TEST-DROPBOX:CALLS 3 T=
   0 S\" {\qpath\q:\q/Gone/Child/leaf.txt\q,\qparent_rev\q:\qrev-leaf\q}"
   DELETED-AS? TTRUE
   1 S\" {\qpath\q:\q/Gone/Child\q}" DELETED-AS? TTRUE
   2 S\" {\qpath\q:\q/Gone\q}" DELETED-AS? TTRUE ;

: TREE-PROBED ( ^ARENA:arena -- )
   PROBE-ARGS {: v :}
   v VEC:COUNT 2 T=
   v 0 VEC:AT @ s" /Gone/Child" PROBED-AS
   v 1 VEC:AT @ s" /Gone" PROBED-AS ;

: LOCAL-DIRECTORY-DELETION-REMOVES-DROPBOX-DIRECTORIES-AFTER-THEIR-ENTRIES
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_directory_deletion_removes_dropbox_directories_after_their_entries"
   T-LABEL
   TEST-DROPBOX:RESET
   s" leaf payload" ar IDENTITY ar TREE-LISTED
   ar LEAF-GONE ar CHILD-GONE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" Gone" SEED-DIRECTORY-BASELINE
   x s" Gone/Child" SEED-DIRECTORY-BASELINE
   x s" Gone/Child/leaf.txt" s" leaf payload" s" rev-leaf" ar REMOTE-FILE
   SEED-BASELINE
   x rec PASSED COMPLETE 1 1 2 COUNTED
   x rec PASSED COMPLETE 1 1 1 COUNTED
   x rec PASSED COMPLETE 1 1 0 COUNTED
   x s" Gone" IN-ROOT FS:EXISTS? TFALSE
   x s" Gone" NO-BASELINE? TTRUE
   x s" Gone/Child" NO-BASELINE? TTRUE
   x s" Gone/Child/leaf.txt" NO-BASELINE? TTRUE
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   TREE-DELETED
   ar TREE-PROBED
   TEST-DROPBOX:SEEN$ s" /2/files/create_folder_v2" STR:CONTAINS? TFALSE
   d x STEP-GONE ;

: BOUND-ANY ( JOURNAL:dropbox-binding-write -- )
   MATCH JOURNAL:dropbox-binding-write
      bound OF ENDOF
      already-bound OF ENDOF
      mismatch OF drop ENDOF
   ;MATCH ;

: LOCAL-DIRECTORY-DELETION-WAITS-FOR-UNSYNCHRONIZED-DROPBOX-ENTRIES
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_directory_deletion_waits_for_unsynchronized_dropbox_entries"
   T-LABEL
   TEST-DROPBOX:RESET
   [: s" /docs" s" /docs" FOLDER-JSON+ COMMA+
      s" /docs/note.paper" s" /docs/note.paper" s" rev-paper"
      UNSUPPORTED-FILE-JSON+ ;] ar ENTRIES s" cursor-paper" false PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" docs" SEED-DIRECTORY-BASELINE
   x rec PASSED COMPLETE 0 0 2 COUNTED
   x s" docs" IN-ROOT FS:EXISTS? TFALSE
   x s" docs" FOLDER-BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ LIST$ T$=
   x RUN-JOURNAL @ s" dbid:account" s" namespace" s" "
   JOURNAL-DROPBOX--BINDING:MAKE ar JOURNAL:BIND-DROPBOX-ROOT BOUND-ANY
   x RUN-JOURNAL @ JOURNAL:CLOSE
   d x JOURNAL-FILE x RUN-ARENA @ ATTENTION:RENDER
   s\" \n- docs: deleted here, kept on Dropbox: its Dropbox folder still holds entries\n"
   STR:CONTAINS? TTRUE
   d x OPENED-AGAIN
   d x STEP-GONE ;

\ The listing, then the probe, with no delete between or after.
: TWO-LISTS$ ( -- str ) s" /2/files/list_folder /2/files/list_folder" ;

: DROPBOX-DIRECTORY-THAT-GAINED-AN-ENTRY-IS-NOT-DELETED-FROM-A-STALE-INVENTORY
   ( ^ARENA:arena -- )
   {: ar :}
   s" dropbox_directory_that_gained_an_entry_is_not_deleted_from_a_stale_inventory"
   T-LABEL
   TEST-DROPBOX:RESET
   s" late arrival" ar IDENTITY {: late:DROPBOX:hash :}
   [: s" /gone" s" /gone" FOLDER-JSON+ ;]
   ar ENTRIES s" cursor-empty" false PAGE
   [: s" /gone/late.txt" s" /gone/late.txt" s" rev-late" late
      FILE-JSON+ ;] ar ENTRIES s" probe-late" false PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" gone" SEED-DIRECTORY-BASELINE
   x rec PASSED OUTCOME-FRESH? TTRUE
   x s" gone" IN-ROOT FS:EXISTS? TFALSE
   x s" gone" FOLDER-BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ TWO-LISTS$ T$=
   d x STEP-GONE ;

\ The file the listing's hook writes, Rust's gated write.
TYPED-VARIABLE RACED str
: AFTER-SCAN$ ( -- str ) s" created after scan" ;
: RACE ( -- ) RACED @ AFTER-SCAN$ FS:WRITE-ALL ;

: CHILD-CREATED-AFTER-SCAN-FORCES-AN-IMMEDIATE-DIRECTORY-RESCAN
   ( ^ARENA:arena -- )
   {: ar :}
   s" child_created_after_scan_forces_an_immediate_directory_rescan"
   T-LABEL
   TEST-DROPBOX:RESET
   s" directory-raced-after-scan" ar EMPTY-PAGE
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" gone" IN-ROOT FS:MAKE-DIR
   x s" gone" SEED-DIRECTORY-BASELINE
   x s" gone/new.txt" IN-ROOT RACED !
   [: RACE ;] TEST-DROPBOX:DURING-LISTING!
   x rec PASSED OUTCOME-FRESH? TTRUE
   RACED @ AFTER-SCAN$ HOLDS-BYTES
   x s" gone" FOLDER-BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ LIST$ T$=
   d x STEP-GONE ;

: NEW-CHILD$ ( -- str ) s" new child" ;

\ Rust's answers in order, whatever the route: the empty listing, the
\ parent's folder, then the new child's file.
: PARENT-DELETED ( DROPBOX:hash -- )
   {: h:DROPBOX:hash :}
   [: S\" {\qentries\q:[],\qcursor\q:\qparent-deleted\q," SB-APPEND
      S\" \qhas_more\q:false}" SB-APPEND ;] s" " ANSWERS
   [: s" /parent" s" /parent" FOLDER-JSON+ ;] s" " METADATA-ANSWERS
   [: s" /parent/new.txt" s" /parent/new.txt" s" rev-new-child" h
      FILE-JSON+ ;] s" " ANSWERS ;

: CHILD-SYNCED-SEEN$ ( -- str )
   s" /2/files/list_folder /2/files/create_folder_v2 /2/files/upload" ;

: CHILD-PRESENT? ( ^run -- bool )
   {: x :}
   x RUN-JOURNAL @ s" parent/new.txt" TEST-CLIENT:DISPLAY x RUN-ARENA @
   JOURNAL:BASELINE STORED-BASELINE PRESENT-BASELINE? ;

: NONEMPTY-DIRECTORY-DELETE-REOBSERVES-AND-SYNCS-THE-NEW-CHILD
   ( ^ARENA:arena -- )
   {: ar :}
   s" nonempty_directory_delete_reobserves_and_syncs_the_new_child"
   T-LABEL
   TEST-DROPBOX:RESET
   NEW-CHILD$ ar IDENTITY PARENT-DELETED
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x s" parent" IN-ROOT FS:MAKE-DIR
   x s" parent/new.txt" IN-ROOT NEW-CHILD$ FS:WRITE-ALL
   x s" parent" SEED-DIRECTORY-BASELINE
   x rec PASSED OUTCOME-FRESH? TTRUE
   x s" parent/new.txt" IN-ROOT NEW-CHILD$ HOLDS-BYTES
   x s" parent" FOLDER-BASELINE-AT
   x CHILD-PRESENT? TTRUE
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ CHILD-SYNCED-SEEN$ T$=
   d x STEP-GONE ;

: DIRECTORY-DELETION-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar REMOTE-DIRECTORY-DELETION-REMOVES-LOCAL-DIRECTORIES-DEEPEST-FIRST
   ar LOCAL-DIRECTORY-DELETION-REMOVES-DROPBOX-DIRECTORIES-AFTER-THEIR-ENTRIES
   ar LOCAL-DIRECTORY-DELETION-WAITS-FOR-UNSYNCHRONIZED-DROPBOX-ENTRIES
   ar DROPBOX-DIRECTORY-THAT-GAINED-AN-ENTRY-IS-NOT-DELETED-FROM-A-STALE-INVENTORY
   ar CHILD-CREATED-AFTER-SCAN-FORCES-AN-IMMEDIATE-DIRECTORY-RESCAN
   ar NONEMPTY-DIRECTORY-DELETE-REOBSERVES-AND-SYNCS-THE-NEW-CHILD ;

\ ---- the root and exclusions against the fake Dropbox ---------------

: UNROOTED-PASS? ( outcome -- bool )
   MATCH outcome
      complete OF drop false ENDOF
      fresh OF false ENDOF
      root-changed OF true ENDOF
   ;MATCH ;

\ The report's replayed and sync-errors.
: REPLAYED-ERRORS ( report -- n n )
   RECONCILE-REPORT:UNMAKE
   {: replayed:n noops:n planned:n blocked:n errors:n conflicts:n
      rested:bool :}
   replayed errors ;

\ Rust's replay_local_operations: the pending plans' local operations
\ below the run's root.
: LOCAL-REPLAYED ( ^run -- ^REPLAY:replay-report )
   {: x :}
   x [: x RUN-JOURNAL @ swap x ROOT$ x PENDING-OF x RUN-ARENA @
      REPLAY:REPLAY-LOCAL-PLANS-AT ;] IN-ACTIVE-ROOT ;

: REJECTION$ ( MODEL:blockage -- str )
   MATCH MODEL:blockage
      unsupported-file-size OF s" " ENDOF
      remote-rejected OF ENDOF
      download-unavailable OF drop s" " ENDOF
      download-verification-failed OF s" " ENDOF
      stage-occupied OF s" " ENDOF
      local-object-in-way OF s" " ENDOF
      remote-object OF s" " ENDOF
      conflict-copy-occupied OF s" " ENDOF
   ;MATCH ;

\ The tag of the plan's remote-rejected block, else empty.
: REJECTED-TAG$ ( JOURNAL:plan-record -- str )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   s MATCH JOURNAL:plan-status
      pending OF s" " ENDOF
      blocked OF drop REJECTION$ ENDOF
      completed OF s" " ENDOF
   ;MATCH ;

: KEEP$ ( -- str ) s" must not be deleted from a replacement root" ;

\ Rust's swap: the run's root renamed old-root in the case directory
\ d, and a new root holding keep.txt's bytes.
: REPLACED-ROOT ( str ^run -- )
   {: d:str x :}
   x ROOT$ d s" old-root" x RUN-ARENA @ TEST-CLIENT:INSIDE FS:RENAME-FILE
   x ROOT$ FS:MAKE-DIR
   x s" keep.txt" IN-ROOT KEEP$ FS:WRITE-ALL ;

: REPLACED-LOCAL-ROOT-NEVER-REPLAYS-PENDING-DELETION
   ( ^ARENA:arena -- )
   {: ar :}
   s" replaced_local_root_never_replays_pending_deletion" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   KEEP$ s" rev-old" ar REMOTE-FILE {: rem :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   x s" keep.txt" IN-ROOT KEEP$ FS:WRITE-ALL
   x s" keep.txt" rem SEED-BASELINE
   x s" keep.txt" rem MODEL-BASELINE:PRESENT c MODEL-LOCAL:MAKE
   LOCAL-PRESENT REMOTE-ABSENT RECORD-FIXTURE-PLAN drop
   d x REPLACED-ROOT
   x rec PASSED UNROOTED-PASS? TTRUE
   x s" keep.txt" IN-ROOT KEEP$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 1 T=
   TEST-DROPBOX:SEEN$ s" " T$=
   d x STEP-GONE ;

: EVENT$ ( pass-event -- str )
   MATCH pass-event
      ok OF s" ok" ENDOF
      fresh OF s" fresh" ENDOF
      root-changed OF s" root-changed" ENDOF
   ;MATCH ;

: NEW-CONFLICT-ANSWERS-A-REPLACED-ROOT ( ^ARENA:arena -- )
   {: ar :}
   s" new conflict answers a replaced root" T-LABEL
   ar STEP-RUN {: d:str x :}
   x s" c-diverged.txt" IN-ROOT DIVERGED-LOCAL$ FS:WRITE-ALL
   DIVERGED-LOCAL$ ar IDENTITY MODEL-LOCAL:MAKE
   DIVERGED-REMOTE$ s" rev-remote-conflict" ar REMOTE-FILE
   MODEL-CONFLICT:DIVERGENT {: c :}
   d x REPLACED-ROOT
   x s" c-diverged.txt" IN-ROOT DIVERGED-LOCAL$ FS:WRITE-ALL
   x NEW-PLANNING {: pl :}
   pl s" c-diverged.txt" ar CANONICAL s" c-diverged.txt" TEST-CLIENT:DISPLAY c
   NEW-CONFLICT EVENT$ s" root-changed" T$=
   x NO-CONFLICT-RECORD
   x ROOT$ S\" c-diverged.txt\nkeep.txt" NAMES-ARE
   d s" old-root/c-diverged.txt" ar TEST-CLIENT:INSIDE DIVERGED-LOCAL$ HOLDS-BYTES
   d x STEP-GONE ;

: SWAP-LOCAL$ ( -- str ) s" local side of a conflict across a swap" ;
: SWAP-REMOTE$ ( -- str ) s" Dropbox side of a conflict across a swap" ;
: STAND-IN$ ( -- str ) s" upload bytes the stand-in also holds" ;

\ The stand-in's later.txt; the swap writes it on the fake's task.
TYPED-VARIABLE STAND-IN-UPLOAD str

\ SWAP-ROOT, the stand-in then holding later.txt's bytes.
: SWAP-WITH-UPLOAD ( -- )
   SWAP-ROOT STAND-IN-UPLOAD @ STAND-IN$ FS:WRITE-ALL ;

\ earlier.txt's conflict copies its Dropbox side, whose download swaps
\ the root; later.txt, a new file, is then decided against a root that
\ is no longer the journal's.
: ROOT-SWAP-DURING-PLANNING-STAGES-NOTHING-FROM-THE-STAND-IN
   ( ^ARENA:arena -- )
   {: ar :}
   s" root swap during planning stages nothing from the stand-in"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   d x SWAP-AT
   x s" later.txt" IN-ROOT STAND-IN-UPLOAD !
   x s" earlier.txt" IN-ROOT SWAP-LOCAL$ FS:WRITE-ALL
   x s" later.txt" IN-ROOT STAND-IN$ FS:WRITE-ALL
   s" earlier.txt" s" rev-swap-conflict" SWAP-REMOTE$ ar SERVES
   s" earlier.txt" s" rev-swap-conflict" SWAP-REMOTE$ s" swap-planning"
   ar LISTED-ALONE
   [: SWAP-WITH-UPLOAD ;] TEST-DROPBOX:DURING-DOWNLOAD!
   x rec PASSED OUTCOME-KIND$ s" root-changed" T$=
   x ROOT$ S\" canary.txt\nlater.txt" NAMES-ARE
   CANARY @ CANARY$ HOLDS-BYTES
   STAND-IN-UPLOAD @ STAND-IN$ HOLDS-BYTES
   x STAGING$ STAND-IN$ ar IDENTITY DROPBOX:HASH>STR ar TEST-CLIENT:INSIDE
   FS:EXISTS? TFALSE
   OLD-ROOT @ s" later.txt" ar TEST-CLIENT:INSIDE STAND-IN$ HOLDS-BYTES
   x CONFLICTS-OF VEC:COUNT 1 T=
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/download" T$=
   d x STEP-GONE ;

: INVALID-NAME$ ( -- str ) s\" invalid-\xFF.txt" ;
: INVALID-BYTES$ ( -- str ) s" invalid path bytes" ;
: REJECTED-BYTES$ ( -- str ) s" rejected bytes" ;
: GOOD-BYTES$ ( -- str ) s" uploaded bytes" ;
: SIBLING-BYTES$ ( -- str ) s" downloaded sibling bytes" ;

: UPLOAD-SUMMARY$ ( str -- str )
   {: t:str :}
   t s" conflict" STR:= if s" path/conflict/file/..." exit then
   t s" disallowed_name" STR:= if
      s" path/disallowed_name/..." exit
   then
   s" path/other/..." ;

\ Rust's upload_error for a reason of tag t, in SB.
: UPLOAD-ERROR$ ( str -- str )
   {: t:str :}
   SB-RESET S\" {\qerror_summary\q:" SB-APPEND
   t UPLOAD-SUMMARY$ TEST-CLIENT:QUOTED+
   S\" ,\qerror\q:{\q.tag\q:\qpath\q,\qreason\q:{\q.tag\q:" SB-APPEND
   t TEST-CLIENT:QUOTED+
   S\" },\qupload_session_id\q:\qfixture-session\q}}" SB-APPEND SB$ ;

\ The next upload is refused 409 for the wire tag t.
: UPLOAD-REFUSED ( str -- )
   {: t:str :}
   UPLOAD-ROUTE$ 409 s" " s" " t UPLOAD-ERROR$
   TEST-DROPBOX:ROUTE-SCRIPT! ;

: DISALLOWED-UPLOAD ( DROPBOX:hash -- )
   drop s" disallowed_name" UPLOAD-REFUSED ;

: FUTURE-WRITE ( DROPBOX:hash -- )
   drop s" future_write_error" UPLOAD-REFUSED ;

\ The next upload is refused 409 content_hash_mismatch, a top-level tag.
: HASH-MISMATCH ( DROPBOX:hash -- )
   drop SB-RESET
   S\" {\qerror_summary\q:\qcontent_hash_mismatch/\q," SB-APPEND
   S\" \qerror\q:{\q.tag\q:\qcontent_hash_mismatch\q}}" SB-APPEND
   UPLOAD-ROUTE$ 409 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT! ;

\ The next upload and its read-back answer /moved.txt with content h.
: MOVED ( DROPBOX:hash -- )
   {: h:DROPBOX:hash :}
   SB-RESET
   s" /moved.txt" s" /moved.txt" s" moved-revision" h FILE-JSON+
   UPLOAD-ROUTE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT!
   METADATA-ROUTE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT! ;

\ A listing page of good.txt, content g, and download.txt, content sib,
\ with the cursor k.
: SIBLINGS-PAGE ( DROPBOX:hash DROPBOX:hash str ^ARENA:arena -- )
   {: g:DROPBOX:hash sib:DROPBOX:hash k:str ar :}
   [: s" /good.txt" s" /good.txt" s" good-revision" g FILE-JSON+ COMMA+
      s" /download.txt" s" /download.txt" s" download-sibling-revision"
      sib FILE-JSON+ ;]
   ar ENTRIES k false PAGE ;

\ Rust's answers: the rejection q for the rejected content, good.txt's
\ upload, both passes' listings and download.txt, then q again.
: REJECTED-SERVED ( [ DROPBOX:hash -- ] ^ARENA:arena -- )
   {: q ar :}
   REJECTED-BYTES$ ar IDENTITY {: rc:DROPBOX:hash :}
   GOOD-BYTES$ ar IDENTITY {: g:DROPBOX:hash :}
   SIBLING-BYTES$ ar IDENTITY {: sib:DROPBOX:hash :}
   rc q execute
   SB-RESET s" /good.txt" s" /good.txt" s" good-revision" g FILE-JSON+
   UPLOAD-ROUTE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT!
   g sib s" after-rejection" ar SIBLINGS-PAGE
   s" download.txt" s" download-sibling-revision" SIBLING-BYTES$ ar
   SERVES
   g sib s" after-due-rejection" ar SIBLINGS-PAGE
   rc q execute ;

\ The local file p holding b, and its upload recorded pending.
: UPLOAD-PENDING ( ^run str str -- )
   {: x p:str b:str :}
   x p b WRITE-IN
   x p b x RUN-ARENA @ IDENTITY UPLOAD-PLANNED drop ;

\ The first pass uploads good.txt, installs download.txt and blocks the
\ invalid path and bad.txt, the second as tag t; bad.txt's plan id.
: REJECTED-FIRST ( ^run str str -- JOURNAL:plan-id )
   {: x rec:str t:str :}
   x RUN-ARENA @ {: ar :}
   x rec PASSED COMPLETE REPLAYED-ERRORS {: replayed:n errors:n :}
   \ Departure 2: download.txt installs in the pass, so 2, not 1.
   replayed 2 T=
   errors 2 T=
   x STEPPED
   x s" download.txt" IN-ROOT SIBLING-BYTES$ HOLDS-BYTES
   x s" good.txt" GOOD-BYTES$ s" good-revision" ar REMOTE-FILE
   BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF {: held :}
   held VEC:COUNT 2 T=
   held 0 PLAN-PATH$ INVALID-NAME$ T$=
   held 1 PLAN-PATH$ s" bad.txt" T$=
   held 0 VEC:AT @ REJECTED-TAG$ s" invalid_path" T$=
   held 1 VEC:AT @ REJECTED-TAG$ t T$=
   held 1 VEC:AT @ ID-OF ;

\ Reopened, the remote replay reports nothing blocked; bad, blocked as
\ tag t and due now, is sent again by a second pass.
: REJECTED-DUE ( str ^run str JOURNAL:plan-id str -- )
   {: d:str x rec:str bad t:str :}
   d x REOPENED
   x REMOTE-REPLAYED BLOCKS VEC:COUNT 0 T=
   x bad t REJECTED-AS 0 BLOCKED-UNTIL
   x rec PASSED COMPLETE REPLAYED-ERRORS nip 2 T=
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 2 T= ;

\ The requests: the rejection's rs, good.txt's upload, the listing, the
\ download and the continuation, then rs again; no account request
\ (departure 5).
: REJECTED-SEEN$ ( str -- str )
   {: rs:str :}
   SB-RESET rs SB-APPEND
   s"  /2/files/upload /2/files/list_folder /2/files/download" SB-APPEND
   s"  /2/files/list_folder/continue " SB-APPEND rs SB-APPEND SB$ ;

: REJECTED-BODIES$ ( -- str )
   SB-RESET REJECTED-BYTES$ SB-APPEND s"  " SB-APPEND
   GOOD-BYTES$ SB-APPEND s"  " SB-APPEND
   REJECTED-BYTES$ SB-APPEND SB$ ;

\ Rust's rejected_path_case: the rejection q, whose requests' paths are
\ rs, blocks bad.txt as tag t while unrelated paths sync.
: REJECTED-PATH-CASE ( [ DROPBOX:hash -- ] str str ^ARENA:arena -- )
   {: q rs:str t:str ar :}
   TEST-DROPBOX:RESET
   q ar REJECTED-SERVED
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x INVALID-NAME$ INVALID-BYTES$ UPLOAD-PENDING
   x s" bad.txt" REJECTED-BYTES$ UPLOAD-PENDING
   x s" good.txt" GOOD-BYTES$ UPLOAD-PENDING
   x rec t REJECTED-FIRST {: bad :}
   d x rec bad t REJECTED-DUE
   TEST-DROPBOX:SEEN$ rs REJECTED-SEEN$ T$=
   UPLOAD-ROUTE$ TEST-DROPBOX:BODIES-TO$ REJECTED-BODIES$ T$=
   d x STEP-GONE ;

: BAD-LOOKUPS$ ( -- str )
   SB-RESET 2 0 ?do
      i 0<> if s"  " SB-APPEND then
      S\" {\qpath\q:\q/bad.txt\q,\qinclude_deleted\q:true}" SB-APPEND
   loop SB$ ;

\ The uploads' arguments: bad.txt's, good.txt's, then bad.txt's again.
: REJECTED-ARGS$ ( ^ARENA:arena -- str )
   {: ar :}
   s" /bad.txt" REJECTED-BYTES$ ar ADD-ARG$ s"  " ar JOIN-BYTES
   s" /good.txt" GOOD-BYTES$ ar ADD-ARG$ ar JOIN-BYTES
   s"  " ar JOIN-BYTES
   s" /bad.txt" REJECTED-BYTES$ ar ADD-ARG$ ar JOIN-BYTES ;

: REJECTED-PATHS-DO-NOT-STOP-UNRELATED-SYNC-OR-REPORT-PROGRESS
   ( ^ARENA:arena -- )
   {: ar :}
   s" rejected_paths_do_not_stop_unrelated_sync_or_report_progress"
   T-LABEL
   [: DISALLOWED-UPLOAD ;] UPLOAD-ROUTE$ s" disallowed_name" ar
   REJECTED-PATH-CASE
   [: FUTURE-WRITE ;] UPLOAD-ROUTE$ s" rejected_by_dropbox" ar
   REJECTED-PATH-CASE
   [: HASH-MISMATCH ;] UPLOAD-ROUTE$
   s" content_hash_mismatch" ar REJECTED-PATH-CASE
   [: MOVED ;] s" /2/files/upload /2/files/get_metadata"
   s" path_mismatch" ar REJECTED-PATH-CASE
   \ The uploads besides good.txt's both name /bad.txt.
   UPLOAD-ROUTE$ TEST-DROPBOX:ARGS-TO$ ar REJECTED-ARGS$ T$=
   METADATA-ROUTE$ TEST-DROPBOX:BODIES-TO$ BAD-LOOKUPS$ T$= ;

: STALE$ ( -- str ) s" preserve stale local metadata" ;
: ORDINARY-UPLOAD$ ( -- str ) s" ordinary local upload" ;
: ORDINARY-DOWNLOAD$ ( -- str ) s" ordinary remote download" ;

\ Rust's excluded local files: q runs on each path and its bytes.
: EXCLUDED-LOCALS ( [ str str -- ] -- )
   {: q :}
   s" Desktop.INI" STALE$ q execute
   s\" Icon\r" s" local icon metadata" q execute
   s" .DROPBOX.ATTR" s" local Dropbox attributes" q execute
   s" metadata.DS_STORE" s" local suffixed metadata" q execute
   s" ~$draft.docx" s" local office temporary file" q execute
   s" .~draft.docx" s" local hidden temporary file" q execute
   s" .DROPBOX/local-child.txt" s" local excluded descendant"
   q execute ;

: EXCLUDED-WRITE ( str str ^run -- )
   {: p:str b:str x :}
   x p b WRITE-IN ;

: EXCLUDED-KEPT ( str str ^run -- )
   {: p:str b:str x :}
   x p IN-ROOT b HOLDS-BYTES ;

\ Rust's delta page: excluded files and a folder with a child, and
\ ordinary-download.txt.
: EXCLUDED-ENTRIES ( ^ARENA:arena -- str )
   {: ar :}
   s" new excluded inventory" ar IDENTITY {: nc:DROPBOX:hash :}
   s" remote excluded payload" ar IDENTITY {: ro:DROPBOX:hash :}
   s" remote excluded descendant" ar IDENTITY {: rc:DROPBOX:hash :}
   ORDINARY-DOWNLOAD$ ar IDENTITY {: dl:DROPBOX:hash :}
   [: s" /.ds_store" s" /.ds_store" s" new-excluded-revision" nc
      FILE-JSON+ COMMA+
      s" /thumbs.db" s" /THUMBS.DB" s" remote-excluded-revision" ro
      FILE-JSON+ COMMA+
      s" /.dropbox" s" /.Dropbox" FOLDER-JSON+ COMMA+
      s" /.dropbox/remote-child.txt" s" /.Dropbox/remote-child.txt"
      s" remote-child-revision" rc FILE-JSON+ COMMA+
      s" /ordinary-download.txt" s" /ordinary-download.txt"
      s" ordinary-download-revision" dl FILE-JSON+ ;]
   ar ENTRIES ;

\ Rust's answers: the delta page, ordinary-upload.txt's upload and
\ ordinary-download.txt.
: EXCLUDED-SERVED ( ^ARENA:arena -- )
   {: ar :}
   ar EXCLUDED-ENTRIES s" excluded-delta" false PAGE
   ORDINARY-UPLOAD$ ar IDENTITY {: up:DROPBOX:hash :}
   SB-RESET s" /ordinary-upload.txt" s" /ordinary-upload.txt"
   s" ordinary-upload-revision" up FILE-JSON+
   UPLOAD-ROUTE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT!
   s" ordinary-download.txt" s" ordinary-download-revision"
   ORDINARY-DOWNLOAD$ ar SERVES ;

\ The root's excluded files and ordinary-upload.txt; the journal's
\ baselines at Desktop.INI and THUMBS.DB and its inventory, .DS_Store
\ at the old revision.
: EXCLUDED-ROOT ( ^run MODEL:remote MODEL:remote -- )
   {: x stale only :}
   x RUN-ARENA @ {: ar :}
   x RUN-JOURNAL @ {: j :}
   x s" .DROPBOX" IN-ROOT FS:MAKE-DIR
   [: x EXCLUDED-WRITE ;] EXCLUDED-LOCALS
   x s" ordinary-upload.txt" IN-ROOT ORDINARY-UPLOAD$ FS:WRITE-ALL
   x s" Desktop.INI" stale SEED-BASELINE
   x s" THUMBS.DB" only SEED-BASELINE
   s" old excluded inventory" s" old-excluded-revision" ar REMOTE-FILE
   {: old :}
   j s" old-excluded-cursor"
   s" .DS_Store" ar CANONICAL s" .DS_Store" TEST-CLIENT:DISPLAY old REMOTE-PRESENT
   MODEL-REMOTE--RECORD:MAKE ar PUBLISHED ;

\ Departure 5: no account request; the download installs before the
\ upload is sent.
: EXCLUDED-SEEN$ ( -- str )
   s" /2/files/list_folder/continue /2/files/download /2/files/upload" ;

: DOCUMENTED-EXCLUSIONS-PRESERVE-PAYLOADS-WHILE-ORDINARY-SIBLINGS-SYNC
   ( ^ARENA:arena -- )
   {: ar :}
   s" documented_exclusions_preserve_payloads_while_ordinary_siblings_sync"
   T-LABEL
   TEST-DROPBOX:RESET
   ar EXCLUDED-SERVED
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   STALE$ s" stale-metadata-revision" ar REMOTE-FILE {: stale :}
   s" remote excluded payload" s" remote-excluded-revision" ar
   REMOTE-FILE {: only :}
   x stale only EXCLUDED-ROOT
   x rec PASSED COMPLETE REPLAYED-ERRORS nip 0 T=
   x STEPPED
   [: x EXCLUDED-KEPT ;] EXCLUDED-LOCALS
   x s" .ds_store" IN-ROOT FS:EXISTS? TFALSE
   x s" THUMBS.DB" IN-ROOT FS:EXISTS? TFALSE
   x s" .Dropbox/remote-child.txt" IN-ROOT FS:EXISTS? TFALSE
   x s" ordinary-upload.txt" IN-ROOT ORDINARY-UPLOAD$ HOLDS-BYTES
   x s" ordinary-download.txt" IN-ROOT ORDINARY-DOWNLOAD$ HOLDS-BYTES
   x s" ordinary-upload.txt" ORDINARY-UPLOAD$
   s" ordinary-upload-revision" ar REMOTE-FILE BASELINE-AT
   x s" ordinary-download.txt" ORDINARY-DOWNLOAD$
   s" ordinary-download-revision" ar REMOTE-FILE BASELINE-AT
   x s" Desktop.INI" stale BASELINE-AT
   x s" THUMBS.DB" only BASELINE-AT
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ EXCLUDED-SEEN$ T$=
   d x STEP-GONE ;

: EXCLUDED-LOCAL$ ( -- str ) s" preserved excluded local bytes" ;

\ Pending excluded plans on both sides, retired by a remote replay of
\ the reopened journal that sends nothing.
: REMOTE-RETIRES ( str ^run MODEL:local MODEL:remote -- )
   {: d:str x loc rem :}
   x RUN-ARENA @ {: ar :}
   x s" .DS_Store" MODEL-BASELINE:ABSENT
   loc LOCAL-PRESENT REMOTE-ABSENT RECORD-FIXTURE-PLAN drop
   x s" Desktop.ini" rem SEED-BASELINE
   x s" Desktop.ini" rem MODEL-BASELINE:PRESENT
   LOCAL-ABSENT rem REMOTE-PRESENT RECORD-FIXTURE-PLAN drop
   d x REOPENED
   x REMOTE-REPLAYED COMPLETED 0 T=
   x PENDING-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" " T$=
   x s" .DS_Store" IN-ROOT EXCLUDED-LOCAL$ HOLDS-BYTES ;

\ Pending excluded plans on both sides, retired by a local replay of
\ the reopened journal that touches neither file.
: LOCAL-RETIRES ( str ^run MODEL:local MODEL:remote -- )
   {: d:str x loc rem :}
   x RUN-ARENA @ {: ar :}
   x s" Thumbs.db" MODEL-BASELINE:ABSENT
   LOCAL-ABSENT rem REMOTE-PRESENT RECORD-FIXTURE-PLAN drop
   x s\" Icon\r" rem SEED-BASELINE
   x s\" Icon\r" rem MODEL-BASELINE:PRESENT
   loc LOCAL-PRESENT REMOTE-ABSENT RECORD-FIXTURE-PLAN drop
   d x REOPENED
   x LOCAL-REPLAYED COMPLETED 0 T=
   x PENDING-OF VEC:COUNT 0 T=
   x s" Thumbs.db" IN-ROOT FS:EXISTS? TFALSE
   x s\" Icon\r" IN-ROOT EXCLUDED-LOCAL$ HOLDS-BYTES ;

\ An excluded pending download, and three excluded plans blocked.
: BLOCKED-EXCLUSIONS ( ^run MODEL:local MODEL:remote -- )
   {: x loc rem :}
   x RUN-ARENA @ {: ar :}
   x s" folder/metadata.ds_store" MODEL-BASELINE:ABSENT
   LOCAL-ABSENT rem REMOTE-PRESENT RECORD-FIXTURE-PLAN drop
   x s" .dropbox.attr" IN-ROOT EXCLUDED-LOCAL$ FS:WRITE-ALL
   x s" .dropbox.attr" MODEL-BASELINE:ABSENT
   loc LOCAL-PRESENT REMOTE-ABSENT RECORD-FIXTURE-PLAN ID-OF
   {: up :}
   x up s" disallowed_name" REJECTED-AS 4000000000 BLOCKED-UNTIL
   x s" ~$blocked-download" MODEL-BASELINE:ABSENT
   LOCAL-ABSENT rem REMOTE-PRESENT RECORD-FIXTURE-PLAN ID-OF {: down :}
   x down MODEL-BLOCKAGE:DOWNLOAD-VERIFICATION-FAILED 4000000000
   BLOCKED-UNTIL
   x s" .~remote-delete" rem SEED-BASELINE
   x s" .~remote-delete" rem MODEL-BASELINE:PRESENT
   LOCAL-ABSENT rem REMOTE-PRESENT RECORD-FIXTURE-PLAN ID-OF {: del :}
   x del s" conflict" REJECTED-AS 4000000000 BLOCKED-UNTIL ;

\ The closed journal's status shows none of the excluded work; the
\ reopened journal's replay step retires it, sends nothing and keeps
\ every baseline and file.
: BLOCKED-RETIRES ( str ^run MODEL:remote -- )
   {: d:str x rem :}
   x RUN-JOURNAL @ JOURNAL:CLOSE
   d x JOURNAL-FILE x RUN-ARENA @ ATTENTION:RENDER
   s\" Omabox has no recorded work needing attention.\n" T$=
   d x OPENED-AGAIN
   TEST-DROPBOX:RESET
   x REPLAY-STEP REPORTED COMPLETED 0 T=
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   x s" Desktop.ini" rem BASELINE-AT
   x s\" Icon\r" rem BASELINE-AT
   x s" .~remote-delete" rem BASELINE-AT
   x s" .dropbox.attr" IN-ROOT EXCLUDED-LOCAL$ HOLDS-BYTES
   x s" folder/metadata.ds_store" IN-ROOT FS:EXISTS? TFALSE
   TEST-DROPBOX:SEEN$ s" " T$= ;

: EXCLUDED-PENDING-AND-BLOCKED-WORK-IS-RETIRED-ACROSS-REOPEN-WITHOUT-EFFECTS
   ( ^ARENA:arena -- )
   {: ar :}
   s" excluded_pending_and_blocked_work_is_retired_across_reopen_without_effects"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   EXCLUDED-LOCAL$ ar IDENTITY MODEL-LOCAL:MAKE {: loc :}
   EXCLUDED-LOCAL$ s" excluded-remote-revision" ar REMOTE-FILE {: rem :}
   x s" .DS_Store" IN-ROOT EXCLUDED-LOCAL$ FS:WRITE-ALL
   x s\" Icon\r" IN-ROOT EXCLUDED-LOCAL$ FS:WRITE-ALL
   x RUN-JOURNAL @ s" dbid:account" s" namespace" s" "
   JOURNAL-DROPBOX--BINDING:MAKE ar JOURNAL:BIND-DROPBOX-ROOT BOUND-ANY
   d x loc rem REMOTE-RETIRES
   d x loc rem LOCAL-RETIRES
   x loc rem BLOCKED-EXCLUSIONS
   d x rem BLOCKED-RETIRES
   d x STEP-GONE ;

: OWN-STAGE$ ( -- str ) s" staged download bytes" ;
: SYNCED$ ( -- str ) s" synced local bytes" ;

: A-VERIFIED-DOWNLOAD-STAGE-IS-NO-BLOCKED-PATH ( ^ARENA:arena -- )
   {: ar :}
   s" a verified download stage is no blocked path" T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   d x PASS-READY {: rec:str :}
   x [: x s" incoming.txt" OWN-STAGE$ PRESTAGED ;] IN-ACTIVE-ROOT
   x STAGE-PATH {: sp:str :}
   SYNCED$ s" rev-synced" ar REMOTE-FILE {: rem :}
   x s" synced.txt" SYNCED$ WRITE-IN
   x s" synced.txt" rem SEED-BASELINE
   s" synced.txt" s" rev-synced" SYNCED$ s" cursor-synced" ar
   LISTED-ALONE
   x rec PASSED COMPLETE BLOCKED-IN 0 T=
   UPLOAD-ROUTE$ TEST-DROPBOX:CALLS 0 T=
   sp OWN-STAGE$ HOLDS-BYTES
   d x STEP-GONE ;

: ROOT-AND-EXCLUSIONS-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar REPLACED-LOCAL-ROOT-NEVER-REPLAYS-PENDING-DELETION
   ar NEW-CONFLICT-ANSWERS-A-REPLACED-ROOT
   ar ROOT-SWAP-DURING-PLANNING-STAGES-NOTHING-FROM-THE-STAND-IN
   ar REJECTED-PATHS-DO-NOT-STOP-UNRELATED-SYNC-OR-REPORT-PROGRESS
   ar DOCUMENTED-EXCLUSIONS-PRESERVE-PAYLOADS-WHILE-ORDINARY-SIBLINGS-SYNC
   ar EXCLUDED-PENDING-AND-BLOCKED-WORK-IS-RETIRED-ACROSS-REOPEN-WITHOUT-EFFECTS
   ar A-VERIFIED-DOWNLOAD-STAGE-IS-NO-BLOCKED-PATH ;

: SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   ar TEST-CLIENT:OPENED TEST-CLIENT:MAIN !
   TEST-CLIENT:ACCOUNTED
   [: ar REFRESH-CASES ar STEP-CASES ar PASS-CASES
      ar STALE-CASES ar DOWNLOAD-BLOCKS-CASES ar UPLOADS-CASES
      ar CONFLICTS-CASES ar RESTRICTED-CASES
      ar EDITS-AND-DIRECTORIES-CASES ar CASE-COLLISION-PASS-CASES
      ar DIRECTORY-COLLISION-CASES ar DIRECTORY-DELETION-CASES
      ar ROOT-AND-EXCLUSIONS-CASES ;]
   [: TEST-CLIENT:MAIN @ DROPBOX:CLOSE ;]
   finally ;


\ The refresh cases against one fake Dropbox, under AIO's loop.
: DROPBOX-SERVED ( ^ARENA:arena -- )
   {: ar :}
   AIO:START
   [: TEST-DROPBOX:START
      [: ar SERVED ;] [: TEST-DROPBOX:STOP ;] finally ;]
   [: AIO:STOP ;] finally ;

: LISTING-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar FOLDERS-ARE-DIRECTORIES-AND-NON-DOWNLOADABLE-FILES-ARE-UNKNOWN
   ar DIRECTORY-RECORDS-NORMALIZE-INCONSISTENT-CHILD-ANCESTOR-CASING
   ar DELTA-NEVER-RESPELLS-A-DIRECTORY-THAT-STILL-EXISTS
   ar LISTING-KEEPS-MISMATCHED-PATHS-UNSUPPORTED
   ar MISMATCHED-RESTRICTED-FOLDER-DROPS-ITS-CHILDREN
   ar TWO-SPELLINGS-SHARE-ONE-KEY
   ar LISTING-REJECTS-AN-INVALID-CONFIGURED-ROOT
   ar LISTING-REJECTS-AN-ENTRY-WITHOUT-PATHS
   ar LISTING-REJECTS-A-PATH-THAT-IS-NOT-UTF-8
   ar LISTING-REJECTS-AN-INVALID-OR-OUT-OF-ROOT-ENTRY
   ar LISTING-CLASSIFIES-THE-REMOTE-ROOTS-OWN-ENTRY
   ar DROPBOX-SERVED ;

\ ---- the listing table against its model --------------------------

: FORMAL-HOLDS-THE-LISTING-TABLE ( ^ARENA:arena -- )
   {: ar :}
   s" formal_holds_the_listing_table" T-LABEL
   s" src/reconcile.f" s" INVENTORY-PUBLICATION" s" InventoryPublication" ar TEST-FORMAL:HOLDS ;

: FORMAL-HOLDS-THE-DOWNLOAD-TABLE ( ^ARENA:arena -- )
   {: ar :}
   s" formal_holds_the_download_table" T-LABEL
   s" src/reconcile.f" s" DOWNLOAD-EXECUTOR" s" DownloadExecutor" ar TEST-FORMAL:HOLDS ;

: FORMAL-HOLDS-THE-PASS-TABLE ( ^ARENA:arena -- )
   {: ar :}
   s" formal_holds_the_pass_table" T-LABEL
   s" src/reconcile.f" s" SYNC-PASS" s" SyncPass" ar
   TEST-FORMAL:HOLDS ;

: FORMAL-HOLDS-THE-PLACEMENT-TABLE ( ^ARENA:arena -- )
   {: ar :}
   s" formal_holds_the_placement_table" T-LABEL
   s" src/reconcile.f" s" CONFLICT-PLACEMENT" s" ConflictPlacement" ar
   TEST-FORMAL:HOLDS ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar ABSENT-PATHS-ARE-SPELLED-WITH-LOCAL-ANCESTOR-CASING
   ar LOCAL-CASE-VARIANTS-NEVER-COLLAPSE-INTO-ONE-OBSERVATION
   ar KNOWN-PATH-MERGE-MATCHES-SET-UNION
   ar DECIDING-SKIPS-ONLY-SETTLED-KEYS
   ar REMAINING-OPERATION-COMPARISON-IGNORES-A-COMPLETED-PREFIX
   ar PENDING-ONLY-PATHS-ARE-VISITED-AS-ABSENT-WITHOUT-CREATING-A-BASELINE
   ar A-PATH-BELOW-AN-UNKNOWN-DIRECTORY-INHERITS-ITS-REASON
   ar A-RECORD-BELOW-AN-UNKNOWN-DIRECTORY-CANNOT-RESTORE-ABSENCE
   ar NAMES-THAT-NEIGHBOR-THE-SEPARATOR-ARE-NOT-ANCESTORS
   ar AN-EXCLUDED-ANCESTOR-LENDS-NO-REASON-OR-SPELLING
   ar AN-UNKNOWN-ANCESTOR-BLOCKS-A-DELETION-ON-EITHER-SIDE
   ar BASELINE-ONLY-PATHS-ARE-INCLUDED-IN-CONFIRMED-ABSENCE
   ar A-WALK-COUNTS-EVERY-KEPT-BASELINE
   ar DECIDING-KEEPS-THE-RUN-RULE
   ar PATH-DECISIONS-ORDER-DELETES-LAST-AND-DEEPEST-FIRST
   ar CASE-COLLISION-CASES
   ar LISTING-CASES
   ar FORMAL-HOLDS-THE-LISTING-TABLE
   ar FORMAL-HOLDS-THE-DOWNLOAD-TABLE
   ar FORMAL-HOLDS-THE-PASS-TABLE
   ar FORMAL-HOLDS-THE-PLACEMENT-TABLE ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" reconcile-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
