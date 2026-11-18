\ replay.f - package REPLAY: the pending plans' replay (rust
\ src/recovery.rs): what a replay pass reports, the outcomes its steps
\ answer, the journal steps that finish, supersede or complete a plan,
\ the replay of the plans' local operations, a staged upload's local
\ conflict copy, the bridge that stages a Dropbox revision's bytes
\ through LOCAL, a revision's exact copy and remote conflict copy, the
\ retention of legacy recovery payloads, each Dropbox mutation's
\ outcome, and the remote replay that records it. A LOCAL call
\ whose failures REPLAY converts into outcomes runs under
\ LOCAL:CONVERTING, so nothing logs those; any other LOCAL, JOURNAL or
\ DROPBOX failure passes up with its own code, which that library
\ logged where it saw it. A mutation Dropbox rejects for its path is
\ logged once with its tag, and a download blocked for its path once
\ with its reason. A Dropbox answer that ends the pass, not one path's
\ verdict, is kept in the link and thrown as E-DROPBOX. A journal
\ answer the replay contract refuses is logged once with the Rust
\ version's text, naming the plan's path, then thrown as
\ E-INVALID-STATE. A failed retention or upload-stage syscall is logged
\ once, by LOCAL, and thrown as LOCAL's E-IO, or E-DISK-FULL on ENOSPC.
\ STORAGE CLASS. No state of its own. CALLER-OWNED: a report, its
\ vector, a replay pass's context, a download's bridge, and every value
\ a journal step or a conflict copy reads lie in the arena the caller
\ passes. A retention pass lays its values in an arena of its own.
\ Retention, the conflict copies, an upload and the bridge close every
\ descriptor they open, on every exit.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/utf8-scalar.f
require src/lib/arena.f
require src/lib/memory.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/vector.f
require src/lib/fs.f
require src/lib/fs-anchored.f
require src/lib/fd.f
require src/lib/fsm.f
require src/lib/time.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/local.f
require src/status.f

package REPLAY
public

-100700 constant E-FIRST
-100799 constant E-LAST
-100700 s" journaled recovery state is invalid"
   ERROR:CODE E-INVALID-STATE
-100701 s" a Dropbox answer ended the replay"
   ERROR:CODE E-DROPBOX

\ How a pass reaches Dropbox: root is the binding's remote root, status
\ takes the transfers; reply holds the answer E-DROPBOX was thrown for.
STRUCTURE link DERIVE addr
   FIELD client ^DROPBOX:client
   FIELD root str
   FIELD status ^STATUS:status
   FIELD reply DROPBOX:reply
;STRUCTURE

\ Ends the pass on a Dropbox answer that is not one path's verdict.
: STOP-PASS ( DROPBOX:reply ^link -- ) REPLAY-LINK:REPLY ! E-DROPBOX throw ;

\ destination-changed: the chosen path changed after it was observed;
\ stage-occupied: other bytes hold its download stage;
\ content-changed: the downloaded bytes did not verify;
\ blocked: Dropbox's answer blocks the download for its path.
ENUM exact-copy-outcome
   VARIANT ready ;VARIANT
   VARIANT destination-changed ;VARIANT
   VARIANT stage-occupied ;VARIANT
   VARIANT content-changed ;VARIANT
   VARIANT blocked FIELD reason MODEL:blockage ;VARIANT
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
   permission-denied insufficient-space operation-not-allowed
   path-mismatch rejected-by-dropbox content-hash-mismatch
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


\ ---- recovery retention --------------------------------------------

public

\ How long a completed legacy recovery payload stays, in seconds.
30 24 * 60 * 60 * constant COMPLETED-RECOVERY-RETENTION

private

\ What statat says of a retained payload's entry.
STRUCTURE stat
   FIELD dev n
   FIELD inode n
   FIELD mode n
;STRUCTURE

\ One retention pass: the journal, the open recovery directory and
\ its path, the time it prunes at, in seconds since the epoch, and
\ the arena its values lie in.
STRUCTURE retention
   FIELD journal JOURNAL:journal
   FIELD dir fd
   FIELD path str
   FIELD now n
   FIELD arena ^ARENA:arena
;STRUCTURE

: NO-STAT ( -- option<stat> ) OPTION:NONE ;

: JOURNAL-OF ( retention -- JOURNAL:journal )
   RETENTION-UNMAKE {: j dir d now ar :} j ;
: DIR-OF ( retention -- fd )
   RETENTION-UNMAKE {: j dir d now ar :} dir ;
: PATH-OF ( retention -- str )
   RETENTION-UNMAKE {: j dir d now ar :} d ;
: NOW-OF ( retention -- n )
   RETENTION-UNMAKE {: j dir d now ar :} now ;
: ARENA-OF ( retention -- ^ARENA:arena )
   RETENTION-UNMAKE {: j dir d now ar :} ar ;

: RECORD-ID ( JOURNAL:recovery-record -- JOURNAL:recovery-id )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :} id ;
: ORIGINAL ( JOURNAL:recovery-record -- MODEL:path )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :} p ;
: COPY-PATH ( JOURNAL:recovery-record -- MODEL:path )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :} q ;
: CONTENT ( JOURNAL:recovery-record -- DROPBOX:hash )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :} c ;
: RETAINED ( JOURNAL:recovery-record -- option<n> )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :} at ;

\ Closes a descriptor; as Rust's drop of an OwnedFd or a File, it
\ ignores close's own failure.
: DISCARD ( fd -- ) FD>N close ;

: SYNC-DIRECTORY ( fd str -- )
   {: dir:fd d:str :}
   [: dir FD:SYNC ;] catch {: code:n :}
   code 0= if exit then
   code E-FS-IO <> if code throw then
   s" sync recovery retention" d str> LOCAL:IO-FAILURE ;

\ statat of the name, never a symlink's target; none once it is gone.
\ o names the operation, p the payload's path.
: STAT-AT ( fd ^u8 n ^u8 n MODEL:path -- option<stat> )
   {: dir:fd nm:^ nu:n o:^ ou:n p :}
   dir nm nu FS:TRY-STAT-AT if
      FS:STAT-DEV@ FS:STAT-INO@ FS:STAT-MODE@ STAT-MAKE OPTION:SOME
      exit
   then
   FS:ERRNO FS:ENOENT = if NO-STAT exit then
   o ou p MODEL:PATH>STR str> LOCAL:IO-FAILURE ;

: REGULAR? ( stat -- bool )
   STAT-UNMAKE {: d i m :}
   m FS:S-IFMT and FS:S-IFREG = ;

: SAME-INODE? ( stat stat -- bool )
   {: a b :}
   a STAT-UNMAKE {: d i m :}
   b STAT-UNMAKE {: d2 i2 m2 :}
   d d2 = i i2 = and ;

\ Retention started COMPLETED-RECOVERY-RETENTION seconds or more
\ before now; never for a record whose retention has not started.
: EXPIRED? ( option<n> n -- bool )
   {: at:option<n> now:n :}
   at MATCH option
      none OF false ENDOF
      some OF {: t:n :}
         now t >= now t - COMPLETED-RECOVERY-RETENTION >= and
      ENDOF
   ;MATCH ;

\ Rust's Path equality: each path's components begin the other's.
: SAME-PATH? ( MODEL:path MODEL:path -- bool )
   {: a b :}
   a b MODEL:BEGINS? b a MODEL:BEGINS? and ;

\ The directory then the name as PathBuf::push joins them: no "/"
\ after an empty directory or one that ends in "/".
: JOINED ( ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: d:^ du:n nm:^ nu:n ar :}
   du 0= d du >str FS:JOIN-SEPARATED? or if 0 else 1 then {: sep:n :}
   ar du sep + nu + ARENA:ALLOC {: dst:^ size:n :}
   d dst du BYTE-COPY
   sep 0<> if $2F dst du + c! then
   nm dst du + sep + nu BYTE-COPY
   dst size ;

\ Rust's destination: where the recovery directory d keeps the copy of
\ the original path holding c.
: DESTINATION
   ( ^u8 n MODEL:path DROPBOX:hash ^ARENA:arena -- MODEL:path )
   {: d:^ du:n original c ar :}
   original MODEL:PATH>STR str> c ar LOCAL:RECOVERY-FILE-NAME
   {: nm:^ nu:n :}
   d du nm nu ar JOINED >str MODEL:>PATH ;

: BECAME-PENDING ( MODEL:path -- )
   s" completed recovery became pending during retention" INVALID ;

\ 1 once the record is forgotten, 0 when it was gone.
: FORGET-RECOVERY ( JOURNAL:journal JOURNAL:recovery-record -- n )
   {: j r :}
   j r RECORD-ID JOURNAL:FORGET-COMPLETED-RECOVERY
   MATCH JOURNAL:recovery-forget
      forgotten OF 1 ENDOF
      not-found OF 0 ENDOF
      pending OF r ORIGINAL BECAME-PENDING ENDOF
   ;MATCH ;

\ Forgets the record once the directory's entries are on disk, so an
\ interrupted pass retries the same cleanup.
: SYNC-THEN-FORGET ( retention JOURNAL:recovery-record -- n )
   {: x r :}
   x DIR-OF x PATH-OF SYNC-DIRECTORY
   x JOURNAL-OF r FORGET-RECOVERY ;

\ VERIFY-PRIVATE-COPY's failures that keep the payload where it is,
\ by code alone.
: KEEPS? ( n n -- bool )
   {: code:n e:n :}
   code LOCAL:E-CORRUPT = code LOCAL:E-UNSUPPORTED = or
   code LOCAL:E-CHANGED = or code LOCAL:E-OCCUPIED = or
   code LOCAL:E-CONTENT-HASH = or code LOCAL:E-UNSAFE-PATH = or
   code LOCAL:E-UNREADABLE = or ;

\ Whether the payload at the name holds the record's content.
: VERIFY ( retention JOURNAL:recovery-record ^u8 n -- bool )
   {: x r nm:^ nu:n :}
   x DIR-OF x PATH-OF str> nm nu r CONTENT x ARENA-OF
   LOCAL:VERIFY-PRIVATE-COPY ;

\ Removes the payload, gone already or not, then forgets the record.
: REMOVE-PAYLOAD ( retention JOURNAL:recovery-record ^u8 n -- n )
   {: x r nm:^ nu:n :}
   x DIR-OF nm nu FS:TRY-REMOVE-FILE-AT 0= if
      FS:ERRNO FS:ENOENT <> if
         x DIR-OF nm nu s" remove expired recovery payload"
         r COPY-PATH MODEL:PATH>STR str> LOCAL:IO-FAILURE-AT
      then
   then
   x r SYNC-THEN-FORGET ;

\ The verified payload, removed while it is the file inspected before.
: REINSPECT ( retention JOURNAL:recovery-record ^u8 n stat -- n )
   {: x r nm:^ nu:n before :}
   x DIR-OF nm nu s" reinspect retained recovery payload" r COPY-PATH
   STAT-AT MATCH option
      none OF x r SYNC-THEN-FORGET ENDOF
      some OF {: after :}
         after REGULAR? before after SAME-INODE? and
         if x r nm nu REMOVE-PAYLOAD else 0 then
      ENDOF
   ;MATCH ;

\ The expired payload: forgotten when gone, removed when verified,
\ kept on a failure that concerns it alone.
: CHECKED ( retention JOURNAL:recovery-record ^u8 n stat -- n )
   {: x r nm:^ nu:n before :}
   false [: drop x r nm nu VERIFY ;]
   ['] KEEPS? LOCAL:CONVERTING {: code:n :}
   code 0= if
      if x r nm nu before REINSPECT exit then
      x r SYNC-THEN-FORGET exit
   then
   drop code FS:ERRNO KEEPS? if 0 exit then
   code throw ;

\ The payload at the name: forgotten when gone, kept when it is not a
\ regular file or its retention has not run out.
: INSPECT ( retention JOURNAL:recovery-record ^u8 n -- n )
   {: x r nm:^ nu:n :}
   x DIR-OF nm nu s" inspect retained recovery payload" r COPY-PATH
   STAT-AT MATCH option
      none OF x r SYNC-THEN-FORGET ENDOF
      some OF {: before :}
         before REGULAR? r RETAINED x NOW-OF EXPIRED? and
         if x r nm nu before CHECKED else 0 then
      ENDOF
   ;MATCH ;

\ One record, whose payload lies where this directory keeps it or not
\ at all.
: PRUNE ( retention JOURNAL:recovery-record -- n )
   {: x r :}
   x PATH-OF str> r ORIGINAL r CONTENT x ARENA-OF DESTINATION
   r COPY-PATH SAME-PATH? 0= if 0 exit then
   r ORIGINAL MODEL:PATH>STR str> r CONTENT x ARENA-OF
   LOCAL:RECOVERY-FILE-NAME {: nm:^ nu:n :}
   x r nm nu INSPECT ;

: PRUNE-ALL ( retention -- n )
   {: x :}
   x JOURNAL-OF x ARENA-OF JOURNAL:COMPLETED-RECOVERIES {: records :}
   0 records VEC:COUNT 0 ?do x records i VEC:AT @ PRUNE + loop ;

\ Prunes from the recovery directory at d, which it opens and closes.
: RETAINING ( ^ARENA:arena JOURNAL:journal ^u8 n n -- n )
   {: ar j d:^ du:n now:n :}
   d du s" open recovery directory for retention"
   LOCAL:OPEN-PRIVATE-DIRECTORY {: dir:fd :}
   j dir d du >str now ar RETENTION-MAKE {: x :}
   [: x PRUNE-ALL ;] [: dir DISCARD ;] finally ;

\ PRUNE-COMPLETED-RECOVERIES at now, in seconds since the epoch.
: PRUNE-COMPLETED-RECOVERIES-AT ( JOURNAL:journal ^u8 n n -- n )
   {: j d:^ du:n now:n :}
   [: j d du now RETAINING ;] ARENA:WITH ;

public

\ Removes the expired legacy recovery payloads in the directory at d
\ that no unfinished journal work can need and forgets their records,
\ answering how many it forgot. Unknown entries and payloads that are
\ not a verified regular file stay.
: PRUNE-COMPLETED-RECOVERIES ( JOURNAL:journal ^u8 n -- n )
   epoch-seconds PRUNE-COMPLETED-RECOVERIES-AT ;


\ ---- local replay

private

\ A replay pass, both lifecycles' context; blocked is why the apply step
\ stopped the plan. Local replay leaves link and staging unset, unread.
STRUCTURE pass DERIVE addr
   FIELD journal JOURNAL:journal
   FIELD root fd
   FIELD root-path str
   FIELD plan JOURNAL:plan-record
   FIELD operation JOURNAL:planned-operation
   FIELD finals ^VEC:vector<final-completion>
   FIELD report ^replay-report
   FIELD arena ^ARENA:arena
   FIELD blocked replay-blocked
   FIELD link ^link
   FIELD staging str
;STRUCTURE

ARENA PASSES pass

ENUM local-state DERIVE eq
   recorded applying passed stopped ;ENUM
ENUM apply-event done blocked ;ENUM

: PLAN-OPERATIONS
   ( JOURNAL:plan-record
     -- ^VEC:vector<JOURNAL:planned-operation> )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} o ;

: RUN-PATH ( ^pass -- MODEL:path )
   PASS-PLAN @ PLAN-PATH ;

: RUN-TARGET ( ^pass -- ^u8 n )
   RUN-PATH MODEL:PATH>STR str> ;

\ The root's descriptor and path.
: RUN-ROOT ( ^pass -- fd ^u8 n )
   {: r :}
   r PASS-ROOT @ r PASS-ROOT-PATH @ str> ;

: RUN-OPERATION ( ^pass -- MODEL:operation )
   PASS-OPERATION @
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :} o ;

: NEW-PASS
   ( JOURNAL:journal fd ^u8 n ^ARENA:arena -- ^pass )
   {: j root:fd p:^ u:n ar :}
   ar PASSES-NEW {: r :}
   j r PASS-JOURNAL ! root r PASS-ROOT !
   p u >str r PASS-ROOT-PATH ! ar r PASS-ARENA !
   ar ARENA:ALLOCATOR 0 [type] final-completion VEC:NEW
   r PASS-FINALS !
   ar NEW-REPORT r PASS-REPORT !
   r ;


\ ---- apply outcomes

: COUNTED ( n ^pass -- )
   PASS-REPORT @
   REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS +! ;

: REMOTE-DONE ( ^pass -- )
   PASS-LINK @ REPLAY-LINK:STATUS @ STATUS:COMPLETED ;

: BLOCKED ( replay-blocked ^pass -- apply-event )
   PASS-BLOCKED ! construct apply-event blocked ;

\ The operation completes with the pass's others, writing b.
: FINAL ( MODEL:baseline ^pass -- apply-event )
   {: b r :}
   r PASS-OPERATION @ OPERATION-ID r RUN-PATH b
   FINAL-COMPLETION-MAKE r PASS-FINALS @ VEC:PUSH !
   construct apply-event done ;

\ The plan is retired; a fresh scan observes its path again.
: SUPERSEDED ( ^pass -- replay-blocked )
   {: r :}
   r PASS-JOURNAL @ r PASS-PLAN @
   r PASS-ARENA @ SUPERSEDE-PLAN
   r RUN-PATH REPLAY-REPLAY--BLOCKED:FRESH-OBSERVATION-REQUIRED ;

: STALE ( ^pass -- apply-event )
   {: r :}
   r SUPERSEDED r BLOCKED ;

public

\ Rust's local_object_blocks_replay, of a code and its errno: an object
\ at the path that replay cannot act on blocks the plan; any other
\ failure passes up.
: LOCAL-OBJECT? ( n n -- bool )
   {: code:n e:n :}
   code LOCAL:E-UNSUPPORTED = if true exit then
   code LOCAL:E-IO <> if false exit then
   e FS:ELOOP = e FS:ENOTDIR = or ;

private

: LOCAL-OBJECT ( ^pass n -- apply-event )
   {: r code:n :}
   code FS:ERRNO LOCAL-OBJECT? 0= if code throw then
   r RUN-PATH REPLAY-REPLAY--BLOCKED:LOCAL-OBJECT r BLOCKED ;

: REMOTE ( ^pass -- apply-event )
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
   ( LOCAL:create-directory-outcome ^pass -- apply-event )
   {: r :}
   MATCH LOCAL:create-directory-outcome
      created OF MODEL-BASELINE:DIRECTORY r FINAL ENDOF
      already-present OF MODEL-BASELINE:DIRECTORY r FINAL ENDOF
      fresh-observation OF r STALE ENDOF
   ;MATCH ;

: CREATE-DIRECTORY ( ^pass -- apply-event )
   {: r :}
   LOCAL-CREATE--DIRECTORY--OUTCOME:CREATED
   [: DROP-MADE r PASS-ROOT @ r RUN-TARGET
      LOCAL:CREATE-DIRECTORY-AT ;]
   ['] LOCAL-OBJECT? LOCAL:CONVERTING {: code:n :}
   code 0= if r MADE exit then
   drop r code LOCAL-OBJECT ;

: REMOVED
   ( LOCAL:delete-directory-outcome ^pass -- apply-event )
   {: r :}
   MATCH LOCAL:delete-directory-outcome
      deleted OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      already-absent OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      fresh-observation OF r STALE ENDOF
   ;MATCH ;

: DELETE-DIRECTORY ( ^pass -- apply-event )
   {: r :}
   LOCAL-DELETE--DIRECTORY--OUTCOME:DELETED
   [: DROP-REMOVED r PASS-ROOT @ r RUN-TARGET
      LOCAL:DELETE-DIRECTORY-AT ;]
   ['] LOCAL-OBJECT? LOCAL:CONVERTING {: code:n :}
   code 0= if r REMOVED exit then
   drop r code LOCAL-OBJECT ;

: CHANGED ( option<DROPBOX:hash> ^pass -- apply-event )
   {: actual r :}
   r RUN-PATH actual REPLAY-REPLAY--BLOCKED:PRECONDITION-CHANGED
   r BLOCKED ;

: PRESENT ( MODEL:remote ^pass -- apply-event )
   swap MODEL-BASELINE:PRESENT swap FINAL ;

: STAGE-OCCUPIED ( JOURNAL:plan-id str ^pass -- apply-event )
   {: id p:str r :}
   id p REPLAY-REPLAY--BLOCKED:STAGE-DESTINATION-OCCUPIED
   r BLOCKED ;

\ What installing src came to.
: INSTALLED
   ( LOCAL:install-outcome MODEL:remote ^pass
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
         r PASS-PLAN @ PLAN-ID p r STAGE-OCCUPIED
      ENDOF
      precondition-changed OF r CHANGED ENDOF
   ;MATCH ;

\ Installs src's verified download while the target holds
\ expected, or is absent when expected is none.
: INSTALL
   ( MODEL:remote option<DROPBOX:hash> ^pass -- apply-event )
   {: src expected r :}
   src MODEL-REMOTE:UNMAKE {: want v :}
   LOCAL-INSTALL--OUTCOME:INSTALLED
   [: DROP-INSTALLED r RUN-ROOT r RUN-TARGET want expected
      r PASS-ARENA @ LOCAL:INSTALL-DOWNLOAD-AT ;]
   ['] LOCAL-OBJECT? LOCAL:CONVERTING {: code:n :}
   code 0= if src r INSTALLED exit then
   drop r code LOCAL-OBJECT ;

: DELETED ( LOCAL:delete-outcome ^pass -- apply-event )
   {: r :}
   MATCH LOCAL:delete-outcome
      deleted OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      already-deleted OF MODEL-BASELINE:ABSENT r FINAL ENDOF
      precondition-changed OF r CHANGED ENDOF
   ;MATCH ;

: DELETE-FILE ( DROPBOX:hash ^pass -- apply-event )
   {: want r :}
   LOCAL-DELETE--OUTCOME:DELETED
   [: DROP-DELETED r RUN-ROOT r RUN-TARGET want
      r PASS-ARENA @ LOCAL:DELETE-LOCAL-AT ;]
   ['] LOCAL-OBJECT? LOCAL:CONVERTING {: code:n :}
   code 0= if r DELETED exit then
   drop r code LOCAL-OBJECT ;

\ The run's operation completes at once, counted; the plan stays
\ pending.
: COMPLETED-NONFINAL ( ^pass -- apply-event )
   {: r :}
   r PASS-JOURNAL @ r PASS-OPERATION @ r RUN-PATH
   r PASS-ARENA @ COMPLETE-NONFINAL
   1 r COUNTED construct apply-event done ;

: NO-CONTENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;

\ The apply step of the run's operation; a remote one blocks.
: APPLY ( ^pass -- apply-event )
   {: r :}
   r RUN-OPERATION MATCH MODEL:operation
      create-local-directory OF r CREATE-DIRECTORY ENDOF
      delete-local-directory OF r DELETE-DIRECTORY ENDOF
      install-local OF NO-CONTENT r INSTALL ENDOF
      replace-local OF OPTION:SOME r INSTALL ENDOF
      delete-local OF r DELETE-FILE ENDOF
      preserve-local OF drop r COMPLETED-NONFINAL ENDOF
      create-remote-directory OF r REMOTE ENDOF
      delete-remote-directory OF r REMOTE ENDOF
      create-remote OF drop r REMOTE ENDOF
      preserve-remote OF drop r REMOTE ENDOF
      replace-remote OF drop drop r REMOTE ENDOF
      delete-remote OF drop r REMOTE ENDOF
   ;MATCH ;

: STATUS ( ^pass -- JOURNAL:record-status )
   PASS-OPERATION @
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :} s ;

\ The block goes in the report; the plan's later operations wait.
: STOP ( ^pass -- )
   {: r :}
   r PASS-REPORT @ REPLAY-REPLAY--REPORT:BLOCKED @ {: v :}
   r PASS-BLOCKED @ v VEC:PUSH ! ;


\ ---- the operation's machine

\ One local operation's replay, after formal/LocalLifecycle.tla: a
\ completed operation passes; a pending one is applied, and passes or
\ stops its plan. APPLY's steps are formal/MutationLifecycle.tla's.
FSM:DEFINE LOCAL-LIFECYCLE ( ^pass ) local-state apply-event
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
: LIFECYCLE ( ^pass -- local-state )
   {: r :}
   construct local-state recorded
   begin r swap LOCAL-LIFECYCLE-STEP until ;

: STOPPED? ( local-state -- bool )
   construct local-state stopped LOCAL-STATE-EQ ;

\ The pass takes plan p; an excluded one is retired, not run.
: RUNNABLE? ( JOURNAL:plan-record ^pass -- bool )
   {: p r :}
   p r PASS-PLAN !
   p PLAN-PATH MODEL:EXCLUDED? 0= if true exit then
   r PASS-JOURNAL @ p r PASS-ARENA @ SUPERSEDE-PLAN false ;

\ An excluded plan is retired; another's operations run in order
\ until one stops it.
: REPLAY-PLAN ( JOURNAL:plan-record ^pass -- )
   {: p r :}
   p r RUNNABLE? 0= if exit then
   p PLAN-OPERATIONS {: ops :}
   ops VEC:COUNT 0 ?do
      ops i VEC:AT @ r PASS-OPERATION !
      r LIFECYCLE STOPPED? if leave then
   loop ;

\ Commits the pass's final completions and counts them.
: COMMIT-PASS ( ^pass -- )
   {: r :}
   r PASS-FINALS @ {: finals :}
   r PASS-JOURNAL @ finals r PASS-ARENA @
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
   j root r ru ar NEW-PASS {: run :}
   plans VEC:COUNT 0 ?do plans i VEC:AT @ run REPLAY-PLAN loop
   run COMMIT-PASS
   run PASS-REPORT @ ;


\ ---- local conflict copies ------------------------------------------

private

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

\ Whether a failed copy found its name held, by code alone: by other
\ bytes, or by an entry Omabox cannot replace.
: OCCUPIED? ( n n -- bool )
   {: code:n e:n :}
   code LOCAL:E-OCCUPIED = if true exit then
   code COPY-NAME-OCCUPIED? ;

\ The upload's bytes, read from f, written as path's local conflict copy.
: WRITE-COPY
   ( fd ^u8 n MODEL:path ^LOCAL:staged-upload fd ^ARENA:arena
     -- LOCAL:conflict-outcome )
   {: root:fd r:^ ru:n path:MODEL:path up:^LOCAL:staged-upload f:fd
      ar:^ARENA:arena :}
   root r ru path MODEL:PATH>STR str> LOCAL-CONFLICT--SIDE:LOCAL
   up LOCAL:UPLOAD-CONTENT [: f -rot LOCAL:FD-READ ;] ar
   LOCAL:MATERIALIZE-CONFLICT-AT ;

\ An occupied copy name blocks the copy; another failure passes up.
: COPY-IN
   ( fd ^u8 n MODEL:path ^LOCAL:staged-upload fd ^ARENA:arena
     -- copy-outcome )
   {: root:fd r:^ ru:n path:MODEL:path up:^LOCAL:staged-upload f:fd
      ar:^ARENA:arena :}
   COPY-OCCUPIED [: DROP-COPY root r ru path up f ar WRITE-COPY
      >COPY-OUTCOME ;]
   ['] OCCUPIED? LOCAL:CONVERTING {: code:n :}
   code 0= if exit then
   drop code FS:ERRNO OCCUPIED? if COPY-OCCUPIED exit then
   code throw ;

public

\ Writes the staged upload as path's local conflict copy below the open
\ root, whose path is r.
: MATERIALIZE-LOCAL-CONFLICT-AT
   ( fd ^u8 n MODEL:path ^LOCAL:staged-upload ^ARENA:arena
     -- copy-outcome )
   {: root:fd r:^ ru:n path:MODEL:path up:^LOCAL:staged-upload
      ar:^ARENA:arena :}
   up ar LOCAL:OPEN-VERIFIED-UPLOAD {: f:fd :}
   [: root r ru path up f ar COPY-IN ;] [: f DISCARD ;] finally ;


\ ---- Dropbox mutations ---------------------------------------------

private

\ Dropbox's largest upload session, in bytes.
350000000000 constant UPLOAD-MAX
47 constant SLASH

\ A mutation's precondition and intent, which a state read is
\ classified against.
ENUM expectation
   VARIANT create-file FIELD desired DROPBOX:hash ;VARIANT
   VARIANT replace-file
      FIELD expected DROPBOX:rev FIELD desired DROPBOX:hash
   ;VARIANT
   VARIANT delete-file FIELD expected DROPBOX:rev ;VARIANT
   VARIANT create-folder ;VARIANT
   VARIANT delete-folder ;VARIANT
;ENUM

\ One upload; rev is the rev it replaces, empty to create, and done the
\ bytes Dropbox has accepted.
STRUCTURE sending DERIVE addr
   FIELD link ^link
   FIELD target str
   FIELD path MODEL:path
   FIELD stage ^LOCAL:staged-upload
   FIELD rev DROPBOX:rev
   FIELD arena ^ARENA:arena
   FIELD fd fd
   FIELD size n
   FIELD done n
;STRUCTURE
ARENA SENDINGS sending
ARENA UPLOADS DROPBOX:upload

: CLIENT ( ^link -- ^DROPBOX:client ) REPLAY-LINK:CLIENT @ ;

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u:n ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

: IS? ( DROPBOX:error DROPBOX:error -- bool ) DROPBOX-ERROR:EQ ;


\ ---- outcomes

: ABSENT ( -- remote-path-state )
   REPLAY-REMOTE--PATH--STATE:ABSENT ;
: FOLDER ( -- remote-path-state )
   REPLAY-REMOTE--PATH--STATE:FOLDER ;
: PENDING ( -- mutation-outcome ) REPLAY-MUTATION--OUTCOME:PENDING ;
: APPLIED ( remote-path-state -- mutation-outcome )
   REPLAY-MUTATION--OUTCOME:APPLIED ;
: CHANGED-TO ( remote-path-state -- mutation-outcome )
   REPLAY-MUTATION--OUTCOME:PRECONDITION-CHANGED ;
: REJECT ( mutation-rejection -- mutation-outcome )
   REPLAY-MUTATION--OUTCOME:REJECTED ;
: GONE ( -- mutation-outcome ) ABSENT APPLIED ;


\ ---- the Dropbox path

\ Rust's Component::Normal that invalid_dropbox_component accepts.
: NORMAL? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 0= if false exit then
   p u s" ." STR= p u s" .." STR= or if false exit then
   p u >str 0 COUNT-CHAR 0<> if false exit then
   p u UTF8:VALID? ;

\ Whether every component from `at` on is NORMAL?.
: NORMAL-FROM? ( ^u8 n n -- bool )
   {: p:^ u:n at:n :}
   p u SLASH at SPLIT-NEXT 0= if 2drop drop true exit then
   {: q:^ v:n next:n :}
   q v NORMAL? 0= if false exit then
   p u next RECURSE ;

: NO-TARGET ( -- option<str> ) OPTION:NONE ;

\ The root, "/" and p, in the arena.
: UNDER ( str ^u8 n ^ARENA:arena -- str )
   {: root:str p:^ u:n ar :}
   root str> {: r:^ ru:n :}
   ar ru u + 1+ ARENA:ALLOC drop {: dst:^ :}
   r dst ru BYTE-COPY
   SLASH dst ru + c!
   p dst ru + 1+ u BYTE-COPY
   dst ru u + 1+ >str ;

\ Rust's mutation_target: the path below the link's root, none for a
\ path with no component or one Dropbox cannot name.
: TARGET ( ^link MODEL:path ^ARENA:arena -- option<str> )
   {: l path ar :}
   path MODEL:PATH>STR str> {: p:^ u:n :}
   p u 0 NORMAL-FROM? 0= if NO-TARGET exit then
   l REPLAY-LINK:ROOT @ p u ar UNDER OPTION:SOME ;

\ Runs `call` on the path's target; an invalid path makes no call.
: TARGETED
   ( ^link MODEL:path ^ARENA:arena [ str -- mutation-outcome ]
     -- mutation-outcome )
   {: l path ar call :}
   l path ar TARGET MATCH option
      some OF call execute ENDOF
      none OF construct mutation-rejection invalid-path REJECT ENDOF
   ;MATCH ;


\ ---- classifying

: REV-IS? ( DROPBOX:rev remote-path-state -- bool )
   {: want:DROPBOX:rev s:remote-path-state :}
   s MATCH remote-path-state
      absent OF false ENDOF
      file OF
         MODEL-REMOTE:UNMAKE {: c v :}
         v DROPBOX:REV>STR str> want DROPBOX:REV>STR str> STR=
      ENDOF
      folder OF false ENDOF
      unsupported OF false ENDOF
   ;MATCH ;

: HOLDS? ( DROPBOX:hash remote-path-state -- bool )
   {: want:DROPBOX:hash s:remote-path-state :}
   s MATCH remote-path-state
      absent OF false ENDOF
      file OF
         MODEL-REMOTE:UNMAKE {: c v :} c want DROPBOX:HASH=
      ENDOF
      folder OF false ENDOF
      unsupported OF false ENDOF
   ;MATCH ;

: ABSENT? ( remote-path-state -- bool )
   MATCH remote-path-state
      absent OF true ENDOF
      file OF drop false ENDOF
      folder OF false ENDOF
      unsupported OF false ENDOF
   ;MATCH ;

: FOLDER? ( remote-path-state -- bool )
   MATCH remote-path-state
      absent OF false ENDOF
      file OF drop false ENDOF
      folder OF true ENDOF
      unsupported OF false ENDOF
   ;MATCH ;

\ The path still holds what the mutation expected to change.
: UNCHANGED? ( remote-path-state expectation -- bool )
   {: s:remote-path-state x:expectation :}
   x MATCH expectation
      create-file OF drop s ABSENT? ENDOF
      replace-file OF drop s REV-IS? ENDOF
      delete-file OF s REV-IS? ENDOF
      create-folder OF s ABSENT? ENDOF
      delete-folder OF s FOLDER? ENDOF
   ;MATCH ;

\ The path holds what the mutation intended.
: INTENDED? ( remote-path-state expectation -- bool )
   {: s:remote-path-state x:expectation :}
   x MATCH expectation
      create-file OF s HOLDS? ENDOF
      replace-file OF
         {: v:DROPBOX:rev c:DROPBOX:hash :} c s HOLDS?
      ENDOF
      delete-file OF drop s ABSENT? ENDOF
      create-folder OF s FOLDER? ENDOF
      delete-folder OF s ABSENT? ENDOF
   ;MATCH ;

\ Rust's MutationExpectation::classify.
: CLASSIFY ( remote-path-state expectation -- mutation-outcome )
   {: s x :}
   s x UNCHANGED? if PENDING exit then
   s x INTENDED? if s APPLIED exit then
   s CHANGED-TO ;

\ Ends the pass on a refusal that is not one path's verdict.
: STOP-REFUSED ( DROPBOX:error ^link -- )
   swap DROPBOX-REPLY:REFUSED swap STOP-PASS ;

: BY-DROPBOX ( -- mutation-rejection )
   construct mutation-rejection rejected-by-dropbox ;
: DENIED ( -- mutation-rejection )
   construct mutation-rejection permission-denied ;
: NOT-ALLOWED ( -- mutation-rejection )
   construct mutation-rejection operation-not-allowed ;

\ Rust's write_outcome and lookup_outcome: one path's refusal; a
\ refusal about the pass, not the path, stops it.
: REJECTION ( DROPBOX:error ^link -- mutation-rejection )
   {: e l :}
   e MATCH DROPBOX:error
      not-found OF BY-DROPBOX ENDOF
      not-file OF BY-DROPBOX ENDOF
      not-folder OF BY-DROPBOX ENDOF
      malformed-path OF
         construct mutation-rejection invalid-path
      ENDOF
      disallowed-name OF
         construct mutation-rejection disallowed-name
      ENDOF
      conflict OF e l STOP-REFUSED ENDOF
      no-write-permission OF DENIED ENDOF
      restricted-content OF BY-DROPBOX ENDOF
      access-restricted OF DENIED ENDOF
      team-folder OF NOT-ALLOWED ENDOF
      operation-suppressed OF NOT-ALLOWED ENDOF
      insufficient-space OF
         construct mutation-rejection insufficient-space
      ENDOF
      locked OF BY-DROPBOX ENDOF
      reset OF e l STOP-REFUSED ENDOF
      invalid-root OF e l STOP-REFUSED ENDOF
      content-hash-mismatch OF
         construct mutation-rejection content-hash-mismatch
      ENDOF
      unsupported-file OF BY-DROPBOX ENDOF
      path-mismatch OF
         construct mutation-rejection path-mismatch
      ENDOF
      unverified OF e l STOP-REFUSED ENDOF
      other OF BY-DROPBOX ENDOF
   ;MATCH ;

: REJECTED ( DROPBOX:error ^link -- mutation-outcome )
   REJECTION REJECT ;


\ ---- reading the path back

public

\ The entry's file, its strings copied into the arena.
: REMOTE-OF ( ^DROPBOX:entry ^ARENA:arena -- MODEL:remote )
   {: e ar :}
   e DROPBOX-ENTRY:CONTENT-HASH @ SPAN:$ ar COPIED DROPBOX:>HASH
   e DROPBOX-ENTRY:REV @ SPAN:$ ar COPIED DROPBOX:>REV
   MODEL-REMOTE:MAKE ;

private

: FILE-STATE ( ^DROPBOX:entry ^ARENA:arena -- remote-path-state )
   {: e ar :}
   e DROPBOX-ENTRY:DOWNLOADABLE @ 0= if
      REPLAY-REMOTE--PATH--STATE:UNSUPPORTED exit
   then
   e ar REMOTE-OF REPLAY-REMOTE--PATH--STATE:FILE ;

: FOUND ( ^DROPBOX:entry ^ARENA:arena -- remote-path-state )
   {: e ar :}
   e DROPBOX-ENTRY:KIND @ MATCH DROPBOX:kind
      file OF e ar FILE-STATE ENDOF
      folder OF FOLDER ENDOF
      deleted OF ABSENT ENDOF
   ;MATCH ;

\ Rust's verify: what Dropbox holds at t, classified against x.
: STATE ( ^link ^u8 n expectation ^ARENA:arena -- mutation-outcome )
   {: l t:^ tu:n x ar :}
   t tu l CLIENT DROPBOX:METADATA {: r:DROPBOX:reply :}
   r MATCH DROPBOX:reply
      done OF l CLIENT DROPBOX:ENTRY {: m :}
         m DROPBOX-ENTRY:KIND @ DROPBOX-KIND:FILE DROPBOX-KIND:EQ
         m DROPBOX-ENTRY:DOWNLOADABLE @ and m DROPBOX:COMPLETE? 0= and
         \ An incomplete file rejects this plan alone; the others go on.
         if BY-DROPBOX REJECT else m ar FOUND x CLASSIFY then
      ENDOF
      refused OF {: e:DROPBOX:error :}
         e DROPBOX-ERROR:NOT-FOUND IS?
         if ABSENT x CLASSIFY else e l REJECTED then
      ENDOF
      retry OF drop r l STOP-PASS ENDOF
      unlinked OF r l STOP-PASS ENDOF
   ;MATCH ;

\ Rust's resolve_explicit_conflict and resolve_ambiguous: Dropbox may
\ hold the mutation's result.
: READ-BACK? ( DROPBOX:error -- bool )
   {: e:DROPBOX:error :}
   e DROPBOX-ERROR:CONFLICT IS? e DROPBOX-ERROR:UNVERIFIED IS? or ;

\ One mutation's reply: done answers `applied`; a conflict or an
\ unverified answer reads the path back once.
: ANSWERED
   ( DROPBOX:reply ^link ^u8 n expectation ^ARENA:arena
     [ -- mutation-outcome ] -- mutation-outcome )
   {: r:DROPBOX:reply l t:^ tu:n x ar applied :}
   r MATCH DROPBOX:reply
      done OF applied execute ENDOF
      refused OF {: e:DROPBOX:error :}
         e READ-BACK?
         if l t tu x ar STATE else e l REJECTED then
      ENDOF
      retry OF drop r l STOP-PASS ENDOF
      unlinked OF r l STOP-PASS ENDOF
   ;MATCH ;


\ ---- create folder, delete file

: MAKE-FOLDER ( str ^link ^ARENA:arena -- mutation-outcome )
   {: t:str l ar :}
   t str> l CLIENT DROPBOX:CREATE-FOLDER
   l t str> EXPECTATION-CREATE-FOLDER ar
   [: FOLDER APPLIED ;] ANSWERED ;

: REMOTE-CREATE-FOLDER
   ( ^link MODEL:path ^ARENA:arena -- mutation-outcome )
   {: l path ar :}
   l path ar [: l ar MAKE-FOLDER ;] TARGETED ;

: UNLINK ( str ^link DROPBOX:rev ^ARENA:arena -- mutation-outcome )
   {: t:str l rev:DROPBOX:rev ar :}
   t str> rev DROPBOX:REV>STR str> l CLIENT DROPBOX:DELETE
   l t str> rev EXPECTATION-DELETE-FILE ar ['] GONE ANSWERED ;

: REMOTE-DELETE-FILE
   ( ^link MODEL:path DROPBOX:rev ^ARENA:arena -- mutation-outcome )
   {: l path rev:DROPBOX:rev ar :}
   rev DROPBOX:REV>STR str> nip 0= if
      path s" remote delete has no revision" INVALID
   then
   l path ar [: l rev ar UNLINK ;] TARGETED ;


\ ---- upload

\ The open stage's size in bytes; a failed fstat ends the pass.
: STAGE-SIZE ( ^sending -- n )
   {: s :}
   [: s SENDING-FD @ FS:FD-STAT ;] catch {: code:n :}
   code 0= if FS:STAT-SIZE@ exit then
   code E-FS-STAT <> if code throw then
   s" read upload stage metadata"
   s SENDING-PATH @ MODEL:PATH>STR str> LOCAL:IO-FAILURE ;

\ Rust's validate_upload_size.
: OVERSIZE? ( n -- bool ) UPLOAD-MAX > ;

: SAMPLE ( ^sending -- STATUS:transfer )
   {: s :}
   STATUS-DIRECTION:UPLOAD s SENDING-PATH @ MODEL:PATH>STR
   s SENDING-DONE @ s SENDING-SIZE @ OPTION:SOME
   STATUS-TRANSFER:MAKE ;

: STATUS-OF ( ^sending -- ^STATUS:status )
   SENDING-LINK @ REPLAY-LINK:STATUS @ ;

\ UPLOAD's progress: n bytes accepted.
: SENT ( n ^sending -- )
   {: n s :}
   n s SENDING-DONE !
   s SAMPLE STATUS-EVENT:PROGRESS s STATUS-OF STATUS:TRANSFER ;

: FINISHED ( ^sending -- )
   {: s :}
   s SAMPLE STATUS-EVENT:FINISHED s STATUS-OF STATUS:TRANSFER ;

: DESIRED ( ^sending -- DROPBOX:hash )
   SENDING-STAGE @ LOCAL:UPLOAD-CONTENT ;

: EXPECTED ( ^sending -- expectation )
   {: s :}
   s SENDING-REV @ {: v:DROPBOX:rev :}
   v DROPBOX:REV>STR str> nip 0= if
      s DESIRED EXPECTATION-CREATE-FILE exit
   then
   v s DESIRED EXPECTATION-REPLACE-FILE ;

: UPLOAD-OF ( ^sending -- ^DROPBOX:upload )
   {: s :}
   s SENDING-ARENA @ UPLOADS-NEW {: up :}
   s SENDING-FD @ up DROPBOX-UPLOAD:FD !
   s SENDING-SIZE @ up DROPBOX-UPLOAD:SIZE !
   s DESIRED DROPBOX:HASH>STR str> SPAN:MAKE
   up DROPBOX-UPLOAD:CONTENT-HASH !
   s SENDING-TARGET @ str> SPAN:MAKE up DROPBOX-UPLOAD:PATH !
   s SENDING-REV @ DROPBOX:REV>STR str> SPAN:MAKE
   up DROPBOX-UPLOAD:REV !
   up ;

\ The upload; a finished transfer follows on every exit.
: PUT ( ^sending -- DROPBOX:reply )
   {: s :}
   [: s UPLOAD-OF s SENDING-LINK @ CLIENT [: s SENT ;]
      DROPBOX:UPLOAD ;]
   [: s FINISHED ;] finally ;

: UPLOADED ( ^sending -- mutation-outcome )
   {: s :}
   s SENDING-LINK @ CLIENT DROPBOX:ENTRY s SENDING-ARENA @ REMOTE-OF
   REPLAY-REMOTE--PATH--STATE:FILE APPLIED ;

: SEND ( ^sending -- mutation-outcome )
   {: s :}
   s PUT s SENDING-LINK @ s SENDING-TARGET @ str> s EXPECTED
   s SENDING-ARENA @ [: s UPLOADED ;] ANSWERED ;

\ A stage Dropbox cannot take is rejected before any call.
: SIZED ( ^sending -- mutation-outcome )
   {: s :}
   s STAGE-SIZE s SENDING-SIZE !
   s SENDING-SIZE @ OVERSIZE? if
      construct mutation-rejection unsupported-file-size REJECT exit
   then
   s SEND ;

\ The stage, opened verified, closes on every exit.
: OPENED ( ^sending -- mutation-outcome )
   {: s :}
   s SENDING-STAGE @ s SENDING-ARENA @ LOCAL:OPEN-VERIFIED-UPLOAD
   {: f:fd :}
   f s SENDING-FD !
   [: s SIZED ;] [: f DISCARD ;] finally ;

: NEW-SENDING
   ( str ^link MODEL:path ^LOCAL:staged-upload DROPBOX:rev
     ^ARENA:arena -- ^sending )
   {: t:str l path up rev:DROPBOX:rev ar :}
   ar SENDINGS-NEW {: s :}
   t s SENDING-TARGET ! l s SENDING-LINK ! path s SENDING-PATH !
   up s SENDING-STAGE ! rev s SENDING-REV ! ar s SENDING-ARENA !
   s ;

\ Rust's create_file, or replace_file of the rev unless it is empty.
: REMOTE-UPLOAD
   ( ^link MODEL:path ^LOCAL:staged-upload DROPBOX:rev ^ARENA:arena
     -- mutation-outcome )
   {: l path up rev:DROPBOX:rev ar :}
   l path ar [: l path up rev ar NEW-SENDING OPENED ;] TARGETED ;


\ ---- delete folder

\ A file the delete found took the folder's place after the probe.
: REPLACED ( ^link MODEL:path -- )
   {: l path :}
   l CLIENT DROPBOX:ENTRY {: e :}
   e DROPBOX-ENTRY:KIND @ DROPBOX-KIND:FILE DROPBOX-KIND:EQ 0=
   if exit then
   LOG:ERROR s" replay" LOG:LINE
   s" Dropbox deleted a file that replaced the empty folder after"
   LOG:TEXT+
   s"  its listing; restore it from Dropbox's deleted files if it"
   LOG:TEXT+
   s"  is wanted path=" LOG:TEXT+ path MODEL:PATH>STR str> LOG:TEXT+
   s"  revision=" LOG:TEXT+ e DROPBOX-ENTRY:REV @ SPAN:$ LOG:TEXT+
   LOG:;LINE ;

\ Deletes the folder the probe found empty, whatever it holds now.
: EMPTIED
   ( str ^link MODEL:path ^ARENA:arena -- mutation-outcome )
   {: t:str l path ar :}
   t str> s" " l CLIENT DROPBOX:DELETE
   l t str> EXPECTATION-DELETE-FOLDER ar
   [: l path REPLACED GONE ;] ANSWERED ;

: PROBE-REFUSED
   ( DROPBOX:error str ^link ^ARENA:arena -- mutation-outcome )
   {: e:DROPBOX:error t:str l ar :}
   e DROPBOX-ERROR:NOT-FOUND IS? if GONE exit then
   e DROPBOX-ERROR:NOT-FOLDER IS? if
      l t str> EXPECTATION-DELETE-FOLDER ar STATE exit
   then
   e DROPBOX-ERROR:RESET IS? if PENDING exit then
   e l REJECTED ;

: PROBED
   ( DROPBOX:probe str ^link MODEL:path ^ARENA:arena
     -- mutation-outcome )
   {: b:DROPBOX:probe t:str l path ar :}
   b MATCH DROPBOX:probe
      empty OF t l path ar EMPTIED ENDOF
      occupied OF FOLDER CHANGED-TO ENDOF
      interrupted OF PENDING ENDOF
   ;MATCH ;

\ Rust's delete_folder: only a folder the probe shows empty.
: CLEARED
   ( str ^link MODEL:path ^ARENA:arena -- mutation-outcome )
   {: t:str l path ar :}
   t str> l CLIENT DROPBOX:PROBE {: r:DROPBOX:reply b:DROPBOX:probe :}
   r MATCH DROPBOX:reply
      done OF b t l path ar PROBED ENDOF
      refused OF t l ar PROBE-REFUSED ENDOF
      retry OF drop r l STOP-PASS ENDOF
      unlinked OF r l STOP-PASS ENDOF
   ;MATCH ;

: REMOTE-DELETE-FOLDER
   ( ^link MODEL:path ^ARENA:arena -- mutation-outcome )
   {: l path ar :}
   l path ar [: l path ar CLEARED ;] TARGETED ;


\ ---- the download bridge ---------------------------------------------

private

\ Rust's PROGRESS_INTERVAL, in nanoseconds.
250000000 constant PROGRESS-INTERVAL

\ One exact download. partial: a prepared partial no LOCAL word has taken;
\ sampled is TIME:MONO-NS; shown: a progress went out.
STRUCTURE bridge DERIVE addr
   FIELD link ^link
   FIELD root fd
   FIELD root-path str
   FIELD target MODEL:path
   FIELD path MODEL:path
   FIELD want DROPBOX:hash
   FIELD arena ^ARENA:arena
   FIELD partial option<^LOCAL:download-partial>
   FIELD outcome LOCAL:stage-outcome<n>
   FIELD done n
   FIELD total n
   FIELD sampled n
   FIELD emitted n
   FIELD shown bool
;STRUCTURE

ARENA BRIDGES bridge

: NO-PARTIAL ( -- option<^LOCAL:download-partial> ) OPTION:NONE ;
: SOME-PARTIAL
   ( ^LOCAL:download-partial -- option<^LOCAL:download-partial> )
   OPTION:SOME ;
: NO-STAGE ( -- option<LOCAL:stage-outcome<n>> ) OPTION:NONE ;

\ The root's descriptor and path, and the target's text.
: TARGET-AT ( ^bridge -- fd ^u8 n ^u8 n )
   {: x :}
   x BRIDGE-ROOT @ x BRIDGE-ROOT-PATH @ str>
   x BRIDGE-TARGET @ MODEL:PATH>STR str> ;

: HELD? ( ^bridge -- bool )
   BRIDGE-PARTIAL @ MATCH option
      none OF false ENDOF
      some OF drop true ENDOF
   ;MATCH ;

\ The partial the bridge held, now its taker's to free.
: TAKE-PARTIAL ( ^bridge -- option<^LOCAL:download-partial> )
   {: x :}
   x BRIDGE-PARTIAL @ NO-PARTIAL x BRIDGE-PARTIAL ! ;


\ ---- progress

: FETCH-SAMPLE ( ^bridge -- STATUS:transfer )
   {: x :}
   STATUS-DIRECTION:DOWNLOAD x BRIDGE-PATH @ MODEL:PATH>STR
   x BRIDGE-DONE @ x BRIDGE-TOTAL @ OPTION:SOME STATUS-TRANSFER:MAKE ;

: FETCH-STATUS ( ^bridge -- ^STATUS:status )
   BRIDGE-LINK @ REPLAY-LINK:STATUS @ ;

: PROGRESSED ( ^bridge -- )
   {: x :}
   x FETCH-SAMPLE STATUS-EVENT:PROGRESS x FETCH-STATUS STATUS:TRANSFER
   x BRIDGE-DONE @ x BRIDGE-EMITTED !
   true x BRIDGE-SHOWN ! ;

\ Rust's ProgressReader::read: a sample is due at the body's end, at
\ its total, or PROGRESS-INTERVAL after the last, if done moved.
: DUE? ( ^bridge n n -- bool )
   {: x k:n now:n :}
   x BRIDGE-DONE @ {: d:n :}
   k 0= d x BRIDGE-TOTAL @ >= or
   now x BRIDGE-SAMPLED @ - PROGRESS-INTERVAL >= or
   d x BRIDGE-EMITTED @ <> and ;

: TALLIED ( ^bridge n -- )
   {: x k:n :}
   k x BRIDGE-DONE +!
   TIME:MONO-NS {: now:n :}
   x k now DUE? 0= if exit then
   x PROGRESSED now x BRIDGE-SAMPLED ! ;

\ The body's reader: f's next bytes into p, counted; its first call
\ sends a progress.
: COUNTED-READ ( ^u8 n ^DROPBOX:fetch ^bridge -- n )
   {: p:^ room:n f x :}
   x BRIDGE-SHOWN @ 0= if
      TIME:MONO-NS x BRIDGE-SAMPLED ! x PROGRESSED
   then
   p room f DROPBOX:READ-BODY {: k:n :}
   x k TALLIED k ;

\ Rust's drop of a ProgressReader, once a progress went out.
: FETCH-FINISHED ( ^bridge -- )
   {: x :}
   x BRIDGE-SHOWN @ 0= if exit then
   x FETCH-SAMPLE STATUS-EVENT:FINISHED x FETCH-STATUS STATUS:TRANSFER ;


\ ---- the body

\ The body appended to the partial up to size; it frees the partial.
: RESUME-INTO
   ( ^bridge ^LOCAL:download-partial n ^DROPBOX:fetch
     -- LOCAL:stage-outcome<n> )
   {: x p size:n f :}
   p size [: f x COUNTED-READ ;] x BRIDGE-ARENA @
   LOCAL:APPEND-PARTIAL ;

: STAGE-NEW ( ^bridge ^DROPBOX:fetch -- LOCAL:stage-outcome<n> )
   {: x f :}
   x TARGET-AT x BRIDGE-WANT @ [: f x COUNTED-READ ;]
   x BRIDGE-ARENA @ LOCAL:STAGE-DOWNLOAD-AT ;

\ After a 416 that is not complete: the partial's slot emptied, then
\ the body staged from 0; a complete one answers with the body unread.
: RESTART-INTO
   ( ^bridge ^LOCAL:download-partial n ^DROPBOX:fetch
     -- LOCAL:stage-outcome<n> )
   {: x p size:n f :}
   p LOCAL:RESTART-PARTIAL MATCH LOCAL:download-preparation
      ready OF {: q :} x q size f RESUME-INTO ENDOF
      complete OF ENDOF
      ephemeral OF x f STAGE-NEW ENDOF
   ;MATCH ;

\ DOWNLOAD's body. A start other than the partial's offset is a restart
\ from 0; a 416 at the offset arrives with the fetch at its end.
: RECEIVED ( n n ^DROPBOX:fetch ^bridge -- )
   {: start:n size:n f x :}
   start x BRIDGE-DONE ! size x BRIDGE-TOTAL !
   x TAKE-PARTIAL MATCH option
      none OF x f STAGE-NEW ENDOF
      some OF {: p :}
         start p LOCAL:PARTIAL-OFFSET@ = if x p size f RESUME-INTO
         else x p size f RESTART-INTO then
      ENDOF
   ;MATCH x BRIDGE-OUTCOME ! ;


\ ---- preparation and the call

\ A ready partial goes to the bridge; a complete stage answers.
: PREPARED
   ( LOCAL:download-preparation ^bridge -- option<LOCAL:stage-outcome<n>> )
   {: x :}
   MATCH LOCAL:download-preparation
      ready OF SOME-PARTIAL x BRIDGE-PARTIAL ! NO-STAGE ENDOF
      complete OF OPTION:SOME ENDOF
      ephemeral OF NO-STAGE ENDOF
   ;MATCH ;

\ o, else what q answers when o is none.
: OR-ELSE
   ( option<LOCAL:stage-outcome<n>> [ -- option<LOCAL:stage-outcome<n>> ]
     -- option<LOCAL:stage-outcome<n>> )
   {: o q :}
   o MATCH option
      none OF q execute ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH ;

: LEASED-SLOT
   ( option<LOCAL:download-slot-lease> ^bridge
     -- option<LOCAL:stage-outcome<n>> )
   {: lease x :}
   lease MATCH option
      none OF NO-STAGE ENDOF
      some OF {: l:LOCAL:download-slot-lease :}
         x TARGET-AT x BRIDGE-WANT @ l x BRIDGE-ARENA @
         LOCAL:PREPARE-DOWNLOAD-SLOT-AT x PREPARED
      ENDOF
   ;MATCH ;

\ An unnamed file in the staging directory s, empty for none.
: DISPOSABLE-FILE ( ^u8 n ^bridge -- option<LOCAL:stage-outcome<n>> )
   {: s:^ su:n x :}
   x HELD? su 0= or if NO-STAGE exit then
   x TARGET-AT x BRIDGE-WANT @ s su x BRIDGE-ARENA @
   LOCAL:PREPARE-DISPOSABLE-DOWNLOAD-AT x PREPARED ;

: EXISTING-STAGE ( ^bridge -- option<LOCAL:stage-outcome<n>> )
   {: x :}
   x HELD? if NO-STAGE exit then
   x TARGET-AT x BRIDGE-WANT @ x BRIDGE-ARENA @
   LOCAL:EXISTING-DOWNLOAD-STAGE-AT ;

: PREPARE
   ( option<LOCAL:download-slot-lease> ^u8 n ^bridge
     -- option<LOCAL:stage-outcome<n>> )
   {: lease s:^ su:n x :}
   lease x LEASED-SLOT [: s su x DISPOSABLE-FILE ;] OR-ELSE
   [: x EXISTING-STAGE ;] OR-ELSE ;

: RESUME-OFFSET ( ^bridge -- n )
   BRIDGE-PARTIAL @ MATCH option
      none OF 0 ENDOF
      some OF LOCAL:PARTIAL-OFFSET@ ENDOF
   ;MATCH ;

\ The rev's bytes from the partial's offset.
: FETCHED ( MODEL:remote ^bridge -- LOCAL:stage-outcome<n> )
   {: rem x :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   x BRIDGE-LINK @ {: k :}
   v c x RESUME-OFFSET k REPLAY-LINK:CLIENT @
   [: x RECEIVED ;] DROPBOX:DOWNLOAD {: r:DROPBOX:reply :}
   r MATCH DROPBOX:reply
      done OF ENDOF
      refused OF drop r k STOP-PASS ENDOF
      retry OF drop r k STOP-PASS ENDOF
      unlinked OF r k STOP-PASS ENDOF
   ;MATCH
   x BRIDGE-OUTCOME @ ;

: STAGED-BY
   ( MODEL:remote option<LOCAL:download-slot-lease> ^u8 n ^bridge
     -- LOCAL:stage-outcome<n> )
   {: rem lease s:^ su:n x :}
   lease s su x PREPARE MATCH option
      none OF rem x FETCHED ENDOF
      some OF ENDOF
   ;MATCH ;

\ Frees a partial no LOCAL word took.
: RELEASED ( ^bridge -- )
   TAKE-PARTIAL MATCH option
      none OF ENDOF
      some OF LOCAL:CLOSE-PARTIAL ENDOF
   ;MATCH ;

: NEW-BRIDGE
   ( ^link fd ^u8 n MODEL:path MODEL:path DROPBOX:hash ^ARENA:arena
     -- ^bridge )
   {: k root:fd r:^ ru:n t p c ar :}
   ar BRIDGES-NEW {: x :}
   k x BRIDGE-LINK ! root x BRIDGE-ROOT ! r ru >str x BRIDGE-ROOT-PATH !
   t x BRIDGE-TARGET ! p x BRIDGE-PATH ! c x BRIDGE-WANT !
   ar x BRIDGE-ARENA ! NO-PARTIAL x BRIDGE-PARTIAL !
   x ;

\ Rust's stage_exact_download_for_access_at: target t's stage, its
\ transfer shown as p; s is the staging directory, empty for none.
: STAGE-EXACT-DOWNLOAD-FOR-AT
   ( ^link fd ^u8 n MODEL:path MODEL:path MODEL:remote
     option<LOCAL:download-slot-lease> ^u8 n ^ARENA:arena
     -- LOCAL:stage-outcome<n> )
   {: k root:fd r:^ ru:n t p rem lease s:^ su:n ar :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   k root r ru t p c ar NEW-BRIDGE {: x :}
   [: rem lease s su x STAGED-BY ;] [: x RELEASED x FETCH-FINISHED ;]
   finally ;

public

\ Rust's stage_worker_download_at: path's stage below root path r,
\ through the lease's slot, else an unnamed file in s.
: STAGE-EXACT-DOWNLOAD-AT
   ( ^link fd ^u8 n MODEL:path MODEL:remote
     option<LOCAL:download-slot-lease> ^u8 n ^ARENA:arena
     -- LOCAL:stage-outcome<n> )
   {: k root:fd r:^ ru:n path rem lease s:^ su:n ar :}
   k root r ru path path rem lease s su ar
   STAGE-EXACT-DOWNLOAD-FOR-AT ;

\ ---- remote conflict copies ------------------------------------------

private

: EXACT-READY ( -- exact-copy-outcome )
   construct exact-copy-outcome ready ;
: EXACT-OCCUPIED ( -- exact-copy-outcome )
   construct exact-copy-outcome stage-occupied ;
: SOME-EXACT ( exact-copy-outcome -- option<exact-copy-outcome> )
   OPTION:SOME ;
: NO-EXACT ( -- option<exact-copy-outcome> ) OPTION:NONE ;
: NO-LEASE ( -- option<LOCAL:download-slot-lease> ) OPTION:NONE ;

\ An install's answer; none: no verified stage to install.
: INSTALL-ANSWER
   ( LOCAL:install-outcome -- option<exact-copy-outcome> )
   MATCH LOCAL:install-outcome
      installed OF EXACT-READY SOME-EXACT ENDOF
      already-installed OF EXACT-READY SOME-EXACT ENDOF
      download-required OF NO-EXACT ENDOF
      stage-destination-occupied OF drop EXACT-OCCUPIED SOME-EXACT ENDOF
      precondition-changed OF
         drop construct exact-copy-outcome destination-changed
         SOME-EXACT
      ENDOF
   ;MATCH ;

\ A stage's answer; none: staged, to install.
: STAGE-ANSWER
   ( LOCAL:stage-outcome<n> -- option<exact-copy-outcome> )
   MATCH LOCAL:stage-outcome
      staged OF drop NO-EXACT ENDOF
      already-staged OF drop NO-EXACT ENDOF
      content-changed OF
         drop construct exact-copy-outcome content-changed SOME-EXACT
      ENDOF
      destination-occupied OF drop EXACT-OCCUPIED SOME-EXACT ENDOF
   ;MATCH ;

: REQUIRED
   ( option<exact-copy-outcome> MODEL:path -- exact-copy-outcome )
   {: path :}
   MATCH option
      none OF
         path s" verified exact Dropbox download disappeared" INVALID
      ENDOF
      some OF ENDOF
   ;MATCH ;

\ Installs t's verified stage of c; nothing at t is replaced.
: INSTALLED-COPY
   ( fd ^u8 n MODEL:path DROPBOX:hash ^ARENA:arena
     -- option<exact-copy-outcome> )
   {: root:fd r:^ ru:n t c ar :}
   root r ru t MODEL:PATH>STR str> c NO-CONTENT ar
   LOCAL:INSTALL-DOWNLOAD-AT INSTALL-ANSWER ;

: STAGED-COPY
   ( ^link fd ^u8 n MODEL:path MODEL:path MODEL:remote ^ARENA:arena
     -- option<exact-copy-outcome> )
   {: k root:fd r:^ ru:n t path rem ar :}
   k root r ru t path rem NO-LEASE s" " ar
   STAGE-EXACT-DOWNLOAD-FOR-AT STAGE-ANSWER ;

: STAGED-THEN-INSTALLED
   ( ^link fd ^u8 n MODEL:path MODEL:path MODEL:remote ^ARENA:arena
     -- exact-copy-outcome )
   {: k root:fd r:^ ru:n t path rem ar :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   k root r ru t path rem ar STAGED-COPY MATCH option
      none OF root r ru t c ar INSTALLED-COPY path REQUIRED ENDOF
      some OF ENDOF
   ;MATCH ;

\ Rust's ensure_exact_copy_at: the remote's exact bytes at target t,
\ staged when no verified stage is there, its transfer shown as path.
: EXACT-COPY-AT
   ( ^link fd ^u8 n MODEL:path MODEL:path MODEL:remote ^ARENA:arena
     -- exact-copy-outcome )
   {: k root:fd r:^ ru:n t path rem ar :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   root r ru t c ar INSTALLED-COPY MATCH option
      none OF k root r ru t path rem ar STAGED-THEN-INSTALLED ENDOF
      some OF ENDOF
   ;MATCH ;

\ A blocked download's reason: its blockage's variant in snake case,
\ with an unavailable download's status or a rejection's tag.
: REASON+ ( MODEL:blockage -- )
   MATCH MODEL:blockage
      unsupported-file-size OF s" unsupported_file_size" LOG:TEXT+ ENDOF
      remote-rejected OF {: t:str :}
         s" remote_rejected " LOG:TEXT+ t str> LOG:TEXT+
      ENDOF
      download-unavailable OF {: st :}
         s" download_unavailable " LOG:TEXT+ st LOG:INT+
      ENDOF
      download-verification-failed OF
         s" download_verification_failed" LOG:TEXT+
      ENDOF
      stage-occupied OF s" stage_occupied" LOG:TEXT+ ENDOF
      local-object-in-way OF s" local_object_in_way" LOG:TEXT+ ENDOF
      remote-object OF s" remote_object" LOG:TEXT+ ENDOF
      conflict-copy-occupied OF
         s" conflict_copy_occupied" LOG:TEXT+
      ENDOF
   ;MATCH ;

public

\ Rust's warning for path's download, blocked for reason b.
: WARN-BLOCKED ( MODEL:blockage MODEL:path -- )
   {: b path :}
   LOG:WARN s" replay" LOG:LINE
   s" exact download blocked for its path `" LOG:TEXT+
   path MODEL:PATH>STR str> LOG:TEXT+ s" `: " LOG:TEXT+
   b REASON+ LOG:;LINE ;

private

\ The copy of path, its download blocked b, logged once.
: DOWNLOAD-BLOCKED ( MODEL:blockage MODEL:path -- copy-outcome )
   {: b path :}
   b path WARN-BLOCKED b REPLAY-COPY--OUTCOME:BLOCKED ;

: >CONFLICT-OUTCOME ( exact-copy-outcome MODEL:path -- copy-outcome )
   {: path :}
   MATCH exact-copy-outcome
      ready OF REPLAY-COPY--OUTCOME:READY ENDOF
      destination-changed OF COPY-OCCUPIED ENDOF
      stage-occupied OF
         MODEL-BLOCKAGE:STAGE-OCCUPIED path DOWNLOAD-BLOCKED
      ENDOF
      content-changed OF
         MODEL-BLOCKAGE:DOWNLOAD-VERIFICATION-FAILED
         path DOWNLOAD-BLOCKED
      ENDOF
      blocked OF path DOWNLOAD-BLOCKED ENDOF
   ;MATCH ;

\ The path of path's conflict copy holding the remote's bytes.
: REMOTE-COPY-PATH
   ( MODEL:path MODEL:remote ^ARENA:arena -- MODEL:path )
   {: path rem ar :}
   rem MODEL-REMOTE:UNMAKE {: c v :}
   path MODEL:PATH>STR str> LOCAL-CONFLICT--SIDE:REMOTE c ar
   LOCAL:CONFLICT-RELATIVE-PATH >str MODEL:>PATH ;

: NAME-HELD? ( n n -- bool ) drop COPY-NAME-OCCUPIED? ;

: NO-BLOCKAGE ( -- option<MODEL:blockage> ) OPTION:NONE ;
: UNAVAILABLE ( -- option<MODEL:blockage> )
   409 MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE OPTION:SOME ;
: UNVERIFIED ( -- option<MODEL:blockage> )
   MODEL-BLOCKAGE:DOWNLOAD-VERIFICATION-FAILED OPTION:SOME ;

\ The blockage a download refused for e earns; none: the refusal is
\ about the pass, not the path.
: ERROR-BLOCKAGE ( DROPBOX:error -- option<MODEL:blockage> )
   MATCH DROPBOX:error
      not-found OF UNAVAILABLE ENDOF
      not-file OF UNAVAILABLE ENDOF
      not-folder OF UNAVAILABLE ENDOF
      malformed-path OF UNAVAILABLE ENDOF
      disallowed-name OF UNAVAILABLE ENDOF
      conflict OF NO-BLOCKAGE ENDOF
      no-write-permission OF UNAVAILABLE ENDOF
      restricted-content OF UNAVAILABLE ENDOF
      access-restricted OF UNAVAILABLE ENDOF
      team-folder OF UNAVAILABLE ENDOF
      operation-suppressed OF UNAVAILABLE ENDOF
      insufficient-space OF UNAVAILABLE ENDOF
      locked OF UNAVAILABLE ENDOF
      reset OF NO-BLOCKAGE ENDOF
      invalid-root OF NO-BLOCKAGE ENDOF
      content-hash-mismatch OF NO-BLOCKAGE ENDOF
      unsupported-file OF UNAVAILABLE ENDOF
      path-mismatch OF UNAVAILABLE ENDOF
      unverified OF UNVERIFIED ENDOF
      other OF UNAVAILABLE ENDOF
   ;MATCH ;

: REPLY-BLOCKAGE ( DROPBOX:reply -- option<MODEL:blockage> )
   MATCH DROPBOX:reply
      done OF NO-BLOCKAGE ENDOF
      refused OF ERROR-BLOCKAGE ENDOF
      retry OF drop NO-BLOCKAGE ENDOF
      unlinked OF NO-BLOCKAGE ENDOF
   ;MATCH ;

: UNAVAILABLE-AS ( n -- option<MODEL:blockage> )
   MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE OPTION:SOME ;

\ The client's last status, when a 4xx, blocks the download.
: STATUS-BLOCKAGE ( ^link -- option<MODEL:blockage> )
   REPLAY-LINK:CLIENT @ DROPBOX:HTTP-STATUS {: st:n :}
   st 400 >= st 500 < and if st UNAVAILABLE-AS exit then
   NO-BLOCKAGE ;

public

\ Rust's download_block_reason for Dropbox's answers; none: the
\ failure is the pass's, which the caller rethrows.
: DOWNLOAD-BLOCKAGE ( n ^link -- option<MODEL:blockage> )
   {: code:n k :}
   code E-DROPBOX = if k REPLAY-LINK:REPLY @ REPLY-BLOCKAGE exit then
   code DROPBOX:E-BAD-REQUEST = code DROPBOX:E-STATUS = or
   if k STATUS-BLOCKAGE exit then
   NO-BLOCKAGE ;

private

: DROP-EXACT ( exact-copy-outcome -- ) drop ;

public

\ Rust's materialize_remote_copy_at: the remote's bytes at t, shown as path,
\ never over a file; blocked by any failure DOWNLOAD-BLOCKAGE classifies.
: MATERIALIZE-REMOTE-COPY-AT
   ( ^link fd ^u8 n MODEL:path MODEL:path MODEL:remote ^ARENA:arena
     -- exact-copy-outcome )
   {: k root:fd r:^ ru:n t path rem ar :}
   EXACT-READY [: DROP-EXACT k root r ru t path rem ar
      EXACT-COPY-AT ;] catch {: code:n :}
   code 0= if exit then
   drop code k DOWNLOAD-BLOCKAGE MATCH option
      none OF code throw ENDOF
      some OF construct exact-copy-outcome blocked ENDOF
   ;MATCH ;

\ Rust's materialize_remote_conflict_at, below the open root at path r;
\ an occupied name or a blocked download blocks it.
: MATERIALIZE-REMOTE-CONFLICT-AT
   ( ^link fd ^u8 n MODEL:path MODEL:remote ^ARENA:arena
     -- copy-outcome )
   {: k root:fd r:^ ru:n path rem ar :}
   path rem ar REMOTE-COPY-PATH {: copy :}
   COPY-OCCUPIED [: DROP-COPY k root r ru copy path rem ar
      MATERIALIZE-REMOTE-COPY-AT path >CONFLICT-OUTCOME ;]
   ['] NAME-HELD? LOCAL:CONVERTING {: code:n :}
   code 0= if exit then
   drop code FS:ERRNO NAME-HELD? if COPY-OCCUPIED exit then
   code throw ;


\ ---- remote replay -------------------------------------------------

private

\ ---- blocks

\ Rust's mutation_rejection_tag.
: REJECTION-TAG ( mutation-rejection -- ^u8 n )
   MATCH mutation-rejection
      unsupported-file-size OF s" unsupported_file_size" ENDOF
      invalid-path OF s" invalid_path" ENDOF
      disallowed-name OF s" disallowed_name" ENDOF
      permission-denied OF s" permission_denied" ENDOF
      insufficient-space OF s" insufficient_space" ENDOF
      operation-not-allowed OF s" operation_not_allowed" ENDOF
      path-mismatch OF s" path_mismatch" ENDOF
      rejected-by-dropbox OF s" rejected_by_dropbox" ENDOF
      content-hash-mismatch OF s" content_hash_mismatch" ENDOF
   ;MATCH ;

\ Rust's sync_error: the rejection, logged, blocks the plan.
: SYNC-ERROR ( mutation-rejection ^pass -- apply-event )
   {: why r :}
   LOG:ERROR s" replay" LOG:LINE
   s" Dropbox rejected sync path `" LOG:TEXT+
   r RUN-TARGET LOG:TEXT+ s" `: " LOG:TEXT+
   why REJECTION-TAG LOG:TEXT+ LOG:;LINE
   r RUN-PATH why REPLAY-REPLAY--BLOCKED:SYNC-ERROR r BLOCKED ;

: LATER ( -- n ) epoch-seconds JOURNAL:BLOCK-RETRY-SECONDS + ;

\ An oversize stage is never retried: waiting does not shrink it.
: RETRY-AT ( MODEL:blockage -- n )
   MATCH MODEL:blockage
      unsupported-file-size OF MEM-MAX-N ENDOF
      remote-rejected OF drop LATER ENDOF
      download-unavailable OF drop LATER ENDOF
      download-verification-failed OF LATER ENDOF
      stage-occupied OF LATER ENDOF
      local-object-in-way OF LATER ENDOF
      remote-object OF LATER ENDOF
      conflict-copy-occupied OF LATER ENDOF
   ;MATCH ;

: LOST ( MODEL:path -- )
   s" mutation blocker lost its owning plan" INVALID ;

\ Rust's block_durably: the plan is held until its retry time.
: BLOCK-DURABLY ( MODEL:blockage ^pass -- replay-blocked )
   {: why r :}
   r PASS-JOURNAL @ r PASS-PLAN @ PLAN-ID why why RETRY-AT
   r PASS-ARENA @ JOURNAL:BLOCK-PLAN
   MATCH JOURNAL:plan-block
      blocked OF
         r RUN-PATH why REPLAY-REPLAY--BLOCKED:DURABLE-PLAN
      ENDOF
      already-completed OF r RUN-PATH LOST ENDOF
      not-found OF r RUN-PATH LOST ENDOF
   ;MATCH ;

: REMOTE-REJECTED ( mutation-rejection -- MODEL:blockage )
   REJECTION-TAG >str MODEL-BLOCKAGE:REMOTE-REJECTED ;

: REJECTED-BLOCKAGE ( mutation-rejection -- MODEL:blockage )
   {: why :}
   why MATCH mutation-rejection
      unsupported-file-size OF
         MODEL-BLOCKAGE:UNSUPPORTED-FILE-SIZE
      ENDOF
      invalid-path OF why REMOTE-REJECTED ENDOF
      disallowed-name OF why REMOTE-REJECTED ENDOF
      permission-denied OF why REMOTE-REJECTED ENDOF
      insufficient-space OF why REMOTE-REJECTED ENDOF
      operation-not-allowed OF why REMOTE-REJECTED ENDOF
      path-mismatch OF why REMOTE-REJECTED ENDOF
      rejected-by-dropbox OF why REMOTE-REJECTED ENDOF
      content-hash-mismatch OF why REMOTE-REJECTED ENDOF
   ;MATCH ;

\ Rust's persist_remote_block: a block Dropbox or the stage caused
\ holds the plan durably; any other answers itself.
: PERSIST-REMOTE-BLOCK ( replay-blocked ^pass -- replay-blocked )
   {: b r :}
   b MATCH replay-blocked
      sync-error OF {: p why :}
         why REJECTED-BLOCKAGE r BLOCK-DURABLY
      ENDOF
      stage-destination-occupied OF drop drop
         MODEL-BLOCKAGE:STAGE-OCCUPIED r BLOCK-DURABLY
      ENDOF
      remote-object OF
         drop MODEL-BLOCKAGE:REMOTE-OBJECT r BLOCK-DURABLY
      ENDOF
      durable-plan OF drop drop b ENDOF
      local-object OF drop b ENDOF
      fresh-observation-required OF drop b ENDOF
      download-required OF drop drop b ENDOF
      precondition-changed OF drop drop b ENDOF
      remote-operation OF drop b ENDOF
      remote-pending OF drop b ENDOF
   ;MATCH ;

: NO-BLOCK ( -- option<replay-blocked> ) OPTION:NONE ;

\ Rust's unplaced_copy: none when the conflict copy was placed.
: UNPLACED-COPY ( copy-outcome ^pass -- option<replay-blocked> )
   {: r :}
   MATCH copy-outcome
      ready OF NO-BLOCK ENDOF
      blocked OF r BLOCK-DURABLY OPTION:SOME ENDOF
      source-changed OF r SUPERSEDED OPTION:SOME ENDOF
   ;MATCH ;


\ ---- upload stage

: SOURCE-CHANGED? ( n n -- bool ) drop LOCAL:E-SOURCE-CHANGED = ;

: NO-UPLOAD-STAGE ( -- LOCAL:stage-outcome<^LOCAL:staged-upload> )
   s" " >str LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED ;
: DROP-STAGE ( LOCAL:stage-outcome<^LOCAL:staged-upload> -- ) drop ;

\ The run's target staged for upload as want, and the code a changed
\ source threw, else 0.
: STAGE
   ( DROPBOX:hash ^pass -- LOCAL:stage-outcome<^LOCAL:staged-upload> n )
   {: want r :}
   NO-UPLOAD-STAGE [: DROP-STAGE r PASS-ROOT @ r RUN-TARGET
      r PASS-STAGING @ str> want r PASS-ARENA @ LOCAL:STAGE-UPLOAD-AT ;]
   ['] SOURCE-CHANGED? LOCAL:CONVERTING ;

\ Other bytes hold the stage's path p.
: STAGE-HELD ( str ^pass -- apply-event )
   {: p:str r :}
   r PASS-PLAN @ PLAN-ID p
   REPLAY-REPLAY--BLOCKED:STAGE-DESTINATION-OCCUPIED r BLOCKED ;

: STAGED
   ( LOCAL:stage-outcome<^LOCAL:staged-upload> ^pass
     [ ^LOCAL:staged-upload -- apply-event ] -- apply-event )
   {: r send :}
   MATCH LOCAL:stage-outcome
      staged OF send execute ENDOF
      already-staged OF send execute ENDOF
      content-changed OF drop r STALE ENDOF
      destination-occupied OF r STAGE-HELD ENDOF
   ;MATCH ;

\ Rust's prepare_upload: send runs on the target's stage; a target
\ changed since its plan retires the plan.
: PREPARE-UPLOAD
   ( DROPBOX:hash ^pass [ ^LOCAL:staged-upload -- apply-event ]
     -- apply-event )
   {: want r send :}
   want r STAGE {: code:n :}
   code 0= if r send STAGED exit then
   drop code LOCAL:E-SOURCE-CHANGED = if r STALE exit then
   code throw ;


\ ---- folder outcomes

\ The completion is written at once and counted.
: COMPLETED ( MODEL:baseline ^pass -- apply-event )
   {: b r :}
   r PASS-JOURNAL @ r PASS-OPERATION @ r RUN-PATH b r PASS-ARENA @
   COMPLETE-FINAL
   1 r COUNTED construct apply-event done ;

: PENDING-REMOTE ( ^pass -- apply-event )
   {: r :}
   r RUN-PATH REPLAY-REPLAY--BLOCKED:REMOTE-PENDING r BLOCKED ;

: FOLDER-MADE ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      folder OF MODEL-BASELINE:DIRECTORY r COMPLETED ENDOF
      absent OF r STALE ENDOF
      file OF drop r STALE ENDOF
      unsupported OF r STALE ENDOF
   ;MATCH ;

\ Rust's apply_folder_mutation.
: APPLY-FOLDER-MUTATION ( mutation-outcome ^pass -- apply-event )
   {: r :}
   MATCH mutation-outcome
      applied OF r FOLDER-MADE ENDOF
      pending OF r PENDING-REMOTE ENDOF
      precondition-changed OF drop r STALE ENDOF
      rejected OF r SYNC-ERROR ENDOF
   ;MATCH ;

: IMPOSSIBLE-APPLIED ( ^pass -- )
   RUN-PATH s" folder delete returned an impossible applied state"
   INVALID ;

: IMPOSSIBLE-ABSENT ( ^pass -- )
   RUN-PATH
   s" folder delete precondition changed to an impossible absent state"
   INVALID ;

: FOLDER-GONE ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      absent OF MODEL-BASELINE:ABSENT r COMPLETED ENDOF
      file OF drop r IMPOSSIBLE-APPLIED ENDOF
      folder OF r IMPOSSIBLE-APPLIED ENDOF
      unsupported OF r IMPOSSIBLE-APPLIED ENDOF
   ;MATCH ;

: FOLDER-CHANGED ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      folder OF r STALE ENDOF
      file OF drop r STALE ENDOF
      unsupported OF r STALE ENDOF
      absent OF r IMPOSSIBLE-ABSENT ENDOF
   ;MATCH ;

\ Rust's apply_folder_delete_mutation: only an absent folder completes
\ the plan, so a replay after a crash stays idempotent.
: APPLY-FOLDER-DELETE-MUTATION
   ( mutation-outcome ^pass -- apply-event )
   {: r :}
   MATCH mutation-outcome
      applied OF r FOLDER-GONE ENDOF
      pending OF r PENDING-REMOTE ENDOF
      precondition-changed OF r FOLDER-CHANGED ENDOF
      rejected OF r SYNC-ERROR ENDOF
   ;MATCH ;


\ ---- file outcomes

\ Rust's FileMutation: the upload creates the file or replaces a rev.
ENUM file-mutation add replace ;ENUM

\ The plan finishes as the conflict, counted; the baseline stays.
: CONFLICTED ( MODEL:conflict ^pass -- apply-event )
   {: x r :}
   r PASS-JOURNAL @ r PASS-PLAN @ PLAN-ID r RUN-PATH x
   r PASS-ARENA @ FINISH-CONFLICT
   1 r COUNTED construct apply-event done ;

\ next runs once the copy is placed; an unplaced one blocks the plan.
: PLACED
   ( option<replay-blocked> ^pass [ -- apply-event ] -- apply-event )
   {: r next :}
   MATCH option
      none OF next execute ENDOF
      some OF r BLOCKED ENDOF
   ;MATCH ;

\ The upload's bytes as the run's local conflict copy.
: KEEP-LOCAL ( ^LOCAL:staged-upload ^pass -- option<replay-blocked> )
   {: up r :}
   r RUN-ROOT r RUN-PATH up r PASS-ARENA @
   MATERIALIZE-LOCAL-CONFLICT-AT r UNPLACED-COPY ;

\ The remote's bytes as the run's remote conflict copy.
: KEEP-REMOTE ( MODEL:remote ^pass -- option<replay-blocked> )
   {: rem r :}
   r PASS-LINK @ r RUN-ROOT r RUN-PATH rem r PASS-ARENA @
   MATERIALIZE-REMOTE-CONFLICT-AT r UNPLACED-COPY ;

: LOCAL-SIDE ( ^LOCAL:staged-upload -- MODEL:local )
   LOCAL:UPLOAD-CONTENT MODEL-LOCAL:MAKE ;

: COLLISION
   ( MODEL:local MODEL:remote file-mutation -- MODEL:conflict )
   MATCH file-mutation
      add OF MODEL-CONFLICT:INITIAL ENDOF
      replace OF MODEL-CONFLICT:DIVERGENT ENDOF
   ;MATCH ;

: COLLIDED
   ( MODEL:remote ^LOCAL:staged-upload file-mutation ^pass
     -- apply-event )
   {: rem up m r :}
   rem r KEEP-REMOTE r
   [: up LOCAL-SIDE rem m COLLISION r CONFLICTED ;] PLACED ;

\ Both sides are placed, the local one first, before the plan
\ finishes.
: FILE-CONFLICT
   ( MODEL:remote ^LOCAL:staged-upload file-mutation ^pass
     -- apply-event )
   {: rem up m r :}
   up r KEEP-LOCAL r [: rem up m r COLLIDED ;] PLACED ;

\ Dropbox deleted the file the upload replaces.
: LOCAL-EDITED ( ^LOCAL:staged-upload ^pass -- apply-event )
   {: up r :}
   up r KEEP-LOCAL r
   [: up LOCAL-SIDE MODEL-CONFLICT:REMOTE-DELETED r CONFLICTED ;]
   PLACED ;

\ Dropbox's answer contradicts the run's journaled state.
: CONTRADICTED ( ^u8 n ^pass -- )
   {: t:^ tu:n r :}
   r RUN-PATH t tu INVALID ;

: REMOTE-GONE
   ( ^LOCAL:staged-upload file-mutation ^pass -- apply-event )
   {: up m r :}
   m MATCH file-mutation
      replace OF up r LOCAL-EDITED ENDOF
      add OF
         s" create precondition changed to an impossible absent state"
         r CONTRADICTED
      ENDOF
   ;MATCH ;

: REMOTE-OBJECT ( ^pass -- apply-event )
   {: r :}
   r RUN-PATH REPLAY-REPLAY--BLOCKED:REMOTE-OBJECT r BLOCKED ;

: IMPOSSIBLE-UPLOAD ( ^pass -- )
   {: r :}
   s" file mutation returned an impossible applied state"
   r CONTRADICTED ;

: FILE-STORED ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      file OF MODEL-BASELINE:PRESENT r COMPLETED ENDOF
      absent OF r IMPOSSIBLE-UPLOAD ENDOF
      folder OF r IMPOSSIBLE-UPLOAD ENDOF
      unsupported OF r IMPOSSIBLE-UPLOAD ENDOF
   ;MATCH ;

: FILE-CHANGED
   ( remote-path-state ^LOCAL:staged-upload file-mutation ^pass
     -- apply-event )
   {: up m r :}
   MATCH remote-path-state
      file OF up m r FILE-CONFLICT ENDOF
      absent OF up m r REMOTE-GONE ENDOF
      folder OF r REMOTE-OBJECT ENDOF
      unsupported OF r REMOTE-OBJECT ENDOF
   ;MATCH ;

\ Rust's apply_file_mutation: a changed file keeps both sides before
\ the plan finishes as a conflict.
: APPLY-FILE-MUTATION
   ( mutation-outcome ^LOCAL:staged-upload file-mutation ^pass
     -- apply-event )
   {: up m r :}
   MATCH mutation-outcome
      applied OF r FILE-STORED ENDOF
      pending OF r PENDING-REMOTE ENDOF
      precondition-changed OF up m r FILE-CHANGED ENDOF
      rejected OF r SYNC-ERROR ENDOF
   ;MATCH ;


\ ---- delete outcomes

: OPERATION-OF ( JOURNAL:planned-operation -- MODEL:operation )
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o s :} o ;

: MAKES-FOLDER? ( MODEL:operation -- bool )
   MATCH MODEL:operation
      create-remote-directory OF true ENDOF
      create-local-directory OF false ENDOF
      delete-local-directory OF false ENDOF
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

\ Rust's keeps_directory: the plan makes a folder where the file was.
: KEEPS-FOLDER? ( ^pass -- bool )
   PASS-PLAN @ PLAN-OPERATIONS {: ops :}
   false ops VEC:COUNT 0 ?do
      ops i VEC:AT @ OPERATION-OF MAKES-FOLDER? or
   loop ;

\ Whether the run's operation is its plan's last.
: LAST? ( ^pass -- bool )
   {: r :}
   r PASS-PLAN @ PLAN-OPERATIONS {: ops :}
   ops ops VEC:COUNT 1- VEC:AT @ OPERATION-ID JOURNAL:OPERATION-ID>N
   r PASS-OPERATION @ OPERATION-ID JOURNAL:OPERATION-ID>N = ;

: IMPOSSIBLE-DELETE ( ^pass -- )
   {: r :}
   s" delete mutation returned an impossible applied state"
   r CONTRADICTED ;

\ Only the plan's last operation writes the absent baseline.
: FILE-DELETED ( ^pass -- apply-event )
   {: r :}
   r LAST? if MODEL-BASELINE:ABSENT r COMPLETED exit then
   r COMPLETED-NONFINAL ;

: FILE-GONE ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      absent OF r FILE-DELETED ENDOF
      file OF drop r IMPOSSIBLE-DELETE ENDOF
      folder OF r IMPOSSIBLE-DELETE ENDOF
      unsupported OF r IMPOSSIBLE-DELETE ENDOF
   ;MATCH ;

\ Dropbox's edit of the file the plan deletes keeps the remote side.
: REMOTE-EDITED ( MODEL:remote ^pass -- apply-event )
   {: rem r :}
   r KEEPS-FOLDER? if r STALE exit then
   rem r KEEP-REMOTE r
   [: rem MODEL-CONFLICT:LOCAL-DELETED r CONFLICTED ;] PLACED ;

: OBJECT-THERE ( ^pass -- apply-event )
   {: r :}
   r KEEPS-FOLDER? if r STALE exit then
   r REMOTE-OBJECT ;

\ A plan that makes a folder there needs the file gone, which it is.
: ALREADY-GONE ( ^pass -- apply-event )
   {: r :}
   r KEEPS-FOLDER? if r COMPLETED-NONFINAL exit then
   s" delete precondition changed to an impossible absent state"
   r CONTRADICTED ;

: DELETE-CHANGED ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      file OF r REMOTE-EDITED ENDOF
      folder OF r OBJECT-THERE ENDOF
      unsupported OF r OBJECT-THERE ENDOF
      absent OF r ALREADY-GONE ENDOF
   ;MATCH ;

\ Rust's apply_delete_mutation.
: APPLY-DELETE-MUTATION ( mutation-outcome ^pass -- apply-event )
   {: r :}
   MATCH mutation-outcome
      applied OF r FILE-GONE ENDOF
      pending OF r PENDING-REMOTE ENDOF
      precondition-changed OF r DELETE-CHANGED ENDOF
      rejected OF r SYNC-ERROR ENDOF
   ;MATCH ;


\ ---- parent folders

: IMPOSSIBLE-PARENT ( ^pass -- )
   {: r :}
   s" parent folder creation returned an impossible state"
   r CONTRADICTED ;

\ A parent that is a folder answers done, so the next one is made.
: PARENT-APPLIED ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      folder OF construct apply-event done ENDOF
      absent OF r IMPOSSIBLE-PARENT ENDOF
      file OF drop r IMPOSSIBLE-PARENT ENDOF
      unsupported OF r IMPOSSIBLE-PARENT ENDOF
   ;MATCH ;

: PARENT-CHANGED ( remote-path-state ^pass -- apply-event )
   {: r :}
   MATCH remote-path-state
      file OF drop r REMOTE-OBJECT ENDOF
      unsupported OF r REMOTE-OBJECT ENDOF
      absent OF r IMPOSSIBLE-PARENT ENDOF
      folder OF r IMPOSSIBLE-PARENT ENDOF
   ;MATCH ;

: PARENT-MADE ( mutation-outcome ^pass -- apply-event )
   {: r :}
   MATCH mutation-outcome
      applied OF r PARENT-APPLIED ENDOF
      pending OF r PENDING-REMOTE ENDOF
      precondition-changed OF r PARENT-CHANGED ENDOF
      rejected OF r SYNC-ERROR ENDOF
   ;MATCH ;

\ The folder at the run's target's first n bytes.
: PARENT ( ^pass n -- apply-event )
   {: r n:n :}
   r RUN-TARGET drop n >str MODEL:>PATH {: dir :}
   r PASS-LINK @ dir r PASS-ARENA @ REMOTE-CREATE-FOLDER
   r PARENT-MADE ;

: STOPS? ( apply-event -- bool )
   MATCH apply-event
      done OF false ENDOF
      blocked OF true ENDOF
   ;MATCH ;

\ Rust's ensure_remote_parents: next runs once each parent of the
\ run's path, shortest first, is a Dropbox folder.
: ENSURE-REMOTE-PARENTS
   ( ^pass [ -- apply-event ] -- apply-event )
   {: r next :}
   r RUN-TARGET {: p:^ u:n :}
   u 0 ?do
      p i + c@ SLASH = if
         r i PARENT dup STOPS? if unloop exit then drop
      then
   loop
   next execute ;


\ ---- operations

: NO-REV ( -- DROPBOX:rev ) s" " >str DROPBOX:>REV ;

: FOLDER-CREATE ( ^pass -- apply-event )
   {: r :}
   r [: r PASS-LINK @ r RUN-PATH r PASS-ARENA @ REMOTE-CREATE-FOLDER
      r APPLY-FOLDER-MUTATION ;] ENSURE-REMOTE-PARENTS ;

: SEND-NEW ( ^LOCAL:staged-upload ^pass -- apply-event )
   {: up r :}
   r [: r PASS-LINK @ r RUN-PATH up NO-REV r PASS-ARENA @
      REMOTE-UPLOAD up FILE-MUTATION-ADD r APPLY-FILE-MUTATION ;]
   ENSURE-REMOTE-PARENTS ;

: FILE-CREATE ( DROPBOX:hash ^pass -- apply-event )
   {: want r :}
   want r [: r SEND-NEW ;] PREPARE-UPLOAD ;

: SEND-OVER ( ^LOCAL:staged-upload DROPBOX:rev ^pass -- apply-event )
   {: up v:DROPBOX:rev r :}
   r PASS-LINK @ r RUN-PATH up v r PASS-ARENA @ REMOTE-UPLOAD
   up FILE-MUTATION-REPLACE r APPLY-FILE-MUTATION ;

: FILE-REPLACE ( DROPBOX:hash DROPBOX:rev ^pass -- apply-event )
   {: want v:DROPBOX:rev r :}
   want r [: v r SEND-OVER ;] PREPARE-UPLOAD ;

: FILE-DELETE ( DROPBOX:rev ^pass -- apply-event )
   {: v:DROPBOX:rev r :}
   r PASS-LINK @ r RUN-PATH v r PASS-ARENA @ REMOTE-DELETE-FILE
   r APPLY-DELETE-MUTATION ;

: FOLDER-DELETE ( ^pass -- apply-event )
   {: r :}
   r PASS-LINK @ r RUN-PATH r PASS-ARENA @ REMOTE-DELETE-FOLDER
   r APPLY-FOLDER-DELETE-MUTATION ;


\ ---- the remote operation's machine

ENUM remote-state DERIVE eq
   recorded applying passed stopped yielded ;ENUM
ENUM remote-event done blocked local ;ENUM

: >REMOTE-EVENT ( apply-event -- remote-event )
   MATCH apply-event
      done OF construct remote-event done ENDOF
      blocked OF construct remote-event blocked ENDOF
   ;MATCH ;

: YIELD ( -- remote-event ) construct remote-event local ;

\ The run's operation sent to Dropbox; a local one waits for local
\ replay.
: APPLY-REMOTE ( ^pass -- remote-event )
   {: r :}
   r RUN-OPERATION MATCH MODEL:operation
      create-remote-directory OF r FOLDER-CREATE >REMOTE-EVENT ENDOF
      preserve-remote OF
         drop r COMPLETED-NONFINAL >REMOTE-EVENT
      ENDOF
      create-remote OF r FILE-CREATE >REMOTE-EVENT ENDOF
      replace-remote OF r FILE-REPLACE >REMOTE-EVENT ENDOF
      delete-remote OF r FILE-DELETE >REMOTE-EVENT ENDOF
      delete-remote-directory OF r FOLDER-DELETE >REMOTE-EVENT ENDOF
      create-local-directory OF YIELD ENDOF
      delete-local-directory OF YIELD ENDOF
      install-local OF drop YIELD ENDOF
      preserve-local OF drop YIELD ENDOF
      replace-local OF drop drop YIELD ENDOF
      delete-local OF drop YIELD ENDOF
   ;MATCH ;

\ The block, held durably where Dropbox or the stage caused it, goes in
\ the report.
: STOP-REMOTE ( ^pass -- )
   {: r :}
   r PASS-BLOCKED @ r PERSIST-REMOTE-BLOCK
   r PASS-REPORT @ REPLAY-REPLAY--REPORT:BLOCKED @ VEC:PUSH ! ;

\ One remote operation's replay, after formal/RemoteLifecycle.tla: a
\ completed one passes; a pending one is applied, or yields if local.
FSM:DEFINE REMOTE-LIFECYCLE ( ^pass ) remote-state remote-event
   IN recorded  STATUS ( JOURNAL:record-status )
      completed  -            >passed
      pending    -            >applying
   IN applying  APPLY-REMOTE
      done     REMOTE-DONE  >passed
      blocked  -            >stopped
      local    -            >yielded
   FINAL passed   -
   FINAL stopped  STOP-REMOTE
   FINAL yielded  -
;DEFINE

\ Runs the machine on r's operation; answers its final state.
: REMOTE-RUN ( ^pass -- remote-state )
   {: r :}
   construct remote-state recorded
   begin r swap REMOTE-LIFECYCLE-STEP until ;

: PASSED? ( remote-state -- bool )
   construct remote-state passed REMOTE-STATE-EQ ;

\ An excluded plan is retired; another's operations run in order
\ until one stops it or is local.
: REPLAY-REMOTE-PLAN ( JOURNAL:plan-record ^pass -- )
   {: p r :}
   p r RUNNABLE? 0= if exit then
   p PLAN-OPERATIONS {: ops :}
   ops VEC:COUNT 0 ?do
      ops i VEC:AT @ r PASS-OPERATION !
      r REMOTE-RUN PASSED? 0= if leave then
   loop ;

public

\ Replays the pending plans' Dropbox operations below root path r,
\ staging uploads in s; each completion is written as it happens.
: REPLAY-REMOTE-OPERATIONS-AT
   ( JOURNAL:journal ^link fd ^u8 n ^u8 n ^ARENA:arena
     -- ^replay-report )
   {: j l root:fd r:^ ru:n s:^ su:n ar :}
   j root r ru ar NEW-PASS {: run :}
   l run PASS-LINK ! s su >str run PASS-STAGING !
   j ar JOURNAL:PENDING-PLANS {: plans :}
   plans VEC:COUNT 0 ?do
      plans i VEC:AT @ run REPLAY-REMOTE-PLAN
   loop
   run PASS-REPORT @ ;

;package
