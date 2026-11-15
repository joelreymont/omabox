\ replay.f - package REPLAY: the pending plans' replay (rust
\ src/recovery.rs): what a replay pass reports, the outcomes its steps
\ answer, the journal steps that finish, supersede or complete a plan,
\ and the retention of legacy recovery payloads. A LOCAL, JOURNAL or
\ DROPBOX failure passes up with its own code, which that library
\ logged where it saw it. A journal answer the replay contract refuses
\ is logged once with the Rust version's text, naming the plan's path,
\ then thrown as E-INVALID-STATE. A failed retention syscall is logged
\ once, as LOCAL logs one, and thrown as LOCAL's E-IO.
\ STORAGE CLASS. No state of its own. CALLER-OWNED: a report, its
\ vector, and every value a journal step reads lie in the arena the
\ caller passes. A retention pass lays its values in an arena of its
\ own and closes the directory it opens, on every exit.

require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/vector.f
require src/lib/fs.f
require src/lib/fs-anchored.f
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

\ Rust's LocalError::Io for operation o on path p: FS:ERRNO holds the
\ errno, kept across the log.
: RETENTION-IO ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   FS:ERRNO {: e:n :}
   LOG:ERROR s" replay" LOG:LINE
   s" local filesystem operation `" LOG:TEXT+ o ou LOG:TEXT+
   s" ` failed for `" LOG:TEXT+ p u LOG:TEXT+ s" `" LOG:TEXT+
   e 0<> if s" : errno " LOG:TEXT+ e LOG:INT+ then
   LOG:;LINE
   e FS:CAUSE! LOCAL:E-IO throw ;

\ As Rust's drop of an OwnedFd, it ignores close's own failure.
: CLOSE-DIRECTORY ( fd -- ) FD>N close ;

: SYNC-DIRECTORY ( fd str -- )
   {: dir:fd d:str :}
   [: dir FD:SYNC ;] catch {: code:n :}
   code 0= if exit then
   code E-FS-IO <> if code throw then
   s" sync recovery retention" d str> RETENTION-IO ;

\ statat of the name, never a symlink's target; none once it is gone.
\ o names the operation, p the payload's path.
: STAT-AT ( fd ^u8 n ^u8 n MODEL:path -- option<stat> )
   {: dir:fd nm:^ nu:n o:^ ou:n p :}
   dir nm nu FS:TRY-STAT-AT if
      FS:STAT-DEV@ FS:STAT-INO@ FS:STAT-MODE@ STAT-MAKE OPTION:SOME
      exit
   then
   FS:ERRNO FS:ENOENT = if NO-STAT exit then
   o ou p MODEL:PATH>STR str> RETENTION-IO ;

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
   du 0= d du FS:JOIN-SEPARATED? or if 0 else 1 then {: sep:n :}
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
: FORGET ( retention JOURNAL:recovery-record -- n )
   {: x r :}
   x DIR-OF x PATH-OF SYNC-DIRECTORY
   x JOURNAL-OF r FORGET-RECOVERY ;

\ VERIFY-PRIVATE-COPY's failures that keep the payload where it is.
: KEEPS? ( n -- bool )
   {: code:n :}
   code LOCAL:E-CORRUPT = code LOCAL:E-UNSUPPORTED = or
   code LOCAL:E-CHANGED = or code LOCAL:E-OCCUPIED = or
   code LOCAL:E-CONTENT-HASH = or code LOCAL:E-UNSAFE-PATH = or ;

\ Whether the payload at the name holds the record's content.
: VERIFY ( retention JOURNAL:recovery-record ^u8 n -- bool )
   {: x r nm:^ nu:n :}
   x DIR-OF x PATH-OF str> nm nu r CONTENT x ARENA-OF
   LOCAL:VERIFY-PRIVATE-COPY ;

\ Removes the payload, gone already or not, then forgets the record.
: REMOVE ( retention JOURNAL:recovery-record ^u8 n -- n )
   {: x r nm:^ nu:n :}
   x DIR-OF nm nu FS:TRY-REMOVE-FILE-AT 0= if
      FS:ERRNO FS:ENOENT <> if
         s" remove expired recovery payload"
         r COPY-PATH MODEL:PATH>STR str> RETENTION-IO
      then
   then
   x r FORGET ;

\ The verified payload, removed while it is the file inspected before.
: REINSPECT ( retention JOURNAL:recovery-record ^u8 n stat -- n )
   {: x r nm:^ nu:n before :}
   x DIR-OF nm nu s" reinspect retained recovery payload" r COPY-PATH
   STAT-AT MATCH option
      none OF x r FORGET ENDOF
      some OF {: after :}
         after REGULAR? before after SAME-INODE? and
         if x r nm nu REMOVE else 0 then
      ENDOF
   ;MATCH ;

\ The expired payload: forgotten when gone, removed when verified,
\ kept on a failure that concerns it alone.
: CHECKED ( retention JOURNAL:recovery-record ^u8 n stat -- n )
   {: x r nm:^ nu:n before :}
   false [: drop x r nm nu VERIFY ;] catch {: code:n :}
   code 0= if
      if x r nm nu before REINSPECT else x r FORGET then exit
   then
   drop code KEEPS? if 0 exit then
   code throw ;

\ The payload at the name: forgotten when gone, kept when it is not a
\ regular file or its retention has not run out.
: INSPECT ( retention JOURNAL:recovery-record ^u8 n -- n )
   {: x r nm:^ nu:n :}
   x DIR-OF nm nu s" inspect retained recovery payload" r COPY-PATH
   STAT-AT MATCH option
      none OF x r FORGET ENDOF
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
   [: x PRUNE-ALL ;] [: dir CLOSE-DIRECTORY ;] finally ;

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

;package
