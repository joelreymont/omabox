\ reconcile.f - package RECONCILE: one sync pass (rust src/reconcile.rs):
\ list Dropbox, scan the root, plan each path, replay the pending plans
\ and run their downloads, one at a time. A journal answer the pass
\ refuses is logged once with the Rust version's text, naming the path,
\ then thrown as E-INVALID-STATE.
\ STORAGE CLASS. No state of its own. CALLER-OWNED: every value a pass
\ reads or makes lies in the arena the caller passes.

require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/vector.f
require src/lib/sort.f
require src/model.f
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

\ A byte of a path for PATH-CMP: a separator below every other byte,
\ the end below that.
: RANK ( ^u8 n n -- n )
   {: p:^ u:n at:n :}
   at u >= if -2 exit then
   p at + c@ dup SEPARATOR = if drop -1 then ;

\ Rust's Path order of two relative paths with no empty or "."
\ component, which compares their components.
: PATH-CMP ( MODEL:path MODEL:path -- n )
   {: a b :}
   a MODEL:PATH>STR str> {: p:^ u:n :}
   b MODEL:PATH>STR str> {: q:^ v:n :}
   u v max 1+ 0 do
      p u i RANK q v i RANK CMP dup 0<> if unloop exit then drop
   loop 0 ;

\ Entry x sorts before y by key, then path, then index.
: ENTRY< ( n n ^VEC:vector<local-entry> -- bool )
   {: x:n y:n v :}
   v x VEC:AT @ LOCAL-ENTRY-UNMAKE {: k r :}
   v y VEC:AT @ LOCAL-ENTRY-UNMAKE {: k2 r2 :}
   k k2 MODEL:KEY-CMP {: c:n :}
   c 0<> if c 0 < exit then
   r RECORD-PATH r2 RECORD-PATH PATH-CMP {: d:n :}
   d 0<> if d 0 < exit then
   x y < ;

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
   v VEC:COUNT [: v ENTRY< ;] ar ORDER {: idx :}
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

\ Rust's parent_bytes: the bytes before the last separator.
: PARENT-BYTES ( str -- option<str> )
   str> {: p:^ u:n :}
   u begin dup 0 > while
      1- dup p + c@ SEPARATOR = if p swap >str OPTION:SOME exit then
   repeat
   drop OPTION:NONE ;

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

\ Remote record x sorts before y by key, then index, as a stable sort.
: REMOTE< ( n n ^VEC:vector<MODEL:remote-record> -- bool )
   {: x:n y:n v :}
   v x VEC:AT @ REMOTE-KEY v y VEC:AT @ REMOTE-KEY MODEL:KEY-CMP
   {: c:n :}
   c 0<> if c 0 < exit then
   x y < ;

: REMOTE-MAP
   ( ^VEC:vector<MODEL:remote-record> ^ARENA:arena
     -- ^VEC:vector<MODEL:remote-record> )
   {: v ar :}
   v VEC:COUNT [: v REMOTE< ;] ar ORDER {: idx :}
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

;package
