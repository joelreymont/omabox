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
\ Remote replay's steps on a pass over a journal's one plan:
\ - Rust's unsupported_size_stays_blocked_across_reopen.
\ - BLOCK-DURABLY holds a plan an hour from now, and throws
\   E-INVALID-STATE, logging once, for a completed plan.
\ - PERSIST-REMOTE-BLOCK holds the plan for a sync error, an occupied
\   stage or a remote object, and answers every other block unchanged.
\ - UNPLACED-COPY of each copy outcome.
\ - APPLY-FOLDER-MUTATION and APPLY-FOLDER-DELETE-MUTATION over every
\   mutation outcome: the event, the block, the plan pending, retired
\   or completed, the count, and a rejection's one log line.
\ - PREPARE-UPLOAD sends a stage once; bytes other than the plan's
\   retire it; a directory at the stage holds it stage-occupied; a
\   directory at the target retires it, logging nothing.
\ Against the fake Dropbox of test-dropbox.f, root empty:
\ - REMOTE-DELETE-FOLDER of an empty folder deletes it; of an occupied
\   one, or one the listing answers not_found or reset, deletes nothing;
\   a file the delete finds in the folder's place is logged once.
\ - REMOTE-UPLOAD of a new file sends its progress, then a finished
\   transfer to a STATUS in TMPDIR; one Dropbox refuses as a conflict
\   with other bytes at the path is read back as changed, and its
\   finished transfer is sent; a read-back incomplete file is rejected,
\   and an incomplete upload answer is read back.
\ - STAGE-EXACT-DOWNLOAD-AT against the fake Dropbox: Rust's
\   exact_download_retry_reuses_a_stage_without_consuming_the_body,
\   exact_download_stage_race_preserves_verified_stage, with the stage
\   back while the call is in flight, and
\   corrupt_exact_download_never_leaves_installable_bytes; a download
\   lost mid-body throws E-DROPBOX with a retry, keeps its slot and
\   leaks no descriptor, and the next stages it; a slot holding a
\   checkpoint: a 416 at its length finishes the stage, a lost answer
\   keeps it, sent with its Range, and another 416 restarts it, or the
\   next download resumes it from its Range to the remote's content; a
\   download's progress, then finished, in a status under TMPDIR.
\ - MATERIALIZE-REMOTE-CONFLICT downloads the copy once, then is ready
\   with no request; a directory or other bytes at the copy's name
\   block it conflict-copy-occupied, logging nothing; other bytes at
\   its stage block it stage-occupied with no request.
\   MATERIALIZE-REMOTE-COPY-AT installs at a target apart from the
\   source path, and answers destination-changed for other bytes there.
\ - APPLY-FILE-MUTATION and APPLY-DELETE-MUTATION over every mutation
\   outcome, a staged upload below a sync root and the fake serving the
\   remote side: the event, the block, the plan pending, held,
\   completed, retired or finished as its conflict, the count, the
\   conflict copies on disk, the downloads and the one line logged.
\ - REPLAY-REMOTE-OPERATIONS-AT against the fake Dropbox: Rust's
\   remote_replay_creates_nested_parents_before_the_file,
\   already_absent_dropbox_directory_completes_its_replayed_delete,
\   dropbox_file_at_a_deleted_directory_path_retires_the_replayed_delete
\   and remote_delete_skips_backup_download_and_ambiguous_create_stays_pending,
\   whose create's lost answer throws E-DROPBOX with a retry in the link
\   and leaves its plan pending; a plan whose next operation is local is
\   left pending, unblocked, with no request; Rust's
\   remote_replay_preserves_conflict_sides_without_a_backup_download,
\   folder_delete_probe_failures_keep_the_plan_retry_safe_or_block_only_its_path,
\   whose 503 throws E-DROPBOX with a retry and leaves its plan pending,
\   and replay_does_not_block_a_conflict_whose_copy_parent_is_read_only.
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

\ REPLAY reopened for the private words the tests call.
package REPLAY
private

\ A pass below the root over the plan's first operation.
: PASS-OVER
   ( JOURNAL:journal fd ^u8 n JOURNAL:plan-record ^ARENA:arena
     -- ^pass )
   {: j root:fd p:^ u:n plan ar :}
   j root p u ar NEW-PASS {: r :}
   plan r PASS-PLAN !
   plan PLAN-OPERATIONS 0 VEC:AT @ r PASS-OPERATION !
   r ;

: EVENT$ ( apply-event -- ^u8 n )
   MATCH apply-event
      done OF s" done" ENDOF
      blocked OF s" blocked" ENDOF
   ;MATCH ;

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
EXPORT PASS-OVER
EXPORT PASS-STAGING
EXPORT PASS-BLOCKED
EXPORT PASS-REPORT
EXPORT EVENT$
EXPORT APPLY-EVENT-DONE
EXPORT BLOCK-DURABLY
EXPORT PERSIST-REMOTE-BLOCK
EXPORT UNPLACED-COPY
EXPORT PREPARE-UPLOAD
EXPORT APPLY-FOLDER-MUTATION
EXPORT APPLY-FOLDER-DELETE-MUTATION
EXPORT PASS-LINK
EXPORT FILE-MUTATION-CREATE
EXPORT FILE-MUTATION-REPLACE
EXPORT APPLY-FILE-MUTATION
EXPORT APPLY-DELETE-MUTATION
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

: A-READ-BACK-INCOMPLETE-FILE-IS-REJECTED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a read-back incomplete file is rejected" T-LABEL
   TEST-DROPBOX:RESET
   s" /notes.txt" s" /notes.txt" s" 0150"
   s" E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
   0 TEST-DROPBOX:FILE!
   ar RUNTIME-STATUS {: rt:str st :}
   st l REPLAY-LINK:STATUS !
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   l up ar UPLOAD-NOTES s" rejected" s" rejected-by-dropbox" GIVES
   TEST-DROPBOX:SEEN$
   s" /2/files/upload /2/files/get_metadata /2/files/get_metadata" T$=
   d GONE rt GONE ;

: AN-INCOMPLETE-UPLOAD-ANSWER-IS-READ-BACK
   ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" an incomplete upload answer is read back" T-LABEL
   TEST-DROPBOX:RESET
   ar RUNTIME-STATUS {: rt:str st :}
   st l REPLAY-LINK:STATUS !
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   up LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR str> {: h:^ hu:n :}
   SB-RESET
   S\" {\qname\q:\qnotes.txt\q,\qid\q:\qid:n\q,\qpath_lower\q:\q/notes.txt\q,\qpath_display\q:\q/notes.txt\q,\qrev\q:\q01701\q,\qsize\q:10,\qcontent_hash\q:\q"
   SB-APPEND h hu SB-APPEND S\" \q,\qis_downloadable\q:false}" SB-APPEND
   200 s" " s" " SB$ TEST-DROPBOX:SCRIPT!
   s" /notes.txt" s" /notes.txt" s" 01702" h hu 10 TEST-DROPBOX:FILE!
   l up ar UPLOAD-NOTES APPLIED-FILE MODEL-REMOTE:UNMAKE {: c v :}
   c DROPBOX:HASH>STR str> h hu T$=
   v DROPBOX:REV>STR str> s" 01702" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
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
   l ar A-REFUSED-UPLOAD-FINISHES-ITS-TRANSFER
   l ar A-READ-BACK-INCOMPLETE-FILE-IS-REJECTED
   l ar AN-INCOMPLETE-UPLOAD-ANSWER-IS-READ-BACK ;


\ ---- remote replay's blocks and folder applies

: PLAN-PATH ( JOURNAL:plan-record -- MODEL:path )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} p ;

: FIRST-ID ( JOURNAL:plan-record -- JOURNAL:operation-id )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops 0 VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE {: i o x st :} i ;

\ A pending plan of the one operation o at path a.
: PLANNED
   ( JOURNAL:journal ^u8 n MODEL:operation ^ARENA:arena
     -- JOURNAL:plan-record )
   {: j a:^ u:n o ar :}
   j a u DISPLAY o ar ONE-PLAN ar JOURNAL:RECORD-PLAN NEW-PLAN ;

\ A case's directory and its open journal, holding one plan of o at a.
: CASE-PLAN
   ( ^u8 n MODEL:operation ^ARENA:arena
     -- str JOURNAL:journal JOURNAL:plan-record )
   {: a:^ u:n o ar :}
   ar JOURNAL-AT {: d:str p:str :}
   p JOURNAL:OPEN {: j :}
   d j j a u o ar PLANNED ;

: MAKE-F ( -- MODEL:operation )
   MODEL-OPERATION:CREATE-REMOTE-DIRECTORY ;

\ No descriptor: the words under test never read the pass's root.
: NO-ROOT ( -- fd ) -1 >FD ;

: BLOCKAGE$ ( MODEL:blockage -- ^u8 n )
   MATCH MODEL:blockage
      unsupported-file-size OF s" unsupported-file-size" ENDOF
      remote-rejected OF str> ENDOF
      download-unavailable OF drop s" download-unavailable" ENDOF
      download-verification-failed OF
         s" download-verification-failed"
      ENDOF
      stage-occupied OF s" stage-occupied" ENDOF
      local-object-in-way OF s" local-object-in-way" ENDOF
      remote-object OF s" remote-object" ENDOF
      conflict-copy-occupied OF s" conflict-copy-occupied" ENDOF
   ;MATCH ;

\ The block's variant and its detail: a durable plan's blockage, a
\ remote rejection's tag, a sync error's rejection, else "-".
: BLOCK$ ( REPLAY:replay-blocked -- ^u8 n ^u8 n )
   MATCH REPLAY:replay-blocked
      durable-plan OF {: p why :} s" durable-plan" why BLOCKAGE$ ENDOF
      local-object OF drop s" local-object" s" -" ENDOF
      fresh-observation-required OF
         drop s" fresh-observation-required" s" -"
      ENDOF
      download-required OF
         drop drop s" download-required" s" -"
      ENDOF
      stage-destination-occupied OF
         drop drop s" stage-destination-occupied" s" -"
      ENDOF
      precondition-changed OF
         drop drop s" precondition-changed" s" -"
      ENDOF
      remote-operation OF drop s" remote-operation" s" -" ENDOF
      remote-pending OF drop s" remote-pending" s" -" ENDOF
      remote-object OF drop s" remote-object" s" -" ENDOF
      sync-error OF {: p why :} s" sync-error" why REJECTION$ ENDOF
   ;MATCH ;

: SOME-BLOCK$ ( option<REPLAY:replay-blocked> -- ^u8 n ^u8 n )
   MATCH option
      none OF s" none" s" -" ENDOF
      some OF BLOCK$ ENDOF
   ;MATCH ;

\ A blocked plan's blockage and retry time; another's status and 0.
: BLOCK-OF ( JOURNAL:plan-record -- ^u8 n n )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   s MATCH JOURNAL:plan-status
      pending OF s" pending" 0 ENDOF
      blocked OF {: why at:n :} why BLOCKAGE$ at ENDOF
      completed OF s" completed" 0 ENDOF
   ;MATCH ;

\ The journal's one plan is blocked with the blockage w; its retry time.
: HELD-AS ( JOURNAL:journal ^u8 n ^ARENA:arena -- n )
   {: j w:^ wu:n ar :}
   j ar JOURNAL:BLOCKED-PLANS {: held :}
   held VEC:COUNT 1 T=
   held 0 VEC:AT @ BLOCK-OF {: at:n :} w wu T$=
   at ;

: BASELINE$ ( option<MODEL:baseline> -- ^u8 n )
   MATCH option
      none OF s" absent" ENDOF
      some OF
         MATCH MODEL:baseline
            absent OF s" absent" ENDOF
            present OF drop s" present" ENDOF
            directory OF s" directory" ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ The plan at f pending or blocked; once it is retired, f's baseline.
: JOURNAL$ ( JOURNAL:journal ^ARENA:arena -- ^u8 n )
   {: j ar :}
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0<> if s" pending" exit then
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0<> if s" blocked" exit then
   j s" f" DISPLAY ar JOURNAL:BASELINE BASELINE$ ;

: UNSUPPORTED-SIZE-STAYS-BLOCKED-ACROSS-REOPEN ( ^ARENA:arena -- )
   {: ar :}
   s" unsupported_size_stays_blocked_across_reopen" T-LABEL
   s" oversized source identity" ar HASH-OF {: c :}
   s" oversized.bin" c MODEL-OPERATION:CREATE-REMOTE ar CASE-PLAN
   {: d:str j plan :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   plan PLAN-PATH REPLAY-MUTATION--REJECTION:UNSUPPORTED-FILE-SIZE
   REPLAY-REPLAY--BLOCKED:SYNC-ERROR r REPLAY:PERSIST-REMOTE-BLOCK
   BLOCK$ s" unsupported-file-size" T$= s" durable-plan" T$=
   j JOURNAL:CLOSE
   d s" journal.sqlite3" ar INSIDE JOURNAL:OPEN {: again :}
   again s" unsupported-file-size" ar HELD-AS MEM-MAX-N T=
   again ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   again JOURNAL:CLOSE
   d GONE ;

: BLOCK-DURABLY-HOLDS-A-PLAN-FOR-AN-HOUR ( ^ARENA:arena -- )
   {: ar :}
   s" block durably holds a plan for an hour" T-LABEL
   s" f" MAKE-F ar CASE-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   epoch-seconds 3600 + {: early:n :}
   MODEL-BLOCKAGE:REMOTE-OBJECT r REPLAY:BLOCK-DURABLY
   epoch-seconds 3600 + {: late:n :}
   BLOCK$ s" remote-object" T$= s" durable-plan" T$=
   j s" remote-object" ar HELD-AS {: at:n :}
   at early >= TTRUE at late <= TTRUE
   j JOURNAL:CLOSE
   d GONE ;

\ The plan's one operation completes it, creating the folder.
: COMPLETE-F ( JOURNAL:journal JOURNAL:plan-record ^ARENA:arena -- )
   {: j plan ar :}
   j plan FIRST-ID MODEL-BASELINE:DIRECTORY OPTION:SOME ar
   JOURNAL:COMPLETE-OPERATION PLAN-COMPLETED? TTRUE ;

: BLOCK-DURABLY-REFUSES-A-COMPLETED-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" block durably refuses a completed plan" T-LABEL
   s" f" MAKE-F ar CASE-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   j plan ar COMPLETE-F
   d [: [: MODEL-BLOCKAGE:REMOTE-OBJECT r REPLAY:BLOCK-DURABLY drop ;]
      REPLAY:E-INVALID-STATE TTHROWSQ ;] ar LOGGED {: t:^ tu:n :}
   t tu LINE-COUNT 1 T=
   t tu s" for `f`: mutation blocker lost its owning plan" CONTAINS?
   TTRUE
   j JOURNAL:CLOSE
   d GONE ;

: PERSIST-REMOTE-BLOCK-KEEPS-OTHER-BLOCKS ( ^ARENA:arena -- )
   {: ar :}
   s" persist remote block keeps other blocks" T-LABEL
   s" f" MAKE-F ar CASE-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   plan PLAN-PATH {: p :}
   p MODEL-BLOCKAGE:LOCAL-OBJECT-IN-WAY
   REPLAY-REPLAY--BLOCKED:DURABLE-PLAN
   r REPLAY:PERSIST-REMOTE-BLOCK BLOCK$
   s" local-object-in-way" T$= s" durable-plan" T$=
   p REPLAY-REPLAY--BLOCKED:LOCAL-OBJECT r REPLAY:PERSIST-REMOTE-BLOCK
   BLOCK$ s" -" T$= s" local-object" T$=
   p REPLAY-REPLAY--BLOCKED:FRESH-OBSERVATION-REQUIRED
   r REPLAY:PERSIST-REMOTE-BLOCK BLOCK$
   s" -" T$= s" fresh-observation-required" T$=
   p OLD REPLAY-REPLAY--BLOCKED:DOWNLOAD-REQUIRED
   r REPLAY:PERSIST-REMOTE-BLOCK BLOCK$
   s" -" T$= s" download-required" T$=
   p OLD OPTION:SOME REPLAY-REPLAY--BLOCKED:PRECONDITION-CHANGED
   r REPLAY:PERSIST-REMOTE-BLOCK BLOCK$
   s" -" T$= s" precondition-changed" T$=
   p REPLAY-REPLAY--BLOCKED:REMOTE-OPERATION
   r REPLAY:PERSIST-REMOTE-BLOCK BLOCK$
   s" -" T$= s" remote-operation" T$=
   p REPLAY-REPLAY--BLOCKED:REMOTE-PENDING r REPLAY:PERSIST-REMOTE-BLOCK
   BLOCK$ s" -" T$= s" remote-pending" T$=
   j ar JOURNAL$ s" pending" T$=
   j JOURNAL:CLOSE
   d GONE ;

: PERSIST-REMOTE-BLOCK-HOLDS-REMOTE-CAUSES ( ^ARENA:arena -- )
   {: ar :}
   s" persist remote block holds remote causes" T-LABEL
   s" f" MAKE-F ar CASE-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   plan PLAN-PATH {: p :}
   p REPLAY-MUTATION--REJECTION:UNSUPPORTED-FILE-SIZE
   REPLAY-REPLAY--BLOCKED:SYNC-ERROR r REPLAY:PERSIST-REMOTE-BLOCK
   BLOCK$ s" unsupported-file-size" T$= s" durable-plan" T$=
   j s" unsupported-file-size" ar HELD-AS MEM-MAX-N T=
   p REPLAY-MUTATION--REJECTION:PATH-MISMATCH
   REPLAY-REPLAY--BLOCKED:SYNC-ERROR r REPLAY:PERSIST-REMOTE-BLOCK
   BLOCK$ s" path_mismatch" T$= s" durable-plan" T$=
   j s" path_mismatch" ar HELD-AS drop
   plan JOURNAL-PLAN--RECORD:UNMAKE {: id q o s :}
   id s" stage" >str REPLAY-REPLAY--BLOCKED:STAGE-DESTINATION-OCCUPIED
   r REPLAY:PERSIST-REMOTE-BLOCK BLOCK$
   s" stage-occupied" T$= s" durable-plan" T$=
   j s" stage-occupied" ar HELD-AS drop
   p REPLAY-REPLAY--BLOCKED:REMOTE-OBJECT r REPLAY:PERSIST-REMOTE-BLOCK
   BLOCK$ s" remote-object" T$= s" durable-plan" T$=
   j s" remote-object" ar HELD-AS drop
   j JOURNAL:CLOSE
   d GONE ;

: UNPLACED-COPY-COVERS-EVERY-COPY-OUTCOME ( ^ARENA:arena -- )
   {: ar :}
   s" unplaced copy covers every copy outcome" T-LABEL
   s" f" MAKE-F ar CASE-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   REPLAY-COPY--OUTCOME:READY r REPLAY:UNPLACED-COPY SOME-BLOCK$
   s" -" T$= s" none" T$=
   j ar JOURNAL$ s" pending" T$=
   MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED REPLAY-COPY--OUTCOME:BLOCKED
   r REPLAY:UNPLACED-COPY SOME-BLOCK$
   s" conflict-copy-occupied" T$= s" durable-plan" T$=
   j s" conflict-copy-occupied" ar HELD-AS drop
   REPLAY-COPY--OUTCOME:SOURCE-CHANGED r REPLAY:UNPLACED-COPY
   SOME-BLOCK$
   s" -" T$= s" fresh-observation-required" T$=
   j ar JOURNAL$ s" absent" T$=
   j JOURNAL:CLOSE
   d GONE ;


\ ---- folder applies

: APPLIED-AS ( REPLAY:remote-path-state -- REPLAY:mutation-outcome )
   REPLAY-MUTATION--OUTCOME:APPLIED ;
: CHANGED-AS ( REPLAY:remote-path-state -- REPLAY:mutation-outcome )
   REPLAY-MUTATION--OUTCOME:PRECONDITION-CHANGED ;
: STILL-PENDING ( -- REPLAY:mutation-outcome )
   REPLAY-MUTATION--OUTCOME:PENDING ;
: NO-SPACE ( -- REPLAY:mutation-outcome )
   REPLAY-MUTATION--REJECTION:INSUFFICIENT-SPACE
   REPLAY-MUTATION--OUTCOME:REJECTED ;
: H1-FILE ( -- REPLAY:remote-path-state ) s" h1" s" r1" FILE-STATE ;

\ p's baseline before a case: a file, which superseding the plan keeps
\ and completing it replaces.
: SEEDED ( JOURNAL:journal ^u8 n ^ARENA:arena -- )
   {: j p:^ pu:n ar :}
   j p pu DISPLAY OLD-REMOTE MODEL-BASELINE:PRESENT ar
   JOURNAL:RECORD-NOOP MATCH JOURNAL:noop-write
      recorded OF true ENDOF
      live-plan OF drop false ENDOF
   ;MATCH TTRUE ;

\ A case's directory and journal holding a plan at f over SEEDED's
\ baseline: a folder delete when del is set, else a folder create.
: FOLDER-PLAN
   ( bool ^ARENA:arena -- str JOURNAL:journal JOURNAL:plan-record )
   {: del:bool ar :}
   ar JOURNAL-AT {: d:str p:str :}
   p JOURNAL:OPEN {: j :}
   j s" f" ar SEEDED
   del if MODEL-OPERATION:DELETE-REMOTE-DIRECTORY else MAKE-F then
   {: o :}
   d j j s" f" o ar PLANNED ;

\ The event, the block's variant and detail, "- -" when done, the
\ journal's plan and the count, spaced.
: SUMMARY$
   ( ^u8 n REPLAY:replay-blocked ^u8 n n -- ^u8 n )
   {: e:^ eu:n b j:^ ju:n k:n :}
   e eu s" blocked" STR= if b BLOCK$ else s" -" s" -" then
   {: v:^ vu:n x:^ xu:n :}
   SB-RESET e eu SB-APPEND 32 SB-APPEND-C v vu SB-APPEND 32 SB-APPEND-C
   x xu SB-APPEND 32 SB-APPEND-C j ju SB-APPEND 32 SB-APPEND-C
   k FMT:SB-INT SB$ ;

\ o applied to f's plan, by the folder delete when del is set; the
\ summary.
: APPLIED$
   ( REPLAY:mutation-outcome bool JOURNAL:journal JOURNAL:plan-record
     ^ARENA:arena -- ^u8 n )
   {: o del:bool j plan ar :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   del if o r REPLAY:APPLY-FOLDER-DELETE-MUTATION
   else o r REPLAY:APPLY-FOLDER-MUTATION then
   REPLAY:EVENT$ r REPLAY:PASS-BLOCKED @ j ar JOURNAL$
   r REPLAY:PASS-REPORT @ COMPLETED SUMMARY$ ;

\ One arm: its summary is want; it logs the line, or nothing when the
\ line is empty.
: ARM
   ( REPLAY:mutation-outcome bool ^u8 n ^u8 n ^ARENA:arena -- )
   {: o del:bool w:^ wu:n line:^ lu:n ar :}
   del ar FOLDER-PLAN {: d:str j plan :}
   d [: o del j plan ar APPLIED$ w wu T$= ;] ar LOGGED {: t:^ tu:n :}
   lu 0= if tu 0 T= else
      t tu LINE-COUNT 1 T= t tu line lu CONTAINS? TTRUE
   then
   j JOURNAL:CLOSE
   d GONE ;

\ A folder delete arm that throws E-INVALID-STATE, logging the line
\ and leaving the plan pending.
: IMPOSSIBLE ( REPLAY:mutation-outcome ^u8 n ^ARENA:arena -- )
   {: o line:^ lu:n ar :}
   true ar FOLDER-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar REPLAY:PASS-OVER {: r :}
   d [: [: o r REPLAY:APPLY-FOLDER-DELETE-MUTATION drop ;]
      REPLAY:E-INVALID-STATE TTHROWSQ ;] ar LOGGED {: t:^ tu:n :}
   t tu LINE-COUNT 1 T= t tu line lu CONTAINS? TTRUE
   j ar JOURNAL$ s" pending" T$=
   j JOURNAL:CLOSE
   d GONE ;

: STALE-ARM ( REPLAY:mutation-outcome bool ^ARENA:arena -- )
   {: o del:bool ar :}
   o del s" blocked fresh-observation-required - present 0" s" " ar
   ARM ;

: REJECTED-ARM ( bool ^ARENA:arena -- )
   {: del:bool ar :}
   NO-SPACE del s" blocked sync-error insufficient-space pending 0"
   s" Dropbox rejected sync path `f`: insufficient_space" ar ARM ;

: PENDING-ARM ( bool ^ARENA:arena -- )
   {: del:bool ar :}
   STILL-PENDING del s" blocked remote-pending - pending 0" s" " ar
   ARM ;

: APPLY-FOLDER-MUTATION-COVERS-EVERY-OUTCOME ( ^ARENA:arena -- )
   {: ar :}
   s" apply folder mutation covers every outcome" T-LABEL
   FOLDER-STATE APPLIED-AS false s" done - - directory 1" s" " ar ARM
   GONE-STATE APPLIED-AS false ar STALE-ARM
   H1-FILE APPLIED-AS false ar STALE-ARM
   ODD-STATE APPLIED-AS false ar STALE-ARM
   false ar PENDING-ARM
   GONE-STATE CHANGED-AS false ar STALE-ARM
   H1-FILE CHANGED-AS false ar STALE-ARM
   FOLDER-STATE CHANGED-AS false ar STALE-ARM
   ODD-STATE CHANGED-AS false ar STALE-ARM
   false ar REJECTED-ARM ;

: IMPOSSIBLE-APPLIED ( REPLAY:mutation-outcome ^ARENA:arena -- )
   {: o ar :}
   o s" for `f`: folder delete returned an impossible applied state"
   ar IMPOSSIBLE ;

: APPLY-FOLDER-DELETE-MUTATION-COVERS-EVERY-OUTCOME ( ^ARENA:arena -- )
   {: ar :}
   s" apply folder delete mutation covers every outcome" T-LABEL
   GONE-STATE APPLIED-AS true s" done - - absent 1" s" " ar ARM
   H1-FILE APPLIED-AS ar IMPOSSIBLE-APPLIED
   FOLDER-STATE APPLIED-AS ar IMPOSSIBLE-APPLIED
   ODD-STATE APPLIED-AS ar IMPOSSIBLE-APPLIED
   true ar PENDING-ARM
   FOLDER-STATE CHANGED-AS true ar STALE-ARM
   H1-FILE CHANGED-AS true ar STALE-ARM
   ODD-STATE CHANGED-AS true ar STALE-ARM
   GONE-STATE CHANGED-AS
   s" for `f`: folder delete precondition changed to an impossible"
   ar IMPOSSIBLE
   true ar REJECTED-ARM ;


\ ---- upload stages

variable SENDS
TYPED-VARIABLE SENT ^LOCAL:staged-upload

: SEND ( ^LOCAL:staged-upload -- ) SENT ! 1 SENDS +! ;

\ A case's directory with its root and staging, and its open journal.
: UPLOAD-DIRS ( ^ARENA:arena -- str str str JOURNAL:journal )
   {: ar :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   d s" journal.sqlite3" ar INSIDE JOURNAL:OPEN {: j :}
   d r s j ;

: UPLOAD-PLAN
   ( JOURNAL:journal DROPBOX:hash ^ARENA:arena -- JOURNAL:plan-record )
   {: j c ar :}
   j s" notes.txt" c MODEL-OPERATION:CREATE-REMOTE ar PLANNED ;

\ The event and the block, "- -" when done.
: EVENT-BLOCK$ ( ^u8 n REPLAY:replay-blocked -- ^u8 n ^u8 n ^u8 n )
   {: e:^ eu:n b :}
   e eu s" blocked" STR= if e eu b BLOCK$ exit then
   e eu s" -" s" -" ;

\ PREPARE-UPLOAD of want for the plan, below the root r with staging s.
: PREPARED
   ( JOURNAL:journal JOURNAL:plan-record str str DROPBOX:hash
     ^ARENA:arena -- ^u8 n ^u8 n ^u8 n )
   {: j plan r:str s:str want ar :}
   0 SENDS !
   r str> s" open test root" LOCAL:OPEN-ROOT {: f:fd :}
   j f r str> plan ar REPLAY:PASS-OVER {: p :}
   s p REPLAY:PASS-STAGING !
   [: want p [: SEND REPLAY:APPLY-EVENT-DONE ;] REPLAY:PREPARE-UPLOAD
      REPLAY:EVENT$ p REPLAY:PASS-BLOCKED @ EVENT-BLOCK$ ;]
   [: f FS:CLOSE-DIR ;] finally ;

\ The target's bytes, "local edit", written below the root r.
: EDITED ( str ^ARENA:arena -- )
   s" notes.txt" rot INSIDE str> s" local edit" FS:WRITE-ALL ;

: PREPARE-UPLOAD-SENDS-THE-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" prepare upload sends the stage" T-LABEL
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r ar EDITED
   r str> s" notes.txt" ar LOCAL:OBSERVE-UPLOAD-SOURCE {: want :}
   j want ar UPLOAD-PLAN {: plan :}
   j plan r s want ar PREPARED s" -" T$= s" -" T$= s" done" T$=
   SENDS @ 1 T=
   SENT @ LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR str>
   want DROPBOX:HASH>STR str> T$=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 1 T=
   j JOURNAL:CLOSE
   d GONE ;

: PREPARE-UPLOAD-RETIRES-CHANGED-BYTES ( ^ARENA:arena -- )
   {: ar :}
   s" prepare upload retires changed bytes" T-LABEL
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r ar EDITED
   j OLD ar UPLOAD-PLAN {: plan :}
   j plan r s OLD ar PREPARED
   s" -" T$= s" fresh-observation-required" T$= s" blocked" T$=
   SENDS @ 0 T=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0 T=
   j JOURNAL:CLOSE
   d GONE ;

: PREPARE-UPLOAD-HOLDS-AN-OCCUPIED-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" prepare upload holds an occupied stage" T-LABEL
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r ar EDITED
   r str> s" notes.txt" ar LOCAL:OBSERVE-UPLOAD-SOURCE {: want :}
   s want DROPBOX:HASH>STR str> ar INSIDE str> FS:MAKE-DIR
   j want ar UPLOAD-PLAN {: plan :}
   j plan r s want ar PREPARED
   s" stage-occupied" T$= s" durable-plan" T$= s" blocked" T$=
   SENDS @ 0 T=
   j s" stage-occupied" ar HELD-AS drop
   j JOURNAL:CLOSE
   d GONE ;

: PREPARE-UPLOAD-RETIRES-A-SOURCE-THAT-WILL-NOT-OPEN ( ^ARENA:arena -- )
   {: ar :}
   s" prepare upload retires a source that will not open" T-LABEL
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r s" notes.txt" ar INSIDE str> FS:MAKE-DIR
   j OLD ar UPLOAD-PLAN {: plan :}
   d [: j plan r s OLD ar PREPARED
      s" -" T$= s" fresh-observation-required" T$= s" blocked" T$= ;]
   ar QUIETLY
   SENDS @ 0 T=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   j JOURNAL:CLOSE
   d GONE ;

: REMOTE-REPLAY-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar UNSUPPORTED-SIZE-STAYS-BLOCKED-ACROSS-REOPEN
   ar BLOCK-DURABLY-HOLDS-A-PLAN-FOR-AN-HOUR
   ar BLOCK-DURABLY-REFUSES-A-COMPLETED-PLAN
   ar PERSIST-REMOTE-BLOCK-KEEPS-OTHER-BLOCKS
   ar PERSIST-REMOTE-BLOCK-HOLDS-REMOTE-CAUSES
   ar UNPLACED-COPY-COVERS-EVERY-COPY-OUTCOME
   ar APPLY-FOLDER-MUTATION-COVERS-EVERY-OUTCOME
   ar APPLY-FOLDER-DELETE-MUTATION-COVERS-EVERY-OUTCOME
   ar PREPARE-UPLOAD-SENDS-THE-STAGE
   ar PREPARE-UPLOAD-RETIRES-CHANGED-BYTES
   ar PREPARE-UPLOAD-HOLDS-AN-OCCUPIED-STAGE
   ar PREPARE-UPLOAD-RETIRES-A-SOURCE-THAT-WILL-NOT-OPEN ;


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

\ HASHING begun and fed CHECKPOINT "x" bytes.
: XS-FED ( -- )
   HASHING DROPBOX:HASH-BEGIN
   CHECKPOINT XS-SIZE / 0 ?do XS XS-SIZE HASHING DROPBOX:HASH-FEED loop ;

: HASHED ( ^ARENA:arena -- DROPBOX:hash )
   {: ar :}
   HASHING DROPBOX:HASH-END ar COPIED DROPBOX:>HASH ;

\ The content hash of CHECKPOINT "x" bytes.
: CHECKPOINT-HASH ( ^ARENA:arena -- DROPBOX:hash ) XS-FED HASHED ;

\ The content hash of CHECKPOINT "x" bytes, then ALPHABET.
: RESUMED-HASH ( ^ARENA:arena -- DROPBOX:hash )
   XS-FED ALPHABET HASHING DROPBOX:HASH-FEED HASHED ;

\ SERVES of CHECKPOINT bytes the fake does not keep, then b.
: SERVES-PAST ( ^u8 n ^u8 n ^u8 n DROPBOX:hash -- )
   {: p:^ pu:n v:^ vu:n b:^ bu:n c:DROPBOX:hash :}
   c DROPBOX:HASH>STR str> {: h:^ hu:n :}
   p pu p pu v vu h hu CHECKPOINT bu + TEST-DROPBOX:FILE!
   v vu CHECKPOINT b bu TEST-DROPBOX:CONTENT-TAIL! ;

\ The content hash of the root r's one file, the stage.
: STAGE-HASH ( str ^ARENA:arena -- DROPBOX:hash )
   {: r:str ar :}
   r str> TEXT CAP FS-LIST:NAMES {: u:n :}
   r TEXT u ar INSIDE str> FS:OPEN-SIZED TTRUE drop {: f:fd :}
   f ar LOCAL:DROPBOX-CONTENT-HASH f FS:CLOSE-DIR ;

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

\ The last download asked the bytes from CHECKPOINT on.
: RESUMED-RANGE ( -- )
   SB-RESET s" bytes=" SB-APPEND CHECKPOINT FMT:SB-INT s" -" SB-APPEND
   SB$ TEST-DROPBOX:RANGE-SENT$ T$= ;

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
   RESUMED-RANGE
   root r s" restart.bin" rem l ar STAGED-AT s" staged" AS
   TEST-DROPBOX:RANGE-SENT? TFALSE
   3 SEEN
   root FS:CLOSE-DIR
   d GONE ;

: A-LOST-ANSWER-RESUMES-FROM-THE-CHECKPOINT ( ^ARENA:arena -- )
   {: ar :}
   s" a lost answer keeps the partial; the next resumes it" T-LABEL
   TEST-DROPBOX:RESET
   ar RESUMED-HASH {: c:DROPBOX:hash :}
   s" /resume.bin" s" resume-revision" ALPHABET c SERVES-PAST
   c s" resume-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   d s" resume.bin" rem LEASE-FOR {: l:option<LOCAL:download-slot-lease> :}
   root r s" resume.bin" c l LEASED ar CHECKPOINTED
   d ar SLOT-PATH {: slot:str :}
   TEST-DROPBOX:LOSE
   root r s" resume.bin" rem l ar STOPPED
   slot str> FS:FILE-SIZE CHECKPOINT T=
   root r s" resume.bin" rem l ar STAGED-AT s" staged" AS
   RESUMED-RANGE
   r ar STAGE-HASH DROPBOX:HASH>STR str> c DROPBOX:HASH>STR str> T$=
   2 SEEN
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

\ ---- file and delete applies --------------------------------------

\ What a case's plan does at notes.txt; keeping deletes rev-old, then
\ makes a folder there.
ENUM plan-kind DERIVE eq
   creating replacing deleting keeping ;ENUM

\ A case: its directory, sync root and open journal, notes.txt staged
\ for upload, and the plan of its kind.
STRUCTURE file-case DERIVE addr
   FIELD dir str
   FIELD root str
   FIELD journal JOURNAL:journal
   FIELD upload ^LOCAL:staged-upload
   FIELD plan JOURNAL:plan-record
   FIELD kind plan-kind
;STRUCTURE

ARENA FILE-CASES file-case

: OLD-REV ( -- DROPBOX:rev ) s" rev-old" AS-REV ;

: KIND-OPS
   ( plan-kind ^LOCAL:staged-upload ^ARENA:arena
     -- ^VEC:vector<MODEL:operation> )
   {: up ar :}
   ar OPS {: ops :}
   up LOCAL:UPLOAD-CONTENT {: c :}
   MATCH plan-kind
      creating OF c MODEL-OPERATION:CREATE-REMOTE ops OP+ ENDOF
      replacing OF
         c OLD-REV MODEL-OPERATION:REPLACE-REMOTE ops OP+
      ENDOF
      deleting OF OLD-REV MODEL-OPERATION:DELETE-REMOTE ops OP+ ENDOF
      keeping OF
         OLD-REV MODEL-OPERATION:DELETE-REMOTE ops OP+ MAKE-F ops OP+
      ENDOF
   ;MATCH ops ;

: NOTES-PLAN
   ( JOURNAL:journal plan-kind ^LOCAL:staged-upload ^ARENA:arena
     -- JOURNAL:plan-record )
   {: j k up ar :}
   k up ar KIND-OPS JOURNAL-OPERATION--PLAN:MAKE {: plan :}
   j s" notes.txt" DISPLAY plan ar JOURNAL:RECORD-PLAN NEW-PLAN ;

\ A case of the kind: notes.txt written and staged below a fresh root
\ over SEEDED's baseline, and the kind's plan for it.
: NEW-CASE ( plan-kind ^ARENA:arena -- ^file-case )
   {: k ar :}
   ar FILE-CASES-NEW {: c :}
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   d c FILE-CASE-DIR ! r c FILE-CASE-ROOT ! k c FILE-CASE-KIND !
   j c FILE-CASE-JOURNAL ! j s" notes.txt" ar SEEDED
   r s s" notes.txt" ar STAGED {: up :} up c FILE-CASE-UPLOAD !
   j k up ar NOTES-PLAN c FILE-CASE-PLAN !
   c ;

: ENDED ( ^file-case -- )
   {: c :}
   c FILE-CASE-JOURNAL @ JOURNAL:CLOSE
   c FILE-CASE-DIR @ GONE ;

: KIND$ ( MODEL:conflict -- ^u8 n )
   MATCH MODEL:conflict
      initial OF 2drop s" initial" ENDOF
      divergent OF 2drop s" divergent" ENDOF
      local-deleted OF drop s" local-deleted" ENDOF
      remote-deleted OF drop s" remote-deleted" ENDOF
   ;MATCH ;

: RECORDED$ ( JOURNAL:conflict-record -- ^u8 n )
   JOURNAL-CONFLICT--RECORD:UNMAKE {: id p x :} x KIND$ ;

: REV$ ( option<MODEL:baseline> -- ^u8 n )
   MATCH option
      none OF s" absent" ENDOF
      some OF
         MATCH MODEL:baseline
            absent OF s" absent" ENDOF
            present OF
               MODEL-REMOTE:UNMAKE {: h v :} v DROPBOX:REV>STR str>
            ENDOF
            directory OF s" directory" ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ notes.txt's plan pending or blocked; once retired, the kind of the
\ conflict it recorded, else the rev of its baseline.
: NOTES$ ( JOURNAL:journal ^ARENA:arena -- ^u8 n )
   {: j ar :}
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0<> if s" pending" exit then
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0<> if s" blocked" exit then
   j ar JOURNAL:CONFLICTS {: v :}
   v VEC:COUNT 0<> if v 0 VEC:AT @ RECORDED$ exit then
   j s" notes.txt" DISPLAY ar JOURNAL:BASELINE REV$ ;

\ Whether the case's plan is the kind k.
: KIND? ( ^file-case plan-kind -- bool )
   swap FILE-CASE-KIND @ PLAN-KIND-EQ ;

: UPLOADS? ( ^file-case -- bool )
   {: c :}
   c PLAN-KIND-CREATING KIND? c PLAN-KIND-REPLACING KIND? or ;

\ The event, the block, notes.txt's journal state and the count.
: AFTER$
   ( ^u8 n REPLAY:replay-blocked ^REPLAY:replay-report ^file-case
     ^ARENA:arena -- ^u8 n )
   {: e:^ eu:n b r c ar :}
   e eu b c FILE-CASE-JOURNAL @ ar NOTES$ r COMPLETED SUMMARY$ ;

\ o applied to the case's plan by its kind's apply word; the summary.
\ A word naming the pass's type in its effect is refused outside REPLAY.
: CASE-APPLIED$
   ( REPLAY:mutation-outcome ^file-case ^ARENA:arena -- ^u8 n )
   {: o c ar :}
   c FILE-CASE-ROOT @ OPEN-ROOT {: root:fd :}
   c FILE-CASE-JOURNAL @ root c FILE-CASE-ROOT @ str>
   c FILE-CASE-PLAN @ ar REPLAY:PASS-OVER {: p :}
   LINK p REPLAY:PASS-LINK !
   c FILE-CASE-UPLOAD @ {: up :}
   [: o c UPLOADS? if
         up c PLAN-KIND-REPLACING KIND?
         if REPLAY:FILE-MUTATION-REPLACE
         else REPLAY:FILE-MUTATION-CREATE then
         p REPLAY:APPLY-FILE-MUTATION
      else p REPLAY:APPLY-DELETE-MUTATION then
      REPLAY:EVENT$ p REPLAY:PASS-BLOCKED @ p REPLAY:PASS-REPORT @
      c ar AFTER$ ;] [: root FS:CLOSE-DIR ;] finally ;

\ The case's arm: o gives the summary want and logs the line, or
\ nothing when the line is empty.
: ARMED
   ( REPLAY:mutation-outcome ^file-case ^u8 n ^u8 n ^ARENA:arena -- )
   {: o c w:^ wu:n line:^ lu:n ar :}
   c FILE-CASE-DIR @ [: o c ar CASE-APPLIED$ w wu T$= ;] ar LOGGED
   {: t:^ tu:n :}
   lu 0= if tu 0 T= exit then
   t tu LINE-COUNT 1 T= t tu line lu CONTAINS? TTRUE ;

\ The local conflict copy of the upload, relative to the root.
: LOCAL-NAME ( ^ARENA:arena -- ^u8 n )
   {: ar :}
   s" notes.txt" LOCAL-CONFLICT--SIDE:LOCAL s" local edit" ar HASH-OF
   ar LOCAL:CONFLICT-RELATIVE-PATH ;

\ The remote conflict copy of THEIRS, relative to the root.
: REMOTE-NAME ( ^ARENA:arena -- ^u8 n )
   {: ar :}
   s" notes.txt" THEIRS ar HASH-OF ar REMOTE-COPY ;

\ The file at p below the case's root holds b when set, else nothing
\ is at p.
: COPY? ( ^file-case ^u8 n ^u8 n bool ^ARENA:arena -- )
   {: c p:^ pu:n b:^ bu:n there:bool ar :}
   c FILE-CASE-ROOT @ {: r:str :}
   there if r p pu b bu ar HOLDS exit then
   r p pu ar INSIDE str> FS:TRY-STAT TFALSE ;

\ The case's local copy holds the upload when l is set, and its
\ remote copy THEIRS when m is set; an unset one is not on disk.
: COPIES ( ^file-case bool bool ^ARENA:arena -- )
   {: c l:bool m:bool ar :}
   c ar LOCAL-NAME s" local edit" l ar COPY?
   c ar REMOTE-NAME THEIRS m ar COPY? ;

\ The case's journal recorded x at notes.txt, its one conflict.
: RECORDED ( ^file-case MODEL:conflict ^ARENA:arena -- )
   {: c x ar :}
   c FILE-CASE-JOURNAL @ ar JOURNAL:CONFLICTS {: v :}
   v VEC:COUNT 1 T=
   v VEC:COUNT 1 <> if exit then
   v 0 VEC:AT @ JOURNAL-CONFLICT--RECORD:UNMAKE {: id p y :}
   p MODEL:PATH>STR str> s" notes.txt" T$=
   y x MODEL:CONFLICT= TTRUE ;

: OURS ( ^file-case -- MODEL:local )
   FILE-CASE-UPLOAD @ LOCAL:UPLOAD-CONTENT MODEL-LOCAL:MAKE ;

\ A fresh case's arm, which places no copy.
: CASE-ARM
   ( REPLAY:mutation-outcome plan-kind ^u8 n ^u8 n ^ARENA:arena -- )
   {: o k w:^ wu:n line:^ lu:n ar :}
   k ar NEW-CASE {: c :}
   o c w wu line lu ar ARMED
   c false false ar COPIES
   c ENDED ;

\ A fresh case's arm that throws E-INVALID-STATE, logging the line,
\ leaving the plan pending and placing no copy.
: REFUSED-ARM
   ( REPLAY:mutation-outcome plan-kind ^u8 n ^ARENA:arena -- )
   {: o k line:^ lu:n ar :}
   k ar NEW-CASE {: c :}
   c FILE-CASE-DIR @
   [: [: o c ar CASE-APPLIED$ 2drop ;] REPLAY:E-INVALID-STATE
      TTHROWSQ ;] ar LOGGED {: t:^ tu:n :}
   t tu LINE-COUNT 1 T= t tu line lu CONTAINS? TTRUE
   c FILE-CASE-JOURNAL @ ar NOTES$ s" pending" T$=
   c false false ar COPIES
   c ENDED ;

: QUIET-ARM
   ( REPLAY:mutation-outcome plan-kind ^u8 n ^ARENA:arena -- )
   {: o k w:^ wu:n ar :}
   o k w wu s" " ar CASE-ARM ;

: STALE-CASE ( REPLAY:mutation-outcome plan-kind ^ARENA:arena -- )
   {: o k ar :}
   o k s" blocked fresh-observation-required - rev-old 0" ar
   QUIET-ARM ;

: OBJECT-CASE ( REPLAY:mutation-outcome plan-kind ^ARENA:arena -- )
   {: o k ar :}
   o k s" blocked remote-object - pending 0" ar QUIET-ARM ;

: PENDING-CASE ( plan-kind ^ARENA:arena -- )
   {: k ar :}
   STILL-PENDING k s" blocked remote-pending - pending 0" ar
   QUIET-ARM ;

: REJECTED-CASE ( plan-kind ^ARENA:arena -- )
   {: k ar :}
   NO-SPACE k s" blocked sync-error insufficient-space pending 0"
   s" Dropbox rejected sync path `notes.txt`: insufficient_space" ar
   CASE-ARM ;

\ notes.txt uploaded as "local edit", at rev-new.
: STORED ( ^ARENA:arena -- REPLAY:mutation-outcome )
   {: ar :}
   s" local edit" ar HASH-OF s" rev-new" REMOTE-OF
   REPLAY-REMOTE--PATH--STATE:FILE APPLIED-AS ;

: THEIRS-AS ( MODEL:remote -- REPLAY:remote-path-state )
   REPLAY-REMOTE--PATH--STATE:FILE ;

: UPLOAD-IMPOSSIBLE
   ( REPLAY:mutation-outcome plan-kind ^ARENA:arena -- )
   {: o k ar :}
   o k s" for `notes.txt`: file mutation returned an impossible"
   ar REFUSED-ARM ;

: DELETE-IMPOSSIBLE
   ( REPLAY:mutation-outcome plan-kind ^ARENA:arena -- )
   {: o k ar :}
   o k s" for `notes.txt`: delete mutation returned an impossible"
   ar REFUSED-ARM ;

: APPLY-FILE-MUTATION-COVERS-EVERY-OUTCOME ( ^ARENA:arena -- )
   {: ar :}
   s" apply file mutation covers every outcome" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   ar STORED PLAN-KIND-CREATING s" done - - rev-new 1" ar QUIET-ARM
   GONE-STATE APPLIED-AS PLAN-KIND-CREATING ar UPLOAD-IMPOSSIBLE
   FOLDER-STATE APPLIED-AS PLAN-KIND-REPLACING ar UPLOAD-IMPOSSIBLE
   ODD-STATE APPLIED-AS PLAN-KIND-CREATING ar UPLOAD-IMPOSSIBLE
   PLAN-KIND-REPLACING ar PENDING-CASE
   FOLDER-STATE CHANGED-AS PLAN-KIND-CREATING ar OBJECT-CASE
   ODD-STATE CHANGED-AS PLAN-KIND-REPLACING ar OBJECT-CASE
   GONE-STATE CHANGED-AS PLAN-KIND-CREATING
   s" for `notes.txt`: create precondition changed to an impossible"
   ar REFUSED-ARM
   PLAN-KIND-CREATING ar REJECTED-CASE
   0 SEEN ;

\ A file changed at notes.txt under the kind's upload: both copies
\ placed, THEIRS downloaded once; the case and the remote.
: COLLIDED ( plan-kind ^u8 n ^ARENA:arena -- ^file-case MODEL:remote )
   {: k w:^ wu:n ar :}
   ar THEIRS-SERVED {: h rem :}
   k ar NEW-CASE {: c :}
   rem THEIRS-AS CHANGED-AS c w wu s" " ar ARMED
   c true true ar COPIES
   1 SEEN
   c rem ;

: A-CHANGED-FILE-KEEPS-BOTH-SIDES ( ^ARENA:arena -- )
   {: ar :}
   s" a changed file keeps both sides as its conflict" T-LABEL
   PLAN-KIND-CREATING s" done - - initial 1" ar COLLIDED {: c rem :}
   c c OURS rem MODEL-CONFLICT:INITIAL ar RECORDED
   c ENDED
   PLAN-KIND-REPLACING s" done - - divergent 1" ar COLLIDED
   {: e theirs :}
   e e OURS theirs MODEL-CONFLICT:DIVERGENT ar RECORDED
   e ENDED ;

: A-DELETED-REMOTE-KEEPS-THE-LOCAL-SIDE ( ^ARENA:arena -- )
   {: ar :}
   s" a remote deletion keeps the upload as its conflict" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   PLAN-KIND-REPLACING ar NEW-CASE {: c :}
   GONE-STATE CHANGED-AS c s" done - - remote-deleted 1" s" " ar ARMED
   c true false ar COPIES
   0 SEEN
   c c OURS MODEL-CONFLICT:REMOTE-DELETED ar RECORDED
   c ENDED ;

: A-REMOTE-EDIT-KEEPS-THE-DELETED-FILE ( ^ARENA:arena -- )
   {: ar :}
   s" a remote edit keeps the deleted file as its conflict" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   PLAN-KIND-DELETING ar NEW-CASE {: c :}
   rem THEIRS-AS CHANGED-AS c s" done - - local-deleted 1" s" " ar
   ARMED
   c false true ar COPIES
   1 SEEN
   c rem MODEL-CONFLICT:LOCAL-DELETED ar RECORDED
   c ENDED ;

\ A directory at the copy p below the case's root.
: TAKEN ( ^file-case ^u8 n ^ARENA:arena -- str )
   {: c p:^ pu:n ar :}
   c FILE-CASE-ROOT @ p pu ar INSIDE {: k:str :}
   k str> FS:MAKE-DIR
   k ;

\ A fresh case's arm with the copy p taken: the plan is held, nothing
\ is placed in p, and the local copy only when l is set.
: HELD-ARM
   ( REPLAY:mutation-outcome plan-kind ^u8 n bool ^ARENA:arena -- )
   {: o k p:^ pu:n l:bool ar :}
   k ar NEW-CASE {: c :}
   c p pu ar TAKEN {: t:str :}
   o c s" blocked durable-plan conflict-copy-occupied blocked 0" s" "
   ar ARMED
   c FILE-CASE-JOURNAL @ s" conflict-copy-occupied" ar HELD-AS drop
   t str> FS:REMOVE-DIR
   c l false ar COPIES
   c ENDED ;

: AN-OCCUPIED-COPY-NAME-HOLDS-THE-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" an occupied copy name holds the plan" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   ar LOCAL-NAME {: l:^ lu:n :}
   rem THEIRS-AS CHANGED-AS PLAN-KIND-REPLACING l lu false ar HELD-ARM
   GONE-STATE CHANGED-AS PLAN-KIND-REPLACING l lu false ar HELD-ARM
   0 SEEN
   ar REMOTE-NAME {: m:^ mu:n :}
   rem THEIRS-AS CHANGED-AS PLAN-KIND-CREATING m mu true ar HELD-ARM
   rem THEIRS-AS CHANGED-AS PLAN-KIND-DELETING m mu false ar HELD-ARM ;

: APPLY-DELETE-MUTATION-COVERS-EVERY-OUTCOME ( ^ARENA:arena -- )
   {: ar :}
   s" apply delete mutation covers every outcome" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   GONE-STATE APPLIED-AS PLAN-KIND-DELETING s" done - - absent 1" ar
   QUIET-ARM
   rem THEIRS-AS APPLIED-AS PLAN-KIND-DELETING ar DELETE-IMPOSSIBLE
   FOLDER-STATE APPLIED-AS PLAN-KIND-KEEPING ar DELETE-IMPOSSIBLE
   ODD-STATE APPLIED-AS PLAN-KIND-DELETING ar DELETE-IMPOSSIBLE
   PLAN-KIND-DELETING ar PENDING-CASE
   rem THEIRS-AS CHANGED-AS PLAN-KIND-KEEPING ar STALE-CASE
   FOLDER-STATE CHANGED-AS PLAN-KIND-KEEPING ar STALE-CASE
   ODD-STATE CHANGED-AS PLAN-KIND-KEEPING ar STALE-CASE
   FOLDER-STATE CHANGED-AS PLAN-KIND-DELETING ar OBJECT-CASE
   ODD-STATE CHANGED-AS PLAN-KIND-DELETING ar OBJECT-CASE
   GONE-STATE CHANGED-AS PLAN-KIND-DELETING
   s" for `notes.txt`: delete precondition changed to an impossible"
   ar REFUSED-ARM
   PLAN-KIND-KEEPING ar REJECTED-CASE
   0 SEEN ;

: OP-STATUS ( ^VEC:vector<JOURNAL:planned-operation> n -- n )
   VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE {: id at o st :}
   st STATUS>N ;

\ The case's plan is pending, its delete done and its folder not.
: DELETE-DONE ( ^file-case ^ARENA:arena -- )
   {: c ar :}
   c FILE-CASE-JOURNAL @ ar JOURNAL:PENDING-PLANS {: v :}
   v VEC:COUNT 1 T=
   v VEC:COUNT 1 <> if exit then
   v 0 VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops 0 OP-STATUS 1 T= ops 1 OP-STATUS 0 T= ;

\ A fresh keeping case's arm completes the delete alone.
: DELETE-PASSED ( REPLAY:mutation-outcome ^ARENA:arena -- )
   {: o ar :}
   PLAN-KIND-KEEPING ar NEW-CASE {: c :}
   o c s" done - - pending 1" s" " ar ARMED
   c ar DELETE-DONE
   c false false ar COPIES
   c ENDED ;

: A-DELETE-BEFORE-A-FOLDER-LEAVES-ITS-PLAN-PENDING ( ^ARENA:arena -- )
   {: ar :}
   s" a delete before a folder leaves its plan pending" T-LABEL
   GONE-STATE APPLIED-AS ar DELETE-PASSED
   GONE-STATE CHANGED-AS ar DELETE-PASSED ;


\ ---- the remote replay loop

\ REPLAY-REMOTE-OPERATIONS-AT of the pending plans below the root r,
\ staging in s, through the bridge's link.
: REMOTE-REPLAYED
   ( JOURNAL:journal str str ^ARENA:arena -- ^REPLAY:replay-report )
   {: j r:str s:str ar :}
   r OPEN-ROOT {: f:fd :}
   [: j LINK f r str> s str> ar REPLAY:REPLAY-REMOTE-OPERATIONS-AT ;]
   [: f FS:CLOSE-DIR ;] finally ;

\ The next API call is refused 409 with Rust's lookup_error of the tag.
: LOOKUP-ERROR ( ^u8 n -- )
   {: t:^ tu:n :}
   SB-RESET S\" {\qerror_summary\q:\qpath/" SB-APPEND t tu SB-APPEND
   S\" /...\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\q" SB-APPEND
   t tu SB-APPEND S\" \q}}}" SB-APPEND
   409 s" " s" " SB$ TEST-DROPBOX:SCRIPT! ;

: NO-BASELINE? ( option<MODEL:baseline> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: BASELINE-FILE ( option<MODEL:baseline> -- MODEL:remote )
   MATCH option
      none OF s" no baseline" FAILED ENDOF
      some OF
         MATCH MODEL:baseline
            absent OF s" an absent baseline" FAILED ENDOF
            present OF ENDOF
            directory OF s" a directory baseline" FAILED ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ The fake holds a folder at p.
: FOLDER-AT ( ^u8 n -- )
   MAIN @ DROPBOX:METADATA DONE? TTRUE
   MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:KIND @ DROPBOX-KIND:FOLDER
   DROPBOX-KIND:EQ TTRUE ;

: REMOTE-REPLAY-CREATES-NESTED-PARENTS-BEFORE-THE-FILE
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_replay_creates_nested_parents_before_the_file" T-LABEL
   TEST-DROPBOX:RESET
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r s" one" ar INSIDE {: one:str :} one str> FS:MAKE-DIR
   one s" two" ar INSIDE {: two:str :} two str> FS:MAKE-DIR
   two s" file.txt" ar INSIDE str> s" nested bytes" FS:WRITE-ALL
   s" nested bytes" ar HASH-OF {: c:DROPBOX:hash :}
   j s" one/two/file.txt" c MODEL-OPERATION:CREATE-REMOTE ar PLANNED
   drop
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 1 T=
   rep BLOCKS VEC:COUNT 0 T=
   j s" one/two/file.txt" DISPLAY ar JOURNAL:BASELINE BASELINE-FILE
   MODEL-REMOTE:UNMAKE {: h v :}
   h DROPBOX:HASH>STR str> c DROPBOX:HASH>STR str> T$=
   v DROPBOX:REV>STR str> s" 01701" T$=
   TEST-DROPBOX:SEEN$
   s" /2/files/create_folder_v2 /2/files/create_folder_v2 /2/files/upload"
   T$=
   s" /one" FOLDER-AT s" /one/two" FOLDER-AT
   j JOURNAL:CLOSE
   d GONE ;

: NOOP-RECORDED? ( JOURNAL:noop-write -- bool )
   MATCH JOURNAL:noop-write
      recorded OF true ENDOF
      live-plan OF drop false ENDOF
   ;MATCH ;

\ Rust's seed_directory_baseline and the folder delete it plans at gone:
\ the case's directory, root, staging and journal.
: GONE-PLAN ( ^ARENA:arena -- str str str JOURNAL:journal )
   {: ar :}
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   j s" gone" DISPLAY MODEL-BASELINE:DIRECTORY ar JOURNAL:RECORD-NOOP
   NOOP-RECORDED? TTRUE
   j s" gone" MODEL-OPERATION:DELETE-REMOTE-DIRECTORY ar PLANNED drop
   d r s j ;

: ALREADY-ABSENT-DROPBOX-DIRECTORY-COMPLETES-ITS-REPLAYED-DELETE
   ( ^ARENA:arena -- )
   {: ar :}
   s" already_absent_dropbox_directory_completes_its_replayed_delete"
   T-LABEL
   TEST-DROPBOX:RESET
   s" not_found" LOOKUP-ERROR
   ar GONE-PLAN {: d:str r:str s:str j :}
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 1 T=
   rep BLOCKS VEC:COUNT 0 T=
   j s" gone" DISPLAY ar JOURNAL:BASELINE NO-BASELINE? TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   j JOURNAL:CLOSE
   d GONE ;

: FRESH-AT? ( REPLAY:replay-blocked ^u8 n -- bool )
   {: b a:^ u :}
   b MATCH REPLAY:replay-blocked
      fresh-observation-required OF MODEL:PATH>STR str> a u STR= ENDOF
      durable-plan OF drop drop false ENDOF
      local-object OF drop false ENDOF
      download-required OF drop drop false ENDOF
      stage-destination-occupied OF drop drop false ENDOF
      precondition-changed OF drop drop false ENDOF
      remote-operation OF drop false ENDOF
      remote-pending OF drop false ENDOF
      remote-object OF drop false ENDOF
      sync-error OF drop drop false ENDOF
   ;MATCH ;

: DROPBOX-FILE-AT-A-DELETED-DIRECTORY-PATH-RETIRES-THE-REPLAYED-DELETE
   ( ^ARENA:arena -- )
   {: ar :}
   s" dropbox_file_at_a_deleted_directory_path_retires_the_replayed_delete"
   T-LABEL
   TEST-DROPBOX:RESET
   s" not_folder" LOOKUP-ERROR
   s" file where a folder was" {: b:^ bu:n :}
   b bu ar HASH-OF {: c:DROPBOX:hash :}
   s" /gone" s" /gone" s" rev-file" c DROPBOX:HASH>STR str> bu
   TEST-DROPBOX:FILE!
   ar GONE-PLAN {: d:str r:str s:str j :}
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep BLOCKS 0 VEC:AT @ s" gone" FRESH-AT? TTRUE
   j s" gone" DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/get_metadata" T$=
   j JOURNAL:CLOSE
   d GONE ;

\ The delete of old's rev-old at delete.txt completes with no download
\ and no recovery; the recovery directory stays empty.
: DELETE-REPLAYED ( str str str str JOURNAL:journal ^ARENA:arena -- )
   {: d:str r:str s:str rec:str j ar :}
   s" old remote bytes" {: b:^ bu:n :}
   b bu ar HASH-OF {: old:DROPBOX:hash :}
   s" /delete.txt" s" /Delete.txt" s" old-rev" old DROPBOX:HASH>STR str>
   bu TEST-DROPBOX:FILE!
   j s" delete.txt" s" old-rev" AS-REV MODEL-OPERATION:DELETE-REMOTE ar
   PLANNED drop
   j r s ar REMOTE-REPLAYED COMPLETED 1 T=
   \ An empty directory removes: nothing was put in it.
   rec str> FS:REMOVE-DIR
   j ar JOURNAL:PENDING-RECOVERIES VEC:COUNT 0 T=
   j ar JOURNAL:COMPLETED-RECOVERIES VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;

\ The create of create.txt's "desired bytes", its upload's answer lost
\ before it took effect, ends the pass on a retry.
: CREATE-STOPPED ( str str JOURNAL:journal ^ARENA:arena -- )
   {: r:str s:str j ar :}
   r s" create.txt" ar INSIDE str> s" desired bytes" FS:WRITE-ALL
   s" desired bytes" ar HASH-OF {: want:DROPBOX:hash :}
   j s" create.txt" want MODEL-OPERATION:CREATE-REMOTE ar PLANNED drop
   TEST-DROPBOX:RESET TEST-DROPBOX:CUT
   [: j r s ar REMOTE-REPLAYED drop ;] REPLAY:E-DROPBOX TTHROWSQ
   LINK REPLAY-LINK:REPLY @ RETRY? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$= ;

: REMOTE-DELETE-SKIPS-BACKUP-DOWNLOAD-AND-AMBIGUOUS-CREATE-STAYS-PENDING
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_delete_skips_backup_download_and_ambiguous_create_stays_pending"
   T-LABEL
   TEST-DROPBOX:RESET
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   d s" recovery" ar INSIDE {: rec:str :} rec str> FS:MAKE-DIR
   d r s rec j ar DELETE-REPLAYED
   r s j ar CREATE-STOPPED
   j JOURNAL:CLOSE
   d s" journal.sqlite3" ar INSIDE JOURNAL:OPEN {: again :}
   again ar JOURNAL:PENDING-PLANS VEC:COUNT 1 T=
   again JOURNAL:CLOSE
   d GONE ;

\ A plan whose next operation is local is left to local replay: no
\ request, no block, both operations pending.
: A-LOCAL-OPERATION-WAITS-FOR-LOCAL-REPLAY ( ^ARENA:arena -- )
   {: ar :}
   s" a local operation waits for local replay" T-LABEL
   TEST-DROPBOX:RESET
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   ar OPS {: ops :}
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY ops OP+ MAKE-F ops OP+
   j s" f" ops ar RECORD-OPS
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 0 T=
   j ar JOURNAL:PENDING-PLANS {: v :}
   v VEC:COUNT 1 T=
   v 0 VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o st :}
   o 0 OP-STATUS 0 T= o 1 OP-STATUS 0 T=
   TEST-DROPBOX:SEEN$ s" " T$=
   j JOURNAL:CLOSE
   d GONE ;

\ Rust's replace.txt below the root r: its baseline "common bytes" at
\ old-rev, its local bytes, and the plan replacing old-rev with them.
: REPLACE-PLAN ( JOURNAL:journal str ^ARENA:arena -- )
   {: j r:str ar :}
   s" common bytes" ar HASH-OF s" old-rev" REMOTE-OF {: old :}
   j s" replace.txt" DISPLAY old MODEL-BASELINE:PRESENT ar
   JOURNAL:RECORD-NOOP NOOP-RECORDED? TTRUE
   r s" replace.txt" ar INSIDE str> s" new local bytes" FS:WRITE-ALL
   j s" replace.txt" s" new local bytes" ar HASH-OF s" old-rev" AS-REV
   MODEL-OPERATION:REPLACE-REMOTE ar PLANNED drop ;

\ Dropbox's replace.txt, shown as v: "new remote bytes" at current-rev.
: CURRENT-AT ( ^u8 n ^ARENA:arena -- MODEL:remote )
   {: v:^ vu:n ar :}
   s" new remote bytes" {: b:^ bu:n :}
   b bu ar HASH-OF {: c:DROPBOX:hash :}
   s" /replace.txt" v vu s" current-rev" c DROPBOX:HASH>STR str> bu
   TEST-DROPBOX:FILE!
   c s" current-rev" REMOTE-OF ;

\ replace.txt's local conflict copy, relative to the root.
: LOCAL-SIDE ( ^ARENA:arena -- ^u8 n )
   {: ar :}
   s" replace.txt" LOCAL-CONFLICT--SIDE:LOCAL s" new local bytes" ar
   HASH-OF ar LOCAL:CONFLICT-RELATIVE-PATH ;

\ The journal's one conflict: x at replace.txt, numbered 1.
: CONFLICTED-AS ( JOURNAL:journal MODEL:conflict ^ARENA:arena -- )
   {: j x ar :}
   j ar JOURNAL:CONFLICTS {: v :}
   v VEC:COUNT 1 T=
   v VEC:COUNT 1 <> if exit then
   v 0 VEC:AT @ JOURNAL-CONFLICT--RECORD:UNMAKE {: id p y :}
   id 1 T=
   p MODEL:PATH>STR str> s" replace.txt" T$=
   y x MODEL:CONFLICT= TTRUE ;

variable SIDES

: SIDE? ( ^u8 n -- )
   s" .omabox-conflict-" STARTS-WITH? if 1 SIDES +! then ;

\ Rust's conflict_bytes: how many conflict copies the root r holds.
: SIDES-IN ( str -- n )
   {: r:str :}
   0 SIDES !
   r str> TEXT CAP FS-LIST:NAMES {: k:n :}
   TEXT k begin dup 0 > while NEXT-NAME SIDE? repeat 2drop SIDES @ ;

: REMOTE-REPLAY-PRESERVES-CONFLICT-SIDES-WITHOUT-A-BACKUP-DOWNLOAD
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_replay_preserves_conflict_sides_without_a_backup_download"
   T-LABEL
   TEST-DROPBOX:RESET
   s" /Replace.txt" ar CURRENT-AT {: cur :}
   s" current-rev" s" new remote bytes" TEST-DROPBOX:CONTENT!
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   j r ar REPLACE-PLAN
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 1 T=
   rep BLOCKS VEC:COUNT 0 T=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   j s" replace.txt" DISPLAY ar JOURNAL:BASELINE BASELINE-FILE
   MODEL-REMOTE:UNMAKE {: h v :}
   h DROPBOX:HASH>STR str>
   s" common bytes" ar HASH-OF DROPBOX:HASH>STR str> T$=
   v DROPBOX:REV>STR str> s" old-rev" T$=
   s" new local bytes" ar HASH-OF MODEL-LOCAL:MAKE cur
   MODEL-CONFLICT:DIVERGENT {: x :}
   j x ar CONFLICTED-AS
   j ar JOURNAL:PENDING-RECOVERIES VEC:COUNT 0 T=
   j ar JOURNAL:COMPLETED-RECOVERIES VEC:COUNT 0 T=
   r SIDES-IN 2 T=
   r ar LOCAL-SIDE s" new local bytes" ar HOLDS
   r s" replace.txt" s" new remote bytes" ar HASH-OF ar REMOTE-COPY
   s" new remote bytes" ar HOLDS
   TEST-DROPBOX:SEEN$
   s" /2/files/upload /2/files/get_metadata /2/files/get_metadata /2/files/download"
   T$=
   TEST-DROPBOX:ARG-SENT$ S\" {\qpath\q:\qrev:current-rev\q}" T$=
   j JOURNAL:CLOSE
   d GONE ;

\ Whether b is the durable plan at p, rejected by Dropbox with tag t.
: REJECTED-AT? ( REPLAY:replay-blocked ^u8 n ^u8 n -- bool )
   {: b p:^ pu:n t:^ tu:n :}
   b MATCH REPLAY:replay-blocked
      durable-plan OF {: at why :}
         at MODEL:PATH>STR str> p pu STR= why BLOCKAGE$ t tu STR= and
      ENDOF
      local-object OF drop false ENDOF
      fresh-observation-required OF drop false ENDOF
      download-required OF drop drop false ENDOF
      stage-destination-occupied OF drop drop false ENDOF
      precondition-changed OF drop drop false ENDOF
      remote-operation OF drop false ENDOF
      remote-pending OF drop false ENDOF
      remote-object OF drop false ENDOF
      sync-error OF drop drop false ENDOF
   ;MATCH ;

: FOLDER-DELETE-PROBE-FAILURES-KEEP-THE-PLAN-RETRY-SAFE-OR-BLOCK-ONLY-ITS-PATH
   ( ^ARENA:arena -- )
   {: ar :}
   s" folder_delete_probe_failures_keep_the_plan_retry_safe_or_block_only_its_path"
   T-LABEL
   TEST-DROPBOX:RESET
   503 s" " s" " s" {}" TEST-DROPBOX:SCRIPT!
   ar GONE-PLAN {: d:str r:str s:str j :}
   [: j r s ar REMOTE-REPLAYED drop ;] REPLAY:E-DROPBOX TTHROWSQ
   LINK REPLAY-LINK:REPLY @ RETRY? TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 1 T=
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0 T=
   s" restricted_content" LOOKUP-ERROR
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep BLOCKS 0 VEC:AT @ s" gone" s" rejected_by_dropbox" REJECTED-AT?
   TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 1 T=
   j s" gone" DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/list_folder" T$=
   j JOURNAL:CLOSE
   d GONE ;

\ The pass below the root r throws LOCAL's E-IO, its errno EACCES,
\ read before the root's close clears it.
: COPY-DENIED ( JOURNAL:journal str str ^ARENA:arena -- )
   {: j r:str s:str ar :}
   r OPEN-ROOT {: f:fd :}
   [: [: j LINK f r str> s str> ar REPLAY:REPLAY-REMOTE-OPERATIONS-AT
         drop ;] LOCAL:E-IO TTHROWSQ
      FS:ERRNO FS:EACCES T= ;]
   [: f FS:CLOSE-DIR ;] finally ;

: REPLAY-DOES-NOT-BLOCK-A-CONFLICT-WHOSE-COPY-PARENT-IS-READ-ONLY
   ( ^ARENA:arena -- )
   {: ar :}
   s" replay_does_not_block_a_conflict_whose_copy_parent_is_read_only"
   T-LABEL
   TEST-DROPBOX:RESET
   s" /replace.txt" ar CURRENT-AT {: cur :}
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   j r ar REPLACE-PLAN
   r str> MODE-NO-WRITE FS:CHMOD-MODE
   [: j r s ar COPY-DENIED ;]
   [: r str> FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;] finally
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0 T=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 1 T=
   r ar LOCAL-SIDE ar INSIDE str> FS:TRY-STAT TFALSE
   r s" replace.txt" s" new local bytes" ar HOLDS
   s" /2/files/upload /2/files/get_metadata" {: w:^ wu:n :}
   TEST-DROPBOX:SEEN$ wu min w wu T$=
   j JOURNAL:CLOSE
   d GONE ;

: LOOP-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar REMOTE-REPLAY-CREATES-NESTED-PARENTS-BEFORE-THE-FILE
   ar ALREADY-ABSENT-DROPBOX-DIRECTORY-COMPLETES-ITS-REPLAYED-DELETE
   ar DROPBOX-FILE-AT-A-DELETED-DIRECTORY-PATH-RETIRES-THE-REPLAYED-DELETE
   ar REMOTE-DELETE-SKIPS-BACKUP-DOWNLOAD-AND-AMBIGUOUS-CREATE-STAYS-PENDING
   ar A-LOCAL-OPERATION-WAITS-FOR-LOCAL-REPLAY
   ar REMOTE-REPLAY-PRESERVES-CONFLICT-SIDES-WITHOUT-A-BACKUP-DOWNLOAD
   ar FOLDER-DELETE-PROBE-FAILURES-KEEP-THE-PLAN-RETRY-SAFE-OR-BLOCK-ONLY-ITS-PATH
   ar REPLAY-DOES-NOT-BLOCK-A-CONFLICT-WHOSE-COPY-PARENT-IS-READ-ONLY ;


: BRIDGE-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar EXACT-DOWNLOAD-RETRY-REUSES-A-STAGE-WITHOUT-CONSUMING-THE-BODY
   ar EXACT-DOWNLOAD-STAGE-RACE-PRESERVES-VERIFIED-STAGE
   ar CORRUPT-EXACT-DOWNLOAD-NEVER-LEAVES-INSTALLABLE-BYTES
   ar A-DOWNLOAD-LOST-MID-BODY-KEEPS-ITS-PARTIAL
   ar A-COMPLETE-416-FINISHES-THE-STAGE
   ar ANOTHER-416-RESTARTS-THE-SLOT
   ar A-LOST-ANSWER-RESUMES-FROM-THE-CHECKPOINT
   ar A-DOWNLOAD-REPORTS-ITS-TRANSFER
   ar A-REMOTE-CONFLICT-COPY-DOWNLOADS-ONCE
   ar AN-OCCUPIED-REMOTE-COPY-NAME-BLOCKS-IT
   ar AN-OCCUPIED-REMOTE-COPY-STAGE-BLOCKS-IT
   ar A-REMOTE-COPY-INSTALLS-AT-ITS-TARGET
   ar APPLY-FILE-MUTATION-COVERS-EVERY-OUTCOME
   ar A-CHANGED-FILE-KEEPS-BOTH-SIDES
   ar A-DELETED-REMOTE-KEEPS-THE-LOCAL-SIDE
   ar A-REMOTE-EDIT-KEEPS-THE-DELETED-FILE
   ar AN-OCCUPIED-COPY-NAME-HOLDS-THE-PLAN
   ar APPLY-DELETE-MUTATION-COVERS-EVERY-OUTCOME
   ar A-DELETE-BEFORE-A-FOLDER-LEAVES-ITS-PLAN-PENDING ;

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
   [: ar BRIDGE-CASES ar LOOP-CASES ;]
   [: MAIN @ DROPBOX:CLOSE RUNTIME @ GONE ;] finally ;


\ The mutation, bridge and remote replay cases against one fake Dropbox,
\ under curl's loop.
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
   ar REMOTE-REPLAY-CASES
   ar DROPBOX-CASES ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" replay-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
