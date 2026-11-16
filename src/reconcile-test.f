\ reconcile-test.f - RECONCILE's words, each case in a directory of its
\ own under TMPDIR, which it removes.
\ Known paths, Rust's tests of the same names:
\ - absent_paths_are_spelled_with_local_ancestor_casing
\ - local_case_variants_never_collapse_into_one_observation, over
\   sampled names, the collision logged once naming both spellings and
\   renamed alike in either order, to a path neither spelling holds
\ - known_path_merge_matches_set_union, over sampled path sets
\ - remaining_operation_comparison_ignores_a_completed_prefix
\ - pending_only_paths_are_visited_as_absent_without_creating_a_baseline
\ - local_map_keeps_one_unsupported_spelling
\ - a_path_below_an_unknown_directory_inherits_its_reason
\ - a_record_below_an_unknown_directory_cannot_restore_absence
\ - names_that_neighbor_the_separator_are_not_ancestors
\ - an_unknown_ancestor_blocks_a_deletion_on_either_side
\ - baseline_only_paths_are_included_in_confirmed_absence
\ - remote_subtree_holds_only_true_descendants
\ - child_prefix_order_matches_the_materialized_prefix, over every
\   pair of strings of up to three bytes from 00 . / 0 FF
\ - ORDER-PATH-DECISIONS puts an upload at depth 3 first, then local
\   directory deletes at depths 2 and 1, deepest first.
\ Case collisions:
\ - Rust's case_variant_name_skips_existing_suffixes,
\   case_variant_name_fits_a_maximum_length_component,
\   file_copy_name_is_deterministic_and_fits_the_parent_limit,
\   case_variant_moves_converge_from_parent_to_child,
\   case_variant_source_keeps_the_recorded_spelling,
\   case_variant_source_leaves_unsupported_spellings and
\   case_variant_source_skips_an_unsupported_collision.
\ - RESOLVE-CASE-COLLISION below a bound root holding Dir/a.txt and
\   dir/b.txt renames dir, the spelling CASE-VARIANT-SOURCE picks, to
\   its case-variant name and retires the plans at both spellings,
\   which share its identity, leaving one at another path pending.
\ - With the root replaced by another directory it answers
\   root-changed, renaming nothing and retiring no plan.
\ Listing changes, Rust's tests of the same names:
\ - folders_are_directories_and_non_downloadable_files_are_unknown
\ - directory_records_normalize_inconsistent_child_ancestor_casing
\ - delta_never_respells_a_directory_that_still_exists
\ - listing_rejects_mismatched_canonical_and_display_paths, its one
\   line logged
\ - listing_classifies_the_remote_roots_own_entry, each refusal's one
\   line logged
\ - LISTING-REJECTS-AN-INVALID-CONFIGURED-ROOT: a/b, /a/, /a//b and a
\   root that is not UTF-8 each throw E-LISTING, one line logged.
\ - LISTING-REJECTS-AN-ENTRY-WITHOUT-PATHS and
\   LISTING-REJECTS-A-PATH-THAT-IS-NOT-UTF-8, an 0xFF byte: E-LISTING,
\   one line logged, naming no path for the first.
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
\ Run from the repository root: hb --load src/reconcile-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/lib/vector.f
require src/lib/adt/option.f
require src/lib/fs-anchored.f
require src/lib/fs-list.f
require src/lib/aio.f
require src/lib/time.f
require src/lib/net/curl.f
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

\ RECONCILE reopened for the private words the tests call.
package RECONCILE
private

\ ---- known paths: helpers -----------------------------------------

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

\ A case's directory, made under TMPDIR, and its journal.
: CASE-JOURNAL ( ^ARENA:arena -- str JOURNAL:journal )
   {: ar :}
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   SB-RESET d str> SB-APPEND s" /journal.sqlite3" SB-APPEND
   d SB$ ar COPIED JOURNAL:OPEN ;

: GONE ( str JOURNAL:journal -- )
   JOURNAL:CLOSE str> FS:REMOVE-TREE ;

: DISPLAY ( ^u8 n -- MODEL:path ) >str MODEL:>PATH ;

\ Rust's CanonicalPath::from_display of the bytes.
: CANONICAL ( ^u8 n ^ARENA:arena -- MODEL:key )
   {: p:^ u:n ar :}
   p u DISPLAY ar MODEL:FOLD ;

\ Rust's identity: dropbox_content_hash of the bytes, from a pipe.
: IDENTITY ( ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: b:^ u:n ar :}
   FD:PIPE {: r:fd w:fd :}
   w b u FD:WRITE-FULL w FS:CLOSE-DIR
   r ar LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR ;

: REMOTE-FILE ( ^u8 n ^u8 n ^ARENA:arena -- MODEL:remote )
   {: b:^ u:n r:^ ru:n ar :}
   b u ar IDENTITY r ru >str DROPBOX:>REV MODEL-REMOTE:MAKE ;

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
   ( ^VEC:vector<MODEL:local-record> ^u8 n
     MODEL:observation<MODEL:local> -- )
   {: v p:^ u:n o :}
   p u DISPLAY o MODEL-LOCAL--RECORD:MAKE v VEC:PUSH ! ;

\ Rust's local_records: a directory at the path.
: DIRECTORY+ ( ^VEC:vector<MODEL:local-record> ^u8 n -- )
   LOCAL-DIRECTORY LOCAL+ ;

\ Rust's unsupported_records: unknown unsupported at the path.
: UNSUPPORTED+ ( ^VEC:vector<MODEL:local-record> ^u8 n -- )
   MODEL-UNKNOWN--REASON:UNSUPPORTED LOCAL-UNKNOWN LOCAL+ ;

\ Rust's present_locally.
: PRESENT+
   ( ^VEC:vector<MODEL:local-record> ^u8 n ^u8 n ^ARENA:arena -- )
   {: v p:^ u:n b:^ bu:n ar :}
   v p u b bu ar IDENTITY MODEL-LOCAL:MAKE LOCAL-PRESENT
   LOCAL+ ;

\ Rust's remote_side for one record.
: REMOTE+
   ( ^VEC:vector<MODEL:remote-record> ^u8 n
     MODEL:observation<MODEL:remote> ^ARENA:arena -- )
   {: v p:^ u:n o ar :}
   p u ar CANONICAL p u DISPLAY o MODEL-REMOTE--RECORD:MAKE
   v VEC:PUSH ! ;

\ The local entries' paths, each followed by a space.
: PATHS$ ( ^VEC:vector<local-entry> -- ^u8 n )
   {: v :}
   SB-RESET
   v VEC:COUNT 0 ?do
      v i VEC:AT @ ENTRY-RECORD RECORD-PATH PATH$ SB-APPEND
      s"  " SB-APPEND
   loop
   SB$ ;

\ The local observation the map holds at the path, else unobserved.
: LOCAL-AT
   ( ^VEC:vector<local-entry> MODEL:key
     -- MODEL:observation<MODEL:local> )
   {: v k :}
   v k FIND-LOCAL
   MATCH option
      none OF v k LOCAL-UNOBSERVED ENDOF
      some OF MODEL-LOCAL--RECORD:UNMAKE {: p o :} o ENDOF
   ;MATCH ;

: REMOTE-AT
   ( ^VEC:vector<MODEL:remote-record> MODEL:key
     -- MODEL:observation<MODEL:remote> )
   {: v k :}
   v k FIND-REMOTE
   MATCH option
      none OF v k REMOTE-UNOBSERVED ENDOF
      some OF REMOTE-OBSERVATION ENDOF
   ;MATCH ;

: LOCAL-UNOBSERVED= ( ^VEC:vector<local-entry> ^u8 n
     MODEL:observation<MODEL:local> ^ARENA:arena -- )
   {: v p:^ u:n want ar :}
   v p u ar CANONICAL LOCAL-UNOBSERVED want MODEL:LOCAL-OBSERVATION=
   TTRUE ;

: REMOTE-UNOBSERVED= ( ^VEC:vector<MODEL:remote-record> ^u8 n
     MODEL:observation<MODEL:remote> ^ARENA:arena -- )
   {: v p:^ u:n want ar :}
   v p u ar CANONICAL REMOTE-UNOBSERVED want MODEL:REMOTE-OBSERVATION=
   TTRUE ;

\ A plan of the one operation, or of two.
: OPERATIONS ( ^ARENA:arena -- ^VEC:vector<MODEL:operation> )
   ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW ;

: ONE-PLAN ( MODEL:operation ^ARENA:arena -- JOURNAL:operation-plan )
   {: o ar :}
   ar OPERATIONS {: ops :}
   o ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

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
: SAMPLE ( ^u8 n n ^ARENA:arena -- str )
   {: a:^ au:n k:n ar :}
   ar k ARENA:ALLOC drop {: dst:^ :}
   k 0 ?do a au RANDOM + c@ dst i + c! loop
   dst k >str ;

\ ---- known paths: cases ---------------------------------------------

: RESPELLED
   ( ^VEC:vector<local-entry> ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: v p:^ u:n q:^ w:n ar :}
   v p u ar CANONICAL q w DISPLAY ar SPELL-WITH-LOCAL-ANCESTORS PATH$ ;

: ABSENT-PATHS-ARE-SPELLED-WITH-LOCAL-ANCESTOR-CASING ( ^ARENA:arena -- )
   {: ar :}
   s" absent_paths_are_spelled_with_local_ancestor_casing" T-LABEL
   ar LOCAL-RECORDS {: rs :}
   rs s" Apps" DIRECTORY+
   rs s" Apps/Day One" DIRECTORY+
   rs s" Notes" DIRECTORY+
   rs ar LOCAL-MAP {: v :}
   v s" apps/day one/journal" s" apps/day one/Journal" ar RESPELLED
   s" Apps/Day One/Journal" T$=
   v s" apps/day one/journal/entries" s" APPS/Day one/journal/Entries"
   ar RESPELLED s" Apps/Day One/journal/Entries" T$=
   v s" docs/report.txt" s" Docs/Report.txt" ar RESPELLED
   s" Docs/Report.txt" T$=
   v s" notes" s" NOTES" ar RESPELLED s" NOTES" T$= ;

\ The text LOCAL-MAP logs for a collision of the two spellings.
: COLLISION$ ( ^u8 n ^u8 n -- ^u8 n )
   {: a:^ au:n b:^ bu:n :}
   SB-RESET s" local paths `" SB-APPEND a au SB-APPEND
   s" ` and `" SB-APPEND b bu SB-APPEND
   s" ` have the same Dropbox path identity" SB-APPEND SB$ ;

\ What q writes to fd 2, captured in the case's directory d, in the
\ arena.
: LOGGED ( str [ -- ] ^ARENA:arena -- ^u8 n )
   {: d:str q ar :}
   SB-RESET d str> SB-APPEND s" /stderr.txt" SB-APPEND
   q SB$ ar COPIED str> ar STDERR:CAPTURING {: code:n t:^ u:n :}
   code 0<> if code throw then
   t u ;

: NO-SPELLING ( MODEL:key -- option<MODEL:path> ) drop NO-PATH ;

\ Rust's case_variant_move, max 255, of case_variant_source's pick
\ with no baseline; a collision with no source fails the case.
: RENAME
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- case-variant-move )
   {: rs ar :}
   rs [: NO-SPELLING ;] ar CASE-VARIANT-SOURCE MATCH option
      none OF
         false TTRUE s" " DISPLAY dup CASE-VARIANT-MOVE-MAKE
      ENDOF
      some OF rs swap 255 ar CASE-VARIANT-MOVE ENDOF
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
   k a str> ar CANONICAL MODEL:KEY= TFALSE
   k b str> ar CANONICAL MODEL:KEY= TFALSE ;

\ The records in reverse order rename alike, to a unique path.
: RENAMES-AGREE
   ( ^VEC:vector<MODEL:local-record> str str ^ARENA:arena -- )
   {: rs lower:str upper:str ar :}
   ar LOCAL-RECORDS {: sr :}
   sr upper str> DIRECTORY+ sr lower str> DIRECTORY+
   rs ar RENAME {: fwd :}
   fwd sr ar RENAME MOVES=
   fwd lower upper ar UNIQUE ;

\ One sample of the proptest: a lowercase name and its uppercase.
: CASE-VARIANTS ( str ^ARENA:arena -- )
   {: d:str ar :}
   s" abcdefghijklmnopqrstuvwxyz" 24 RANDOM 1+ ar SAMPLE {: stem:str :}
   SB-RESET stem str> SB-APPEND s" .txt" SB-APPEND
   SB$ ar COPIED {: lower:str :}
   lower str> ar COPIED {: upper:str :}
   upper str> 0 ?do dup i + c@ ASCII-UPPER over i + c! loop drop
   ar LOCAL-RECORDS {: rs :}
   rs lower str> DIRECTORY+ rs upper str> DIRECTORY+
   d [: [: rs ar LOCAL-MAP drop ;] E-CASE-COLLISION TTHROWSQ ;] ar
   LOGGED {: t:^ tu:n :}
   t tu 10 COUNT-CHAR 1 T=
   t tu upper str> lower str> COLLISION$ CONTAINS? TTRUE
   rs lower upper ar RENAMES-AGREE ;

: LOCAL-CASE-VARIANTS-NEVER-COLLAPSE-INTO-ONE-OBSERVATION
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_case_variants_never_collapse_into_one_observation" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   1 SEED !
   16 0 ?do d ar CASE-VARIANTS loop
   d str> FS:REMOVE-TREE ;

\ For MERGE-PATH: the piece from at, kept unless empty, "." or "..";
\ the index after it, or -1 past the last.
: MERGE-PIECE ( ^u8 n n ^VEC:vector<str> -- n )
   {: p:^ u:n at:n kept :}
   p u SEPARATOR at SPLIT-NEXT 0= if 2drop drop -1 exit then
   {: q:^ w:n next:n :}
   q w NAME? q w s" .." STR= 0= and if q w >str kept VEC:PUSH ! then
   next ;

\ Rust's merge_path: the pieces between separators but empty, "."
\ and "..", joined.
: MERGE-PATH ( str ^ARENA:arena -- option<str> )
   {: raw:str ar :}
   ar ARENA:ALLOCATOR 0 [type] str VEC:NEW {: kept :}
   raw str> {: p:^ u:n :}
   0 begin p u rot kept MERGE-PIECE dup 0< until drop
   kept VEC:COUNT 0= if OPTION:NONE exit then
   kept ar JOINED OPTION:SOME ;

: HOLDS? ( ^VEC:vector<str> ^u8 n -- bool )
   {: v p:^ u:n :}
   false v VEC:COUNT 0 ?do v i VEC:AT @ str> p u STR= or loop ;

\ Rust's merge_paths over up to 23 sampled names, without repeats.
: MERGE-PATHS ( ^ARENA:arena -- ^VEC:vector<str> )
   {: ar :}
   ar ARENA:ALLOCATOR 0 [type] str VEC:NEW {: v :}
   24 RANDOM 0 ?do
      s" abcdefghijklmnopqrstuvwxyz./ -" 12 RANDOM 1+ ar SAMPLE
      ar MERGE-PATH
      MATCH option
         none OF ENDOF
         some OF dup str> v -rot HOLDS? if drop else v VEC:PUSH ! then
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

: CHECK-VISIT
   ( MODEL:key option<JOURNAL:path-baseline>
     option<MODEL:local-record> option<MODEL:remote-record>
     ^VEC:vector<str> ^VEC:vector<str> ^VEC:vector<str>
     ^VEC:vector<MODEL:key> -- )
   {: k b l r bp lp rp merged :}
   k KEY-BYTES {: p:^ u:n :}
   b BASELINE-SOME? bool>n bp p u HOLDS? bool>n T=
   l LOCAL-SOME? bool>n lp p u HOLDS? bool>n T=
   r REMOTE-SOME? bool>n rp p u HOLDS? bool>n T=
   k merged VEC:PUSH ! ;

: KEYS-INTO
   ( ^VEC:vector<str> ^VEC:vector<MODEL:key> ^ARENA:arena -- )
   {: paths keys ar :}
   paths VEC:COUNT 0 ?do
      paths i VEC:AT @ str> ar CANONICAL keys VEC:PUSH !
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

\ The union's keys, sorted by bytes, without repeats.
: EXPECTED
   ( ^VEC:vector<str> ^VEC:vector<str> ^VEC:vector<str> ^ARENA:arena
     -- ^VEC:vector<MODEL:key> )
   {: bp lp rp ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: all :}
   bp all ar KEYS-INTO lp all ar KEYS-INTO rp all ar KEYS-INTO
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
      v paths i VEC:AT @ str> REMOTE-DIRECTORY ar REMOTE+
   loop
   v ar REMOTE-MAP ;

: LOCAL-DIRECTORIES
   ( ^VEC:vector<str> ^ARENA:arena -- ^VEC:vector<local-entry> )
   {: paths ar :}
   ar LOCAL-RECORDS {: v :}
   paths VEC:COUNT 0 ?do v paths i VEC:AT @ str> DIRECTORY+ loop
   v ar LOCAL-MAP ;

: NO-PENDING ( ^ARENA:arena -- ^VEC:vector<pending-plan> )
   ARENA:ALLOCATOR 0 [type] pending-plan VEC:NEW ;

\ One sample of the proptest.
: MERGE-SAMPLE ( ^ARENA:arena -- )
   {: ar :}
   ar MERGE-PATHS {: bp :}
   ar MERGE-PATHS {: lp :}
   ar MERGE-PATHS {: rp :}
   ar CASE-JOURNAL {: d:str j :}
   j bp ar SEED-DIRECTORY-BASELINES
   j ar JOURNAL:BASELINES {: bs :}
   bs VEC:COUNT bp VEC:COUNT T=
   lp ar LOCAL-DIRECTORIES {: ls :}
   rp ar REMOTE-DIRECTORIES {: rs :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: merged :}
   bs ls rs ar NO-PENDING
   [: bp lp rp merged CHECK-VISIT ;] FOR-EACH-KNOWN-PATH
   merged bp lp rp ar EXPECTED SAME-KEYS
   d j GONE ;

: KNOWN-PATH-MERGE-MATCHES-SET-UNION ( ^ARENA:arena -- )
   {: ar :}
   s" known_path_merge_matches_set_union" T-LABEL
   7 SEED !
   24 0 ?do ar MERGE-SAMPLE loop ;

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
   j s" file.txt" DISPLAY original ar JOURNAL:RECORD-PLAN RECORDED
   {: recorded :}
   recorded JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops VEC:COUNT 2 T=
   j recorded FIRST-OPERATION-ID NO-BASELINE ar
   JOURNAL:COMPLETE-OPERATION OPERATION-COMPLETED? TTRUE
   j ar JOURNAL:PENDING-PLANS {: pending :}
   pending VEC:COUNT 1 T=
   pending 0 VEC:AT @ {: plan :}
   remote MODEL-OPERATION:INSTALL-LOCAL ar ONE-PLAN {: fresh :}
   plan fresh REMAINING-OPERATIONS-MATCH? TTRUE
   plan original REMAINING-OPERATIONS-MATCH? TFALSE
   d j GONE ;

: KEYED-PLAN
   ( JOURNAL:plan-record ^VEC:vector<pending-plan> ^ARENA:arena -- )
   {: plan v ar :}
   plan JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   p ar MODEL:FOLD plan PENDING-PLAN-MAKE v VEC:PUSH ! ;

\ The pending plans keyed by path, as Rust's BTreeMap holds them.
: PENDING-MAP
   ( ^VEC:vector<JOURNAL:plan-record> ^ARENA:arena
     -- ^VEC:vector<pending-plan> )
   {: plans ar :}
   ar NO-PENDING {: v :}
   plans VEC:COUNT 0 ?do plans i VEC:AT @ v ar KEYED-PLAN loop
   v ;

: VISITED-ABSENT
   ( MODEL:key option<JOURNAL:path-baseline>
     option<MODEL:local-record> option<MODEL:remote-record>
     MODEL:key ^VEC:vector<MODEL:decision> -- )
   {: k b l r want decisions :}
   k want MODEL:KEY= TTRUE
   b BASELINE-SOME? TFALSE
   l LOCAL-SOME? TFALSE
   r REMOTE-SOME? TFALSE
   MODEL-BASELINE:ABSENT LOCAL-ABSENT REMOTE-ABSENT MODEL-SUBTREE:EMPTY
   PLANNER:PLAN decisions VEC:PUSH ! ;

: PENDING-ONLY-PATHS-ARE-VISITED-AS-ABSENT-WITHOUT-CREATING-A-BASELINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" pending_only_paths_are_visited_as_absent_without_creating_a_baseline"
   T-LABEL
   ar CASE-JOURNAL {: d:str j :}
   s" removed.txt" DISPLAY {: path :}
   s" obsolete" s" obsolete-revision" ar REMOTE-FILE
   MODEL-OPERATION:INSTALL-LOCAL ar ONE-PLAN {: plan :}
   j path plan ar JOURNAL:RECORD-PLAN RECORDED drop
   j ar JOURNAL:PENDING-PLANS ar PENDING-MAP {: pending :}
   path ar MODEL:FOLD {: want :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:decision VEC:NEW {: decisions :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:baseline-record VEC:NEW
   ar LOCAL-RECORDS ar LOCAL-MAP ar REMOTE-RECORDS pending
   [: want decisions VISITED-ABSENT ;] FOR-EACH-KNOWN-PATH
   decisions VEC:COUNT 1 T=
   decisions 0 VEC:AT @ NOOP? TTRUE
   j path ar JOURNAL:BASELINE STORED-SOME? TFALSE
   d j GONE ;

: LOCAL-MAP-KEEPS-ONE-UNSUPPORTED-SPELLING ( ^ARENA:arena -- )
   {: ar :}
   s" local_map_keeps_one_unsupported_spelling" T-LABEL
   ar LOCAL-RECORDS {: rs :}
   rs s" link" UNSUPPORTED+ rs s" Link" UNSUPPORTED+
   rs ar LOCAL-MAP PATHS$ s" Link " T$= ;

: A-PATH-BELOW-AN-UNKNOWN-DIRECTORY-INHERITS-ITS-REASON
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_path_below_an_unknown_directory_inherits_its_reason" T-LABEL
   ar LOCAL-RECORDS {: rs :}
   rs s" locked" MODEL-UNKNOWN--REASON:INACCESSIBLE LOCAL-UNKNOWN LOCAL+
   rs s" open" DIRECTORY+
   rs s" open/kept.txt" s" kept" ar PRESENT+
   rs ar LOCAL-MAP {: v :}
   MODEL-UNKNOWN--REASON:INACCESSIBLE LOCAL-UNKNOWN {: locked :}
   v s" locked/secret.txt" locked ar LOCAL-UNOBSERVED=
   v s" Locked/Deep/Deeper.TXT" locked ar LOCAL-UNOBSERVED=
   v s" gone.txt" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   v s" open/gone.txt" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   v s" open/kept.txt/below" LOCAL-ABSENT ar LOCAL-UNOBSERVED= ;

: A-RECORD-BELOW-AN-UNKNOWN-DIRECTORY-CANNOT-RESTORE-ABSENCE
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_record_below_an_unknown_directory_cannot_restore_absence" T-LABEL
   ar REMOTE-RECORDS {: rs :}
   rs s" volume" MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN ar
   REMOTE+
   rs s" volume/listed" REMOTE-DIRECTORY ar REMOTE+
   rs ar REMOTE-MAP {: v :}
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN {: why :}
   v s" volume/gone.txt" why ar REMOTE-UNOBSERVED=
   v s" volume/listed/gone.txt" why ar REMOTE-UNOBSERVED=
   v s" volume/listed/deeper/gone.txt" why ar REMOTE-UNOBSERVED=
   ar REMOTE-RECORDS {: cs :}
   cs s" volume" REMOTE-DIRECTORY ar REMOTE+
   cs s" volume/listed" REMOTE-DIRECTORY ar REMOTE+
   cs ar REMOTE-MAP {: complete :}
   complete s" volume/gone.txt" REMOTE-ABSENT ar REMOTE-UNOBSERVED=
   complete s" volume/listed/deeper/gone.txt" REMOTE-ABSENT ar
   REMOTE-UNOBSERVED= ;

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
   rs ar LOCAL-MAP {: v :}
   MODEL-UNKNOWN--REASON:INCOMPLETE LOCAL-UNKNOWN {: why :}
   v s" report/x" why ar LOCAL-UNOBSERVED=
   v s" REPORT/x/y" why ar LOCAL-UNOBSERVED=
   v s\" unreadable\xFF/x" MODEL-UNKNOWN--REASON:INACCESSIBLE
   LOCAL-UNKNOWN ar LOCAL-UNOBSERVED=
   v s" report.txt/x" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   v s" report0/x" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   v s" reportx/y" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   v s" report" LOCAL-ABSENT ar LOCAL-UNOBSERVED=
   v s" unreadable/x" LOCAL-ABSENT ar LOCAL-UNOBSERVED= ;

: BLOCKED-UNKNOWN ( -- MODEL:decision )
   MODEL-BLOCKED--REASON:UNKNOWN MODEL-DECISION:BLOCKED ;

\ One reason of an_unknown_ancestor_blocks_a_deletion_on_either_side:
\ the observation each side reads below the unknown directory is
\ unknown for that reason, and the plan is blocked.
: BLOCKS-EITHER-SIDE
   ( MODEL:unknown-reason MODEL:remote ^ARENA:arena -- )
   {: why file ar :}
   file MODEL-BASELINE:PRESENT {: baseline :}
   s" locked/secret.txt" ar CANONICAL {: below :}
   ar LOCAL-RECORDS {: ul :}
   ul s" locked" why LOCAL-UNKNOWN LOCAL+
   ul ar LOCAL-MAP below LOCAL-UNOBSERVED {: lo :}
   ar REMOTE-RECORDS {: lr :}
   lr s" locked" REMOTE-DIRECTORY ar REMOTE+
   lr s" locked/secret.txt" file REMOTE-PRESENT ar REMOTE+
   lr ar REMOTE-MAP below REMOTE-AT {: ro :}
   lo why LOCAL-UNKNOWN MODEL:LOCAL-OBSERVATION= TTRUE
   baseline lo ro MODEL-SUBTREE:EMPTY PLANNER:PLAN BLOCKED-UNKNOWN
   MODEL:DECISION= TTRUE
   ar LOCAL-RECORDS {: sl :}
   sl s" locked" DIRECTORY+
   sl s" locked/secret.txt" s" secret" ar PRESENT+
   sl ar LOCAL-MAP below LOCAL-AT {: lo2 :}
   ar REMOTE-RECORDS {: ur :}
   ur s" locked" why REMOTE-UNKNOWN ar REMOTE+
   ur ar REMOTE-MAP below REMOTE-UNOBSERVED {: ro2 :}
   ro2 why REMOTE-UNKNOWN MODEL:REMOTE-OBSERVATION= TTRUE
   baseline lo2 ro2 MODEL-SUBTREE:EMPTY PLANNER:PLAN BLOCKED-UNKNOWN
   MODEL:DECISION= TTRUE ;

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
   s" gone.txt" DISPLAY {: path :}
   s" old" s" rev-old" ar REMOTE-FILE {: remote :}
   j path remote ar RECORD-MATCHING-BASELINE
   j ar JOURNAL:BASELINE-PATHS {: paths :}
   paths VEC:COUNT 1 T=
   paths 0 VEC:AT @ PATH$ s" gone.txt" T$=
   j path ar JOURNAL:BASELINE STORED-BASELINE
   LOCAL-ABSENT REMOTE-ABSENT MODEL-SUBTREE:EMPTY PLANNER:PLAN
   MODEL-BASELINE:ABSENT MODEL-DECISION:NOOP MODEL:DECISION= TTRUE
   d j GONE ;

: SUBTREE$ ( MODEL:subtree -- ^u8 n )
   MATCH MODEL:subtree
      empty OF s" empty" ENDOF
      occupied OF s" occupied" ENDOF
   ;MATCH ;

: SUBTREE-AT
   ( ^VEC:vector<MODEL:remote-record> ^u8 n ^ARENA:arena -- ^u8 n )
   {: v p:^ u:n ar :}
   v p u ar CANONICAL REMOTE-SUBTREE SUBTREE$ ;

\ Rust's remote_directory.
: REMOTE-DIRECTORY+
   ( ^VEC:vector<MODEL:remote-record> ^u8 n ^ARENA:arena -- )
   {: v p:^ u:n ar :}
   v p u REMOTE-DIRECTORY ar REMOTE+ ;

: REMOTE-SUBTREE-HOLDS-ONLY-TRUE-DESCENDANTS ( ^ARENA:arena -- )
   {: ar :}
   s" remote_subtree_holds_only_true_descendants" T-LABEL
   ar REMOTE-RECORDS {: rs :}
   rs s" Report" ar REMOTE-DIRECTORY+
   rs s" report.txt" ar REMOTE-DIRECTORY+
   rs s" Report/x" ar REMOTE-DIRECTORY+
   rs s" reports/y" ar REMOTE-DIRECTORY+
   rs s\" deep/\xFF" ar REMOTE-DIRECTORY+
   rs ar REMOTE-MAP {: v :}
   v s" report" ar SUBTREE-AT s" occupied" T$=
   v s" reports" ar SUBTREE-AT s" occupied" T$=
   v s" deep" ar SUBTREE-AT s" occupied" T$=
   v s" report.txt" ar SUBTREE-AT s" empty" T$=
   v s" report/x" ar SUBTREE-AT s" empty" T$=
   v s" repo" ar SUBTREE-AT s" empty" T$=
   v s" other" ar SUBTREE-AT s" empty" T$= ;

\ Appends the byte of 00 . / 0 FF that digit d names, none for 0.
: SYMBOL+ ( n n ^u8 -- n )
   {: len:n d:n dst:^ :}
   d 0= if len exit then
   s\" \x00./0\xFF" drop d 1- + c@ dst len + c!
   len 1+ ;

\ The string k's three base-6 digits name, in dst.
: SYMBOL-STRING ( n ^u8 -- ^u8 n )
   {: k:n dst:^ :}
   0 k 3 0 do 6 /mod swap rot swap dst SYMBOL+ swap loop drop
   dst swap ;

216 constant STRINGS
4 BUFFER: LEFT
4 BUFFER: RIGHT
5 BUFFER: PREFIX

\ PRECEDES-CHILDREN? disagrees with a comparison against parent then
\ "/" materialized.
: DISAGREES? ( ^u8 n ^u8 n -- bool )
   {: b:^ u:n p:^ v:n :}
   p PREFIX v BYTE-COPY SEPARATOR PREFIX v + c!
   b u p v PRECEDES-CHILDREN? bool>n b u PREFIX v 1+ STR< bool>n <> ;

: CHILD-PREFIX-ORDER-MATCHES-THE-MATERIALIZED-PREFIX ( ^ARENA:arena -- )
   drop
   s" child_prefix_order_matches_the_materialized_prefix" T-LABEL
   0 STRINGS 0 ?do
      i LEFT SYMBOL-STRING
      STRINGS 0 ?do
         2dup i RIGHT SYMBOL-STRING DISAGREES? if rot 1+ -rot then
      loop 2drop
   loop
   0 T= ;

\ A path decision at the path, its key folded.
: DECIDED ( ^u8 n MODEL:decision ^ARENA:arena -- path-decision )
   {: p:^ u:n d ar :}
   p u ar CANONICAL p u DISPLAY false d PATH-DECISION-MAKE ;

: DECISION-PATH ( path-decision -- ^u8 n )
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
   ( ^VEC:vector<MODEL:local-record> ^u8 n
     MODEL:observation<MODEL:local> -- )
   {: v p:^ u:n o :}
   p u DISPLAY o MODEL-LOCAL--RECORD:MAKE v VEC:PUSH ! ;

\ Rust's local_records: each path a directory.
: DIR+ ( ^VEC:vector<MODEL:local-record> ^u8 n -- )
   DIRECTORY OBSERVED ;

: UNSUPPORTED-SPELLING+ ( ^VEC:vector<MODEL:local-record> ^u8 n -- )
   MODEL-UNKNOWN--REASON:UNSUPPORTED UNKNOWN OBSERVED ;

: INACCESSIBLE+ ( ^VEC:vector<MODEL:local-record> ^u8 n -- )
   MODEL-UNKNOWN--REASON:INACCESSIBLE UNKNOWN OBSERVED ;

\ Rust's identity: dropbox_content_hash of the bytes, read from a pipe.
: HASH-OF ( ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: b:^ u:n ar :}
   FD:PIPE {: r:fd w:fd :}
   w b u FD:WRITE-FULL w FS:CLOSE-DIR
   r ar LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR ;

\ A file at the path holding the bytes b.
: FILE+
   ( ^VEC:vector<MODEL:local-record> ^u8 n ^u8 n ^ARENA:arena -- )
   {: v p:^ u:n b:^ bu:n ar :}
   b bu ar HASH-OF MODEL-LOCAL:MAKE PRESENT {: o :}
   v p u o OBSERVED ;

: RECORDED-FOO ( MODEL:key -- option<MODEL:path> )
   drop s" FOO.txt" DISPLAY OPTION:SOME ;

: RECORDED-NOTES ( MODEL:key -- option<MODEL:path> )
   drop s" notes.txt" DISPLAY OPTION:SOME ;

: SOURCE$ ( option<MODEL:path> -- ^u8 n )
   MATCH option
      none OF s" (none)" ENDOF
      some OF PATH$ ENDOF
   ;MATCH ;

\ The source, failing the case when there is none.
: SOME-PATH ( option<MODEL:path> -- MODEL:path )
   MATCH option
      none OF false TTRUE s" " DISPLAY ENDOF
      some OF ENDOF
   ;MATCH ;

: UNBASED-SOURCE
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena -- MODEL:path )
   [: NO-SPELLING ;] swap CASE-VARIANT-SOURCE SOME-PATH ;

: MOVE-SOURCE$ ( case-variant-move -- ^u8 n )
   CASE-VARIANT-MOVE-UNMAKE {: s d :} s PATH$ ;

: MOVE-DESTINATION ( case-variant-move -- MODEL:path )
   CASE-VARIANT-MOVE-UNMAKE {: s d :} d ;

: CASE-VARIANT-NAME-SKIPS-EXISTING-SUFFIXES ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_name_skips_existing_suffixes" T-LABEL
   ar NEW-RECORDS {: v :}
   v s" Credit" DIR+
   v s" credit" DIR+
   v s" credit (case variant)" DIR+
   v s" CREDIT (CASE VARIANT 2)" DIR+
   v v ar UNBASED-SOURCE 255 ar CASE-VARIANT-MOVE {: mv :}
   mv MOVE-SOURCE$ s" credit" T$=
   mv MOVE-DESTINATION PATH$ s" credit (case variant 3)" T$= ;

: REPEATED ( u8 n ^ARENA:arena -- ^u8 n )
   {: c:u8 u:n ar :}
   ar u ARENA:ALLOC drop {: p:^ :}
   u 0 ?do c p i + c! loop
   p u ;

: CASE-VARIANT-NAME-FITS-A-MAXIMUM-LENGTH-COMPONENT ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_name_fits_a_maximum_length_component" T-LABEL
   ar NEW-RECORDS {: v :}
   v 65 255 ar REPEATED DIR+
   v 97 255 ar REPEATED DIR+
   v v ar UNBASED-SOURCE 255 ar CASE-VARIANT-MOVE MOVE-DESTINATION
   PATH$ SPLIT-NAME {: dir:^ du:n name:^ nu:n :}
   nu 255 T=
   name nu s"  (case variant)" ENDS-WITH? TTRUE ;

\ The name, failing the case when none fits.
: SOME-NAME ( option<str> -- str )
   MATCH option
      none OF false TTRUE s" " >str ENDOF
      some OF ENDOF
   ;MATCH ;

: FILE-COPY-NAME-IS-DETERMINISTIC-AND-FITS-THE-PARENT-LIMIT
   ( ^ARENA:arena -- )
   {: ar :}
   s" file_copy_name_is_deterministic_and_fits_the_parent_limit"
   T-LABEL
   97 255 ar REPEATED >str {: name:str :}
   98 64 ar REPEATED >str DROPBOX:>HASH {: h :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:path VEC:NEW {: none :}
   none construct file-copy-origin dropbox {: o :}
   name h o 0 255 ar FILE-COPY-NAME SOME-NAME str> {: a:^ au:n :}
   name h o 0 255 ar FILE-COPY-NAME SOME-NAME str> {: b:^ bu:n :}
   a au b bu T$=
   au 255 T=
   a au s"  (Dropbox file bbbbbbbbbbbb)" ENDS-WITH? TTRUE ;

: CASE-VARIANT-MOVES-CONVERGE-FROM-PARENT-TO-CHILD ( ^ARENA:arena -- )
   {: ar :}
   s" case_variant_moves_converge_from_parent_to_child" T-LABEL
   ar NEW-RECORDS {: v :}
   v s" Credit" DIR+
   v s" credit" DIR+
   v s" credit/Expenses" DIR+
   v s" credit/expenses" DIR+
   v v ar UNBASED-SOURCE 255 ar CASE-VARIANT-MOVE {: parent :}
   parent MOVE-SOURCE$ s" credit" T$=
   parent MOVE-DESTINATION PATH$ s" credit (case variant)" T$=
   ar NEW-RECORDS {: after :}
   after s" Credit" DIR+
   after s" credit (case variant)" DIR+
   after s" credit (case variant)/Expenses" DIR+
   after s" credit (case variant)/expenses" DIR+
   after after ar UNBASED-SOURCE 255 ar CASE-VARIANT-MOVE {: child :}
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

\ ---- RESOLVE-CASE-COLLISION

\ dir/name.
: INSIDE ( str ^u8 n ^ARENA:arena -- str )
   {: d:str a:^ u ar :}
   d str> s" /" ar JOIN-BYTES a u ar JOIN-BYTES >str ;

: TREE-GONE ( str -- ) str> FS:REMOVE-TREE ;

: MAKE-AT ( str ^u8 n ^ARENA:arena -- )
   INSIDE str> FS:MAKE-DIR ;

: WRITE-AT ( str ^u8 n ^u8 n ^ARENA:arena -- )
   {: r:str p:^ u:n b:^ bu:n ar :}
   r p u ar INSIDE str> b bu FS:WRITE-ALL ;

: THERE? ( str ^u8 n ^ARENA:arena -- bool ) INSIDE str> FS:EXISTS? ;

\ A case's directory under TMPDIR and the sync root in it, holding
\ Dir/a.txt and dir/b.txt.
: FIXTURE ( ^ARENA:arena -- str str )
   {: ar :}
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   d s" root" ar INSIDE {: r:str :}
   r str> FS:MAKE-DIR
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

: RECORDED? ( JOURNAL:plan-write -- bool )
   MATCH JOURNAL:plan-write
      recorded OF drop true ENDOF
      already-live OF drop false ENDOF
   ;MATCH ;

\ A pending plan creating the local directory at path.
: RECORD ( JOURNAL:journal ^u8 n ^ARENA:arena -- )
   {: j a:^ u ar :}
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY ar ONE-PLAN {: plan :}
   j a u DISPLAY plan ar JOURNAL:RECORD-PLAN RECORDED? TTRUE ;

\ The journal in the case's directory d, bound to the root r, with a
\ pending plan below each spelling and one beside them.
: BOUND ( str str ^ARENA:arena -- JOURNAL:journal )
   {: d:str r:str ar :}
   d s" journal.sqlite3" ar INSIDE JOURNAL:OPEN {: j :}
   j r JOURNAL:INSPECT ar JOURNAL:ACTIVATE-LOCAL-ROOT drop
   j s" Dir/a.txt" ar RECORD
   j s" dir/b.txt" ar RECORD
   j s" other.txt" ar RECORD
   j ;

: RESOLUTION$ ( case-collision-resolution ^ARENA:arena -- ^u8 n )
   {: ar :}
   MATCH case-collision-resolution
      none OF s" none" ENDOF
      renamed OF s" renamed " rot PATH$ ar JOIN-BYTES ENDOF
      changed OF s" changed " rot PATH$ ar JOIN-BYTES ENDOF
      root-changed OF s" root-changed" ENDOF
   ;MATCH ;

: PLAN-PATH$ ( ^VEC:vector<JOURNAL:plan-record> n -- ^u8 n )
   VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} p PATH$ ;

: RENAMES-ONE ( str str ^ARENA:arena -- )
   {: d:str r:str ar :}
   d r ar BOUND {: j :}
   ar TREE {: v :}
   v ar UNBASED-SOURCE PATH$ s" dir" T$=
   j r str> v ar RESOLVE-CASE-COLLISION ar RESOLUTION$
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
   d s" old" ar INSIDE {: old:str :}
   r str> old str> FS:RENAME-FILE
   r str> FS:MAKE-DIR
   j r str> ar TREE ar RESOLVE-CASE-COLLISION ar RESOLUTION$
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
   ar RESOLVE-CASE-COLLISION-RENAMES-ONE-SPELLING
   ar RESOLVE-CASE-COLLISION-ANSWERS-A-REPLACED-ROOT ;


\ ---- listing changes -------------------------------------------------

ARENA LISTED DROPBOX:entry

: ENTRY-AT
   ( DROPBOX:kind ^u8 n ^u8 n ^ARENA:arena -- ^DROPBOX:entry )
   {: kind l:^ lu:n d:^ du:n ar :}
   ar LISTED-NEW {: e :}
   kind e DROPBOX-ENTRY:KIND !
   l lu SPAN:MAKE e DROPBOX-ENTRY:LOWER !
   d du SPAN:MAKE e DROPBOX-ENTRY:DISPLAY !
   true e DROPBOX-ENTRY:DOWNLOADABLE !
   e ;

\ Rust's folder_metadata.
: FOLDER-ENTRY ( ^u8 n ^u8 n ^ARENA:arena -- ^DROPBOX:entry )
   {: l:^ lu:n d:^ du:n ar :}
   DROPBOX-KIND:FOLDER l lu d du ar ENTRY-AT ;

\ Rust's file_metadata: a revision and a well-formed content hash.
: FILE-ENTRY ( ^u8 n ^u8 n ^ARENA:arena -- ^DROPBOX:entry )
   {: l:^ lu:n d:^ du:n ar :}
   DROPBOX-KIND:FILE l lu d du ar ENTRY-AT {: e :}
   s" test-revision" SPAN:MAKE e DROPBOX-ENTRY:REV !
   s" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
   SPAN:MAKE e DROPBOX-ENTRY:CONTENT-HASH !
   e ;

: DELETED-ENTRY ( ^u8 n ^u8 n ^ARENA:arena -- ^DROPBOX:entry )
   {: l:^ lu:n d:^ du:n ar :}
   DROPBOX-KIND:DELETED l lu d du ar ENTRY-AT ;

: LISTING-AT ( ^u8 n ^ARENA:arena -- listing-root )
   {: p:^ u:n ar :}
   p u >str ar NEW-LISTING-ROOT ;

: NO-CHANGES
   ( ^ARENA:arena -- ^VEC:vector<JOURNAL:remote-inventory-change> )
   ARENA:ALLOCATOR 0 [type] JOURNAL:remote-inventory-change VEC:NEW ;

\ The record's path at the key's display bytes, else empty.
: PATH-OF
   ( ^VEC:vector<MODEL:remote-record> ^u8 n ^ARENA:arena -- ^u8 n )
   {: rs p:^ u:n ar :}
   rs p u ar CANONICAL FIND-REMOTE MATCH option
      none OF s" " ENDOF
      some OF MODEL-REMOTE--RECORD:UNMAKE {: k q o :} q PATH$ ENDOF
   ;MATCH ;

\ The records' paths, each followed by "|".
: RECORD-PATHS$ ( ^VEC:vector<MODEL:remote-record> -- ^u8 n )
   {: rs :}
   SB-RESET
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k q o :}
      q PATH$ SB-APPEND s" |" SB-APPEND
   loop
   SB$ ;

\ Rust's change_paths: the writes' paths, each followed by "|".
: CHANGE-PATHS
   ( ^VEC:vector<JOURNAL:remote-inventory-change> -- ^u8 n )
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
   s" /folder" s" /Folder" ar FOLDER-ENTRY root v ar APPEND-ENTRY-CHANGES
   s" /paper" s" /Paper" ar FILE-ENTRY {: paper :}
   false paper DROPBOX-ENTRY:DOWNLOADABLE !
   s" " SPAN:MAKE paper DROPBOX-ENTRY:CONTENT-HASH !
   paper root v ar APPEND-ENTRY-CHANGES
   v ar INVENTORY-RECORDS {: rs :}
   rs VEC:COUNT 2 T=
   rs s" folder" ar CANONICAL REMOTE-AT REMOTE-DIRECTORY
   MODEL:REMOTE-OBSERVATION= TTRUE
   rs s" paper" ar CANONICAL REMOTE-AT
   MODEL-UNKNOWN--REASON:UNSUPPORTED REMOTE-UNKNOWN
   MODEL:REMOTE-OBSERVATION= TTRUE ;

: DIRECTORY-RECORDS-NORMALIZE-INCONSISTENT-CHILD-ANCESTOR-CASING
   ( ^ARENA:arena -- )
   {: ar :}
   s" directory_records_normalize_inconsistent_child_ancestor_casing"
   T-LABEL
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /apps" s" /apps" ar FOLDER-ENTRY root v ar APPEND-ENTRY-CHANGES
   s" /apps/day one/entry.doentry" s" /Apps/day one/Entry.doentry"
   ar FILE-ENTRY root v ar APPEND-ENTRY-CHANGES
   s" /apps/day one" s" /Apps/Day One" ar FOLDER-ENTRY
   root v ar APPEND-ENTRY-CHANGES
   v ar INVENTORY-RECORDS {: rs :}
   rs s" apps" ar PATH-OF s" apps" T$=
   rs s" apps/day one" ar PATH-OF s" apps/Day One" T$=
   rs s" apps/day one/entry.doentry" ar PATH-OF
   s" apps/Day One/Entry.doentry" T$= ;

\ Rust's existing directories: Apps and Apps/Day One.
: EXISTING ( ^ARENA:arena -- ^VEC:vector<JOURNAL:remote-directory> )
   {: ar :}
   ar ARENA:ALLOCATOR 0 [type] JOURNAL:remote-directory VEC:NEW {: v :}
   s" apps" ar CANONICAL s" Apps" DISPLAY
   JOURNAL-REMOTE--DIRECTORY:MAKE v VEC:PUSH !
   s" apps/day one" ar CANONICAL s" Apps/Day One" DISPLAY
   JOURNAL-REMOTE--DIRECTORY:MAKE v VEC:PUSH !
   v ;

: DELTA-PATHS
   ( ^VEC:vector<JOURNAL:remote-inventory-change> ^ARENA:arena
     -- ^u8 n )
   {: v ar :}
   v ar EXISTING ar NORMALIZE-INVENTORY-CHANGES CHANGE-PATHS ;

: DELTA-NEVER-RESPELLS-A-DIRECTORY-THAT-STILL-EXISTS ( ^ARENA:arena -- )
   {: ar :}
   s" delta_never_respells_a_directory_that_still_exists" T-LABEL
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /apps" s" /apps" ar FOLDER-ENTRY root v ar APPEND-ENTRY-CHANGES
   s" /apps/day one/journal" s" /apps/day one/Journal" ar FOLDER-ENTRY
   root v ar APPEND-ENTRY-CHANGES
   v ar DELTA-PATHS s" Apps|Apps|Apps/Day One|Apps/Day One/Journal|" T$=
   ar NO-CHANGES {: w :}
   s" /apps/day one" s" /apps/day one" ar DELETED-ENTRY
   root w ar APPEND-ENTRY-CHANGES
   s" /apps/day one" s" /apps/DAY ONE" ar FOLDER-ENTRY
   root w ar APPEND-ENTRY-CHANGES
   w ar DELTA-PATHS s" Apps|Apps/DAY ONE|" T$=
   ar NO-CHANGES {: x :}
   s" /apps" s" /apps" ar DELETED-ENTRY root x ar APPEND-ENTRY-CHANGES
   s" /apps/day one/journal" s" /APPS/DAY ONE/Journal" ar FOLDER-ENTRY
   root x ar APPEND-ENTRY-CHANGES
   x ar DELTA-PATHS s" APPS|APPS/DAY ONE|APPS/DAY ONE/Journal|" T$= ;

: LISTING-REJECTS-MISMATCHED-CANONICAL-AND-DISPLAY-PATHS
   ( ^ARENA:arena -- )
   {: ar :}
   s" listing_rejects_mismatched_canonical_and_display_paths" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /report.txt" s" /Different.txt" ar FILE-ENTRY {: e :}
   d [: [: e root v ar APPEND-ENTRY-CHANGES ;] E-LISTING TTHROWSQ ;]
   ar LOGGED {: t:^ tu:n :}
   t tu 10 COUNT-CHAR 1 T=
   t tu s" invalid or out-of-root path `/Different.txt`" CONTAINS? TTRUE
   v ar INVENTORY-RECORDS VEC:COUNT 0 T=
   d str> FS:REMOVE-TREE ;

\ The configured root p refused: E-LISTING and its one line.
: ROOT-PATH-REFUSED ( ^u8 n str ^ARENA:arena -- )
   {: p:^ u:n d:str ar :}
   d [: [: p u ar LISTING-AT ROOT-DEPTH drop ;] E-LISTING TTHROWSQ ;]
   ar LOGGED {: t:^ tu:n :}
   t tu 10 COUNT-CHAR 1 T=
   t tu
   s" configured Dropbox root must be empty or a normalized absolute Dropbox path"
   CONTAINS? TTRUE ;

: LISTING-REJECTS-AN-INVALID-CONFIGURED-ROOT ( ^ARENA:arena -- )
   {: ar :}
   s" listing rejects an invalid configured root" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   s" a/b" d ar ROOT-PATH-REFUSED
   s" /a/" d ar ROOT-PATH-REFUSED
   s" /a//b" d ar ROOT-PATH-REFUSED
   s\" /a\xFF" d ar ROOT-PATH-REFUSED
   d str> FS:REMOVE-TREE ;

\ The entry e refused as an invalid path: E-LISTING, its one line,
\ nothing listed; the line's text.
: ENTRY-REFUSED ( ^DROPBOX:entry str ^ARENA:arena -- ^u8 n )
   {: e d:str ar :}
   s" " ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   d [: [: e root v ar APPEND-ENTRY-CHANGES ;] E-LISTING TTHROWSQ ;]
   ar LOGGED {: t:^ tu:n :}
   t tu 10 COUNT-CHAR 1 T=
   t tu s" Dropbox listing contained an invalid or out-of-root path"
   CONTAINS? TTRUE
   v ar INVENTORY-RECORDS VEC:COUNT 0 T=
   t tu ;

: LISTING-REJECTS-AN-ENTRY-WITHOUT-PATHS ( ^ARENA:arena -- )
   {: ar :}
   s" listing rejects an entry without paths" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   s" " s" " ar FILE-ENTRY d ar ENTRY-REFUSED {: t:^ tu:n :}
   t tu s" `" CONTAINS? TFALSE
   d str> FS:REMOVE-TREE ;

: LISTING-REJECTS-A-PATH-THAT-IS-NOT-UTF-8 ( ^ARENA:arena -- )
   {: ar :}
   s" listing rejects a path that is not UTF-8" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   s\" /report\xFF.txt" s\" /report\xFF.txt" ar FILE-ENTRY
   d ar ENTRY-REFUSED 2drop
   d str> FS:REMOVE-TREE ;

\ The root's own entry e refused with its text t: E-LISTING, one line
\ naming t, and nothing listed after Old.
: ROOT-REFUSED ( ^DROPBOX:entry ^u8 n str ^ARENA:arena -- )
   {: e t:^ tu:n d:str ar :}
   s" /Sync" ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /sync/old" s" /Sync/Old" ar FOLDER-ENTRY
   root v ar APPEND-ENTRY-CHANGES
   s" /sync/child" s" /Sync/Child" ar FOLDER-ENTRY {: child :}
   d [: [: e root v ar APPEND-ENTRY-CHANGES
         child root v ar APPEND-ENTRY-CHANGES ;] E-LISTING TTHROWSQ ;]
   ar LOGGED {: g:^ gu:n :}
   g gu 10 COUNT-CHAR 1 T=
   g gu t tu CONTAINS? TTRUE
   v ar INVENTORY-RECORDS {: rs :}
   rs RECORD-PATHS$ s" Old|" T$=
   rs s" old" ar CANONICAL REMOTE-AT REMOTE-DIRECTORY
   MODEL:REMOTE-OBSERVATION= TTRUE ;

: ROOT-ACCEPTED ( ^ARENA:arena -- )
   {: ar :}
   s" /Sync" ar LISTING-AT {: root :}
   ar NO-CHANGES {: v :}
   s" /sync" s" /Sync" ar FOLDER-ENTRY root v ar APPEND-ENTRY-CHANGES
   s" /sync/child" s" /Sync/Child" ar FOLDER-ENTRY
   root v ar APPEND-ENTRY-CHANGES
   v ar INVENTORY-RECORDS RECORD-PATHS$ s" Child|" T$= ;

: LISTING-CLASSIFIES-THE-REMOTE-ROOTS-OWN-ENTRY ( ^ARENA:arena -- )
   {: ar :}
   s" listing_classifies_the_remote_roots_own_entry" T-LABEL
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   ar ROOT-ACCEPTED
   s" /sync" s" /Sync" ar DELETED-ENTRY
   s" configured Dropbox root is unavailable" d ar ROOT-REFUSED
   s" /sync" s" /Sync" ar FOLDER-ENTRY {: r :}
   true r DROPBOX-ENTRY:RESTRICTED !
   r s" configured Dropbox root cannot be traversed completely" d ar
   ROOT-REFUSED
   s" /sync" s" /Sync" ar FILE-ENTRY
   s" configured Dropbox root is not a folder" d ar ROOT-REFUSED
   d str> FS:REMOVE-TREE ;

\ ---- the listing against the fake Dropbox ---------------------------

TYPED-VARIABLE CFG DROPBOX:config
\ The client on the fake, while it serves.
TYPED-VARIABLE MAIN ^DROPBOX:client
ARENA LINKS REPLAY:link

\ A client on the fake, no root, keeping no rotated token.
: OPENED ( ^ARENA:arena -- ^DROPBOX:client )
   {: ar :}
   [: 2drop ;] CFG DROPBOX-CONFIG:STORE !
   CFG DROPBOX:PRODUCTION
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:API !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:NOTIFY !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:CONTENT !
   s" fake-key" SPAN:MAKE CFG DROPBOX-CONFIG:KEY !
   s" live-token" SPAN:MAKE CFG DROPBOX-CONFIG:TOKEN !
   s" " SPAN:MAKE CFG DROPBOX-CONFIG:ROOT !
   CFG ar DROPBOX:OPEN ;

\ Ends the run: the case cannot go on.
: FAILED ( ^u8 n -- ) T-EX-FAIL die ;

: CURL-READY ( CURL:status -- )
   MATCH CURL:status
      ok OF ENDOF
      failed OF drop s" the curl loop did not start" FAILED ENDOF
   ;MATCH ;

\ The account call takes the client's first access token, so no case's
\ requests start with a refresh.
: ACCOUNT-OF ( ^DROPBOX:client -- )
   DROPBOX:ACCOUNT MATCH DROPBOX:reply
      done OF ENDOF
      refused OF drop s" the account was refused" FAILED ENDOF
      retry OF drop s" the account asked a retry" FAILED ENDOF
      unlinked OF s" the account was unlinked" FAILED ENDOF
   ;MATCH ;

: ACCOUNTED ( -- ) MAIN @ ACCOUNT-OF ;

: NEW-LINK ( ^ARENA:arena -- ^REPLAY:link )
   LINKS-NEW {: l :} MAIN @ l REPLAY-LINK:CLIENT ! l ;

: RETRY? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF drop true ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

: QUOTED+ ( ^u8 n -- ) S\" \q" SB-APPEND SB-APPEND S\" \q" SB-APPEND ;

: PATHS+ ( ^u8 n ^u8 n -- )
   {: l:^ lu:n d:^ du:n :}
   S\" ,\qpath_lower\q:" SB-APPEND l lu QUOTED+
   S\" ,\qpath_display\q:" SB-APPEND d du QUOTED+ ;

\ Rust's folder_metadata, deleted_metadata and file_metadata, each
\ appended to SB.
: FOLDER-JSON+ ( ^u8 n ^u8 n -- )
   S\" {\q.tag\q:\qfolder\q" SB-APPEND PATHS+ s" }" SB-APPEND ;

: DELETED-JSON+ ( ^u8 n ^u8 n -- )
   S\" {\q.tag\q:\qdeleted\q" SB-APPEND PATHS+ s" }" SB-APPEND ;

: FILE-JSON+ ( ^u8 n ^u8 n ^u8 n DROPBOX:hash -- )
   {: l:^ lu:n d:^ du:n r:^ ru:n h:DROPBOX:hash :}
   S\" {\q.tag\q:\qfile\q" SB-APPEND l lu d du PATHS+
   S\" ,\qrev\q:" SB-APPEND r ru QUOTED+
   S\" ,\qsize\q:0,\qcontent_hash\q:" SB-APPEND
   h DROPBOX:HASH>STR str> QUOTED+ s" }" SB-APPEND ;

: COMMA+ ( -- ) s" ," SB-APPEND ;

\ The entries q appends, as a JSON array in the arena.
: ENTRIES ( [ -- ] ^ARENA:arena -- str )
   {: q ar :}
   SB-RESET s" [" SB-APPEND q execute s" ]" SB-APPEND SB$ ar COPIED ;

: PAGE ( str ^u8 n bool -- )
   {: e:str k:^ ku:n more:bool :}
   e str> k ku more TEST-DROPBOX:PAGE! ;

: CONTINUE$ ( -- ^u8 n ) s" /2/files/list_folder/continue" ;

\ Rust's 503 answer, which only a continuation gets.
: UNAVAILABLE! ( -- )
   CONTINUE$ 503 s" " s" "
   S\" {\qerror\q:{\q.tag\q:\qother\q}}" TEST-DROPBOX:ROUTE-SCRIPT! ;

\ Rust's Old.txt at rev-old with the identity h.
: OLD-RECORD ( DROPBOX:hash ^ARENA:arena -- MODEL:remote-record )
   {: h:DROPBOX:hash ar :}
   s" old.txt" ar CANONICAL s" Old.txt" DISPLAY
   h s" rev-old" >str DROPBOX:>REV MODEL-REMOTE:MAKE REMOTE-PRESENT
   MODEL-REMOTE--RECORD:MAKE ;

\ The journal's inventory: the record o, published with the cursor.
: PUBLISHED
   ( JOURNAL:journal ^u8 n MODEL:remote-record ^ARENA:arena -- )
   {: j k:^ ku:n o ar :}
   ar REMOTE-RECORDS {: rs :} o rs VEC:PUSH !
   j k ku >str DROPBOX:>CURSOR rs JOURNAL:PUBLISH-REMOTE-INVENTORY ;

: CURSOR-IS? ( option<DROPBOX:cursor> ^u8 n -- bool )
   {: a:^ u :}
   MATCH option
      none OF false ENDOF
      some OF DROPBOX:CURSOR>STR str> a u STR= ENDOF
   ;MATCH ;

: KIND$ ( MODEL:observation<MODEL:remote> -- ^u8 n )
   MATCH MODEL:observation
      present OF drop s" present" ENDOF
      directory OF s" directory" ENDOF
      absent OF s" absent" ENDOF
      unknown OF drop s" unknown" ENDOF
   ;MATCH ;

\ Rust's observation: the kind of the record at the display path, else
\ none.
: OBSERVED$ ( ^VEC:vector<MODEL:remote-record> ^u8 n -- ^u8 n )
   {: rs p:^ u:n :}
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k q o :}
      q PATH$ p u STR= if o KIND$ unloop exit then
   loop
   s" none" ;

: REFRESHED ( JOURNAL:journal ^REPLAY:link ^ARENA:arena -- )
   {: j l ar :}
   j l s" " ar LISTING-AT ar REFRESH-INVENTORY ;

\ The journal's one record is o, with the cursor k.
: KEPT ( JOURNAL:journal ^u8 n MODEL:remote-record ^ARENA:arena -- )
   {: j k:^ ku:n o ar :}
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   cur k ku CURSOR-IS? TTRUE
   rs VEC:COUNT 1 T=
   rs 0 VEC:AT @ o MODEL:REMOTE-RECORD= TTRUE ;

: CURSOR-RESET-REBUILDS-BEFORE-ONE-COMPLETE-PUBLICATION
   ( ^ARENA:arena -- )
   {: ar :}
   s" cursor_reset_rebuilds_before_one_complete_publication" T-LABEL
   TEST-DROPBOX:RESET
   s" replacement" ar IDENTITY {: h:DROPBOX:hash :}
   ar CASE-JOURNAL {: d:str j :}
   j s" stale" s" old" >str DROPBOX:>HASH ar OLD-RECORD ar
   PUBLISHED
   TEST-DROPBOX:PAGE-RESET!
   [: s" /folder" s" /Folder" FOLDER-JSON+ ;] ar ENTRIES
   s" fresh-a" true PAGE
   [: s" /new.txt" s" /New.txt" s" rev-new" h FILE-JSON+ ;] ar ENTRIES
   s" fresh-b" false PAGE
   j ar NEW-LINK ar REFRESHED
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
   ar NEW-LINK {: l :}
   [: j l ar REFRESHED ;] REPLAY:E-DROPBOX TTHROWSQ
   l REPLAY-LINK:REPLY @ RETRY? TTRUE
   j s" durable-cursor" old ar KEPT
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder/continue /2/files/list_folder /2/files/list_folder/continue"
   T$=
   d j GONE ;

: TREE-JSON+ ( ^u8 n ^u8 n DROPBOX:hash -- )
   {: l:^ lu:n d:^ du:n h:DROPBOX:hash :}
   l lu d du s" tree-revision" h FILE-JSON+ ;

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
   j ar NEW-LINK ar REFRESHED
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
   s" durable-old" >str DROPBOX:>HASH ar OLD-RECORD {: old :}
   ar CASE-JOURNAL {: d:str j :}
   j s" durable-cursor" old ar PUBLISHED
   [: s" /old.txt" s" /Old.txt" s" rev-changed" h FILE-JSON+ ;] ar ENTRIES
   {: e:str :}
   \ Both pages are continuations, so the first is a script too.
   SB-RESET S\" {\qentries\q:" SB-APPEND e str> SB-APPEND
   S\" ,\qcursor\q:\qnext\q,\qhas_more\q:true}" SB-APPEND
   CONTINUE$ 200 s" " s" " SB$ TEST-DROPBOX:ROUTE-SCRIPT!
   UNAVAILABLE!
   ar NEW-LINK {: l :}
   [: j l ar REFRESHED ;] REPLAY:E-DROPBOX TTHROWSQ
   l REPLAY-LINK:REPLY @ RETRY? TTRUE
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
   ( ^u8 n MODEL:observation<MODEL:remote> ^ARENA:arena
     -- MODEL:remote-record )
   {: p:^ u:n o ar :}
   p u ar CANONICAL p u DISPLAY o MODEL-REMOTE--RECORD:MAKE ;

: STALE ( -- MODEL:observation<MODEL:remote> )
   MODEL-UNKNOWN--REASON:STALE REMOTE-UNKNOWN ;

: PRESENT-AT
   ( DROPBOX:hash ^u8 n -- MODEL:observation<MODEL:remote> )
   {: h:DROPBOX:hash r:^ ru:n :}
   h r ru >str DROPBOX:>REV MODEL-REMOTE:MAKE REMOTE-PRESENT ;

\ Rust's {index:05}, appended to SB.
: INDEX+ ( n -- )
   {: x:n :}
   10000 begin dup 0 > while
      x over / 10 mod [char] 0 + SB-APPEND-C 10 /
   repeat drop ;

\ The bulk name at the index below the prefix: <prefix>/00042.txt.
: BULK$ ( ^u8 n n -- ^u8 n )
   {: p:^ u:n x:n :}
   SB-RESET p u SB-APPEND s" /" SB-APPEND x INDEX+
   s" .txt" SB-APPEND SB$ ;

\ Rust's large inventory: Bulk, then Bulk/00001.txt on at rev-old with
\ the identity h, u records in all.
: BULK-RECORDS
   ( DROPBOX:hash n ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: h:DROPBOX:hash u:n ar :}
   ar REMOTE-RECORDS {: rs :}
   s" Bulk" REMOTE-DIRECTORY ar RECORD-AT rs VEC:PUSH !
   u 1 ?do
      s" Bulk" i BULK$ ar COPIED str> h s" rev-old" PRESENT-AT
      ar RECORD-AT rs VEC:PUSH !
   loop
   rs ;

\ Rust's observation: the record at the display path is o.
: OBSERVED?
   ( ^VEC:vector<MODEL:remote-record> ^u8 n
     MODEL:observation<MODEL:remote> -- bool )
   {: rs p:^ u:n o :}
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k q w :}
      q PATH$ p u STR= if w o MODEL:REMOTE-OBSERVATION= unloop exit then
   loop
   false ;

\ The journal's inventory, sorted by key as Rust sorts it, is the
\ cursor k and the records want.
: HOLDS
   ( JOURNAL:journal ^u8 n ^VEC:vector<MODEL:remote-record>
     ^ARENA:arena -- )
   {: j k:^ ku:n want ar :}
   j ar JOURNAL:REMOTE-INVENTORY
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur rs :}
   cur k ku CURSOR-IS? TTRUE
   rs VEC:COUNT want VEC:COUNT T=
   rs VEC:COUNT want VEC:COUNT min 0 ?do
      rs i VEC:AT @ want i VEC:AT @ MODEL:REMOTE-RECORD= TTRUE
   loop ;

\ A text that grows in the arena.
: NO-TEXT ( ^ARENA:arena -- ^VEC:vector<u8> )
   ARENA:ALLOCATOR 0 [type] u8 VEC:NEW ;

: TEXT+ ( ^VEC:vector<u8> ^u8 n -- )
   {: v a:^ u:n :}
   v VEC:COUNT {: at:n :}
   v at u + VEC:RESIZE
   a v at VEC:AT u BYTE-COPY ;

: TEXT>STR ( ^VEC:vector<u8> -- str )
   {: v :}
   v 0 VEC:AT v VEC:COUNT >str ;

\ Rust's large listing's entry at the index: the folder /bulk, then
\ /bulk/00001.txt on at rev-bulk with the identity h; in SB.
: BULK-ENTRY ( n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: x:n h:DROPBOX:hash ar :}
   x 0= if SB-RESET s" /bulk" s" /Bulk" FOLDER-JSON+ SB$ exit then
   s" /bulk" x BULK$ ar COPIED {: l:str :}
   s" /Bulk" x BULK$ ar COPIED {: d:str :}
   SB-RESET l str> d str> s" rev-bulk" h FILE-JSON+ SB$ ;

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
: LISTED$ ( n -- ^u8 n )
   {: u:n :}
   SB-RESET s" /2/files/list_folder" SB-APPEND
   u 1 ?do s"  " SB-APPEND CONTINUE$ SB-APPEND loop
   SB$ ;

\ Rust's incomplete_file_metadata: downloadable, with no content hash.
: INCOMPLETE-JSON+ ( ^u8 n ^u8 n ^u8 n -- )
   {: l:^ lu:n d:^ du:n r:^ ru:n :}
   S\" {\q.tag\q:\qfile\q" SB-APPEND l lu d du PATHS+
   S\" ,\qrev\q:" SB-APPEND r ru QUOTED+
   S\" ,\qsize\q:0,\qis_downloadable\q:true}" SB-APPEND ;

\ Rust's restricted_folder_metadata with traverse_only.
: TRAVERSE-ONLY-JSON+ ( ^u8 n ^u8 n -- )
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
   j s" cursor-old" >str DROPBOX:>CURSOR old 10000 ar BULK-RECORDS
   JOURNAL:PUBLISH-REMOTE-INVENTORY
   [: s" /bulk/05000.txt" s" /Bulk/05000.txt" s" rev-new" h
      FILE-JSON+ ;] ar ENTRIES
   s" cursor-new" false PAGE
   j ar NEW-LINK ar REFRESHED
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
   ar NEW-LINK {: l :}
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
   j ar NEW-LINK ar REFRESHED
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
   j ar NEW-LINK ar REFRESHED
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

: REFRESH-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar CURSOR-RESET-REBUILDS-BEFORE-ONE-COMPLETE-PUBLICATION
   ar FAILED-REBUILD-AFTER-CURSOR-RESET-PRESERVES-DURABLE-INVENTORY
   ar LISTING-APPLIES-ORDERED-TREE-MUTATIONS-ACROSS-PAGES
   ar FAILED-LATER-PAGE-CANNOT-PUBLISH-PARTIAL-LISTING-AS-ABSENCE
   ar ONE-FILE-CURSOR-DELTA-UPDATES-A-LARGE-INVENTORY-WITHOUT-A-FULL-LISTING
   ar LARGE-FULL-LISTING-BUILDS-ITS-INVENTORY-IN-LINEAR-TIME
   ar INCOMPLETE-DOWNLOADABLE-METADATA-PUBLISHES-AS-UNKNOWN-INCOMPLETE
   ar RESTRICTED-LATER-PAGE-PUBLISHES-AS-UNKNOWN-INACCESSIBLE ;


\ ---- the replay step against the fake Dropbox ---------------------

ARENA RUNS run
4096 constant READ-CAP
READ-CAP BUFFER: READ-BUF

\ A link whose transfers a status below the directory d shows.
: STEP-LINK ( str ^ARENA:arena -- ^REPLAY:link )
   {: d:str ar :}
   ar NEW-LINK {: l :}
   d ar STATUS:NEW l REPLAY-LINK:STATUS !
   l ;

\ A case's directory under TMPDIR, holding root, staging and a journal
\ bound to the root, and a pass over them.
: STEP-RUN ( ^ARENA:arena -- str ^run )
   {: ar :}
   s" reconcile-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   d s" root" ar INSIDE {: r:str :}
   d s" staging" ar INSIDE {: s:str :}
   r str> FS:MAKE-DIR s str> FS:MAKE-DIR
   d s" journal.sqlite3" ar INSIDE JOURNAL:OPEN {: j :}
   j r JOURNAL:INSPECT ar JOURNAL:ACTIVATE-LOCAL-ROOT drop
   ar RUNS-NEW {: x :}
   j x RUN-JOURNAL ! d ar STEP-LINK x RUN-LINK !
   r x RUN-ROOT ! s x RUN-STAGING ! ar x RUN-ARENA !
   d x ;

: STEP-GONE ( str ^run -- ) RUN-JOURNAL @ GONE ;

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
: INSTALLING ( ^run ^u8 n MODEL:remote -- JOURNAL:plan-record )
   {: x a:^ u:n rem :}
   x RUN-ARENA @ {: ar :}
   rem MODEL-OPERATION:INSTALL-LOCAL ar ONE-PLAN {: plan :}
   x RUN-JOURNAL @ a u DISPLAY plan ar JOURNAL:RECORD-PLAN
   WRITTEN TTRUE ;

: NUMBERED ( ^u8 n n ^ARENA:arena -- str )
   {: a:^ u:n k:n ar :}
   SB-RESET a u SB-APPEND k FMT:SB-INT SB$ ar COPIED ;

\ The fake's file /<p> at rev v with b's identity and size.
: FILE-AT ( ^u8 n ^u8 n ^u8 n ^ARENA:arena -- )
   {: p:^ pu:n v:^ vu:n b:^ bu:n ar :}
   b bu ar IDENTITY DROPBOX:HASH>STR str> {: h:^ hu:n :}
   SB-RESET s" /" SB-APPEND p pu SB-APPEND SB$ ar COPIED {: l:str :}
   l str> l str> v vu h hu bu TEST-DROPBOX:FILE! ;

\ The fake serves b as rev v of /<p>.
: SERVES ( ^u8 n ^u8 n ^u8 n ^ARENA:arena -- )
   {: p:^ pu:n v:^ vu:n b:^ bu:n ar :}
   p pu v vu b bu ar FILE-AT
   v vu b bu TEST-DROPBOX:CONTENT! ;

: DOWNLOAD$ ( -- ^u8 n ) s" /2/files/download" ;

\ The fake's record of u downloads.
: DOWNLOADS$ ( n -- ^u8 n )
   {: u:n :}
   SB-RESET
   u 0 ?do i 0<> if s"  " SB-APPEND then DOWNLOAD$ SB-APPEND loop
   SB$ ;

: REPORTED ( replay-step -- ^REPLAY:replay-report )
   MATCH replay-step
      root-changed OF s" the replay step lost its root" FAILED ENDOF
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
: HELD-FOR$ ( JOURNAL:plan-record -- ^u8 n )
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
         s"  " SB-APPEND p str> SB-APPEND
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
: REPORTS? ( ^REPLAY:replay-report ^u8 n -- bool )
   {: rep e:^ eu:n :}
   rep BLOCKS {: bs :}
   bs VEC:COUNT 0 ?do
      SB-RESET bs i VEC:AT @ BLOCKED+
      SB$ e eu STR= if true unloop exit then
   loop
   false ;

\ The reply's variant, then a retry's wait, else 0.
: REPLY$ ( DROPBOX:reply -- ^u8 n n )
   MATCH DROPBOX:reply
      done OF s" done" 0 ENDOF
      refused OF drop s" refused" 0 ENDOF
      retry OF {: ms:n :} s" retry" ms ENDOF
      unlinked OF s" unlinked" 0 ENDOF
   ;MATCH ;

: MISMATCH$ ( -- ^u8 n ) s" correct body with mismatched metadata" ;

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
: BLOCKS-MISMATCH ( [ -- ] ^u8 n ^ARENA:arena -- )
   {: q w:^ wu:n ar :}
   TEST-DROPBOX:RESET q execute
   ar STEP-RUN {: d:str x :}
   MISMATCH$ s" expected-revision" ar REMOTE-FILE {: rem :}
   x s" mismatch.txt" rem INSTALLING drop
   SB-RESET s" durable-plan mismatch.txt " SB-APPEND w wu SB-APPEND
   SB$ ar COPIED {: e:str :}
   x REPLAY-STEP REPORTED e str> REPORTS? TTRUE
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ HELD-FOR$ w wu T$=
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
   s" global-" st ar NUMBERED str>
   s" revision-" st ar NUMBERED str> ar REMOTE-FILE {: rem :}
   x s" global.txt" rem INSTALLING drop
   d x ;

\ The step ends with E-DROPBOX, the reply w with the wait ms kept in
\ the link and the plan still pending; the fake saw the requests s.
: ENDS-STEP ( ^run ^u8 n n ^u8 n -- )
   {: x w:^ wu:n ms:n s:^ su:n :}
   [: x STEPPED ;] REPLAY:E-DROPBOX TTHROWSQ
   x RUN-LINK @ REPLAY-LINK:REPLY @ REPLY$ ms T= w wu T$=
   x PENDING-OF VEC:COUNT 1 T=
   x BLOCKED-OF VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s su T$= ;

\ The answer q scripts for status st ends the step.
: STAYS-GLOBAL ( [ -- ] n ^u8 n n ^ARENA:arena -- )
   {: q st:n w:^ wu:n ms:n ar :}
   TEST-DROPBOX:RESET q execute
   MAIN @ st ar GLOBAL-RUN {: d:str x :}
   x w wu ms DOWNLOAD$ ENDS-STEP
   d x STEP-GONE ;

\ The client c, holding its first token, refreshes on a 401 and sends
\ again once, so a revoked token ends the step unlinked.
: REVOKED ( ^DROPBOX:client ^ARENA:arena -- )
   {: c ar :}
   c ACCOUNT-OF
   TEST-DROPBOX:RESET TEST-DROPBOX:REVOKE
   c 401 ar GLOBAL-RUN {: d:str x :}
   x s" unlinked" 0
   s" /2/files/download /oauth2/token /2/files/download" ENDS-STEP
   d x STEP-GONE ;

\ A client of its own, so MAIN stays linked.
: UNAUTHORIZED ( ^ARENA:arena -- )
   {: ar :}
   ar OPENED {: c :}
   [: c ar REVOKED ;] [: c DROPBOX:CLOSE ;] finally ;

: WORKER-AUTH-RATE-LIMIT-AND-SERVER-FAILURES-REMAIN-GLOBAL
   ( ^ARENA:arena -- )
   {: ar :}
   s" worker_auth_rate_limit_and_server_failures_remain_global" T-LABEL
   ar UNAUTHORIZED
   [: RATE-LIMITED ;] 429 s" retry" 7000 ar STAYS-GLOBAL
   [: SERVER-ERROR ;] 500 s" retry" 0 ar STAYS-GLOBAL ;

: EXPECTED$ ( -- ^u8 n ) s" expected download bytes" ;
: OCCUPANT$ ( -- ^u8 n ) s" unrelated occupant bytes" ;

: STAGED? ( LOCAL:stage-outcome<n> -- bool )
   MATCH LOCAL:stage-outcome
      staged OF drop true ENDOF
      already-staged OF drop false ENDOF
      content-changed OF drop false ENDOF
      destination-occupied OF drop false ENDOF
   ;MATCH ;

\ The pipe's bytes, of identity c, staged as target t's download.
: STAGE-FROM ( fd ^run ^u8 n DROPBOX:hash fd -- bool )
   {: root:fd x t:^ tu:n c:DROPBOX:hash rd:fd :}
   root x ROOT$ t tu c [: rd -rot LOCAL:FD-READ ;] x RUN-ARENA @
   LOCAL:STAGE-DOWNLOAD-AT STAGED? ;

\ Rust's stage_download: b staged as target t's download.
: PRESTAGED ( fd ^run ^u8 n ^u8 n -- )
   {: root:fd x t:^ tu:n b:^ bu:n :}
   b bu x RUN-ARENA @ IDENTITY {: c:DROPBOX:hash :}
   FD:PIPE {: rd:fd w:fd :}
   w b bu FD:WRITE-FULL w FS:CLOSE-DIR
   [: root x t tu c rd STAGE-FROM TTRUE ;] [: rd FS:CLOSE-DIR ;]
   finally ;

: ONE-NAME? ( ^u8 n -- bool )
   10 INDEX-OF MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

\ The root's one entry, the stage PRESTAGED made.
: STAGE-PATH ( ^run -- str )
   {: x :}
   x ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u ONE-NAME? TTRUE
   READ-BUF u s" .omabox-download-" STARTS-WITH? TTRUE
   x RUN-ROOT @ READ-BUF u x RUN-ARENA @ INSIDE ;

: HOLDS-BYTES ( str ^u8 n -- )
   {: f:str b:^ bu:n :}
   f str> READ-BUF READ-CAP FS:READ-ALL {: u:n :}
   READ-BUF u b bu T$= ;

\ The stage of occupied.txt's download, holding other bytes, and the
\ plan to install it.
: OCCUPIED ( ^run -- str JOURNAL:plan-record )
   {: x :}
   x ROOT$ s" open test root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root x s" occupied.txt" EXPECTED$ PRESTAGED ;]
   [: root FS:CLOSE-DIR ;] finally
   x STAGE-PATH {: sp:str :}
   sp str> FS:REMOVE-FILE sp str> OCCUPANT$ FS:WRITE-ALL
   EXPECTED$ s" occupied-stage-revision" x RUN-ARENA @ REMOTE-FILE
   {: rem :}
   sp x s" occupied.txt" rem INSTALLING ;

\ Rust's StageDestinationOccupied for the plan p at the stage sp.
: OCCUPIED-ENTRY ( JOURNAL:plan-record str ^ARENA:arena -- str )
   {: p sp:str ar :}
   SB-RESET s" stage-destination-occupied " SB-APPEND
   p ID-OF JOURNAL:PLAN-ID>N FMT:SB-INT
   s"  " SB-APPEND sp str> SB-APPEND SB$ ar COPIED ;

: OCCUPIED-DOWNLOAD-STAGE-IS-DURABLY-BLOCKED-WITHOUT-OVERWRITE-OR-REQUEST
   ( ^ARENA:arena -- )
   {: ar :}
   s" occupied_download_stage_is_durably_blocked_without_overwrite_or_request"
   T-LABEL
   TEST-DROPBOX:RESET
   ar STEP-RUN {: d:str x :}
   x OCCUPIED {: sp:str p :}
   p sp ar OCCUPIED-ENTRY {: e:str :}
   x REPLAY-STEP REPORTED e str> REPORTS? TTRUE
   sp OCCUPANT$ HOLDS-BYTES
   x PENDING-OF VEC:COUNT 0 T=
   x BLOCKED-OF {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ HELD-FOR$ s" stage-occupied" T$=
   TEST-DROPBOX:SEEN$ s" " T$=
   d x STEP-GONE ;

5 constant DOWNLOAD-COUNT
4 constant COMPLETED-BATCH

: BATCH$ ( -- ^u8 n ) s" install each bounded batch" ;

\ batch-<k>.txt and its own rev, batch-<k>.
: BATCH ( n ^ARENA:arena -- str str )
   {: k:n ar :}
   s" batch-" k ar NUMBERED {: v:str :}
   SB-RESET v str> SB-APPEND s" .txt" SB-APPEND SB$ ar COPIED v ;

\ The fake serves batch file k's bytes, the last's only past a byte it
\ does not keep, so its download from the start answers 500.
: BATCH-SERVED ( str str n ^ARENA:arena -- )
   {: p:str v:str k:n ar :}
   p str> v str> BATCH$ ar FILE-AT
   BATCH$ {: b:^ bu:n :}
   k COMPLETED-BATCH < if v str> b bu TEST-DROPBOX:CONTENT! exit then
   v str> 1 b 1 + bu 1 - TEST-DROPBOX:CONTENT-TAIL! ;

\ Batch file k, served, and its pending plan.
: BATCHED ( ^run n -- )
   {: x k:n :}
   x RUN-ARENA @ {: ar :}
   k ar BATCH {: p:str v:str :}
   p v k ar BATCH-SERVED
   BATCH$ v str> ar REMOTE-FILE {: rem :}
   x p str> rem INSTALLING drop ;

\ Whether batch file k is installed, holding the batch's bytes.
: INSTALLED? ( ^run n -- bool )
   {: x k:n :}
   k x RUN-ARENA @ BATCH drop {: p:str :}
   x RUN-ROOT @ p str> x RUN-ARENA @ INSIDE {: f:str :}
   f str> FS:FILE? 0= if false exit then
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
   x RUN-ROOT @ pending 0 PLAN-PATH$ ar INSIDE str> FS:EXISTS? TFALSE
   TEST-DROPBOX:SEEN$ DOWNLOAD-COUNT DOWNLOADS$ T$=
   d x STEP-GONE ;

: FALLBACK$ ( -- ^u8 n ) s" fallback download" ;

PROCESS-SYMBOLS
FUNCTION: SOCKET-CALL socket ( n n n -- i32 ) ;FUNCTION
FUNCTION: BIND-CALL bind ( n ^u8 n -- i32 ) ;FUNCTION

1 constant AF-UNIX
1 constant SOCK-STREAM
\ Linux sockaddr_un: a u16 sun_family, then a 108-byte sun_path.
110 BUFFER: SOCKADDR
\ S_IFSOCK, the file type of a socket.
$C000 constant S-IFSOCK
\ Mode 0400, read-only to its owner.
$100 constant MODE-0400
\ LOCAL's slots, 0 to 3.
4 constant SLOTS

\ A socket bound at the path, as Rust's UnixListener::bind leaves one;
\ its descriptor.
: SOCKET-AT ( str -- fd )
   str> {: p:^ u:n :}
   u 108 < TTRUE
   AF-UNIX SOCKADDR c! 0 SOCKADDR 1 + c!
   p SOCKADDR 2 + u BYTE-COPY 0 SOCKADDR 2 + u + c!
   AF-UNIX SOCK-STREAM 0 SOCKET-CALL {: s:n :}
   s 0 >= TTRUE
   s SOCKADDR u 3 + BIND-CALL 0 T=
   s >FD ;

\ The run's slot k, as LOCAL names it.
: SLOT-AT ( ^run n -- str )
   {: x k:n :}
   x RUN-ARENA @ {: ar :}
   s" .omabox-download-slot-" k ar NUMBERED {: nm:str :}
   x RUN-STAGING @ nm str> ar INSIDE ;

: UNKNOWN$ ( n ^ARENA:arena -- str )
   {: k:n ar :}
   s" unknown-" k ar NUMBERED ;

\ Rust's unknown slots: a bound socket at slot 0, files holding
\ unknown-<k> at the others, slot 1 read-only; the socket.
: UNKNOWN-SLOTS ( ^run -- fd )
   {: x :}
   SLOTS 1 ?do
      x i SLOT-AT str> i x RUN-ARENA @ UNKNOWN$ str> FS:WRITE-ALL
   loop
   x 1 SLOT-AT str> MODE-0400 FS:CHMOD-MODE
   x 0 SLOT-AT SOCKET-AT ;

\ Slot 0 is still a socket, and the others hold their bytes.
: SLOTS-KEPT ( ^run -- )
   {: x :}
   x 0 SLOT-AT str> FS:TRY-LSTAT TTRUE
   FS:STAT-MODE@ FS:S-IFMT and S-IFSOCK T=
   SLOTS 1 ?do
      x i SLOT-AT i x RUN-ARENA @ UNKNOWN$ str> HOLDS-BYTES
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
   x REPLAY-STEP REPORTED COMPLETED 1 T=
   x RUN-ROOT @ s" fallback.txt" ar INSIDE FALLBACK$ HOLDS-BYTES
   x SLOTS-KEPT
   TEST-DROPBOX:SEEN$ 1 DOWNLOADS$ T$=
   TEST-DROPBOX:RANGE-SENT? TFALSE
   sock FS:CLOSE-DIR
   d x STEP-GONE ;

\ The root swap's paths: it runs on the fake's task.
TYPED-VARIABLE LIVE-ROOT str
TYPED-VARIABLE OLD-ROOT str
TYPED-VARIABLE CANARY str

: CANARY$ ( -- ^u8 n ) s" replacement bytes" ;
: SWAPPED$ ( -- ^u8 n ) s" descriptor-bound download" ;

\ Rust's swap: the root renamed old-root, and a new root holding
\ canary.txt.
: SWAP-ROOT ( -- )
   LIVE-ROOT @ str> OLD-ROOT @ str> FS:RENAME-FILE
   LIVE-ROOT @ str> FS:MAKE-DIR
   CANARY @ str> CANARY$ FS:WRITE-ALL ;

\ The swap's paths for the run x in the case directory d.
: SWAP-AT ( str ^run -- )
   {: d:str x :}
   x RUN-ARENA @ {: ar :}
   x RUN-ROOT @ LIVE-ROOT !
   d s" old-root" ar INSIDE OLD-ROOT !
   x RUN-ROOT @ s" canary.txt" ar INSIDE CANARY ! ;

: ROOT-CHANGED? ( replay-step -- bool )
   MATCH replay-step
      root-changed OF true ENDOF
      report OF drop false ENDOF
   ;MATCH ;

\ The new root holds canary.txt alone, with its bytes.
: REPLACEMENT-KEPT ( ^run -- )
   {: x :}
   x ROOT$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u s" canary.txt" T$=
   CANARY @ CANARY$ HOLDS-BYTES ;

\ Whether a name in the list starts with .omabox-download-.
: STAGE-LISTED? ( ^u8 n -- bool )
   {: l:^ u:n :}
   l u s" .omabox-download-" STARTS-WITH? if true exit then
   l u 10 INDEX-OF MATCH option
      none OF false ENDOF
      some OF IDX>N 1+ {: k:n :} l k + u k - RECURSE ENDOF
   ;MATCH ;

\ old-root holds no download.txt, and a download's stage.
: OLD-ROOT-STAGED ( ^ARENA:arena -- )
   {: ar :}
   OLD-ROOT @ s" download.txt" ar INSIDE str> FS:EXISTS? TFALSE
   OLD-ROOT @ str> READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u STAGE-LISTED? TTRUE ;

: NO-BASELINE? ( ^run ^u8 n -- bool )
   {: x p:^ u:n :}
   x RUN-JOURNAL @ p u DISPLAY x RUN-ARENA @ JOURNAL:BASELINE
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
   TEST-DROPBOX:SEEN$ 1 DOWNLOADS$ T$=
   d x STEP-GONE ;

public
EXPORT LOCAL:DOWNLOAD-CHECKPOINT-BYTES
private

TYPED-VARIABLE HASHING DROPBOX:hasher
variable REMAINING
$10000 constant XS-SIZE
XS-SIZE BUFFER: XS

: FILL-XS ( -- ) XS-SIZE 0 ?do $78 XS i + c! loop ;

: CHECKPOINT ( -- n ) DOWNLOAD-CHECKPOINT-BYTES ;

\ Rust's FailingBytes: "x" bytes until none remain, then a reset
\ connection.
: FAILING ( ^u8 n -- n )
   {: dst:^ cap:n :}
   REMAINING @ 0= if 104 FS:CAUSE! E-FS-IO throw then
   REMAINING @ cap min XS-SIZE min {: k:n :}
   XS dst k BYTE-COPY
   k negate REMAINING +!
   k ;

: READY-PARTIAL
   ( LOCAL:download-preparation -- ^LOCAL:download-partial )
   MATCH LOCAL:download-preparation
      ready OF ENDOF
      complete OF drop s" reconcile-test: no partial" FAILED ENDOF
      ephemeral OF s" reconcile-test: no partial" FAILED ENDOF
   ;MATCH ;

\ The lease's slot holding a durable checkpoint of CHECKPOINT "x"
\ bytes for target t, as a transfer lost just past it leaves it.
: CHECKPOINTED
   ( fd str ^u8 n DROPBOX:hash LOCAL:download-slot-lease ^ARENA:arena
     -- )
   {: root:fd r:str t:^ tu:n c:DROPBOX:hash
      l:LOCAL:download-slot-lease ar :}
   root r str> t tu c l ar LOCAL:PREPARE-DOWNLOAD-SLOT-AT READY-PARTIAL
   {: x :}
   CHECKPOINT 1+ REMAINING !
   [: x CHECKPOINT DROPBOX:BLOCK + [: FAILING ;] ar
      LOCAL:APPEND-PARTIAL drop ;]
   [: 2drop true ;] LOCAL:CONVERTING LOCAL:E-STAGE-READ T= ;

\ The content hash of CHECKPOINT "x" bytes, then t.
: PAST-HASH ( ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: t:^ tu:n ar :}
   HASHING DROPBOX:HASH-BEGIN
   CHECKPOINT XS-SIZE / 0 ?do XS XS-SIZE HASHING DROPBOX:HASH-FEED loop
   t tu HASHING DROPBOX:HASH-FEED
   HASHING DROPBOX:HASH-END ar COPIED DROPBOX:>HASH ;

\ The fake's /<p> at rev v, of content c: CHECKPOINT bytes it does not
\ keep, then t, so its download from the start answers 500.
: SERVES-PAST ( ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: p:^ pu:n v:^ vu:n t:^ tu:n c:DROPBOX:hash ar :}
   SB-RESET s" /" SB-APPEND p pu SB-APPEND SB$ ar COPIED {: l:str :}
   c DROPBOX:HASH>STR str> {: h:^ hu:n :}
   l str> l str> v vu h hu CHECKPOINT tu + TEST-DROPBOX:FILE!
   v vu CHECKPOINT t tu TEST-DROPBOX:CONTENT-TAIL! ;

: HELD$ ( -- ^u8 n ) s" first download held open by the fake server" ;
: NEXT$ ( -- ^u8 n ) s" download introduced by the next pass" ;

: UNPROTECTED ( LOCAL:binding -- bool ) drop false ;

: LEASED
   ( option<LOCAL:download-slot-lease> -- LOCAL:download-slot-lease )
   MATCH option
      none OF s" reconcile-test: no download slot leased" FAILED ENDOF
      some OF ENDOF
   ;MATCH ;

: GENERATION ( ^run -- n )
   {: x :}
   x RUN-JOURNAL @ x RUN-ARENA @ JOURNAL:LOCAL-ROOT-BINDING
   MATCH option
      none OF s" reconcile-test: the root is not bound" FAILED ENDOF
      some OF JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b gen:n :} gen ENDOF
   ;MATCH ;

\ The slot identity the step computes for plan p's download.
: STEP-IDENTITY
   ( ^run JOURNAL:plan-record -- LOCAL:download-slot-identity )
   {: x p :}
   x GENERATION {: gen:n :}
   p PENDING-DOWNLOAD MATCH option
      none OF s" reconcile-test: no download" FAILED ENDOF
      some OF {: d :} gen p PLAN-PATH d SLOT-IDENTITY ENDOF
   ;MATCH ;

\ Plan p's slot, leased as the step leases it, holding a checkpoint of
\ its content c.
: HELD-SLOT ( ^run JOURNAL:plan-record DROPBOX:hash -- )
   {: x p c:DROPBOX:hash :}
   x p STEP-IDENTITY {: id :}
   x STAGING$ id [: UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT LEASED
   {: l :}
   x ROOT$ s" open test root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root x RUN-ROOT @ s" a.bin" c l x RUN-ARENA @ CHECKPOINTED ;]
   [: root FS:CLOSE-DIR ;] finally ;

\ Holds plan p live, blocked until an hour from now.
: BLOCKED-AHEAD ( ^run JOURNAL:plan-record -- )
   {: x p :}
   x RUN-JOURNAL @ p ID-OF 503 MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE
   epoch-seconds JOURNAL:BLOCK-RETRY-SECONDS + x RUN-ARENA @
   JOURNAL:BLOCK-PLAN MATCH JOURNAL:plan-block
      not-found OF false ENDOF
      already-completed OF false ENDOF
      blocked OF true ENDOF
   ;MATCH TTRUE ;

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
   HELD$ ar PAST-HASH {: c:DROPBOX:hash :}
   s" a.bin" s" rev-held-slot" HELD$ c ar SERVES-PAST
   c s" rev-held-slot" >str DROPBOX:>REV MODEL-REMOTE:MAKE {: rem :}
   x s" a.bin" rem INSTALLING {: p :}
   x p BLOCKED-AHEAD
   x p c HELD-SLOT
   p c ;

\ The staging directory's one entry, the slot HELD-SLOT leased.
: HELD-SLOT-PATH ( ^run -- str )
   {: x :}
   x STAGING$ READ-BUF READ-CAP FS-LIST:NAMES {: u:n :}
   READ-BUF u ONE-NAME? TTRUE
   READ-BUF u s" .omabox-download-slot-" STARTS-WITH? TTRUE
   x RUN-STAGING @ READ-BUF u x RUN-ARENA @ INSIDE ;

: IN-ROOT ( ^run ^u8 n -- str )
   {: x p:^ u:n :}
   x RUN-ROOT @ p u x RUN-ARENA @ INSIDE ;

\ Plan b pending, and one step installing it, from the start.
: NEXT-STEPPED ( ^run -- )
   {: x :}
   x RUN-ARENA @ {: ar :}
   s" b.bin" s" rev-next-slot" NEXT$ ar SERVES
   NEXT$ s" rev-next-slot" ar REMOTE-FILE {: rem :}
   x s" b.bin" rem INSTALLING drop
   x STEPPED
   x s" b.bin" IN-ROOT NEXT$ HOLDS-BYTES
   TEST-DROPBOX:SEEN$ 1 DOWNLOADS$ T$=
   TEST-DROPBOX:RANGE-SENT? TFALSE ;

: RESUMED-RANGE ( -- )
   TEST-DROPBOX:RANGE-SENT? TTRUE
   SB-RESET s" bytes=" SB-APPEND CHECKPOINT FMT:SB-INT s" -" SB-APPEND
   SB$ TEST-DROPBOX:RANGE-SENT$ T$= ;

\ The file f holds content c, of size u.
: HOLDS-CONTENT ( str DROPBOX:hash n ^ARENA:arena -- )
   {: f:str c:DROPBOX:hash u:n ar :}
   f str> FS:FILE-SIZE u T=
   f str> FS:OPEN-SIZED TTRUE drop {: h:fd :}
   h ar LOCAL:DROPBOX-CONTENT-HASH h FS:CLOSE-DIR {: got:DROPBOX:hash :}
   got DROPBOX:HASH>STR str> c DROPBOX:HASH>STR str> T$= ;

\ Whether f is a file of u bytes.
: SIZED? ( str n -- bool )
   {: f:str u:n :}
   f str> FS:FILE? 0= if false exit then
   f str> FS:FILE-SIZE u = ;

\ Plan a unblocked, and a step resuming its download from its slot.
: HELD-STEPPED ( ^run JOURNAL:plan-record DROPBOX:hash -- )
   {: x p c:DROPBOX:hash :}
   x p UNBLOCKED
   x STEPPED
   x s" a.bin" IN-ROOT c CHECKPOINT HELD$ nip + x RUN-ARENA @
   HOLDS-CONTENT
   RESUMED-RANGE
   TEST-DROPBOX:SEEN$ 2 DOWNLOADS$ T$= ;

: LATER-PLANNED-DOWNLOAD-DOES-NOT-RECLAIM-AN-ACTIVE-SLOT
   ( ^ARENA:arena -- )
   {: ar :}
   s" later_planned_download_does_not_reclaim_an_active_slot" T-LABEL
   TEST-DROPBOX:RESET FILL-XS
   ar STEP-RUN {: d:str x :}
   x HELD-PLAN {: p c:DROPBOX:hash :}
   x HELD-SLOT-PATH {: slot:str :}
   x NEXT-STEPPED
   x s" a.bin" IN-ROOT str> FS:EXISTS? TFALSE
   slot CHECKPOINT SIZED? TTRUE
   x p c HELD-STEPPED
   d x STEP-GONE ;

: STEP-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar WORKER-VERIFICATION-MISMATCH-DURABLY-BLOCKS-ITS-PLAN
   ar WORKER-AUTH-RATE-LIMIT-AND-SERVER-FAILURES-REMAIN-GLOBAL
   ar OCCUPIED-DOWNLOAD-STAGE-IS-DURABLY-BLOCKED-WITHOUT-OVERWRITE-OR-REQUEST
   ar COMPLETED-DOWNLOAD-BATCH-IS-INSTALLED-BEFORE-THE-NEXT-BATCH-FAILS
   ar UNKNOWN-DOWNLOAD-SLOTS-ARE-PRESERVED-WITH-DISPOSABLE-FALLBACK
   ar ROOT-SWAP-AFTER-REPLAY-VALIDATION-NEVER-TOUCHES-THE-REPLACEMENT
   ar LATER-PLANNED-DOWNLOAD-DOES-NOT-RECLAIM-AN-ACTIVE-SLOT ;

: SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   ar OPENED MAIN !
   ACCOUNTED
   [: ar REFRESH-CASES ar STEP-CASES ;] [: MAIN @ DROPBOX:CLOSE ;]
   finally ;


\ The refresh cases against one fake Dropbox, under curl's loop.
: DROPBOX-SERVED ( ^ARENA:arena -- )
   {: ar :}
   AIO:START CURL:LOOP-START CURL-READY
   [: TEST-DROPBOX:START
      [: ar SERVED ;] [: TEST-DROPBOX:STOP ;] finally ;]
   [: CURL:LOOP-STOP AIO:STOP ;] finally ;

: LISTING-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar FOLDERS-ARE-DIRECTORIES-AND-NON-DOWNLOADABLE-FILES-ARE-UNKNOWN
   ar DIRECTORY-RECORDS-NORMALIZE-INCONSISTENT-CHILD-ANCESTOR-CASING
   ar DELTA-NEVER-RESPELLS-A-DIRECTORY-THAT-STILL-EXISTS
   ar LISTING-REJECTS-MISMATCHED-CANONICAL-AND-DISPLAY-PATHS
   ar LISTING-REJECTS-AN-INVALID-CONFIGURED-ROOT
   ar LISTING-REJECTS-AN-ENTRY-WITHOUT-PATHS
   ar LISTING-REJECTS-A-PATH-THAT-IS-NOT-UTF-8
   ar LISTING-CLASSIFIES-THE-REMOTE-ROOTS-OWN-ENTRY
   ar DROPBOX-SERVED ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar ABSENT-PATHS-ARE-SPELLED-WITH-LOCAL-ANCESTOR-CASING
   ar LOCAL-CASE-VARIANTS-NEVER-COLLAPSE-INTO-ONE-OBSERVATION
   ar KNOWN-PATH-MERGE-MATCHES-SET-UNION
   ar REMAINING-OPERATION-COMPARISON-IGNORES-A-COMPLETED-PREFIX
   ar PENDING-ONLY-PATHS-ARE-VISITED-AS-ABSENT-WITHOUT-CREATING-A-BASELINE
   ar LOCAL-MAP-KEEPS-ONE-UNSUPPORTED-SPELLING
   ar A-PATH-BELOW-AN-UNKNOWN-DIRECTORY-INHERITS-ITS-REASON
   ar A-RECORD-BELOW-AN-UNKNOWN-DIRECTORY-CANNOT-RESTORE-ABSENCE
   ar NAMES-THAT-NEIGHBOR-THE-SEPARATOR-ARE-NOT-ANCESTORS
   ar AN-UNKNOWN-ANCESTOR-BLOCKS-A-DELETION-ON-EITHER-SIDE
   ar BASELINE-ONLY-PATHS-ARE-INCLUDED-IN-CONFIRMED-ABSENCE
   ar REMOTE-SUBTREE-HOLDS-ONLY-TRUE-DESCENDANTS
   ar CHILD-PREFIX-ORDER-MATCHES-THE-MATERIALIZED-PREFIX
   ar PATH-DECISIONS-ORDER-DELETES-LAST-AND-DEEPEST-FIRST
   ar CASE-COLLISION-CASES
   ar LISTING-CASES ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" reconcile-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
