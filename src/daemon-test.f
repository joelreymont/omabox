\ daemon-test.f - DAEMON's words, each case's journal in a directory of
\ its own under TMPDIR, which it removes.
\ The failure policy, Rust's tests of the same names, each Rust error
\ stood for by the Habu code or Dropbox reply that carries it:
\ - retry_schedule_doubles_caps_and_honors_bounded_server_delays
\ - dispositions_cover_retry_environment_user_action_and_invariant,
\   the rate limit as the 900 s retry DROPBOX caps it to
\ - rejected_token_exits_without_rebuilding_the_download_pool, its
\   disposition, a pass's E-DROPBOX whose link keeps unlinked
\ - refresh_rejection_and_binding_rejection_exit_for_user_action, the
\   refresh's unlinked, and RECONCILE:E-INVALID-STATE for an unavailable
\   download slot coordinator
\ - local_and_nested_failures_keep_their_intended_policy
\ - local_root_failures_name_their_own_cause, a removed root inspected
\ Account validation, against the fake Dropbox of test-dropbox.f on
\ test-client.f's clients, each holding its first access token:
\ - Rust's link_rejects_unavailable_file_and_restricted_roots, each root
\   through VALIDATE's remote-root check.
\ - Rust's journal_binding_mismatch_blocks_inventory_before_listing.
\ - Rust's
\   account_validation_is_cached_per_client_but_every_journal_is_checked.
\ - Rust's failed_account_validation_is_retried_by_the_same_client.
\ The run, on statuses under TMPDIR, AUTH's credential in a directory
\ there that SECRET:DIR-BIND serves, and a recording wait:
\ - durable_binding_is_required_and_authoritative, through starting
\ - recovery_control_retries_under_a_held_lock_and_clears_only_after_a_clean_pass,
\   a directory at the journal's path failing opening twice
\ - recovery_control_publishes_stopped_before_a_fatal_exit
\ - repeated_long_poll_retries_retain_the_session_and_escalate_after_clean_sync_passes,
\   on a status that writes nothing, as Rust's has none
\ - root_inspection_failure_is_unavailable_only_for_a_stand_in
\ - stand_in_without_birth_time_leaves_the_root_unavailable, /sys/kernel
\ - syncing_backs_off_and_stops_on_a_refused_refresh, Rust having none:
\   DAEMON-RUN from a clean pass through a backed-off poll to the stop
\ Run from the repository root: hb --load src/daemon-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/sqlite.f
require src/dropbox.f
require src/journal.f
require src/local.f
require src/replay.f
require src/reconcile.f
require src/daemon.f
require src/status.f
require src/config.f
require src/lib/secret/dir.f
require src/lib/aio.f
require src/lib/net/curl.f
require src/test-dropbox.f
require src/test-client.f

\ DAEMON reopened for the private words the tests call.
package DAEMON
private

: CHECK$ ( account-check -- ^u8 n )
   MATCH account-check
      valid OF s" valid" ENDOF
      account-changed OF s" account-changed" ENDOF
      root-changed OF s" root-changed" ENDOF
      journal-binding-changed OF s" journal-binding-changed" ENDOF
      root-unavailable OF s" root-unavailable" ENDOF
      failed OF drop s" failed" ENDOF
   ;MATCH ;

\ Whether the check failed on a call Dropbox refused with e.
: REFUSED? ( account-check DROPBOX:error -- bool )
   {: e:DROPBOX:error :}
   MATCH account-check
      valid OF false ENDOF
      account-changed OF false ENDOF
      root-changed OF false ENDOF
      journal-binding-changed OF false ENDOF
      root-unavailable OF false ENDOF
      failed OF e TEST-CLIENT:REFUSAL? ENDOF
   ;MATCH ;

\ ---- failure policy ----------------------------------------------

TYPED-VARIABLE BACKOFF schedule
TYPED-VARIABLE LINK REPLAY:link

: TEXT= ( failure str -- )
   {: f t:str :}
   f FAILURE-UNMAKE {: d u:str :} u str> t str> T$= ;

: KIND= ( failure disposition -- )
   {: f want :}
   f FAILURE-UNMAKE {: d u:str :} d want DISPOSITION-EQ TTRUE ;

: WAITS ( n n -- ) BACKOFF ADVANCE swap T= ;

: RETRY-SCHEDULE-DOUBLES-CAPS-AND-HONORS-BOUNDED-SERVER-DELAYS
   ( -- )
   s" retry_schedule_doubles_caps_and_honors_bounded_server_delays"
   T-LABEL
   BACKOFF RESET
   5000 0 WAITS
   10000 0 WAITS
   8 0 do 0 BACKOFF ADVANCE drop loop
   RETRY-CEILING 0 WAITS
   MAX-RETRY-AFTER 86400000 WAITS
   BACKOFF RESET
   RETRY-BASE 0 WAITS ;

: DISPOSITIONS-COVER-RETRY-ENVIRONMENT-USER-ACTION-AND-INVARIANT
   ( -- )
   s" dispositions_cover_retry_environment_user_action_and_invariant"
   T-LABEL
   MAX-RETRY-AFTER DROPBOX-REPLY:RETRY REPLY-FAILURE
   MAX-RETRY-AFTER construct disposition retry KIND=
   SQLITE:E-FULL CODE-FAILURE
   construct disposition environmental KIND=
   SQLITE:E-CORRUPT CODE-FAILURE
   construct disposition user-action KIND=
   RECONCILE:E-INVALID-STATE CODE-FAILURE
   construct disposition invariant KIND=
   DROPBOX:E-UNUSABLE CODE-FAILURE {: f :}
   f construct disposition environmental KIND=
   f DROPBOX TEXT=
   SECRET:E-CONFIG CODE-FAILURE {: g :}
   g construct disposition environmental KIND=
   g CREDENTIALS TEXT=
   JOURNAL:E-DISK-FULL CODE-FAILURE {: j :}
   j construct disposition environmental KIND=
   j DISK-FULL TEXT=
   CONFIG:E-DISK-FULL CODE-FAILURE {: c :}
   c construct disposition environmental KIND=
   c DISK-FULL TEXT=
   CONFIG:E-MISSING CODE-FAILURE {: m :}
   m construct disposition user-action KIND=
   m SETUP TEXT= ;

: REJECTED-TOKEN-EXITS-WITHOUT-REBUILDING-THE-DOWNLOAD-POOL ( -- )
   s" rejected_token_exits_without_rebuilding_the_download_pool"
   T-LABEL
   DROPBOX-REPLY:UNLINKED LINK REPLAY-LINK:REPLY !
   REPLAY:E-DROPBOX LINK PASS-FAILURE
   construct disposition user-action KIND= ;

: REFRESH-REJECTION-AND-BINDING-REJECTION-EXIT-FOR-USER-ACTION
   ( -- )
   s" refresh_rejection_and_binding_rejection_exit_for_user_action"
   T-LABEL
   DROPBOX-REPLY:UNLINKED REPLY-FAILURE {: f :}
   f construct disposition user-action KIND=
   f FAILURE-UNMAKE {: d u:str :} d EXIT-CODE 78 T=
   construct account-check account-changed CHECK-FAILURE
   FAILURE-UNMAKE {: c v:str :} c EXIT-CODE 78 T=
   RECONCILE:E-INVALID-STATE CODE-FAILURE
   FAILURE-UNMAKE {: i w:str :} i EXIT-CODE 70 T= ;

: LOCAL-AND-NESTED-FAILURES-KEEP-THEIR-INTENDED-POLICY ( -- )
   s" local_and_nested_failures_keep_their_intended_policy" T-LABEL
   LOCAL:E-DISK-FULL CODE-FAILURE {: f :}
   f construct disposition environmental KIND=
   f DISK-FULL TEXT=
   LOCAL:E-UNSAFE-PATH CODE-FAILURE
   construct disposition invariant KIND= ;

: LOCAL-ROOT-FAILURES-NAME-THEIR-OWN-CAUSE ( ^ARENA:arena -- )
   {: ar :}
   s" local_root_failures_name_their_own_cause" T-LABEL
   s" daemon-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: d:str :}
   d s" Dropbox" ar TEST-CLIENT:INSIDE {: root:str :}
   root str> FS:MAKE-DIR
   d s" journal.sqlite3" ar TEST-CLIENT:INSIDE JOURNAL:OPEN {: j :}
   root str> FS:REMOVE-DIR
   d s" stderr.txt" ar TEST-CLIENT:INSIDE {: log:str :}
   [: root j ar JOURNAL:INSPECT-ROOT drop ;] log str> ar
   STDERR:CAPTURING 2drop {: code :}
   j JOURNAL:CLOSE
   code JOURNAL:E-ROOT T=
   code CODE-FAILURE {: f :}
   f construct disposition environmental KIND=
   f SYNC-ROOT TEXT=
   d str> FS:REMOVE-TREE ;

: POLICY-CASES ( ^ARENA:arena -- )
   {: ar :}
   RETRY-SCHEDULE-DOUBLES-CAPS-AND-HONORS-BOUNDED-SERVER-DELAYS
   DISPOSITIONS-COVER-RETRY-ENVIRONMENT-USER-ACTION-AND-INVARIANT
   REJECTED-TOKEN-EXITS-WITHOUT-REBUILDING-THE-DOWNLOAD-POOL
   REFRESH-REJECTION-AND-BINDING-REJECTION-EXIT-FOR-USER-ACTION
   LOCAL-AND-NESTED-FAILURES-KEEP-THEIR-INTENDED-POLICY
   ar LOCAL-ROOT-FAILURES-NAME-THEIR-OWN-CAUSE ;


\ ---- run ----

8 constant NAP-CAP
NAP-CAP TYPED-BUFFER NAPPED n
variable NAPS                   \ the waits a case's recording wait saw
1024 constant SEEN-CAP
SEEN-CAP BUFFER: SEEN-JSON
TYPED-VARIABLE HELD-PATHS ^CONFIG:paths
TYPED-VARIABLE HELD-JOURNAL str
TYPED-VARIABLE CREDENTIAL-DIR str
variable DROPPED

\ A wait that records its length and never sleeps.
: NAP ( n -- ) NAPS @ NAP-CAP 1- min NAPPED ! 1 NAPS +! ;

: NAPPED= ( n n -- )
   {: i want :}
   i NAPPED @ want T= ;

: AT-LOCKING ( -- daemon-state ) construct daemon-state locking ;
: AT-OPENING ( -- daemon-state ) construct daemon-state opening ;
: AT-NOTIFYING ( -- daemon-state ) construct daemon-state notifying ;
: AT-SYNCING ( -- daemon-state ) construct daemon-state syncing ;
: AT-POLLING ( -- daemon-state ) construct daemon-state polling ;
: AT-WAITING ( -- daemon-state ) construct daemon-state waiting ;

\ One step from s, which must reach want.
: STEP-TO ( daemon-state ^run daemon-state -- daemon-state )
   {: s x want :}
   x s DAEMON-RUN-STEP drop {: next :}
   next want DAEMON-STATE-EQ TTRUE
   next ;

: OK? ( step-event -- bool )
   MATCH step-event
      ok OF true ENDOF
      failed OF false ENDOF
   ;MATCH ;

\ A case's directory under TMPDIR.
: CASE-DIR ( ^ARENA:arena -- str )
   s" daemon-test" FS:MKTEMP-DIR rot TEST-CLIENT:COPIED ;

\ The status DIR/omabox/status.json holds the text t.
: STATUS-HAS ( str ^u8 n ^ARENA:arena -- )
   {: d t:^ tu ar :}
   d s" omabox/status.json" ar TEST-CLIENT:INSIDE
   str> SEEN-JSON SEEN-CAP FS:READ-ALL
   {: u :}
   SEEN-JSON u t tu CONTAINS? TTRUE ;

\ XDG under DIR/config and DIR/state, the sync root at root.
: CASE-CONFIG ( str CONFIG:abs-path ^ARENA:arena -- ^CONFIG:config )
   {: d root ar :}
   d s" config" ar TEST-CLIENT:INSIDE CONFIG:>ABS-PATH
   d s" state" ar TEST-CLIENT:INSIDE CONFIG:>ABS-PATH ar CONFIG:XDG-NEW
   root s" test-app-key" >str ar CONFIG:FROM-VALUES ;

\ The second wait releases the journal path a directory held.
: LOCK-NAP ( n -- )
   NAP
   [: HELD-PATHS @ CONFIG:LOCK CONFIG:UNLOCK ;]
   CONFIG:E-ALREADY-RUNNING TTHROWSQ
   NAPS @ 2 = if HELD-JOURNAL @ str> FS:REMOVE-DIR then ;

: WITH-CASE ( [ ^ARENA:arena -- ] -- )
   {: q :}
   ARENA:NEW {: car :}
   [: car q execute ;] [: car ARENA:RELEASE ;] finally ;

\ Steps under the lock from locking until opening succeeds.
: HELD-LOCK ( ^ARENA:arena str ^CONFIG:paths ^ARENA:arena -- )
   {: car d p ar :}
   d car STATUS:NEW {: s :}
   s [: LOCK-NAP ;] car NEW-RUN {: x :}
   p x RUN-PATHS !
   AT-LOCKING x AT-OPENING STEP-TO
   x AT-WAITING STEP-TO x AT-OPENING STEP-TO
   x AT-WAITING STEP-TO x AT-OPENING STEP-TO
   x AT-NOTIFYING STEP-TO drop
   NAPS @ 2 T= 0 5000 NAPPED= 1 10000 NAPPED=
   d S\" \qphase\q:\qerror\q" ar STATUS-HAS
   d JOURNAL str> ar STATUS-HAS
   STATUS-PHASE:SYNCING s STATUS:PHASE
   d JOURNAL str> ar STATUS-HAS
   x CLEANED
   d S\" \qlast_error\q:null" ar STATUS-HAS ;

: RECOVERY-CONTROL-RETRIES-UNDER-A-HELD-LOCK-AND-CLEARS-ONLY-AFTER-A-CLEAN-PASS
   ( ^ARENA:arena -- )
   {: ar :}
   s" recovery_control_retries_under_a_held_lock_and_clears_only_after_a_clean_pass"
   T-LABEL
   ar CASE-DIR {: d:str :}
   d s" config" ar TEST-CLIENT:INSIDE CONFIG:>ABS-PATH
   d s" state" ar TEST-CLIENT:INSIDE CONFIG:>ABS-PATH
   ar CONFIG:XDG-NEW {: xdg :}
   xdg ar CONFIG:RESOLVE-PRIVATE {: p :}
   d s" Dropbox" ar TEST-CLIENT:INSIDE {: root:str :}
   root str> FS:MAKE-DIR
   p root CONFIG:>ABS-PATH CONFIG:PREPARE-PATHS
   p CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR {: jp:str :}
   jp str> FS:MAKE-DIR
   p HELD-PATHS ! jp HELD-JOURNAL !
   0 NAPS !
   [: d p ar HELD-LOCK ;] WITH-CASE
   d str> FS:REMOVE-TREE ;

: STOPS-FOR-SETUP ( ^ARENA:arena str ^ARENA:arena -- )
   {: car d ar :}
   d car STATUS:NEW [: NAP ;] car NEW-RUN {: x :}
   0 SETUP USER-ACTION x FAILED
   x AT-WAITING DAEMON-RUN
   NAPS @ 0 T=
   d S\" \qphase\q:\qstopped\q" ar STATUS-HAS
   d SETUP str> ar STATUS-HAS
   x EXIT-STATUS 78 T= ;

: RECOVERY-CONTROL-PUBLISHES-STOPPED-BEFORE-A-FATAL-EXIT ( ^ARENA:arena -- )
   {: ar :}
   s" recovery_control_publishes_stopped_before_a_fatal_exit" T-LABEL
   ar CASE-DIR {: d:str :}
   0 NAPS !
   [: d ar STOPS-FOR-SETUP ;] WITH-CASE
   d str> FS:REMOVE-TREE ;

\ ---- the binding starting checks

: EXPECTED ( -- JOURNAL:dropbox-binding )
   s" dbid:account" >str s" namespace" >str s" /root" >str
   JOURNAL-DROPBOX--BINDING:MAKE ;

\ The credential store's record, for the binding b.
: CREDENTIAL! ( JOURNAL:dropbox-binding ^ARENA:arena -- )
   {: b ar :}
   b JOURNAL-DROPBOX--BINDING:UNMAKE {: a:str n:str r:str :}
   CREDENTIAL-DIR @ s" dropbox-credentials-v1" ar TEST-CLIENT:INSIDE
   {: p:str :}
   SB-RESET
   S\" {\qversion\q:1,\qrefresh_token\q:\qrefresh\q,\qaccount_id\q:\q"
   SB-APPEND a str> SB-APPEND
   S\" \q,\qroot_namespace_id\q:\q" SB-APPEND n str> SB-APPEND
   S\" \q,\qremote_root\q:\q" SB-APPEND r str> SB-APPEND
   S\" \q}" SB-APPEND
   p str> SB$ FS:WRITE-ALL ;

: STARTS ( JOURNAL:dropbox-binding ^run ^ARENA:arena -- bool )
   {: b x ar :}
   b ar CREDENTIAL!
   x START OK? ;

: RUN-IN-DIR ( str ^STATUS:status ^ARENA:arena -- ^run JOURNAL:journal )
   {: d s car :}
   s [: NAP ;] car NEW-RUN {: x :}
   d s" journal.sqlite3" car TEST-CLIENT:INSIDE x HOLD-JOURNAL
   x x JOURNAL@ ;

\ Rust's root_from_bindings: none, another, then the same binding.
: BINDINGS-CHECKED ( ^ARENA:arena str str -- )
   {: car d root:str :}
   d d car STATUS:NEW car RUN-IN-DIR {: x j :}
   d root CONFIG:>ABS-PATH car CASE-CONFIG x RUN-CONFIG !
   EXPECTED x car STARTS TFALSE
   x RUN-FAILURE @ construct disposition user-action KIND=
   x RUN-FAILURE @ SETUP TEXT=
   j EXPECTED car JOURNAL:BIND-DROPBOX-ROOT drop
   s" dbid:other" >str s" namespace" >str s" /root" >str
   JOURNAL-DROPBOX--BINDING:MAKE x car STARTS TFALSE
   x RUN-FAILURE @ construct disposition user-action KIND=
   x RUN-FAILURE @ BINDING TEXT=
   EXPECTED x car STARTS TTRUE
   x RUN-DROPBOX DROPBOX-CONFIG:ROOT @ SPAN:$ s" namespace" T$= ;

: DURABLE-BINDING-IS-REQUIRED-AND-AUTHORITATIVE ( ^ARENA:arena -- )
   {: ar :}
   s" durable_binding_is_required_and_authoritative" T-LABEL
   ar CASE-DIR {: d:str :}
   d s" Dropbox" ar TEST-CLIENT:INSIDE {: root:str :}
   root str> FS:MAKE-DIR
   [: d root BINDINGS-CHECKED ;] WITH-CASE
   d str> FS:REMOVE-TREE ;

\ ---- the session polling keeps

: NOTE-DROPPED ( ^u8 -- ) drop true DROPPED ! ;

: LONGPOLL-503 ( -- )
   s" /2/files/list_folder/longpoll" 503 s" " s" " s" "
   TEST-DROPBOX:ROUTE-SCRIPT! ;

: RETRIED-POLL ( ^run ^session -- )
   {: x s :}
   x CLEANED
   LONGPOLL-503
   AT-POLLING x AT-WAITING STEP-TO x AT-SYNCING STEP-TO drop
   DROPPED @ TFALSE
   x RUN-SESSION @ NULL-PTR - s NULL-PTR - T= ;

: RETAINED ( ^ARENA:arena str -- )
   {: car d :}
   d car STATUS:DETACHED car RUN-IN-DIR {: x j :}
   j s" cursor" >str DROPBOX:>CURSOR
   car ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW
   JOURNAL:PUBLISH-REMOTE-INVENTORY
   x RUN-SESSIONS @ {: sar :}
   sar TEST-CLIENT:OPENED EXPECTED sar OWNED-SESSION {: s :}
   sar 8 [: NOTE-DROPPED ;] ARENA:ALLOC-DISPOSE 2drop
   s x RUN-SESSION !
   TEST-DROPBOX:RESET
   x s RETRIED-POLL x s RETRIED-POLL
   NAPS @ 2 T= 0 5000 NAPPED= 1 10000 NAPPED=
   false 0 TEST-DROPBOX:POLL!
   AT-POLLING x AT-SYNCING STEP-TO drop
   x RUN-SCHEDULE SCHEDULE-NEXT @ RETRY-BASE T=
   DROPPED @ TFALSE ;

: REPEATED-LONG-POLL-RETRIES-RETAIN-THE-SESSION-AND-ESCALATE-AFTER-CLEAN-SYNC-PASSES
   ( ^ARENA:arena -- )
   {: ar :}
   s" repeated_long_poll_retries_retain_the_session_and_escalate_after_clean_sync_passes"
   T-LABEL
   ar CASE-DIR {: d:str :}
   0 NAPS ! false DROPPED !
   [: d RETAINED ;] WITH-CASE
   DROPPED @ TTRUE
   d str> FS:REMOVE-TREE ;

\ ---- the local root

public
EXPORT JOURNAL:STOOD-IN-BY?
private

: SYNC-ROOT-AT ( option<JOURNAL:birth-time> -- JOURNAL:local-root-record )
   {: birth :}
   s" /sync/root" >str 2 birth OPTION:NONE JOURNAL-LOCAL--ROOT--BINDING:MAKE
   1 JOURNAL-LOCAL--ROOT--RECORD:MAKE ;

: BORN ( -- option<JOURNAL:birth-time> )
   1700000000 5 JOURNAL-BIRTH--TIME:MAKE OPTION:SOME ;

: NO-BIRTH ( -- option<JOURNAL:birth-time> ) OPTION:NONE ;

: ROOT-INSPECTION-FAILURE-IS-UNAVAILABLE-ONLY-FOR-A-STAND-IN ( -- )
   s" root_inspection_failure_is_unavailable_only_for_a_stand_in" T-LABEL
   BORN SYNC-ROOT-AT s" /sync/root" >str 2 STOOD-IN-BY? TTRUE
   ROOT-UNAVAILABLE {: f :}
   f construct disposition environmental KIND=
   f SYNC-ROOT TEXT=
   NO-BIRTH SYNC-ROOT-AT s" /sync/root" >str 2 STOOD-IN-BY? TFALSE
   JOURNAL:E-NO-BIRTH-TIME CODE-FAILURE {: g :}
   g construct disposition user-action KIND=
   g ROOT-UNSUPPORTED TEXT= ;

: STAND-IN$ ( -- ^u8 n ) s" /sys/kernel" ;

: STOOD-IN ( ^ARENA:arena str -- )
   {: car d :}
   d d car STATUS:NEW car RUN-IN-DIR {: x j :}
   d STAND-IN$ >str CONFIG:>ABS-PATH car CASE-CONFIG x RUN-CONFIG !
   j STAND-IN$ >str 1 BORN OPTION:NONE JOURNAL-LOCAL--ROOT--BINDING:MAKE
   car JOURNAL:ACTIVATE-LOCAL-ROOT drop
   x [: ROOT-ACTIVE ;] TRIED TFALSE
   x RUN-FAILURE @ construct disposition environmental KIND=
   x RUN-FAILURE @ SYNC-ROOT TEXT=
   x RUN-CODE @ 0 T= ;

: STAND-IN-WITHOUT-BIRTH-TIME-LEAVES-THE-ROOT-UNAVAILABLE
   ( ^ARENA:arena -- )
   {: ar :}
   s" stand_in_without_birth_time_leaves_the_root_unavailable" T-LABEL
   [: STAND-IN$ >str JOURNAL:INSPECT drop ;] JOURNAL:E-NO-BIRTH-TIME
   TTHROWSQ
   ar CASE-DIR {: d:str :}
   [: d STOOD-IN ;] WITH-CASE
   d str> FS:REMOVE-TREE ;

\ ---- a cycle from syncing to a stop

3 constant BACKOFF-S            \ the backoff the long poll asks for
TYPED-VARIABLE CYCLE-DIR str
TYPED-VARIABLE CYCLE-ARENA ^ARENA:arena

: CLEAN? ( sync-event -- bool )
   MATCH sync-event
      clean OF true ENDOF
      dirty OF false ENDOF
      fresh OF false ENDOF
      failed OF false ENDOF
   ;MATCH ;

\ The token route's next answer: Dropbox refuses the refresh token.
: REFRESH-REFUSED ( -- )
   s" /oauth2/token" 400 s" " s" " S\" {\qerror\q:\qinvalid_grant\q}"
   TEST-DROPBOX:ROUTE-SCRIPT! ;

\ The backoff's wait, after a clean pass: the status shows backoff and
\ no error. Then every access token expires and the next refresh is
\ refused, which the next pass meets.
: BACKOFF-NAP ( n -- )
   NAP
   CYCLE-DIR @ S\" \qphase\q:\qbackoff\q" CYCLE-ARENA @ STATUS-HAS
   CYCLE-DIR @ S\" \qlast_error\q:null" CYCLE-ARENA @ STATUS-HAS
   TEST-DROPBOX:EXPIRE REFRESH-REFUSED ;

\ Two passes' listing pages, both empty, and a long poll that answers
\ changes with a backoff.
: CYCLE-SCRIPT ( -- )
   TEST-DROPBOX:RESET
   s" []" s" cursor-1" false TEST-DROPBOX:PAGE!
   s" []" s" cursor-2" false TEST-DROPBOX:PAGE!
   true BACKOFF-S TEST-DROPBOX:POLL! ;

\ A run whose status in d holds an error for a clean pass to clear,
\ with the sync root at root and a session on the fake.
: CYCLE-RUN ( ^ARENA:arena str str -- ^run )
   {: car d root:str :}
   d d car STATUS:NEW car RUN-IN-DIR {: x j :}
   [: BACKOFF-NAP ;] x RUN-WAIT !
   d root CONFIG:>ABS-PATH car CASE-CONFIG {: c :}
   c CONFIG:PREPARE c x RUN-CONFIG !
   x RUN-SESSIONS @ {: sar :}
   sar TEST-CLIENT:OPENED {: k :}
   k TEST-CLIENT:ACCOUNT-OF
   k EXPECTED sar OWNED-SESSION {: s :}
   s x RUN-SESSION !
   s x NEW-LINK x RUN-LINK !
   JOURNAL x STATUS@ STATUS:ERROR
   x ;

: CYCLED-TO-A-STOP ( ^ARENA:arena str str -- )
   {: car d root:str :}
   car d root CYCLE-RUN {: x :}
   CYCLE-SCRIPT
   d CYCLE-DIR ! car CYCLE-ARENA ! 0 NAPS !
   x AT-SYNCING DAEMON-RUN
   NAPS @ 1 T= 0 BACKOFF-S 1000 * NAPPED=
   x RUN-PASSED @ CLEAN? TTRUE
   d S\" \qphase\q:\qstopped\q" car STATUS-HAS
   d BINDING str> car STATUS-HAS
   x EXIT-STATUS 78 T= ;

: SYNCING-BACKS-OFF-AND-STOPS-ON-A-REFUSED-REFRESH
   ( ^ARENA:arena -- )
   {: ar :}
   s" syncing_backs_off_and_stops_on_a_refused_refresh" T-LABEL
   ar CASE-DIR {: d:str :}
   ar CASE-DIR {: root:str :}
   [: d root CYCLED-TO-A-STOP ;] WITH-CASE
   root str> FS:REMOVE-TREE
   d str> FS:REMOVE-TREE ;

\ The cases that need no Dropbox, then those against the fake under
\ curl's loop.
: RUN-SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   ar DURABLE-BINDING-IS-REQUIRED-AND-AUTHORITATIVE
   ar REPEATED-LONG-POLL-RETRIES-RETAIN-THE-SESSION-AND-ESCALATE-AFTER-CLEAN-SYNC-PASSES
   ar SYNCING-BACKS-OFF-AND-STOPS-ON-A-REFUSED-REFRESH ;

\ AUTH reads its credential from a directory under TMPDIR.
: RUN-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar CASE-DIR {: cd:str :}
   cd CREDENTIAL-DIR !
   cd str> s" org.omarchy.omabox" SECRET:DIR-BIND
   ar RECOVERY-CONTROL-RETRIES-UNDER-A-HELD-LOCK-AND-CLEARS-ONLY-AFTER-A-CLEAN-PASS
   ar RECOVERY-CONTROL-PUBLISHES-STOPPED-BEFORE-A-FATAL-EXIT
   ROOT-INSPECTION-FAILURE-IS-UNAVAILABLE-ONLY-FOR-A-STAND-IN
   ar STAND-IN-WITHOUT-BIRTH-TIME-LEAVES-THE-ROOT-UNAVAILABLE
   AIO:START CURL:LOOP-START TEST-CLIENT:CURL-READY
   [: TEST-DROPBOX:START
      [: ar RUN-SERVED ;] [: TEST-DROPBOX:STOP ;] finally ;]
   [: CURL:LOOP-STOP AIO:STOP ;] finally
   cd str> FS:REMOVE-TREE ;


public
EXPORT OWNED-SESSION
EXPORT VALIDATE
EXPORT CHECK$
EXPORT REFUSED?
EXPORT POLICY-CASES
EXPORT RUN-CASES
;package

using TEST-CLIENT
package DAEMON-TEST
private


\ ---- account ----

\ Rust's fake_client's root: the fake's account and namespace, at
\ remote root r.
: BINDING-AT ( ^u8 n -- JOURNAL:dropbox-binding )
   >str {: r:str :}
   s" dbid:account" >str s" namespace" >str r
   JOURNAL-DROPBOX--BINDING:MAKE ;

\ The binding Rust's tests store for another account.
: ANOTHER ( -- JOURNAL:dropbox-binding )
   s" different-account" >str s" namespace" >str s" " >str
   JOURNAL-DROPBOX--BINDING:MAKE ;

: TOKENED ( ^ARENA:arena -- ^DROPBOX:client )
   OPENED {: c :}
   c ACCOUNT-OF c ;

\ A case's directory and the journal opened in it.
: CASE-JOURNAL ( ^ARENA:arena -- str JOURNAL:journal )
   {: ar :}
   s" daemon-test" FS:MKTEMP-DIR ar COPIED {: d:str :}
   SB-RESET d str> SB-APPEND s" /journal.sqlite3" SB-APPEND
   d SB$ ar COPIED JOURNAL:OPEN ;

: CASE-GONE ( str JOURNAL:journal -- )
   JOURNAL:CLOSE str> FS:REMOVE-TREE ;

: SEEN ( ^u8 n -- ) TEST-DROPBOX:SEEN$ 2swap T$= ;

: ACCOUNT-ROUTE$ ( -- ^u8 n ) s" /2/users/get_current_account" ;

\ Rust's root_link_failure: a client whose get_metadata answers status
\ st and the body b builds, nothing seen yet.
: ROOT-ANSWERS ( n [ -- ^u8 n ] ^ARENA:arena -- ^DROPBOX:client )
   {: st:n b ar :}
   ar TOKENED {: c :}
   TEST-DROPBOX:RESET
   s" /2/files/get_metadata" st s" " s" " b execute
   TEST-DROPBOX:ROUTE-SCRIPT!
   c ;

\ Rust's root_link_failure's two requests.
: ROOT-SEEN ( -- )
   s" /2/users/get_current_account /2/files/get_metadata" SEEN ;

: PATHS+ ( -- )
   S\" ,\qpath_lower\q:\q/sync\q,\qpath_display\q:\q/Sync\q" SB-APPEND ;

\ Rust's lookup_error("not_found").
: NOT-FOUND$ ( -- ^u8 n )
   SB-RESET S\" {\qerror_summary\q:\qpath/not_found/...\q," SB-APPEND
   S\" \qerror\q:{\q.tag\q:\qpath\q,\qpath\q:{\q.tag\q:\qnot_found\q}}}"
   SB-APPEND SB$ ;

TYPED-VARIABLE HASHING DROPBOX:hasher

\ Rust's file_metadata("/sync", "/Sync", "root-file-revision") of the
\ bytes "root file".
: ROOT-FILE$ ( -- ^u8 n )
   HASHING DROPBOX:HASH-BEGIN
   s" root file" HASHING DROPBOX:HASH-FEED
   HASHING DROPBOX:HASH-END {: h:^ hu:n :}
   SB-RESET S\" {\q.tag\q:\qfile\q" SB-APPEND PATHS+
   S\" ,\qrev\q:\qroot-file-revision\q,\qsize\q:0" SB-APPEND
   S\" ,\qcontent_hash\q:" SB-APPEND h hu QUOTED+
   S\" ,\qis_downloadable\q:true}" SB-APPEND SB$ ;

\ Rust's restricted_folder_metadata("/sync", "/Sync", {r: true}).
: RESTRICTED$ ( ^u8 n -- ^u8 n )
   {: r:^ ru:n :}
   SB-RESET S\" {\q.tag\q:\qfolder\q" SB-APPEND PATHS+
   S\" ,\qsharing_info\q:{" SB-APPEND r ru QUOTED+
   S\" :true,\qread_only\q:false}}" SB-APPEND SB$ ;

: LINK-REJECTS-UNAVAILABLE-FILE-AND-RESTRICTED-ROOTS ( ^ARENA:arena -- )
   {: ar :}
   s" link_rejects_unavailable_file_and_restricted_roots" T-LABEL
   s" /Sync" BINDING-AT {: b :}
   ar CASE-JOURNAL {: d:str j :}
   409 [: NOT-FOUND$ ;] ar ROOT-ANSWERS {: c1 :}
   j c1 b ar DAEMON:OWNED-SESSION ar DAEMON:VALIDATE
   DROPBOX-ERROR:NOT-FOUND DAEMON:REFUSED? TTRUE
   ROOT-SEEN
   200 [: ROOT-FILE$ ;] ar ROOT-ANSWERS {: c2 :}
   j c2 b ar DAEMON:OWNED-SESSION ar DAEMON:VALIDATE DAEMON:CHECK$
   s" root-unavailable" T$=
   ROOT-SEEN
   200 [: s" no_access" RESTRICTED$ ;] ar ROOT-ANSWERS {: c3 :}
   j c3 b ar DAEMON:OWNED-SESSION ar DAEMON:VALIDATE DAEMON:CHECK$
   s" root-unavailable" T$=
   ROOT-SEEN
   200 [: s" traverse_only" RESTRICTED$ ;] ar ROOT-ANSWERS {: c4 :}
   j c4 b ar DAEMON:OWNED-SESSION ar DAEMON:VALIDATE DAEMON:CHECK$
   s" root-unavailable" T$=
   ROOT-SEEN
   d j CASE-GONE ;

: JOURNAL-BINDING-MISMATCH-BLOCKS-INVENTORY-BEFORE-LISTING
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_binding_mismatch_blocks_inventory_before_listing" T-LABEL
   ar CASE-JOURNAL {: d:str j :}
   j ANOTHER ar JOURNAL:BIND-DROPBOX-ROOT drop
   ar TOKENED {: c :}
   TEST-DROPBOX:RESET
   j c s" " BINDING-AT ar DAEMON:OWNED-SESSION ar DAEMON:VALIDATE
   DAEMON:CHECK$ s" journal-binding-changed" T$=
   ACCOUNT-ROUTE$ SEEN
   d j CASE-GONE ;

: ACCOUNT-VALIDATION-IS-CACHED-PER-CLIENT-BUT-EVERY-JOURNAL-IS-CHECKED
   ( ^ARENA:arena -- )
   {: ar :}
   s" account_validation_is_cached_per_client_but_every_journal_is_checked"
   T-LABEL
   s" " BINDING-AT {: b :}
   ar CASE-JOURNAL {: d:str j :}
   ar TOKENED {: c1 :}
   ar TOKENED {: c2 :}
   TEST-DROPBOX:RESET
   c1 b ar DAEMON:OWNED-SESSION {: s1 :}
   j s1 ar DAEMON:VALIDATE DAEMON:CHECK$ s" valid" T$=
   j s1 ar DAEMON:VALIDATE DAEMON:CHECK$ s" valid" T$=
   j s1 ar DAEMON:VALIDATE DAEMON:CHECK$ s" valid" T$=
   c2 b ar DAEMON:OWNED-SESSION {: s2 :}
   j s2 ar DAEMON:VALIDATE DAEMON:CHECK$ s" valid" T$=
   ar CASE-JOURNAL {: wd:str wj :}
   wj ANOTHER ar JOURNAL:BIND-DROPBOX-ROOT drop
   wj s2 ar DAEMON:VALIDATE DAEMON:CHECK$
   s" journal-binding-changed" T$=
   ACCOUNT-ROUTE$ TEST-DROPBOX:CALLS 2 T=
   s" /2/users/get_current_account /2/users/get_current_account" SEEN
   wd wj CASE-GONE
   d j CASE-GONE ;

: FAILED-ACCOUNT-VALIDATION-IS-RETRIED-BY-THE-SAME-CLIENT
   ( ^ARENA:arena -- )
   {: ar :}
   s" failed_account_validation_is_retried_by_the_same_client" T-LABEL
   ar CASE-JOURNAL {: d:str j :}
   ar TOKENED {: c :}
   TEST-DROPBOX:RESET
   ACCOUNT-ROUTE$ 500 s" " s" "
   S\" {\qerror\q:{\q.tag\q:\qother\q}}" TEST-DROPBOX:ROUTE-SCRIPT!
   c s" " BINDING-AT ar DAEMON:OWNED-SESSION {: s :}
   j s ar DAEMON:VALIDATE DAEMON:CHECK$ s" failed" T$=
   j s ar DAEMON:VALIDATE DAEMON:CHECK$ s" valid" T$=
   s" /2/users/get_current_account /2/users/get_current_account" SEEN
   d j CASE-GONE ;

: ACCOUNT-SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   ar LINK-REJECTS-UNAVAILABLE-FILE-AND-RESTRICTED-ROOTS
   ar JOURNAL-BINDING-MISMATCH-BLOCKS-INVENTORY-BEFORE-LISTING
   ar ACCOUNT-VALIDATION-IS-CACHED-PER-CLIENT-BUT-EVERY-JOURNAL-IS-CHECKED
   ar FAILED-ACCOUNT-VALIDATION-IS-RETRIED-BY-THE-SAME-CLIENT ;

\ The account cases against one fake Dropbox, under curl's loop.
: ACCOUNT-CASES ( ^ARENA:arena -- )
   {: ar :}
   AIO:START CURL:LOOP-START CURL-READY
   [: TEST-DROPBOX:START
      [: ar ACCOUNT-SERVED ;] [: TEST-DROPBOX:STOP ;] finally ;]
   [: CURL:LOOP-STOP AIO:STOP ;] finally ;


\ ---- the suite ----

: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar DAEMON:POLICY-CASES ar ACCOUNT-CASES ar DAEMON:RUN-CASES ;]
   [: ar ARENA:RELEASE ;] finally
   s" daemon-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
;using
