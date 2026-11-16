\ replay-test.f - REPLAY's steps, each case in a directory of its own
\ under TMPDIR, which it removes:
\ - RETIRE-EXCLUDED-PLANS, given two pending plans, one at an excluded
\   name, supersedes that one and leaves the other, in the vector and in
\   the journal's pending plans.
\ - Retention removes and forgets a verified payload only once its
\   retention runs out, keeps pending, blocked, corrupt, non-regular and
\   unknown entries, and forgets a record whose payload is already gone.
\ - REPLAY-LOCAL-PLANS-AT below a sync root: Rust's
\   legacy_local_preservation_replays_without_creating_a_copy, and a
\   directory at one plan's install target blocking only that plan,
\   logging nothing, the next plan's directory made and its baseline
\   written.
\ - MATERIALIZE-LOCAL-CONFLICT, given a staged upload in a fresh sync
\   root, answers blocked conflict-copy-occupied for a directory at the
\   copy's name, logging nothing, or an unreadable file there, and ready
\   beside a directory elsewhere, and passes up LOCAL's E-IO when the
\   copy's parent denies writes.
\ Run from the repository root: hb --load src/replay-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
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

\ Runs q with fd 2 sent to stderr.txt in the case's directory d, which
\ q must leave empty: q logs nothing.
: QUIETLY ( str [ -- ] ^ARENA:arena -- )
   {: d:str q ar :}
   d s" stderr.txt" ar INSIDE str> {: e:^ eu:n :}
   e eu STDERR:CAPTURE
   [: q execute ;] [: STDERR:;CAPTURE ;] finally
   e eu FS:FILE-SIZE 0 T=
   e eu FS:REMOVE-FILE ;


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

: COPY-PATH$ ( JOURNAL:recovery-record -- ^u8 n )
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

: STATUS>N ( JOURNAL:record-status -- n )
   MATCH JOURNAL:record-status
      pending OF 0 ENDOF
      completed OF 1 ENDOF
   ;MATCH ;

\ 1 and the time a retention started, 0 0 when it has not.
: START>N ( option<n> -- n n )
   MATCH option
      none OF 0 0 ENDOF
      some OF 1 swap ENDOF
   ;MATCH ;

: SAME-START? ( option<n> option<n> -- bool )
   {: a b :}
   a START>N {: af:n at:n :}
   b START>N {: bf:n bt:n :}
   af bf = at bt = and ;

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
   c DROPBOX:HASH>STR str> c2 DROPBOX:HASH>STR str> STR= and
   s STATUS>N s2 STATUS>N = and
   t t2 SAME-START? and ;

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
   rec COPY-PATH$ s" retained bytes" FS:WRITE-ALL
   rec COPY-PATH$ MODIFIED-AT-EPOCH
   j plan rec ar COMPLETE-RECOVERY-AND-PLAN
   j rec ar RETAINED-START REPLAY:COMPLETED-RECOVERY-RETENTION +
   {: boundary:n :}
   j r str> boundary 1- REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 0 T=
   rec COPY-PATH$ FS:FILE? TTRUE
   j r str> boundary REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 1 T=
   rec COPY-PATH$ FS:EXISTS? TFALSE
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
   rec COPY-PATH$ w wu FS:WRITE-ALL
   plan rec ;

\ A completed recovery whose payload is a directory.
: NONREGULAR
   ( JOURNAL:journal str ^ARENA:arena -- JOURNAL:recovery-record )
   {: j r:str ar :}
   j r s" nonregular.txt" s" directory bytes" ar HASH-OF ar
   RECORD-RECOVERY {: plan rec :}
   rec COPY-PATH$ FS:MAKE-DIR
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
   pending COPY-PATH$ FS:FILE? TTRUE
   blocked COPY-PATH$ FS:FILE? TTRUE
   corrupt COPY-PATH$ FS:FILE? TTRUE
   nonregular COPY-PATH$ FS:DIR? TTRUE
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
   rec COPY-PATH$ FS:REMOVE-FILE
   j r str> epoch-seconds REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 1 T=
   j rec FORGOTTEN
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

\ The replay completed the other plan's one operation and blocked
\ only the plan at taken.txt, on the local object there.
: TAKEN-BLOCKED ( ^REPLAY:replay-report -- )
   {: r :}
   r COMPLETED 1 T=
   r BLOCKS VEC:COUNT 1 T=
   r BLOCKS 0 VEC:AT @ s" taken.txt" LOCAL-OBJECT-AT? TTRUE ;

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
   d [: j root ar REPLAYED TAKEN-BLOCKED ;] ar QUIETLY
   root s" made" ar INSIDE str> FS:EXISTS? TTRUE
   j s" made" DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   j ar JOURNAL:PENDING-PLANS s" taken.txt" ONLY-AT
   j JOURNAL:CLOSE
   d GONE ;


\ ---- local conflict copies -----------------------------------------

\ 0500: its owner reads and searches it, but writes nothing in it.
$140 constant MODE-NO-WRITE

\ A case's directory, and the sync root and upload staging made in it.
: CONFLICT-DIRS ( ^ARENA:arena -- str str str )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   d s" root" ar INSIDE {: r:str :}
   d s" staging" ar INSIDE {: s:str :}
   r str> FS:MAKE-DIR s str> FS:MAKE-DIR
   d r s ;

: UPLOAD-OF
   ( LOCAL:stage-outcome<^LOCAL:staged-upload> -- ^LOCAL:staged-upload )
   MATCH LOCAL:stage-outcome
      staged OF ENDOF
      already-staged OF ENDOF
      content-changed OF drop LOCAL:E-CHANGED throw ENDOF
      destination-occupied OF drop LOCAL:E-OCCUPIED throw ENDOF
   ;MATCH ;

\ The file at p below the root, written and staged as an upload.
: STAGED
   ( str str ^u8 n ^ARENA:arena -- ^LOCAL:staged-upload )
   {: r:str s:str p:^ u:n ar :}
   r p u ar INSIDE str> s" local edit" FS:WRITE-ALL
   r str> p u ar LOCAL:OBSERVE-UPLOAD-SOURCE {: c:DROPBOX:hash :}
   r str> p u s str> c ar LOCAL:STAGE-UPLOAD UPLOAD-OF ;

\ The absolute path of p's local conflict copy holding the upload.
: COPY-NAME
   ( str ^u8 n ^LOCAL:staged-upload ^ARENA:arena -- str )
   {: r:str p:^ u:n up ar :}
   p u LOCAL-CONFLICT--SIDE:LOCAL up LOCAL:UPLOAD-CONTENT ar
   LOCAL:CONFLICT-RELATIVE-PATH {: c:^ cu:n :}
   r c cu ar INSIDE ;

: REASON$ ( MODEL:blockage -- ^u8 n )
   MATCH MODEL:blockage
      unsupported-file-size OF s" other" ENDOF
      remote-rejected OF drop s" other" ENDOF
      download-unavailable OF drop s" other" ENDOF
      download-verification-failed OF s" other" ENDOF
      stage-occupied OF s" other" ENDOF
      local-object-in-way OF s" other" ENDOF
      remote-object OF s" other" ENDOF
      conflict-copy-occupied OF s" conflict-copy-occupied" ENDOF
   ;MATCH ;

\ The outcome's variant, and a blocked one's reason, else empty.
: OUTCOME$ ( REPLAY:copy-outcome -- ^u8 n ^u8 n )
   MATCH REPLAY:copy-outcome
      ready OF s" ready" s" " ENDOF
      blocked OF {: b:MODEL:blockage :} s" blocked" b REASON$ ENDOF
      source-changed OF s" source-changed" s" " ENDOF
   ;MATCH ;

\ The local conflict copy of p, written below the root r.
: LOCAL-COPY$
   ( str ^u8 n ^LOCAL:staged-upload ^ARENA:arena -- ^u8 n ^u8 n )
   {: r:str p:^ u:n up ar :}
   r str> p u DISPLAY up ar REPLAY:MATERIALIZE-LOCAL-CONFLICT OUTCOME$ ;

: BLOCKED-OCCUPIED ( ^u8 n ^u8 n -- )
   s" conflict-copy-occupied" T$= s" blocked" T$= ;

\ An unreadable file at the copy's name blocks the copy.
: UNREADABLE-COPY ( str ^LOCAL:staged-upload str ^ARENA:arena -- )
   {: r:str up c:str ar :}
   c str> s" other bytes" FS:WRITE-ALL
   c str> 0 FS:CHMOD-MODE
   [: r s" notes.txt" up ar LOCAL-COPY$ BLOCKED-OCCUPIED ;]
   [: c str> FS:MODE-PRIVATE-FILE FS:CHMOD-MODE ;] finally
   c str> FS:REMOVE-FILE ;

: ONLY-AN-OBJECT-AT-THE-COPY-NAME-OCCUPIES-IT ( ^ARENA:arena -- )
   {: ar :}
   s" only_an_object_at_the_copy_name_occupies_it" T-LABEL
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   r s" notes.txt" up ar COPY-NAME {: c:str :}
   c str> FS:MAKE-DIR
   d [: r s" notes.txt" up ar LOCAL-COPY$ BLOCKED-OCCUPIED ;] ar
   QUIETLY
   c str> FS:REMOVE-DIR
   r up c ar UNREADABLE-COPY
   r s" notes.d" ar INSIDE str> FS:MAKE-DIR
   r s" notes.txt" up ar LOCAL-COPY$ s" " T$= s" ready" T$=
   d GONE ;

\ The copy below dir, which denies writes; LOCAL's E-IO passes up.
: DENIED-COPY ( str ^LOCAL:staged-upload ^ARENA:arena -- )
   {: r:str up ar :}
   [: r str> s" dir/notes.txt" DISPLAY up ar
      REPLAY:MATERIALIZE-LOCAL-CONFLICT drop ;] LOCAL:E-IO TTHROWSQ
   FS:ERRNO FS:EACCES T= ;

: A-DENIED-OPERATION-AT-THE-COPY-NAME-DOES-NOT-OCCUPY-IT
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_denied_operation_at_the_copy_name_does_not_occupy_it" T-LABEL
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s" dir" ar INSIDE {: dir:str :}
   dir str> FS:MAKE-DIR
   r s s" dir/notes.txt" ar STAGED {: up :}
   dir str> MODE-NO-WRITE FS:CHMOD-MODE
   [: r up ar DENIED-COPY ;]
   [: dir str> FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;] finally
   d GONE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ar RETENTION-EXPIRES-VERIFIED-PAYLOAD-ONLY-AT-BOUNDARY
   ar RETENTION-KEEPS-PENDING-CORRUPT-NONREGULAR-AND-ORPHAN-ENTRIES
   ar RETENTION-FINISHES-METADATA-CLEANUP-AFTER-PAYLOAD-DELETION
   ar LEGACY-LOCAL-PRESERVATION-REPLAYS-WITHOUT-CREATING-A-COPY
   ar A-LOCAL-OBJECT-BLOCKS-ONLY-ITS-PLAN
   ar ONLY-AN-OBJECT-AT-THE-COPY-NAME-OCCUPIES-IT
   ar A-DENIED-OPERATION-AT-THE-COPY-NAME-DOES-NOT-OCCUPY-IT ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" replay-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
