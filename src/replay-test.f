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
\ - MATERIALIZE-LOCAL-CONFLICT-AT, given a staged upload in a fresh sync
\   root, answers blocked conflict-copy-occupied for a directory at the
\   copy's name, logging nothing, or an unreadable file there, and ready
\   beside a directory elsewhere, and passes up LOCAL's E-IO when the
\   copy's parent denies writes.
\ - CLASSIFY over every pair of expectation and remote state, against
\   Rust's MutationExpectation::classify.
\ - REJECTION over every DROPBOX error: a path's rejection, or E-DROPBOX
\   with the refusal kept in the link.
\ - Rust's download_failures_separate_path_blocks_from_global_errors:
\   DOWNLOAD-BLOCKAGE of E-DROPBOX over every DROPBOX reply and error, a
\   path's blockage or none, the reply kept in the link; of DROPBOX's
\   E-REDIRECT and E-TRANSPORT and LOCAL's E-IO, none.
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
\   retire it; a directory at the stage blocks it
\   stage-destination-occupied at the stage's path, the plan pending; a
\   directory at the target retires it, logging nothing.
\ Against the fake Dropbox of test-dropbox.f, on test-client.f's
\ client, root empty:
\ - REMOTE-CREATE-FOLDER of a folder Dropbox already holds, refused as a
\   conflict, is read back as applied.
\ - REMOTE-DELETE-FOLDER of an empty folder deletes it; of an occupied
\   one, or one the listing answers not_found, deletes nothing; Rust's
\   folder_delete_probe_outcomes_are_classified_per_path, whose 503
\   throws E-DROPBOX with a retry.
\ - REMOTE-UPLOAD of a new file sends its progress, then a finished
\   transfer to a STATUS in TMPDIR; one Dropbox refuses as a conflict
\   with other bytes at the path is read back as changed, and its
\   finished transfer is sent; one refused as a conflict with its own
\   bytes at the path is read back as applied; a read-back incomplete
\   file is rejected, and an incomplete upload answer is read back;
\   Rust's verification_without_a_lowercase_path_is_invalid_metadata.
\ - REMOTE-DELETE-FILE without a rev throws E-INVALID-STATE, logging
\   once, with no request; one refused as a conflict for a path now gone
\   is read back as applied.
\ - STAGE-EXACT-DOWNLOAD-AT against the fake Dropbox: Rust's
\   exact_download_retry_reuses_a_stage_without_consuming_the_body,
\   exact_download_stage_race_preserves_verified_stage, with the stage
\   back while the call is in flight, and
\   corrupt_exact_download_never_leaves_installable_bytes; a download
\   lost mid-body throws E-DROPBOX with a retry, keeps its slot and
\   leaks no descriptor, and the next stages it; a slot holding a
\   checkpoint: a 416 at its length finishes the stage; Rust's
\   unsatisfiable_resume_restarts_only_the_owned_partial, from a lost
\   answer sent with its Range, and
\   interrupted_exact_download_resumes_only_from_a_valid_range, whose
\   eight bad answers are each refused unverified, logged once, the slot
\   at its checkpoint; a download's progress, then finished, in a status
\   under TMPDIR.
\ - MATERIALIZE-REMOTE-CONFLICT-AT downloads the copy once, then is ready
\   with no request; a directory or other bytes at the copy's name
\   block it conflict-copy-occupied, logging nothing; other bytes at
\   its stage block it stage-occupied, logged once, with no request.
\   MATERIALIZE-REMOTE-COPY-AT installs at a target apart from the
\   source path, and answers destination-changed for other bytes there.
\ - APPLY-FILE-MUTATION and APPLY-DELETE-MUTATION over every mutation
\   outcome, a staged upload below a sync root and the fake serving the
\   remote side: the event, the block, the plan pending, held,
\   completed, retired or finished as its conflict, the count, the
\   conflict copies on disk, the downloads and the one line logged; a
\   replace whose remote side's download Dropbox refuses, answers 400 or
\   404, or whose bytes do not verify, holds only its plan, its local
\   copy placed, logging the block once, and a 400 or 404 once more by
\   DROPBOX; one whose remote side's download Dropbox answers 503, or
\   whose token refresh it answers 400, throws E-DROPBOX with a retry
\   in the link, or DROPBOX's E-BAD-REQUEST, its plan left pending.
\ - REPLAY-REMOTE-OPERATIONS-AT against the fake Dropbox: Rust's
\   remote_replay_creates_nested_parents_before_the_file,
\   already_absent_dropbox_directory_completes_its_replayed_delete,
\   dropbox_file_at_a_deleted_directory_path_retires_the_replayed_delete
\   and remote_delete_skips_backup_download_and_ambiguous_create_stays_pending,
\   whose completed remote delete clears a retry's error the status
\   held and whose create's lost answer is read back absent, blocking its plan
\   remote-pending as the pass goes on; a plan whose next operation is
\   local is left pending, unblocked, with no request; Rust's
\   remote_replay_preserves_conflict_sides_without_a_backup_download,
\   folder_delete_probe_failures_keep_the_plan_retry_safe_or_block_only_its_path,
\   whose 503 throws E-DROPBOX with a retry and leaves its plan pending,
\   and replay_does_not_block_a_conflict_whose_copy_parent_is_read_only;
\   a pass over two plans, the first blocked at its delete, sends none of
\   its later operations and completes the second; a directory at a
\   replace's stage holds its plan stage-occupied, in the report.
\ - LOCAL-LIFECYCLE's lines are formal/LocalLifecycleTable.tla's, and
\   TLC finds formal/LocalLifecycle.tla's steps follow them.
\ - REMOTE-LIFECYCLE's lines are formal/RemoteLifecycleTable.tla's,
\   and TLC finds formal/RemoteLifecycle.tla's steps follow them.
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
require src/dropbox.f
require src/test-dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f
require src/local.f
require src/status.f
require src/replay.f
require src/test-formal.f
require src/test-client.f

\ REPLAY reopened for the private words the tests call.
package REPLAY
private

\ A pass below the root over the plan's first operation, on link l.
: PASS-OVER
   ( JOURNAL:journal fd str JOURNAL:plan-record ^link
     ^ARENA:arena -- ^pass )
   {: j root:fd p:str plan l ar :}
   j root p ar NEW-PASS {: r :}
   l r PASS-LINK !
   plan r PASS-PLAN !
   plan PLAN-OPERATIONS 0 VEC:AT @ r PASS-OPERATION !
   r ;

: EVENT$ ( apply-event -- str )
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
EXPORT REMOTE-DELETE-FILE
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
EXPORT FILE-MUTATION-ADD
EXPORT FILE-MUTATION-REPLACE
EXPORT APPLY-FILE-MUTATION
EXPORT APPLY-DELETE-MUTATION
;package

package REPLAY-TEST
private


\ ---- a case's directory ------------------------------------------

\ A case's directory and the journal path in it.
: JOURNAL-AT ( ^ARENA:arena -- str str )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: d:str :}
   d d s" journal.sqlite3" ar TEST-CLIENT:INSIDE ;

\ Rust's RetentionFixture: a case's directory, the journal path in it
\ and its recovery directory, made.
: FIXTURE ( ^ARENA:arena -- str str str )
   {: ar :}
   ar JOURNAL-AT {: d:str p:str :}
   d s" recovery" ar TEST-CLIENT:INSIDE {: r:str :}
   r FS:MAKE-DIR
   d p r ;

: GONE ( str -- ) FS:REMOVE-TREE ;

\ Runs q with fd 2 sent to stderr.txt in the case's directory d, which
\ q must leave empty: q logs nothing.
: QUIETLY ( str [ -- ] ^ARENA:arena -- )
   {: d:str q ar :}
   d s" stderr.txt" ar TEST-CLIENT:INSIDE {: e:str :}
   e STDERR:CAPTURE
   [: q execute ;] [: STDERR:;CAPTURE ;] finally
   e FS:FILE-SIZE 0 T=
   e FS:REMOVE-FILE ;


\ ---- plans ---------------------------------------------------------

: PATH-OF ( ^VEC:vector<JOURNAL:plan-record> n -- str )
   VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   p MODEL:PATH>STR ;

\ The vector holds one plan, at path.
: ONLY-AT ( ^VEC:vector<JOURNAL:plan-record> str -- )
   {: plans a:str :}
   plans VEC:COUNT 1 T=
   plans 0 PATH-OF a STR:= TTRUE ;


\ ---- recoveries ----------------------------------------------------

\ Rust's dropbox_content_hash of the bytes, read from a pipe.
: HASH-OF ( str ^ARENA:arena -- DROPBOX:hash )
   {: b:str ar :}
   FD:PIPE {: r:fd w:fd :}
   w b FD:WRITE-FULL w FS:CLOSE-DIR
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
         drop s" test path unexpectedly had a pending plan" TEST-CLIENT:FAILED
      ENDOF
   ;MATCH ;

: NOT-RECORDED ( -- )
   s" test recovery intent was not recorded" TEST-CLIENT:FAILED ;

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

: COPY-PATH$ ( JOURNAL:recovery-record -- str )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: id op p q c s at :}
   q MODEL:PATH>STR ;

\ Rust's record_recovery: a plan preserving, then deleting, the
\ content at the path, whose deletion records a recovery intent
\ copying to the destination in the recovery directory r.
: RECORD-RECOVERY
   ( JOURNAL:journal str str DROPBOX:hash ^ARENA:arena
     -- JOURNAL:plan-record JOURNAL:recovery-record )
   {: j r:str a:str c ar :}
   a TEST-CLIENT:DISPLAY {: original :}
   j original c ar PRESERVED-DELETE ar JOURNAL:RECORD-PLAN NEW-PLAN
   {: plan :}
   r original c ar REPLAY:DESTINATION {: copy :}
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
      none OF s" test recovery retention did not start" TEST-CLIENT:FAILED ENDOF
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
   p MODEL:PATH>STR p2 MODEL:PATH>STR STR:= and
   q MODEL:PATH>STR q2 MODEL:PATH>STR STR:= and
   c DROPBOX:HASH>STR c2 DROPBOX:HASH>STR STR:= and
   s STATUS>N s2 STATUS>N = and
   t t2 SAME-START? and ;

PROCESS-SYMBOLS
FUNCTION: UTIMENSAT-CALL utimensat ( n ^u8 ^u8 n -- i32 ) ;FUNCTION

-100 constant AT-FDCWD
$3FFFFFFE constant UTIME-OMIT
create TIMES 32 allot

\ The file's modification time set to the epoch, its access time kept.
: MODIFIED-AT-EPOCH ( str -- )
   FS:>PATHZ {: z:^ :}
   0 TIMES ! UTIME-OMIT TIMES 8 + ! 0 TIMES 16 + ! 0 TIMES 24 + !
   AT-FDCWD z TIMES 0 UTIMENSAT-CALL 0 T= ;

\ Root reads a mode-000 file, so its cases skip.
: ROOT-USER? ( -- bool ) FS:EUID 0 = ;


\ ---- cases ---------------------------------------------------------

: RETIRE-EXCLUDED-PLANS-SUPERSEDES-ONLY-EXCLUDED-PLANS
   ( ^ARENA:arena -- )
   {: ar :}
   s" retire excluded plans supersedes only excluded plans" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p JOURNAL:OPEN {: j :}
   j s" folder/.DS_Store" ar TEST-CLIENT:RECORD
   j s" folder/notes.md" ar TEST-CLIENT:RECORD
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
   j r boundary 1- REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 0 T=
   rec COPY-PATH$ FS:FILE? TTRUE
   j r boundary REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 1 T=
   rec COPY-PATH$ FS:EXISTS? TFALSE
   j rec FORGOTTEN
   j JOURNAL:CLOSE
   d GONE ;

\ A recovery of the content of the bytes b at the path a, with the
\ bytes w written as its payload.
: WRITTEN
   ( JOURNAL:journal str str str str ^ARENA:arena
     -- JOURNAL:plan-record JOURNAL:recovery-record )
   {: j r:str a:str b:str w:str ar :}
   j r a b ar HASH-OF ar RECORD-RECOVERY {: plan rec :}
   rec COPY-PATH$ w FS:WRITE-ALL
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
   r s" unknown-orphan" ar TEST-CLIENT:INSIDE {: orphan:str :}
   orphan s" unknown bytes" FS:WRITE-ALL
   j r epoch-seconds REPLAY:COMPLETED-RECOVERY-RETENTION +
   REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 0 T=
   pending COPY-PATH$ FS:FILE? TTRUE
   blocked COPY-PATH$ FS:FILE? TTRUE
   corrupt COPY-PATH$ FS:FILE? TTRUE
   nonregular COPY-PATH$ FS:DIR? TTRUE
   orphan FS:FILE? TTRUE
   j pending corrupt nonregular ar ELIGIBLE-KEPT
   j JOURNAL:CLOSE
   d GONE ;

\ A completed recovery of its own bytes, expired.
: VERIFIED
   ( JOURNAL:journal str str str ^ARENA:arena
     -- JOURNAL:recovery-record )
   {: j r:str a:str b:str ar :}
   j r a b b ar WRITTEN {: plan rec :}
   j plan rec ar COMPLETE-RECOVERY-AND-PLAN
   rec ;

\ Prunes at the end of retention, quietly, while locked is mode 000.
: PRUNE-LOCKED
   ( JOURNAL:journal str str JOURNAL:recovery-record ^ARENA:arena
     -- )
   {: j d:str r:str locked ar :}
   locked COPY-PATH$ 0 FS:CHMOD-MODE
   [: d [: j r epoch-seconds REPLAY:COMPLETED-RECOVERY-RETENTION +
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
   j r epoch-seconds REPLAY:PRUNE-COMPLETED-RECOVERIES-AT 1 T=
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
   ( JOURNAL:journal str ^VEC:vector<MODEL:operation>
     ^ARENA:arena -- )
   {: j a:str ops ar :}
   ops JOURNAL-OPERATION--PLAN:MAKE {: plan :}
   j a TEST-CLIENT:DISPLAY plan ar JOURNAL:RECORD-PLAN TEST-CLIENT:RECORDED? TTRUE ;

\ The content hash of the bytes "old".
: OLD ( -- DROPBOX:hash )
   s" b5fa717fc4f7b26b60d0399621cfe776638d31a054fda40246b7872a1b12f897"
   DROPBOX:>HASH ;

: OLD-REMOTE ( -- MODEL:remote )
   OLD s" rev-old" DROPBOX:>REV MODEL-REMOTE:MAKE ;

\ The case's sync root, made in its directory d.
: ROOT-IN ( str ^ARENA:arena -- str )
   s" root" swap TEST-CLIENT:INSIDE {: root:str :}
   root FS:MAKE-DIR
   root ;

\ REPLAY-LOCAL-PLANS-AT of the pending plans below root.
: REPLAYED
   ( JOURNAL:journal str ^ARENA:arena -- ^REPLAY:replay-report )
   {: j root:str ar :}
   root s" open test root" LOCAL:OPEN-ROOT {: f:fd :}
   [: j f root j ar JOURNAL:PENDING-PLANS ar
      REPLAY:REPLAY-LOCAL-PLANS-AT ;]
   [: f FS:CLOSE-DIR ;] finally ;

: COMPLETED ( ^REPLAY:replay-report -- n )
   REPLAY-REPLAY--REPORT:COMPLETED-OPERATIONS @ ;

: BLOCKS
   ( ^REPLAY:replay-report -- ^VEC:vector<REPLAY:replay-blocked> )
   REPLAY-REPLAY--REPORT:BLOCKED @ ;

\ Whether b is a local object at the path.
: LOCAL-OBJECT-AT? ( REPLAY:replay-blocked str -- bool )
   {: b a:str :}
   b MATCH REPLAY:replay-blocked
      local-object OF MODEL:PATH>STR a STR:= ENDOF
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
   root s" legacy.txt" ar TEST-CLIENT:INSIDE {: f:str :}
   f s" old" FS:WRITE-ALL
   ar OPS {: ops :}
   OLD MODEL-LOCAL:MAKE MODEL-OPERATION:PRESERVE-LOCAL ops OP+
   OLD MODEL-OPERATION:DELETE-LOCAL ops OP+
   p JOURNAL:OPEN {: j :}
   j s" legacy.txt" ops ar RECORD-OPS
   j root ar REPLAYED {: r :}
   r COMPLETED 2 T=
   r BLOCKS VEC:COUNT 0 T=
   f FS:EXISTS? TFALSE
   \ An empty root removes: no copy was made in it.
   root FS:REMOVE-DIR
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
   root s" taken.txt" ar TEST-CLIENT:INSIDE FS:MAKE-DIR
   ar OPS {: ops :}
   OLD-REMOTE MODEL-OPERATION:INSTALL-LOCAL ops OP+
   p JOURNAL:OPEN {: j :}
   j s" taken.txt" ops ar RECORD-OPS
   j s" made" ar TEST-CLIENT:RECORD
   d [: j root ar REPLAYED TAKEN-BLOCKED ;] ar QUIETLY
   root s" made" ar TEST-CLIENT:INSIDE FS:EXISTS? TTRUE
   j s" made" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   j ar JOURNAL:PENDING-PLANS s" taken.txt" ONLY-AT
   j JOURNAL:CLOSE
   d GONE ;


\ ---- local conflict copies -----------------------------------------

\ 0500: its owner reads and searches it, but writes nothing in it.
$140 constant MODE-NO-WRITE

\ A case's directory, and the sync root and upload staging made in it.
: CONFLICT-DIRS ( ^ARENA:arena -- str str str )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: d:str :}
   d s" root" ar TEST-CLIENT:INSIDE {: r:str :}
   d s" staging" ar TEST-CLIENT:INSIDE {: s:str :}
   r FS:MAKE-DIR s FS:MAKE-DIR
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
   ( str str str ^ARENA:arena -- ^LOCAL:staged-upload )
   {: r:str s:str p:str ar :}
   r p ar TEST-CLIENT:INSIDE s" local edit" FS:WRITE-ALL
   r p ar LOCAL:OBSERVE-UPLOAD-SOURCE {: c:DROPBOX:hash :}
   r p s c ar LOCAL:STAGE-UPLOAD UPLOAD-OF ;

\ The absolute path of p's local conflict copy holding the upload.
: COPY-NAME
   ( str str ^LOCAL:staged-upload ^ARENA:arena -- str )
   {: r:str p:str up ar :}
   p LOCAL-CONFLICT--SIDE:LOCAL up LOCAL:UPLOAD-CONTENT ar
   LOCAL:CONFLICT-RELATIVE-PATH {: c:str :}
   r c ar TEST-CLIENT:INSIDE ;

: REASON$ ( MODEL:blockage -- str )
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
: OUTCOME$ ( REPLAY:copy-outcome -- str str )
   MATCH REPLAY:copy-outcome
      ready OF s" ready" s" " ENDOF
      blocked OF {: b:MODEL:blockage :} s" blocked" b REASON$ ENDOF
      source-changed OF s" source-changed" s" " ENDOF
   ;MATCH ;

: OPEN-ROOT ( str -- fd ) s" open test sync root" LOCAL:OPEN-ROOT ;

\ The local conflict copy of p, written below the root r.
: LOCAL-COPY$
   ( str str ^LOCAL:staged-upload ^ARENA:arena -- str str )
   {: r:str p:str up ar :}
   r OPEN-ROOT {: root:fd :}
   [: root r p TEST-CLIENT:DISPLAY up ar
      REPLAY:MATERIALIZE-LOCAL-CONFLICT-AT OUTCOME$ ;]
   [: root FS:CLOSE-DIR ;] finally ;

: BLOCKED-OCCUPIED ( str str -- )
   s" conflict-copy-occupied" T$= s" blocked" T$= ;

\ An unreadable file at the copy's name blocks the copy.
: UNREADABLE-COPY ( str ^LOCAL:staged-upload str ^ARENA:arena -- )
   {: r:str up c:str ar :}
   c s" other bytes" FS:WRITE-ALL
   c 0 FS:CHMOD-MODE
   [: r s" notes.txt" up ar LOCAL-COPY$ BLOCKED-OCCUPIED ;]
   [: c FS:MODE-PRIVATE-FILE FS:CHMOD-MODE ;] finally
   c FS:REMOVE-FILE ;

: ONLY-AN-OBJECT-AT-THE-COPY-NAME-OCCUPIES-IT ( ^ARENA:arena -- )
   {: ar :}
   s" only_an_object_at_the_copy_name_occupies_it" T-LABEL
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   r s" notes.txt" up ar COPY-NAME {: c:str :}
   c FS:MAKE-DIR
   d [: r s" notes.txt" up ar LOCAL-COPY$ BLOCKED-OCCUPIED ;] ar
   QUIETLY
   c FS:REMOVE-DIR
   r up c ar UNREADABLE-COPY
   r s" notes.d" ar TEST-CLIENT:INSIDE FS:MAKE-DIR
   r s" notes.txt" up ar LOCAL-COPY$ s" " T$= s" ready" T$=
   d GONE ;

\ The copy below dir, which denies writes; LOCAL's E-IO passes up.
: DENIED-COPY ( str ^LOCAL:staged-upload ^ARENA:arena -- )
   {: r:str up ar :}
   r OPEN-ROOT {: root:fd :}
   [: root r s" dir/notes.txt" TEST-CLIENT:DISPLAY up ar
      REPLAY:MATERIALIZE-LOCAL-CONFLICT-AT drop ;] LOCAL:E-IO TTHROWSQ
   FS:ERRNO FS:EACCES T=
   root FS:CLOSE-DIR ;

: A-DENIED-OPERATION-AT-THE-COPY-NAME-DOES-NOT-OCCUPY-IT
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_denied_operation_at_the_copy_name_does_not_occupy_it" T-LABEL
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s" dir" ar TEST-CLIENT:INSIDE {: dir:str :}
   dir FS:MAKE-DIR
   r s s" dir/notes.txt" ar STAGED {: up :}
   dir MODE-NO-WRITE FS:CHMOD-MODE
   [: r up ar DENIED-COPY ;]
   [: dir FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;] finally
   d GONE ;


\ ---- Dropbox mutations ---------------------------------------------

: STATE$ ( REPLAY:remote-path-state -- str )
   MATCH REPLAY:remote-path-state
      absent OF s" absent" ENDOF
      file OF drop s" file" ENDOF
      folder OF s" folder" ENDOF
      unsupported OF s" unsupported" ENDOF
   ;MATCH ;

: REJECTION$ ( REPLAY:mutation-rejection -- str )
   MATCH REPLAY:mutation-rejection
      invalid-path OF s" invalid-path" ENDOF
      unsupported-file-size OF s" unsupported-file-size" ENDOF
      disallowed-name OF s" disallowed-name" ENDOF
      permission-denied OF s" permission-denied" ENDOF
      insufficient-space OF s" insufficient-space" ENDOF
      operation-not-allowed OF s" operation-not-allowed" ENDOF
      path-mismatch OF s" path-mismatch" ENDOF
      rejected-by-dropbox OF s" rejected-by-dropbox" ENDOF
      content-hash-mismatch OF s" content-hash-mismatch" ENDOF
   ;MATCH ;

\ The outcome's variant and its state's or rejection's name.
: MUTATION$ ( REPLAY:mutation-outcome -- str str )
   MATCH REPLAY:mutation-outcome
      applied OF s" applied" swap STATE$ ENDOF
      pending OF s" pending" s" " ENDOF
      precondition-changed OF s" precondition-changed" swap STATE$ ENDOF
      rejected OF s" rejected" swap REJECTION$ ENDOF
   ;MATCH ;

: GIVES ( REPLAY:mutation-outcome str str -- )
   {: o a:str b:str :}
   o MUTATION$ b T$= a T$= ;

: AS-HASH ( str -- DROPBOX:hash ) DROPBOX:>HASH ;
: AS-REV ( str -- DROPBOX:rev ) DROPBOX:>REV ;

\ A file state of hash and rev.
: FILE-STATE ( str str -- REPLAY:remote-path-state )
   {: h:str v:str :}
   h AS-HASH v AS-REV MODEL-REMOTE:MAKE
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

: CHANGED ( REPLAY:mutation-outcome str -- )
   {: o s:str :}
   o s" precondition-changed" s GIVES ;

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



: REJECTS ( DROPBOX:error ^REPLAY:link str -- )
   {: e l want:str :}
   e l REPLAY:REJECTION REJECTION$ want T$= ;

\ The refusal stops the pass, kept whole in the link.
: STOPS ( DROPBOX:error ^REPLAY:link -- )
   {: e l :}
   [: e l REPLAY:REJECTION drop ;] REPLAY:E-DROPBOX TTHROWSQ
   l REPLAY-LINK:REPLY @ e TEST-CLIENT:REFUSAL? TTRUE ;

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
   DROPBOX-ERROR:CONTENT-HASH-MISMATCH l s" content-hash-mismatch" REJECTS
   DROPBOX-ERROR:PATH-MISMATCH l s" path-mismatch" REJECTS
   DROPBOX-ERROR:OTHER l s" rejected-by-dropbox" REJECTS ;

: REJECTION-COVERS-EVERY-DROPBOX-ERROR ( ^ARENA:arena -- )
   {: ar :}
   s" rejection covers every Dropbox error" T-LABEL
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: l :}
   l PATH-REFUSALS
   DROPBOX-ERROR:CONFLICT l STOPS
   DROPBOX-ERROR:RESET l STOPS
   DROPBOX-ERROR:INVALID-ROOT l STOPS
   DROPBOX-ERROR:UNVERIFIED l STOPS ;

: BLOCKAGE$ ( MODEL:blockage -- str )
   MATCH MODEL:blockage
      unsupported-file-size OF s" unsupported-file-size" ENDOF
      remote-rejected OF ENDOF
      download-unavailable OF drop s" download-unavailable" ENDOF
      download-verification-failed OF
         s" download-verification-failed"
      ENDOF
      stage-occupied OF s" stage-occupied" ENDOF
      local-object-in-way OF s" local-object-in-way" ENDOF
      remote-object OF s" remote-object" ENDOF
      conflict-copy-occupied OF s" conflict-copy-occupied" ENDOF
   ;MATCH ;

: STATUS-OF ( MODEL:blockage -- n )
   MATCH MODEL:blockage
      unsupported-file-size OF 0 ENDOF
      remote-rejected OF drop 0 ENDOF
      download-unavailable OF ENDOF
      download-verification-failed OF 0 ENDOF
      stage-occupied OF 0 ENDOF
      local-object-in-way OF 0 ENDOF
      remote-object OF 0 ENDOF
      conflict-copy-occupied OF 0 ENDOF
   ;MATCH ;

\ A blockage's variant and an unavailable download's status; none is
\ "none" 0.
: DOWNLOAD-BLOCK$ ( option<MODEL:blockage> -- str n )
   MATCH option
      none OF s" none" 0 ENDOF
      some OF {: b :} b BLOCKAGE$ b STATUS-OF ENDOF
   ;MATCH ;

\ The reply's variant, then a retry's wait, else 0.
: REPLY$ ( DROPBOX:reply -- str n )
   MATCH DROPBOX:reply
      done OF s" done" 0 ENDOF
      refused OF drop s" refused" 0 ENDOF
      retry OF {: ms:n :} s" retry" ms ENDOF
      unlinked OF s" unlinked" 0 ENDOF
   ;MATCH ;

: BLOCKS-AS ( n ^REPLAY:link str n -- )
   {: code:n l w:str st:n :}
   code l REPLAY:DOWNLOAD-BLOCKAGE DOWNLOAD-BLOCK$ {: b:str s:n :}
   b w T$= s st T= ;

\ A download Dropbox refused for e blocks as w with status st, the
\ refusal kept in the link.
: REFUSED-AS ( DROPBOX:error ^REPLAY:link str n -- )
   {: e l w:str st:n :}
   e DROPBOX-REPLY:REFUSED l REPLAY-LINK:REPLY !
   REPLAY:E-DROPBOX l w st BLOCKS-AS
   l REPLAY-LINK:REPLY @ e TEST-CLIENT:REFUSAL? TTRUE ;

: UNAVAILABLE-409 ( DROPBOX:error ^REPLAY:link -- )
   s" download-unavailable" 409 REFUSED-AS ;

: PASS-WIDE ( DROPBOX:error ^REPLAY:link -- ) s" none" 0 REFUSED-AS ;

\ With the reply y, whose variant is w, E-DROPBOX blocks nothing and
\ y stays in the link.
: REPLY-PASSES ( DROPBOX:reply ^REPLAY:link str -- )
   {: y l w:str :}
   y l REPLAY-LINK:REPLY !
   REPLAY:E-DROPBOX l s" none" 0 BLOCKS-AS
   l REPLAY-LINK:REPLY @ REPLY$ 0 T= w T$= ;

: PATH-DOWNLOADS ( ^REPLAY:link -- )
   {: l :}
   DROPBOX-ERROR:NOT-FOUND l UNAVAILABLE-409
   DROPBOX-ERROR:NOT-FILE l UNAVAILABLE-409
   DROPBOX-ERROR:NOT-FOLDER l UNAVAILABLE-409
   DROPBOX-ERROR:MALFORMED-PATH l UNAVAILABLE-409
   DROPBOX-ERROR:DISALLOWED-NAME l UNAVAILABLE-409
   DROPBOX-ERROR:NO-WRITE-PERMISSION l UNAVAILABLE-409
   DROPBOX-ERROR:RESTRICTED-CONTENT l UNAVAILABLE-409
   DROPBOX-ERROR:ACCESS-RESTRICTED l UNAVAILABLE-409
   DROPBOX-ERROR:TEAM-FOLDER l UNAVAILABLE-409
   DROPBOX-ERROR:OPERATION-SUPPRESSED l UNAVAILABLE-409
   DROPBOX-ERROR:INSUFFICIENT-SPACE l UNAVAILABLE-409
   DROPBOX-ERROR:LOCKED l UNAVAILABLE-409
   DROPBOX-ERROR:UNSUPPORTED-FILE l UNAVAILABLE-409
   DROPBOX-ERROR:PATH-MISMATCH l UNAVAILABLE-409
   DROPBOX-ERROR:OTHER l UNAVAILABLE-409
   DROPBOX-ERROR:UNVERIFIED l s" download-verification-failed" 0
   REFUSED-AS ;

: DOWNLOAD-FAILURES-SEPARATE-PATH-BLOCKS-FROM-GLOBAL-ERRORS
   ( ^ARENA:arena -- )
   {: ar :}
   s" download_failures_separate_path_blocks_from_global_errors" T-LABEL
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: l :}
   l PATH-DOWNLOADS
   DROPBOX-ERROR:CONFLICT l PASS-WIDE
   DROPBOX-ERROR:RESET l PASS-WIDE
   DROPBOX-ERROR:INVALID-ROOT l PASS-WIDE
   DROPBOX-ERROR:CONTENT-HASH-MISMATCH l PASS-WIDE
   DROPBOX-REPLY:DONE l s" done" REPLY-PASSES
   0 DROPBOX-REPLY:RETRY l s" retry" REPLY-PASSES
   DROPBOX-REPLY:UNLINKED l s" unlinked" REPLY-PASSES
   DROPBOX:E-REDIRECT l s" none" 0 BLOCKS-AS
   DROPBOX:E-TRANSPORT l s" none" 0 BLOCKS-AS
   LOCAL:E-IO l s" none" 0 BLOCKS-AS ;

: TARGET$ ( ^REPLAY:link str ^ARENA:arena -- str )
   {: l p:str ar :}
   l p TEST-CLIENT:DISPLAY ar REPLAY:TARGET MATCH option
      some OF ENDOF
      none OF s" none" ENDOF
   ;MATCH ;

\ p is no Dropbox path: no target, and no call is made for it.
: NO-TARGET ( ^REPLAY:link str ^ARENA:arena -- )
   {: l p:str ar :}
   l p ar TARGET$ s" none" T$=
   TEST-DROPBOX:RESET
   l p TEST-CLIENT:DISPLAY ar REPLAY:REMOTE-CREATE-FOLDER
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
   TEST-CLIENT:MAIN @ s" /Sync" ar TEST-CLIENT:NEW-LINK {: l :}
   l s" a/B.txt" ar TARGET$ s" /Sync/a/B.txt" T$=
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: top :}
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
   l s" f" TEST-CLIENT:DISPLAY ar REPLAY:REMOTE-DELETE-FOLDER ;

: AN-EMPTY-FOLDER-IS-DELETED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" an empty folder is deleted" T-LABEL
   TEST-DROPBOX:RESET
   l s" f" TEST-CLIENT:DISPLAY ar REPLAY:REMOTE-CREATE-FOLDER
   s" applied" s" folder" GIVES
   false OWN-PAGE
   l ar DELETE-F s" applied" s" absent" GIVES
   TEST-DROPBOX:SEEN$
   s" /2/files/create_folder_v2 /2/files/list_folder /2/files/delete_v2"
   T$= ;

: A-HELD-FOLDER-IS-READ-BACK ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a held folder is read back" T-LABEL
   TEST-DROPBOX:RESET
   l s" f" TEST-CLIENT:DISPLAY ar REPLAY:REMOTE-CREATE-FOLDER
   s" applied" s" folder" GIVES
   l s" f" TEST-CLIENT:DISPLAY ar REPLAY:REMOTE-CREATE-FOLDER
   s" applied" s" folder" GIVES
   TEST-DROPBOX:SEEN$
   s" /2/files/create_folder_v2 /2/files/create_folder_v2 /2/files/get_metadata"
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

\ Runs q with fd 2 sent to a file in the case's directory d; its text,
\ in the arena.
: LOGGED ( str [ -- ] ^ARENA:arena -- str )
   {: d:str q ar :}
   q d s" stderr.txt" ar TEST-CLIENT:INSIDE ar STDERR:CAPTURING
   {: code:n t:str :}
   code 0<> if code throw then
   t ;

: LINE-COUNT ( str -- n ) 10 STR:COUNT-CHAR ;

\ A probe Dropbox fails 503 ends the pass; Rust reads the path back.
: PROBE-UNREACHED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   503 s" " s" " s" {}" TEST-DROPBOX:SCRIPT!
   [: l ar DELETE-F drop ;] REPLAY:E-DROPBOX TTHROWSQ
   l REPLAY-LINK:REPLY @ TEST-CLIENT:RETRY? TTRUE ;

: PROBE-RESTRICTED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath/restricted_content/\q,\qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qrestricted_content\q}}}"
   TEST-DROPBOX:SCRIPT!
   l ar DELETE-F s" rejected" s" rejected-by-dropbox" GIVES ;

: PROBE-RESET ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   true OWN-PAGE TEST-DROPBOX:PAGE-RESET!
   l ar DELETE-F s" pending" s" " GIVES ;

\ A continue page whose cursor did not advance leaves the delete pending.
: PROBE-STALLED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" []" s" c1" true TEST-DROPBOX:PAGE!
   s" []" s" c1" true TEST-DROPBOX:PAGE!
   l ar DELETE-F s" pending" s" " GIVES ;

: PROBE-LATER-ENTRY ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" []" s" c1" true TEST-DROPBOX:PAGE!
   S\" [{\q.tag\q:\qfolder\q,\qpath_lower\q:\q/f/inner\q,\qpath_display\q:\q/f/inner\q}]"
   s" c2" false TEST-DROPBOX:PAGE!
   l ar DELETE-F s" precondition-changed" s" folder" GIVES ;

: PROBE-OWN-ENTRY ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   false OWN-PAGE
   l ar DELETE-F s" applied" s" absent" GIVES ;

\ A file the delete finds in the folder's place is logged once.
: PROBE-RACED ( str ^REPLAY:link ^ARENA:arena -- )
   {: d:str l ar :}
   s" /f" s" /f" s" 015f" s" abc" 3 TEST-DROPBOX:FILE!
   false OWN-PAGE
   d [: l ar DELETE-F s" applied" s" absent" GIVES ;] ar LOGGED
   {: t:str :}
   t LINE-COUNT 1 T=
   t s" Dropbox deleted a file that replaced the empty folder"
   STR:CONTAINS? TTRUE
   t s" path=f revision=015f" STR:CONTAINS? TTRUE ;

: ROUTE+ ( str -- ) s"  /2/files/" SB-APPEND SB-APPEND ;

\ What the seven probes sent after the folder's create.
: PROBES$ ( -- str )
   SB-RESET s" /2/files/create_folder_v2" SB-APPEND
   s" list_folder" ROUTE+ s" list_folder" ROUTE+
   3 0 ?do s" list_folder" ROUTE+ s" list_folder/continue" ROUTE+ loop
   2 0 ?do s" list_folder" ROUTE+ s" delete_v2" ROUTE+ loop
   SB$ ;

: FOLDER-DELETE-PROBE-OUTCOMES-ARE-CLASSIFIED-PER-PATH
   ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" folder_delete_probe_outcomes_are_classified_per_path" T-LABEL
   TEST-DROPBOX:RESET
   s" replay-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: d:str :}
   l s" f" TEST-CLIENT:DISPLAY ar REPLAY:REMOTE-CREATE-FOLDER
   s" applied" s" folder" GIVES
   l ar PROBE-UNREACHED l ar PROBE-RESTRICTED l ar PROBE-RESET
   l ar PROBE-STALLED l ar PROBE-LATER-ENTRY l ar PROBE-OWN-ENTRY
   d l ar PROBE-RACED
   TEST-DROPBOX:SEEN$ PROBES$ T$=
   d GONE ;

: RUNTIME-STATUS ( ^ARENA:arena -- str ^STATUS:status )
   {: ar :}
   s" replay-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: rt:str :}
   rt rt ar STATUS:NEW ;

4096 constant STATUS-CAP
STATUS-CAP BUFFER: STATUS-BUF

\ status.json's text below the runtime directory rt.
: STATUS-TEXT ( str ^ARENA:arena -- str )
   {: rt:str ar :}
   rt s" omabox/status.json" ar TEST-CLIENT:INSIDE
   STATUS-BUF STATUS-CAP FS:READ-ALL {: u:n :} STATUS-BUF u >str ;

: SHOWS ( str ^ARENA:arena str -- )
   {: rt:str ar want:str :}
   rt ar STATUS-TEXT want STR:CONTAINS? TTRUE ;

: UPLOAD-NOTES
   ( ^REPLAY:link ^LOCAL:staged-upload ^ARENA:arena
     -- REPLAY:mutation-outcome )
   {: l up ar :}
   l s" notes.txt" TEST-CLIENT:DISPLAY up s" " AS-REV ar REPLAY:REMOTE-UPLOAD ;

: APPLIED-FILE ( REPLAY:mutation-outcome -- MODEL:remote )
   MATCH REPLAY:mutation-outcome
      applied OF
         MATCH REPLAY:remote-path-state
            absent OF s" applied absent" TEST-CLIENT:FAILED ENDOF
            file OF ENDOF
            folder OF s" applied folder" TEST-CLIENT:FAILED ENDOF
            unsupported OF s" applied unsupported" TEST-CLIENT:FAILED ENDOF
         ;MATCH
      ENDOF
      pending OF s" pending" TEST-CLIENT:FAILED ENDOF
      precondition-changed OF drop s" changed" TEST-CLIENT:FAILED ENDOF
      rejected OF drop s" rejected" TEST-CLIENT:FAILED ENDOF
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
   c DROPBOX:HASH>STR up LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR
   T$=
   v DROPBOX:REV>STR s" 01701" T$=
   rt ar
   S\" {\qdirection\q:\qupload\q,\qpath\q:\qnotes.txt\q,\qbytes_done\q:10,\qbytes_total\q:10}"
   SHOWS
   TEST-DROPBOX:SEEN$ s" /2/files/upload" T$=
   d GONE rt GONE ;

\ A transfer of notes.txt with 3 of 10 bytes sent.
: PART-SENT ( ^STATUS:status -- )
   {: st :}
   STATUS-DIRECTION:UPLOAD s" notes.txt" 3 10 OPTION:SOME
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
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
   d GONE rt GONE ;

: A-HELD-UPLOAD-IS-READ-BACK ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a held upload is read back" T-LABEL
   TEST-DROPBOX:RESET
   ar RUNTIME-STATUS {: rt:str st :}
   st l REPLAY-LINK:STATUS !
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" notes.txt" ar STAGED {: up :}
   up LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR {: h:str :}
   s" /notes.txt" s" /notes.txt" s" 0150" h 10 TEST-DROPBOX:FILE!
   l up ar UPLOAD-NOTES APPLIED-FILE MODEL-REMOTE:UNMAKE {: c v :}
   c DROPBOX:HASH>STR h T$=
   v DROPBOX:REV>STR s" 0150" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
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
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
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
   up LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR {: h:str :}
   SB-RESET
   S\" {\qname\q:\qnotes.txt\q,\qid\q:\qid:n\q,\qpath_lower\q:\q/notes.txt\q,\qpath_display\q:\q/notes.txt\q,\qrev\q:\q01701\q,\qsize\q:10,\qcontent_hash\q:\q"
   SB-APPEND h SB-APPEND S\" \q,\qis_downloadable\q:false}" SB-APPEND
   200 s" " s" " SB$ TEST-DROPBOX:SCRIPT!
   s" /notes.txt" s" /notes.txt" s" 01702" h 10 TEST-DROPBOX:FILE!
   l up ar UPLOAD-NOTES APPLIED-FILE MODEL-REMOTE:UNMAKE {: c v :}
   c DROPBOX:HASH>STR h T$=
   v DROPBOX:REV>STR s" 01702" T$=
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
   d GONE rt GONE ;

: DROP-OUTCOME ( REPLAY:mutation-outcome -- ) drop ;

\ The upload answers the file h at /moved.txt, and get_metadata the file
\ h at bad.txt with no path_lower, as Rust's fixture does.
: MOVED-AND-UNPATHED ( str -- )
   {: h:str :}
   SB-RESET
   S\" {\qname\q:\qmoved.txt\q,\qid\q:\qid:m\q,\qpath_lower\q:\q/moved.txt\q,\qpath_display\q:\q/moved.txt\q,\qrev\q:\qmoved-rev\q,\qsize\q:10,\qcontent_hash\q:\q"
   SB-APPEND h SB-APPEND S\" \q,\qis_downloadable\q:true}" SB-APPEND
   200 s" " s" " SB$ TEST-DROPBOX:SCRIPT!
   SB-RESET
   S\" {\q.tag\q:\qfile\q,\qname\q:\qbad.txt\q,\qid\q:\qid:b\q,\qrev\q:\qbad-rev\q,\qsize\q:10,\qcontent_hash\q:\q"
   SB-APPEND h SB-APPEND S\" \q,\qis_downloadable\q:true}" SB-APPEND
   200 s" " s" " SB$ TEST-DROPBOX:SCRIPT! ;

: UPLOAD-BAD ( ^REPLAY:link ^LOCAL:staged-upload ^ARENA:arena -- )
   {: l up ar :}
   l s" bad.txt" TEST-CLIENT:DISPLAY up s" " AS-REV ar REPLAY:REMOTE-UPLOAD
   DROP-OUTCOME ;

: VERIFICATION-WITHOUT-A-LOWERCASE-PATH-IS-INVALID-METADATA
   ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" verification_without_a_lowercase_path_is_invalid_metadata" T-LABEL
   TEST-DROPBOX:RESET
   ar RUNTIME-STATUS {: rt:str st :}
   st l REPLAY-LINK:STATUS !
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s s" bad.txt" ar STAGED {: up :}
   up LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR MOVED-AND-UNPATHED
   d [: [: l up ar UPLOAD-BAD ;] DROPBOX:E-UNUSABLE TTHROWSQ ;] ar LOGGED
   {: t:str :}
   t LINE-COUNT 1 T=
   t s" files/get_metadata answered 200: an incomplete entry"
   STR:CONTAINS? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
   s" /2/files/get_metadata" TEST-DROPBOX:BODIES-TO$
   S\" {\qpath\q:\q/bad.txt\q,\qinclude_deleted\q:true}" T$=
   d GONE rt GONE ;

: A-FILE-DELETE-WITHOUT-A-REV-IS-REFUSED ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a file delete without a revision is refused" T-LABEL
   TEST-DROPBOX:RESET
   s" replay-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: d:str :}
   d [: [: l s" notes.txt" TEST-CLIENT:DISPLAY s" " AS-REV ar
         REPLAY:REMOTE-DELETE-FILE DROP-OUTCOME ;]
      REPLAY:E-INVALID-STATE TTHROWSQ ;] ar LOGGED {: t:str :}
   t LINE-COUNT 1 T=
   t s" for `notes.txt`: remote delete has no revision" STR:CONTAINS?
   TTRUE
   TEST-DROPBOX:SEEN$ s" " T$=
   d GONE ;

: A-GONE-FILE-IS-READ-BACK ( ^REPLAY:link ^ARENA:arena -- )
   {: l ar :}
   s" a gone file is read back" T-LABEL
   TEST-DROPBOX:RESET
   409 s" " s" "
   S\" {\qerror_summary\q:\qpath_write/conflict/file/...\q,\qerror\q:{\q.tag\q:\qpath_write\q,\qpath_write\q:{\q.tag\q:\qconflict\q,\qconflict\q:{\q.tag\q:\qfile\q}}}}"
   TEST-DROPBOX:SCRIPT!
   l s" notes.txt" TEST-CLIENT:DISPLAY s" 0150" AS-REV ar REPLAY:REMOTE-DELETE-FILE
   s" applied" s" absent" GIVES
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2 /2/files/get_metadata" T$= ;

: REMOTE-CASES ( ^ARENA:arena -- )
   {: ar :}
   TEST-CLIENT:MAIN @ s" " ar TEST-CLIENT:NEW-LINK {: l :}
   l ar AN-EMPTY-FOLDER-IS-DELETED
   l ar A-HELD-FOLDER-IS-READ-BACK
   l ar AN-OCCUPIED-FOLDER-IS-KEPT
   l ar A-MISSING-FOLDER-IS-ALREADY-DELETED
   l ar FOLDER-DELETE-PROBE-OUTCOMES-ARE-CLASSIFIED-PER-PATH
   l ar AN-UPLOAD-SENDS-ITS-TRANSFER
   l ar A-REFUSED-UPLOAD-FINISHES-ITS-TRANSFER
   l ar A-HELD-UPLOAD-IS-READ-BACK
   l ar A-READ-BACK-INCOMPLETE-FILE-IS-REJECTED
   l ar AN-INCOMPLETE-UPLOAD-ANSWER-IS-READ-BACK
   l ar VERIFICATION-WITHOUT-A-LOWERCASE-PATH-IS-INVALID-METADATA
   l ar A-FILE-DELETE-WITHOUT-A-REV-IS-REFUSED
   l ar A-GONE-FILE-IS-READ-BACK ;


\ ---- remote replay's blocks and folder applies

: PLAN-PATH ( JOURNAL:plan-record -- MODEL:path )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :} p ;

: FIRST-ID ( JOURNAL:plan-record -- JOURNAL:operation-id )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p ops s :}
   ops 0 VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE {: i o x st :} i ;

\ A pending plan of the one operation o at path a.
: PLANNED
   ( JOURNAL:journal str MODEL:operation ^ARENA:arena
     -- JOURNAL:plan-record )
   {: j a:str o ar :}
   j a TEST-CLIENT:DISPLAY o ar TEST-CLIENT:ONE-PLAN ar JOURNAL:RECORD-PLAN NEW-PLAN ;

ARENA OFFLINE-LINKS REPLAY:link

\ A link with no client and a status that writes nothing, for a pass
\ that makes no Dropbox call.
: OFFLINE ( ^ARENA:arena -- ^REPLAY:link )
   {: ar :}
   ar OFFLINE-LINKS-NEW {: l :}
   ar STATUS:DETACHED l REPLAY-LINK:STATUS !
   l ;

\ A case's directory and its open journal, holding one plan of o at a.
: CASE-PLAN
   ( str MODEL:operation ^ARENA:arena
     -- str JOURNAL:journal JOURNAL:plan-record )
   {: a:str o ar :}
   ar JOURNAL-AT {: d:str p:str :}
   p JOURNAL:OPEN {: j :}
   d j j a o ar PLANNED ;

: MAKE-F ( -- MODEL:operation )
   MODEL-OPERATION:CREATE-REMOTE-DIRECTORY ;

\ No descriptor: the words under test never read the pass's root.
: NO-ROOT ( -- fd ) -1 >FD ;

\ The block's variant and its detail: a durable plan's blockage, a
\ remote rejection's tag, a sync error's rejection, an occupied stage's
\ path, else "-".
: BLOCK$ ( REPLAY:replay-blocked -- str str )
   MATCH REPLAY:replay-blocked
      durable-plan OF {: p why :} s" durable-plan" why BLOCKAGE$ ENDOF
      local-object OF drop s" local-object" s" -" ENDOF
      fresh-observation-required OF
         drop s" fresh-observation-required" s" -"
      ENDOF
      download-required OF
         drop drop s" download-required" s" -"
      ENDOF
      stage-destination-occupied OF {: id at:str :}
         s" stage-destination-occupied" at
      ENDOF
      precondition-changed OF
         drop drop s" precondition-changed" s" -"
      ENDOF
      remote-operation OF drop s" remote-operation" s" -" ENDOF
      remote-pending OF drop s" remote-pending" s" -" ENDOF
      remote-object OF drop s" remote-object" s" -" ENDOF
      sync-error OF {: p why :} s" sync-error" why REJECTION$ ENDOF
   ;MATCH ;

: SOME-BLOCK$ ( option<REPLAY:replay-blocked> -- str str )
   MATCH option
      none OF s" none" s" -" ENDOF
      some OF BLOCK$ ENDOF
   ;MATCH ;

\ A blocked plan's blockage and retry time; another's status and 0.
: BLOCK-OF ( JOURNAL:plan-record -- str n )
   JOURNAL-PLAN--RECORD:UNMAKE {: id p o s :}
   s MATCH JOURNAL:plan-status
      pending OF s" pending" 0 ENDOF
      blocked OF {: why at:n :} why BLOCKAGE$ at ENDOF
      completed OF s" completed" 0 ENDOF
   ;MATCH ;

\ The journal's one plan is blocked with the blockage w; its retry time.
: HELD-AS ( JOURNAL:journal str ^ARENA:arena -- n )
   {: j w:str ar :}
   j ar JOURNAL:BLOCKED-PLANS {: held :}
   held VEC:COUNT 1 T=
   held VEC:COUNT 1 <> if 0 exit then
   held 0 VEC:AT @ BLOCK-OF {: at:n :} w T$=
   at ;

: BASELINE$ ( option<MODEL:baseline> -- str )
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
: JOURNAL$ ( JOURNAL:journal ^ARENA:arena -- str )
   {: j ar :}
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0<> if s" pending" exit then
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0<> if s" blocked" exit then
   j s" f" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE BASELINE$ ;

: UNSUPPORTED-SIZE-STAYS-BLOCKED-ACROSS-REOPEN ( ^ARENA:arena -- )
   {: ar :}
   s" unsupported_size_stays_blocked_across_reopen" T-LABEL
   s" oversized source identity" ar HASH-OF {: c :}
   s" oversized.bin" c MODEL-OPERATION:CREATE-REMOTE ar CASE-PLAN
   {: d:str j plan :}
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
   plan PLAN-PATH REPLAY-MUTATION--REJECTION:UNSUPPORTED-FILE-SIZE
   REPLAY-REPLAY--BLOCKED:SYNC-ERROR r REPLAY:PERSIST-REMOTE-BLOCK
   BLOCK$ s" unsupported-file-size" T$= s" durable-plan" T$=
   j JOURNAL:CLOSE
   d s" journal.sqlite3" ar TEST-CLIENT:INSIDE JOURNAL:OPEN {: again :}
   again s" unsupported-file-size" ar HELD-AS MEM-MAX-N T=
   again ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   again JOURNAL:CLOSE
   d GONE ;

: BLOCK-DURABLY-HOLDS-A-PLAN-FOR-AN-HOUR ( ^ARENA:arena -- )
   {: ar :}
   s" block durably holds a plan for an hour" T-LABEL
   s" f" MAKE-F ar CASE-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
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
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
   j plan ar COMPLETE-F
   d [: [: MODEL-BLOCKAGE:REMOTE-OBJECT r REPLAY:BLOCK-DURABLY drop ;]
      REPLAY:E-INVALID-STATE TTHROWSQ ;] ar LOGGED {: t:str :}
   t LINE-COUNT 1 T=
   t s" for `f`: mutation blocker lost its owning plan" STR:CONTAINS?
   TTRUE
   j JOURNAL:CLOSE
   d GONE ;

: PERSIST-REMOTE-BLOCK-KEEPS-OTHER-BLOCKS ( ^ARENA:arena -- )
   {: ar :}
   s" persist remote block keeps other blocks" T-LABEL
   s" f" MAKE-F ar CASE-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
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
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
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
   id s" stage" REPLAY-REPLAY--BLOCKED:STAGE-DESTINATION-OCCUPIED
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
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
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
: SEEDED ( JOURNAL:journal str ^ARENA:arena -- )
   {: j p:str ar :}
   j p TEST-CLIENT:DISPLAY OLD-REMOTE MODEL-BASELINE:PRESENT ar
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
   ( str REPLAY:replay-blocked str n -- str )
   {: e:str b j:str k:n :}
   e s" blocked" STR:= if b BLOCK$ else s" -" s" -" then
   {: v:str x:str :}
   SB-RESET e SB-APPEND 32 SB-APPEND-C v SB-APPEND 32 SB-APPEND-C
   x SB-APPEND 32 SB-APPEND-C j SB-APPEND 32 SB-APPEND-C
   k FMT:SB-INT SB$ ;

\ o applied to f's plan, by the folder delete when del is set; the
\ summary.
: APPLIED$
   ( REPLAY:mutation-outcome bool JOURNAL:journal JOURNAL:plan-record
     ^ARENA:arena -- str )
   {: o del:bool j plan ar :}
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
   del if o r REPLAY:APPLY-FOLDER-DELETE-MUTATION
   else o r REPLAY:APPLY-FOLDER-MUTATION then
   REPLAY:EVENT$ r REPLAY:PASS-BLOCKED @ j ar JOURNAL$
   r REPLAY:PASS-REPORT @ COMPLETED SUMMARY$ ;

\ One arm: its summary is want; it logs the line, or nothing when the
\ line is empty.
: ARM
   ( REPLAY:mutation-outcome bool str str ^ARENA:arena -- )
   {: o del:bool w:str line:str ar :}
   del ar FOLDER-PLAN {: d:str j plan :}
   d [: o del j plan ar APPLIED$ w T$= ;] ar LOGGED {: t:str :}
   line str> nip 0= if t str> nip 0 T= else
      t LINE-COUNT 1 T= t line STR:CONTAINS? TTRUE
   then
   j JOURNAL:CLOSE
   d GONE ;

\ A folder delete arm that throws E-INVALID-STATE, logging the line
\ and leaving the plan pending.
: IMPOSSIBLE ( REPLAY:mutation-outcome str ^ARENA:arena -- )
   {: o line:str ar :}
   true ar FOLDER-PLAN {: d:str j plan :}
   j NO-ROOT s" " plan ar OFFLINE ar REPLAY:PASS-OVER {: r :}
   d [: [: o r REPLAY:APPLY-FOLDER-DELETE-MUTATION drop ;]
      REPLAY:E-INVALID-STATE TTHROWSQ ;] ar LOGGED {: t:str :}
   t LINE-COUNT 1 T= t line STR:CONTAINS? TTRUE
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
   d s" journal.sqlite3" ar TEST-CLIENT:INSIDE JOURNAL:OPEN {: j :}
   d r s j ;

: UPLOAD-PLAN
   ( JOURNAL:journal DROPBOX:hash ^ARENA:arena -- JOURNAL:plan-record )
   {: j c ar :}
   j s" notes.txt" c MODEL-OPERATION:CREATE-REMOTE ar PLANNED ;

\ The event and the block, "- -" when done.
: EVENT-BLOCK$ ( str REPLAY:replay-blocked -- str str str )
   {: e:str b :}
   e s" blocked" STR:= if e b BLOCK$ exit then
   e s" -" s" -" ;

\ PREPARE-UPLOAD of want for the plan, below the root r with staging s.
: PREPARED
   ( JOURNAL:journal JOURNAL:plan-record str str DROPBOX:hash
     ^ARENA:arena -- str str str )
   {: j plan r:str s:str want ar :}
   0 SENDS !
   r s" open test root" LOCAL:OPEN-ROOT {: f:fd :}
   j f r plan ar OFFLINE ar REPLAY:PASS-OVER {: p :}
   s p REPLAY:PASS-STAGING !
   [: want p [: SEND REPLAY:APPLY-EVENT-DONE ;] REPLAY:PREPARE-UPLOAD
      REPLAY:EVENT$ p REPLAY:PASS-BLOCKED @ EVENT-BLOCK$ ;]
   [: f FS:CLOSE-DIR ;] finally ;

\ The target's bytes, "local edit", written below the root r.
: EDITED ( str ^ARENA:arena -- )
   s" notes.txt" swap TEST-CLIENT:INSIDE s" local edit" FS:WRITE-ALL ;

: PREPARE-UPLOAD-SENDS-THE-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" prepare upload sends the stage" T-LABEL
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r ar EDITED
   r s" notes.txt" ar LOCAL:OBSERVE-UPLOAD-SOURCE {: want :}
   j want ar UPLOAD-PLAN {: plan :}
   j plan r s want ar PREPARED s" -" T$= s" -" T$= s" done" T$=
   SENDS @ 1 T=
   SENT @ LOCAL:UPLOAD-CONTENT DROPBOX:HASH>STR
   want DROPBOX:HASH>STR T$=
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
   r s" notes.txt" ar LOCAL:OBSERVE-UPLOAD-SOURCE {: want :}
   s want DROPBOX:HASH>STR ar TEST-CLIENT:INSIDE {: k:str :}
   k FS:MAKE-DIR
   j want ar UPLOAD-PLAN {: plan :}
   j plan r s want ar PREPARED
   k T$= s" stage-destination-occupied" T$= s" blocked" T$=
   SENDS @ 0 T=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 1 T=
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0 T=
   j JOURNAL:CLOSE
   d GONE ;

: PREPARE-UPLOAD-RETIRES-A-SOURCE-THAT-WILL-NOT-OPEN ( ^ARENA:arena -- )
   {: ar :}
   s" prepare upload retires a source that will not open" T-LABEL
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r s" notes.txt" ar TEST-CLIENT:INSIDE FS:MAKE-DIR
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

: SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   ar TEST-CLIENT:OPENED TEST-CLIENT:MAIN !
   TEST-CLIENT:ACCOUNTED
   [: ar TARGET-JOINS-THE-ROOT-AND-REJECTS-INVALID-PATHS
      ar REMOTE-CASES ;]
   [: TEST-CLIENT:MAIN @ DROPBOX:CLOSE ;] finally ;


\ ---- the download bridge -------------------------------------------

TYPED-VARIABLE LINK REPLAY:link
TYPED-VARIABLE RUNTIME str
TYPED-VARIABLE ASIDE str
TYPED-VARIABLE STAGE-AT str

4096 constant CAP
CAP BUFFER: TEXT


\ A store that keeps no rotated token.
: KEEP-NONE ( str -- ) drop ;

: LINKED ( ^DROPBOX:client -- ) LINK REPLAY-LINK:CLIENT ! ;

: SERVES ( str str str DROPBOX:hash -- )
   {: p:str v:str b:str c:DROPBOX:hash :}
   p p v c DROPBOX:HASH>STR b str> nip TEST-DROPBOX:FILE!
   v b TEST-DROPBOX:CONTENT! ;

: REMOTE-OF ( DROPBOX:hash str -- MODEL:remote )
   DROPBOX:>REV MODEL-REMOTE:MAKE ;

: NO-LEASE ( -- option<LOCAL:download-slot-lease> ) OPTION:NONE ;

\ The case directory d's slot for target t's download of the remote.
: LEASE-FOR
   ( str str MODEL:remote -- option<LOCAL:download-slot-lease> )
   {: d:str t:str rem:MODEL:remote :}
   1 1 t rem LOCAL:NEW-SLOT-IDENTITY
   {: id:LOCAL:download-slot-identity :}
   d id [: TEST-CLIENT:UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT ;

\ STAGE-EXACT-DOWNLOAD-AT of p's remote below the root r, open as root.
: STAGED-AT
   ( fd str str MODEL:remote option<LOCAL:download-slot-lease>
     ^ARENA:arena -- LOCAL:stage-outcome<n> )
   {: root:fd r:str p:str rem:MODEL:remote
      lease:option<LOCAL:download-slot-lease> ar :}
   LINK root r p TEST-CLIENT:DISPLAY rem lease s" " ar
   REPLAY:STAGE-EXACT-DOWNLOAD-AT ;

: DROP-STAGE ( LOCAL:stage-outcome<n> -- ) drop ;

\ The outcome's variant, and its actual content or path, else empty.
: STAGE$ ( LOCAL:stage-outcome<n> -- str str )
   MATCH LOCAL:stage-outcome
      staged OF drop s" staged" s" " ENDOF
      already-staged OF drop s" already-staged" s" " ENDOF
      content-changed OF {: a:DROPBOX:hash :}
         s" content-changed" a DROPBOX:HASH>STR
      ENDOF
      destination-occupied OF {: p:str :}
         s" destination-occupied" p
      ENDOF
   ;MATCH ;

: AS ( LOCAL:stage-outcome<n> str -- )
   {: o w:str :}
   o STAGE$ drop w T$= ;

\ The stage of p's remote throws E-DROPBOX, its reply a retry.
: STOPPED
   ( fd str str MODEL:remote option<LOCAL:download-slot-lease>
     ^ARENA:arena -- )
   {: root:fd r:str p:str rem:MODEL:remote
      lease:option<LOCAL:download-slot-lease> ar :}
   [: root r p rem lease ar STAGED-AT DROP-STAGE ;]
   REPLAY:E-DROPBOX TTHROWSQ
   LINK REPLAY-LINK:REPLY @ TEST-CLIENT:RETRY? TTRUE ;

: SEEN ( n -- ) TEST-CLIENT:DOWNLOADS$ TEST-DROPBOX:SEEN$ swap T$= ;

: ALPHABET ( -- str ) s" abcdefghijklmnopqrstuvwxyz" ;

: FIRST-LINE ( str -- str )
   str> {: p:^ u:n :}
   u 0 ?do p i + c@ 10 = if p i >str unloop exit then loop
   p u >str ;

\ The case directory's download slot, listed first by its leading dot.
: SLOT-PATH ( str ^ARENA:arena -- str )
   {: d:str ar :}
   d TEXT CAP FS-LIST:NAMES {: u:n :}
   TEXT u >str FIRST-LINE {: n:str :}
   n str> {: np:^ nu:n :}
   nu 22 >= TTRUE
   np 22 >str s" .omabox-download-slot-" T$=
   d n ar TEST-CLIENT:INSIDE ;

variable HELD

\ The list's first name, after the rest past its newline.
: NEXT-NAME ( str -- str str )
   str> {: p:^ u:n :}
   u 0 ?do
      p i + c@ 10 = if
         p i + 1+ u i - 1- >str p i >str unloop exit
      then
   loop
   p u + 0 >str p u >str ;

: SAME-FILE? ( str n n -- bool )
   {: nm:str dev:n ino:n :}
   SB-RESET s" /proc/self/fd/" SB-APPEND nm SB-APPEND
   SB$ FS:TRY-STAT 0= if false exit then
   FS:STAT-DEV@ dev = FS:STAT-INO@ ino = and ;

\ How many of this process's descriptors hold the file at p.
: HOLDERS ( str -- n )
   {: p:str :}
   p FS:TRY-STAT TTRUE
   FS:STAT-DEV@ FS:STAT-INO@ {: dev:n ino:n :}
   0 HELD !
   s" /proc/self/fd" TEXT CAP FS-LIST:NAMES {: k:n :}
   TEXT k >str begin dup str> nip 0 > while
      NEXT-NAME dev ino SAME-FILE? if 1 HELD +! then
   repeat drop HELD @ ;

\ The content hash of the root r's one file, the stage.
: STAGE-HASH ( str ^ARENA:arena -- DROPBOX:hash )
   {: r:str ar :}
   r TEXT CAP FS-LIST:NAMES {: u:n :}
   r TEXT u >str ar TEST-CLIENT:INSIDE FS:OPEN-SIZED TTRUE drop {: f:fd :}
   f ar LOCAL:DROPBOX-CONTENT-HASH f FS:CLOSE-DIR ;

\ A reader of the pipe's bytes into LOCAL.
: STAGE-FROM
   ( fd str str DROPBOX:hash fd ^ARENA:arena -- LOCAL:stage-outcome<n> )
   {: root:fd r:str t:str c:DROPBOX:hash rd:fd ar :}
   root r t c [: rd -rot LOCAL:FD-READ ;] ar
   LOCAL:STAGE-DOWNLOAD-AT ;

\ The bytes b staged for target t below the root, as another download
\ stages them.
: PRESTAGED
   ( fd str str str DROPBOX:hash ^ARENA:arena
     -- LOCAL:stage-outcome<n> )
   {: root:fd r:str t:str b:str c:DROPBOX:hash ar :}
   FD:PIPE {: rd:fd w:fd :}
   w b FD:WRITE-FULL w FS:CLOSE-DIR
   [: root r t c rd ar STAGE-FROM ;] [: rd FS:CLOSE-DIR ;] finally ;

\ The race client's store: it runs while DOWNLOAD's call is in flight,
\ after the bridge found no stage, and the verified stage reappears.
: RETURNED ( str -- )
   drop ASIDE @ STAGE-AT @ FS:RENAME-FILE ;

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
: HOLDS ( str str str ^ARENA:arena -- )
   {: r:str p:str b:str ar :}
   r p ar TEST-CLIENT:INSIDE TEXT CAP FS:READ-ALL {: u:n :}
   TEXT u >str b T$= ;

: EXACT-DOWNLOAD-RETRY-REUSES-A-STAGE-WITHOUT-CONSUMING-THE-BODY
   ( ^ARENA:arena -- )
   {: ar :}
   s" exact_download_retry_reuses_a_stage_without_consuming_the_body"
   T-LABEL
   TEST-DROPBOX:RESET
   s" already staged Dropbox bytes" {: b:str :}
   b ar HASH-OF {: c:DROPBOX:hash :}
   s" /staged.txt" s" staged-revision" b c SERVES
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
   r TEXT CAP FS-LIST:NAMES {: u:n :}
   r TEXT u >str ar TEST-CLIENT:INSIDE STAGE-AT !
   d s" aside" ar TEST-CLIENT:INSIDE ASIDE !
   STAGE-AT @ ASIDE @ FS:RENAME-FILE ;

\ A fresh client refreshes its token first, and stores the rotated
\ refresh token through RETURNED.
: RACED ( fd str MODEL:remote ^ARENA:arena -- LOCAL:stage-outcome<n> )
   {: root:fd r:str rem:MODEL:remote ar :}
   s" replay-refresh-2" TEST-DROPBOX:ROTATE!
   [: RETURNED ;] s" replay-refresh" s" " ar TEST-CLIENT:CLIENT-ON {: c :}
   c LINKED
   [: root r s" raced.txt" rem NO-LEASE ar STAGED-AT ;]
   [: c DROPBOX:CLOSE TEST-CLIENT:MAIN @ LINKED
      s" fake-key" s" replay-refresh" TEST-DROPBOX:ACCEPT! ;] finally ;

: EXACT-DOWNLOAD-STAGE-RACE-PRESERVES-VERIFIED-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" exact_download_stage_race_preserves_verified_stage" T-LABEL
   TEST-DROPBOX:RESET
   s" complete expected Dropbox bytes" {: b:str :}
   b ar HASH-OF {: c:DROPBOX:hash :}
   s" /raced.txt" s" raced-revision" s" ignored response body, not read"
   c SERVES
   c s" raced-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   root r s" raced.txt" b c ar PRESTAGED s" staged" AS
   d r ar SET-ASIDE
   root r rem ar RACED s" already-staged" AS
   TEST-DROPBOX:SEEN$ s" /oauth2/token /2/files/download" T$=
   root r s" raced.txt" c NO-CONTENT ar LOCAL:INSTALL-DOWNLOAD-AT
   INSTALLED? TTRUE
   r s" raced.txt" b ar HOLDS
   root FS:CLOSE-DIR
   d GONE ;

: CORRUPT-EXACT-DOWNLOAD-NEVER-LEAVES-INSTALLABLE-BYTES ( ^ARENA:arena -- )
   {: ar :}
   s" corrupt_exact_download_never_leaves_installable_bytes" T-LABEL
   TEST-DROPBOX:RESET
   s" expected download" ar HASH-OF {: c:DROPBOX:hash :}
   s" corrupt response" {: b:str :}
   b ar HASH-OF {: actual:DROPBOX:hash :}
   s" /corrupt.txt" s" rev-corrupt" b c SERVES
   c s" rev-corrupt" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   root r s" corrupt.txt" rem NO-LEASE ar STAGED-AT STAGE$
   actual DROPBOX:HASH>STR T$= s" content-changed" T$=
   r TEXT CAP FS-LIST:NAMES 0 T=
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
   slot HOLDERS 0 T=
   slot FS:FILE-SIZE 0 T=
   root r s" lost.txt" rem l ar STAGED-AT s" staged" AS
   TEST-DROPBOX:RANGE-SENT? TFALSE
   2 SEEN
   root FS:CLOSE-DIR
   d GONE ;

\ Content-Range bytes */n.
: UNSATISFIED$ ( n -- str )
   SB-RESET s" bytes */" SB-APPEND FMT:SB-INT SB$ ;

: A-COMPLETE-416-FINISHES-THE-STAGE ( ^ARENA:arena -- )
   {: ar :}
   s" a 416 at the partial's length finishes the stage, unread" T-LABEL
   TEST-DROPBOX:RESET
   s" " ar TEST-CLIENT:PAST-HASH {: c:DROPBOX:hash :}
   c s" full-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   d s" full.bin" rem LEASE-FOR TEST-CLIENT:LEASED {: l:LOCAL:download-slot-lease :}
   root r s" full.bin" c l ar TEST-CLIENT:CHECKPOINTED
   416 s" Content-Range" TEST-CLIENT:CHECKPOINT UNSATISFIED$ s" "
   TEST-DROPBOX:SCRIPT!
   root r s" full.bin" rem l OPTION:SOME ar STAGED-AT s" staged" AS
   1 SEEN
   root FS:CLOSE-DIR
   d GONE ;

\ The last download asked the bytes from CHECKPOINT on.
: RESUMED-RANGE ( -- )
   SB-RESET s" bytes=" SB-APPEND TEST-CLIENT:CHECKPOINT FMT:SB-INT s" -" SB-APPEND
   SB$ TEST-DROPBOX:RANGE-SENT$ T$= ;

\ The last download asked for rev v.
: ASKED-REV ( str -- )
   {: v:str :}
   SB-RESET S\" {\qpath\q:\qrev:" SB-APPEND v SB-APPEND
   S\" \q}" SB-APPEND SB$ TEST-DROPBOX:ARG-SENT$ T$= ;

\ The root r's one file holds the content c.
: STAGE-HOLDS ( str DROPBOX:hash ^ARENA:arena -- )
   {: r:str c:DROPBOX:hash ar :}
   r ar STAGE-HASH DROPBOX:HASH>STR c DROPBOX:HASH>STR T$= ;

: UNSATISFIABLE-RESUME-RESTARTS-ONLY-THE-OWNED-PARTIAL
   ( ^ARENA:arena -- )
   {: ar :}
   s" unsatisfiable_resume_restarts_only_the_owned_partial" T-LABEL
   TEST-DROPBOX:RESET
   ALPHABET ar HASH-OF {: c:DROPBOX:hash :}
   s" /restart.bin" s" restart-revision" ALPHABET c SERVES
   c s" restart-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   d s" restart.bin" rem LEASE-FOR {: l:option<LOCAL:download-slot-lease> :}
   root r s" restart.bin" c l TEST-CLIENT:LEASED ar TEST-CLIENT:CHECKPOINTED
   d ar SLOT-PATH {: slot:str :}
   TEST-DROPBOX:LOSE
   root r s" restart.bin" rem l ar STOPPED
   slot HOLDERS 0 T=
   slot FS:FILE-SIZE TEST-CLIENT:CHECKPOINT T=
   RESUMED-RANGE
   s" restart-revision" ASKED-REV
   root r s" restart.bin" rem l ar STAGED-AT s" staged" AS
   TEST-DROPBOX:RANGE-SENT? TFALSE
   s" restart-revision" ASKED-REV
   r c ar STAGE-HOLDS
   3 SEEN
   root FS:CLOSE-DIR
   d GONE ;

\ The next resume of resume.bin is refused unverified, logged once;
\ the slot keeps its checkpoint and the target stays absent.
: REFUSED-RESUME
   ( fd str str MODEL:remote option<LOCAL:download-slot-lease>
     ^ARENA:arena -- )
   {: root:fd d:str r:str rem:MODEL:remote
      l:option<LOCAL:download-slot-lease> ar :}
   d [: [: root r s" resume.bin" rem l ar STAGED-AT DROP-STAGE ;]
      REPLAY:E-DROPBOX TTHROWSQ ;] ar LOGGED LINE-COUNT 1 T=
   LINK REPLAY-LINK:REPLY @ DROPBOX-ERROR:UNVERIFIED TEST-CLIENT:REFUSAL? TTRUE
   d ar SLOT-PATH FS:FILE-SIZE TEST-CLIENT:CHECKPOINT T=
   r s" resume.bin" ar TEST-CLIENT:INSIDE FS:TRY-STAT TFALSE
   RESUMED-RANGE s" resume-revision" ASKED-REV ;

\ Rust's eight bad answers in its order: a 200 with no range or body, a
\ Content-Range a byte late, a byte short or totalling a byte more,
\ another rev, another hash, another size, a valid range with no body.
: BAD-RESUMES
   ( fd str str MODEL:remote option<LOCAL:download-slot-lease>
     DROPBOX:hash ^ARENA:arena -- )
   {: root:fd d:str r:str rem:MODEL:remote
      l:option<LOCAL:download-slot-lease> c:DROPBOX:hash ar :}
   TEST-DROPBOX:IGNORE-RANGE TEST-DROPBOX:EMPTY
   root d r rem l ar REFUSED-RESUME
   TEST-DROPBOX:SKEW root d r rem l ar REFUSED-RESUME
   TEST-DROPBOX:CLIP root d r rem l ar REFUSED-RESUME
   TEST-DROPBOX:INFLATE root d r rem l ar REFUSED-RESUME
   s" /resume.bin" s" different-revision" ALPHABET c TEST-CLIENT:SERVES-PAST
   s" different-revision" TEST-DROPBOX:MISFILE
   root d r rem l ar REFUSED-RESUME
   s" different resumed bytes" ar HASH-OF DROPBOX:HASH>STR
   TEST-DROPBOX:MISHASH root d r rem l ar REFUSED-RESUME
   TEST-CLIENT:CHECKPOINT 1- TEST-DROPBOX:MISSIZE
   root d r rem l ar REFUSED-RESUME
   TEST-DROPBOX:EMPTY root d r rem l ar REFUSED-RESUME ;

: INTERRUPTED-EXACT-DOWNLOAD-RESUMES-ONLY-FROM-A-VALID-RANGE
   ( ^ARENA:arena -- )
   {: ar :}
   s" interrupted_exact_download_resumes_only_from_a_valid_range" T-LABEL
   TEST-DROPBOX:RESET
   ALPHABET ar TEST-CLIENT:PAST-HASH {: c:DROPBOX:hash :}
   s" /resume.bin" s" resume-revision" ALPHABET c TEST-CLIENT:SERVES-PAST
   c s" resume-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   d s" resume.bin" rem LEASE-FOR {: l:option<LOCAL:download-slot-lease> :}
   root r s" resume.bin" c l TEST-CLIENT:LEASED ar TEST-CLIENT:CHECKPOINTED
   d ar SLOT-PATH {: slot:str :}
   TEST-DROPBOX:LOSE
   root r s" resume.bin" rem l ar STOPPED
   slot FS:FILE-SIZE TEST-CLIENT:CHECKPOINT T=
   s" resume-revision" ASKED-REV
   root d r rem l c ar BAD-RESUMES
   root r s" resume.bin" rem l ar STAGED-AT s" staged" AS
   RESUMED-RANGE s" resume-revision" ASKED-REV
   r c ar STAGE-HOLDS
   10 SEEN
   root FS:CLOSE-DIR
   d GONE ;

\ The status file's text.
: STATUS$ ( ^ARENA:arena -- str )
   {: ar :}
   RUNTIME @ s" omabox/status.json" ar TEST-CLIENT:INSIDE
   TEXT CAP FS:READ-ALL TEXT swap >str ;

: PART-SHOWN$ ( -- str )
   s\" \"path\":\"docs/progress.txt\",\"bytes_done\":10,\"bytes_total\":26}" ;
: ALL-SHOWN$ ( -- str )
   s\" \"path\":\"docs/progress.txt\",\"bytes_done\":26,\"bytes_total\":26}" ;

: A-DOWNLOAD-REPORTS-ITS-TRANSFER ( ^ARENA:arena -- )
   {: ar :}
   s" a download sends progress, then finished on every exit" T-LABEL
   TEST-DROPBOX:RESET
   ALPHABET ar HASH-OF {: c:DROPBOX:hash :}
   s" /docs/progress.txt" s" progress-revision" ALPHABET c SERVES
   c s" progress-revision" REMOTE-OF {: rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r s" docs" ar TEST-CLIENT:INSIDE FS:MAKE-DIR
   r OPEN-ROOT {: root:fd :}
   TEST-DROPBOX:CUT-BODY
   root r s" docs/progress.txt" rem NO-LEASE ar STOPPED
   ar STATUS$ PART-SHOWN$ STR:CONTAINS? TTRUE
   root r s" docs/progress.txt" rem NO-LEASE ar STAGED-AT s" staged" AS
   ar STATUS$ ALL-SHOWN$ STR:CONTAINS? TTRUE
   root FS:CLOSE-DIR
   d GONE ;


\ ---- remote conflict copies -----------------------------------------

\ p's remote conflict copy holding c, relative to the root.
: REMOTE-COPY ( str DROPBOX:hash ^ARENA:arena -- str )
   {: p:str c:DROPBOX:hash ar :}
   p LOCAL-CONFLICT--SIDE:REMOTE c ar LOCAL:CONFLICT-RELATIVE-PATH ;

\ p's remote conflict copy, written below the root r.
: REMOTE-COPY$
   ( str str MODEL:remote ^ARENA:arena -- str str )
   {: r:str p:str rem:MODEL:remote ar :}
   r OPEN-ROOT {: root:fd :}
   [: LINK root r p TEST-CLIENT:DISPLAY rem ar
      REPLAY:MATERIALIZE-REMOTE-CONFLICT-AT OUTCOME$ ;]
   [: root FS:CLOSE-DIR ;] finally ;

: EXACT$ ( REPLAY:exact-copy-outcome -- str )
   MATCH REPLAY:exact-copy-outcome
      ready OF s" ready" ENDOF
      destination-changed OF s" destination-changed" ENDOF
      stage-occupied OF s" stage-occupied" ENDOF
      content-changed OF s" content-changed" ENDOF
      blocked OF drop s" blocked" ENDOF
   ;MATCH ;

\ The remote's exact copy at t below the root r, shown as p.
: COPY-AT$
   ( fd str str str MODEL:remote ^ARENA:arena -- str )
   {: root:fd r:str t:str p:str rem:MODEL:remote ar :}
   LINK root r t TEST-CLIENT:DISPLAY p TEST-CLIENT:DISPLAY rem ar
   REPLAY:MATERIALIZE-REMOTE-COPY-AT EXACT$ ;

: THEIRS ( -- str ) s" Dropbox's side of the conflict" ;

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
   r s" notes.txt" c ar REMOTE-COPY ar TEST-CLIENT:INSIDE {: k:str :}
   k FS:MAKE-DIR
   d [: r s" notes.txt" rem ar REMOTE-COPY$ BLOCKED-OCCUPIED ;] ar
   QUIETLY
   k FS:REMOVE-DIR
   k s" other bytes" FS:WRITE-ALL
   d [: r s" notes.txt" rem ar REMOTE-COPY$ BLOCKED-OCCUPIED ;] ar
   QUIETLY
   r s" notes.txt" c ar REMOTE-COPY s" other bytes" ar HOLDS
   d GONE ;

\ The log t holds the line once and nothing else.
: LOGS-ONCE ( str str -- )
   {: t:str line:str :}
   t LINE-COUNT 1 T= t line STR:CONTAINS? TTRUE ;

\ REPLAY's line for notes.txt's copy, blocked for the reason r.
: BLOCKED-LINE ( str -- str )
   SB-RESET s" exact download blocked for its path `notes.txt`: "
   SB-APPEND SB-APPEND SB$ ;

: AN-OCCUPIED-REMOTE-COPY-STAGE-BLOCKS-IT ( ^ARENA:arena -- )
   {: ar :}
   s" other bytes at the copy's stage block it" T-LABEL
   ar THEIRS-SERVED {: c:DROPBOX:hash rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   s" notes.txt" c ar REMOTE-COPY {: k:str :}
   root r k THEIRS c ar PRESTAGED s" staged" AS
   root FS:CLOSE-DIR
   d r ar SET-ASIDE
   STAGE-AT @ s" other bytes" FS:WRITE-ALL
   d [: r s" notes.txt" rem ar REMOTE-COPY$
      s" stage-occupied" T$= s" blocked" T$= ;] ar LOGGED
   s" stage_occupied" BLOCKED-LINE LOGS-ONCE
   0 SEEN
   STAGE-AT @ TEXT CAP FS:READ-ALL {: u:n :}
   TEXT u >str s" other bytes" T$=
   d GONE ;

: A-REMOTE-COPY-INSTALLS-AT-ITS-TARGET ( ^ARENA:arena -- )
   {: ar :}
   s" a remote copy installs at its target, never over a file" T-LABEL
   ar THEIRS-SERVED {: c:DROPBOX:hash rem:MODEL:remote :}
   ar CONFLICT-DIRS {: d:str r:str s:str :}
   r OPEN-ROOT {: root:fd :}
   root r s" moved.txt" s" notes.txt" rem ar COPY-AT$ s" ready" T$=
   r s" moved.txt" THEIRS ar HOLDS
   r s" notes.txt" ar TEST-CLIENT:INSIDE FS:TRY-STAT TFALSE
   r s" taken.txt" ar TEST-CLIENT:INSIDE s" other bytes" FS:WRITE-ALL
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
   j s" notes.txt" TEST-CLIENT:DISPLAY plan ar JOURNAL:RECORD-PLAN NEW-PLAN ;

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

: KIND$ ( MODEL:conflict -- str )
   MATCH MODEL:conflict
      initial OF 2drop s" initial" ENDOF
      divergent OF 2drop s" divergent" ENDOF
      local-deleted OF drop s" local-deleted" ENDOF
      remote-deleted OF drop s" remote-deleted" ENDOF
   ;MATCH ;

: RECORDED$ ( JOURNAL:conflict-record -- str )
   JOURNAL-CONFLICT--RECORD:UNMAKE {: id p x :} x KIND$ ;

: REV$ ( option<MODEL:baseline> -- str )
   MATCH option
      none OF s" absent" ENDOF
      some OF
         MATCH MODEL:baseline
            absent OF s" absent" ENDOF
            present OF
               MODEL-REMOTE:UNMAKE {: h v :} v DROPBOX:REV>STR
            ENDOF
            directory OF s" directory" ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ notes.txt's plan pending or blocked; once retired, the kind of the
\ conflict it recorded, else the rev of its baseline.
: NOTES$ ( JOURNAL:journal ^ARENA:arena -- str )
   {: j ar :}
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0<> if s" pending" exit then
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0<> if s" blocked" exit then
   j ar JOURNAL:CONFLICTS {: v :}
   v VEC:COUNT 0<> if v 0 VEC:AT @ RECORDED$ exit then
   j s" notes.txt" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE REV$ ;

\ Whether the case's plan is the kind k.
: KIND? ( ^file-case plan-kind -- bool )
   swap FILE-CASE-KIND @ PLAN-KIND-EQ ;

: UPLOADS? ( ^file-case -- bool )
   {: c :}
   c PLAN-KIND-CREATING KIND? c PLAN-KIND-REPLACING KIND? or ;

\ The event, the block, notes.txt's journal state and the count.
: AFTER$
   ( str REPLAY:replay-blocked ^REPLAY:replay-report ^file-case
     ^ARENA:arena -- str )
   {: e:str b r c ar :}
   e b c FILE-CASE-JOURNAL @ ar NOTES$ r COMPLETED SUMMARY$ ;

\ o applied to the case's plan by its kind's apply word; the summary.
\ A word naming the pass's type in its effect is refused outside REPLAY.
: CASE-APPLIED$
   ( REPLAY:mutation-outcome ^file-case ^ARENA:arena -- str )
   {: o c ar :}
   c FILE-CASE-ROOT @ OPEN-ROOT {: root:fd :}
   c FILE-CASE-JOURNAL @ root c FILE-CASE-ROOT @
   c FILE-CASE-PLAN @ LINK ar REPLAY:PASS-OVER {: p :}
   c FILE-CASE-UPLOAD @ {: up :}
   [: o c UPLOADS? if
         up c PLAN-KIND-REPLACING KIND?
         if REPLAY:FILE-MUTATION-REPLACE
         else REPLAY:FILE-MUTATION-ADD then
         p REPLAY:APPLY-FILE-MUTATION
      else p REPLAY:APPLY-DELETE-MUTATION then
      REPLAY:EVENT$ p REPLAY:PASS-BLOCKED @ p REPLAY:PASS-REPORT @
      c ar AFTER$ ;] [: root FS:CLOSE-DIR ;] finally ;

\ The case's arm: o gives the summary want and logs the line, or
\ nothing when the line is empty.
: ARMED
   ( REPLAY:mutation-outcome ^file-case str str ^ARENA:arena -- )
   {: o c w:str line:str ar :}
   c FILE-CASE-DIR @ [: o c ar CASE-APPLIED$ w T$= ;] ar LOGGED
   {: t:str :}
   line str> nip 0= if t str> nip 0 T= exit then
   t LINE-COUNT 1 T= t line STR:CONTAINS? TTRUE ;

\ The local conflict copy of the upload, relative to the root.
: LOCAL-NAME ( ^ARENA:arena -- str )
   {: ar :}
   s" notes.txt" LOCAL-CONFLICT--SIDE:LOCAL s" local edit" ar HASH-OF
   ar LOCAL:CONFLICT-RELATIVE-PATH ;

\ The remote conflict copy of THEIRS, relative to the root.
: REMOTE-NAME ( ^ARENA:arena -- str )
   {: ar :}
   s" notes.txt" THEIRS ar HASH-OF ar REMOTE-COPY ;

\ The file at p below the case's root holds b when set, else nothing
\ is at p.
: COPY? ( ^file-case str str bool ^ARENA:arena -- )
   {: c p:str b:str there:bool ar :}
   c FILE-CASE-ROOT @ {: r:str :}
   there if r p b ar HOLDS exit then
   r p ar TEST-CLIENT:INSIDE FS:TRY-STAT TFALSE ;

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
   p MODEL:PATH>STR s" notes.txt" T$=
   y x MODEL:CONFLICT= TTRUE ;

: OURS ( ^file-case -- MODEL:local )
   FILE-CASE-UPLOAD @ LOCAL:UPLOAD-CONTENT MODEL-LOCAL:MAKE ;

\ A fresh case's arm, which places no copy.
: CASE-ARM
   ( REPLAY:mutation-outcome plan-kind str str ^ARENA:arena -- )
   {: o k w:str line:str ar :}
   k ar NEW-CASE {: c :}
   o c w line ar ARMED
   c false false ar COPIES
   c ENDED ;

\ A fresh case's arm that throws E-INVALID-STATE, logging the line,
\ leaving the plan pending and placing no copy.
: REFUSED-ARM
   ( REPLAY:mutation-outcome plan-kind str ^ARENA:arena -- )
   {: o k line:str ar :}
   k ar NEW-CASE {: c :}
   c FILE-CASE-DIR @
   [: [: o c ar CASE-APPLIED$ drop ;] REPLAY:E-INVALID-STATE
      TTHROWSQ ;] ar LOGGED {: t:str :}
   t LINE-COUNT 1 T= t line STR:CONTAINS? TTRUE
   c FILE-CASE-JOURNAL @ ar NOTES$ s" pending" T$=
   c false false ar COPIES
   c ENDED ;

: QUIET-ARM
   ( REPLAY:mutation-outcome plan-kind str ^ARENA:arena -- )
   {: o k w:str ar :}
   o k w s" " ar CASE-ARM ;

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
: COLLIDED ( plan-kind str ^ARENA:arena -- ^file-case MODEL:remote )
   {: k w:str ar :}
   ar THEIRS-SERVED {: h rem :}
   k ar NEW-CASE {: c :}
   rem THEIRS-AS CHANGED-AS c w s" " ar ARMED
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
: TAKEN ( ^file-case str ^ARENA:arena -- str )
   {: c p:str ar :}
   c FILE-CASE-ROOT @ p ar TEST-CLIENT:INSIDE {: k:str :}
   k FS:MAKE-DIR
   k ;

\ A fresh case's arm with the copy p taken: the plan is held, nothing
\ is placed in p, and the local copy only when l is set.
: HELD-ARM
   ( REPLAY:mutation-outcome plan-kind str bool ^ARENA:arena -- )
   {: o k p:str l:bool ar :}
   k ar NEW-CASE {: c :}
   c p ar TAKEN {: t:str :}
   o c s" blocked durable-plan conflict-copy-occupied blocked 0" s" "
   ar ARMED
   c FILE-CASE-JOURNAL @ s" conflict-copy-occupied" ar HELD-AS drop
   t FS:REMOVE-DIR
   c l false ar COPIES
   c ENDED ;

: AN-OCCUPIED-COPY-NAME-HOLDS-THE-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" an occupied copy name holds the plan" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   ar LOCAL-NAME {: l:str :}
   rem THEIRS-AS CHANGED-AS PLAN-KIND-REPLACING l false ar HELD-ARM
   GONE-STATE CHANGED-AS PLAN-KIND-REPLACING l false ar HELD-ARM
   0 SEEN
   ar REMOTE-NAME {: m:str :}
   rem THEIRS-AS CHANGED-AS PLAN-KIND-CREATING m true ar HELD-ARM
   rem THEIRS-AS CHANGED-AS PLAN-KIND-DELETING m false ar HELD-ARM ;

\ The next API call is refused 409 with the union tag u's leaf tag t.
: REFUSAL ( str str -- )
   {: u:str t:str :}
   SB-RESET S\" {\qerror_summary\q:\q" SB-APPEND u SB-APPEND
   s" /" SB-APPEND t SB-APPEND
   S\" /...\q,\qerror\q:{\q.tag\q:\q" SB-APPEND u SB-APPEND
   S\" \q,\q" SB-APPEND u SB-APPEND
   S\" \q:{\q.tag\q:\q" SB-APPEND t SB-APPEND S\" \q}}}" SB-APPEND
   409 s" " s" " SB$ TEST-DROPBOX:SCRIPT! ;

\ The status of the journal's first blocked plan's unavailable
\ download, else 0.
: HELD-STATUS ( JOURNAL:journal ^ARENA:arena -- n )
   JOURNAL:BLOCKED-PLANS {: held :}
   held VEC:COUNT 0= if 0 exit then
   held 0 VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o st :}
   st MATCH JOURNAL:plan-status
      pending OF 0 ENDOF
      blocked OF {: why at:n :} why STATUS-OF ENDOF
      completed OF 0 ENDOF
   ;MATCH ;

\ A replace collided with THEIRS, whose copy fails: the summary want,
\ the plan held as w, no conflict recorded and only the local copy
\ placed, after one download; the case and what it logged.
: UNCOPIED
   ( MODEL:remote str str ^ARENA:arena -- ^file-case str )
   {: rem want:str w:str ar :}
   PLAN-KIND-REPLACING ar NEW-CASE {: c :}
   rem THEIRS-AS CHANGED-AS {: o :}
   c FILE-CASE-DIR @ [: o c ar CASE-APPLIED$ want T$= ;] ar LOGGED
   {: t:str :}
   c FILE-CASE-JOURNAL @ w ar HELD-AS drop
   c FILE-CASE-JOURNAL @ ar JOURNAL:CONFLICTS VEC:COUNT 0 T=
   c true false ar COPIES
   1 SEEN
   c t ;

: A-REFUSED-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" a refused download of the remote side holds only its plan" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   s" path" s" restricted_content" REFUSAL
   rem s" blocked durable-plan download-unavailable blocked 0"
   s" download-unavailable" ar UNCOPIED {: c t:str :}
   t s" download_unavailable 409" BLOCKED-LINE LOGS-ONCE
   c FILE-CASE-JOURNAL @ ar HELD-STATUS 409 T=
   c ENDED ;

\ The copy's download Dropbox answers st with the body b: the plan
\ is held download-unavailable st, logged once by DROPBOX as d and
\ once by REPLAY, nothing else.
: HELD-AT-STATUS ( n str str ^ARENA:arena -- )
   {: st:n b:str d:str ar :}
   ar THEIRS-SERVED {: h rem :}
   s" /2/files/download" st s" " s" " b TEST-DROPBOX:ROUTE-SCRIPT!
   rem s" blocked durable-plan download-unavailable blocked 0"
   s" download-unavailable" ar UNCOPIED {: c t:str :}
   t LINE-COUNT 2 T= t d STR:CONTAINS? TTRUE
   s" download_unavailable " SB-RESET SB-APPEND st FMT:INT$ SB-APPEND
   SB$ ar TEST-CLIENT:COPIED BLOCKED-LINE t swap STR:CONTAINS? TTRUE
   c FILE-CASE-JOURNAL @ ar HELD-STATUS st T=
   c ENDED ;

: A-REJECTED-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" a 400 download of the remote side holds only its plan" T-LABEL
   400 s" bad request" s" answered 400: a malformed request" ar
   HELD-AT-STATUS ;

: A-MISSING-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" a 404 download of the remote side holds only its plan" T-LABEL
   404 s" {}" s" answered 404: an unexpected status" ar
   HELD-AT-STATUS ;

: AN-UNVERIFIED-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" unverified bytes of the remote side hold only its plan" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   s" theirs-revision" s" Dropbox's side of the CONFLICT"
   TEST-DROPBOX:CONTENT!
   rem s" blocked durable-plan download-verification-failed blocked 0"
   s" download-verification-failed" ar UNCOPIED {: c t:str :}
   t s" download_verification_failed" BLOCKED-LINE LOGS-ONCE
   c ENDED ;

\ A replace collided with rem, whose copy's download throws code: the
\ plan stays pending, with no conflict recorded; the case.
: COPY-FAILED ( MODEL:remote n ^ARENA:arena -- ^file-case )
   {: rem code:n ar :}
   PLAN-KIND-REPLACING ar NEW-CASE {: c :}
   rem THEIRS-AS CHANGED-AS {: o :}
   c FILE-CASE-DIR @
   [: [: o c ar CASE-APPLIED$ drop ;] code TTHROWSQ ;] ar LOGGED
   drop
   c FILE-CASE-JOURNAL @ ar NOTES$ s" pending" T$=
   c FILE-CASE-JOURNAL @ ar JOURNAL:CONFLICTS VEC:COUNT 0 T=
   c ;

: AN-UNREACHED-REMOTE-SIDE-ENDS-THE-PASS ( ^ARENA:arena -- )
   {: ar :}
   s" a 503 download of the remote side ends the pass" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   s" /2/files/download" 503 s" " s" " s" " TEST-DROPBOX:ROUTE-SCRIPT!
   rem REPLAY:E-DROPBOX ar COPY-FAILED {: c :}
   LINK REPLAY-LINK:REPLY @ TEST-CLIENT:RETRY? TTRUE
   c true false ar COPIES
   1 SEEN
   c ENDED ;

\ The copy's download on a fresh client, whose token refresh Dropbox
\ answers 400, ends the pass.
: A-REFUSED-REFRESH-ENDS-THE-PASS ( ^ARENA:arena -- )
   {: ar :}
   s" a refresh refused 400 for the remote side ends the pass" T-LABEL
   ar THEIRS-SERVED {: h rem :}
   s" /oauth2/token" 400 s" " s" "
   S\" {\qerror\q:\qinvalid_request\q}" TEST-DROPBOX:ROUTE-SCRIPT!
   [: KEEP-NONE ;] s" replay-refresh" s" " ar TEST-CLIENT:CLIENT-ON {: k :}
   k LINKED
   [: rem DROPBOX:E-BAD-REQUEST ar COPY-FAILED ENDED ;]
   [: k DROPBOX:CLOSE TEST-CLIENT:MAIN @ LINKED ;] finally ;

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
   [: j LINK f r s ar REPLAY:REPLAY-REMOTE-OPERATIONS-AT ;]
   [: f FS:CLOSE-DIR ;] finally ;

\ The next API call is refused 409 with Rust's lookup_error of the tag.
: LOOKUP-ERROR ( str -- ) s" path" swap REFUSAL ;

: NO-BASELINE? ( option<MODEL:baseline> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: BASELINE-FILE ( option<MODEL:baseline> -- MODEL:remote )
   MATCH option
      none OF s" no baseline" TEST-CLIENT:FAILED ENDOF
      some OF
         MATCH MODEL:baseline
            absent OF s" an absent baseline" TEST-CLIENT:FAILED ENDOF
            present OF ENDOF
            directory OF s" a directory baseline" TEST-CLIENT:FAILED ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ The fake holds a folder at p.
: FOLDER-AT ( str -- )
   TEST-CLIENT:MAIN @ DROPBOX:METADATA DROPBOX:DONE? TTRUE
   TEST-CLIENT:MAIN @ DROPBOX:ENTRY DROPBOX-ENTRY:KIND @ DROPBOX-KIND:FOLDER
   DROPBOX-KIND:EQ TTRUE ;

: REMOTE-REPLAY-CREATES-NESTED-PARENTS-BEFORE-THE-FILE
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_replay_creates_nested_parents_before_the_file" T-LABEL
   TEST-DROPBOX:RESET
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   r s" one" ar TEST-CLIENT:INSIDE {: one:str :} one FS:MAKE-DIR
   one s" two" ar TEST-CLIENT:INSIDE {: two:str :} two FS:MAKE-DIR
   two s" file.txt" ar TEST-CLIENT:INSIDE s" nested bytes" FS:WRITE-ALL
   s" nested bytes" ar HASH-OF {: c:DROPBOX:hash :}
   j s" one/two/file.txt" c MODEL-OPERATION:CREATE-REMOTE ar PLANNED
   drop
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 1 T=
   rep BLOCKS VEC:COUNT 0 T=
   j s" one/two/file.txt" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE BASELINE-FILE
   MODEL-REMOTE:UNMAKE {: h v :}
   h DROPBOX:HASH>STR c DROPBOX:HASH>STR T$=
   v DROPBOX:REV>STR s" 01701" T$=
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
   j s" gone" TEST-CLIENT:DISPLAY MODEL-BASELINE:DIRECTORY ar JOURNAL:RECORD-NOOP
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
   j s" gone" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE NO-BASELINE? TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder" T$=
   j JOURNAL:CLOSE
   d GONE ;

: FRESH-AT? ( REPLAY:replay-blocked str -- bool )
   {: b a:str :}
   b MATCH REPLAY:replay-blocked
      fresh-observation-required OF MODEL:PATH>STR a STR:= ENDOF
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

: PENDING-AT? ( REPLAY:replay-blocked str -- bool )
   {: b a:str :}
   b MATCH REPLAY:replay-blocked
      remote-pending OF MODEL:PATH>STR a STR:= ENDOF
      durable-plan OF drop drop false ENDOF
      local-object OF drop false ENDOF
      fresh-observation-required OF drop false ENDOF
      download-required OF drop drop false ENDOF
      stage-destination-occupied OF drop drop false ENDOF
      precondition-changed OF drop drop false ENDOF
      remote-operation OF drop false ENDOF
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
   s" file where a folder was" {: b:str :}
   b ar HASH-OF {: c:DROPBOX:hash :}
   s" /gone" s" /gone" s" rev-file" c DROPBOX:HASH>STR b str> nip
   TEST-DROPBOX:FILE!
   ar GONE-PLAN {: d:str r:str s:str j :}
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep BLOCKS 0 VEC:AT @ s" gone" FRESH-AT? TTRUE
   j s" gone" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/get_metadata" T$=
   j JOURNAL:CLOSE
   d GONE ;

\ The delete of old's rev-old at delete.txt completes with no download
\ and no recovery, clearing the retry's error the status held; the
\ recovery directory stays empty.
: DELETE-REPLAYED ( str str str str JOURNAL:journal ^ARENA:arena -- )
   {: d:str r:str s:str rec:str j ar :}
   s" old remote bytes" {: b:str :}
   b ar HASH-OF {: old:DROPBOX:hash :}
   s" /delete.txt" s" /Delete.txt" s" old-rev" old DROPBOX:HASH>STR
   b str> nip TEST-DROPBOX:FILE!
   j s" delete.txt" s" old-rev" AS-REV MODEL-OPERATION:DELETE-REMOTE ar
   PLANNED drop
   s" Dropbox could not be reached."
   LINK REPLAY-LINK:STATUS @ STATUS:ERROR
   j r s ar REMOTE-REPLAYED COMPLETED 1 T=
   RUNTIME @ ar S\" \qlast_error\q:null" SHOWS
   \ An empty directory removes: nothing was put in it.
   rec FS:REMOVE-DIR
   j ar JOURNAL:PENDING-RECOVERIES VEC:COUNT 0 T=
   j ar JOURNAL:COMPLETED-RECOVERIES VEC:COUNT 0 T=
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2" T$= ;

\ create.txt's upload of "desired bytes", lost before it took effect, is
\ read back absent: the plan stays pending and the pass goes on.
: CREATE-PENDING ( str str JOURNAL:journal ^ARENA:arena -- )
   {: r:str s:str j ar :}
   r s" create.txt" ar TEST-CLIENT:INSIDE s" desired bytes" FS:WRITE-ALL
   s" desired bytes" ar HASH-OF {: want:DROPBOX:hash :}
   j s" create.txt" want MODEL-OPERATION:CREATE-REMOTE ar PLANNED drop
   TEST-DROPBOX:RESET TEST-DROPBOX:CUT
   j r s ar REMOTE-REPLAYED BLOCKS {: v :}
   TEST-DROPBOX:SEEN$ s" /2/files/upload /2/files/get_metadata" T$=
   v VEC:COUNT 1 T=
   v VEC:COUNT 1 <> if exit then
   v 0 VEC:AT @ s" create.txt" PENDING-AT? TTRUE ;

: REMOTE-DELETE-SKIPS-BACKUP-DOWNLOAD-AND-AMBIGUOUS-CREATE-STAYS-PENDING
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_delete_skips_backup_download_and_ambiguous_create_stays_pending"
   T-LABEL
   TEST-DROPBOX:RESET
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   d s" recovery" ar TEST-CLIENT:INSIDE {: rec:str :} rec FS:MAKE-DIR
   d r s rec j ar DELETE-REPLAYED
   r s j ar CREATE-PENDING
   j JOURNAL:CLOSE
   d s" journal.sqlite3" ar TEST-CLIENT:INSIDE JOURNAL:OPEN {: again :}
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
   j s" replace.txt" TEST-CLIENT:DISPLAY old MODEL-BASELINE:PRESENT ar
   JOURNAL:RECORD-NOOP NOOP-RECORDED? TTRUE
   r s" replace.txt" ar TEST-CLIENT:INSIDE s" new local bytes" FS:WRITE-ALL
   j s" replace.txt" s" new local bytes" ar HASH-OF s" old-rev" AS-REV
   MODEL-OPERATION:REPLACE-REMOTE ar PLANNED drop ;

\ Dropbox's replace.txt, shown as v: "new remote bytes" at current-rev.
: CURRENT-AT ( str ^ARENA:arena -- MODEL:remote )
   {: v:str ar :}
   s" new remote bytes" {: b:str :}
   b ar HASH-OF {: c:DROPBOX:hash :}
   s" /replace.txt" v s" current-rev" c DROPBOX:HASH>STR b str> nip
   TEST-DROPBOX:FILE!
   c s" current-rev" REMOTE-OF ;

\ replace.txt's local conflict copy, relative to the root.
: LOCAL-SIDE ( ^ARENA:arena -- str )
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
   p MODEL:PATH>STR s" replace.txt" T$=
   y x MODEL:CONFLICT= TTRUE ;

variable SIDES

: SIDE? ( str -- )
   s" .omabox-conflict-" STR:STARTS-WITH? if 1 SIDES +! then ;

\ Rust's conflict_bytes: how many conflict copies the root r holds.
: SIDES-IN ( str -- n )
   {: r:str :}
   0 SIDES !
   r TEXT CAP FS-LIST:NAMES {: k:n :}
   TEXT k >str begin dup str> nip 0 > while NEXT-NAME SIDE? repeat
   drop SIDES @ ;

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
   j s" replace.txt" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE BASELINE-FILE
   MODEL-REMOTE:UNMAKE {: h v :}
   h DROPBOX:HASH>STR
   s" common bytes" ar HASH-OF DROPBOX:HASH>STR T$=
   v DROPBOX:REV>STR s" old-rev" T$=
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
   s" /2/files/upload /2/files/get_metadata /2/files/download"
   T$=
   TEST-DROPBOX:ARG-SENT$ S\" {\qpath\q:\qrev:current-rev\q}" T$=
   j JOURNAL:CLOSE
   d GONE ;

\ Whether b is the durable plan at p, held with the blockage t.
: HELD-AT? ( REPLAY:replay-blocked str str -- bool )
   {: b p:str t:str :}
   b MATCH REPLAY:replay-blocked
      durable-plan OF {: at why :}
         at MODEL:PATH>STR p STR:= why BLOCKAGE$ t STR:= and
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
   LINK REPLAY-LINK:REPLY @ TEST-CLIENT:RETRY? TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 1 T=
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0 T=
   s" restricted_content" LOOKUP-ERROR
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep BLOCKS 0 VEC:AT @ s" gone" s" rejected_by_dropbox" HELD-AT?
   TTRUE
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 1 T=
   j s" gone" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/list_folder /2/files/list_folder" T$=
   j JOURNAL:CLOSE
   d GONE ;

\ The pass below the root r throws LOCAL's E-IO, its errno EACCES,
\ read before the root's close clears it; its one line gives r's mode
\ and owner and the uid Omabox runs as.
: COPY-DENIED ( JOURNAL:journal str str ^ARENA:arena -- )
   {: j r:str s:str ar :}
   r OPEN-ROOT {: f:fd :}
   [: [: j LINK f r s ar REPLAY:REPLAY-REMOTE-OPERATIONS-AT
         drop ;] LOCAL:E-IO TTHROWSQ
      FS:ERRNO FS:EACCES T= ;]
   [: f FS:CLOSE-DIR ;] finally ;

: READ-ONLY-CLAUSE$ ( str -- str )
   {: r:str :}
   SB-RESET s" ; directory `" SB-APPEND r SB-APPEND
   s" ` mode 0500 owner uid " SB-APPEND FS:EUID FMT:SB-INT SB$ ;

: RUNS-AS$ ( -- str )
   SB-RESET s" ; Omabox runs as uid " SB-APPEND FS:EUID FMT:SB-INT SB$ ;

: REPLAY-DOES-NOT-BLOCK-A-CONFLICT-WHOSE-COPY-PARENT-IS-READ-ONLY
   ( ^ARENA:arena -- )
   {: ar :}
   s" replay_does_not_block_a_conflict_whose_copy_parent_is_read_only"
   T-LABEL
   TEST-DROPBOX:RESET
   s" /replace.txt" ar CURRENT-AT {: cur :}
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   j r ar REPLACE-PLAN
   r MODE-NO-WRITE FS:CHMOD-MODE
   [: d [: j r s ar COPY-DENIED ;] ar LOGGED ;]
   [: r FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;] finally {: t:str :}
   t LINE-COUNT 1 T=
   t s" Permission denied" STR:CONTAINS? TTRUE
   t r READ-ONLY-CLAUSE$ STR:CONTAINS? TTRUE
   t RUNS-AS$ STR:CONTAINS? TTRUE
   j ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0 T=
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 1 T=
   r ar LOCAL-SIDE ar TEST-CLIENT:INSIDE FS:TRY-STAT TFALSE
   r s" replace.txt" s" new local bytes" ar HOLDS
   s" /2/files/upload /2/files/get_metadata" {: w:str :}
   w str> nip {: wu:n :}
   TEST-DROPBOX:SEEN$ str> wu min >str w T$=
   j JOURNAL:CLOSE
   d GONE ;

\ The journal's one blocked plan is at a, its two operations pending.
: HELD-AT-A ( JOURNAL:journal ^ARENA:arena -- )
   JOURNAL:BLOCKED-PLANS {: v :}
   v VEC:COUNT 1 <> if exit then
   v 0 VEC:AT @ JOURNAL-PLAN--RECORD:UNMAKE {: id p o st :}
   p MODEL:PATH>STR s" a" T$=
   o 0 OP-STATUS 0 T= o 1 OP-STATUS 0 T= ;

\ Plan A at a: delete rev-old, then make the folder a; plan B makes
\ the folder b. Dropbox refuses A's delete for its path alone.
: A-BLOCKED-PLAN-LEAVES-THE-NEXT-TO-RUN ( ^ARENA:arena -- )
   {: ar :}
   s" a blocked plan sends no more and leaves the next to run" T-LABEL
   TEST-DROPBOX:RESET
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   ar OPS {: ops :}
   OLD-REV MODEL-OPERATION:DELETE-REMOTE ops OP+ MAKE-F ops OP+
   j s" a" ops ar RECORD-OPS
   j s" b" MAKE-F ar PLANNED drop
   s" path_lookup" s" restricted_content" REFUSAL
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 1 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep BLOCKS 0 VEC:AT @ s" a" s" rejected_by_dropbox" HELD-AT? TTRUE
   j s" rejected_by_dropbox" ar HELD-AS drop
   j ar HELD-AT-A
   j ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   j s" b" TEST-CLIENT:DISPLAY ar JOURNAL:BASELINE DIRECTORY? TTRUE
   TEST-DROPBOX:SEEN$ s" /2/files/delete_v2 /2/files/create_folder_v2"
   T$=
   j JOURNAL:CLOSE
   d GONE ;

\ A directory at the stage of replace.txt's upload.
: A-HELD-STAGE-HOLDS-ITS-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" a held upload stage holds its plan, in the report" T-LABEL
   TEST-DROPBOX:RESET
   ar UPLOAD-DIRS {: d:str r:str s:str j :}
   j r ar REPLACE-PLAN
   s" new local bytes" ar HASH-OF DROPBOX:HASH>STR {: h:str :}
   s h ar TEST-CLIENT:INSIDE FS:MAKE-DIR
   j r s ar REMOTE-REPLAYED {: rep :}
   rep COMPLETED 0 T=
   rep BLOCKS VEC:COUNT 1 T=
   rep BLOCKS 0 VEC:AT @ s" replace.txt" s" stage-occupied" HELD-AT?
   TTRUE
   j s" stage-occupied" ar HELD-AS drop
   TEST-DROPBOX:SEEN$ s" " T$=
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
   ar REPLAY-DOES-NOT-BLOCK-A-CONFLICT-WHOSE-COPY-PARENT-IS-READ-ONLY
   ar A-BLOCKED-PLAN-LEAVES-THE-NEXT-TO-RUN
   ar A-HELD-STAGE-HOLDS-ITS-PLAN ;


: BRIDGE-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar EXACT-DOWNLOAD-RETRY-REUSES-A-STAGE-WITHOUT-CONSUMING-THE-BODY
   ar EXACT-DOWNLOAD-STAGE-RACE-PRESERVES-VERIFIED-STAGE
   ar CORRUPT-EXACT-DOWNLOAD-NEVER-LEAVES-INSTALLABLE-BYTES
   ar A-DOWNLOAD-LOST-MID-BODY-KEEPS-ITS-PARTIAL
   ar A-COMPLETE-416-FINISHES-THE-STAGE
   ar UNSATISFIABLE-RESUME-RESTARTS-ONLY-THE-OWNED-PARTIAL
   ar INTERRUPTED-EXACT-DOWNLOAD-RESUMES-ONLY-FROM-A-VALID-RANGE
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
   ar A-REFUSED-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN
   ar A-REJECTED-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN
   ar A-MISSING-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN
   ar AN-UNVERIFIED-REMOTE-SIDE-HOLDS-ONLY-ITS-PLAN
   ar AN-UNREACHED-REMOTE-SIDE-ENDS-THE-PASS
   ar A-REFUSED-REFRESH-ENDS-THE-PASS
   ar APPLY-DELETE-MUTATION-COVERS-EVERY-OUTCOME
   ar A-DELETE-BEFORE-A-FOLDER-LEAVES-ITS-PLAN-PENDING ;

\ The link: the main client, its token fetched, and a status in a
\ runtime directory of its own.
: LINKING ( ^ARENA:arena -- )
   {: ar :}
   [: KEEP-NONE ;] s" replay-refresh" s" " ar TEST-CLIENT:CLIENT-ON TEST-CLIENT:MAIN !
   TEST-CLIENT:MAIN @ LINKED
   s" " LINK REPLAY-LINK:ROOT !
   s" replay-status" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED RUNTIME !
   RUNTIME @ ar STATUS:NEW LINK REPLAY-LINK:STATUS !
   TEST-CLIENT:MAIN @ DROPBOX:ACCOUNT DROPBOX:DONE? TTRUE ;

: BRIDGE-SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" replay-refresh" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   TEST-CLIENT:FILL-XS
   ar LINKING
   [: ar BRIDGE-CASES ar LOOP-CASES ;]
   [: TEST-CLIENT:MAIN @ DROPBOX:CLOSE RUNTIME @ GONE ;] finally ;


\ The mutation, bridge and remote replay cases against one fake Dropbox,
\ under AIO's loop.
: DROPBOX-CASES ( ^ARENA:arena -- )
   {: ar :}
   AIO:START
   [: TEST-DROPBOX:START
      [: ar SERVED ar BRIDGE-SERVED ;] [: TEST-DROPBOX:STOP ;] finally ;]
   [: AIO:STOP ;] finally ;

\ ---- the tables against their models

: FORMAL-HOLDS-THE-LOCAL-TABLE ( ^ARENA:arena -- )
   {: ar :}
   s" formal holds the local table" T-LABEL
   s" src/replay.f" s" LOCAL-LIFECYCLE" s" LocalLifecycle" ar
   TEST-FORMAL:HOLDS ;

: FORMAL-HOLDS-THE-REMOTE-TABLE ( ^ARENA:arena -- )
   {: ar :}
   s" formal holds the remote table" T-LABEL
   s" src/replay.f" s" REMOTE-LIFECYCLE" s" RemoteLifecycle" ar
   TEST-FORMAL:HOLDS ;


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
   ar DOWNLOAD-FAILURES-SEPARATE-PATH-BLOCKS-FROM-GLOBAL-ERRORS
   UPLOAD-SIZE-STOPS-AT-THE-SESSION-LIMIT
   ar REMOTE-REPLAY-CASES
   ar DROPBOX-CASES
   ar FORMAL-HOLDS-THE-LOCAL-TABLE
   ar FORMAL-HOLDS-THE-REMOTE-TABLE ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" replay-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
