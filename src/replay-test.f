\ replay-test.f - REPLAY's journal steps on a journal under TMPDIR:
\ RETIRE-EXCLUDED-PLANS, given two pending plans, one at an excluded
\ name, supersedes that one and leaves the other, in the vector and in
\ the journal's pending plans. REPLAY-LOCAL-PLANS-AT below a sync
\ root in the case's directory: Rust's
\ legacy_local_preservation_replays_without_creating_a_copy, and a
\ directory at one plan's install target blocking only that plan,
\ the next plan's directory made and its baseline written. Each case
\ removes its directory.
\ Run from the repository root: hb --load src/replay-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/adt/option.f
require src/lib/vector.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/local.f
require src/replay.f

package REPLAY-TEST
private


\ ---- a case's directory ------------------------------------------

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

\ dir/name.
: INSIDE ( str ^u8 n ^ARENA:arena -- str )
   {: d:str a:^ u ar :}
   d str> {: p:^ pu :}
   ar pu u + 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst pu BYTE-COPY
   47 dst pu + c!
   a dst pu + 1+ u BYTE-COPY
   dst pu u + 1+ >str ;

\ A case's directory and the journal path in it.
: JOURNAL-AT ( ^ARENA:arena -- str str )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   d d s" journal.sqlite3" ar INSIDE ;

: GONE ( str -- ) str> FS:REMOVE-TREE ;


\ ---- plans ---------------------------------------------------------

: DISPLAY ( ^u8 n -- MODEL:path ) >str MODEL:>PATH ;

: ONE-PLAN ( MODEL:operation ^ARENA:arena -- JOURNAL:operation-plan )
   {: o ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW {: ops :}
   o ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

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

: PATH-OF ( ^VEC:vector<JOURNAL:plan-record> n -- ^u8 n )
   VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   p MODEL:PATH>STR str> ;

\ The vector holds one plan, at path.
: ONLY-AT ( ^VEC:vector<JOURNAL:plan-record> ^u8 n -- )
   {: plans a:^ u :}
   plans VEC:COUNT 1 T=
   plans 0 PATH-OF a u STR= TTRUE ;


\ ---- cases ---------------------------------------------------------

: RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ( ^ARENA:arena -- )
   {: ar :}
   s" retire excluded plans supersedes only excluded plans" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p JOURNAL:OPEN {: j :}
   j s" folder/.DS_Store" ar RECORD
   j s" folder/notes.md" ar RECORD
   j ar JOURNAL:PENDING-PLANS {: plans :}
   plans VEC:COUNT 2 T=
   j plans ar REPLAY:RETIRE-EXCLUDED-PLANS
   plans s" folder/notes.md" ONLY-AT
   j ar JOURNAL:PENDING-PLANS s" folder/notes.md" ONLY-AT
   j JOURNAL:CLOSE
   d GONE ;

\ ---- local replay

: OPS ( ^ARENA:arena -- ^VEC:vector<MODEL:operation> )
   ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW ;

: OP+ ( MODEL:operation ^VEC:vector<MODEL:operation> -- )
   VEC:PUSH ! ;

\ A pending plan of ops, recorded at path.
: RECORD-OPS
   ( JOURNAL:journal ^u8 n ^VEC:vector<MODEL:operation>
     ^ARENA:arena -- )
   {: j a:^ u ops ar :}
   ops JOURNAL-OPERATION--PLAN:MAKE {: plan :}
   j a u DISPLAY plan ar JOURNAL:RECORD-PLAN RECORDED? TTRUE ;

\ The content hash of the bytes "old".
: OLD ( -- DROPBOX:hash )
   s" b5fa717fc4f7b26b60d0399621cfe776638d31a054fda40246b7872a1b12f897"
   >str DROPBOX:>HASH ;

: OLD-REMOTE ( -- MODEL:remote )
   OLD s" rev-old" >str DROPBOX:>REV MODEL-REMOTE:MAKE ;

\ The case's sync root, made in its directory d.
: ROOT-IN ( str ^ARENA:arena -- str )
   s" root" rot INSIDE {: root:str :}
   root str> FS:MAKE-DIR
   root ;

\ REPLAY-LOCAL-PLANS-AT of the pending plans below root.
: REPLAYED
   ( JOURNAL:journal str ^ARENA:arena -- ^REPLAY:replay-report )
   {: j root:str ar :}
   root str> s" open test root" LOCAL:OPEN-ROOT {: f:fd :}
   [: j f root str> j ar JOURNAL:PENDING-PLANS ar
      REPLAY:REPLAY-LOCAL-PLANS-AT ;]
   [: f FS:CLOSE-DIR ;] finally ;

: COMPLETED ( ^REPLAY:replay-report -- n )
   REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS @ ;

: BLOCKS
   ( ^REPLAY:replay-report -- ^VEC:vector<REPLAY:replay-blocked> )
   REPLAY-REPLAY--REPORT:BLOCKED @ ;

\ Whether b is a local object at the path.
: LOCAL-OBJECT-AT? ( REPLAY:replay-blocked ^u8 n -- bool )
   {: b a:^ u :}
   b MATCH REPLAY:replay-blocked
      local-object OF MODEL:PATH>STR str> a u STR= ENDOF
      durable-plan OF drop drop false ENDOF
      fresh-observation-required OF drop false ENDOF
      download-required OF drop drop false ENDOF
      stage-destination-occupied OF drop drop false ENDOF
      precondition-changed OF drop drop false ENDOF
      remote-operation OF drop false ENDOF
      remote-pending OF drop false ENDOF
      remote-object OF drop false ENDOF
      sync-error OF drop drop false ENDOF
   ;MATCH ;

: DIRECTORY? ( option<MODEL:baseline> -- bool )
   MATCH option
      none OF false ENDOF
      some OF MATCH MODEL:baseline
            absent OF false ENDOF
            present OF drop false ENDOF
            directory OF true ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

: LEGACY-LOCAL-PRESERVATION-REPLAYS-WITHOUT-CREATING-A-COPY
   ( ^ARENA:arena -- )
   {: ar :}
   s" legacy_local_preservation_replays_without_creating_a_copy"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   d ar ROOT-IN {: root:str :}
   root s" legacy.txt" ar INSIDE {: f:str :}
   f str> s" old" FS:WRITE-ALL
   ar OPS {: ops :}
   OLD MODEL-LOCAL:MAKE MODEL-OPERATION:PRESERVE-LOCAL ops OP+
   OLD MODEL-OPERATION:DELETE-LOCAL ops OP+
   p JOURNAL:OPEN {: j :}
   j s" legacy.txt" ops ar RECORD-OPS
   j root ar REPLAYED {: r :}
   r COMPLETED 2 T=
   r BLOCKS VEC:COUNT 0 T=
   f str> FS:EXISTS? TFALSE
   \ An empty root removes: no copy was made in it.
   root str> FS:REMOVE-DIR
   j ar JOURNAL:PENDING-RECOVERIES VEC:COUNT 0 T=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   j JOURNAL:CLOSE
   d GONE ;

: A-LOCAL-OBJECT-BLOCKS-ONLY-ITS-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" a local object blocks only its plan" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   d ar ROOT-IN {: root:str :}
   root s" taken.txt" ar INSIDE str> FS:MAKE-DIR
   ar OPS {: ops :}
   OLD-REMOTE MODEL-OPERATION:INSTALL-LOCAL ops OP+
   p JOURNAL:OPEN {: j :}
   j s" taken.txt" ops ar RECORD-OPS
   j s" made" ar RECORD
   j root ar REPLAYED {: r :}
   r COMPLETED 1 T=
   r BLOCKS VEC:COUNT 1 T=
   r BLOCKS 0 VEC:AT @ s" taken.txt" LOCAL-OBJECT-AT? TTRUE
   root s" made" ar INSIDE str> FS:EXISTS? TTRUE
   j s" made" DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   j ar JOURNAL:PENDING-PLANS s" taken.txt" ONLY-AT
   j JOURNAL:CLOSE
   d GONE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ar LEGACY-LOCAL-PRESERVATION-REPLAYS-WITHOUT-CREATING-A-COPY
   ar A-LOCAL-OBJECT-BLOCKS-ONLY-ITS-PLAN ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" replay-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
