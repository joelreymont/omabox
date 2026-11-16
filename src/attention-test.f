\ attention-test.f - ATTENTION against the Rust version's status.rs tests
\ of the same names:
\ - status_snapshot_is_sorted_and_omits_internal_values
\ - status_never_initializes_or_migrates_a_journal
\ - status_diagnostics_redact_the_absolute_journal_path, over the lines
\   JOURNAL and ATTENTION log, which name `[Omabox journal]`
\ and one of its own:
\ - A-JOURNAL-BELOW-A-FILE-IS-UNINSPECTABLE: ENOTDIR from stat is
\   E-INSPECT, its two lines logged, ENOTDIR left in FS:ERRNO.
\ Each case runs in a directory of its own under TMPDIR and removes it;
\ a refusal's log lines are captured there, checked and removed.
\ Run from the repository root: hb --load src/attention-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/sqlite.f
require src/lib/vector.f
require src/lib/adt/option.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f
require src/attention.f

package ATTENTION-TEST
private

TYPED-VARIABLE SUBJECT str
TYPED-VARIABLE SUBJECT-ARENA ^ARENA:arena
variable CAUSE      \ FS:ERRNO as RENDER left it


\ ---- a case's directory --------------------------------------------

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u:n ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

\ dir/name.
: INSIDE ( str ^u8 n ^ARENA:arena -- str )
   {: d:str a:^ u:n ar :}
   d str> {: p:^ pu:n :}
   ar pu u + 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst pu BYTE-COPY
   47 dst pu + c!
   a dst pu + 1+ u BYTE-COPY
   dst pu u + 1+ >str ;

: SCRATCH ( ^ARENA:arena -- str )
   {: ar :}
   s" attention-test" FS:MKTEMP-DIR ar COPIED ;

: GONE ( str -- ) str> FS:REMOVE-TREE ;

: CONTAINS? ( ^u8 n ^u8 n -- bool )
   {: a:^ u:n t:^ tu:n :}
   tu u > if false exit then
   u tu - 1+ 0 ?do
      a i + tu t tu STR= if true unloop exit then
   loop false ;

: RENDERED ( str ^ARENA:arena -- ^u8 n ) ATTENTION:RENDER str> ;

: RENDER-SUBJECT ( -- ) SUBJECT @ SUBJECT-ARENA @ RENDERED 2drop ;

\ RENDER of path throws want, logging the text in dir/stderr.txt, which
\ is removed; FS:ERRNO as RENDER left it.
: REFUSED ( str n str ^ARENA:arena -- ^u8 n n )
   {: path:str want:n dir:str ar :}
   path SUBJECT !  ar SUBJECT-ARENA !
   dir s" stderr.txt" ar INSIDE {: f:str :}
   [: [: RENDER-SUBJECT ;] [: FS:ERRNO CAUSE ! ;] finally ;] f str> ar
   STDERR:CAPTURING {: code:n e:^ u:n :}
   code want T=
   e u CAUSE @ ;

\ The line ends in the text.
: LINE-ENDS? ( ^u8 n ^u8 n -- bool )
   {: line:^ lu:n t:^ tu:n :}
   tu lu > if false exit then
   line lu tu - + tu t tu STR= ;

\ The first line of the log, without its newline, and the rest.
: FIRST-LINE ( ^u8 n -- ^u8 n ^u8 n )
   {: e:^ u:n :}
   u 0 ?do
      e i + c@ 10 = if e i e i + 1+ u i - 1- unloop exit then
   loop e u e u + 0 ;

: NOT-SET-UP$ ( -- ^u8 n )
   s\" Omabox is not set up; run `omabox setup [REMOTE_ROOT]`.\n" ;

: HELP$ ( -- ^u8 n )
   s" attention: help: Check access to the Omabox state directory, then retry `omabox status`." ;


\ ---- fixtures ------------------------------------------------------

: PATH ( ^u8 n -- MODEL:path ) >str MODEL:>PATH ;
: HASH ( ^u8 n -- DROPBOX:hash ) >str DROPBOX:>HASH ;
: REV ( ^u8 n -- DROPBOX:rev ) >str DROPBOX:>REV ;

: REMOTE ( ^u8 n ^u8 n -- MODEL:remote )
   {: c:^ cu:n r:^ ru:n :}
   c cu HASH r ru REV MODEL-REMOTE:MAKE ;

: LOCAL-UNKNOWN
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:UNKNOWN ;

: REMOTE-UNKNOWN
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:UNKNOWN ;

: BOUND? ( JOURNAL:dropbox-binding-write -- bool )
   MATCH JOURNAL:dropbox-binding-write
      bound OF true ENDOF
      already-bound OF false ENDOF
      mismatch OF drop false ENDOF
   ;MATCH ;

: BIND ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   s" account-id-must-not-render" >str
   s" namespace-id-must-not-render" >str
   s" /remote-root-must-not-render" >str
   JOURNAL-DROPBOX--BINDING:MAKE {: b :}
   j b ar JOURNAL:BIND-DROPBOX-ROOT BOUND? TTRUE ;

: ACTIVATED ( JOURNAL:local-root-activation -- ) drop ;

: ROOT ( -- JOURNAL:local-root-binding )
   s" /sync" >str 2 1700000000 5 JOURNAL-BIRTH--TIME:MAKE OPTION:SOME
   256 OPTION:SOME JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

\ The local inventory: each path unknown as inaccessible.
: LOCALS ( ^VEC:vector<MODEL:path> JOURNAL:journal ^ARENA:arena -- )
   {: paths j ar :}
   ROOT {: root :}
   j root ar JOURNAL:ACTIVATE-LOCAL-ROOT ACTIVATED
   ar ARENA:ALLOCATOR 0 [type] MODEL:local-record VEC:NEW {: v :}
   paths VEC:COUNT 0 ?do
      paths i VEC:AT @ MODEL-UNKNOWN--REASON:INACCESSIBLE LOCAL-UNKNOWN
      MODEL-LOCAL--RECORD:MAKE v VEC:PUSH !
   loop
   ar ARENA:ALLOCATOR 0 [type] MODEL:hash-record VEC:NEW {: none :}
   j root v none JOURNAL:PUBLISH-LOCAL-SCAN TTRUE ;

: PATHS ( ^ARENA:arena -- ^VEC:vector<MODEL:path> )
   ARENA:ALLOCATOR 0 [type] MODEL:path VEC:NEW ;

: STALE-REMOTE ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   s" a-remote.txt" PATH {: p :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: v :}
   p ar MODEL:FOLD p MODEL-UNKNOWN--REASON:STALE REMOTE-UNKNOWN
   MODEL-REMOTE--RECORD:MAKE v VEC:PUSH !
   j s" cursor-must-not-render" >str DROPBOX:>CURSOR v
   JOURNAL:PUBLISH-REMOTE-INVENTORY ;

: RECORDED ( JOURNAL:plan-write -- JOURNAL:plan-record )
   MATCH JOURNAL:plan-write
      recorded OF ENDOF
      already-live OF ENDOF
   ;MATCH ;

: FRESH? ( JOURNAL:plan-write -- bool )
   MATCH JOURNAL:plan-write
      recorded OF drop true ENDOF
      already-live OF drop false ENDOF
   ;MATCH ;

: PLAN ( JOURNAL:journal ^u8 n ^VEC:vector<MODEL:operation>
     ^ARENA:arena -- JOURNAL:plan-record )
   {: j a:^ u:n ops ar :}
   j a u PATH ops JOURNAL-OPERATION--PLAN:MAKE ar JOURNAL:RECORD-PLAN
   {: w :}
   w FRESH? TTRUE
   w RECORDED ;

: OPERATIONS ( ^ARENA:arena -- ^VEC:vector<MODEL:operation> )
   ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW ;

: INTENT? ( JOURNAL:recovery-write -- bool )
   MATCH JOURNAL:recovery-write
      recorded OF drop true ENDOF
      already-recorded OF drop false ENDOF
      operation-not-found OF false ENDOF
      operation-completed OF false ENDOF
      operation-not-destructive OF false ENDOF
   ;MATCH ;

\ m-pending.txt: preserve then delete, its recovery intent recorded at
\ an absolute path.
: PENDING-WITH-RECOVERY ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   s" content-id-must-not-render" HASH {: displaced :}
   ar OPERATIONS {: ops :}
   displaced MODEL-LOCAL:MAKE MODEL-OPERATION:PRESERVE-LOCAL
   ops VEC:PUSH !
   displaced MODEL-OPERATION:DELETE-LOCAL ops VEC:PUSH !
   j s" m-pending.txt" ops ar PLAN JOURNAL-PLAN--RECORD:UNMAKE
   {: id p planned s :}
   planned 1 VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE {: oid at o st :}
   j oid s" /private/absolute-state-sentinel" PATH ar
   JOURNAL:RECORD-RECOVERY-INTENT INTENT? TTRUE ;

: BLOCKED? ( JOURNAL:plan-block -- bool )
   MATCH JOURNAL:plan-block
      not-found OF false ENDOF
      already-completed OF false ENDOF
      blocked OF true ENDOF
   ;MATCH ;

\ n-blocked.txt's download, blocked by HTTP 409.
: BLOCKED-DOWNLOAD ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   ar OPERATIONS {: ops :}
   s" blocked-content-must-not-render"
   s" blocked-revision-must-not-render" REMOTE
   MODEL-OPERATION:INSTALL-LOCAL ops VEC:PUSH !
   j s" n-blocked.txt" ops ar PLAN JOURNAL-PLAN--RECORD:UNMAKE
   {: id p planned s :}
   j id 409 MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE 1700000000 ar
   JOURNAL:BLOCK-PLAN BLOCKED? TTRUE ;

: CONFLICTS ( JOURNAL:journal ^ARENA:arena -- )
   {: j ar :}
   j s" b-diverged.txt" PATH
   s" local-secret-sentinel" HASH MODEL-LOCAL:MAKE
   MODEL-CONFLICT:REMOTE-DELETED ar JOURNAL:RECORD-CONFLICT drop
   j s" c-diverged.txt" PATH
   s" remote-secret-sentinel" s" revision-must-not-render" REMOTE
   MODEL-CONFLICT:LOCAL-DELETED ar JOURNAL:RECORD-CONFLICT drop ;


\ ---- status.rs's tests -------------------------------------------

: SNAPSHOT$ ( -- ^u8 n )
   s\" Omabox status:\n- a-remote.txt: Dropbox status unknown: inventory is stale\n- m-pending.txt: pending sync: 2 remaining; next: preserve displaced local payload\n- m-pending.txt: recovery copy is pending\n- n-blocked.txt: blocked sync: Dropbox download returned HTTP 409; retry is scheduled\n- z-local.txt: local status unknown: path is inaccessible\n" ;

\ Nothing the journal holds but paths and texts shows.
: OMITS ( ^u8 n -- )
   {: r:^ u:n :}
   r u s" absolute-state-sentinel" CONTAINS? TFALSE
   r u s" cursor-must-not-render" CONTAINS? TFALSE
   r u s" content-id-must-not-render" CONTAINS? TFALSE
   r u s" revision-must-not-render" CONTAINS? TFALSE
   r u s" blocked-content-must-not-render" CONTAINS? TFALSE
   r u s" blocked-revision-must-not-render" CONTAINS? TFALSE
   r u s" local-secret-sentinel" CONTAINS? TFALSE
   r u s" remote-secret-sentinel" CONTAINS? TFALSE
   r u s" account-id-must-not-render" CONTAINS? TFALSE
   r u s" namespace-id-must-not-render" CONTAINS? TFALSE
   r u s" remote-root-must-not-render" CONTAINS? TFALSE
   r u s" b-diverged.txt" CONTAINS? TFALSE
   r u s" c-diverged.txt" CONTAINS? TFALSE ;

: STATUS-SNAPSHOT-IS-SORTED-AND-OMITS-INTERNAL-VALUES ( ^ARENA:arena -- )
   {: ar :}
   s" status_snapshot_is_sorted_and_omits_internal_values" T-LABEL
   ar SCRATCH {: d:str :}
   d s" journal.sqlite3" ar INSIDE {: p:str :}
   p JOURNAL:OPEN {: j :}
   j ar BIND
   ar PATHS {: locals :}
   s" z-local.txt" PATH locals VEC:PUSH !
   locals j ar LOCALS
   j ar STALE-REMOTE
   j ar PENDING-WITH-RECOVERY
   j ar BLOCKED-DOWNLOAD
   j ar CONFLICTS
   j JOURNAL:CLOSE
   p ar RENDERED {: r:^ u:n :}
   r u SNAPSHOT$ T$=
   r u OMITS
   d GONE ;

\ The bytes of the file at path.
: SIZE ( str -- n ) str> FS:FILE-SIZE ;

: USER-VERSION ( str -- n )
   str> SQLITE:OPEN-READ {: c :}
   c s" PRAGMA user_version"
   [: SQLITE:STEP drop 0 SQLITE:COL-INT swap ;] SQLITE:WITH-STATEMENT
   c SQLITE:CLOSE ;

: STATUS-NEVER-INITIALIZES-OR-MIGRATES-A-JOURNAL ( ^ARENA:arena -- )
   {: ar :}
   s" status_never_initializes_or_migrates_a_journal" T-LABEL
   ar SCRATCH {: d:str :}
   d s" absent.sqlite3" ar INSIDE {: absent:str :}
   absent ar RENDERED NOT-SET-UP$ T$=
   absent str> FS:EXISTS? TFALSE
   d s" empty.sqlite3" ar INSIDE {: empty:str :}
   empty str> s" " FS:WRITE-ALL
   empty ATTENTION:E-JOURNAL d ar REFUSED drop 2drop
   empty SIZE 0 T=
   d s" version-zero.sqlite3" ar INSIDE {: zero:str :}
   zero str> SQLITE:OPEN SQLITE:CLOSE
   zero ATTENTION:E-JOURNAL d ar REFUSED drop 2drop
   zero USER-VERSION 0 T=
   d s" unbound.sqlite3" ar INSIDE {: unbound:str :}
   unbound JOURNAL:OPEN JOURNAL:CLOSE
   unbound ar RENDERED NOT-SET-UP$ T$=
   d GONE ;

: STATUS-DIAGNOSTICS-REDACT-THE-ABSOLUTE-JOURNAL-PATH ( ^ARENA:arena -- )
   {: ar :}
   s" status_diagnostics_redact_the_absolute_journal_path" T-LABEL
   ar SCRATCH {: d:str :}
   d s" absolute-journal-path-sentinel" ar INSIDE {: p:str :}
   p str> SQLITE:OPEN SQLITE:CLOSE
   p ATTENTION:E-JOURNAL d ar REFUSED drop {: e:^ u:n :}
   e u s" absolute-journal-path-sentinel" CONTAINS? TFALSE
   e u FIRST-LINE 2swap
   s" journal: journal `[Omabox journal]` has unsupported schema version 0; supported version is 8"
   LINE-ENDS? TTRUE
   FIRST-LINE 2swap
   s" attention: could not open the journal read-only" LINE-ENDS? TTRUE
   FIRST-LINE {: rest:^ ru:n :}
   HELP$ LINE-ENDS? TTRUE
   ru 0 T=
   d GONE ;


\ ---- failures and order -------------------------------------------

: A-JOURNAL-BELOW-A-FILE-IS-UNINSPECTABLE ( ^ARENA:arena -- )
   {: ar :}
   s" A-JOURNAL-BELOW-A-FILE-IS-UNINSPECTABLE" T-LABEL
   ar SCRATCH {: d:str :}
   d s" file" ar INSIDE {: f:str :}
   f str> s" bytes" FS:WRITE-ALL
   f s" journal.sqlite3" ar INSIDE {: p:str :}
   p ATTENTION:E-INSPECT d ar REFUSED {: e:^ u:n cause:n :}
   cause FS:ENOTDIR T=
   e u FIRST-LINE 2swap
   s" attention: could not inspect Omabox setup state" LINE-ENDS? TTRUE
   FIRST-LINE {: rest:^ ru:n :}
   HELP$ LINE-ENDS? TTRUE
   ru 0 T=
   d GONE ;

: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar STATUS-SNAPSHOT-IS-SORTED-AND-OMITS-INTERNAL-VALUES
   ar STATUS-NEVER-INITIALIZES-OR-MIGRATES-A-JOURNAL
   ar STATUS-DIAGNOSTICS-REDACT-THE-ABSOLUTE-JOURNAL-PATH
   ar A-JOURNAL-BELOW-A-FILE-IS-UNINSPECTABLE ;

: TESTS ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" attention-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

TESTS

;package
