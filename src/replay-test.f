\ replay-test.f - REPLAY's steps, each case in a directory of its own
\ under TMPDIR, which it removes:
\ - RETIRE-EXCLUDED-PLANS, given two pending plans, one at an excluded
\   name, supersedes that one and leaves the other, in the vector and in
\   the journal's pending plans.
\ - Retention removes and forgets a verified payload only once its
\   retention runs out, keeps pending, blocked, corrupt, non-regular and
\   unknown entries, and forgets a record whose payload is already gone.
\ - Retention keeps an expired payload it cannot read and its record,
\   logging nothing, and forgets the next verified one; skipped as root.
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
\ - CLASSIFY over every pair of expectation and remote state, against
\   Rust's MutationExpectation::classify.
\ - REJECTION over every DROPBOX error: a path's rejection, or E-DROPBOX
\   with the refusal kept in the link.
\ - TARGET of a valid path below the link's root, and each invalid form
\   rejected invalid-path with no request reaching the fake.
\ - OVERSIZE? at 350 000 000 000 bytes and one more.
\ Against the fake Dropbox of test-dropbox.f, root empty:
\ - REMOTE-DELETE-FOLDER of an empty folder deletes it; of an occupied
\   one, or one the listing answers not_found or reset, deletes nothing;
\   a file the delete finds in the folder's place is logged once.
\ - REMOTE-UPLOAD of a new file sends its progress, then a finished
\   transfer to a STATUS in TMPDIR; one Dropbox refuses as a conflict
\   with other bytes at the path is read back as changed, and its
\   finished transfer is sent.
\ - STAGE-EXACT-DOWNLOAD-AT against the fake Dropbox: Rust's
\   exact_download_retry_reuses_a_stage_without_consuming_the_body,
\   exact_download_stage_race_preserves_verified_stage, with the stage
\   back while the call is in flight, and
\   corrupt_exact_download_never_leaves_installable_bytes; a download
\   lost mid-body throws E-DROPBOX with a retry, keeps its slot and
\   leaks no descriptor, and the next stages it; a slot holding a
\   checkpoint: a 416 at its length finishes the stage, a lost answer
\   keeps it, sent with its Range, and another 416 restarts it; a
\   download's progress, then finished, in a status under TMPDIR.
\ - MATERIALIZE-REMOTE-CONFLICT downloads the copy once, then is ready
\   with no request; a directory or other bytes at the copy's name
\   block it conflict-copy-occupied, logging nothing; other bytes at
\   its stage block it stage-occupied with no request.
\   MATERIALIZE-REMOTE-COPY-AT installs at a target apart from the
\   source path, and answers destination-changed for other bytes there.
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
require src/lib/fs-list.f
require src/lib/aio.f
require src/lib/net/curl.f
require src/dropbox.f
require src/test-dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f
require src/local.f
require src/status.f
require src/replay.f

\ REPLAY reopened for the retention words the Rust tests call, the
\ Dropbox mutations' steps, and the checkpoint a slot resumes from.
package REPLAY
public
EXPORT PRUNE-COMPLETED-RECOVERIES-AT
EXPORT DESTINATION
EXPORT TARGET
EXPORT CLASSIFY
EXPORT REJECTION
EXPORT OVERSIZE?
EXPORT EXPECTATION-CREATE-FILE
EXPORT EXPECTATION-REPLACE-FILE
EXPORT EXPECTATION-DELETE-FILE
EXPORT EXPECTATION-CREATE-FOLDER
EXPORT EXPECTATION-DELETE-FOLDER
EXPORT REMOTE-CREATE-FOLDER
EXPORT REMOTE-UPLOAD
EXPORT REMOTE-DELETE-FOLDER
EXPORT LOCAL:DOWNLOAD-CHECKPOINT-BYTES
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
FUNCTION: GETEUID-CALL geteuid ( -- i32 ) ;FUNCTION

-100 constant AT-FDCWD
$3FFFFFFE constant UTIME-OMIT
create TIMES 32 allot

\ The file's modification time set to the epoch, its access time kept.
: MODIFIED-AT-EPOCH ( ^u8 n -- )
   FS:>PATHZ {: z:^ :}
   0 TIMES ! UTIME-OMIT TIMES 8 + ! 0 TIMES 16 + ! 0 TIMES 24 + !
   AT-FDCWD z TIMES 0 UTIMENSAT-CALL 0 T= ;

\ Root reads a mode-000 file, so its cases skip.
: ROOT-USER? ( -- bool ) GETEUID-CALL 0 = ;


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

\ A completed recovery of its own bytes, expired.
: VERIFIED
   ( JOURNAL:journal str ^u8 n ^u8 n ^ARENA:arena
     -- JOURNAL:recovery-record )
   {: j r:str a:^ u:n b:^ bu:n ar :}
   j r a u b bu b bu ar WRITTEN {: plan rec :}
   j plan rec ar COMPLETE-RECOVERY-AND-PLAN
   rec ;

\ Prunes at the end of retention, quietly, while locked is mode 000.
: PRUNE-LOCKED
   ( JOURNAL:journal str str JOURNAL:recovery-record ^ARENA:arena
     -- )
   {: j d:str r:str locked ar :}
   locked COPY-PATH$ 0 FS:CHMOD-MODE
   [: d [: j r str> epoch-seconds REPLAY:COMPLETED-RECOVERY-RETENTION +
      REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 1 T= ;] ar QUIETLY ;]
   [: locked COPY-PATH$ FS:MODE-PRIVATE-FILE FS:CHMOD-MODE ;] finally ;

: RETENTION-KEEPS-AN-UNREADABLE-PAYLOAD ( ^ARENA:arena -- )
   {: ar :}
   s" retention keeps an unreadable payload" T-LABEL
   ROOT-USER? if exit then
   ar FIXTURE {: d:str p:str r:str :}
   p JOURNAL:OPEN {: j :}
   j r s" locked.txt" s" locked bytes" ar VERIFIED {: locked :}
   j r s" verified.txt" s" verified bytes" ar VERIFIED {: verified :}
   j d r locked ar PRUNE-LOCKED
   locked COPY-PATH$ FS:FILE? TTRUE
   verified COPY-PATH$ FS:EXISTS? TFALSE
   j verified FORGOTTEN
   j ar JOURNAL:COMPLETED-RECOVERIES {: kept :}
   kept VEC:COUNT 1 T=
   kept locked ID-OF HOLDS? TTRUE
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
      stage-occupied OF s" stage-occupied" ENDOF
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


\ ---- Dropbox mutations ---------------------------------------------

TYPED-VARIABLE CFG DROPBOX:config
\ The client on the fake, while it serves.
TYPED-VARIABLE MAIN ^DROPBOX:client

: STATE$ ( REPLAY:remote-path-state -- ^u8 n )
   MATCH REPLAY:remote-path-state
      absent OF s" absent" ENDOF
      file OF drop s" file" ENDOF
      folder OF s" folder" ENDOF
      unsupported OF s" unsupported" ENDOF
   ;MATCH ;

: REJECTION$ ( REPLAY:mutation-rejection -- ^u8 n )
   MATCH REPLAY:mutation-rejection
      invalid-path OF s" invalid-path" ENDOF
      unsupported-file-size OF s" unsupported-file-size" ENDOF
      disallowed-name OF s" disallowed-name" ENDOF
      permission-denied OF s" permission-denied" ENDOF
      insufficient-space OF s" insufficient-space" ENDOF
      operation-not-allowed OF s" operation-not-allowed" ENDOF
      path-mismatch OF s" path-mismatch" ENDOF
      rejected-by-dropbox OF s" rejected-by-dropbox" ENDOF
   ;MATCH ;

\ The outcome's variant and its state's or rejection's name.
: MUTATION$ ( REPLAY:mutation-outcome -- ^u8 n ^u8 n )
   MATCH REPLAY:mutation-outcome
      applied OF s" applied" rot STATE$ ENDOF
      pending OF s" pending" s" " ENDOF
      precondition-changed OF s" precondition-changed" rot STATE$ ENDOF
      rejected OF s" rejected" rot REJECTION$ ENDOF
   ;MATCH ;

: GIVES ( REPLAY:mutation-outcome ^u8 n ^u8 n -- )
   {: o a:^ au:n b:^ bu:n :}
   o MUTATION$ b bu T$= a au T$= ;

: AS-HASH ( ^u8 n -- DROPBOX:hash ) >str DROPBOX:>HASH ;
: AS-REV ( ^u8 n -- DROPBOX:rev ) >str DROPBOX:>REV ;

\ A file state of hash and rev.
: FILE-STATE ( ^u8 n ^u8 n -- REPLAY:remote-path-state )
   {: h:^ hu:n v:^ vu:n :}
   h hu AS-HASH v vu AS-REV MODEL-REMOTE:MAKE
   REPLAY-REMOTE--PATH--STATE:FILE ;

: GONE-STATE ( -- REPLAY:remote-path-state )
   REPLAY-REMOTE--PATH--STATE:ABSENT ;
: FOLDER-STATE ( -- REPLAY:remote-path-state )
   REPLAY-REMOTE--PATH--STATE:FOLDER ;
: ODD-STATE ( -- REPLAY:remote-path-state )
   REPLAY-REMOTE--PATH--STATE:UNSUPPORTED ;

: CREATING-H1 ( REPLAY:remote-path-state -- REPLAY:mutation-outcome )
   s" h1" AS-HASH REPLAY:EXPECTATION-CREATE-FILE REPLAY:CLASSIFY ;
\ Replacing r1 with h2.
: REPLACING-R1 ( REPLAY:remote-path-state -- REPLAY:mutation-outcome )
   s" r1" AS-REV s" h2" AS-HASH REPLAY:EXPECTATION-REPLACE-FILE
   REPLAY:CLASSIFY ;
: DELETING-R1 ( REPLAY:remote-path-state -- REPLAY:mutation-outcome )
   s" r1" AS-REV REPLAY:EXPECTATION-DELETE-FILE REPLAY:CLASSIFY ;
: CREATING-DIR ( REPLAY:remote-path-state -- REPLAY:mutation-outcome )
   REPLAY:EXPECTATION-CREATE-FOLDER REPLAY:CLASSIFY ;
: DELETING-DIR ( REPLAY:remote-path-state -- REPLAY:mutation-outcome )
   REPLAY:EXPECTATION-DELETE-FOLDER REPLAY:CLASSIFY ;

: CHANGED ( REPLAY:mutation-outcome ^u8 n -- )
   {: o s:^ su:n :}
   o s" precondition-changed" s su GIVES ;

: CREATE-FILE-ROWS ( -- )
   GONE-STATE CREATING-H1 s" pending" s" " GIVES
   s" h1" s" r1" FILE-STATE CREATING-H1 s" applied" s" file" GIVES
   s" h2" s" r1" FILE-STATE CREATING-H1 s" file" CHANGED
   FOLDER-STATE CREATING-H1 s" folder" CHANGED
   ODD-STATE CREATING-H1 s" unsupported" CHANGED ;

: REPLACE-FILE-ROWS ( -- )
   GONE-STATE REPLACING-R1 s" absent" CHANGED
   s" h2" s" r1" FILE-STATE REPLACING-R1 s" pending" s" " GIVES
   s" h2" s" r2" FILE-STATE REPLACING-R1 s" applied" s" file" GIVES
   s" h1" s" r2" FILE-STATE REPLACING-R1 s" file" CHANGED
   FOLDER-STATE REPLACING-R1 s" folder" CHANGED
   ODD-STATE REPLACING-R1 s" unsupported" CHANGED ;

: DELETE-FILE-ROWS ( -- )
   GONE-STATE DELETING-R1 s" applied" s" absent" GIVES
   s" h1" s" r1" FILE-STATE DELETING-R1 s" pending" s" " GIVES
   s" h1" s" r2" FILE-STATE DELETING-R1 s" file" CHANGED
   FOLDER-STATE DELETING-R1 s" folder" CHANGED
   ODD-STATE DELETING-R1 s" unsupported" CHANGED ;

: CREATE-FOLDER-ROWS ( -- )
   GONE-STATE CREATING-DIR s" pending" s" " GIVES
   s" h1" s" r1" FILE-STATE CREATING-DIR s" file" CHANGED
   FOLDER-STATE CREATING-DIR s" applied" s" folder" GIVES
   ODD-STATE CREATING-DIR s" unsupported" CHANGED ;

: DELETE-FOLDER-ROWS ( -- )
   GONE-STATE DELETING-DIR s" applied" s" absent" GIVES
   s" h1" s" r1" FILE-STATE DELETING-DIR s" file" CHANGED
   FOLDER-STATE DELETING-DIR s" pending" s" " GIVES
   ODD-STATE DELETING-DIR s" unsupported" CHANGED ;

: CLASSIFY-COVERS-EVERY-EXPECTATION-AND-STATE ( -- )
   s" classify covers every expectation and state" T-LABEL
   CREATE-FILE-ROWS REPLACE-FILE-ROWS DELETE-FILE-ROWS
   CREATE-FOLDER-ROWS DELETE-FOLDER-ROWS ;


ARENA LINKS REPLAY:link

\ A link on the client below root, with no status.
: NEW-LINK ( ^DROPBOX:client ^u8 n ^ARENA:arena -- ^REPLAY:link )
   {: c r:^ ru:n ar :}
   ar LINKS-NEW {: l :}
   c l REPLAY-LINK:CLIENT ! r ru ar COPIED l REPLAY-LINK:ROOT !
   l ;

: REJECTS ( DROPBOX:error ^REPLAY:link ^u8 n -- )
   {: e l want:^ wu:n :}
   e l REPLAY:REJECTION REJECTION$ want wu T$= ;

: REFUSAL? ( DROPBOX:reply DROPBOX:error -- bool )
   {: e:DROPBOX:error :}
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF e DROPBOX-ERROR:EQ ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

\ The refusal stops the pass, kept whole in the link.
: STOPS ( DROPBOX:error ^REPLAY:link -- )
   {: e l :}
   [: e l REPLAY:REJECTION drop ;] REPLAY:E-DROPBOX TTHROWSQ
   l REPLAY-LINK:REPLY @ e REFUSAL? TTRUE ;

: PATH-REFUSALS ( ^REPLAY:link -- )
   {: l :}
   DROPBOX-ERROR:NOT-FOUND l s" rejected-by-dropbox" REJECTS
   DROPBOX-ERROR:NOT-FILE l s" rejected-by-dropbox" REJECTS
   DROPBOX-ERROR:NOT-FOLDER l s" rejected-by-dropbox" REJECTS
   DROPBOX-ERROR:MALFORMED-PATH l s" invalid-path" REJECTS
   DROPBOX-ERROR:DISALLOWED-NAME l s" disallowed-name" REJECTS
   DROPBOX-ERROR:NO-WRITE-PERMISSION l s" permission-denied" REJECTS
   DROPBOX-ERROR:RESTRICTED-CONTENT l s" rejected-by-dropbox" REJECTS
   DROPBOX-ERROR:ACCESS-RESTRICTED l s" permission-denied" REJECTS
   DROPBOX-ERROR:TEAM-FOLDER l s" operation-not-allowed" REJECTS
   DROPBOX-ERROR:OPERATION-SUPPRESSED l s" operation-not-allowed" REJECTS
   DROPBOX-ERROR:INSUFFICIENT-SPACE l s" insufficient-space" REJECTS
   DROPBOX-ERROR:LOCKED l s" rejected-by-dropbox" REJECTS
   DROPBOX-ERROR:UNSUPPORTED-FILE l s" rejected-by-dropbox" REJECTS
   DROPBOX-ERROR:PATH-MISMATCH l s" path-mismatch" REJECTS
   DROPBOX-ERROR:OTHER l s" rejected-by-dropbox" REJECTS ;

: REJECTION-COVERS-EVERY-DROPBOX-ERROR ( ^ARENA:arena -- )
   {: ar :}
   s" rejection covers every Dropbox error" T-LABEL
   MAIN @ s" " ar NEW-LINK {: l :}
   l PATH-REFUSALS
   DROPBOX-ERROR:CONFLICT l STOPS
   DROPBOX-ERROR:RESET l STOPS
   DROPBOX-ERROR:INVALID-ROOT l STOPS
   DROPBOX-ERROR:CONTENT-HASH-MISMATCH l STOPS
   DROPBOX-ERROR:UNVERIFIED l STOPS ;

: TARGET$ ( ^REPLAY:link ^u8 n ^ARENA:arena -- ^u8 n )
   {: l p:^ u:n ar :}
   l p u DISPLAY ar REPLAY:TARGET MATCH option
      some OF str> ENDOF
      none OF s" none" ENDOF
   ;MATCH ;

\ p is no Dropbox path: no target, and no call is made for it.
: NO-TARGET ( ^REPLAY:link ^u8 n ^ARENA:arena -- )
   {: l p:^ u:n ar :}
   l p u ar TARGET$ s" none" T$=
   TEST-DROPBOX:RESET
   l p u DISPLAY ar REPLAY:REMOTE-CREATE-FOLDER
   s" rejected" s" invalid-path" GIVES
   TEST-DROPBOX:SEEN$ s" " T$= ;

: INVALID-FORMS ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   l s" " ar NO-TARGET l s" /a" ar NO-TARGET l s" a/" ar NO-TARGET
   l s" a//b" ar NO-TARGET l s" ./a" ar NO-TARGET
   l s" a/./b" ar NO-TARGET
   l s" a/../b" ar NO-TARGET l s" .." ar NO-TARGET
   l s\" a\xFFb" ar NO-TARGET l s\" a\x00b" ar NO-TARGET ;

: TARGET-JOINS-THE-ROOT-AND-REJECTS-INVALID-PATHS ( ^ARENA:arena -- )
   {: ar :}
   s" target joins the root and rejects invalid paths" T-LABEL
   MAIN @ s" /Sync" ar NEW-LINK {: l :}
   l s" a/B.txt" ar TARGET$ s" /Sync/a/B.txt" T$=
   MAIN @ s" " ar NEW-LINK {: top :}
   top s" a" ar TARGET$ s" /a" T$=
   top s" .a/b..c/ d" ar TARGET$ s" /.a/b..c/ d" T$=
   l ar INVALID-FORMS ;

: UPLOAD-SIZE-STOPS-AT-THE-SESSION-LIMIT ( -- )
   s" upload size stops at the session limit" T-LABEL
   350000000000 REPLAY:OVERSIZE? TFALSE
   350000000001 REPLAY:OVERSIZE? TTRUE ;


\ ---- against the fake Dropbox

: OWN-PAGE ( bool -- )
   {: more:bool :}
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/f\q,\qpath_display\q:\q/f\q}]"
   s" c1" more TEST-DROPBOX:PAGE! ;

: DELETE-F ( ^REPLAY:link ^ARENA:arena -- REPLAY:mutation-outcome )
   {: l ar :}
   l s" f" DISPLAY ar REPLAY:REMOTE-DELETE-FOLDER ;

: AN-EMPTY-FOLDER-IS-DELETED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" an empty folder is deleted" T-LABEL
   TEST-DROPBOX:RESET
   l s" f" DISPLAY ar REPLAY:REMOTE-CREATE-FOLDER
   s" applied" s" folder" GIVES
   false OWN-PAGE
   l ar DELETE-F s" applied" s" absent" GIVES
   TEST-DROPBOX:SEEN$
   s" /2/files/create_folder_v2 /2/files/list_folder /2/files/delete_v2"
   T$= ;

: AN-OCCUPIED-FOLDER-IS-KEPT ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" an occupied folder is kept" T-LABEL
   TEST-DROPBOX:RESET
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/f\q,\qpath_display\q:\q/f\q},{\q.tag\q:\qfile\q,\qpath_lower\q:\q/f/a.txt\q,\qpath_display\q:\q/f/a.txt\q,\qrev\q:\q015f\q,\qsize\q:3,\qcontent_hash\q:\qabc\q}]"
   s" c1" false TEST-DROPBOX:PAGE!
   l ar DELETE-F s" precondition-changed" s" folder" GIVES
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$= ;

: A-MISSING-FOLDER-IS-ALREADY-DELETED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a missing folder is already deleted" T-LABEL
   TEST-DROPBOX:RESET
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath/not_found/\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnot_found\q}}}"
   TEST-DROPBOX:SCRIPT!
   l ar DELETE-F s" applied" s" absent" GIVES
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$= ;

: A-RESET-PROBE-LEAVES-THE-DELETE-PENDING ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a reset probe leaves the delete pending" T-LABEL
   TEST-DROPBOX:RESET
   true OWN-PAGE TEST-DROPBOX:PAGE-RESET!
   l ar DELETE-F s" pending" s" " GIVES
   TEST-DROPBOX:SEEN$
   s" /2/files/list_folder /2/files/list_folder/continue" T$= ;

4096 constant LOG-CAP
LOG-CAP BUFFER: LOG-TEXT

\ Runs q with fd 2 sent to a file in the case's directory d; its text.
: LOGGED ( str [ -- ] ^ARENA:arena -- ^u8 n )
   {: d:str q ar :}
   d s" stderr.txt" ar INSIDE str> {: e:^ eu:n :}
   e eu STDERR:CAPTURE
   [: q execute ;] [: STDERR:;CAPTURE ;] finally
   e eu LOG-TEXT LOG-CAP FS:READ-ALL {: u:n :}
   e eu FS:REMOVE-FILE
   LOG-TEXT u ;

: LINE-COUNT ( ^u8 n -- n ) 10 COUNT-CHAR ;

: A-FILE-THE-FOLDER-DELETE-FINDS-IS-LOGGED
   ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a file the folder delete finds is logged" T-LABEL
   TEST-DROPBOX:RESET
   s" /f" s" /f" s" 015f" s" abc" 3 TEST-DROPBOX:FILE!
   false OWN-PAGE
   s" replay-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   d [: l ar DELETE-F s" applied" s" absent" GIVES ;] ar LOGGED
   {: t:^ tu:n :}
   t tu LINE-COUNT 1 T=
   t tu s" Dropbox deleted a file that replaced the empty folder"
   CONTAINS? TTRUE
   t tu s" path=f revision=015f" CONTAINS? TTRUE
   d GONE ;

: RUNTIME-STATUS ( ^ARENA:arena -- str ^STATUS:status )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar COPIED {: rt:str :}
   rt rt ar STATUS:NEW ;

\ status.json's text below the runtime directory rt.
: STATUS-TEXT ( str ^ARENA:arena -- ^u8 n )
   {: rt:str ar :}
   rt s" omabox/status.json" ar INSIDE str> LOG-TEXT LOG-CAP FS:READ-ALL
   {: u:n :} LOG-TEXT u ;

: SHOWS ( str ^ARENA:arena ^u8 n -- )
   {: rt:str ar want:^ wu:n :}
   rt ar STATUS-TEXT want wu CONTAINS? TTRUE ;

: UPLOAD-NOTES
   ( ^REPLAY:link ^LOCAL:staged-upload ^ARENA:arena
     -- REPLAY:mutation-outcome )
   {: l up ar :}
   l s" notes.txt" DISPLAY up s" " AS-REV ar REPLAY:REMOTE-UPLOAD ;

: APPLIED-FILE ( REPLAY:mutation-outcome -- MODEL:remote )
   MATCH REPLAY:mutation-outcome
      applied OF
         MATCH REPLAY:remote-path-state
            absent OF s" applied absent" FAILED ENDOF
            file OF ENDOF
            folder OF s" applied folder" FAILED ENDOF
            unsupported OF s" applied unsupported" FAILED ENDOF
         ;MATCH
      ENDOF
      pending OF s" pending" FAILED ENDOF
      precondition-changed OF drop s" changed" FAILED ENDOF
      rejected OF drop s" rejected" FAILED ENDOF
   ;MATCH ;

: AN-UPLOAD-SENDS-ITS-TRANSFER ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" an upload sends its transfer" T-LABEL
   TEST-DROPBOX:RESET
   ar RUNTIME-STATUS {: rt:str st :}
   st l REPLAY-LINK:STATUS !
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   l up ar UPLOAD-NOTES APPLIED-FILE MODEL-REMOTE:UNMAKE {: c v :}
   c DROPBOX:HASH>STR str> up LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR str>
   T$=
   v DROPBOX:REV>STR str> s" 01701" T$=
   rt ar
   S\" {\qdirection\q:\qupload\q,\qpath\q:\qnotes.txt\q,\qbytes_done\q:10,\qbytes_total\q:10}"
   SHOWS
   TEST-DROPBOX:SEEN$ s" /2/files/upload" T$=
   d GONE rt GONE ;

\ A transfer of notes.txt with 3 of 10 bytes sent.
: PART-SENT ( ^STATUS:status -- )
   {: st :}
   STATUS-DIRECTION:UPLOAD s" notes.txt" >str 3 10 OPTION:SOME
   STATUS-TRANSFER:MAKE STATUS-EVENT:PROGRESS st STATUS:TRANSFER ;

: A-REFUSED-UPLOAD-FINISHES-ITS-TRANSFER ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a refused upload finishes its transfer" T-LABEL
   TEST-DROPBOX:RESET
   s" /notes.txt" s" /notes.txt" s" 0150"
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   0 TEST-DROPBOX:FILE!
   ar RUNTIME-STATUS {: rt:str st :}
   st l REPLAY-LINK:STATUS !
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   st PART-SENT
   l up ar UPLOAD-NOTES s" precondition-changed" s" file" GIVES
   rt ar
   S\" {\qdirection\q:\qupload\q,\qpath\q:\qnotes.txt\q,\qbytes_done\q:0,\qbytes_total\q:10}"
   SHOWS
   TEST-DROPBOX:SEEN$
   s" /2/files/upload /2/files/get_metadata /2/files/get_metadata" T$=
   d GONE rt GONE ;

: REMOTE-CASES ( ^ARENA:arena -- )
   {: ar :}
   MAIN @ s" " ar NEW-LINK {: l :}
   l ar AN-EMPTY-FOLDER-IS-DELETED
   l ar AN-OCCUPIED-FOLDER-IS-KEPT
   l ar A-MISSING-FOLDER-IS-ALREADY-DELETED
   l ar A-RESET-PROBE-LEAVES-THE-DELETE-PENDING
   l ar A-FILE-THE-FOLDER-DELETE-FINDS-IS-LOGGED
   l ar AN-UPLOAD-SENDS-ITS-TRANSFER
   l ar A-REFUSED-UPLOAD-FINISHES-ITS-TRANSFER ;


\ ---- the fake's client

\ A client on the fake, no root, keeping no rotated token.
: OPENED ( ^ARENA:arena -- ^DROPBOX:client )
   {: ar :}
   [: 2drop ;] CFG DROPBOX-CONFIG:STORE !
   CFG DROPBOX:PRODUCTION
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:API !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:NOTIFY !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:CONTENT !
   s" fake-key" SPAN:MAKE CFG DROPBOX-CONFIG:KEY !
   s" live-token" SPAN:MAKE CFG DROPBOX-CONFIG:TOKEN !
   s" " SPAN:MAKE CFG DROPBOX-CONFIG:ROOT !
   CFG ar DROPBOX:OPEN ;

: CURL-READY ( CURL:status -- )
   MATCH CURL:status
      ok OF ENDOF
      failed OF drop s" the curl loop did not start" FAILED ENDOF
   ;MATCH ;

\ The account call takes the client's first access token, so no case's
\ requests start with a refresh.
: ACCOUNTED ( -- )
   MAIN @ DROPBOX:ACCOUNT MATCH DROPBOX:reply
      done OF ENDOF
      refused OF drop s" the account was refused" FAILED ENDOF
      retry OF drop s" the account asked a retry" FAILED ENDOF
      unlinked OF s" the account was unlinked" FAILED ENDOF
   ;MATCH ;

: SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   ar OPENED MAIN !
   ACCOUNTED
   [: ar TARGET-JOINS-THE-ROOT-AND-REJECTS-INVALID-PATHS
      ar REMOTE-CASES ;]
   [: MAIN @ DROPBOX:CLOSE ;] finally ;


\ ---- the download bridge -------------------------------------------

TYPED-VARIABLE LINK REPLAY:link
TYPED-VARIABLE RUNTIME str
TYPED-VARIABLE ASIDE str
TYPED-VARIABLE STAGE-AT str
TYPED-VARIABLE HASHING DROPBOX:hasher
variable REMAINING

4096 constant CAP
CAP BUFFER: TEXT
$10000 constant XS-SIZE
XS-SIZE BUFFER: XS

: FILL-XS ( -- ) XS-SIZE 0 ?do $78 XS i + c! loop ;


\ A client on the fake with the refresh token t, as CFG's store has it.
: OPENED-WITH ( ^u8 n ^ARENA:arena -- ^DROPBOX:client )
   {: t:^ tu:n ar :}
   CFG DROPBOX:PRODUCTION
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:API !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:NOTIFY !
   TEST-DROPBOX:ORIGIN$ SPAN:MAKE CFG DROPBOX-CONFIG:CONTENT !
   s" fake-key" SPAN:MAKE CFG DROPBOX-CONFIG:KEY !
   t tu SPAN:MAKE CFG DROPBOX-CONFIG:TOKEN !
   s" " SPAN:MAKE CFG DROPBOX-CONFIG:ROOT !
   CFG ar DROPBOX:OPEN ;

: KEPT ( ^u8 n -- ) 2drop ;

: LINKED ( ^DROPBOX:client -- ) LINK REPLAY-LINK:CLIENT ! ;

: SERVES ( ^u8 n ^u8 n ^u8 n DROPBOX:hash -- )
   {: p:^ pu:n v:^ vu:n b:^ bu:n c:DROPBOX:hash :}
   p pu p pu v vu c DROPBOX:HASH>STR str> bu TEST-DROPBOX:FILE!
   v vu b bu TEST-DROPBOX:CONTENT! ;

: REMOTE-OF ( DROPBOX:hash ^u8 n -- MODEL:remote )
   >str DROPBOX:>REV MODEL-REMOTE:MAKE ;

: OPEN-ROOT ( str -- fd ) str> s" open test sync root" LOCAL:OPEN-ROOT ;

: NO-LEASE ( -- option<LOCAL:download-slot-lease> ) OPTION:NONE ;

: UNPROTECTED ( LOCAL:binding -- bool ) drop false ;

\ The case directory d's slot for target t's download of the remote.
: LEASE-FOR
   ( str ^u8 n MODEL:remote -- option<LOCAL:download-slot-lease> )
   {: d:str t:^ tu:n rem:MODEL:remote :}
   1 1 t tu rem LOCAL:NEW-SLOT-IDENTITY
   {: id:LOCAL:download-slot-identity :}
   d str> id [: UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT ;

: LEASED
   ( option<LOCAL:download-slot-lease> -- LOCAL:download-slot-lease )
   MATCH option
      none OF s" replay-test: no download slot leased" FAILED ENDOF
      some OF ENDOF
   ;MATCH ;

\ STAGE-EXACT-DOWNLOAD-AT of p's remote below the root r, open as root.
: STAGED-AT
   ( fd str ^u8 n MODEL:remote option<LOCAL:download-slot-lease>
     ^ARENA:arena -- LOCAL:stage-outcome<n> )
   {: root:fd r:str p:^ pu:n rem:MODEL:remote
      lease:option<LOCAL:download-slot-lease> ar :}
   LINK root r str> p pu DISPLAY rem lease s" " ar
   REPLAY:STAGE-EXACT-DOWNLOAD-AT ;

: DROP-STAGE ( LOCAL:stage-outcome<n> -- ) drop ;

\ The outcome's variant, and its actual content or path, else empty.
: STAGE$ ( LOCAL:stage-outcome<n> -- ^u8 n ^u8 n )
   MATCH LOCAL:stage-outcome
      staged OF drop s" staged" s" " ENDOF
      already-staged OF drop s" already-staged" s" " ENDOF
      content-changed OF {: a:DROPBOX:hash :}
         s" content-changed" a DROPBOX:HASH>STR str>
      ENDOF
      destination-occupied OF {: p:str :}
         s" destination-occupied" p str>
      ENDOF
   ;MATCH ;

: AS ( LOCAL:stage-outcome<n> ^u8 n -- )
   {: o w:^ wu:n :}
   o STAGE$ 2drop w wu T$= ;

: DONE? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF true ENDOF
      refused OF drop false ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

: RETRY? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF drop false ENDOF
      retry OF drop true ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

\ The stage of p's remote throws E-DROPBOX, its reply a retry.
: STOPPED
   ( fd str ^u8 n MODEL:remote option<LOCAL:download-slot-lease>
     ^ARENA:arena -- )
   {: root:fd r:str p:^ pu:n rem:MODEL:remote
      lease:option<LOCAL:download-slot-lease> ar :}
   [: root r p pu rem lease ar STAGED-AT DROP-STAGE ;]
   REPLAY:E-DROPBOX TTHROWSQ
   LINK REPLAY-LINK:REPLY @ RETRY? TTRUE ;

: DOWNLOADS$ ( n -- ^u8 n )
   {: k:n :}
   SB-RESET
   k 0 ?do
      i 0 > if s"  " SB-APPEND then s" /2/files/download" SB-APPEND
   loop SB$ ;

: SEEN ( n -- ) DOWNLOADS$ TEST-DROPBOX:SEEN$ 2swap T$= ;

: ALPHABET ( -- ^u8 n ) s" abcdefghijklmnopqrstuvwxyz" ;

: FIRST-LINE ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   u 0 ?do p i + c@ 10 = if p i unloop exit then loop
   p u ;

\ The case directory's download slot, listed first by its leading dot.
: SLOT-PATH ( str ^ARENA:arena -- str )
   {: d:str ar :}
   d str> TEXT CAP FS-LIST:NAMES {: u:n :}
   TEXT u FIRST-LINE {: n:^ nu:n :}
   nu 22 >= TTRUE
   n 22 s" .omabox-download-slot-" T$=
   d n nu ar INSIDE ;

variable HELD

\ The list's first name, after the rest past its newline.
: NEXT-NAME ( ^u8 n -- ^u8 n ^u8 n )
   {: p:^ u:n :}
   u 0 ?do
      p i + c@ 10 = if p i + 1+ u i - 1- p i unloop exit then
   loop
   p u + 0 p u ;

: SAME-FILE? ( ^u8 n n n -- bool )
   {: nm:^ nu:n dev:n ino:n :}
   SB-RESET s" /proc/self/fd/" SB-APPEND nm nu SB-APPEND
   SB$ FS:TRY-STAT 0= if false exit then
   FS:STAT-DEV@ dev = FS:STAT-INO@ ino = and ;

\ How many of this process's descriptors hold the file at p.
: HOLDERS ( ^u8 n -- n )
   {: p:^ u:n :}
   p u FS:TRY-STAT TTRUE
   FS:STAT-DEV@ FS:STAT-INO@ {: dev:n ino:n :}
   0 HELD !
   s" /proc/self/fd" TEXT CAP FS-LIST:NAMES {: k:n :}
   TEXT k begin dup 0 > while
      NEXT-NAME dev ino SAME-FILE? if 1 HELD +! then
   repeat 2drop HELD @ ;

\ Rust's FailingBytes: "x" bytes until none remain, then a reset
\ connection.
: FAILING ( ^u8 n -- n )
   {: dst:^ cap:n :}
   REMAINING @ 0= if 104 FS:CAUSE! E-FS-IO throw then
   REMAINING @ cap min XS-SIZE min {: k:n :}
   XS dst k BYTE-COPY
   k negate REMAINING +!
   k ;

: READY-PARTIAL ( LOCAL:download-preparation -- ^LOCAL:download-partial )
   MATCH LOCAL:download-preparation
      ready OF ENDOF
      complete OF DROP-STAGE s" replay-test: no partial" FAILED ENDOF
      ephemeral OF s" replay-test: no partial" FAILED ENDOF
   ;MATCH ;

: CHECKPOINT ( -- n ) REPLAY:DOWNLOAD-CHECKPOINT-BYTES ;

\ The lease's slot holding a durable checkpoint of CHECKPOINT "x"
\ bytes for target t, as a transfer lost just past it leaves it.
: CHECKPOINTED
   ( fd str ^u8 n DROPBOX:hash LOCAL:download-slot-lease ^ARENA:arena
     -- )
   {: root:fd r:str t:^ tu:n c:DROPBOX:hash
      l:LOCAL:download-slot-lease ar :}
   root r str> t tu c l ar LOCAL:PREPARE-DOWNLOAD-SLOT-AT READY-PARTIAL
   {: x :}
   CHECKPOINT 1+ REMAINING !
   [: x CHECKPOINT DROPBOX:BLOCK + [: FAILING ;] ar
      LOCAL:APPEND-PARTIAL DROP-STAGE ;]
   [: 2drop true ;] LOCAL:CONVERTING LOCAL:E-STAGE-READ T= ;

\ The content hash of CHECKPOINT "x" bytes.
: CHECKPOINT-HASH ( ^ARENA:arena -- DROPBOX:hash )
   {: ar :}
   HASHING DROPBOX:HASH-BEGIN
   CHECKPOINT XS-SIZE / 0 ?do XS XS-SIZE HASHING DROPBOX:HASH-FEED loop
   HASHING DROPBOX:HASH-END ar COPIED DROPBOX:>HASH ;

\ A reader of the pipe's bytes into LOCAL.
: STAGE-FROM
   ( fd str ^u8 n DROPBOX:hash fd ^ARENA:arena -- LOCAL:stage-outcome<n> )
   {: root:fd r:str t:^ tu:n c:DROPBOX:hash rd:fd ar :}
   root r str> t tu c [: rd -rot LOCAL:FD-READ ;] ar
   LOCAL:STAGE-DOWNLOAD-AT ;

\ The bytes b staged for target t below the root, as another download
\ stages them.
: PRESTAGED
   ( fd str ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- LOCAL:stage-outcome<n> )
   {: root:fd r:str t:^ tu:n b:^ bu:n c:DROPBOX:hash ar :}
   FD:PIPE {: rd:fd w:fd :}
   w b bu FD:WRITE-FULL w FS:CLOSE-DIR
   [: root r t tu c rd ar STAGE-FROM ;] [: rd FS:CLOSE-DIR ;] finally ;

\ The race client's store: it runs while DOWNLOAD's call is in flight,
\ after the bridge found no stage, and the verified stage reappears.
: RETURNED ( ^u8 n -- )
   2drop ASIDE @ str> STAGE-AT @ str> FS:RENAME-FILE ;

: NO-CONTENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;

: INSTALLED? ( LOCAL:install-outcome -- bool )
   MATCH LOCAL:install-outcome
      installed OF true ENDOF
      already-installed OF false ENDOF
      download-required OF false ENDOF
      stage-destination-occupied OF drop false ENDOF
      precondition-changed OF drop false ENDOF
   ;MATCH ;

\ The file at p below r holds b.
: HOLDS ( str ^u8 n ^u8 n ^ARENA:arena -- )
   {: r:str p:^ pu:n b:^ bu:n ar :}
   r p pu ar INSIDE str> TEXT CAP FS:READ-ALL {: u:n :}
   TEXT u b bu T$= ;

: EXACT-DOWNLOAD-RETRY-REUSES-A-STAGE-WITHOUT-CONSUMING-THE-BODY
   ( ^ARENA:arena -- )
   {: ar :}
   s" exact_download_retry_reuses_a_stage_without_consuming_the_body"
   T-LABEL
   TEST-DROPBOX:RESET
   s" already staged Dropbox bytes" {: b:^ bu:n :}
   b bu ar HASH-OF {: c:DROPBOX:hash :}
   s" /staged.txt" s" staged-revision" b bu c SERVES
   c s" staged-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   root r s" staged.txt" rem NO-LEASE ar STAGED-AT s" staged" AS
   root r s" staged.txt" rem NO-LEASE ar STAGED-AT
   s" already-staged" AS
   1 SEEN
   root FS:CLOSE-DIR
   d GONE ;

\ The verified stage moved aside, to come back while the call is in
\ flight.
: SET-ASIDE ( str str ^ARENA:arena -- )
   {: d:str r:str ar :}
   r str> TEXT CAP FS-LIST:NAMES {: u:n :}
   r TEXT u ar INSIDE STAGE-AT !
   d s" aside" ar INSIDE ASIDE !
   STAGE-AT @ str> ASIDE @ str> FS:RENAME-FILE ;

\ A fresh client refreshes its token first, and stores the rotated
\ refresh token through RETURNED.
: RACED ( fd str MODEL:remote ^ARENA:arena -- LOCAL:stage-outcome<n> )
   {: root:fd r:str rem:MODEL:remote ar :}
   [: RETURNED ;] CFG DROPBOX-CONFIG:STORE !
   s" replay-refresh-2" TEST-DROPBOX:ROTATE!
   s" replay-refresh" ar OPENED-WITH {: c :}
   c LINKED
   [: root r s" raced.txt" rem NO-LEASE ar STAGED-AT ;]
   [: c DROPBOX:CLOSE MAIN @ LINKED
      s" fake-key" s" replay-refresh" TEST-DROPBOX:ACCEPT! ;] finally ;

: EXACT-DOWNLOAD-STAGE-RACE-PRESERVES-VERIFIED-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" exact_download_stage_race_preserves_verified_stage" T-LABEL
   TEST-DROPBOX:RESET
   s" complete expected Dropbox bytes" {: b:^ bu:n :}
   b bu ar HASH-OF {: c:DROPBOX:hash :}
   s" /raced.txt" s" raced-revision" s" ignored response body, not read"
   c SERVES
   c s" raced-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   root r s" raced.txt" b bu c ar PRESTAGED s" staged" AS
   d r ar SET-ASIDE
   root r rem ar RACED s" already-staged" AS
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/files/download" T$=
   root r str> s" raced.txt" c NO-CONTENT ar LOCAL:INSTALL-DOWNLOAD-AT
   INSTALLED? TTRUE
   r s" raced.txt" b bu ar HOLDS
   root FS:CLOSE-DIR
   d GONE ;

: CORRUPT-EXACT-DOWNLOAD-NEVER-LEAVES-INSTALLABLE-BYTES ( ^ARENA:arena -- )
   {: ar :}
   s" corrupt_exact_download_never_leaves_installable_bytes" T-LABEL
   TEST-DROPBOX:RESET
   s" expected download" ar HASH-OF {: c:DROPBOX:hash :}
   s" corrupt response" {: b:^ bu:n :}
   b bu ar HASH-OF {: actual:DROPBOX:hash :}
   s" /corrupt.txt" s" rev-corrupt" b bu c SERVES
   c s" rev-corrupt" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   root r s" corrupt.txt" rem NO-LEASE ar STAGED-AT STAGE$
   actual DROPBOX:HASH>STR str> T$= s" content-changed" T$=
   r str> TEXT CAP FS-LIST:NAMES 0 T=
   1 SEEN
   root FS:CLOSE-DIR
   d GONE ;

: A-DOWNLOAD-LOST-MID-BODY-KEEPS-ITS-PARTIAL ( ^ARENA:arena -- )
   {: ar :}
   s" a download lost mid-body keeps its partial and resumes it" T-LABEL
   TEST-DROPBOX:RESET
   ALPHABET ar HASH-OF {: c:DROPBOX:hash :}
   s" /lost.txt" s" lost-revision" ALPHABET c SERVES
   c s" lost-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   d s" lost.txt" rem LEASE-FOR {: l:option<LOCAL:download-slot-lease> :}
   TEST-DROPBOX:CUT-BODY
   root r s" lost.txt" rem l ar STOPPED
   d ar SLOT-PATH {: slot:str :}
   slot str> HOLDERS 0 T=
   slot str> FS:FILE-SIZE 0 T=
   root r s" lost.txt" rem l ar STAGED-AT s" staged" AS
   TEST-DROPBOX:RANGE-SENT? TFALSE
   2 SEEN
   root FS:CLOSE-DIR
   d GONE ;

\ Content-Range bytes */n.
: UNSATISFIED$ ( n -- ^u8 n )
   SB-RESET s" bytes */" SB-APPEND FMT:SB-INT SB$ ;

: A-COMPLETE-416-FINISHES-THE-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" a 416 at the partial's length finishes the stage, unread" T-LABEL
   TEST-DROPBOX:RESET
   ar CHECKPOINT-HASH {: c:DROPBOX:hash :}
   c s" full-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   d s" full.bin" rem LEASE-FOR LEASED {: l:LOCAL:download-slot-lease :}
   root r s" full.bin" c l ar CHECKPOINTED
   416 s" Content-Range" CHECKPOINT UNSATISFIED$ s" "
   TEST-DROPBOX:SCRIPT!
   root r s" full.bin" rem l OPTION:SOME ar STAGED-AT s" staged" AS
   1 SEEN
   root FS:CLOSE-DIR
   d GONE ;

: ANOTHER-416-RESTARTS-THE-SLOT ( ^ARENA:arena -- )
   {: ar :}
   s" a lost answer keeps the partial; another 416 restarts it" T-LABEL
   TEST-DROPBOX:RESET
   ALPHABET ar HASH-OF {: c:DROPBOX:hash :}
   s" /restart.bin" s" restart-revision" ALPHABET c SERVES
   c s" restart-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   d s" restart.bin" rem LEASE-FOR {: l:option<LOCAL:download-slot-lease> :}
   root r s" restart.bin" c l LEASED ar CHECKPOINTED
   d ar SLOT-PATH {: slot:str :}
   TEST-DROPBOX:LOSE
   root r s" restart.bin" rem l ar STOPPED
   slot str> HOLDERS 0 T=
   slot str> FS:FILE-SIZE CHECKPOINT T=
   SB-RESET s" bytes=" SB-APPEND CHECKPOINT FMT:SB-INT s" -" SB-APPEND
   SB$ TEST-DROPBOX:RANGE-SENT$ T$=
   root r s" restart.bin" rem l ar STAGED-AT s" staged" AS
   TEST-DROPBOX:RANGE-SENT? TFALSE
   3 SEEN
   root FS:CLOSE-DIR
   d GONE ;

\ The status file's text.
: STATUS$ ( ^ARENA:arena -- ^u8 n )
   {: ar :}
   RUNTIME @ s" omabox/status.json" ar INSIDE str>
   TEXT CAP FS:READ-ALL TEXT swap ;

: PART-SHOWN$ ( -- ^u8 n )
   s\" \"path\":\"docs/progress.txt\",\"bytes_done\":10,\"bytes_total\":26}" ;
: ALL-SHOWN$ ( -- ^u8 n )
   s\" \"path\":\"docs/progress.txt\",\"bytes_done\":26,\"bytes_total\":26}" ;

: A-DOWNLOAD-REPORTS-ITS-TRANSFER ( ^ARENA:arena -- )
   {: ar :}
   s" a download sends progress, then finished on every exit" T-LABEL
   TEST-DROPBOX:RESET
   ALPHABET ar HASH-OF {: c:DROPBOX:hash :}
   s" /docs/progress.txt" s" progress-revision" ALPHABET c SERVES
   c s" progress-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s" docs" ar INSIDE str> FS:MAKE-DIR
   r OPEN-ROOT {: root:fd :}
   TEST-DROPBOX:CUT-BODY
   root r s" docs/progress.txt" rem NO-LEASE ar STOPPED
   ar STATUS$ PART-SHOWN$ CONTAINS? TTRUE
   root r s" docs/progress.txt" rem NO-LEASE ar STAGED-AT s" staged" AS
   ar STATUS$ ALL-SHOWN$ CONTAINS? TTRUE
   root FS:CLOSE-DIR
   d GONE ;


\ ---- remote conflict copies -----------------------------------------

\ p's remote conflict copy holding c, relative to the root.
: REMOTE-COPY ( ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: p:^ u:n c:DROPBOX:hash ar :}
   p u LOCAL-CONFLICT--SIDE:REMOTE c ar LOCAL:CONFLICT-RELATIVE-PATH ;

\ p's remote conflict copy, written below the root r.
: REMOTE-COPY$
   ( str ^u8 n MODEL:remote ^ARENA:arena -- ^u8 n ^u8 n )
   {: r:str p:^ u:n rem:MODEL:remote ar :}
   LINK r str> p u DISPLAY rem ar REPLAY:MATERIALIZE-REMOTE-CONFLICT
   OUTCOME$ ;

: EXACT$ ( REPLAY:exact-copy-outcome -- ^u8 n )
   MATCH REPLAY:exact-copy-outcome
      ready OF s" ready" ENDOF
      destination-changed OF s" destination-changed" ENDOF
      stage-occupied OF s" stage-occupied" ENDOF
   ;MATCH ;

\ The remote's exact copy at t below the root r, shown as p.
: COPY-AT$
   ( fd str ^u8 n ^u8 n MODEL:remote ^ARENA:arena -- ^u8 n )
   {: root:fd r:str t:^ tu:n p:^ pu:n rem:MODEL:remote ar :}
   LINK root r str> t tu DISPLAY p pu DISPLAY rem ar
   REPLAY:MATERIALIZE-REMOTE-COPY-AT EXACT$ ;

: THEIRS ( -- ^u8 n ) s" Dropbox's side of the conflict" ;

\ THEIRS served at /notes.txt, and its remote.
: THEIRS-SERVED ( ^ARENA:arena -- DROPBOX:hash MODEL:remote )
   {: ar :}
   TEST-DROPBOX:RESET
   THEIRS ar HASH-OF {: c:DROPBOX:hash :}
   s" /notes.txt" s" theirs-revision" THEIRS c SERVES
   c c s" theirs-revision" REMOTE-OF ;

: A-REMOTE-CONFLICT-COPY-DOWNLOADS-ONCE ( ^ARENA:arena -- )
   {: ar :}
   s" a remote conflict copy downloads once, then is ready" T-LABEL
   ar THEIRS-SERVED {: c:DROPBOX:hash rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s" notes.txt" rem ar REMOTE-COPY$ s" " T$= s" ready" T$=
   r s" notes.txt" rem ar REMOTE-COPY$ s" " T$= s" ready" T$=
   1 SEEN
   r s" notes.txt" c ar REMOTE-COPY THEIRS ar HOLDS
   d GONE ;

: AN-OCCUPIED-REMOTE-COPY-NAME-BLOCKS-IT ( ^ARENA:arena -- )
   {: ar :}
   s" a directory or other bytes at the copy's name block it" T-LABEL
   ar THEIRS-SERVED {: c:DROPBOX:hash rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s" notes.txt" c ar REMOTE-COPY ar INSIDE {: k:str :}
   k str> FS:MAKE-DIR
   d [: r s" notes.txt" rem ar REMOTE-COPY$ BLOCKED-OCCUPIED ;] ar
   QUIETLY
   k str> FS:REMOVE-DIR
   k str> s" other bytes" FS:WRITE-ALL
   d [: r s" notes.txt" rem ar REMOTE-COPY$ BLOCKED-OCCUPIED ;] ar
   QUIETLY
   r s" notes.txt" c ar REMOTE-COPY s" other bytes" ar HOLDS
   d GONE ;

: AN-OCCUPIED-REMOTE-COPY-STAGE-BLOCKS-IT ( ^ARENA:arena -- )
   {: ar :}
   s" other bytes at the copy's stage block it" T-LABEL
   ar THEIRS-SERVED {: c:DROPBOX:hash rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   s" notes.txt" c ar REMOTE-COPY {: k:^ ku:n :}
   root r k ku THEIRS c ar PRESTAGED s" staged" AS
   root FS:CLOSE-DIR
   d r ar SET-ASIDE
   STAGE-AT @ str> s" other bytes" FS:WRITE-ALL
   r s" notes.txt" rem ar REMOTE-COPY$
   s" stage-occupied" T$= s" blocked" T$=
   0 SEEN
   STAGE-AT @ str> TEXT CAP FS:READ-ALL {: u:n :}
   TEXT u s" other bytes" T$=
   d GONE ;

: A-REMOTE-COPY-INSTALLS-AT-ITS-TARGET ( ^ARENA:arena -- )
   {: ar :}
   s" a remote copy installs at its target, never over a file" T-LABEL
   ar THEIRS-SERVED {: c:DROPBOX:hash rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   root r s" moved.txt" s" notes.txt" rem ar COPY-AT$ s" ready" T$=
   r s" moved.txt" THEIRS ar HOLDS
   r s" notes.txt" ar INSIDE str> FS:TRY-STAT TFALSE
   r s" taken.txt" ar INSIDE str> s" other bytes" FS:WRITE-ALL
   root r s" taken.txt" s" notes.txt" rem ar COPY-AT$
   s" destination-changed" T$=
   r s" taken.txt" s" other bytes" ar HOLDS
   1 SEEN
   root FS:CLOSE-DIR
   d GONE ;

: BRIDGE-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar EXACT-DOWNLOAD-RETRY-REUSES-A-STAGE-WITHOUT-CONSUMING-THE-BODY
   ar EXACT-DOWNLOAD-STAGE-RACE-PRESERVES-VERIFIED-STAGE
   ar CORRUPT-EXACT-DOWNLOAD-NEVER-LEAVES-INSTALLABLE-BYTES
   ar A-DOWNLOAD-LOST-MID-BODY-KEEPS-ITS-PARTIAL
   ar A-COMPLETE-416-FINISHES-THE-STAGE
   ar ANOTHER-416-RESTARTS-THE-SLOT
   ar A-DOWNLOAD-REPORTS-ITS-TRANSFER
   ar A-REMOTE-CONFLICT-COPY-DOWNLOADS-ONCE
   ar AN-OCCUPIED-REMOTE-COPY-NAME-BLOCKS-IT
   ar AN-OCCUPIED-REMOTE-COPY-STAGE-BLOCKS-IT
   ar A-REMOTE-COPY-INSTALLS-AT-ITS-TARGET ;

\ The link: the main client, its token fetched, and a status in a
\ runtime directory of its own.
: LINKING ( ^ARENA:arena -- )
   {: ar :}
   [: KEPT ;] CFG DROPBOX-CONFIG:STORE !
   s" replay-refresh" ar OPENED-WITH MAIN !
   MAIN @ LINKED
   s" " >str LINK REPLAY-LINK:ROOT !
   s" replay-status" FS:MKTEMP-DIR ar COPIED RUNTIME !
   RUNTIME @ ar STATUS:NEW LINK REPLAY-LINK:STATUS !
   MAIN @ DROPBOX:ACCOUNT DONE? TTRUE ;

: BRIDGE-SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" replay-refresh" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   FILL-XS
   ar LINKING
   [: ar BRIDGE-CASES ;]
   [: MAIN @ DROPBOX:CLOSE RUNTIME @ GONE ;] finally ;


\ The mutation and bridge cases against one fake Dropbox, under curl's
\ loop.
: DROPBOX-CASES ( ^ARENA:arena -- )
   {: ar :}
   AIO:START CURL:LOOP-START CURL-READY
   [: TEST-DROPBOX:START
      [: ar SERVED ar BRIDGE-SERVED ;] [: TEST-DROPBOX:STOP ;] finally ;]
   [: CURL:LOOP-STOP AIO:STOP ;] finally ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ar RETENTION-EXPIRES-VERIFIED-PAYLOAD-ONLY-AT-BOUNDARY
   ar RETENTION-KEEPS-PENDING-CORRUPT-NONREGULAR-AND-ORPHAN-ENTRIES
   ar RETENTION-KEEPS-AN-UNREADABLE-PAYLOAD
   ar RETENTION-FINISHES-METADATA-CLEANUP-AFTER-PAYLOAD-DELETION
   ar LEGACY-LOCAL-PRESERVATION-REPLAYS-WITHOUT-CREATING-A-COPY
   ar A-LOCAL-OBJECT-BLOCKS-ONLY-ITS-PLAN
   ar ONLY-AN-OBJECT-AT-THE-COPY-NAME-OCCUPIES-IT
   ar A-DENIED-OPERATION-AT-THE-COPY-NAME-DOES-NOT-OCCUPY-IT
   CLASSIFY-COVERS-EVERY-EXPECTATION-AND-STATE
   ar REJECTION-COVERS-EVERY-DROPBOX-ERROR
   UPLOAD-SIZE-STOPS-AT-THE-SESSION-LIMIT
   ar DROPBOX-CASES ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" replay-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
