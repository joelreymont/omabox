\ replay-test.f - REPLAY's journal steps and recovery retention on
\ a journal under TMPDIR: RETIRE-EXCLUDED-PLANS, given two pending
\ plans, one at an excluded name, supersedes that one and leaves the
\ other, in the vector and in the journal's pending plans. Retention
\ removes and forgets a verified payload only once its retention runs
\ out, keeps pending, blocked, corrupt, non-regular and unknown
\ entries, and forgets a record whose payload is already gone. Each
\ case removes its directory.
\ Run from the repository root: hb --load src/replay-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/lib/vector.f
require src/lib/adt/option.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f
require src/local.f
require src/replay.f

\ REPLAY reopened for the retention words the Rust tests call.
package REPLAY
public
EXPORT PRUNE-COMPLETED-RECOVERIES-AT
EXPORT DESTINATION
;package

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

\ Rust's RetentionFixture: a case's directory, the journal path in it
\ and its recovery directory, made.
: FIXTURE ( ^ARENA:arena -- str str str )
   {: ar :}
   ar JOURNAL-AT {: d:str p:str :}
   d s" recovery" ar INSIDE {: r:str :}
   r str> FS:MAKE-DIR
   d p r ;

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


\ ---- recoveries ----------------------------------------------------

: FAILED ( ^u8 n -- ) T-EX-FAIL die ;

\ Rust's dropbox_content_hash of the bytes, read from a pipe.
: HASH-OF ( ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: b:^ u:n ar :}
   FD:PIPE {: r:fd w:fd :}
   w b u FD:WRITE-FULL w FS:CLOSE-DIR
   r ar LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR ;

\ The content preserved as a local file, then deleted where it stands.
: PRESERVED-DELETE
   ( DROPBOX:hash ^ARENA:arena -- JOURNAL:operation-plan )
   {: c ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW {: ops :}
   c MODEL-LOCAL:MAKE MODEL-OPERATION:PRESERVE-LOCAL ops VEC:PUSH !
   c MODEL-OPERATION:DELETE-LOCAL ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

: NEW-PLAN ( JOURNAL:plan-write -- JOURNAL:plan-record )
   MATCH JOURNAL:plan-write
      recorded OF ENDOF
      already-live OF
         drop s" test path unexpectedly had a pending plan" FAILED
      ENDOF
   ;MATCH ;

: NOT-RECORDED ( -- )
   s" test recovery intent was not recorded" FAILED ;

: NEW-RECOVERY ( JOURNAL:recovery-write -- JOURNAL:recovery-record )
   MATCH JOURNAL:recovery-write
      recorded OF ENDOF
      already-recorded OF drop NOT-RECORDED ENDOF
      operation-not-found OF NOT-RECORDED ENDOF
      operation-completed OF NOT-RECORDED ENDOF
      operation-not-destructive OF NOT-RECORDED ENDOF
   ;MATCH ;

\ The id of the plan's operation k; the plan holds two.
: NTH-ID ( JOURNAL:plan-record n -- JOURNAL:operation-id )
   {: plan k :}
   plan JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops VEC:COUNT 2 T=
   ops k VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE {: i o x st :} i ;

: ID-OF ( JOURNAL:recovery-record -- n )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :}
   id JOURNAL:RECOVERY-ID>N ;

: COPY$ ( JOURNAL:recovery-record -- ^u8 n )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :}
   q MODEL:PATH>STR str> ;

\ Rust's record_recovery: a plan preserving, then deleting, the
\ content at the path, whose deletion records a recovery intent
\ copying to the destination in the recovery directory r.
: RECORD-RECOVERY
   ( JOURNAL:journal str ^u8 n DROPBOX:hash ^ARENA:arena
     -- JOURNAL:plan-record JOURNAL:recovery-record )
   {: j r:str a:^ u:n c ar :}
   a u DISPLAY {: original :}
   j original c ar PRESERVED-DELETE ar JOURNAL:RECORD-PLAN NEW-PLAN
   {: plan :}
   r str> original c ar REPLAY:DESTINATION {: copy :}
   plan
   j plan 1 NTH-ID copy ar JOURNAL:RECORD-RECOVERY-INTENT
   NEW-RECOVERY ;

: COMPLETED? ( JOURNAL:recovery-completion -- bool )
   MATCH JOURNAL:recovery-completion
      not-found OF false ENDOF
      already-completed OF false ENDOF
      completed OF true ENDOF
   ;MATCH ;

: OPERATION-COMPLETED? ( JOURNAL:operation-completion -- bool )
   MATCH JOURNAL:operation-completion
      operation-completed OF true ENDOF
      not-found OF false ENDOF
      already-completed OF false ENDOF
      waiting-for-earlier-operation OF drop false ENDOF
      baseline-required OF false ENDOF
      unexpected-baseline OF false ENDOF
      baseline-mismatch OF false ENDOF
      plan-completed OF false ENDOF
   ;MATCH ;

: PLAN-COMPLETED? ( JOURNAL:operation-completion -- bool )
   MATCH JOURNAL:operation-completion
      plan-completed OF true ENDOF
      not-found OF false ENDOF
      already-completed OF false ENDOF
      waiting-for-earlier-operation OF drop false ENDOF
      baseline-required OF false ENDOF
      unexpected-baseline OF false ENDOF
      baseline-mismatch OF false ENDOF
      operation-completed OF false ENDOF
   ;MATCH ;

: NO-BASELINE ( -- option<MODEL:baseline> ) OPTION:NONE ;

: COMPLETE ( JOURNAL:journal JOURNAL:recovery-record -- )
   {: j rec :}
   j rec JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :} id
   JOURNAL:COMPLETE-RECOVERY COMPLETED? TTRUE ;

\ Rust's complete_recovery_and_plan: the recovery, then the plan's
\ preservation and its deletion, which leaves the path absent.
: COMPLETE-RECOVERY-AND-PLAN
   ( JOURNAL:journal JOURNAL:plan-record JOURNAL:recovery-record
     ^ARENA:arena -- )
   {: j plan rec ar :}
   j rec COMPLETE
   j plan 0 NTH-ID NO-BASELINE ar JOURNAL:COMPLETE-OPERATION
   OPERATION-COMPLETED? TTRUE
   j plan 1 NTH-ID MODEL-BASELINE:ABSENT OPTION:SOME ar
   JOURNAL:COMPLETE-OPERATION PLAN-COMPLETED? TTRUE ;

: FORGOTTEN-BEFORE? ( JOURNAL:recovery-forget -- bool )
   MATCH JOURNAL:recovery-forget
      not-found OF true ENDOF
      pending OF false ENDOF
      forgotten OF false ENDOF
   ;MATCH ;

\ The record is no longer in the journal.
: FORGOTTEN ( JOURNAL:journal JOURNAL:recovery-record -- )
   {: j rec :}
   j rec JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :} id
   JOURNAL:FORGET-COMPLETED-RECOVERY FORGOTTEN-BEFORE? TTRUE ;

: STARTED ( JOURNAL:recovery-record -- n )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :}
   at MATCH option
      none OF s" test recovery retention did not start" FAILED ENDOF
      some OF ENDOF
   ;MATCH ;

\ Some record in the vector has the id.
: HOLDS? ( ^VEC:vector<JOURNAL:recovery-record> n -- bool )
   {: v id :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ ID-OF id = if true unloop exit then
   loop
   false ;

\ The fields of two recovery records agree, path and content bytes
\ compared.
: SAME-RECORD?
   ( JOURNAL:recovery-record JOURNAL:recovery-record -- bool )
   {: a b :}
   a JOURNAL-RECOVERY--RECORD:UNMAKE {: i o p q c s t :}
   b JOURNAL-RECOVERY--RECORD:UNMAKE {: i2 o2 p2 q2 c2 s2 t2 :}
   i JOURNAL:RECOVERY-ID>N i2 JOURNAL:RECOVERY-ID>N =
   o JOURNAL:OPERATION-ID>N o2 JOURNAL:OPERATION-ID>N = and
   p MODEL:PATH>STR str> p2 MODEL:PATH>STR str> STR= and
   q MODEL:PATH>STR str> q2 MODEL:PATH>STR str> STR= and
   c DROPBOX:HASH>STR str> c2 DROPBOX:HASH>STR str> STR= and ;

PROCESS-SYMBOLS
FUNCTION: UTIMENSAT-CALL utimensat ( n ^u8 ^u8 n -- i32 ) ;FUNCTION

-100 constant AT-FDCWD
$3FFFFFFE constant UTIME-OMIT
create TIMES 32 allot

\ The file's modification time set to the epoch, its access time kept.
: MODIFIED-AT-EPOCH ( ^u8 n -- )
   FS:>PATHZ {: z:^ :}
   0 TIMES ! UTIME-OMIT TIMES 8 + ! 0 TIMES 16 + ! 0 TIMES 24 + !
   AT-FDCWD z TIMES 0 UTIMENSAT-CALL 0 T= ;


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

\ The one completed recovery, rec, whose retention start it answers.
: RETAINED-START
   ( JOURNAL:journal JOURNAL:recovery-record ^ARENA:arena -- n )
   {: j rec ar :}
   j ar JOURNAL:COMPLETED-RECOVERIES {: done :}
   done VEC:COUNT 1 T=
   done 0 VEC:AT @ {: completed :}
   completed ID-OF rec ID-OF T=
   completed STARTED ;

\ The payload's modification time is the epoch: only the journal's
\ retention start decides when it expires.
: RETENTION-EXPIRES-VERIFIED-PAYLOAD-ONLY-AT-BOUNDARY
   ( ^ARENA:arena -- )
   {: ar :}
   s" retention_expires_verified_payload_only_at_boundary" T-LABEL
   ar FIXTURE {: d:str p:str r:str :}
   p JOURNAL:OPEN {: j :}
   s" retained bytes" ar HASH-OF {: c :}
   j r s" expired.txt" c ar RECORD-RECOVERY {: plan rec :}
   rec COPY$ s" retained bytes" FS:WRITE-ALL
   rec COPY$ MODIFIED-AT-EPOCH
   j plan rec ar COMPLETE-RECOVERY-AND-PLAN
   j rec ar RETAINED-START REPLAY:COMPLETED-RECOVERY-RETENTION +
   {: boundary:n :}
   j r str> boundary 1- REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 0 T=
   rec COPY$ FS:FILE? TTRUE
   j r str> boundary REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 1 T=
   rec COPY$ FS:EXISTS? TFALSE
   j rec FORGOTTEN
   j JOURNAL:CLOSE
   d GONE ;

\ A recovery of the content of the bytes b at the path a, with the
\ bytes w written as its payload.
: WRITTEN
   ( JOURNAL:journal str ^u8 n ^u8 n ^u8 n ^ARENA:arena
     -- JOURNAL:plan-record JOURNAL:recovery-record )
   {: j r:str a:^ u:n b:^ bu:n w:^ wu:n ar :}
   j r a u b bu ar HASH-OF ar RECORD-RECOVERY {: plan rec :}
   rec COPY$ w wu FS:WRITE-ALL
   plan rec ;

\ A completed recovery whose payload is a directory.
: NONREGULAR
   ( JOURNAL:journal str ^ARENA:arena -- JOURNAL:recovery-record )
   {: j r:str ar :}
   j r s" nonregular.txt" s" directory bytes" ar HASH-OF ar
   RECORD-RECOVERY {: plan rec :}
   rec COPY$ FS:MAKE-DIR
   j plan rec ar COMPLETE-RECOVERY-AND-PLAN
   rec ;

\ The journal still holds pending as its one pending recovery, and
\ corrupt and nonregular as its only completed ones.
: ELIGIBLE-KEPT
   ( JOURNAL:journal JOURNAL:recovery-record JOURNAL:recovery-record
     JOURNAL:recovery-record ^ARENA:arena -- )
   {: j pending corrupt nonregular ar :}
   j ar JOURNAL:PENDING-RECOVERIES {: still :}
   still VEC:COUNT 1 T=
   still 0 VEC:AT @ pending SAME-RECORD? TTRUE
   j ar JOURNAL:COMPLETED-RECOVERIES {: eligible :}
   eligible VEC:COUNT 2 T=
   eligible corrupt ID-OF HOLDS? TTRUE
   eligible nonregular ID-OF HOLDS? TTRUE ;

: RETENTION-KEEPS-PENDING-CORRUPT-NONREGULAR-AND-ORPHAN-ENTRIES
   ( ^ARENA:arena -- )
   {: ar :}
   s" retention_keeps_pending_corrupt_nonregular_and_orphan_entries"
   T-LABEL
   ar FIXTURE {: d:str p:str r:str :}
   p JOURNAL:OPEN {: j :}
   j r s" pending.txt" s" pending bytes" s" pending bytes" ar WRITTEN
   {: pp pending :}
   j r s" blocked.txt" s" blocked bytes" s" blocked bytes" ar WRITTEN
   {: bp blocked :}
   j blocked COMPLETE
   j r s" corrupt.txt" s" expected bytes" s" different bytes" ar
   WRITTEN
   {: cp corrupt :}
   j cp corrupt ar COMPLETE-RECOVERY-AND-PLAN
   j r ar NONREGULAR {: nonregular :}
   r s" unknown-orphan" ar INSIDE {: orphan:str :}
   orphan str> s" unknown bytes" FS:WRITE-ALL
   j r str> epoch-seconds REPLAY:COMPLETED-RECOVERY-RETENTION +
   REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 0 T=
   pending COPY$ FS:FILE? TTRUE
   blocked COPY$ FS:FILE? TTRUE
   corrupt COPY$ FS:FILE? TTRUE
   nonregular COPY$ FS:DIR? TTRUE
   orphan str> FS:FILE? TTRUE
   j pending corrupt nonregular ar ELIGIBLE-KEPT
   j JOURNAL:CLOSE
   d GONE ;

: RETENTION-FINISHES-METADATA-CLEANUP-AFTER-PAYLOAD-DELETION
   ( ^ARENA:arena -- )
   {: ar :}
   s" retention_finishes_metadata_cleanup_after_payload_deletion"
   T-LABEL
   ar FIXTURE {: d:str p:str r:str :}
   p JOURNAL:OPEN {: j :}
   j r s" interrupted.txt" s" deleted before retry"
   s" deleted before retry" ar WRITTEN {: plan rec :}
   j plan rec ar COMPLETE-RECOVERY-AND-PLAN
   rec COPY$ FS:REMOVE-FILE
   j r str> epoch-seconds REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 1 T=
   j rec FORGOTTEN
   j JOURNAL:CLOSE
   d GONE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ar RETENTION-EXPIRES-VERIFIED-PAYLOAD-ONLY-AT-BOUNDARY
   ar RETENTION-KEEPS-PENDING-CORRUPT-NONREGULAR-AND-ORPHAN-ENTRIES
   ar RETENTION-FINISHES-METADATA-CLEANUP-AFTER-PAYLOAD-DELETION ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" replay-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
