\ reconcile.f - package RECONCILE: one sync pass (rust src/reconcile.rs):
\ list Dropbox, scan the root, plan each path, replay the pending plans
\ and run their downloads, one at a time. A journal answer the pass
\ refuses is logged once with the Rust version's text, naming the path,
\ then thrown as E-INVALID-STATE.
\ A listing's entries become inventory changes, numbered in order. The
\ last delete over a key is the largest number among the deletes at it
\ or an ancestor, a binary search per prefix, and a key's record or
\ directory spelling comes from its writes numbered after that delete:
\ no change is replayed against the whole inventory.
\ STORAGE CLASS. No state of its own. CALLER-OWNED: every value a pass
\ reads or makes lies in the arena the caller passes.

require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/vector.f
require src/lib/sort.f
require src/lib/utf8-scalar.f
require src/lib/unicode.f
require src/lib/fmt.f
require src/lib/fs-anchored.f
require src/model.f
require src/planner.f
require src/journal.f
require src/local.f
require src/dropbox.f
require src/replay.f

package RECONCILE
public

-100800 constant E-FIRST
-100899 constant E-LAST
-100800 s" journaled reconciliation state is invalid"
   ERROR:CODE E-INVALID-STATE
-100801 s" two local paths have one Dropbox path identity"
   ERROR:CODE E-CASE-COLLISION
-100802 s" Dropbox's listing does not fit the configured root"
   ERROR:CODE E-LISTING

private

\ ---- failures ------------------------------------------------------

: INVALID ( MODEL:path ^u8 n -- )
   {: path detail:^ du:n :}
   LOG:ERROR s" reconcile" LOG:LINE
   s" reconciliation found invalid journal state for `" LOG:TEXT+
   path MODEL:PATH>STR str> LOG:TEXT+ s" `: " LOG:TEXT+
   detail du LOG:TEXT+ LOG:;LINE
   E-INVALID-STATE throw ;


\ ---- known paths ---------------------------------------------------

$2F constant SEPARATOR
$2E constant PERIOD

: PENDING? ( JOURNAL:record-status -- bool )
   MATCH JOURNAL:record-status
      pending OF true ENDOF
      completed OF false ENDOF
   ;MATCH ;

\ The count of want matched so far, one more when planned is pending
\ and is want's next, or -1 once one is not.
: MATCHED
   ( n JOURNAL:planned-operation ^VEC:vector<MODEL:operation> -- n )
   {: k:n planned want :}
   planned JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :}
   k 0 < if k exit then
   s PENDING? 0= if k exit then
   k want VEC:COUNT >= if -1 exit then
   o want k VEC:AT @ MODEL:OPERATION= if k 1+ exit then
   -1 ;

\ The pending plan's operations not yet completed are the fresh plan's.
: REMAINING-OPERATIONS-MATCH?
   ( JOURNAL:plan-record JOURNAL:operation-plan -- bool )
   {: pending fresh :}
   fresh JOURNAL-OPERATION--PLAN:UNMAKE {: want :}
   pending JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   0 ops VEC:COUNT 0 ?do ops i VEC:AT @ want MATCHED loop
   want VEC:COUNT = ;

\ A path's decision as a pass orders it before recording it.
STRUCTURE path-decision
   FIELD key MODEL:key
   FIELD path MODEL:path
   FIELD baseline-matches-noop bool
   FIELD decision MODEL:decision
;STRUCTURE

: DELETES-LOCAL-DIRECTORY? ( MODEL:operation -- bool )
   MATCH MODEL:operation
      create-local-directory OF false ENDOF
      create-remote-directory OF false ENDOF
      delete-local-directory OF true ENDOF
      delete-remote-directory OF false ENDOF
      create-remote OF drop false ENDOF
      install-local OF drop false ENDOF
      preserve-local OF drop false ENDOF
      replace-local OF drop drop false ENDOF
      delete-local OF drop false ENDOF
      preserve-remote OF drop false ENDOF
      replace-remote OF drop drop false ENDOF
      delete-remote OF drop false ENDOF
   ;MATCH ;

: LOCAL-DIRECTORY-DELETE? ( MODEL:decision -- bool )
   MATCH MODEL:decision
      noop OF drop false ENDOF
      operate OF DELETES-LOCAL-DIRECTORY? ENDOF
      blocked OF drop false ENDOF
      conflicted OF drop false ENDOF
      collided OF drop false ENDOF
   ;MATCH ;

\ A path's leading root or ".", which Path::iter yields first.
: LEAD ( ^u8 n -- n )
   {: p:^ u:n :}
   u 0= if 0 exit then
   p c@ SEPARATOR = if 1 exit then
   p c@ PERIOD <> if 0 exit then
   u 1 = if 1 exit then
   p 1+ c@ SEPARATOR = if 1 exit then
   0 ;

\ A name Path::iter yields: neither empty nor ".".
: NAME? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 1 = if p c@ PERIOD <> exit then
   u 0 > ;

\ Runs q on the name from at, when NAME? accepts it; the index after
\ it, or -1 past the last.
: NEXT-NAME ( n ^u8 n n [ n ^u8 n -- n ] -- n n )
   {: acc:n p:^ u:n at:n q :}
   p u SEPARATOR at SPLIT-NEXT 0= if 2drop drop acc -1 exit then
   {: s:^ su:n next:n :}
   s su NAME? if acc s su q execute next exit then
   acc next ;

\ Runs q on each of Path::iter's components of the bytes, a slice of
\ them, threading n.
: EACH-COMPONENT ( n ^u8 n [ n ^u8 n -- n ] -- n )
   {: p:^ u:n q :}
   p u LEAD {: lead:n :}
   lead 0 > if p lead q execute then
   lead begin p u rot q NEXT-NAME dup 0< until drop ;

: COMPONENTS ( str ^ARENA:arena -- ^VEC:vector<str> )
   {: s:str ar :}
   ar ARENA:ALLOCATOR 0 [type] str VEC:NEW {: v :}
   0 s str> [: >str v VEC:PUSH ! ;] EACH-COMPONENT drop
   v ;

: PATH-DEPTH ( MODEL:path -- n )
   0 swap MODEL:PATH>STR str> [: 2drop 1+ ;] EACH-COMPONENT ;

\ Rust's Ordering of two cells: -1, 0 or 1.
: CMP ( n n -- n )
   {: x:n y:n :}
   x y < if -1 exit then
   x y > if 1 exit then
   0 ;

: DECISION-PARTS ( path-decision -- MODEL:key n bool )
   PATH-DECISION-UNMAKE {: k path same d :}
   k path PATH-DEPTH d LOCAL-DIRECTORY-DELETE? ;

: ORDER-PATH-DECISIONS ( path-decision path-decision -- n )
   {: a b :}
   a DECISION-PARTS {: ak ad:n adel:bool :}
   b DECISION-PARTS {: bk bd:n bdel:bool :}
   adel bdel and if bd ad CMP else
      adel if 1 exit then
      bdel if -1 exit then
      ad bd CMP
   then
   dup 0<> if exit then
   drop ak bk MODEL:KEY-CMP ;

\ A scan record and its key.
STRUCTURE local-entry
   FIELD key MODEL:key
   FIELD record MODEL:local-record
;STRUCTURE

\ A pending plan and its path's key.
STRUCTURE pending-plan
   FIELD key MODEL:key
   FIELD plan JOURNAL:plan-record
;STRUCTURE

: ENTRY-KEY ( local-entry -- MODEL:key )
   LOCAL-ENTRY-UNMAKE {: k r :} k ;

: ENTRY-RECORD ( local-entry -- MODEL:local-record )
   LOCAL-ENTRY-UNMAKE {: k r :} r ;

: RECORD-PATH ( MODEL:local-record -- MODEL:path )
   MODEL-LOCAL--RECORD:UNMAKE {: p o :} p ;

: ENTRY-OBSERVATION ( local-entry -- MODEL:observation<MODEL:local> )
   ENTRY-RECORD MODEL-LOCAL--RECORD:UNMAKE {: p o :} o ;

: REMOTE-KEY ( MODEL:remote-record -- MODEL:key )
   MODEL-REMOTE--RECORD:UNMAKE {: k p o :} k ;

: REMOTE-OBSERVATION
   ( MODEL:remote-record -- MODEL:observation<MODEL:remote> )
   MODEL-REMOTE--RECORD:UNMAKE {: k p o :} o ;

: BASELINE-KEY ( MODEL:baseline-record -- MODEL:key )
   MODEL-BASELINE--RECORD:UNMAKE {: k p b :} k ;

: PENDING-KEY ( pending-plan -- MODEL:key )
   PENDING-PLAN-UNMAKE {: k p :} k ;

: KEY-BYTES ( MODEL:key -- ^u8 n ) MODEL:KEY>STR str> ;

\ The indices 0 to n-1 in the order less gives.
: ORDER ( n [ n n -- bool ] ^ARENA:arena -- ^VEC:vector<n> )
   {: k:n less ar :}
   ar ARENA:ALLOCATOR k [type] n VEC:NEW {: v :}
   k 0 ?do i v i VEC:AT ! loop
   k 1 > if v 0 VEC:AT k less SORT:SORT! then
   v ;

\ Rust's sort_by is stable: equal items keep their order.
: STABLE< ( n n n -- bool )
   {: x:n y:n c:n :}
   c 0<> if c 0 < exit then
   x y < ;

\ The indices 0 to n-1 in the order cmp gives.
: STABLE-ORDER ( n [ n n -- n ] ^ARENA:arena -- ^VEC:vector<n> )
   {: k:n cmp ar :}
   k [: 2dup cmp execute STABLE< ;] ar ORDER ;

\ Entry x against y by key, then path.
: ENTRY-CMP ( n n ^VEC:vector<local-entry> -- n )
   {: x:n y:n v :}
   v x VEC:AT @ LOCAL-ENTRY-UNMAKE {: k r :}
   v y VEC:AT @ LOCAL-ENTRY-UNMAKE {: k2 r2 :}
   k k2 MODEL:KEY-CMP {: c:n :}
   c 0<> if c exit then
   r RECORD-PATH r2 RECORD-PATH MODEL:PATH-CMP ;

: KEY-INTO
   ( MODEL:local-record ^VEC:vector<local-entry> ^ARENA:arena -- )
   {: r v ar :}
   r RECORD-PATH {: p :}
   p MODEL:EXCLUDED? if exit then
   p ar MODEL:FOLD r LOCAL-ENTRY-MAKE v VEC:PUSH ! ;

\ The scan's records but excluded ones, each with its key.
: KEYED
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- ^VEC:vector<local-entry> )
   {: records ar :}
   ar ARENA:ALLOCATOR 0 [type] local-entry VEC:NEW {: v :}
   records VEC:COUNT 0 ?do records i VEC:AT @ v ar KEY-INTO loop
   v ;

: ENTRIES-IN
   ( ^VEC:vector<local-entry> ^VEC:vector<n> ^ARENA:arena
     -- ^VEC:vector<local-entry> )
   {: v idx ar :}
   ar ARENA:ALLOCATOR 0 [type] local-entry VEC:NEW {: out :}
   idx VEC:COUNT 0 ?do
      v idx i VEC:AT @ VEC:AT @ out VEC:PUSH !
   loop
   out ;

\ The index after the run of entries from i that share its key.
: RUN-END ( ^VEC:vector<local-entry> n -- n )
   {: v from:n :}
   v from VEC:AT @ ENTRY-KEY {: k :}
   from 1+ begin dup v VEC:COUNT < while
      v over VEC:AT @ ENTRY-KEY k MODEL:KEY= 0= if exit then
      1+
   repeat ;

: UNSUPPORTED-REASON? ( MODEL:unknown-reason -- bool )
   MATCH MODEL:unknown-reason
      incomplete OF false ENDOF
      inaccessible OF false ENDOF
      unavailable OF false ENDOF
      stale OF false ENDOF
      cursor-reset OF false ENDOF
      unsupported OF true ENDOF
   ;MATCH ;

: UNSUPPORTED? ( local-entry -- bool )
   ENTRY-OBSERVATION
   MATCH MODEL:observation
      present OF drop false ENDOF
      directory OF false ENDOF
      absent OF false ENDOF
      unknown OF UNSUPPORTED-REASON? ENDOF
   ;MATCH ;

: UNSUPPORTED-ONLY? ( ^VEC:vector<local-entry> n n -- bool )
   {: v from:n end:n :}
   true end from ?do v i VEC:AT @ UNSUPPORTED? and loop ;

: SPELLING ( ^VEC:vector<local-entry> n -- ^u8 n )
   VEC:AT @ ENTRY-RECORD RECORD-PATH MODEL:PATH>STR str> ;

\ Logs Rust's LocalCaseCollision text for the run's first two
\ spellings, then throws E-CASE-COLLISION.
: COLLISION ( ^VEC:vector<local-entry> n -- )
   {: v from:n :}
   LOG:ERROR s" reconcile" LOG:LINE
   s" local paths `" LOG:TEXT+ v from SPELLING LOG:TEXT+
   s" ` and `" LOG:TEXT+ v from 1+ SPELLING LOG:TEXT+
   s" ` have the same Dropbox path identity" LOG:TEXT+ LOG:;LINE
   E-CASE-COLLISION throw ;

\ Keeps a run's first entry; a run of more, unless all unsupported,
\ is a collision.
: KEEP-RUN
   ( n n ^VEC:vector<local-entry> ^VEC:vector<local-entry> -- n )
   {: from:n end:n v out :}
   end from - 1 > if
      v from end UNSUPPORTED-ONLY? 0= if v from COLLISION then
   then
   v from VEC:AT @ out VEC:PUSH !
   end ;

\ The scan's records but excluded ones, keyed and sorted by key, then
\ path. A run of unsupported spellings of one key cannot be renamed
\ apart and infers nothing, so its least spelling stands for them.
: LOCAL-MAP
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- ^VEC:vector<local-entry> )
   {: records ar :}
   records ar KEYED {: v :}
   v VEC:COUNT [: v ENTRY-CMP ;] ar STABLE-ORDER {: idx :}
   v idx ar ENTRIES-IN {: sorted :}
   ar ARENA:ALLOCATOR 0 [type] local-entry VEC:NEW {: out :}
   0 begin dup sorted VEC:COUNT < while
      dup sorted over RUN-END sorted out KEEP-RUN nip
   repeat drop
   out ;

\ Rust's observed_unknown, one word for each side's observation.
: LOCAL-OBSERVED-UNKNOWN
   ( MODEL:observation<MODEL:local> -- option<MODEL:unknown-reason> )
   MATCH MODEL:observation
      present OF drop OPTION:NONE ENDOF
      directory OF OPTION:NONE ENDOF
      absent OF OPTION:NONE ENDOF
      unknown OF OPTION:SOME ENDOF
   ;MATCH ;

: REMOTE-OBSERVED-UNKNOWN
   ( MODEL:observation<MODEL:remote> -- option<MODEL:unknown-reason> )
   MATCH MODEL:observation
      present OF drop OPTION:NONE ENDOF
      directory OF OPTION:NONE ENDOF
      absent OF OPTION:NONE ENDOF
      unknown OF OPTION:SOME ENDOF
   ;MATCH ;

\ Rust's unobserved, one word for each side: a path one side holds no
\ record for proves absence only when no ancestor was observed
\ unknown; beneath one it inherits the reason.
: UNOBSERVED-LOCAL
   ( option<MODEL:unknown-reason> -- MODEL:observation<MODEL:local> )
   MATCH option
      none OF MODEL-OBSERVATION:ABSENT ENDOF
      some OF MODEL-OBSERVATION:UNKNOWN ENDOF
   ;MATCH ;

: UNOBSERVED-REMOTE
   ( option<MODEL:unknown-reason> -- MODEL:observation<MODEL:remote> )
   MATCH option
      none OF MODEL-OBSERVATION:ABSENT ENDOF
      some OF MODEL-OBSERVATION:UNKNOWN ENDOF
   ;MATCH ;

\ The index of the last separator in the bytes.
: LAST-SEPARATOR ( ^u8 n -- option<n> )
   {: p:^ u:n :}
   u begin dup 0 > while
      1- dup p + c@ SEPARATOR = if OPTION:SOME exit then
   repeat
   drop OPTION:NONE ;

\ Rust's parent_bytes: the bytes before the last separator.
: PARENT-BYTES ( str -- option<str> )
   str> {: p:^ u:n :}
   p u LAST-SEPARATOR MATCH option
      none OF OPTION:NONE ENDOF
      some OF p swap >str OPTION:SOME ENDOF
   ;MATCH ;

\ The index of the record of n, sorted by key, that key reads as
\ these bytes, or n when none does.
: FIND-BYTES ( ^u8 n n [ n -- MODEL:key ] -- n )
   {: p:^ u:n count:n key :}
   0 count [: key execute KEY-BYTES p u STR< ;]
   SORT:PARTITION-POINT {: at:n :}
   at count >= if count exit then
   at key execute KEY-BYTES p u STR= if at exit then
   count ;

\ The reason of the record at these bytes, if it is unknown.
: REASON-AT
   ( ^u8 n n [ n -- MODEL:key ]
     [ n -- option<MODEL:unknown-reason> ]
     -- option<MODEL:unknown-reason> )
   {: p:^ u:n count:n key reason :}
   p u count key FIND-BYTES {: at:n :}
   at count = if OPTION:NONE exit then
   at reason execute ;

\ For ANCESTOR-UNKNOWN: the reason at the ancestor or the next one up.
: CLIMB
   ( option<str> n [ n -- MODEL:key ]
     [ n -- option<MODEL:unknown-reason> ]
     -- option<MODEL:unknown-reason> )
   {: ancestor count:n key reason :}
   ancestor MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: s:str :}
         s str> count key reason REASON-AT
         MATCH option
            none OF s PARENT-BYTES count key reason RECURSE ENDOF
            some OF OPTION:SOME ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ The reason any ancestor of the key was recorded unknown with, among
\ n records sorted by key that key and reason read by index. The climb
\ goes to the root: a record below an unknown directory cannot turn
\ the rest of it back into confirmed absence.
: ANCESTOR-UNKNOWN
   ( n MODEL:key [ n -- MODEL:key ]
     [ n -- option<MODEL:unknown-reason> ]
     -- option<MODEL:unknown-reason> )
   {: count:n k key reason :}
   k MODEL:KEY>STR PARENT-BYTES count key reason CLIMB ;

: LOCAL-UNOBSERVED
   ( ^VEC:vector<local-entry> MODEL:key
     -- MODEL:observation<MODEL:local> )
   {: v k :}
   v VEC:COUNT k [: v swap VEC:AT @ ENTRY-KEY ;]
   [: v swap VEC:AT @ ENTRY-OBSERVATION LOCAL-OBSERVED-UNKNOWN ;]
   ANCESTOR-UNKNOWN UNOBSERVED-LOCAL ;

: REMOTE-UNOBSERVED
   ( ^VEC:vector<MODEL:remote-record> MODEL:key
     -- MODEL:observation<MODEL:remote> )
   {: v k :}
   v VEC:COUNT k [: v swap VEC:AT @ REMOTE-KEY ;]
   [: v swap VEC:AT @ REMOTE-OBSERVATION REMOTE-OBSERVED-UNKNOWN ;]
   ANCESTOR-UNKNOWN UNOBSERVED-REMOTE ;

\ The index of the local entry at these bytes, or the count.
: LOCAL-INDEX ( ^VEC:vector<local-entry> ^u8 n -- n )
   {: v p:^ u:n :}
   p u v VEC:COUNT [: v swap VEC:AT @ ENTRY-KEY ;] FIND-BYTES ;

: FIND-LOCAL
   ( ^VEC:vector<local-entry> MODEL:key
     -- option<MODEL:local-record> )
   {: v k :}
   v k KEY-BYTES LOCAL-INDEX {: at:n :}
   at v VEC:COUNT = if OPTION:NONE exit then
   v at VEC:AT @ ENTRY-RECORD OPTION:SOME ;

: FIND-REMOTE
   ( ^VEC:vector<MODEL:remote-record> MODEL:key
     -- option<MODEL:remote-record> )
   {: v k :}
   k KEY-BYTES v VEC:COUNT [: v swap VEC:AT @ REMOTE-KEY ;] FIND-BYTES
   {: at:n :}
   at v VEC:COUNT = if OPTION:NONE exit then
   v at VEC:AT @ OPTION:SOME ;

\ Rust's Path::file_name: the last component, unless a root, "." or
\ "..".
: FILE-NAME ( MODEL:path ^ARENA:arena -- option<str> )
   {: path ar :}
   path MODEL:PATH>STR ar COMPONENTS {: parts :}
   parts VEC:COUNT 0= if OPTION:NONE exit then
   parts parts VEC:COUNT 1- VEC:AT @ {: last:str :}
   last str> {: p:^ u:n :}
   p u s" /" STR= p u s" ." STR= or p u s" .." STR= or
   if OPTION:NONE exit then
   last OPTION:SOME ;

\ The component at idx: an ancestor's spelling from the local entry at
\ the key's bytes up to it, else the candidate's.
: SPELLED
   ( ^VEC:vector<local-entry> MODEL:key ^VEC:vector<str>
     ^VEC:vector<str> n ^ARENA:arena -- str )
   {: v k canon shown at:n ar :}
   shown at VEC:AT @ {: own:str :}
   at 1+ canon VEC:COUNT = if own exit then
   k KEY-BYTES drop {: base:^ :}
   canon at VEC:AT @ str> + base - {: end:n :}
   v base end LOCAL-INDEX {: found:n :}
   found v VEC:COUNT = if own exit then
   v found VEC:AT @ ENTRY-RECORD RECORD-PATH ar FILE-NAME
   MATCH option
      none OF own ENDOF
      some OF ENDOF
   ;MATCH ;

\ PathBuf::push puts a separator after a part but a root.
: SEPARATED? ( str -- bool ) str> s" /" STR= 0= ;

: JOINED-SIZE ( ^VEC:vector<str> -- n )
   {: parts :}
   0 parts VEC:COUNT 0 ?do
      parts i VEC:AT @ str> nip +
      i 0 > if parts i 1- VEC:AT @ SEPARATED? if 1+ then then
   loop ;

: APPEND-PART ( n ^VEC:vector<str> n ^u8 -- n )
   {: len:n parts at:n dst:^ :}
   len at 0 > if
      parts at 1- VEC:AT @ SEPARATED? if
         SEPARATOR dst len + c! 1+
      then
   then
   {: from:n :}
   parts at VEC:AT @ str> {: p:^ u:n :}
   p dst from + u BYTE-COPY
   from u + ;

\ PathBuf::push of every part in turn.
: JOINED ( ^VEC:vector<str> ^ARENA:arena -- str )
   {: parts ar :}
   parts JOINED-SIZE {: size:n :}
   size 0= if s" " >str exit then
   ar size ARENA:ALLOC drop {: dst:^ :}
   0 parts VEC:COUNT 0 ?do parts i dst APPEND-PART loop drop
   dst size >str ;

\ Spells a path the scan did not observe with the local spelling of
\ each ancestor it did, so an effect there joins the directories the
\ filesystem holds instead of building a sibling tree in other case;
\ the last component keeps the candidate's spelling.
: SPELL-WITH-LOCAL-ANCESTORS
   ( ^VEC:vector<local-entry> MODEL:key MODEL:path ^ARENA:arena
     -- MODEL:path )
   {: v k candidate ar :}
   k MODEL:KEY>STR ar COMPONENTS {: canon :}
   candidate MODEL:PATH>STR ar COMPONENTS {: shown :}
   canon VEC:COUNT shown VEC:COUNT <> if candidate exit then
   ar ARENA:ALLOCATOR 0 [type] str VEC:NEW {: parts :}
   canon VEC:COUNT 0 ?do
      v k canon shown i ar SPELLED parts VEC:PUSH !
   loop
   parts ar JOINED MODEL:>PATH ;

\ Remote record x against y by key.
: REMOTE-CMP ( n n ^VEC:vector<MODEL:remote-record> -- n )
   {: x:n y:n v :}
   v x VEC:AT @ REMOTE-KEY v y VEC:AT @ REMOTE-KEY MODEL:KEY-CMP ;

: REMOTE-MAP
   ( ^VEC:vector<MODEL:remote-record> ^ARENA:arena
     -- ^VEC:vector<MODEL:remote-record> )
   {: v ar :}
   v VEC:COUNT [: v REMOTE-CMP ;] ar STABLE-ORDER {: idx :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: out :}
   idx VEC:COUNT 0 ?do
      v idx i VEC:AT @ VEC:AT @ out VEC:PUSH !
   loop
   out ;

\ The bytes sort before every path beneath parent, before parent then
\ "/", decided without building that prefix.
: PRECEDES-CHILDREN? ( ^u8 n ^u8 n -- bool )
   {: b:^ u:n p:^ v:n :}
   u v >= if
      b v p v STR= if
         u v = if true exit then
         b v + c@ SEPARATOR < exit
      then
   then
   b u p v STR< ;

\ Whether the inventory, sorted by key, holds a path beneath the key:
\ the first record at or past the key then "/" decides, as a sibling
\ such as the key then ".txt" sorts between the key and its children.
: REMOTE-SUBTREE
   ( ^VEC:vector<MODEL:remote-record> MODEL:key -- MODEL:subtree )
   {: v k :}
   k KEY-BYTES {: p:^ u:n :}
   0 v VEC:COUNT
   [: v swap VEC:AT @ REMOTE-KEY KEY-BYTES p u PRECEDES-CHILDREN? ;]
   SORT:PARTITION-POINT {: first:n :}
   first v VEC:COUNT < if
      v first VEC:AT @ REMOTE-KEY k MODEL:BENEATH? if
         MODEL-SUBTREE:OCCUPIED exit
      then
   then
   MODEL-SUBTREE:EMPTY ;

\ Every side for FOR-EACH-KNOWN-PATH, each sorted by key.
STRUCTURE sides
   FIELD baselines ^VEC:vector<MODEL:baseline-record>
   FIELD local ^VEC:vector<local-entry>
   FIELD remote ^VEC:vector<MODEL:remote-record>
   FIELD pending ^VEC:vector<pending-plan>
;STRUCTURE

\ How far FOR-EACH-KNOWN-PATH is through each side.
STRUCTURE cursor
   FIELD baseline n
   FIELD local n
   FIELD remote n
   FIELD pending n
;STRUCTURE

\ The key q reads at idx, if idx is below the count.
: KEY-AT ( n n [ n -- MODEL:key ] -- option<MODEL:key> )
   {: count:n at:n q :}
   at count >= if OPTION:NONE exit then
   at q execute OPTION:SOME ;

\ The key q reads at idx, below the count, is this one.
: HERE? ( n n MODEL:key [ n -- MODEL:key ] -- bool )
   {: count:n at:n k q :}
   at count >= if false exit then
   at q execute k MODEL:KEY= ;

\ The lesser of two keys a side may hold, by bytes.
: LEAST ( option<MODEL:key> option<MODEL:key> -- option<MODEL:key> )
   {: a b :}
   a MATCH option
      none OF b ENDOF
      some OF {: x :}
         b MATCH option
            none OF x OPTION:SOME ENDOF
            some OF {: y :}
               x y MODEL:KEY-CMP 0 > if y else x then OPTION:SOME
            ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ A baseline at a key leads when no other side holds a lesser one.
: LEADS? ( option<MODEL:key> option<MODEL:key> -- bool )
   {: base least :}
   base MATCH option
      none OF false ENDOF
      some OF {: x :}
         least MATCH option
            none OF true ENDOF
            some OF x swap MODEL:KEY-CMP 0 <= ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

: SIDE-LEAST ( sides cursor -- option<MODEL:key> )
   {: s c :}
   s SIDES-UNMAKE {: bs ls rs ps :}
   c CURSOR-UNMAKE {: b:n l:n r:n p:n :}
   ls VEC:COUNT l [: ls swap VEC:AT @ ENTRY-KEY ;] KEY-AT
   rs VEC:COUNT r [: rs swap VEC:AT @ REMOTE-KEY ;] KEY-AT LEAST
   ps VEC:COUNT p [: ps swap VEC:AT @ PENDING-KEY ;] KEY-AT LEAST ;

: TURN-BASELINE
   ( bool ^VEC:vector<MODEL:baseline-record> n
     -- option<JOURNAL:path-baseline> )
   {: leads bs b:n :}
   leads 0= if OPTION:NONE exit then
   bs b VEC:AT @ MODEL-BASELINE--RECORD:UNMAKE {: k path base :}
   path base JOURNAL-PATH--BASELINE:MAKE OPTION:SOME ;

: TURN-LOCAL
   ( bool ^VEC:vector<local-entry> n -- option<MODEL:local-record> )
   {: here ls l:n :}
   here 0= if OPTION:NONE exit then
   ls l VEC:AT @ ENTRY-RECORD OPTION:SOME ;

: TURN-REMOTE
   ( bool ^VEC:vector<MODEL:remote-record> n
     -- option<MODEL:remote-record> )
   {: here rs r:n :}
   here 0= if OPTION:NONE exit then
   rs r VEC:AT @ OPTION:SOME ;

: ADVANCE ( n bool -- n ) if 1+ then ;

\ Visits the key with what each side holds there; the cursor past it.
: VISIT
   ( sides cursor bool MODEL:key
     [ MODEL:key option<JOURNAL:path-baseline>
       option<MODEL:local-record> option<MODEL:remote-record> -- ]
     -- cursor )
   {: s c leads k visit :}
   s SIDES-UNMAKE {: bs ls rs ps :}
   c CURSOR-UNMAKE {: b:n l:n r:n p:n :}
   ls VEC:COUNT l k [: ls swap VEC:AT @ ENTRY-KEY ;] HERE?
   {: lh:bool :}
   rs VEC:COUNT r k [: rs swap VEC:AT @ REMOTE-KEY ;] HERE?
   {: rh:bool :}
   ps VEC:COUNT p k [: ps swap VEC:AT @ PENDING-KEY ;] HERE?
   {: ph:bool :}
   k leads bs b TURN-BASELINE lh ls l TURN-LOCAL rh rs r TURN-REMOTE
   visit execute
   b leads ADVANCE l lh ADVANCE r rh ADVANCE p ph ADVANCE
   CURSOR-MAKE ;

\ One turn of the merge over the least key any side holds next; false
\ once every side is done.
: MERGE-STEP
   ( sides cursor
     [ MODEL:key option<JOURNAL:path-baseline>
       option<MODEL:local-record> option<MODEL:remote-record> -- ]
     -- cursor bool )
   {: s c visit :}
   s SIDES-UNMAKE {: bs ls rs ps :}
   c CURSOR-UNMAKE {: b:n l:n r:n p:n :}
   s c SIDE-LEAST {: least :}
   bs VEC:COUNT b [: bs swap VEC:AT @ BASELINE-KEY ;] KEY-AT
   {: base :}
   base least LEADS? {: leads:bool :}
   leads if base else least then
   MATCH option
      none OF c false ENDOF
      some OF {: k :} s c leads k visit VISIT true ENDOF
   ;MATCH ;

\ Visits every key any side knows once, in key order, with the
\ baseline's path and value, the scan's record and the listing's
\ record at it, each if that side has one.
: FOR-EACH-KNOWN-PATH
   ( ^VEC:vector<MODEL:baseline-record> ^VEC:vector<local-entry>
     ^VEC:vector<MODEL:remote-record> ^VEC:vector<pending-plan>
     [ MODEL:key option<JOURNAL:path-baseline>
       option<MODEL:local-record> option<MODEL:remote-record> -- ]
     -- )
   {: bs ls rs ps visit :}
   bs ls rs ps SIDES-MAKE {: s :}
   0 0 0 0 CURSOR-MAKE
   begin s swap visit MERGE-STEP 0= until
   drop ;


\ ---- case collisions ------------------------------------------------

\ Rust's CaseCollisionResolution; root-changed is its LocalRootChanged:
\ the configured path no longer names the journal's active root.
ENUM case-collision-resolution
   VARIANT none ;VARIANT
   VARIANT renamed FIELD path MODEL:path ;VARIANT
   VARIANT changed FIELD path MODEL:path ;VARIANT
   VARIANT root-changed ;VARIANT
;ENUM

\ A local spelling, its Dropbox identity and whether a rename may move
\ it.
STRUCTURE spelling
   FIELD key MODEL:key
   FIELD path MODEL:path
   FIELD renamable bool
;STRUCTURE

STRUCTURE case-variant-move
   FIELD source MODEL:path
   FIELD destination MODEL:path
;STRUCTURE

: NO-PATH ( -- option<MODEL:path> ) OPTION:NONE ;
: NO-NAME ( -- option<str> ) OPTION:NONE ;

: PATH$ ( MODEL:path -- ^u8 n ) MODEL:PATH>STR str> ;

: PATH= ( MODEL:path MODEL:path -- bool )
   {: a:MODEL:path b:MODEL:path :}
   a PATH$ b PATH$ STR= ;

: SPELLING-KEY ( spelling -- MODEL:key )
   SPELLING-UNMAKE {: k p r :} k ;

: SPELLING-PATH ( spelling -- MODEL:path )
   SPELLING-UNMAKE {: k p r :} p ;

: RENAMABLE ( spelling -- bool )
   SPELLING-UNMAKE {: k p r :} r ;

: SPELLING-AT ( ^VEC:vector<spelling> n -- spelling ) VEC:AT @ ;

\ The rename moves only a regular file or a directory, never what the
\ scan published as unsupported.
: RENAMABLE? ( MODEL:observation<MODEL:local> -- bool )
   MATCH MODEL:observation
      present OF drop true ENDOF
      directory OF true ENDOF
      absent OF true ENDOF
      unknown OF UNSUPPORTED-REASON? 0= ENDOF
   ;MATCH ;

: PUSH-SPELLING
   ( ^VEC:vector<spelling> MODEL:local-record ^ARENA:arena -- )
   {: out r ar :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p o :}
   p MODEL:EXCLUDED? if exit then
   p ar MODEL:FOLD p o RENAMABLE? SPELLING-MAKE out VEC:PUSH ! ;

\ The records' spellings, in their order, excluded paths left out.
: SPELLINGS
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- ^VEC:vector<spelling> )
   {: v ar :}
   ar ARENA:ALLOCATOR 0 [type] spelling VEC:NEW {: out :}
   v VEC:COUNT 0 ?do out v i VEC:AT @ ar PUSH-SPELLING loop
   out ;

\ Spelling a against b by key bytes, then path bytes.
: SPELLING-CMP ( n n ^VEC:vector<spelling> -- n )
   {: a b v :}
   v a SPELLING-AT {: x:spelling :}
   v b SPELLING-AT {: y:spelling :}
   x SPELLING-KEY y SPELLING-KEY MODEL:KEY-CMP {: c :}
   c 0<> if c exit then
   x SPELLING-PATH y SPELLING-PATH PATH= if 0 exit then
   x SPELLING-PATH PATH$ y SPELLING-PATH PATH$ STR<
   if -1 else 1 then ;

: SAME-AS-LAST? ( ^VEC:vector<spelling> spelling -- bool )
   {: out s :}
   out VEC:COUNT 0= if false exit then
   out out VEC:COUNT 1- SPELLING-AT SPELLING-PATH
   s SPELLING-PATH PATH= ;

\ A repeated path keeps its last record's spelling, as a map would.
: ADD-DISTINCT ( ^VEC:vector<spelling> spelling -- )
   {: out s :}
   out s SAME-AS-LAST? if s out out VEC:COUNT 1- VEC:AT ! exit then
   s out VEC:PUSH ! ;

\ The distinct spellings, in key order, each key's in path order.
: ORDERED
   ( ^VEC:vector<spelling> ^ARENA:arena -- ^VEC:vector<spelling> )
   {: v ar :}
   v VEC:COUNT [: v SPELLING-CMP ;] ar STABLE-ORDER {: idx :}
   ar ARENA:ALLOCATOR 0 [type] spelling VEC:NEW {: out :}
   idx VEC:COUNT 0 ?do out v idx i VEC:AT @ SPELLING-AT ADD-DISTINCT loop
   out ;

\ The index past the run of spellings from `from` that share its key.
: SPELLING-RUN-END ( ^VEC:vector<spelling> n -- n )
   {: v from :}
   v from SPELLING-AT SPELLING-KEY {: k :}
   from 1+
   begin
      dup v VEC:COUNT < if
         v over SPELLING-AT SPELLING-KEY k MODEL:KEY=
      else false then
   while 1+ repeat ;

: ANY-RENAMABLE? ( ^VEC:vector<spelling> n n -- bool )
   {: v from to :}
   to from ?do
      v i SPELLING-AT RENAMABLE if true unloop exit then
   loop
   false ;

\ The run from `from`, and whether two spellings collide in it.
: SPELLING-RUN-AT ( ^VEC:vector<spelling> n -- n n bool )
   {: v from :}
   v from SPELLING-RUN-END {: to :}
   from to
   to from - 1 > if v from to ANY-RENAMABLE? exit then
   false ;

\ The first colliding run with a renamable spelling; an empty run when
\ none.
: FIRST-COLLISION ( ^VEC:vector<spelling> -- n n )
   {: v :}
   0 begin dup v VEC:COUNT < while
      v swap SPELLING-RUN-AT if exit then nip
   repeat
   dup ;

: KEPT? ( MODEL:path option<MODEL:path> -- bool )
   MATCH option
      none OF drop false ENDOF
      some OF PATH= ENDOF
   ;MATCH ;

: OTHER? ( spelling option<MODEL:path> -- bool )
   {: s kept :}
   s RENAMABLE 0= if false exit then
   s SPELLING-PATH kept KEPT? 0= ;

\ The run's greatest renamable spelling other than kept.
: PREFERRED
   ( ^VEC:vector<spelling> n n option<MODEL:path>
     -- option<MODEL:path> )
   {: v from to kept :}
   to from - 0 ?do
      v to 1- i - SPELLING-AT kept OTHER? if
         v to 1- i - SPELLING-AT SPELLING-PATH OPTION:SOME
         unloop exit
      then
   loop
   NO-PATH ;

\ Rust's case_variant_source: the greatest renamable spelling of the
\ first collision in key order other than the one recorded keeps a
\ baseline under, so the history stays with its file; the recorded one
\ itself when it is the only candidate. A collision of unsupported
\ spellings only is left as it is.
: CASE-VARIANT-SOURCE
   ( ^VEC:vector<MODEL:local-record> [ MODEL:key -- option<MODEL:path> ]
     ^ARENA:arena -- option<MODEL:path> )
   {: records recorded ar :}
   records ar SPELLINGS ar ORDERED {: v :}
   v FIRST-COLLISION {: from:n to:n :}
   from to = if NO-PATH exit then
   v from SPELLING-AT SPELLING-KEY recorded execute {: kept :}
   v from to kept PREFERRED MATCH option
      none OF v from to NO-PATH PREFERRED ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH ;

\ Rust's truncate_component: the name cut to limit bytes, at a character
\ boundary when the name is UTF-8.
: TRUNCATE-COMPONENT ( ^u8 n n -- ^u8 n )
   {: p:^ u:n limit:n :}
   u limit <= if p u exit then
   p u UTF8:VALID? if p p u limit UTF8:FIT exit then
   p limit ;

: JOIN-BYTES ( ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: a:^ au:n b:^ bu:n ar :}
   ar au bu + ARENA:ALLOC drop {: dst:^ :}
   a dst au BYTE-COPY
   b dst au + bu BYTE-COPY
   dst au bu + ;

: SUFFIX ( n ^ARENA:arena -- ^u8 n )
   {: attempt:n ar :}
   attempt 0= if s"  (case variant)" exit then
   s"  (case variant " attempt 1+ FMT:INT$ ar JOIN-BYTES
   s" )" ar JOIN-BYTES ;

\ Rust's case_variant_name; none when the suffix alone passes name-max.
: CASE-VARIANT-NAME ( ^u8 n n n ^ARENA:arena -- option<str> )
   {: name:^ nu:n attempt:n max:n ar :}
   attempt ar SUFFIX {: s:^ su:n :}
   max su < if NO-NAME exit then
   name nu max su - TRUNCATE-COMPONENT s su ar JOIN-BYTES >str OPTION:SOME ;

\ The bytes before and after the "/" at k.
: SPLIT-AT ( ^u8 n n -- ^u8 n ^u8 n )
   {: p:^ u:n k:n :}
   p k p k + 1+ u k - 1- ;

\ The path's parent, empty at the top, and its last name.
: SPLIT-NAME ( ^u8 n -- ^u8 n ^u8 n )
   {: p:^ u:n :}
   p u LAST-SEPARATOR MATCH option
      none OF p 0 p u ENDOF
      some OF p u rot SPLIT-AT ENDOF
   ;MATCH ;

: FINAL? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 0= if false exit then
   p u s" ." STR= if false exit then
   p u s" .." STR= 0= ;

: UNDER ( ^u8 n str ^ARENA:arena -- MODEL:path )
   {: dir:^ du:n name:str ar :}
   du 0= if name MODEL:>PATH exit then
   dir du s" /" ar JOIN-BYTES name str> ar JOIN-BYTES >str MODEL:>PATH ;

: KEYS
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- ^VEC:vector<MODEL:key> )
   {: v ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:key VEC:NEW {: out :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ RECORD-PATH ar MODEL:FOLD out VEC:PUSH !
   loop
   out ;

: TAKEN? ( ^VEC:vector<MODEL:key> MODEL:key -- bool )
   {: keys k :}
   keys VEC:COUNT 0 ?do
      keys i VEC:AT @ k MODEL:KEY= if true unloop exit then
   loop
   false ;

\ The attempt's destination, unless no name fits or a record holds its
\ identity.
: DESTINATION
   ( ^VEC:vector<MODEL:key> ^u8 n ^u8 n n n ^ARENA:arena
     -- option<MODEL:path> bool )
   {: keys dir:^ du:n name:^ nu:n attempt:n max:n ar :}
   name nu attempt max ar CASE-VARIANT-NAME MATCH option
      none OF NO-PATH true ENDOF
      some OF dir du rot ar UNDER {: d :}
         keys d ar MODEL:FOLD TAKEN? if NO-PATH false exit then
         d OPTION:SOME true
      ENDOF
   ;MATCH ;

: NO-UNIQUE ( MODEL:path -- )
   s" could not select a unique local case-variant path" INVALID ;

\ Rust's case_variant_move: the source's first case-variant name whose
\ identity no record holds, trying one more name than there are records.
: CASE-VARIANT-MOVE
   ( ^VEC:vector<MODEL:local-record> MODEL:path n ^ARENA:arena
     -- case-variant-move )
   {: records source max:n ar :}
   records ar KEYS {: keys :}
   source PATH$ SPLIT-NAME {: dir:^ du:n name:^ nu:n :}
   name nu FINAL? 0= if
      source s" local case collision has no final path component"
      INVALID
   then
   records VEC:COUNT 1+ 0 ?do
      keys dir du name nu i max ar DESTINATION if
         MATCH option
            none OF source NO-UNIQUE ENDOF
            some OF source swap CASE-VARIANT-MOVE-MAKE unloop exit ENDOF
         ;MATCH
      else drop then
   loop
   source NO-UNIQUE ;

\ Rust's supersede_pending_plan: retires a stale live plan; one that
\ already completed needs nothing.
: SUPERSEDE-PENDING-PLAN
   ( JOURNAL:journal JOURNAL:plan-record ^ARENA:arena -- )
   {: j plan ar :}
   plan JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   j id ar JOURNAL:SUPERSEDE-PLAN
   MATCH JOURNAL:plan-supersede
      superseded OF ENDOF
      already-completed OF ENDOF
      not-found OF p s" stale pending plan disappeared" INVALID ENDOF
   ;MATCH ;

: SUPERSEDE-IF-UNDER
   ( JOURNAL:journal JOURNAL:plan-record MODEL:key ^ARENA:arena -- )
   {: j plan k ar :}
   plan JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   p ar MODEL:FOLD {: pk :}
   pk k MODEL:KEY= pk k MODEL:BENEATH? or 0= if exit then
   j plan ar SUPERSEDE-PENDING-PLAN ;

: SUPERSEDE-ALL-UNDER
   ( JOURNAL:journal ^VEC:vector<JOURNAL:plan-record> MODEL:key
     ^ARENA:arena -- )
   {: j plans k ar :}
   plans VEC:COUNT 0 ?do j plans i VEC:AT @ k ar SUPERSEDE-IF-UNDER loop ;

\ Retires every live plan, pending or blocked, at the source's identity
\ or beneath it, both read before any is retired.
: SUPERSEDE-BENEATH ( JOURNAL:journal MODEL:path ^ARENA:arena -- )
   {: j source ar :}
   source ar MODEL:FOLD {: k :}
   j ar JOURNAL:PENDING-PLANS {: pending :}
   j ar JOURNAL:BLOCKED-PLANS {: blocked :}
   j pending k ar SUPERSEDE-ALL-UNDER
   j blocked k ar SUPERSEDE-ALL-UNDER ;

: RENAMED ( MODEL:path -- case-collision-resolution )
   construct case-collision-resolution renamed ;

: CHANGED ( MODEL:path -- case-collision-resolution )
   construct case-collision-resolution changed ;

: MOVE-VARIANT
   ( fd JOURNAL:journal case-variant-move ^ARENA:arena
     -- case-collision-resolution )
   {: root:fd j mv ar :}
   mv CASE-VARIANT-MOVE-UNMAKE {: src dst :}
   j src ar SUPERSEDE-BENEATH
   j src [: PATH$ root -rot LOCAL:ENTRY-EXISTS-AT ;] ar
   JOURNAL:INVALIDATE-CASE-COLLISION-BASELINES
   root src PATH$ dst PATH$ LOCAL:RENAME-CASE-VARIANT
   MATCH LOCAL:rename-outcome
      renamed OF src RENAMED ENDOF
      retry OF src CHANGED ENDOF
   ;MATCH ;

: RESOLVE-BELOW
   ( fd MODEL:path JOURNAL:journal ^VEC:vector<MODEL:local-record>
     ^ARENA:arena -- case-collision-resolution )
   {: root:fd source j records ar :}
   root source PATH$ LOCAL:PARENT-NAME-MAX MATCH option
      none OF source CHANGED ENDOF
      some OF {: max:n :}
         root j records source max ar CASE-VARIANT-MOVE ar MOVE-VARIANT
      ENDOF
   ;MATCH ;

: RESOLVE-AT
   ( MODEL:path JOURNAL:journal ^u8 n ^VEC:vector<MODEL:local-record>
     ^ARENA:arena -- case-collision-resolution )
   {: source j p:^ u:n records ar :}
   j p u LOCAL:OPEN-ACTIVE-ROOT MATCH option
      none OF construct case-collision-resolution root-changed ENDOF
      some OF {: root:fd :}
         [: root source j records ar RESOLVE-BELOW ;]
         [: root FS:CLOSE-DIR ;] finally
      ENDOF
   ;MATCH ;

: RECORDED-SPELLING
   ( MODEL:key JOURNAL:journal ^ARENA:arena -- option<MODEL:path> )
   {: k j ar :}
   j k ar JOURNAL:BASELINE-SPELLING ;

\ Rust's resolve_case_collision: renames one spelling of the first
\ collision below the sync root at p apart, retiring the plans at its
\ identity and forgetting the baselines the rename leaves stale.
: RESOLVE-CASE-COLLISION
   ( JOURNAL:journal ^u8 n ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- case-collision-resolution )
   {: j p:^ u:n records ar :}
   records [: j ar RECORDED-SPELLING ;] ar
   CASE-VARIANT-SOURCE MATCH option
      none OF construct case-collision-resolution none ENDOF
      some OF j p u records ar RESOLVE-AT ENDOF
   ;MATCH ;

\ ---- file-copy names ----------------------------------------------

\ Rust's FileCopyOrigin with what its callers pass beside it: a Dropbox
\ copy reuses a name holding its content and skips the excluded paths.
ENUM file-copy-origin
   VARIANT local ;VARIANT
   VARIANT dropbox FIELD excluded ^VEC:vector<MODEL:path> ;VARIANT
;ENUM

\ The k kept bytes, c appended while k is below 12 and c alphanumeric.
: KEEP-ALNUM ( n ^u8 u8 -- n )
   {: k:n dst:^ c:u8 :}
   k 12 < c STR-ALNUM? and 0= if k exit then
   c dst k + c!
   k 1+ ;

\ The hash's first 12 ASCII letters and digits, else "content".
: COPY-IDENTITY ( DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: h ar :}
   h DROPBOX:HASH>STR str> {: p:^ u:n :}
   ar 12 ARENA:ALLOC drop {: dst:^ :}
   0 u 0 ?do dst p i + c@ KEEP-ALNUM loop {: k:n :}
   k 0= if s" content" exit then
   dst k ;

: ORIGIN$ ( file-copy-origin -- ^u8 n )
   MATCH file-copy-origin
      local OF s" local file" ENDOF
      dropbox OF drop s" Dropbox file" ENDOF
   ;MATCH ;

: COPY-SUFFIX
   ( file-copy-origin DROPBOX:hash n ^ARENA:arena -- ^u8 n )
   {: o h attempt:n ar :}
   s"  (" o ORIGIN$ ar JOIN-BYTES s"  " ar JOIN-BYTES
   h ar COPY-IDENTITY ar JOIN-BYTES
   attempt 0<> if
      s"  " ar JOIN-BYTES attempt 1+ FMT:INT$ ar JOIN-BYTES
   then
   s" )" ar JOIN-BYTES ;

\ Rust's file_copy_name; none when the suffix alone passes name-max.
: FILE-COPY-NAME
   ( str DROPBOX:hash file-copy-origin n n ^ARENA:arena -- option<str> )
   {: name:str h o attempt:n max:n ar :}
   o h attempt ar COPY-SUFFIX {: s:^ su:n :}
   max su < if NO-NAME exit then
   name str> max su - TRUNCATE-COMPONENT s su ar JOIN-BYTES >str
   OPTION:SOME ;

: LISTED? ( ^VEC:vector<MODEL:path> MODEL:path -- bool )
   {: v p :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ p PATH= if true unloop exit then
   loop
   false ;

: EXCLUDED-COPY? ( file-copy-origin MODEL:path -- bool )
   {: o p :}
   o MATCH file-copy-origin
      local OF false ENDOF
      dropbox OF p LISTED? ENDOF
   ;MATCH ;

: REUSES? ( file-copy-origin -- bool )
   MATCH file-copy-origin
      local OF false ENDOF
      dropbox OF drop true ENDOF
   ;MATCH ;

: LOCAL-HOLDS? ( MODEL:observation<MODEL:local> DROPBOX:hash -- bool )
   {: o h :}
   o MATCH MODEL:observation
      present OF MODEL-LOCAL:UNMAKE h DROPBOX:HASH= ENDOF
      directory OF false ENDOF
      absent OF false ENDOF
      unknown OF drop false ENDOF
   ;MATCH ;

: REMOTE-HOLDS? ( MODEL:observation<MODEL:remote> DROPBOX:hash -- bool )
   {: o h :}
   o MATCH MODEL:observation
      present OF MODEL-REMOTE:UNMAKE drop h DROPBOX:HASH= ENDOF
      directory OF false ENDOF
      absent OF false ENDOF
      unknown OF drop false ENDOF
   ;MATCH ;

: LOCAL-MATCHES? ( option<MODEL:local-record> DROPBOX:hash -- bool )
   {: found h :}
   found MATCH option
      none OF true ENDOF
      some OF MODEL-LOCAL--RECORD:UNMAKE nip h LOCAL-HOLDS? ENDOF
   ;MATCH ;

: REMOTE-MATCHES? ( option<MODEL:remote-record> DROPBOX:hash -- bool )
   {: found h :}
   found MATCH option
      none OF true ENDOF
      some OF REMOTE-OBSERVATION h REMOTE-HOLDS? ENDOF
   ;MATCH ;

: NO-REMOTE? ( option<MODEL:remote-record> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

\ Whether neither side holds a record at the key.
: FREE?
   ( option<MODEL:local-record> option<MODEL:remote-record> -- bool )
   {: l r :}
   l MATCH option
      none OF r NO-REMOTE? ENDOF
      some OF drop false ENDOF
   ;MATCH ;

\ Whether the copy may take candidate c: no record holds its identity,
\ or a Dropbox copy finds this content in each record that does.
: USABLE?
   ( sides MODEL:path DROPBOX:hash file-copy-origin ^ARENA:arena
     -- bool )
   {: s c h o ar :}
   o c EXCLUDED-COPY? if false exit then
   c ar MODEL:FOLD {: k :}
   s SIDES-UNMAKE {: bs ls rs ps :}
   ls k FIND-LOCAL {: l :}
   rs k FIND-REMOTE {: r :}
   l r FREE? if true exit then
   o REUSES? 0= if false exit then
   l h LOCAL-MATCHES? r h REMOTE-MATCHES? and ;

: COPY-NAME ( MODEL:path ^ARENA:arena -- str )
   {: source ar :}
   source ar FILE-NAME MATCH option
      none OF
         source s" directory collision has no final path component"
         INVALID
      ENDOF
      some OF ENDOF
   ;MATCH ;

\ Rust's file_copy_path: the source's first file-copy name under its
\ parent the copy may take; the names grow until one no longer fits.
: FILE-COPY-PATH
   ( sides MODEL:path DROPBOX:hash file-copy-origin n ^ARENA:arena
     -- MODEL:path )
   {: s source h o max:n ar :}
   source ar COPY-NAME {: name:str :}
   source PATH$ SPLIT-NAME {: dir:^ du:n x:^ xu:n :}
   0 begin
      dup >r name h o r> max ar FILE-COPY-NAME MATCH option
         none OF
            source
            s" could not select a unique synchronized file-copy path"
            INVALID
         ENDOF
         some OF
            dir du rot ar UNDER
            s over h o ar USABLE? if nip exit then drop
         ENDOF
      ;MATCH
      1+
   again ;

\ ---- listing changes -----------------------------------------------

\ Rust's DropboxRoot: the configured root, lowercase, and its count of
\ components.
STRUCTURE listing-root
   FIELD path str
   FIELD lower str
   FIELD depth n
;STRUCTURE

\ A directory's key and the spelling of its last component.
STRUCTURE casing
   FIELD key MODEL:key
   FIELD name str
;STRUCTURE

: LISTING-FAILED ( ^u8 n -- )
   {: t:^ tu:n :}
   LOG:ERROR s" reconcile" LOG:LINE t tu LOG:TEXT+ LOG:;LINE
   E-LISTING throw ;

\ Rust's InvalidEntryPath, naming the display path when there is one.
: BAD-PATH ( ^u8 n -- )
   {: d:^ du:n :}
   LOG:ERROR s" reconcile" LOG:LINE
   s" Dropbox listing contained an invalid or out-of-root path"
   LOG:TEXT+
   du 0<> if s"  `" LOG:TEXT+ d du LOG:TEXT+ s" `" LOG:TEXT+ then
   LOG:;LINE E-LISTING throw ;

: SAVED ( ^u8 n ^ARENA:arena -- str )
   {: p:^ u:n ar :}
   u 0= if s" " >str exit then
   ar u ARENA:ALLOC drop {: dst:^ :}
   p dst u BYTE-COPY
   dst u >str ;

\ The valid UTF-8 bytes lowercased, in the arena.
: LOWERED ( ^u8 n ^ARENA:arena -- str )
   {: p:^ u:n ar :}
   u 0= if s" " >str exit then
   p u UNICODE:LOWERED-BYTES {: size:n :}
   ar size ARENA:ALLOC drop {: dst:^ :}
   p u dst size UNICODE:LOWER drop
   dst size >str ;

\ Rust's DropboxRoot::new over the binding's remote root.
: NEW-LISTING-ROOT ( str ^ARENA:arena -- listing-root )
   {: s:str ar :}
   s str> DROPBOX:ROOT-PATH? 0= if
      DROPBOX:E-ROOT-PATH ERROR:TEXT$ LISTING-FAILED
   then
   s s str> ar LOWERED s str> SEPARATOR COUNT-CHAR LISTING-ROOT-MAKE ;

: ROOT-LOWER ( listing-root -- str )
   LISTING-ROOT-UNMAKE {: p:str l:str depth:n :} l ;

: ROOT-DEPTH ( listing-root -- n )
   LISTING-ROOT-UNMAKE {: p:str l:str depth:n :} depth ;

\ Whether the display path lowercases to the lower one, both valid
\ UTF-8 as Rust's strings are.
: LOWERS? ( ^u8 n ^u8 n -- bool )
   {: l:^ lu:n d:^ du:n :}
   l lu UTF8:VALID? d du UTF8:VALID? and 0= if false exit then
   d du l lu UNICODE:LOWERS-TO? ;

\ The index of the key in the lower path: past the root's lower path
\ and a separator, or -1.
: KEY-START ( ^u8 n str -- n )
   {: l:^ lu:n rl:str :}
   rl str> {: r:^ ru:n :}
   l lu r ru STARTS-WITH? 0= if -1 exit then
   lu ru <= if -1 exit then
   l ru + c@ SEPARATOR <> if -1 exit then
   ru 1+ ;

\ The index after the k-th separator, k above 0, or -1 when fewer.
: PAST-SEPARATORS ( ^u8 n n -- n )
   {: p:^ u:n k:n :}
   0 u 0 ?do
      p i + c@ SEPARATOR = if
         1+ dup k = if drop i 1+ unloop exit then
      then
   loop drop -1 ;

\ Whether key and path bytes have as many components, none invalid.
: FITTING? ( ^u8 n ^u8 n -- bool )
   {: k:^ ku:n p:^ pu:n :}
   k ku SEPARATOR COUNT-CHAR p pu SEPARATOR COUNT-CHAR <>
   if false exit then
   k ku DROPBOX:INVALID-PARTS? p pu DROPBOX:INVALID-PARTS? or 0= ;

\ Rust's relative_paths: the key and display path beneath the root of
\ the entry's lower and display paths, in the arena.
: RELATIVE-PATHS
   ( ^u8 n ^u8 n listing-root ^ARENA:arena -- MODEL:key MODEL:path )
   {: l:^ lu:n d:^ du:n root ar :}
   l lu root ROOT-LOWER KEY-START {: ks:n :}
   d du root ROOT-DEPTH 1+ PAST-SEPARATORS {: ps:n :}
   l lu d du LOWERS? ks 0 >= and ps 0 >= and 0= if d du BAD-PATH then
   l ks + lu ks - {: k:^ ku:n :}
   d ps + du ps - {: p:^ pu:n :}
   k ku p pu FITTING? 0= if d du BAD-PATH then
   k ku ar SAVED MODEL:>KEY p pu ar SAVED MODEL:>PATH ;

: OWN-ENTRY? ( ^DROPBOX:entry listing-root -- bool )
   {: e root :}
   root ROOT-LOWER str> {: r:^ ru:n :}
   ru 0= if false exit then
   e DROPBOX-ENTRY:LOWER @ SPAN:$ r ru STR= ;

: RESTRICTED-ROOT ( ^DROPBOX:entry -- )
   DROPBOX-ENTRY:RESTRICTED @ if
      s" configured Dropbox root cannot be traversed completely"
      LISTING-FAILED
   then ;

\ A listing of a folder holds the folder; only an unrestricted one
\ keeps the root usable.
: ROOT-ENTRY ( ^DROPBOX:entry -- )
   {: e :}
   e DROPBOX-ENTRY:KIND @ MATCH DROPBOX:kind
      file OF s" configured Dropbox root is not a folder" LISTING-FAILED
      ENDOF
      folder OF e RESTRICTED-ROOT ENDOF
      deleted OF s" configured Dropbox root is unavailable" LISTING-FAILED
      ENDOF
   ;MATCH ;

: DELETE+
   ( MODEL:key ^VEC:vector<JOURNAL:remote-inventory-change> -- )
   {: k v :}
   k JOURNAL-REMOTE--INVENTORY--CHANGE:DELETE-SUBTREE v VEC:PUSH ! ;

\ The index of the next separator from at, or the length.
: NEXT-SEPARATOR ( ^u8 n n -- n )
   {: p:^ u:n at:n :}
   at begin dup u < while
      dup p + c@ SEPARATOR = if exit then
      1+
   repeat ;

: REMOTE-FOLDER ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:DIRECTORY ;

\ Pushes the ancestor ending at the separators next from ki and pi;
\ the indices past them, or -1 at the last component.
: PARENT+
   ( n n MODEL:key MODEL:path
     ^VEC:vector<JOURNAL:remote-inventory-change> -- n n )
   {: ki:n pi:n k p v :}
   k KEY-BYTES {: kb:^ ku:n :}
   p PATH$ {: pb:^ pu:n :}
   kb ku ki NEXT-SEPARATOR {: ke:n :}
   ke ku >= if -1 -1 exit then
   pb pu pi NEXT-SEPARATOR {: pe:n :}
   kb ke >str MODEL:>KEY pb pe >str MODEL:>PATH REMOTE-FOLDER
   MODEL-REMOTE--RECORD:MAKE
   JOURNAL-REMOTE--INVENTORY--CHANGE:ENSURE-DIRECTORY v VEC:PUSH !
   ke 1+ pe 1+ ;

\ Rust's append_parent_folders: an ensure-directory for each ancestor,
\ outermost first.
: APPEND-PARENT-FOLDERS
   ( MODEL:key MODEL:path
     ^VEC:vector<JOURNAL:remote-inventory-change> -- )
   {: k p v :}
   0 0 begin dup 0 >= while k p v PARENT+ repeat 2drop ;

: UPSERT+
   ( MODEL:observation<MODEL:remote> MODEL:key MODEL:path
     ^VEC:vector<JOURNAL:remote-inventory-change> -- )
   {: o k p v :}
   k p v APPEND-PARENT-FOLDERS
   k p o MODEL-REMOTE--RECORD:MAKE
   JOURNAL-REMOTE--INVENTORY--CHANGE:UPSERT v VEC:PUSH ! ;

: FILE-OBSERVATION
   ( ^DROPBOX:entry ^ARENA:arena -- MODEL:observation<MODEL:remote> )
   {: e ar :}
   e DROPBOX-ENTRY:DOWNLOADABLE @ 0= if
      MODEL-UNKNOWN--REASON:UNSUPPORTED MODEL-OBSERVATION:UNKNOWN exit
   then
   e DROPBOX:COMPLETE? 0= if
      MODEL-UNKNOWN--REASON:INCOMPLETE MODEL-OBSERVATION:UNKNOWN exit
   then
   e ar REPLAY:REMOTE-OF MODEL-OBSERVATION:PRESENT ;

\ A restricted folder's subtree is unknown: its listed contents go.
: FOLDER-OBSERVATION
   ( ^DROPBOX:entry MODEL:key
     ^VEC:vector<JOURNAL:remote-inventory-change>
     -- MODEL:observation<MODEL:remote> )
   {: e k v :}
   e DROPBOX-ENTRY:RESTRICTED @ 0= if
      MODEL-OBSERVATION:DIRECTORY exit
   then
   k v DELETE+
   MODEL-UNKNOWN--REASON:INACCESSIBLE MODEL-OBSERVATION:UNKNOWN ;

: APPEND-OBSERVED
   ( ^DROPBOX:entry MODEL:key MODEL:path
     ^VEC:vector<JOURNAL:remote-inventory-change> ^ARENA:arena -- )
   {: e k p v ar :}
   e DROPBOX-ENTRY:KIND @ MATCH DROPBOX:kind
      file OF k v DELETE+ e ar FILE-OBSERVATION k p v UPSERT+ ENDOF
      folder OF e k v FOLDER-OBSERVATION k p v UPSERT+ ENDOF
      deleted OF k v DELETE+ ENDOF
   ;MATCH ;

\ Rust's append_entry_changes for one entry, which a listing calls for
\ each.
: APPEND-ENTRY-CHANGES
   ( ^DROPBOX:entry listing-root
     ^VEC:vector<JOURNAL:remote-inventory-change> ^ARENA:arena -- )
   {: e root v ar :}
   e DROPBOX-ENTRY:LOWER @ SPAN:$ {: l:^ lu:n :}
   e DROPBOX-ENTRY:DISPLAY @ SPAN:$ {: d:^ du:n :}
   lu 0= du 0= or if d du BAD-PATH then
   e root OWN-ENTRY? if e ROOT-ENTRY exit then
   l lu d du root ar RELATIVE-PATHS {: k p :}
   e k p v ar APPEND-OBSERVED ;

: CHANGE-KEY ( JOURNAL:remote-inventory-change -- MODEL:key )
   MATCH JOURNAL:remote-inventory-change
      upsert OF REMOTE-KEY ENDOF
      ensure-directory OF REMOTE-KEY ENDOF
      delete-subtree OF ENDOF
   ;MATCH ;

: CHANGE-RECORD
   ( JOURNAL:remote-inventory-change -- option<MODEL:remote-record> )
   MATCH JOURNAL:remote-inventory-change
      upsert OF OPTION:SOME ENDOF
      ensure-directory OF OPTION:SOME ENDOF
      delete-subtree OF drop OPTION:NONE ENDOF
   ;MATCH ;

: DELETE? ( JOURNAL:remote-inventory-change -- bool )
   CHANGE-RECORD MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: WRITE? ( JOURNAL:remote-inventory-change -- bool ) DELETE? 0= ;

\ Rust's spells_folder: a folder's or a restricted folder's spelling
\ is authoritative for its descendants.
: SPELLS-FOLDER? ( MODEL:observation<MODEL:remote> -- bool )
   MATCH MODEL:observation
      present OF drop false ENDOF
      directory OF true ENDOF
      absent OF false ENDOF
      unknown OF
         MATCH MODEL:unknown-reason
            incomplete OF false ENDOF
            inaccessible OF true ENDOF
            unavailable OF false ENDOF
            stale OF false ENDOF
            cursor-reset OF false ENDOF
            unsupported OF false ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

: FOLDER-WRITE? ( JOURNAL:remote-inventory-change -- bool )
   CHANGE-RECORD MATCH option
      none OF false ENDOF
      some OF REMOTE-OBSERVATION SPELLS-FOLDER? ENDOF
   ;MATCH ;

\ Change x against y by key.
: CHANGE-CMP ( n n ^VEC:vector<JOURNAL:remote-inventory-change> -- n )
   {: x:n y:n cs :}
   cs x VEC:AT @ CHANGE-KEY cs y VEC:AT @ CHANGE-KEY MODEL:KEY-CMP ;

\ The numbers of the changes q accepts, by key, then number.
: KEYED-NUMBERS
   ( ^VEC:vector<JOURNAL:remote-inventory-change>
     [ JOURNAL:remote-inventory-change -- bool ] ^ARENA:arena
     -- ^VEC:vector<n> )
   {: cs q ar :}
   ar ARENA:ALLOCATOR 0 [type] n VEC:NEW {: v :}
   cs VEC:COUNT 0 ?do
      cs i VEC:AT @ q execute if i v VEC:PUSH ! then
   loop
   v VEC:COUNT 1 > if
      v 0 VEC:AT v VEC:COUNT [: 2dup cs CHANGE-CMP STABLE< ;] SORT:SORT!
   then
   v ;

\ The key of the change whose number is at i.
: NTH-KEY
   ( ^VEC:vector<n> n ^VEC:vector<JOURNAL:remote-inventory-change>
     -- MODEL:key )
   {: v at:n cs :}
   cs v at VEC:AT @ VEC:AT @ CHANGE-KEY ;

\ The index after the run of numbers from i whose changes share a key.
: KEY-RUN-END
   ( ^VEC:vector<n> n ^VEC:vector<JOURNAL:remote-inventory-change>
     -- n )
   {: v from:n cs :}
   v from cs NTH-KEY {: k :}
   from 1+ begin dup v VEC:COUNT < while
      v over cs NTH-KEY k MODEL:KEY= 0= if exit then
      1+
   repeat ;

\ The deletes' numbers by key, only the last at each key.
: LATEST-DELETES
   ( ^VEC:vector<JOURNAL:remote-inventory-change> ^ARENA:arena
     -- ^VEC:vector<n> )
   {: cs ar :}
   cs [: DELETE? ;] ar KEYED-NUMBERS {: sorted :}
   ar ARENA:ALLOCATOR 0 [type] n VEC:NEW {: v :}
   0 begin dup sorted VEC:COUNT < while
      sorted over cs KEY-RUN-END nip
      dup 1- sorted swap VEC:AT @ v VEC:PUSH !
   repeat drop
   v ;

\ The number of the delete at these key bytes, or -1.
: DELETE-AT
   ( ^u8 n ^VEC:vector<n> ^VEC:vector<JOURNAL:remote-inventory-change>
     -- n )
   {: p:^ u:n ds cs :}
   p u ds VEC:COUNT [: ds swap cs NTH-KEY ;] FIND-BYTES {: at:n :}
   at ds VEC:COUNT = if -1 exit then
   ds at VEC:AT @ ;

\ The number of the last delete over the key: at it or an ancestor.
: LAST-DELETE
   ( MODEL:key ^VEC:vector<n>
     ^VEC:vector<JOURNAL:remote-inventory-change> -- n )
   {: k ds cs :}
   k KEY-BYTES {: p:^ u:n :}
   p u ds cs DELETE-AT
   u 0 ?do
      p i + c@ SEPARATOR = if p i ds cs DELETE-AT max then
   loop ;

: NO-RECORD ( -- option<MODEL:remote-record> ) OPTION:NONE ;

\ An ancestor seen through a listed child never hides an unknown
\ folder.
: DIRECTORY-UNLESS-UNKNOWN
   ( MODEL:observation<MODEL:remote>
     -- MODEL:observation<MODEL:remote> )
   MATCH MODEL:observation
      present OF drop MODEL-OBSERVATION:DIRECTORY ENDOF
      directory OF MODEL-OBSERVATION:DIRECTORY ENDOF
      absent OF MODEL-OBSERVATION:DIRECTORY ENDOF
      unknown OF MODEL-OBSERVATION:UNKNOWN ENDOF
   ;MATCH ;

: ENSURED
   ( MODEL:remote-record option<MODEL:remote-record>
     -- option<MODEL:remote-record> )
   {: r held :}
   held MATCH option
      none OF r OPTION:SOME ENDOF
      some OF MODEL-REMOTE--RECORD:UNMAKE DIRECTORY-UNLESS-UNKNOWN
         MODEL-REMOTE--RECORD:MAKE OPTION:SOME
      ENDOF
   ;MATCH ;

\ Rust's apply_entries for one write over what its key holds.
: APPLIED
   ( option<MODEL:remote-record> JOURNAL:remote-inventory-change
     -- option<MODEL:remote-record> )
   {: held c :}
   c MATCH JOURNAL:remote-inventory-change
      upsert OF OPTION:SOME ENDOF
      ensure-directory OF held ENSURED ENDOF
      delete-subtree OF drop held ENDOF
   ;MATCH ;

\ Replays the run of writes from i numbered after the last delete over
\ their key, pushing the record they leave; the index after the run.
: KEY-RECORD
   ( n ^VEC:vector<n> ^VEC:vector<JOURNAL:remote-inventory-change>
     ^VEC:vector<n> ^VEC:vector<MODEL:remote-record> -- n )
   {: from:n ws cs ds out :}
   ws from cs KEY-RUN-END {: end:n :}
   ws from cs NTH-KEY ds cs LAST-DELETE {: last:n :}
   NO-RECORD end from ?do
      ws i VEC:AT @ dup last > if cs swap VEC:AT @ APPLIED else drop then
   loop
   MATCH option
      none OF ENDOF
      some OF out VEC:PUSH ! ENDOF
   ;MATCH
   end ;

: CASING-KEY ( casing -- MODEL:key ) CASING-UNMAKE {: k s:str :} k ;

: NO-CASINGS ( ^ARENA:arena -- ^VEC:vector<casing> )
   ARENA:ALLOCATOR 0 [type] casing VEC:NEW ;

\ Rust's insert_directory_casing: the path's last component.
: INSERT-DIRECTORY-CASING
   ( MODEL:key MODEL:path ^VEC:vector<casing> ^ARENA:arena -- )
   {: k p cv ar :}
   p ar FILE-NAME MATCH option
      none OF p PATH$ BAD-PATH ENDOF
      some OF {: name:str :} k name CASING-MAKE cv VEC:PUSH ! ENDOF
   ;MATCH ;

: RECORD-CASING
   ( MODEL:remote-record ^VEC:vector<casing> ^ARENA:arena -- )
   {: r cv ar :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k p o :}
   o SPELLS-FOLDER? if k p cv ar INSERT-DIRECTORY-CASING then ;

\ Rust's directory_casing over records sorted by key, so by key.
: DIRECTORY-CASING
   ( ^VEC:vector<MODEL:remote-record> ^ARENA:arena
     -- ^VEC:vector<casing> )
   {: rs ar :}
   ar NO-CASINGS {: cv :}
   rs VEC:COUNT 0 ?do rs i VEC:AT @ cv ar RECORD-CASING loop
   cv ;

\ The casing at these key bytes among casings sorted by key, if any.
: CASING-AT ( ^u8 n ^VEC:vector<casing> -- option<str> )
   {: p:^ u:n cv :}
   p u cv VEC:COUNT [: cv swap VEC:AT @ CASING-KEY ;] FIND-BYTES
   {: at:n :}
   at cv VEC:COUNT = if OPTION:NONE exit then
   cv at VEC:AT @ CASING-UNMAKE {: k s:str :} s OPTION:SOME ;

\ Runs q on the component at ki and pi, spelled by the casing of the
\ key up to it, else its own; the indices after them, or -1 past the
\ last.
: SPELL-PART
   ( n n n MODEL:key MODEL:path ^VEC:vector<casing> [ n ^u8 n -- n ]
     -- n n n )
   {: acc:n ki:n pi:n k p cv q :}
   k KEY-BYTES {: kb:^ ku:n :}
   p PATH$ {: pb:^ pu:n :}
   kb ku ki NEXT-SEPARATOR {: ke:n :}
   pb pu pi NEXT-SEPARATOR {: pe:n :}
   kb ke cv CASING-AT MATCH option
      none OF pb pi + pe pi - ENDOF
      some OF str> ENDOF
   ;MATCH {: s:^ su:n :}
   acc s su q execute
   ke ku >= if -1 -1 exit then
   ke 1+ pe 1+ ;

: EACH-SPELLED
   ( n MODEL:key MODEL:path ^VEC:vector<casing> [ n ^u8 n -- n ]
     -- n )
   {: k p cv q :}
   0 0 begin dup 0 >= while k p cv q SPELL-PART repeat 2drop ;

\ Writes the part at offset at of dst, after a separator unless
\ first; the offset after it.
: PUT-PART ( n ^u8 n ^u8 -- n )
   {: at:n s:^ su:n dst:^ :}
   at at 0 > if SEPARATOR dst at + c! 1+ then {: from:n :}
   s dst from + su BYTE-COPY
   from su + ;

\ Rust's normalized_remote_path: each component takes the casing of
\ its prefix's key, when there is one.
: NORMALIZED-REMOTE-PATH
   ( MODEL:key MODEL:path ^VEC:vector<casing> ^ARENA:arena
     -- MODEL:path )
   {: k p cv ar :}
   k KEY-BYTES SEPARATOR COUNT-CHAR p PATH$ SEPARATOR COUNT-CHAR <>
   if p PATH$ BAD-PATH then
   0 k p cv [: nip swap dup 0 > if 1+ then + ;] EACH-SPELLED
   {: size:n :}
   ar size ARENA:ALLOC drop {: dst:^ :}
   0 k p cv [: dst PUT-PART ;] EACH-SPELLED drop
   dst size >str MODEL:>PATH ;

: RESPELL-RECORD
   ( MODEL:remote-record ^VEC:vector<casing> ^ARENA:arena
     -- MODEL:remote-record )
   {: r cv ar :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k p o :}
   k k p cv ar NORMALIZED-REMOTE-PATH o MODEL-REMOTE--RECORD:MAKE ;

\ Rust's normalize_inventory_records over records sorted by key.
: NORMALIZE-INVENTORY-RECORDS
   ( ^VEC:vector<MODEL:remote-record> ^ARENA:arena -- )
   {: rs ar :}
   rs ar DIRECTORY-CASING {: cv :}
   rs VEC:COUNT 0 ?do
      rs i VEC:AT @ cv ar RESPELL-RECORD rs i VEC:AT !
   loop ;

\ Rust's apply_entries over a full listing's changes, then
\ normalize_inventory_records: the records by key.
: INVENTORY-RECORDS
   ( ^VEC:vector<JOURNAL:remote-inventory-change> ^ARENA:arena
     -- ^VEC:vector<MODEL:remote-record> )
   {: cs ar :}
   cs ar LATEST-DELETES {: ds :}
   cs [: WRITE? ;] ar KEYED-NUMBERS {: ws :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: out :}
   0 begin dup ws VEC:COUNT < while ws cs ds out KEY-RECORD repeat drop
   out ar NORMALIZE-INVENTORY-RECORDS
   out ;

\ A journal directory keeps its spelling while no delete is over it.
: KEPT-CASING
   ( JOURNAL:remote-directory ^VEC:vector<n>
     ^VEC:vector<JOURNAL:remote-inventory-change> ^VEC:vector<casing>
     ^ARENA:arena -- )
   {: d ds cs cv ar :}
   d JOURNAL-REMOTE--DIRECTORY:UNMAKE {: k p :}
   k ds cs LAST-DELETE 0< if k p cv ar INSERT-DIRECTORY-CASING then ;

: WRITE-CASING
   ( JOURNAL:remote-inventory-change ^VEC:vector<casing> ^ARENA:arena
     -- )
   {: c cv ar :}
   c CHANGE-RECORD MATCH option
      none OF ENDOF
      some OF MODEL-REMOTE--RECORD:UNMAKE {: k p o :}
         k p cv ar INSERT-DIRECTORY-CASING
      ENDOF
   ;MATCH ;

\ The casing of the run of folder writes from i: its first numbered
\ after the last delete over the key; the index after the run.
: RUN-CASING
   ( n ^VEC:vector<n> ^VEC:vector<JOURNAL:remote-inventory-change>
     ^VEC:vector<n> ^VEC:vector<casing> ^ARENA:arena -- n )
   {: from:n ws cs ds cv ar :}
   ws from cs KEY-RUN-END {: end:n :}
   ws from cs NTH-KEY ds cs LAST-DELETE {: last:n :}
   from end [: ws swap VEC:AT @ last <= ;] SORT:PARTITION-POINT
   {: at:n :}
   at end < if cs ws at VEC:AT @ VEC:AT @ cv ar WRITE-CASING then
   end ;

\ Casing x against y by key.
: CASING-CMP ( n n ^VEC:vector<casing> -- n )
   {: x:n y:n cv :}
   cv x VEC:AT @ CASING-KEY cv y VEC:AT @ CASING-KEY MODEL:KEY-CMP ;

: FIRST-CASING+ ( casing ^VEC:vector<casing> -- )
   {: c out :}
   out VEC:COUNT {: u:n :}
   u 0 > if
      out u 1- VEC:AT @ CASING-KEY c CASING-KEY MODEL:KEY= if exit then
   then
   c out VEC:PUSH ! ;

\ The casings by key, the first of each key's.
: UNIQUE-CASINGS
   ( ^VEC:vector<casing> ^ARENA:arena -- ^VEC:vector<casing> )
   {: cv ar :}
   cv VEC:COUNT [: cv CASING-CMP ;] ar STABLE-ORDER {: idx :}
   ar NO-CASINGS {: out :}
   idx VEC:COUNT 0 ?do cv idx i VEC:AT @ VEC:AT @ out FIRST-CASING+ loop
   out ;

: RESPELL-CHANGE
   ( JOURNAL:remote-inventory-change ^VEC:vector<casing> ^ARENA:arena
     -- JOURNAL:remote-inventory-change )
   {: c cv ar :}
   c MATCH JOURNAL:remote-inventory-change
      upsert OF cv ar RESPELL-RECORD
         JOURNAL-REMOTE--INVENTORY--CHANGE:UPSERT
      ENDOF
      ensure-directory OF cv ar RESPELL-RECORD
         JOURNAL-REMOTE--INVENTORY--CHANGE:ENSURE-DIRECTORY
      ENDOF
      delete-subtree OF drop c ENDOF
   ;MATCH ;

\ Rust's normalize_inventory_changes: a directory keeps the journal's
\ spelling until a delete is over it, then takes the first after.
: NORMALIZE-INVENTORY-CHANGES
   ( ^VEC:vector<JOURNAL:remote-inventory-change>
     ^VEC:vector<JOURNAL:remote-directory> ^ARENA:arena
     -- ^VEC:vector<JOURNAL:remote-inventory-change> )
   {: cs dirs ar :}
   cs ar LATEST-DELETES {: ds :}
   cs [: FOLDER-WRITE? ;] ar KEYED-NUMBERS {: ws :}
   ar NO-CASINGS {: all :}
   dirs VEC:COUNT 0 ?do dirs i VEC:AT @ ds cs all ar KEPT-CASING loop
   0 begin dup ws VEC:COUNT < while ws cs ds all ar RUN-CASING repeat
   drop
   all ar UNIQUE-CASINGS {: cv :}
   ar ARENA:ALLOCATOR cs VEC:COUNT
   [type] JOURNAL:remote-inventory-change VEC:NEW {: out :}
   cs VEC:COUNT 0 ?do
      cs i VEC:AT @ cv ar RESPELL-CHANGE out i VEC:AT !
   loop
   out ;


\ ---- the listing ---------------------------------------------------

\ One refresh of the remote inventory: cursor is the journal's, changes
\ the current listing's entries.
STRUCTURE refresh DERIVE addr
   FIELD journal JOURNAL:journal
   FIELD link ^REPLAY:link
   FIELD root listing-root
   FIELD arena ^ARENA:arena
   FIELD cursor DROPBOX:cursor
   FIELD changes ^VEC:vector<JOURNAL:remote-inventory-change>
;STRUCTURE

ARENA REFRESHES refresh

ENUM listing-state starting delta full published ;ENUM
ENUM listing-event done reset ;ENUM
ENUM stored-cursor some none ;ENUM
ENUM listed done ;ENUM

: NEW-REFRESH
   ( JOURNAL:journal ^REPLAY:link listing-root ^ARENA:arena
     -- ^refresh )
   {: j l root ar :}
   ar REFRESHES-NEW {: r :}
   j r REFRESH-JOURNAL ! l r REFRESH-LINK !
   root r REFRESH-ROOT ! ar r REFRESH-ARENA !
   r ;

: CLIENT ( ^refresh -- ^DROPBOX:client )
   REFRESH-LINK @ REPLAY-LINK:CLIENT @ ;

: LISTING-PATH ( listing-root -- ^u8 n )
   LISTING-ROOT-UNMAKE {: p:str l:str depth:n :} p str> ;

\ The cursor of the listing the client finished last.
: LISTED-CURSOR ( ^refresh -- DROPBOX:cursor )
   CLIENT DROPBOX:CURSOR >str DROPBOX:>CURSOR ;

\ Every listing starts with no changes, so a reset drops the delta's.
: FRESH ( ^refresh -- )
   {: r :}
   r REFRESH-ARENA @ ARENA:ALLOCATOR 0
   [type] JOURNAL:remote-inventory-change VEC:NEW
   r REFRESH-CHANGES ! ;

: ENTRY+ ( ^DROPBOX:entry ^refresh -- )
   {: e r :}
   e r REFRESH-ROOT @ r REFRESH-CHANGES @ r REFRESH-ARENA @
   APPEND-ENTRY-CHANGES ;

: STORED ( ^refresh -- stored-cursor )
   {: r :}
   r REFRESH-JOURNAL @ r REFRESH-ARENA @ JOURNAL:REMOTE-CURSOR
   MATCH option
      none OF construct stored-cursor none ENDOF
      some OF r REFRESH-CURSOR ! construct stored-cursor some ENDOF
   ;MATCH ;

: DELTA-REPLY ( DROPBOX:reply ^refresh -- listing-event )
   {: y:DROPBOX:reply r :}
   y MATCH DROPBOX:reply
      done OF construct listing-event done ENDOF
      refused OF
         DROPBOX-ERROR:RESET DROPBOX-ERROR:EQ 0=
         if y r REFRESH-LINK @ REPLAY:STOP-PASS then
         construct listing-event reset
      ENDOF
      retry OF drop y r REFRESH-LINK @ REPLAY:STOP-PASS ENDOF
      unlinked OF y r REFRESH-LINK @ REPLAY:STOP-PASS ENDOF
   ;MATCH ;

\ A reset here is another reply: the full listing cannot restart.
: FULL-REPLY ( DROPBOX:reply ^refresh -- listed )
   {: y:DROPBOX:reply r :}
   y MATCH DROPBOX:reply
      done OF construct listed done ENDOF
      refused OF drop y r REFRESH-LINK @ REPLAY:STOP-PASS ENDOF
      retry OF drop y r REFRESH-LINK @ REPLAY:STOP-PASS ENDOF
      unlinked OF y r REFRESH-LINK @ REPLAY:STOP-PASS ENDOF
   ;MATCH ;

: CONTINUED ( ^refresh -- listing-event )
   {: r :}
   r FRESH
   r REFRESH-CURSOR @ DROPBOX:CURSOR>STR str> r CLIENT
   [: r ENTRY+ ;] DROPBOX:CHANGES r DELTA-REPLY ;

: LISTED ( ^refresh -- listed )
   {: r :}
   r FRESH
   r REFRESH-ROOT @ LISTING-PATH r CLIENT
   [: r ENTRY+ ;] DROPBOX:LIST r FULL-REPLY ;

: APPLY-DELTA ( ^refresh -- )
   {: r :}
   r REFRESH-JOURNAL @ r REFRESH-ARENA @ JOURNAL:REMOTE-DIRECTORY-PATHS
   {: dirs :}
   r REFRESH-CHANGES @ dirs r REFRESH-ARENA @
   NORMALIZE-INVENTORY-CHANGES {: cs :}
   r REFRESH-JOURNAL @ r LISTED-CURSOR cs
   JOURNAL:APPLY-REMOTE-INVENTORY-DELTA ;

: PUBLISH ( ^refresh -- )
   {: r :}
   r REFRESH-CHANGES @ r REFRESH-ARENA @ INVENTORY-RECORDS {: rs :}
   r REFRESH-JOURNAL @ r LISTED-CURSOR rs
   JOURNAL:PUBLISH-REMOTE-INVENTORY ;

\ Rust's refresh_inventory, after formal/InventoryPublication.tla: a
\ stored cursor's changes apply as one delta, else a full listing
\ replaces the inventory; the journal changes only on the way to
\ published.
FSM:DEFINE INVENTORY-PUBLICATION ( ^refresh ) listing-state listing-event
   IN starting  STORED ( stored-cursor )
      some  -  >delta
      none  -  >full
   IN delta  CONTINUED
      done   APPLY-DELTA  >published
      reset  -            >full
   IN full  LISTED ( listed )
      done  PUBLISH  >published
   FINAL published  -
;DEFINE

\ Brings the journal's remote inventory up to date with the link's
\ client; a reply that ends it is in the link.
: REFRESH-INVENTORY
   ( JOURNAL:journal ^REPLAY:link listing-root ^ARENA:arena -- )
   NEW-REFRESH construct listing-state starting
   INVENTORY-PUBLICATION ;


\ ---- prepare words -------------------------------------------------

\ The pass's context; a prepare word reads what it needs.
STRUCTURE run DERIVE addr
   FIELD journal JOURNAL:journal
   FIELD link ^REPLAY:link
   FIELD root str
   FIELD staging str
   FIELD arena ^ARENA:arena
;STRUCTURE

: ROOT$ ( ^run -- ^u8 n ) RUN-ROOT @ str> ;
: STAGING$ ( ^run -- ^u8 n ) RUN-STAGING @ str> ;

\ Rust's Prepared<StagedUpload>; occupied is its
\ StageDestinationOccupied error, which every caller acts on at once.
ENUM prepared-upload
   VARIANT ready FIELD stage ^LOCAL:staged-upload ;VARIANT
   VARIANT fresh ;VARIANT
   VARIANT occupied ;VARIANT
;ENUM

\ Rust's Prepared<()>.
ENUM prepared ready fresh ;ENUM

: NO-STAGE ( -- LOCAL:stage-outcome<^LOCAL:staged-upload> )
   s" " >str LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED ;
: DROP-STAGE ( LOCAL:stage-outcome<^LOCAL:staged-upload> -- ) drop ;
: NO-HASH ( -- DROPBOX:hash ) s" " >str DROPBOX:>HASH ;
: DROP-HASH ( DROPBOX:hash -- ) drop ;

: STAGE-CONVERTS? ( n n -- bool )
   drop dup LOCAL:E-OCCUPIED = swap LOCAL:E-SOURCE-CHANGED = or ;
: SOURCE-CHANGED? ( n n -- bool ) drop LOCAL:E-SOURCE-CHANGED = ;

\ LOCAL:STAGE-UPLOAD of path's content c, and the code it threw,
\ else 0.
: STAGE-LOCAL
   ( ^run MODEL:path DROPBOX:hash
     -- LOCAL:stage-outcome<^LOCAL:staged-upload> n )
   {: r path c :}
   NO-STAGE [: DROP-STAGE r ROOT$ path PATH$ r STAGING$ c
      r RUN-ARENA @ LOCAL:STAGE-UPLOAD ;]
   ['] STAGE-CONVERTS? LOCAL:CONVERTING ;

\ The upload source's content now, and the code it threw, else 0.
: OBSERVE-SOURCE ( ^run MODEL:path -- DROPBOX:hash n )
   {: r path :}
   NO-HASH [: DROP-HASH r ROOT$ path PATH$ r RUN-ARENA @
      LOCAL:OBSERVE-UPLOAD-SOURCE ;]
   ['] SOURCE-CHANGED? LOCAL:CONVERTING ;

\ An already staged upload is ready while its source still holds c.
: RECHECK
   ( ^LOCAL:staged-upload ^run MODEL:path DROPBOX:hash
     -- prepared-upload )
   {: stage r path c :}
   r path OBSERVE-SOURCE {: code:n :}
   code 0= if
      c DROPBOX:HASH= 0= if construct prepared-upload fresh exit then
      stage construct prepared-upload ready exit
   then
   drop code LOCAL:E-SOURCE-CHANGED = if
      construct prepared-upload fresh exit
   then
   code throw ;

\ Rust's prepare_local: path's content staged for upload.
: PREPARE-LOCAL ( ^run MODEL:path DROPBOX:hash -- prepared-upload )
   {: r path c :}
   r path c STAGE-LOCAL {: code:n :}
   code 0= if
      MATCH LOCAL:stage-outcome
         staged OF construct prepared-upload ready ENDOF
         already-staged OF r path c RECHECK ENDOF
         content-changed OF drop construct prepared-upload fresh ENDOF
         destination-occupied OF
            drop construct prepared-upload occupied
         ENDOF
      ;MATCH exit
   then
   DROP-STAGE
   code LOCAL:E-OCCUPIED = if
      construct prepared-upload occupied exit
   then
   code LOCAL:E-SOURCE-CHANGED = if
      construct prepared-upload fresh exit
   then
   code throw ;

\ An occupied stage path still records the plan.
: PREPARE-UPLOAD ( ^run MODEL:path DROPBOX:hash -- prepared )
   PREPARE-LOCAL MATCH prepared-upload
      ready OF drop construct prepared ready ENDOF
      fresh OF construct prepared fresh ENDOF
      occupied OF construct prepared ready ENDOF
   ;MATCH ;

\ Rust's prepare_plan for a decision's one operation.
: PREPARE-OPERATION ( ^run MODEL:path MODEL:operation -- prepared )
   {: r path op :}
   op MATCH MODEL:operation
      create-local-directory OF construct prepared ready ENDOF
      create-remote-directory OF construct prepared ready ENDOF
      delete-local-directory OF construct prepared ready ENDOF
      delete-remote-directory OF construct prepared ready ENDOF
      create-remote OF
         {: c :} r path c PREPARE-UPLOAD
      ENDOF
      \ A download is fetched only after its plan is durable: the
      \ replay step runs it.
      install-local OF drop construct prepared ready ENDOF
      replace-local OF drop drop construct prepared ready ENDOF
      preserve-local OF drop construct prepared ready ENDOF
      preserve-remote OF drop construct prepared ready ENDOF
      delete-local OF drop construct prepared ready ENDOF
      delete-remote OF drop construct prepared ready ENDOF
      replace-remote OF
         drop {: c :} r path c PREPARE-UPLOAD
      ENDOF
   ;MATCH ;

\ Rust's Conflict::local.
: CONFLICT-LOCAL ( MODEL:conflict -- option<MODEL:local> )
   MATCH MODEL:conflict
      initial OF drop OPTION:SOME ENDOF
      divergent OF drop OPTION:SOME ENDOF
      local-deleted OF drop OPTION:NONE ENDOF
      remote-deleted OF OPTION:SOME ENDOF
   ;MATCH ;

\ Rust's Conflict::remote.
: CONFLICT-REMOTE ( MODEL:conflict -- option<MODEL:remote> )
   MATCH MODEL:conflict
      initial OF {: l r :} r OPTION:SOME ENDOF
      divergent OF {: l r :} r OPTION:SOME ENDOF
      local-deleted OF OPTION:SOME ENDOF
      remote-deleted OF drop OPTION:NONE ENDOF
   ;MATCH ;

\ The local copy from the prepared stage; another entry at the stage
\ path blocks it.
: STAGED-COPY
   ( prepared-upload ^run MODEL:path -- REPLAY:copy-outcome )
   {: r path :}
   MATCH prepared-upload
      ready OF
         {: stage :} r ROOT$ path stage r RUN-ARENA @
         REPLAY:MATERIALIZE-LOCAL-CONFLICT
      ENDOF
      fresh OF REPLAY-COPY--OUTCOME:SOURCE-CHANGED ENDOF
      occupied OF
         MODEL-BLOCKAGE:STAGE-OCCUPIED REPLAY-COPY--OUTCOME:BLOCKED
      ENDOF
   ;MATCH ;

\ The conflict's local copy, ready when it has no local side.
: LOCAL-SIDE
   ( ^run MODEL:path MODEL:conflict -- REPLAY:copy-outcome )
   {: r path c :}
   c CONFLICT-LOCAL MATCH option
      none OF REPLAY-COPY--OUTCOME:READY ENDOF
      some OF
         MODEL-LOCAL:UNMAKE {: want :}
         r path want PREPARE-LOCAL r path STAGED-COPY
      ENDOF
   ;MATCH ;

\ The conflict's remote copy, ready when it has no remote side.
: REMOTE-SIDE
   ( ^run MODEL:path MODEL:conflict -- REPLAY:copy-outcome )
   {: r path c :}
   c CONFLICT-REMOTE MATCH option
      none OF REPLAY-COPY--OUTCOME:READY ENDOF
      some OF
         {: rem :} r RUN-LINK @ r ROOT$ path rem r RUN-ARENA @
         REPLAY:MATERIALIZE-REMOTE-CONFLICT
      ENDOF
   ;MATCH ;

\ Rust's prepare_conflict: the local copy first, then the remote one.
: PREPARE-CONFLICT
   ( ^run MODEL:path MODEL:conflict -- REPLAY:copy-outcome )
   {: r path c :}
   r path c LOCAL-SIDE MATCH REPLAY:copy-outcome
      ready OF r path c REMOTE-SIDE ENDOF
      blocked OF REPLAY-COPY--OUTCOME:BLOCKED ENDOF
      source-changed OF REPLAY-COPY--OUTCOME:SOURCE-CHANGED ENDOF
   ;MATCH ;

\ Rust's PreparedDirectoryCollision; root-changed is its
\ LocalRootChanged error, an answer here as in
\ case-collision-resolution.
ENUM prepared-collision
   VARIANT root-changed ;VARIANT
   VARIANT fresh ;VARIANT
   VARIANT blocked FIELD reason MODEL:blockage ;VARIANT
   VARIANT plan FIELD plan JOURNAL:operation-plan ;VARIANT
;ENUM

: FRESH-COLLISION ( -- prepared-collision )
   construct prepared-collision fresh ;

\ prepare_directory_collision's local file, renamed aside to its
\ file-copy name; the path is observed again.
: RENAME-ASIDE
   ( fd ^run sides MODEL:path MODEL:local n -- prepared-collision )
   {: root:fd r s path file max:n :}
   file MODEL-LOCAL:UNMAKE {: c :}
   s path c construct file-copy-origin local max r RUN-ARENA @
   FILE-COPY-PATH {: dst :}
   root path PATH$ dst PATH$ LOCAL:RENAME-FILE-COPY
   MATCH LOCAL:rename-outcome
      renamed OF FRESH-COLLISION ENDOF
      retry OF FRESH-COLLISION ENDOF
   ;MATCH ;

\ prepare_directory_collision's plan once Dropbox's file is copied: its
\ delete on Dropbox, then the directory there.
: DIRECTORY-PLAN
   ( MODEL:remote ^ARENA:arena -- prepared-collision )
   {: rem ar :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW {: ops :}
   v MODEL-OPERATION:DELETE-REMOTE ops VEC:PUSH !
   MODEL-OPERATION:CREATE-REMOTE-DIRECTORY ops VEC:PUSH !
   \ Rust's prepare_plan stages nothing for these two operations.
   ops JOURNAL-OPERATION--PLAN:MAKE
   construct prepared-collision plan ;

: NO-COLLISION ( -- option<prepared-collision> ) OPTION:NONE ;
: SOME-COLLISION ( prepared-collision -- option<prepared-collision> )
   OPTION:SOME ;

\ The collision at path held for this pass, its copy's download
\ blocked b, logged once.
: COPY-BLOCKED
   ( MODEL:blockage MODEL:path -- option<prepared-collision> )
   {: b path :}
   b path REPLAY:WARN-BLOCKED
   b construct prepared-collision blocked SOME-COLLISION ;

\ The answer to path's copy; none: other bytes hold its stage.
: COPY-ANSWER
   ( REPLAY:exact-copy-outcome MODEL:path MODEL:remote ^ARENA:arena
     -- option<prepared-collision> )
   {: path rem ar :}
   MATCH REPLAY:exact-copy-outcome
      ready OF rem ar DIRECTORY-PLAN SOME-COLLISION ENDOF
      destination-changed OF FRESH-COLLISION SOME-COLLISION ENDOF
      stage-occupied OF NO-COLLISION ENDOF
      content-changed OF
         MODEL-BLOCKAGE:DOWNLOAD-VERIFICATION-FAILED
         path COPY-BLOCKED
      ENDOF
      blocked OF path COPY-BLOCKED ENDOF
   ;MATCH ;

\ One try at Dropbox's file copied to dst; none: excluded now
\ holds dst.
: COPY-TRY
   ( fd ^run MODEL:path MODEL:remote ^VEC:vector<MODEL:path>
     MODEL:path -- option<prepared-collision> )
   {: root:fd r path rem ex dst :}
   r RUN-LINK @ root r ROOT$ dst path rem r RUN-ARENA @
   REPLAY:MATERIALIZE-REMOTE-COPY-AT
   path rem r RUN-ARENA @ COPY-ANSWER MATCH option
      none OF dst ex VEC:PUSH ! NO-COLLISION ENDOF
      some OF SOME-COLLISION ENDOF
   ;MATCH ;

\ prepare_directory_collision's Dropbox file copy path, skipping the
\ excluded paths.
: DROPBOX-COPY-PATH
   ( sides MODEL:path MODEL:remote ^VEC:vector<MODEL:path> n ^run
     -- MODEL:path )
   {: s path rem ex max:n r :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   s path c ex construct file-copy-origin dropbox max r RUN-ARENA @
   FILE-COPY-PATH ;

\ prepare_directory_collision's Dropbox file, placed locally under its
\ file-copy name, a name whose stage other bytes hold skipped.
: PLACE-COPY
   ( fd ^run sides MODEL:path MODEL:remote n -- prepared-collision )
   {: root:fd r s path rem max:n :}
   r RUN-ARENA @ ARENA:ALLOCATOR 0 [type] MODEL:path VEC:NEW {: ex :}
   begin
      root r path rem ex s path rem ex max r DROPBOX-COPY-PATH
      COPY-TRY MATCH option
         none OF ENDOF
         some OF exit ENDOF
      ;MATCH
   again ;

: BY-SIDE
   ( fd ^run sides MODEL:path MODEL:collision n
     -- prepared-collision )
   {: root:fd r s path col max:n :}
   col MATCH MODEL:collision
      local-file OF
         {: file :} root r s path file max RENAME-ASIDE
      ENDOF
      local-dir OF {: rem :} root r s path rem max PLACE-COPY ENDOF
   ;MATCH ;

: COLLIDE-BELOW
   ( fd ^run sides MODEL:path MODEL:collision -- prepared-collision )
   {: root:fd r s path col :}
   root path PATH$ LOCAL:PARENT-NAME-MAX MATCH option
      none OF FRESH-COLLISION ENDOF
      some OF {: max:n :} root r s path col max BY-SIDE ENDOF
   ;MATCH ;

\ Rust's prepare_directory_collision: the directory wins, the file
\ kept under its file-copy name.
: PREPARE-DIRECTORY-COLLISION
   ( ^run sides MODEL:path MODEL:collision -- prepared-collision )
   {: r s path col :}
   r RUN-JOURNAL @ r ROOT$ LOCAL:OPEN-ACTIVE-ROOT MATCH option
      none OF construct prepared-collision root-changed ENDOF
      some OF {: root:fd :}
         [: root r s path col COLLIDE-BELOW ;]
         [: root FS:CLOSE-DIR ;] finally
      ENDOF
   ;MATCH ;


\ ---- replay step ---------------------------------------------------

\ A plan's download: its operation and the Dropbox file it installs.
STRUCTURE download-operation
   FIELD id JOURNAL:operation-id
   FIELD source MODEL:remote
;STRUCTURE

: NO-DOWNLOAD ( -- option<download-operation> ) OPTION:NONE ;
: SOME-DOWNLOAD
   ( JOURNAL:operation-id MODEL:remote -- option<download-operation> )
   DOWNLOAD-OPERATION-MAKE OPTION:SOME ;

\ The operation's download, while it is pending.
: DOWNLOAD-OF
   ( JOURNAL:planned-operation -- option<download-operation> )
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :}
   s PENDING? 0= if NO-DOWNLOAD exit then
   o MATCH MODEL:operation
      create-local-directory OF NO-DOWNLOAD ENDOF
      create-remote-directory OF NO-DOWNLOAD ENDOF
      delete-local-directory OF NO-DOWNLOAD ENDOF
      delete-remote-directory OF NO-DOWNLOAD ENDOF
      create-remote OF drop NO-DOWNLOAD ENDOF
      install-local OF {: src :} id src SOME-DOWNLOAD ENDOF
      preserve-local OF drop NO-DOWNLOAD ENDOF
      replace-local OF drop {: src :} id src SOME-DOWNLOAD ENDOF
      delete-local OF drop NO-DOWNLOAD ENDOF
      preserve-remote OF drop NO-DOWNLOAD ENDOF
      replace-remote OF drop drop NO-DOWNLOAD ENDOF
      delete-remote OF drop NO-DOWNLOAD ENDOF
   ;MATCH ;

\ Rust's pending_download_operation: the plan's first operation not
\ completed that installs a Dropbox file.
: PENDING-DOWNLOAD
   ( JOURNAL:plan-record -- option<download-operation> )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops VEC:COUNT 0 ?do
      ops i VEC:AT @ DOWNLOAD-OF MATCH option
         none OF ENDOF
         some OF OPTION:SOME unloop exit ENDOF
      ;MATCH
   loop
   NO-DOWNLOAD ;

: DOWNLOADS? ( JOURNAL:plan-record -- bool )
   PENDING-DOWNLOAD MATCH option
      none OF false ENDOF
      some OF drop true ENDOF
   ;MATCH ;

: ID-OF ( JOURNAL:plan-record -- JOURNAL:plan-id )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :} id ;
: PLAN-PATH ( JOURNAL:plan-record -- MODEL:path )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :} p ;

: PATH-PLAN? ( JOURNAL:plan-record MODEL:path -- bool )
   {: p path :}
   p PLAN-PATH path PATH= ;

: DOWNLOAD-PLAN? ( JOURNAL:plan-record JOURNAL:plan-id -- bool )
   {: p id :}
   p ID-OF JOURNAL:PLAN-ID>N id JOURNAL:PLAN-ID>N =
   p DOWNLOADS? and ;

\ Plan x against plan y by path.
: PLAN-PATH-CMP ( n n ^VEC:vector<JOURNAL:plan-record> -- n )
   {: x:n y:n plans :}
   plans x VEC:AT @ PLAN-PATH plans y VEC:AT @ PLAN-PATH MODEL:PATH-CMP ;

\ The plans' indices sorted by path, which FIND-PATH-PLAN searches.
: PATH-ORDER
   ( ^VEC:vector<JOURNAL:plan-record> ^ARENA:arena -- ^VEC:vector<n> )
   {: plans ar :}
   plans VEC:COUNT [: plans PLAN-PATH-CMP ;] ar STABLE-ORDER ;

: SOME-PLAN
   ( JOURNAL:plan-record bool -- option<JOURNAL:plan-record> )
   {: p ok:bool :}
   ok if p OPTION:SOME exit then
   OPTION:NONE ;

\ The plan by-path's at-th index names.
: PLAN-AT
   ( ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<n> n
     -- JOURNAL:plan-record )
   {: plans by-path at:n :}
   plans by-path at VEC:AT @ VEC:AT @ ;

\ The plan at path, by-path ordering the plans as PATH-ORDER does.
: FIND-PATH-PLAN
   ( ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<n> MODEL:path
     -- option<JOURNAL:plan-record> )
   {: plans by-path path :}
   0 by-path VEC:COUNT
   [: plans by-path rot PLAN-AT PLAN-PATH path MODEL:PATH-CMP 0 < ;]
   SORT:PARTITION-POINT {: at:n :}
   at by-path VEC:COUNT >= if OPTION:NONE exit then
   plans by-path at PLAN-AT {: p :}
   p p path PATH-PLAN? SOME-PLAN ;

\ The plan of this id if it downloads, among plans sorted by id.
: FIND-DOWNLOAD-PLAN
   ( ^VEC:vector<JOURNAL:plan-record> JOURNAL:plan-id
     -- option<JOURNAL:plan-record> )
   {: plans id :}
   0 plans VEC:COUNT
   [: plans swap VEC:AT @ ID-OF JOURNAL:PLAN-ID>N
      id JOURNAL:PLAN-ID>N < ;]
   SORT:PARTITION-POINT {: at:n :}
   at plans VEC:COUNT >= if OPTION:NONE exit then
   plans at VEC:AT @ {: p :}
   p p id DOWNLOAD-PLAN? SOME-PLAN ;

\ Rust's pending_download_slot_identity, for a root of generation gen.
: SLOT-IDENTITY
   ( n MODEL:path download-operation
     -- LOCAL:download-slot-identity )
   {: gen:n path d :}
   d DOWNLOAD-OPERATION-UNMAKE {: id src :}
   gen id JOURNAL:OPERATION-ID>N path PATH$ src
   LOCAL:NEW-SLOT-IDENTITY ;

: ADD-BINDING
   ( ^VEC:vector<LOCAL:binding> n JOURNAL:plan-record -- )
   {: live gen:n p :}
   p PENDING-DOWNLOAD MATCH option
      none OF ENDOF
      some OF {: d :}
         gen p PLAN-PATH d SLOT-IDENTITY LOCAL:SLOT-BINDING
         live VEC:PUSH !
      ENDOF
   ;MATCH ;

: ADD-BINDINGS
   ( ^VEC:vector<LOCAL:binding> n ^VEC:vector<JOURNAL:plan-record> -- )
   {: live gen:n plans :}
   plans VEC:COUNT 0 ?do live gen plans i VEC:AT @ ADD-BINDING loop ;

\ The slot bindings of the pending and the blocked plans' downloads,
\ which no other download's lease may take (replay_pending_at).
: LIVE-BINDINGS
   ( n ^VEC:vector<JOURNAL:plan-record>
     ^VEC:vector<JOURNAL:plan-record> ^ARENA:arena
     -- ^VEC:vector<LOCAL:binding> )
   {: gen:n pending blocked ar :}
   ar ARENA:ALLOCATOR 0 [type] LOCAL:binding VEC:NEW {: live :}
   live gen pending ADD-BINDINGS
   live gen blocked ADD-BINDINGS
   live ;

: LIVE? ( LOCAL:binding ^VEC:vector<LOCAL:binding> -- bool )
   {: b live :}
   live VEC:COUNT 0 ?do
      live i VEC:AT @ b LOCAL:BINDING= if true unloop exit then
   loop
   false ;

\ Holds the plan until its retry time; Rust accepts every answer.
: BLOCK-UNTIL-RETRY ( ^run JOURNAL:plan-id MODEL:blockage -- )
   {: r id why :}
   r RUN-JOURNAL @ id why epoch-seconds JOURNAL:BLOCK-RETRY-SECONDS +
   r RUN-ARENA @ JOURNAL:BLOCK-PLAN MATCH JOURNAL:plan-block
      not-found OF ENDOF
      already-completed OF ENDOF
      blocked OF ENDOF
   ;MATCH ;

: BLOCK-FOUND
   ( ^run option<JOURNAL:plan-record> MODEL:blockage -- )
   {: r found why :}
   found MATCH option
      none OF ENDOF
      some OF {: p :} r p ID-OF why BLOCK-UNTIL-RETRY ENDOF
   ;MATCH ;

\ The plans are sorted by id; by-path is their PATH-ORDER.
: RECORD-BLOCK
   ( ^run ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<n>
     REPLAY:replay-blocked -- )
   {: r plans by-path b :}
   b MATCH REPLAY:replay-blocked
      stage-destination-occupied OF drop {: id :}
         r plans id FIND-DOWNLOAD-PLAN
         MODEL-BLOCKAGE:STAGE-OCCUPIED BLOCK-FOUND
      ENDOF
      local-object OF {: path :}
         r plans by-path path FIND-PATH-PLAN
         MODEL-BLOCKAGE:LOCAL-OBJECT-IN-WAY BLOCK-FOUND
      ENDOF
      durable-plan OF drop drop ENDOF
      fresh-observation-required OF drop ENDOF
      download-required OF drop drop ENDOF
      precondition-changed OF drop drop ENDOF
      remote-operation OF drop ENDOF
      remote-pending OF drop ENDOF
      remote-object OF drop ENDOF
      sync-error OF drop drop ENDOF
   ;MATCH ;

: BLOCKS
   ( ^REPLAY:replay-report -- ^VEC:vector<REPLAY:replay-blocked> )
   REPLAY-REPLAY--REPORT:BLOCKED @ ;

\ Rust's record_local_replay_blocks: the plans an occupied stage or a
\ local object blocked are held durably.
: RECORD-LOCAL-BLOCKS
   ( ^run ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<n>
     ^REPLAY:replay-report -- )
   {: r plans by-path rep :}
   rep BLOCKS {: bs :}
   bs VEC:COUNT 0 ?do
      r plans by-path bs i VEC:AT @ RECORD-BLOCK
   loop ;

: ADD-REPORT ( ^REPLAY:replay-report ^REPLAY:replay-report -- )
   {: from into :}
   from REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS @
   into REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS +!
   from BLOCKS {: bs :}
   bs VEC:COUNT 0 ?do bs i VEC:AT @ into BLOCKS VEC:PUSH ! loop ;

: ADD-DURABLE ( MODEL:path MODEL:blockage ^REPLAY:replay-report -- )
   {: path why rep :}
   path why REPLAY-REPLAY--BLOCKED:DURABLE-PLAN rep BLOCKS VEC:PUSH ! ;

\ A blocked plan's entry in the report.
: ADD-BLOCKED ( JOURNAL:plan-record ^REPLAY:replay-report -- )
   {: p rep :}
   p JOURNAL-PLAN--RECORD:UNMAKE {: id path ops s :}
   s MATCH JOURNAL:plan-status
      pending OF ENDOF
      blocked OF drop {: why :} path why rep ADD-DURABLE ENDOF
      completed OF ENDOF
   ;MATCH ;

\ The step's download, one at a time; reason is why FETCH blocked it.
STRUCTURE download DERIVE addr
   FIELD run ^run
   FIELD root fd
   FIELD generation n
   FIELD plan JOURNAL:plan-record
   FIELD wanted download-operation
   FIELD live ^VEC:vector<LOCAL:binding>
   FIELD report ^REPLAY:replay-report
   FIELD reason MODEL:blockage
;STRUCTURE

ARENA DOWNLOADS download

ENUM download-state DERIVE eq
   queued staged blocked installed unrooted ;ENUM
ENUM fetched staged blocked ;ENUM
ENUM root-check active changed ;ENUM

: NEW-DOWNLOAD
   ( ^run fd n ^VEC:vector<LOCAL:binding> ^REPLAY:replay-report
     -- ^download )
   {: r root:fd gen:n live rep :}
   r RUN-ARENA @ DOWNLOADS-NEW {: x :}
   r x DOWNLOAD-RUN ! root x DOWNLOAD-ROOT !
   gen x DOWNLOAD-GENERATION ! live x DOWNLOAD-LIVE !
   rep x DOWNLOAD-REPORT ! x ;

: WANTED-SOURCE ( ^download -- MODEL:remote )
   DOWNLOAD-WANTED @ DOWNLOAD-OPERATION-UNMAKE {: id src :} src ;

\ The slot the download's partial is kept in, if one can be leased.
: LEASE ( ^download -- option<LOCAL:download-slot-lease> )
   {: x :}
   x DOWNLOAD-GENERATION @ x DOWNLOAD-PLAN @ PLAN-PATH
   x DOWNLOAD-WANTED @ SLOT-IDENTITY {: id :}
   x DOWNLOAD-RUN @ STAGING$ id
   [: x DOWNLOAD-LIVE @ LIVE? ;] LOCAL:LEASE-DOWNLOAD-SLOT ;

: NO-FETCH ( -- LOCAL:stage-outcome<n> )
   s" " >str LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED ;
: DROP-FETCH ( LOCAL:stage-outcome<n> -- ) drop ;

\ The codes FETCH blocks on, other than DOWNLOAD-BLOCKAGE's.
: FETCH-CONVERTS? ( n n -- bool )
   {: code:n e:n :}
   code LOCAL:E-OCCUPIED = code e REPLAY:LOCAL-OBJECT? or ;

\ The download staged through the lease, and the code it threw, else 0.
: STAGE
   ( ^download option<LOCAL:download-slot-lease>
     -- LOCAL:stage-outcome<n> n )
   {: x lease :}
   x DOWNLOAD-RUN @ {: r :}
   NO-FETCH [: DROP-FETCH r RUN-LINK @ x DOWNLOAD-ROOT @ r ROOT$
      x DOWNLOAD-PLAN @ PLAN-PATH x WANTED-SOURCE lease r STAGING$
      r RUN-ARENA @ REPLAY:STAGE-EXACT-DOWNLOAD-AT ;]
   ['] FETCH-CONVERTS? LOCAL:CONVERTING ;

: BLOCKED-AS ( MODEL:blockage ^download -- fetched )
   DOWNLOAD-REASON ! construct fetched blocked ;

: STAGED-AS ( LOCAL:stage-outcome<n> ^download -- fetched )
   {: x :}
   MATCH LOCAL:stage-outcome
      staged OF drop construct fetched staged ENDOF
      already-staged OF drop construct fetched staged ENDOF
      content-changed OF drop
         MODEL-BLOCKAGE:DOWNLOAD-VERIFICATION-FAILED x BLOCKED-AS
      ENDOF
      destination-occupied OF drop
         MODEL-BLOCKAGE:STAGE-OCCUPIED x BLOCKED-AS
      ENDOF
   ;MATCH ;

\ Rust's download_block_reason: a code that blocks the path, else
\ rethrown.
: THROWN-AS ( n ^download -- fetched )
   {: code:n x :}
   code LOCAL:E-OCCUPIED = if
      MODEL-BLOCKAGE:STAGE-OCCUPIED x BLOCKED-AS exit
   then
   code FS:ERRNO REPLAY:LOCAL-OBJECT? if
      MODEL-BLOCKAGE:LOCAL-OBJECT-IN-WAY x BLOCKED-AS exit
   then
   code x DOWNLOAD-RUN @ RUN-LINK @ REPLAY:DOWNLOAD-BLOCKAGE
   MATCH option
      none OF code throw ENDOF
      some OF x BLOCKED-AS ENDOF
   ;MATCH ;

\ Rust's run_download_job: the download staged, or why it blocks.
: FETCH ( ^download -- fetched )
   {: x :}
   x x LEASE STAGE {: code:n :}
   code 0= if x STAGED-AS exit then
   DROP-FETCH code x THROWN-AS ;

\ The download's plan as the journal holds it now: the step's earlier
\ replay may have completed some of its operations.
: CURRENT-PLAN ( ^download -- JOURNAL:plan-record )
   {: x :}
   x DOWNLOAD-RUN @ {: r :}
   x DOWNLOAD-PLAN @ {: p :}
   r RUN-JOURNAL @ p ID-OF r RUN-ARENA @ JOURNAL:PLAN-OF
   MATCH option
      none OF
         p PLAN-PATH s" installing download has no journal plan" INVALID
      ENDOF
      some OF ENDOF
   ;MATCH ;

\ The staged download installed at once.
: INSTALL ( ^download -- )
   {: x :}
   x DOWNLOAD-RUN @ {: r :}
   r RUN-ARENA @ ARENA:ALLOCATOR 0 [type] JOURNAL:plan-record
   VEC:NEW {: one :}
   x CURRENT-PLAN one VEC:PUSH !
   r RUN-JOURNAL @ x DOWNLOAD-ROOT @ r ROOT$ one r RUN-ARENA @
   REPLAY:REPLAY-LOCAL-PLANS-AT {: rep :}
   r one one r RUN-ARENA @ PATH-ORDER rep RECORD-LOCAL-BLOCKS
   rep x DOWNLOAD-REPORT @ ADD-REPORT ;

: BLOCK ( ^download -- )
   {: x :}
   x DOWNLOAD-PLAN @ {: p :}
   x DOWNLOAD-RUN @ p ID-OF x DOWNLOAD-REASON @ BLOCK-UNTIL-RETRY
   p PLAN-PATH x DOWNLOAD-REASON @ x DOWNLOAD-REPORT @ ADD-DURABLE ;

: ROOT-ACTIVE? ( ^run -- bool )
   {: r :}
   r RUN-JOURNAL @ r ROOT$ LOCAL:CONFIGURED-ROOT-IS-ACTIVE? ;

: ROOT-NOW ( ^download -- root-check )
   DOWNLOAD-RUN @ ROOT-ACTIVE? if
      construct root-check active
   else
      construct root-check changed
   then ;

\ One download, after formal/DownloadExecutor.tla: a staged download is
\ installed only while its root is still the active one; otherwise it
\ stays staged and its plan pending. A blocked one is held; any other
\ failure passes up.
FSM:DEFINE DOWNLOAD-EXECUTOR ( ^download ) download-state fetched
   IN queued  FETCH
      staged   -  >staged
      blocked  -  >blocked
   IN staged  ROOT-NOW ( root-check )
      active   -  >installed
      changed  -  >unrooted
   FINAL installed  INSTALL
   FINAL blocked    BLOCK
   FINAL unrooted   -
;DEFINE

\ The step's answer; root-changed is Rust's LocalRootChanged error.
ENUM replay-step
   VARIANT root-changed ;VARIANT
   VARIANT report FIELD report ^REPLAY:replay-report ;VARIANT
;ENUM

: UNROOTED ( -- replay-step ) construct replay-step root-changed ;

\ The plans' excluded ones retired.
: RETIRED
   ( ^run ^VEC:vector<JOURNAL:plan-record>
     -- ^VEC:vector<JOURNAL:plan-record> )
   {: r plans :}
   r RUN-JOURNAL @ plans r RUN-ARENA @ REPLAY:RETIRE-EXCLUDED-PLANS
   plans ;

: BLOCKED-NOW ( ^run -- ^VEC:vector<JOURNAL:plan-record> )
   {: r :}
   r r RUN-JOURNAL @ r RUN-ARENA @ JOURNAL:BLOCKED-PLANS RETIRED ;

: PENDING-NOW ( ^run -- ^VEC:vector<JOURNAL:plan-record> )
   {: r :}
   r r RUN-JOURNAL @ r RUN-ARENA @ JOURNAL:PENDING-PLANS RETIRED ;

: DOWNLOAD-PATH ( REPLAY:replay-blocked -- option<MODEL:path> )
   MATCH REPLAY:replay-blocked
      download-required OF drop OPTION:SOME ENDOF
      durable-plan OF drop drop NO-PATH ENDOF
      local-object OF drop NO-PATH ENDOF
      fresh-observation-required OF drop NO-PATH ENDOF
      stage-destination-occupied OF drop drop NO-PATH ENDOF
      precondition-changed OF drop drop NO-PATH ENDOF
      remote-operation OF drop NO-PATH ENDOF
      remote-pending OF drop NO-PATH ENDOF
      remote-object OF drop NO-PATH ENDOF
      sync-error OF drop drop NO-PATH ENDOF
   ;MATCH ;

\ The entry at index at kept at index w, or its download's path taken
\ to paths; the next free index.
: SET-ASIDE
   ( n ^VEC:vector<REPLAY:replay-blocked> n ^VEC:vector<MODEL:path>
     -- n )
   {: w bs at paths :}
   bs at VEC:AT @ {: b :}
   b DOWNLOAD-PATH MATCH option
      none OF b bs w VEC:AT ! w 1+ ENDOF
      some OF paths VEC:PUSH ! w ENDOF
   ;MATCH ;

\ The paths of the report's download-required entries, taken out of
\ it; the rest keep their order.
: TAKE-DOWNLOADS
   ( ^REPLAY:replay-report ^ARENA:arena -- ^VEC:vector<MODEL:path> )
   {: rep ar :}
   rep BLOCKS {: bs :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:path VEC:NEW {: paths :}
   0 bs VEC:COUNT 0 ?do bs i paths SET-ASIDE loop
   bs swap VEC:RESIZE
   paths ;

: NO-LOCAL-OPERATION ( MODEL:path -- )
   s" pending download blocker has no matching local operation"
   INVALID ;

\ Runs plan p's download d until it is installed, blocked or left
\ staged by a changed root; answers its final state.
: EXECUTE-DOWNLOAD
   ( ^download JOURNAL:plan-record download-operation
     -- download-state )
   {: x p d :}
   p x DOWNLOAD-PLAN ! d x DOWNLOAD-WANTED !
   construct download-state queued
   begin x swap DOWNLOAD-EXECUTOR-STEP until ;

: UNROOTED? ( download-state -- bool )
   construct download-state unrooted DOWNLOAD-STATE-EQ ;

\ The download of the pending plan at path, which a download-required
\ entry names; answers its final state. by-path is PATH-ORDER's.
: RUN-DOWNLOAD
   ( ^download ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<n>
     MODEL:path -- download-state )
   {: x pending by-path path :}
   pending by-path path FIND-PATH-PLAN MATCH option
      none OF
         path s" pending download blocker has no matching plan" INVALID
      ENDOF
      some OF {: p :}
         p PENDING-DOWNLOAD MATCH option
            none OF path NO-LOCAL-OPERATION ENDOF
            some OF {: d :} x p d EXECUTE-DOWNLOAD ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ The downloads in order, the root checked first and again before
\ each install; false: the root changed, and no later download ran.
: RUN-DOWNLOADS
   ( ^download ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<n>
     ^VEC:vector<MODEL:path> -- bool )
   {: x pending by-path paths :}
   paths VEC:COUNT 0= if true exit then
   x DOWNLOAD-RUN @ ROOT-ACTIVE? 0= if false exit then
   paths VEC:COUNT 0 ?do
      x pending by-path paths i VEC:AT @ RUN-DOWNLOAD UNROOTED? if
         false unloop exit
      then
   loop
   true ;

\ The pending plans' local replay with its blocks recorded, then an
\ entry for each blocked plan.
: LOCAL-REPORT
   ( ^run fd ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<n>
     ^VEC:vector<JOURNAL:plan-record> -- ^REPLAY:replay-report )
   {: r root:fd pending by-path blocked :}
   r RUN-JOURNAL @ root r ROOT$ pending r RUN-ARENA @
   REPLAY:REPLAY-LOCAL-PLANS-AT {: rep :}
   r pending by-path rep RECORD-LOCAL-BLOCKS
   blocked VEC:COUNT 0 ?do blocked i VEC:AT @ rep ADD-BLOCKED loop
   rep ;

\ The pending plans' Dropbox operations, once the root is checked.
: REMOTE-REPORT ( ^run fd ^REPLAY:replay-report -- replay-step )
   {: r root:fd rep :}
   r ROOT-ACTIVE? 0= if UNROOTED exit then
   r RUN-JOURNAL @ r RUN-LINK @ root r ROOT$ r STAGING$
   r RUN-ARENA @ REPLAY:REPLAY-REMOTE-OPERATIONS-AT rep ADD-REPORT
   rep construct replay-step report ;

\ The step below the root's descriptor, of generation gen.
: STEP-AT
   ( ^run fd n ^VEC:vector<JOURNAL:plan-record> -- replay-step )
   {: r root:fd gen:n blocked :}
   r PENDING-NOW {: pending :}
   pending r RUN-ARENA @ PATH-ORDER {: by-path :}
   gen pending blocked r RUN-ARENA @ LIVE-BINDINGS {: live :}
   r root pending by-path blocked LOCAL-REPORT {: rep :}
   rep r RUN-ARENA @ TAKE-DOWNLOADS {: paths :}
   r root gen live rep NEW-DOWNLOAD {: x :}
   x pending by-path paths RUN-DOWNLOADS 0= if UNROOTED exit then
   r root rep REMOTE-REPORT ;

: STEP-BELOW
   ( ^run fd ^VEC:vector<JOURNAL:plan-record> -- replay-step )
   {: r root:fd blocked :}
   r RUN-JOURNAL @ r RUN-ARENA @ JOURNAL:LOCAL-ROOT-BINDING
   MATCH option
      none OF UNROOTED ENDOF
      some OF JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b gen:n :}
         r root gen blocked STEP-AT
      ENDOF
   ;MATCH ;

\ Rust's replay_pending_at: the plans of earlier passes replayed and
\ their downloads run one at a time, then their Dropbox operations.
: REPLAY-STEP ( ^run -- replay-step )
   {: r :}
   r BLOCKED-NOW {: blocked :}
   r RUN-JOURNAL @ r ROOT$ LOCAL:OPEN-ACTIVE-ROOT MATCH option
      none OF UNROOTED ENDOF
      some OF {: root:fd :}
         [: r root blocked STEP-BELOW ;]
         [: root FS:CLOSE-DIR ;] finally
      ENDOF
   ;MATCH ;


\ ---- planning ------------------------------------------------------

\ Planning's answer: fresh is Rust's FreshObservationRequired,
\ root-changed its LocalRootChanged.
ENUM pass-event ok fresh root-changed ;ENUM

\ A recorded conflict and its path's key.
STRUCTURE known-conflict
   FIELD key MODEL:key
   FIELD conflict MODEL:conflict
;STRUCTURE

\ One planning pass: Rust's report (noop-count, planned, conflict-count) and
\ blocked_paths (held, keys may repeat); collisions are the held collisions.
STRUCTURE planning DERIVE addr
   FIELD run ^run
   FIELD sides sides
   FIELD conflicts ^VEC:vector<known-conflict>
   FIELD now n
   FIELD noop-count n
   FIELD planned n
   FIELD conflict-count n
   FIELD held ^VEC:vector<MODEL:key>
   FIELD collisions ^VEC:vector<MODEL:key>
   FIELD noops ^VEC:vector<JOURNAL:path-baseline>
   FIELD plans ^VEC:vector<JOURNAL:path-plan>
   FIELD decisions ^VEC:vector<path-decision>
;STRUCTURE

ARENA PLANNINGS planning

: NEW-VECTOR ( ^ARENA:arena width<t> -- ^VEC:vector<t> )
   {: ar w :}
   ar ARENA:ALLOCATOR 0 w VEC:NEW ;

\ Runs q on each index in turn.
: GATHER ( ^VEC:vector<n> [ n -- ] -- )
   {: idx q :}
   idx VEC:COUNT 0 ?do idx i VEC:AT @ q execute loop ;

: KEY-PLAN
   ( JOURNAL:plan-record ^VEC:vector<pending-plan> ^ARENA:arena -- )
   {: plan v ar :}
   plan PLAN-PATH ar MODEL:FOLD plan PENDING-PLAN-MAKE v VEC:PUSH ! ;

: KEY-PLANS
   ( ^VEC:vector<JOURNAL:plan-record> ^VEC:vector<pending-plan>
     ^ARENA:arena -- )
   {: plans v ar :}
   plans VEC:COUNT 0 ?do plans i VEC:AT @ v ar KEY-PLAN loop ;

: PLAN-CMP ( n n ^VEC:vector<pending-plan> -- n )
   {: x:n y:n v :}
   v x VEC:AT @ PENDING-KEY v y VEC:AT @ PENDING-KEY MODEL:KEY-CMP ;

\ Rust's live map: the pending plans, then the blocked ones, keyed by
\ path.
: LIVE-PLANS ( ^run -- ^VEC:vector<pending-plan> )
   {: r :}
   r RUN-JOURNAL @ {: j :}
   r RUN-ARENA @ {: ar :}
   ar [type] pending-plan NEW-VECTOR {: v :}
   j ar JOURNAL:PENDING-PLANS v ar KEY-PLANS
   j ar JOURNAL:BLOCKED-PLANS v ar KEY-PLANS
   ar [type] pending-plan NEW-VECTOR {: out :}
   v VEC:COUNT [: v PLAN-CMP ;] ar STABLE-ORDER
   [: v swap VEC:AT @ out VEC:PUSH ! ;] GATHER
   out ;

: CONFLICT-KEY ( known-conflict -- MODEL:key )
   KNOWN-CONFLICT-UNMAKE {: k c :} k ;

: CONFLICT-OF ( known-conflict -- MODEL:conflict )
   KNOWN-CONFLICT-UNMAKE {: k c :} c ;

: KEY-CONFLICT
   ( JOURNAL:conflict-record ^VEC:vector<known-conflict>
     ^ARENA:arena -- )
   {: rec v ar :}
   rec JOURNAL-CONFLICT--RECORD:UNMAKE {: id path c :}
   path ar MODEL:FOLD c KNOWN-CONFLICT-MAKE v VEC:PUSH ! ;

: CONFLICT-CMP ( n n ^VEC:vector<known-conflict> -- n )
   {: x:n y:n v :}
   v x VEC:AT @ CONFLICT-KEY v y VEC:AT @ CONFLICT-KEY MODEL:KEY-CMP ;

\ Rust's conflicts, keyed by path.
: KNOWN-CONFLICTS ( ^run -- ^VEC:vector<known-conflict> )
   {: r :}
   r RUN-ARENA @ {: ar :}
   r RUN-JOURNAL @ ar JOURNAL:CONFLICTS {: recs :}
   ar [type] known-conflict NEW-VECTOR {: v :}
   recs VEC:COUNT 0 ?do recs i VEC:AT @ v ar KEY-CONFLICT loop
   ar [type] known-conflict NEW-VECTOR {: out :}
   v VEC:COUNT [: v CONFLICT-CMP ;] ar STABLE-ORDER
   [: v swap VEC:AT @ out VEC:PUSH ! ;] GATHER
   out ;

\ The merge's sides, read in Rust's order.
: READ-SIDES ( ^run ^VEC:vector<MODEL:local-record> -- sides )
   {: r records :}
   r RUN-JOURNAL @ {: j :}
   r RUN-ARENA @ {: ar :}
   records ar LOCAL-MAP {: ls :}
   j ar JOURNAL:REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE
   {: cursor seen :}
   seen ar REMOTE-MAP {: rs :}
   r LIVE-PLANS {: ps :}
   j ar JOURNAL:BASELINES ls rs ps SIDES-MAKE ;

\ A pass's planning over the merge's sides and the known conflicts.
: NEW-PLANNING
   ( ^run ^VEC:vector<MODEL:local-record> -- ^planning )
   {: r records :}
   r records READ-SIDES {: s :}
   r RUN-ARENA @ {: ar :}
   ar PLANNINGS-NEW {: pl :}
   r pl PLANNING-RUN ! s pl PLANNING-SIDES !
   r KNOWN-CONFLICTS pl PLANNING-CONFLICTS !
   ar [type] MODEL:key NEW-VECTOR pl PLANNING-HELD !
   ar [type] MODEL:key NEW-VECTOR pl PLANNING-COLLISIONS !
   ar [type] JOURNAL:path-baseline NEW-VECTOR pl PLANNING-NOOPS !
   ar [type] JOURNAL:path-plan NEW-VECTOR pl PLANNING-PLANS !
   ar [type] path-decision NEW-VECTOR pl PLANNING-DECISIONS !
   pl ;

: ARENA-OF ( ^planning -- ^ARENA:arena ) PLANNING-RUN @ RUN-ARENA @ ;
: JOURNAL-OF ( ^planning -- JOURNAL:journal )
   PLANNING-RUN @ RUN-JOURNAL @ ;

: SCAN-SIDE ( ^planning -- ^VEC:vector<local-entry> )
   PLANNING-SIDES @ SIDES-UNMAKE {: bs ls rs ps :} ls ;

: LIST-SIDE ( ^planning -- ^VEC:vector<MODEL:remote-record> )
   PLANNING-SIDES @ SIDES-UNMAKE {: bs ls rs ps :} rs ;

: LIVE-SIDE ( ^planning -- ^VEC:vector<pending-plan> )
   PLANNING-SIDES @ SIDES-UNMAKE {: bs ls rs ps :} ps ;

\ The live plan at the key; the journal keeps one per key.
: FIND-LIVE ( ^planning MODEL:key -- option<JOURNAL:plan-record> )
   {: pl k :}
   pl LIVE-SIDE {: v :}
   k KEY-BYTES v VEC:COUNT [: v swap VEC:AT @ PENDING-KEY ;] FIND-BYTES
   {: at:n :}
   at v VEC:COUNT = if OPTION:NONE exit then
   v at VEC:AT @ PENDING-PLAN-UNMAKE {: pk plan :} plan OPTION:SOME ;

: LIVE-AT? ( ^planning MODEL:key -- bool )
   FIND-LIVE MATCH option
      none OF false ENDOF
      some OF drop true ENDOF
   ;MATCH ;

\ The index of the first known conflict at or past the key.
: CONFLICT-FROM ( ^VEC:vector<known-conflict> MODEL:key -- n )
   {: v k :}
   0 v VEC:COUNT
   [: v swap VEC:AT @ CONFLICT-KEY k MODEL:KEY-CMP 0 < ;]
   SORT:PARTITION-POINT ;

\ Whether q accepts a known conflict at the key.
: ANY-AT? ( ^planning MODEL:key [ MODEL:conflict -- bool ] -- bool )
   {: pl k q :}
   pl PLANNING-CONFLICTS @ {: v :}
   v VEC:COUNT v k CONFLICT-FROM ?do
      v i VEC:AT @ CONFLICT-KEY k MODEL:KEY= 0= if
         false unloop exit
      then
      v i VEC:AT @ CONFLICT-OF q execute if true unloop exit then
   loop
   false ;

: ANY-CONFLICT ( MODEL:conflict -- bool ) drop true ;

\ Rust's conflict_paths.contains.
: CONFLICT-AT? ( ^planning MODEL:key -- bool )
   [: ANY-CONFLICT ;] ANY-AT? ;

\ The conflict is recorded at the key.
: CONFLICT-RECORDED? ( ^planning MODEL:key MODEL:conflict -- bool )
   {: pl k c :}
   pl k [: c MODEL:CONFLICT= ;] ANY-AT? ;

\ Rust's blocked_paths.insert.
: HELD+ ( ^planning MODEL:key -- )
   {: pl k :}
   k pl PLANNING-HELD @ VEC:PUSH ! ;

\ Rust's no-op rule: one that keeps the baseline at a path with no
\ conflict is only counted; any other is recorded.
: NOOP ( ^planning MODEL:key MODEL:path MODEL:baseline bool -- )
   {: pl k path base same:bool :}
   same pl k CONFLICT-AT? 0= and if
      1 pl PLANNING-NOOP-COUNT +! exit
   then
   path base JOURNAL-PATH--BASELINE:MAKE
   pl PLANNING-NOOPS @ VEC:PUSH ! ;

: BASELINE-OF ( option<JOURNAL:path-baseline> -- MODEL:baseline )
   MATCH option
      none OF MODEL-BASELINE:ABSENT ENDOF
      some OF JOURNAL-PATH--BASELINE:UNMAKE {: p b :} b ENDOF
   ;MATCH ;

: LOCAL-SEEN
   ( option<MODEL:local-record> ^planning MODEL:key
     -- MODEL:observation<MODEL:local> )
   {: lr pl k :}
   lr MATCH option
      none OF pl SCAN-SIDE k LOCAL-UNOBSERVED ENDOF
      some OF MODEL-LOCAL--RECORD:UNMAKE {: p o :} o ENDOF
   ;MATCH ;

: REMOTE-SEEN
   ( option<MODEL:remote-record> ^planning MODEL:key
     -- MODEL:observation<MODEL:remote> )
   {: rr pl k :}
   rr MATCH option
      none OF pl LIST-SIDE k REMOTE-UNOBSERVED ENDOF
      some OF REMOTE-OBSERVATION ENDOF
   ;MATCH ;

: LIVE-PATH ( ^planning MODEL:key -- MODEL:path )
   {: pl k :}
   pl k FIND-LIVE MATCH option
      none OF
         k MODEL:KEY>STR MODEL:>PATH
         s" canonical path has no display spelling" INVALID
      ENDOF
      some OF PLAN-PATH ENDOF
   ;MATCH ;

: REMOTE-PATH
   ( option<MODEL:remote-record> ^planning MODEL:key -- MODEL:path )
   {: rr pl k :}
   rr MATCH option
      none OF pl k LIVE-PATH ENDOF
      some OF MODEL-REMOTE--RECORD:UNMAKE {: rk p o :} p ENDOF
   ;MATCH ;

\ The baseline's path, else the listing's, else the live plan's.
: CANDIDATE
   ( option<JOURNAL:path-baseline> option<MODEL:remote-record>
     ^planning MODEL:key -- MODEL:path )
   {: br rr pl k :}
   br MATCH option
      none OF rr pl k REMOTE-PATH ENDOF
      some OF JOURNAL-PATH--BASELINE:UNMAKE {: p b :} p ENDOF
   ;MATCH ;

\ The scan's spelling, else the candidate's with the local spelling of
\ each ancestor the scan observed.
: SHOWN-PATH
   ( MODEL:key option<JOURNAL:path-baseline>
     option<MODEL:local-record> option<MODEL:remote-record>
     ^planning -- MODEL:path )
   {: k br lr rr pl :}
   lr MATCH option
      none OF
         pl SCAN-SIDE k br rr pl k CANDIDATE pl ARENA-OF
         SPELL-WITH-LOCAL-ANCESTORS
      ENDOF
      some OF RECORD-PATH ENDOF
   ;MATCH ;

: DECISION-AT
   ( MODEL:baseline option<MODEL:local-record>
     option<MODEL:remote-record> ^planning MODEL:key
     -- MODEL:decision )
   {: base lr rr pl k :}
   base lr pl k LOCAL-SEEN rr pl k REMOTE-SEEN
   pl LIST-SIDE k REMOTE-SUBTREE PLANNER:PLAN ;

\ Rust's baseline_matches_noop.
: KEEPS-BASELINE? ( MODEL:decision MODEL:baseline -- bool )
   {: d base :}
   d MATCH MODEL:decision
      noop OF base MODEL:BASELINE= ENDOF
      operate OF drop false ENDOF
      blocked OF drop false ENDOF
      conflicted OF drop false ENDOF
      collided OF drop false ENDOF
   ;MATCH ;

: NOOP-OF ( MODEL:decision -- option<MODEL:baseline> )
   MATCH MODEL:decision
      noop OF OPTION:SOME ENDOF
      operate OF drop OPTION:NONE ENDOF
      blocked OF drop OPTION:NONE ENDOF
      conflicted OF drop OPTION:NONE ENDOF
      collided OF drop OPTION:NONE ENDOF
   ;MATCH ;

\ A no-op at a key no live plan holds is settled now; any other
\ decision waits for DECIDE.
: FILE-DECISION ( ^planning path-decision -- )
   {: pl pd :}
   pd PATH-DECISION-UNMAKE {: k path same d :}
   pl k LIVE-AT? if pd pl PLANNING-DECISIONS @ VEC:PUSH ! exit then
   d NOOP-OF MATCH option
      none OF pd pl PLANNING-DECISIONS @ VEC:PUSH ! ENDOF
      some OF {: base :} pl k path base same NOOP ENDOF
   ;MATCH ;

\ Rust's closure over each known path in reconcile_published. An
\ excluded path is outside synchronization, even when an older journal
\ has a baseline or remote observation for it: never infer its
\ deletion from its omission in the local scan.
: KNOWN-PATH
   ( MODEL:key option<JOURNAL:path-baseline>
     option<MODEL:local-record> option<MODEL:remote-record>
     ^planning -- )
   {: k br lr rr pl :}
   k MODEL:KEY>STR MODEL:>PATH MODEL:EXCLUDED? if exit then
   br BASELINE-OF {: base :}
   k br lr rr pl SHOWN-PATH {: path :}
   base lr rr pl k DECISION-AT {: d :}
   d base KEEPS-BASELINE? {: same:bool :}
   pl k path same d PATH-DECISION-MAKE FILE-DECISION ;

: DECISION-CMP ( n n ^VEC:vector<path-decision> -- n )
   {: x:n y:n v :}
   v x VEC:AT @ v y VEC:AT @ ORDER-PATH-DECISIONS ;

: DECIDE-ALL ( ^planning -- )
   {: pl :}
   pl PLANNING-SIDES @ SIDES-UNMAKE {: bs ls rs ps :}
   bs ls rs ps [: pl KNOWN-PATH ;] FOR-EACH-KNOWN-PATH
   pl PLANNING-DECISIONS @ {: v :}
   pl ARENA-OF {: ar :}
   ar [type] path-decision NEW-VECTOR {: out :}
   v VEC:COUNT [: v DECISION-CMP ;] ar STABLE-ORDER
   [: v swap VEC:AT @ out VEC:PUSH ! ;] GATHER
   out pl PLANNING-DECISIONS ! ;

\ Rust's Operations(plan): a decision's operate carries one operation.
: ONE-OPERATION
   ( MODEL:operation ^ARENA:arena -- JOURNAL:operation-plan )
   {: op ar :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   op ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

\ What a live plan leaves its path's decision: held, settled for this
\ pass; superseded, decided afresh; fresh, Rust's
\ FreshObservationRequired.
ENUM live-step held superseded fresh ;ENUM

: STATUS-OF ( JOURNAL:plan-record -- JOURNAL:plan-status )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :} s ;

: PLACE-TAKEN? ( MODEL:blockage -- bool )
   MATCH MODEL:blockage
      unsupported-file-size OF false ENDOF
      remote-rejected OF drop false ENDOF
      download-unavailable OF drop false ENDOF
      download-verification-failed OF false ENDOF
      stage-occupied OF true ENDOF
      local-object-in-way OF false ENDOF
      remote-object OF false ENDOF
      conflict-copy-occupied OF true ENDOF
   ;MATCH ;

\ A plan blocked on a taken copy or stage place before its retry time.
: COPY-WAITS? ( JOURNAL:plan-record n -- bool )
   {: plan now:n :}
   plan STATUS-OF MATCH JOURNAL:plan-status
      pending OF false ENDOF
      blocked OF {: why at:n :} why PLACE-TAKEN? at now > and ENDOF
      completed OF false ENDOF
   ;MATCH ;

\ A blocked plan whose retry time has come.
: DUE? ( JOURNAL:plan-record n -- bool )
   {: plan now:n :}
   plan STATUS-OF MATCH JOURNAL:plan-status
      pending OF false ENDOF
      blocked OF {: why at:n :} at now <= ENDOF
      completed OF false ENDOF
   ;MATCH ;

: SUPERSEDE ( ^planning JOURNAL:plan-record -- )
   {: pl plan :}
   pl JOURNAL-OF plan pl ARENA-OF SUPERSEDE-PENDING-PLAN ;

\ Rust's finish_pending_conflict.
: FINISH-PENDING-CONFLICT
   ( ^planning JOURNAL:plan-record MODEL:conflict -- )
   {: pl plan c :}
   pl JOURNAL-OF plan ID-OF c pl ARENA-OF
   JOURNAL:FINISH-PLAN-WITH-CONFLICT
   MATCH JOURNAL:plan-conflict-completion
      not-found OF
         plan PLAN-PATH
         s" pending plan disappeared before conflict completion" INVALID
      ENDOF
      already-completed OF ENDOF
      recorded OF ENDOF
   ;MATCH ;

: CONFLICT-LOST ( JOURNAL:plan-record -- )
   PLAN-PATH s" blocked conflict lost its pending plan" INVALID ;

: BLOCK-CONFLICT
   ( ^planning JOURNAL:plan-record MODEL:blockage -- )
   {: pl plan why :}
   pl PLANNING-NOW @ JOURNAL:BLOCK-RETRY-SECONDS + {: at:n :}
   pl JOURNAL-OF plan ID-OF why at pl ARENA-OF JOURNAL:BLOCK-PLAN
   MATCH JOURNAL:plan-block
      not-found OF plan CONFLICT-LOST ENDOF
      already-completed OF plan CONFLICT-LOST ENDOF
      blocked OF ENDOF
   ;MATCH ;

\ A live plan's conflict: one whose copy waits is held; a prepared one
\ completes the plan, which settles the path without holding it.
: LIVE-CONFLICT
   ( ^planning MODEL:key MODEL:path JOURNAL:plan-record
     MODEL:conflict -- live-step )
   {: pl k path plan c :}
   plan pl PLANNING-NOW @ COPY-WAITS? if
      pl k HELD+ construct live-step held exit
   then
   pl PLANNING-RUN @ path c PREPARE-CONFLICT
   MATCH REPLAY:copy-outcome
      ready OF
         pl plan c FINISH-PENDING-CONFLICT
         1 pl PLANNING-CONFLICT-COUNT +! construct live-step held
      ENDOF
      blocked OF
         {: why :} pl plan why BLOCK-CONFLICT
         pl k HELD+ construct live-step held
      ENDOF
      source-changed OF construct live-step fresh ENDOF
   ;MATCH ;

\ A recorded remote directory delete rests on an inventory that showed
\ nothing beneath the path; entries there now retire it. Every other
\ block keeps its plan, whose own precondition still guards the replay.
: LIVE-BLOCKED
   ( ^planning MODEL:key JOURNAL:plan-record MODEL:blocked-reason
     -- live-step )
   {: pl k plan why :}
   why MATCH MODEL:blocked-reason
      unknown OF ENDOF
      occupied OF pl plan SUPERSEDE ENDOF
   ;MATCH
   pl k HELD+ construct live-step held ;

: UNBLOCK ( ^planning JOURNAL:plan-record -- )
   {: pl plan :}
   pl JOURNAL-OF plan ID-OF pl ARENA-OF JOURNAL:UNBLOCK-PLAN
   MATCH JOURNAL:plan-unblock
      not-found OF
         plan PLAN-PATH s" due blocked plan disappeared" INVALID
      ENDOF
      not-blocked OF ENDOF
      unblocked OF ENDOF
   ;MATCH ;

\ A live plan whose remaining operations are the decision's is kept,
\ and pending again once its retry time has come.
: LIVE-OPERATE
   ( ^planning MODEL:key JOURNAL:plan-record MODEL:operation
     -- live-step )
   {: pl k plan op :}
   plan op pl ARENA-OF ONE-OPERATION REMAINING-OPERATIONS-MATCH?
   0= if pl plan SUPERSEDE construct live-step superseded exit then
   plan pl PLANNING-NOW @ DUE? if pl plan UNBLOCK then
   pl k HELD+ construct live-step held ;

\ reconcile_published's decision at a path a live plan holds.
: LIVE-DECISION
   ( ^planning path-decision JOURNAL:plan-record -- live-step )
   {: pl pd plan :}
   pd PATH-DECISION-UNMAKE {: k path same d :}
   d MATCH MODEL:decision
      noop OF
         drop pl plan SUPERSEDE construct live-step superseded
      ENDOF
      operate OF {: op :} pl k plan op LIVE-OPERATE ENDOF
      blocked OF {: why :} pl k plan why LIVE-BLOCKED ENDOF
      conflicted OF {: c :} pl k path plan c LIVE-CONFLICT ENDOF
      collided OF
         drop pl plan SUPERSEDE construct live-step fresh
      ENDOF
   ;MATCH ;

\ Rust's require_active_local_root, then the plan for recording.
: PUSH-PLAN
   ( ^planning MODEL:path JOURNAL:operation-plan -- pass-event )
   {: pl path plan :}
   pl PLANNING-RUN @ ROOT-ACTIVE? 0= if
      construct pass-event root-changed exit
   then
   path plan JOURNAL-PATH--PLAN:MAKE pl PLANNING-PLANS @ VEC:PUSH !
   construct pass-event ok ;

: NEW-OPERATE
   ( ^planning MODEL:path MODEL:operation -- pass-event )
   {: pl path op :}
   pl PLANNING-RUN @ path op PREPARE-OPERATION MATCH prepared
      ready OF pl path op pl ARENA-OF ONE-OPERATION PUSH-PLAN ENDOF
      fresh OF construct pass-event fresh ENDOF
   ;MATCH ;

\ A recorded conflict was prepared once; its copies now belong to the
\ user, who may edit, move, or delete them.
: NEW-CONFLICT
   ( ^planning MODEL:key MODEL:path MODEL:conflict -- pass-event )
   {: pl k path c :}
   pl k c CONFLICT-RECORDED? if construct pass-event ok exit then
   pl PLANNING-RUN @ path c PREPARE-CONFLICT
   MATCH REPLAY:copy-outcome
      ready OF
         pl JOURNAL-OF path c pl ARENA-OF JOURNAL:RECORD-CONFLICT drop
         1 pl PLANNING-CONFLICT-COUNT +! construct pass-event ok
      ENDOF
      blocked OF drop pl k HELD+ construct pass-event ok ENDOF
      source-changed OF construct pass-event fresh ENDOF
   ;MATCH ;

\ A collision whose copy is blocked holds its path and its subtree.
: NEW-COLLISION
   ( ^planning MODEL:key MODEL:path MODEL:collision -- pass-event )
   {: pl k path col :}
   pl PLANNING-RUN @ pl PLANNING-SIDES @ path col
   PREPARE-DIRECTORY-COLLISION MATCH prepared-collision
      root-changed OF construct pass-event root-changed ENDOF
      fresh OF construct pass-event fresh ENDOF
      blocked OF
         drop k pl PLANNING-COLLISIONS @ VEC:PUSH !
         pl k HELD+ construct pass-event ok
      ENDOF
      plan OF {: plan :} pl path plan PUSH-PLAN ENDOF
   ;MATCH ;

\ reconcile_published's decision at a path no live plan holds.
: NEW-DECISION ( ^planning path-decision -- pass-event )
   {: pl pd :}
   pd PATH-DECISION-UNMAKE {: k path same d :}
   d MATCH MODEL:decision
      noop OF
         {: base :} pl k path base same NOOP construct pass-event ok
      ENDOF
      operate OF {: op :} pl path op NEW-OPERATE ENDOF
      blocked OF drop pl k HELD+ construct pass-event ok ENDOF
      conflicted OF {: c :} pl k path c NEW-CONFLICT ENDOF
      collided OF {: col :} pl k path col NEW-COLLISION ENDOF
   ;MATCH ;

: AFTER-LIVE ( ^planning path-decision live-step -- pass-event )
   {: pl pd step :}
   step MATCH live-step
      held OF construct pass-event ok ENDOF
      superseded OF pl pd NEW-DECISION ENDOF
      fresh OF construct pass-event fresh ENDOF
   ;MATCH ;

: DECISION-KEY ( path-decision -- MODEL:key )
   PATH-DECISION-UNMAKE {: k path same d :} k ;

\ Whether the key is beneath a collision held this pass.
: UNDER-HELD? ( ^planning MODEL:key -- bool )
   {: pl k :}
   pl PLANNING-COLLISIONS @ {: v :}
   v VEC:COUNT 0 ?do
      k v i VEC:AT @ MODEL:BENEATH? if true unloop exit then
   loop
   false ;

\ A path beneath a held collision is held, its live plan kept.
: DECIDE ( ^planning path-decision -- pass-event )
   {: pl pd :}
   pl pd DECISION-KEY UNDER-HELD? if
      pl pd DECISION-KEY HELD+ construct pass-event ok exit
   then
   pl pd DECISION-KEY FIND-LIVE MATCH option
      none OF pl pd NEW-DECISION ENDOF
      some OF {: plan :} pl pd pl pd plan LIVE-DECISION AFTER-LIVE ENDOF
   ;MATCH ;

: OK? ( pass-event -- bool )
   MATCH pass-event
      ok OF true ENDOF
      fresh OF false ENDOF
      root-changed OF false ENDOF
   ;MATCH ;

\ Each decision in order; the first answer but ok ends planning.
: DECIDE-EACH ( ^planning -- pass-event )
   {: pl :}
   pl PLANNING-DECISIONS @ {: v :}
   v VEC:COUNT 0 ?do
      pl v i VEC:AT @ DECIDE dup OK? 0= if unloop exit then drop
   loop
   construct pass-event ok ;

\ Rust's record_reconciliation and what reconcile_published takes from
\ its answer; a path a live plan kept is held.
: RECORD-PLANNING ( ^planning -- )
   {: pl :}
   pl JOURNAL-OF pl PLANNING-NOOPS @ pl PLANNING-PLANS @ pl ARENA-OF
   JOURNAL:RECORD-RECONCILIATION
   JOURNAL-RECONCILIATION--WRITE:UNMAKE {: noops:n plans:n live :}
   noops pl PLANNING-NOOP-COUNT +!
   plans pl PLANNING-PLANNED !
   live VEC:COUNT 0 ?do
      pl live i VEC:AT @ pl ARENA-OF MODEL:FOLD HELD+
   loop ;

\ Rust's reconcile_published from its start to record_reconciliation:
\ every known path decided and prepared, then the no-ops and plans
\ recorded together, unless planning ended early.
: PLAN-PATHS
   ( ^run ^VEC:vector<MODEL:local-record> -- ^planning pass-event )
   NEW-PLANNING {: pl :}
   pl DECIDE-ALL
   epoch-seconds pl PLANNING-NOW !
   pl pl DECIDE-EACH dup OK? 0= if exit then
   drop pl RECORD-PLANNING construct pass-event ok ;


\ ---- the pass ------------------------------------------------------

public

\ Rust's ReconcileReport: blocked counts the distinct live paths,
\ sync-errors the distinct paths replay could not settle.
STRUCTURE report
   FIELD replayed n
   FIELD noops n
   FIELD planned n
   FIELD blocked n
   FIELD sync-errors n
   FIELD conflicts n
;STRUCTURE

\ Rust's ReconcileOutcome: fresh asks for a new scan at once,
\ root-changed says the configured root is not the journal's.
ENUM outcome
   VARIANT complete FIELD report report ;VARIANT
   VARIANT fresh ;VARIANT
   VARIANT root-changed ;VARIANT
;ENUM

private

ARENA RUNS run

\ One pass; each field is set by the state that makes it.
STRUCTURE pass DERIVE addr
   FIELD run ^run
   FIELD recovery str
   FIELD records ^VEC:vector<MODEL:local-record>
   FIELD recovered ^REPLAY:replay-report
   FIELD planning ^planning
   FIELD applied ^REPLAY:replay-report
   FIELD report report
;STRUCTURE

ARENA PASSES pass

\ The answers of RECOVER and LIST-REMOTE, which never ask a new scan.
ENUM step-event ok root-changed ;ENUM

ENUM pass-state DERIVE eq
   settling recovering observing listing deciding applying
   complete stale unrooted ;ENUM

: JOURNAL@ ( ^pass -- JOURNAL:journal ) PASS-RUN @ RUN-JOURNAL @ ;
: ARENA@ ( ^pass -- ^ARENA:arena ) PASS-RUN @ RUN-ARENA @ ;

\ A case collision's answer before the scan: changed only names a
\ path the scan observes again.
: PUBLISHED-SETTLED ( case-collision-resolution -- pass-event )
   MATCH case-collision-resolution
      none OF construct pass-event ok ENDOF
      renamed OF drop construct pass-event fresh ENDOF
      changed OF drop construct pass-event ok ENDOF
      root-changed OF construct pass-event root-changed ENDOF
   ;MATCH ;

: SCAN-SETTLED ( case-collision-resolution -- pass-event )
   MATCH case-collision-resolution
      none OF construct pass-event ok ENDOF
      renamed OF drop construct pass-event fresh ENDOF
      changed OF drop construct pass-event fresh ENDOF
      root-changed OF construct pass-event root-changed ENDOF
   ;MATCH ;

: RESOLVED
   ( ^pass ^VEC:vector<MODEL:local-record>
     -- case-collision-resolution )
   {: x records :}
   x JOURNAL@ x PASS-RUN @ ROOT$ records x ARENA@
   RESOLVE-CASE-COLLISION ;

: SETTLE-PUBLISHED ( ^pass -- pass-event )
   {: x :}
   x x JOURNAL@ x ARENA@ JOURNAL:LOCAL-INVENTORY RESOLVED
   PUBLISHED-SETTLED ;

: RECOVER ( ^pass -- step-event )
   {: x :}
   x PASS-RUN @ REPLAY-STEP MATCH replay-step
      root-changed OF construct step-event root-changed ENDOF
      report OF x PASS-RECOVERED ! construct step-event ok ENDOF
   ;MATCH ;

: NO-SCAN ( -- LOCAL:scan-publication )
   LOCAL-SCAN--PUBLICATION:ROOT-CHANGED ;
: DROP-SCAN ( LOCAL:scan-publication -- ) drop ;
: SCAN-CONVERTS? ( n n -- bool ) drop LOCAL:E-CHANGED = ;

\ LOCAL:SCAN-AND-PUBLISH of the root, and the code it threw, else 0.
: SCANNED ( ^pass -- LOCAL:scan-publication n )
   {: x :}
   x PASS-RUN @ {: r :}
   NO-SCAN [: DROP-SCAN r RUN-JOURNAL @ r ROOT$ r RUN-ARENA @
      LOCAL:SCAN-AND-PUBLISH ;]
   ['] SCAN-CONVERTS? LOCAL:CONVERTING ;

: SCAN-OBSERVED ( LOCAL:scan-publication ^pass -- pass-event )
   {: x :}
   MATCH LOCAL:scan-publication
      published OF LOCAL:SCAN-OBSERVATIONS {: records :}
         records x PASS-RECORDS !
         x records RESOLVED SCAN-SETTLED
      ENDOF
      root-changed OF construct pass-event root-changed ENDOF
   ;MATCH ;

\ A file that changes while it is read asks for a new scan.
: OBSERVE ( ^pass -- pass-event )
   {: x :}
   x SCANNED {: code:n :}
   code 0= if x SCAN-OBSERVED exit then
   DROP-SCAN
   code LOCAL:E-CHANGED = if construct pass-event fresh exit then
   code throw ;

: LIST-REMOTE ( ^pass -- step-event )
   {: x :}
   x PASS-RUN @ {: r :}
   r RUN-LINK @ REPLAY-LINK:ROOT @ r RUN-ARENA @ NEW-LISTING-ROOT
   {: root :}
   r RUN-JOURNAL @ r RUN-LINK @ root r RUN-ARENA @ REFRESH-INVENTORY
   r ROOT-ACTIVE? if construct step-event ok exit then
   construct step-event root-changed ;

: PLAN ( ^pass -- pass-event )
   {: x :}
   x PASS-RUN @ x PASS-RECORDS @ PLAN-PATHS {: pl ev :}
   pl x PASS-PLANNING ! ev ;

: FRESH-REQUIRED? ( REPLAY:replay-blocked -- bool )
   MATCH REPLAY:replay-blocked
      durable-plan OF drop drop false ENDOF
      local-object OF drop false ENDOF
      fresh-observation-required OF drop true ENDOF
      download-required OF drop drop false ENDOF
      stage-destination-occupied OF drop drop false ENDOF
      precondition-changed OF drop drop false ENDOF
      remote-operation OF drop false ENDOF
      remote-pending OF drop false ENDOF
      remote-object OF drop false ENDOF
      sync-error OF drop drop false ENDOF
   ;MATCH ;

: ASKS-FRESH? ( ^REPLAY:replay-report -- bool )
   BLOCKS {: bs :}
   bs VEC:COUNT 0 ?do
      bs i VEC:AT @ FRESH-REQUIRED? if true unloop exit then
   loop
   false ;

: APPLY ( ^pass -- pass-event )
   {: x :}
   x PASS-RUN @ REPLAY-STEP MATCH replay-step
      root-changed OF construct pass-event root-changed ENDOF
      report OF {: rep :}
         rep x PASS-APPLIED !
         rep ASKS-FRESH? if
            construct pass-event fresh
         else
            construct pass-event ok
         then
      ENDOF
   ;MATCH ;

\ Rust's replay_sync_error_path.
: SYNC-ERROR-PATH ( REPLAY:replay-blocked -- option<MODEL:path> )
   MATCH REPLAY:replay-blocked
      durable-plan OF drop OPTION:SOME ENDOF
      local-object OF drop NO-PATH ENDOF
      fresh-observation-required OF drop NO-PATH ENDOF
      download-required OF drop drop NO-PATH ENDOF
      stage-destination-occupied OF drop drop NO-PATH ENDOF
      precondition-changed OF drop drop NO-PATH ENDOF
      remote-operation OF drop NO-PATH ENDOF
      remote-pending OF drop NO-PATH ENDOF
      remote-object OF drop NO-PATH ENDOF
      sync-error OF drop OPTION:SOME ENDOF
   ;MATCH ;

: NTH$ ( ^VEC:vector<str> n -- ^u8 n ) VEC:AT @ str> ;

: NTH< ( n n ^VEC:vector<str> -- bool )
   {: x:n y:n v :}
   v x NTH$ v y NTH$ STR< ;

\ How many distinct byte strings v holds, counted in STR< order.
: DISTINCT ( ^VEC:vector<str> ^ARENA:arena -- n )
   {: v ar :}
   v VEC:COUNT {: k:n :}
   k 0= if 0 exit then
   k [: v NTH< ;] ar ORDER {: idx :}
   1 k 1 ?do
      v idx i 1- VEC:AT @ NTH$ v idx i VEC:AT @ NTH$ STR= 0= if 1+ then
   loop ;

: HELD-COUNT ( ^pass -- n )
   {: x :}
   x ARENA@ [type] str NEW-VECTOR {: v :}
   x PASS-PLANNING @ PLANNING-HELD @ {: held :}
   held VEC:COUNT 0 ?do
      held i VEC:AT @ MODEL:KEY>STR v VEC:PUSH !
   loop
   v x ARENA@ DISTINCT ;

: ERROR-PATHS+ ( ^REPLAY:replay-report ^VEC:vector<str> -- )
   {: rep v :}
   rep BLOCKS {: bs :}
   bs VEC:COUNT 0 ?do
      bs i VEC:AT @ SYNC-ERROR-PATH MATCH option
         none OF ENDOF
         some OF MODEL:PATH>STR v VEC:PUSH ! ENDOF
      ;MATCH
   loop ;

: SYNC-ERROR-COUNT ( ^pass -- n )
   {: x :}
   x ARENA@ [type] str NEW-VECTOR {: v :}
   x PASS-RECOVERED @ v ERROR-PATHS+
   x PASS-APPLIED @ v ERROR-PATHS+
   v x ARENA@ DISTINCT ;

: REPLAYED ( ^pass -- n )
   {: x :}
   x PASS-RECOVERED @ REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS @
   x PASS-APPLIED @ REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS @ + ;

: FILL-REPORT ( ^pass -- )
   {: x :}
   x PASS-PLANNING @ {: pl :}
   x REPLAYED pl PLANNING-NOOP-COUNT @ pl PLANNING-PLANNED @
   x HELD-COUNT x SYNC-ERROR-COUNT pl PLANNING-CONFLICT-COUNT @
   RECONCILE-REPORT:MAKE x PASS-REPORT ! ;

\ Every live plan's path is held, the ones planning kept included.
: HOLD-LIVE ( ^pass -- )
   {: x :}
   x PASS-PLANNING @ {: pl :}
   x PASS-RUN @ LIVE-PLANS {: v :}
   v VEC:COUNT 0 ?do pl v i VEC:AT @ PENDING-KEY HELD+ loop ;

: RETAINED? ( DROPBOX:hash ^VEC:vector<DROPBOX:hash> -- bool )
   {: h:DROPBOX:hash kept :}
   kept VEC:COUNT 0 ?do
      kept i VEC:AT @ h DROPBOX:HASH= if true unloop exit then
   loop
   false ;

\ Rust's reconcile_published after its last replay: the journal
\ pruned, the report filled, then the unreferenced stages removed.
: FINISH ( ^pass -- )
   {: x :}
   x JOURNAL@ {: j :}
   j JOURNAL:PRUNE-COMPLETED-WORK drop
   j x PASS-RECOVERY @ str> REPLAY:PRUNE-COMPLETED-RECOVERIES drop
   j x ARENA@ JOURNAL:PENDING-UPLOAD-CONTENT {: kept :}
   x HOLD-LIVE
   x FILL-REPORT
   x PASS-RUN @ STAGING$ [: kept RETAINED? ;] x ARENA@
   LOCAL:REMOVE-UNREFERENCED-UPLOAD-STAGES drop ;

\ One pass, after formal/SyncPass.tla. A pass that ends early leaves the
\ journal's plans for the next pass to replay.
FSM:DEFINE SYNC-PASS ( ^pass ) pass-state pass-event
   IN settling  SETTLE-PUBLISHED
      ok            -  >recovering
      fresh         -  >stale
      root-changed  -  >unrooted
   IN recovering  RECOVER ( step-event )
      ok            -  >observing
      root-changed  -  >unrooted
   IN observing  OBSERVE
      ok            -  >listing
      fresh         -  >stale
      root-changed  -  >unrooted
   IN listing  LIST-REMOTE ( step-event )
      ok            -  >deciding
      root-changed  -  >unrooted
   IN deciding  PLAN
      ok            -  >applying
      fresh         -  >stale
      root-changed  -  >unrooted
   IN applying  APPLY
      ok            -  >complete
      fresh         -  >stale
      root-changed  -  >unrooted
   FINAL complete  FINISH
   FINAL stale     -
   FINAL unrooted  -
;DEFINE

: NEW-RUN
   ( JOURNAL:journal ^REPLAY:link str str ^ARENA:arena -- ^run )
   {: j l root:str staging:str ar :}
   ar RUNS-NEW {: r :}
   j r RUN-JOURNAL ! l r RUN-LINK !
   root r RUN-ROOT ! staging r RUN-STAGING ! ar r RUN-ARENA !
   r ;

\ SYNC-PASS stops only in a final state.
: ANSWER ( pass-state ^pass -- outcome )
   {: s x :}
   s construct pass-state complete PASS-STATE-EQ if
      x PASS-REPORT @ construct outcome complete exit
   then
   s construct pass-state stale PASS-STATE-EQ if
      construct outcome fresh exit
   then
   construct outcome root-changed ;

public

\ Rust's reconcile_once: replays the plans of earlier passes,
\ publishes both complete inventories and plans every known path once.
: PASS
   ( JOURNAL:journal ^REPLAY:link str str str ^ARENA:arena -- outcome )
   {: j l root:str staging:str recovery:str ar :}
   j l root staging ar NEW-RUN {: r :}
   ar PASSES-NEW {: x :}
   r x PASS-RUN ! recovery x PASS-RECOVERY !
   construct pass-state settling
   begin x swap SYNC-PASS-STEP until
   x ANSWER ;

;package
