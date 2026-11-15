\ replay.f - package REPLAY: the pending plans' replay (rust
\ src/recovery.rs): what a replay pass reports, the outcomes its steps
\ answer, and the journal steps that finish, supersede or complete a
\ plan. A LOCAL, JOURNAL or DROPBOX failure passes up with its own code,
\ which that library logged where it saw it. A journal answer the
\ replay contract refuses is logged once with the Rust version's text,
\ naming the plan's path, then thrown as E-INVALID-STATE.
\ STORAGE CLASS. No state of its own. CALLER-OWNED: a report, its
\ vector, and every value a journal step reads lie in the arena the
\ caller passes.

require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/vector.f
require src/lib/span.f
require src/lib/fd.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/local.f

package REPLAY
public

-100700 constant E-FIRST
-100799 constant E-LAST
-100700 s" journaled recovery state is invalid"
   ERROR:CODE E-INVALID-STATE

\ destination-changed: the chosen path changed after it was observed;
\ stage-occupied: other bytes hold its download stage.
ENUM exact-copy-outcome
   ready destination-changed stage-occupied
;ENUM

\ A conflict copy: blocked leaves every payload where it is;
\ source-changed: the bytes copied no longer match their identity.
ENUM copy-outcome
   VARIANT ready ;VARIANT
   VARIANT blocked FIELD reason MODEL:blockage ;VARIANT
   VARIANT source-changed ;VARIANT
;ENUM

\ What Dropbox confirms at one path after a mutation or a read.
ENUM remote-path-state
   VARIANT absent ;VARIANT
   VARIANT file FIELD file MODEL:remote ;VARIANT
   VARIANT folder ;VARIANT
   VARIANT unsupported ;VARIANT
;ENUM

\ Dropbox's permanent refusal of one path, which leaves other work be.
ENUM mutation-rejection
   invalid-path unsupported-file-size disallowed-name
   restricted-content permission-denied insufficient-space
   operation-not-allowed path-mismatch rejected-by-dropbox
;ENUM

\ One conditional mutation: pending keeps the precondition, so the
\ journaled mutation stays safe to retry.
ENUM mutation-outcome
   VARIANT applied FIELD state remote-path-state ;VARIANT
   VARIANT pending ;VARIANT
   VARIANT precondition-changed
      FIELD state remote-path-state
   ;VARIANT
   VARIANT rejected FIELD rejection mutation-rejection ;VARIANT
;ENUM

\ Why a plan stays pending. actual: the local content, none when
\ absent; stage-destination-occupied's path is the stage's.
ENUM replay-blocked
   VARIANT durable-plan
      FIELD path MODEL:path FIELD reason MODEL:blockage
   ;VARIANT
   VARIANT local-object FIELD path MODEL:path ;VARIANT
   VARIANT fresh-observation-required
      FIELD path MODEL:path
   ;VARIANT
   VARIANT download-required
      FIELD path MODEL:path FIELD content DROPBOX:hash
   ;VARIANT
   VARIANT stage-destination-occupied
      FIELD plan-id JOURNAL:plan-id FIELD path str
   ;VARIANT
   VARIANT precondition-changed
      FIELD path MODEL:path FIELD actual option<DROPBOX:hash>
   ;VARIANT
   VARIANT remote-operation FIELD path MODEL:path ;VARIANT
   VARIANT remote-pending FIELD path MODEL:path ;VARIANT
   VARIANT remote-object FIELD path MODEL:path ;VARIANT
   VARIANT sync-error
      FIELD path MODEL:path FIELD rejection mutation-rejection
   ;VARIANT
;ENUM

\ One pass: the operations it completed and the plans it left pending.
STRUCTURE replay-report DERIVE addr
   FIELD completed-operations n
   FIELD blocked ^VEC:vector<replay-blocked>
;STRUCTURE

private

\ An operation completed together with the others of its pass.
STRUCTURE final-completion
   FIELD operation-id JOURNAL:operation-id
   FIELD path MODEL:path
   FIELD baseline MODEL:baseline
;STRUCTURE

ARENA REPORTS replay-report


\ ---- failures ------------------------------------------------------

: INVALID ( MODEL:path ^u8 n -- )
   {: path detail:^ du:n :}
   LOG:ERROR s" replay" LOG:LINE
   s" journaled recovery state is invalid for `" LOG:TEXT+
   path MODEL:PATH>STR str> LOG:TEXT+ s" `: " LOG:TEXT+
   detail du LOG:TEXT+ LOG:;LINE
   E-INVALID-STATE throw ;


\ ---- journal records -----------------------------------------------

: PLAN-ID ( JOURNAL:plan-record -- JOURNAL:plan-id )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} id ;

: PLAN-PATH ( JOURNAL:plan-record -- MODEL:path )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} p ;

: OPERATION-ID ( JOURNAL:planned-operation -- JOURNAL:operation-id )
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :} id ;

: NO-BASELINE ( -- option<MODEL:baseline> ) OPTION:NONE ;

: FINAL-PATH ( final-completion -- MODEL:path )
   FINAL-COMPLETION-UNMAKE {: id p b :} p ;

: >REQUEST ( final-completion -- JOURNAL:operation-baseline )
   FINAL-COMPLETION-UNMAKE {: id p b :}
   id b JOURNAL-OPERATION--BASELINE:MAKE ;

: REQUESTS
   ( ^VEC:vector<final-completion> ^ARENA:arena
     -- ^VEC:vector<JOURNAL:operation-baseline> )
   {: finals ar :}
   ar ARENA:ALLOCATOR 0 [type] JOURNAL:operation-baseline VEC:NEW
   {: reqs :}
   finals VEC:COUNT 0 ?do
      finals i VEC:AT @ >REQUEST reqs VEC:PUSH !
   loop
   reqs ;


\ ---- journal answers ------------------------------------------------

\ A non-final operation's completion that leaves its plan pending.
: NONFINAL-DONE? ( JOURNAL:operation-completion -- bool )
   MATCH JOURNAL:operation-completion
      operation-completed OF true ENDOF
      already-completed OF true ENDOF
      not-found OF false ENDOF
      waiting-for-earlier-operation OF drop false ENDOF
      baseline-required OF false ENDOF
      unexpected-baseline OF false ENDOF
      baseline-mismatch OF false ENDOF
      plan-completed OF false ENDOF
   ;MATCH ;

\ A final operation's completion that completed its plan.
: FINAL-DONE? ( JOURNAL:operation-completion -- bool )
   MATCH JOURNAL:operation-completion
      plan-completed OF true ENDOF
      already-completed OF true ENDOF
      not-found OF false ENDOF
      waiting-for-earlier-operation OF drop false ENDOF
      baseline-required OF false ENDOF
      unexpected-baseline OF false ENDOF
      baseline-mismatch OF false ENDOF
      operation-completed OF false ENDOF
   ;MATCH ;

: REJECTED-FINAL ( MODEL:path -- )
   s" journal rejected a completed durable effect" INVALID ;

: CHECK-FINAL ( final-completion JOURNAL:operation-completion -- )
   FINAL-DONE? if drop exit then
   FINAL-PATH REJECTED-FINAL ;

public

\ An empty report, its vector in the arena.
: NEW-REPORT ( ^ARENA:arena -- ^replay-report )
   {: ar :}
   ar REPORTS-NEW {: r :}
   ar ARENA:ALLOCATOR 0 [type] replay-blocked VEC:NEW
   r REPLAY-REPLAY--REPORT:BLOCKED !
   r ;

private

\ Records the conflict and retires the plan; the baseline stays.
: FINISH-CONFLICT
   ( JOURNAL:journal JOURNAL:plan-id MODEL:path MODEL:conflict
     ^ARENA:arena -- )
   {: j id path x ar :}
   j id x ar JOURNAL:FINISH-PLAN-WITH-CONFLICT
   MATCH JOURNAL:plan-conflict-completion
      recorded OF ENDOF
      already-completed OF ENDOF
      not-found OF
         path s" conflicted plan disappeared" INVALID
      ENDOF
   ;MATCH ;

\ Retires a stale plan; the baseline and both trees stay.
: SUPERSEDE-PLAN
   ( JOURNAL:journal JOURNAL:plan-record ^ARENA:arena -- )
   {: j p ar :}
   j p PLAN-ID ar JOURNAL:SUPERSEDE-PLAN
   MATCH JOURNAL:plan-supersede
      superseded OF ENDOF
      already-completed OF ENDOF
      not-found OF
         p PLAN-PATH s" stale plan disappeared" INVALID
      ENDOF
   ;MATCH ;

\ Completes the final operations in one transaction, each completing
\ its plan.
: COMMIT-FINAL-COMPLETIONS
   ( JOURNAL:journal ^VEC:vector<final-completion> ^ARENA:arena -- )
   {: j finals ar :}
   j finals ar REQUESTS ar JOURNAL:COMPLETE-FINAL-OPERATIONS
   {: outcomes :}
   finals VEC:COUNT 0 ?do
      finals i VEC:AT @ outcomes i VEC:AT @ CHECK-FINAL
   loop ;

\ Completes an operation that leaves its plan pending.
: COMPLETE-NONFINAL
   ( JOURNAL:journal JOURNAL:planned-operation MODEL:path ^ARENA:arena
     -- )
   {: j op path ar :}
   j op OPERATION-ID NO-BASELINE ar JOURNAL:COMPLETE-OPERATION
   NONFINAL-DONE? if exit then
   path
   s" journal rejected an ordered preservation completion"
   INVALID ;

\ Completes a plan's final operation and writes its baseline.
: COMPLETE-FINAL
   ( JOURNAL:journal JOURNAL:planned-operation MODEL:path MODEL:baseline
     ^ARENA:arena -- )
   {: j op path b ar :}
   j op OPERATION-ID b OPTION:SOME ar JOURNAL:COMPLETE-OPERATION
   FINAL-DONE? if exit then
   path REJECTED-FINAL ;

: SUPERSEDE-IF-EXCLUDED
   ( JOURNAL:journal JOURNAL:plan-record ^ARENA:arena -- )
   {: j p ar :}
   p PLAN-PATH MODEL:EXCLUDED? 0= if exit then
   j p ar SUPERSEDE-PLAN ;

\ The plan at, kept at index w unless excluded; the next free index.
: KEPT ( ^VEC:vector<JOURNAL:plan-record> n n -- n )
   {: plans at w :}
   plans at VEC:AT @ {: p :}
   p PLAN-PATH MODEL:EXCLUDED? if w exit then
   p plans w VEC:AT !
   w 1+ ;

public

\ Supersedes each excluded plan, then removes it from plans, the rest
\ kept in order; neither tree changes.
: RETIRE-EXCLUDED-PLANS
   ( JOURNAL:journal ^VEC:vector<JOURNAL:plan-record> ^ARENA:arena -- )
   {: j plans ar :}
   plans VEC:COUNT 0 ?do
      j plans i VEC:AT @ ar SUPERSEDE-IF-EXCLUDED
   loop
   0 plans VEC:COUNT 0 ?do plans i rot KEPT loop
   plans swap VEC:RESIZE ;


\ ---- local conflict copies ------------------------------------------

private

\ Closes a descriptor; as Rust's drop of a File, it ignores close's own
\ failure.
: DISCARD ( fd -- ) FD>N close ;

\ The span filled from the open upload, or the bytes before its end.
: UPLOAD-READ ( fd ^u8 n -- n )
   {: f:fd p:^ u:n :}
   f p u SPAN:MAKE FD:READ-EXACT MATCH FD:fill
      full OF u ENDOF
      eof OF ENDOF
   ;MATCH ;

: COPY-OCCUPIED ( -- copy-outcome )
   MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED REPLAY-COPY--OUTCOME:BLOCKED ;
: DROP-COPY ( copy-outcome -- ) drop ;

: >COPY-OUTCOME ( LOCAL:conflict-outcome -- copy-outcome )
   MATCH LOCAL:conflict-outcome
      created OF drop REPLAY-COPY--OUTCOME:READY ENDOF
      already-present OF drop REPLAY-COPY--OUTCOME:READY ENDOF
      content-changed OF
         drop REPLAY-COPY--OUTCOME:SOURCE-CHANGED
      ENDOF
   ;MATCH ;

\ Rust's copy_name_occupied. Writing a conflict copy, LOCAL throws these
\ only for the entry at the copy's own name: a directory, symlink or
\ special file, or a file Omabox cannot read.
: COPY-NAME-OCCUPIED? ( n -- bool )
   {: code:n :}
   code LOCAL:E-UNSUPPORTED = code LOCAL:E-UNREADABLE = or ;

\ Whether a failed copy found its name held: by other bytes, or by an
\ entry Omabox cannot replace.
: OCCUPIED? ( n -- bool )
   {: code:n :}
   code LOCAL:E-OCCUPIED = if true exit then
   code COPY-NAME-OCCUPIED? ;

\ The upload's bytes, read from f, written as path's local conflict copy.
: WRITE-COPY
   ( fd ^u8 n MODEL:path ^LOCAL:staged-upload fd ^ARENA:arena
     -- LOCAL:conflict-outcome )
   {: root:fd r:^ ru:n path:MODEL:path up:^LOCAL:staged-upload f:fd
      ar:^ARENA:arena :}
   root r ru path MODEL:PATH>STR str> LOCAL-CONFLICT--SIDE:LOCAL
   up LOCAL:UPLOAD-CONTENT [: f -rot UPLOAD-READ ;] ar
   LOCAL:MATERIALIZE-CONFLICT-AT ;

\ An occupied copy name blocks the copy; another failure passes up.
: COPY-IN
   ( fd ^u8 n MODEL:path ^LOCAL:staged-upload fd ^ARENA:arena
     -- copy-outcome )
   {: root:fd r:^ ru:n path:MODEL:path up:^LOCAL:staged-upload f:fd
      ar:^ARENA:arena :}
   COPY-OCCUPIED [: DROP-COPY root r ru path up f ar WRITE-COPY
      >COPY-OUTCOME ;] catch {: code:n :}
   code 0= if exit then
   drop code OCCUPIED? if COPY-OCCUPIED exit then
   code throw ;

\ COPY-IN from the verified upload, which closes after it.
: COPY-FROM-UPLOAD
   ( fd ^u8 n MODEL:path ^LOCAL:staged-upload ^ARENA:arena
     -- copy-outcome )
   {: root:fd r:^ ru:n path:MODEL:path up:^LOCAL:staged-upload
      ar:^ARENA:arena :}
   up ar LOCAL:OPEN-VERIFIED-UPLOAD {: f:fd :}
   [: root r ru path up f ar COPY-IN ;] [: f DISCARD ;] finally ;

public

\ Writes the staged upload as path's local conflict copy below the sync
\ root, whose absolute path is r; it never overwrites a file.
: MATERIALIZE-LOCAL-CONFLICT
   ( ^u8 n MODEL:path ^LOCAL:staged-upload ^ARENA:arena
     -- copy-outcome )
   {: r:^ ru:n path:MODEL:path up:^LOCAL:staged-upload
      ar:^ARENA:arena :}
   r ru s" open sync root for local conflict" LOCAL:OPEN-ROOT
   {: root:fd :}
   [: root r ru path up ar COPY-FROM-UPLOAD ;] [: root DISCARD ;]
   finally ;

;package
