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
require src/dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f
require src/local.f
require src/planner.f
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

: LISTING-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar FOLDERS-ARE-DIRECTORIES-AND-NON-DOWNLOADABLE-FILES-ARE-UNKNOWN
   ar DIRECTORY-RECORDS-NORMALIZE-INCONSISTENT-CHILD-ANCESTOR-CASING
   ar DELTA-NEVER-RESPELLS-A-DIRECTORY-THAT-STILL-EXISTS
   ar LISTING-REJECTS-MISMATCHED-CANONICAL-AND-DISPLAY-PATHS
   ar LISTING-REJECTS-AN-INVALID-CONFIGURED-ROOT
   ar LISTING-REJECTS-AN-ENTRY-WITHOUT-PATHS
   ar LISTING-REJECTS-A-PATH-THAT-IS-NOT-UTF-8
   ar LISTING-CLASSIFIES-THE-REMOTE-ROOTS-OWN-ENTRY ;


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
