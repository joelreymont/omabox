\ reconcile-test.f - RECONCILE's words, each case in a directory of its
\ own under TMPDIR, which it removes.
\ Known paths, Rust's tests of the same names:
\ - absent_paths_are_spelled_with_local_ancestor_casing
\ - local_case_variants_never_collapse_into_one_observation, over
\   sampled names, the collision logged once naming both spellings
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
require src/model.f
require src/journal.f
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

: PATH$ ( MODEL:path -- ^u8 n ) MODEL:PATH>STR str> ;

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
   t tu upper str> lower str> COLLISION$ CONTAINS? TTRUE ;

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
   ar PATH-DECISIONS-ORDER-DELETES-LAST-AND-DEEPEST-FIRST ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" reconcile-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
