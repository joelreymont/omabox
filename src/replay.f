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
require src/lib/fs.f
require src/lib/fsm.f
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


\ ---- local replay

private

\ A pass's local replay, LOCAL-LIFECYCLE's context: the journal,
\ the root's descriptor and path, and the arena; the plan and the
\ operation it runs; the final completions and the report it adds
\ to; and blocked, why the apply step stopped the plan.
STRUCTURE local-run DERIVE addr
   FIELD journal JOURNAL:journal
   FIELD root fd
   FIELD root-path str
   FIELD plan JOURNAL:plan-record
   FIELD operation JOURNAL:planned-operation
   FIELD finals ^VEC:vector<final-completion>
   FIELD report ^replay-report
   FIELD arena ^ARENA:arena
   FIELD blocked replay-blocked
;STRUCTURE

ARENA LOCAL-RUNS local-run

ENUM local-state DERIVE eq
   recorded applying passed stopped ;ENUM
ENUM apply-event done blocked ;ENUM

: PLAN-OPERATIONS
   ( JOURNAL:plan-record
     -- ^VEC:vector<JOURNAL:planned-operation> )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} o ;

: RUN-PATH ( ^local-run -- MODEL:path )
   LOCAL-RUN-PLAN @ PLAN-PATH ;

: RUN-TARGET ( ^local-run -- ^u8 n )
   RUN-PATH MODEL:PATH>STR str> ;

\ The root's descriptor and path.
: RUN-ROOT ( ^local-run -- fd ^u8 n )
   {: r :}
   r LOCAL-RUN-ROOT @ r LOCAL-RUN-ROOT-PATH @ str> ;

: RUN-OPERATION ( ^local-run -- MODEL:operation )
   LOCAL-RUN-OPERATION @
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :} o ;

: NEW-RUN
   ( JOURNAL:journal fd ^u8 n ^ARENA:arena -- ^local-run )
   {: j root:fd p:^ u:n ar :}
   ar LOCAL-RUNS-NEW {: r :}
   j r LOCAL-RUN-JOURNAL ! root r LOCAL-RUN-ROOT !
   p u >str r LOCAL-RUN-ROOT-PATH ! ar r LOCAL-RUN-ARENA !
   ar ARENA:ALLOCATOR 0 [type] final-completion VEC:NEW
   r LOCAL-RUN-FINALS !
   ar NEW-REPORT r LOCAL-RUN-REPORT !
   r ;


\ ---- apply outcomes

: COUNTED ( n ^local-run -- )
   LOCAL-RUN-REPORT @
   REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS +! ;

: BLOCKED ( replay-blocked ^local-run -- apply-event )
   LOCAL-RUN-BLOCKED ! construct apply-event blocked ;

\ The operation completes with the pass's others, writing b.
: FINAL ( MODEL:baseline ^local-run -- apply-event )
   {: b r :}
   r LOCAL-RUN-OPERATION @ OPERATION-ID r RUN-PATH b
   FINAL-COMPLETION-MAKE r LOCAL-RUN-FINALS @ VEC:PUSH !
   construct apply-event done ;

\ The plan is retired; a fresh scan observes its path again.
: STALE ( ^local-run -- apply-event )
   {: r :}
   r LOCAL-RUN-JOURNAL @ r LOCAL-RUN-PLAN @
   r LOCAL-RUN-ARENA @ SUPERSEDE-PLAN
   r RUN-PATH REPLAY-REPLAY--BLOCKED:FRESH-OBSERVATION-REQUIRED
   r BLOCKED ;

\ Rust's local_object_blocks_replay: an object at the path that
\ replay cannot act on blocks the plan; any other failure passes up.
: LOCAL-OBJECT? ( n -- bool )
   {: code:n :}
   code LOCAL:E-UNSUPPORTED = if true exit then
   code LOCAL:E-IO <> if false exit then
   FS:ERRNO {: e:n :}
   e FS:ELOOP = e FS:ENOTDIR = or ;

: LOCAL-OBJECT ( ^local-run n -- apply-event )
   {: r code:n :}
   code LOCAL-OBJECT? 0= if code throw then
   r RUN-PATH REPLAY-REPLAY--BLOCKED:LOCAL-OBJECT r BLOCKED ;

: REMOTE ( ^local-run -- apply-event )
   {: r :}
   r RUN-PATH REPLAY-REPLAY--BLOCKED:REMOTE-OPERATION
   r BLOCKED ;


\ ---- apply steps

\ A catch's quotation keeps its input's type: each drops the
\ outcome it is given to answer its own.
: DROP-MADE ( LOCAL:create-directory-outcome -- ) drop ;
: DROP-REMOVED ( LOCAL:delete-directory-outcome -- ) drop ;
: DROP-INSTALLED ( LOCAL:install-outcome -- ) drop ;
: DROP-DELETED ( LOCAL:delete-outcome -- ) drop ;

: MADE
   ( LOCAL:create-directory-outcome ^local-run -- apply-event )
   {: r :}
   MATCH LOCAL:create-directory-outcome
      created OF MODEL-BASELINE:DIRECTORY r FINAL ENDOF
      already-present OF MODEL-BASELINE:DIRECTORY r FINAL ENDOF
      fresh-observation OF r STALE ENDOF
   ;MATCH ;

: CREATE-DIRECTORY ( ^local-run -- apply-event )
   {: r :}
   LOCAL-CREATE--DIRECTORY--OUTCOME:CREATED
   [: DROP-MADE r LOCAL-RUN-ROOT @ r RUN-TARGET
      LOCAL:CREATE-DIRECTORY-AT ;] catch {: code:n :}
   code 0= if r MADE exit then
   drop r code LOCAL-OBJECT ;

: REMOVED
   ( LOCAL:delete-directory-outcome ^local-run -- apply-event )
   {: r :}
   MATCH LOCAL:delete-directory-outcome
      deleted OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      already-absent OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      fresh-observation OF r STALE ENDOF
   ;MATCH ;

: DELETE-DIRECTORY ( ^local-run -- apply-event )
   {: r :}
   LOCAL-DELETE--DIRECTORY--OUTCOME:DELETED
   [: DROP-REMOVED r LOCAL-RUN-ROOT @ r RUN-TARGET
      LOCAL:DELETE-DIRECTORY-AT ;] catch {: code:n :}
   code 0= if r REMOVED exit then
   drop r code LOCAL-OBJECT ;

: CHANGED ( option<DROPBOX:hash> ^local-run -- apply-event )
   {: actual r :}
   r RUN-PATH actual REPLAY-REPLAY--BLOCKED:PRECONDITION-CHANGED
   r BLOCKED ;

: PRESENT ( MODEL:remote ^local-run -- apply-event )
   swap MODEL-BASELINE:PRESENT swap FINAL ;

: OCCUPIED ( JOURNAL:plan-id str ^local-run -- apply-event )
   {: id p:str r :}
   id p REPLAY-REPLAY--BLOCKED:STAGE-DESTINATION-OCCUPIED
   r BLOCKED ;

\ What installing src came to.
: INSTALLED
   ( LOCAL:install-outcome MODEL:remote ^local-run
     -- apply-event )
   {: src r :}
   MATCH LOCAL:install-outcome
      installed OF src r PRESENT ENDOF
      already-installed OF src r PRESENT ENDOF
      download-required OF
         r RUN-PATH src MODEL-REMOTE:UNMAKE {: c v :} c
         REPLAY-REPLAY--BLOCKED:DOWNLOAD-REQUIRED r BLOCKED
      ENDOF
      stage-destination-occupied OF {: p:str :}
         r LOCAL-RUN-PLAN @ PLAN-ID p r OCCUPIED
      ENDOF
      precondition-changed OF r CHANGED ENDOF
   ;MATCH ;

\ Installs src's verified download while the target holds
\ expected, or is absent when expected is none.
: INSTALL
   ( MODEL:remote option<DROPBOX:hash> ^local-run -- apply-event )
   {: src expected r :}
   src MODEL-REMOTE:UNMAKE {: want v :}
   LOCAL-INSTALL--OUTCOME:INSTALLED
   [: DROP-INSTALLED r RUN-ROOT r RUN-TARGET want expected
      r LOCAL-RUN-ARENA @ LOCAL:INSTALL-DOWNLOAD-AT ;]
   catch {: code:n :}
   code 0= if src r INSTALLED exit then
   drop r code LOCAL-OBJECT ;

: DELETED ( LOCAL:delete-outcome ^local-run -- apply-event )
   {: r :}
   MATCH LOCAL:delete-outcome
      deleted OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      already-deleted OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      precondition-changed OF r CHANGED ENDOF
   ;MATCH ;

: DELETE-FILE ( DROPBOX:hash ^local-run -- apply-event )
   {: want r :}
   LOCAL-DELETE--OUTCOME:DELETED
   [: DROP-DELETED r RUN-ROOT r RUN-TARGET want
      r LOCAL-RUN-ARENA @ LOCAL:DELETE-LOCAL-AT ;]
   catch {: code:n :}
   code 0= if r DELETED exit then
   drop r code LOCAL-OBJECT ;

\ A preservation completes at once and leaves the plan pending.
: PRESERVE ( ^local-run -- apply-event )
   {: r :}
   r LOCAL-RUN-JOURNAL @ r LOCAL-RUN-OPERATION @ r RUN-PATH
   r LOCAL-RUN-ARENA @ COMPLETE-NONFINAL
   1 r COUNTED construct apply-event done ;

: NO-CONTENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;

\ The apply step of the run's operation; a remote one blocks.
: APPLY ( ^local-run -- apply-event )
   {: r :}
   r RUN-OPERATION MATCH MODEL:operation
      create-local-directory OF r CREATE-DIRECTORY ENDOF
      delete-local-directory OF r DELETE-DIRECTORY ENDOF
      install-local OF NO-CONTENT r INSTALL ENDOF
      replace-local OF OPTION:SOME r INSTALL ENDOF
      delete-local OF r DELETE-FILE ENDOF
      preserve-local OF drop r PRESERVE ENDOF
      create-remote-directory OF r REMOTE ENDOF
      delete-remote-directory OF r REMOTE ENDOF
      create-remote OF drop r REMOTE ENDOF
      preserve-remote OF drop r REMOTE ENDOF
      replace-remote OF drop drop r REMOTE ENDOF
      delete-remote OF drop r REMOTE ENDOF
   ;MATCH ;

: STATUS ( ^local-run -- JOURNAL:record-status )
   LOCAL-RUN-OPERATION @
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :} s ;

\ The block goes in the report; the plan's later operations wait.
: STOP ( ^local-run -- )
   {: r :}
   r LOCAL-RUN-REPORT @ REPLAY-REPLAY--REPORT:BLOCKED @ {: v :}
   r LOCAL-RUN-BLOCKED @ v VEC:PUSH ! ;


\ ---- the operation's machine

\ One local operation's replay, after formal/MutationLifecycle.tla:
\ a completed operation passes; a pending one is applied, and passes
\ or stops its plan.
FSM:DEFINE LOCAL-LIFECYCLE ( ^local-run ) local-state apply-event
   IN recorded  STATUS ( JOURNAL:record-status )
      completed  -  >passed
      pending    -  >applying
   IN applying  APPLY
      done     -  >passed
      blocked  -  >stopped
   FINAL passed   -
   FINAL stopped  STOP
;DEFINE

\ Runs the machine on r's operation; answers its final state.
: LIFECYCLE ( ^local-run -- local-state )
   {: r :}
   construct local-state recorded
   begin r swap LOCAL-LIFECYCLE-STEP until ;

: STOPPED? ( local-state -- bool )
   construct local-state stopped LOCAL-STATE-EQ ;

\ An excluded plan is retired; another's operations run in order
\ until one stops it.
: REPLAY-PLAN ( JOURNAL:plan-record ^local-run -- )
   {: p r :}
   p r LOCAL-RUN-PLAN !
   p PLAN-PATH MODEL:EXCLUDED? if
      r LOCAL-RUN-JOURNAL @ p r LOCAL-RUN-ARENA @ SUPERSEDE-PLAN
      exit
   then
   p PLAN-OPERATIONS {: ops :}
   ops VEC:COUNT 0 ?do
      ops i VEC:AT @ r LOCAL-RUN-OPERATION !
      r LIFECYCLE STOPPED? if leave then
   loop ;

\ Commits the pass's final completions and counts them.
: COMMIT-RUN ( ^local-run -- )
   {: r :}
   r LOCAL-RUN-FINALS @ {: finals :}
   r LOCAL-RUN-JOURNAL @ finals r LOCAL-RUN-ARENA @
   COMMIT-FINAL-COMPLETIONS
   finals VEC:COUNT r COUNTED ;

public

\ Replays the plans' local operations in order below the root's
\ descriptor, whose path is r; the final completions commit
\ together once every plan has run.
: REPLAY-LOCAL-PLANS-AT
   ( JOURNAL:journal fd ^u8 n ^VEC:vector<JOURNAL:plan-record>
     ^ARENA:arena -- ^replay-report )
   {: j root:fd r:^ ru:n plans ar :}
   j root r ru ar NEW-RUN {: run :}
   plans VEC:COUNT 0 ?do plans i VEC:AT @ run REPLAY-PLAN loop
   run COMMIT-RUN
   run LOCAL-RUN-REPORT @ ;

;package
