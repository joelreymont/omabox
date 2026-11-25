\ daemon.f - package DAEMON: the daemon (rust src/daemon.rs). Its
\ failure policy maps each code a step throws, and each Dropbox reply
\ that ends a step, to a failure: a disposition, which decides whether
\ the daemon waits and tries again or exits, and the status text the
\ widget shows. No row reads FS:ERRNO, which cleanup on the way up may
\ clear: a full disk and a missing config.toml are codes of their own. A
\ code no row names is an invariant, INTERNAL. VALIDATE checks a client's
\ account, namespace and remote root once, and the journal's binding every
\ time.
\ RUN is the daemon: the machine DAEMON-RUN prepares, locks, opens the
\ journal, tells systemd it is ready, then syncs and long-polls until a
\ failure stops it, and RUN answers the exit status.
\ STORAGE CLASS. PROCESS-WIDE: the binding a rotated refresh token is
\ stored with. CALLER-OWNED: a retry schedule, and a session in the
\ arena its caller passes. RUN owns an arena for the process; its
\ children are one each for preparing and configuring, reset before each
\ attempt, one for the session, whose reset closes its client, and one
\ for the pass.

require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fs.f
require src/lib/sqlite.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/systemd.f
require src/lib/task.f
require src/lib/time.f
require src/lib/ffi-abi.f
require src/dropbox.f
require src/journal.f
require src/config.f
require src/local.f
require src/lib/secret.f
require src/auth.f
require src/replay.f
require src/reconcile.f
require src/status.f

package DAEMON
private


\ ---- failure policy ----------------------------------------------

\ retry waits at least floor ms; environmental waits with backoff;
\ user-action and invariant exit.
ENUM disposition DERIVE eq
   VARIANT retry FIELD floor n ;VARIANT
   VARIANT environmental ;VARIANT
   VARIANT user-action ;VARIANT
   VARIANT invariant ;VARIANT
;ENUM

STRUCTURE failure
   FIELD disposition disposition
   FIELD text str
;STRUCTURE

: SETUP ( -- str ) s" Omabox setup is incomplete." ;
: CONFIGURATION ( -- str )
   s" Omabox configuration is unavailable." ;
: CONFIGURATION-INVALID ( -- str )
   s" Omabox configuration needs attention." ;
: STATE ( -- str ) s" Omabox state storage is unavailable." ;
: DISK-FULL ( -- str ) s" Local storage is full." ;
: JOURNAL ( -- str )
   s" The sync journal is temporarily unavailable." ;
: JOURNAL-INVALID ( -- str )
   s" The sync journal needs attention." ;
: CREDENTIALS ( -- str )
   s" Dropbox credentials are temporarily unavailable." ;
: CREDENTIAL-INVALID ( -- str )
   s" Dropbox credentials need to be renewed." ;
: DROPBOX ( -- str )
   s" Dropbox is temporarily unavailable." ;
: UNREACHABLE ( -- str ) s" Dropbox could not be reached." ;
: BINDING ( -- str )
   s" The Dropbox account or sync root no longer matches setup." ;
: SYNC-ROOT ( -- str )
   s" The configured sync folder is temporarily unavailable." ;
: ROOT-UNSUPPORTED ( -- str )
   s" The sync folder's filesystem does not record creation times." ;
: SYNC-ERRORS ( -- str )
   s" One or more files could not be synchronized." ;
: CURSOR ( -- str )
   s" The Dropbox inventory cursor is temporarily unavailable." ;
: RUNNING ( -- str )
   s" Another Omabox daemon is already running." ;
: READINESS ( -- str )
   s" Omabox could not notify the service manager that startup completed." ;
: INTERNAL ( -- str )
   s" Omabox stopped after detecting invalid internal state." ;

: ENVIRONMENTAL ( str -- failure )
   {: t:str :}
   construct disposition environmental t FAILURE-MAKE ;
: USER-ACTION ( str -- failure )
   {: t:str :}
   construct disposition user-action t FAILURE-MAKE ;
: INVARIANT ( str -- failure )
   {: t:str :}
   construct disposition invariant t FAILURE-MAKE ;
\ Rust's retry_policy: try again after at least n ms.
: RETRY ( n str -- failure )
   {: t:str :}
   construct disposition retry t FAILURE-MAKE ;

\ Rust's config_policy and lock_policy.
: CONFIG-POLICY ( n -- failure )
   case
      CONFIG:E-HOME-UNAVAILABLE of
         CONFIGURATION-INVALID USER-ACTION endof
      CONFIG:E-PATH-NOT-ABSOLUTE of
         CONFIGURATION-INVALID USER-ACTION endof
      CONFIG:E-READ of CONFIGURATION ENVIRONMENTAL endof
      CONFIG:E-MISSING of SETUP USER-ACTION endof
      CONFIG:E-PARSE of CONFIGURATION-INVALID USER-ACTION endof
      CONFIG:E-EMPTY-APP-KEY of
         CONFIGURATION-INVALID USER-ACTION endof
      CONFIG:E-RESOLVE-SYNC-ROOT of SYNC-ROOT ENVIRONMENTAL endof
      CONFIG:E-SYNC-ROOT-NOT-DIRECTORY of
         SYNC-ROOT ENVIRONMENTAL endof
      CONFIG:E-INSPECT-PATH of SYNC-ROOT ENVIRONMENTAL endof
      CONFIG:E-INSIDE-SYNC-ROOT of
         CONFIGURATION-INVALID USER-ACTION endof
      CONFIG:E-CREATE-DIRECTORY of STATE ENVIRONMENTAL endof
      CONFIG:E-SECURE-DIRECTORY of STATE ENVIRONMENTAL endof
      CONFIG:E-LOCK-OPEN of STATE ENVIRONMENTAL endof
      CONFIG:E-ALREADY-RUNNING of RUNNING USER-ACTION endof
      CONFIG:E-LOCK-ACQUIRE of STATE ENVIRONMENTAL endof
      CONFIG:E-DISK-FULL of DISK-FULL ENVIRONMENTAL endof
      INTERNAL INVARIANT swap
   endcase ;

\ Rust's journal_policy over JOURNAL's and SQLITE's codes; E-ROOT is
\ local_root_policy's file failure.
: JOURNAL-POLICY ( n -- failure )
   case
      JOURNAL:E-FILE of JOURNAL ENVIRONMENTAL endof
      JOURNAL:E-DISK-FULL of DISK-FULL ENVIRONMENTAL endof
      JOURNAL:E-JSON of JOURNAL-INVALID INVARIANT endof
      JOURNAL:E-INVALID-STATE of JOURNAL-INVALID INVARIANT endof
      JOURNAL:E-UNSUPPORTED-VERSION of
         JOURNAL-INVALID USER-ACTION endof
      JOURNAL:E-NO-BIRTH-TIME of ROOT-UNSUPPORTED USER-ACTION endof
      JOURNAL:E-ROOT of SYNC-ROOT ENVIRONMENTAL endof
      SQLITE:E-CORRUPT of JOURNAL-INVALID USER-ACTION endof
      SQLITE:E-FULL of DISK-FULL ENVIRONMENTAL endof
      SQLITE:E-SQL of JOURNAL ENVIRONMENTAL endof
      SQLITE:E-HANDLE of JOURNAL ENVIRONMENTAL endof
      INTERNAL INVARIANT swap
   endcase ;

\ Rust's auth_policy, and SECRET's codes AUTH passes on: E-CONFIG is no
\ Secret Service to reach, Rust's CredentialSpawn.
: AUTH-POLICY ( n -- failure )
   case
      AUTH:E-JSON of CREDENTIAL-INVALID USER-ACTION endof
      AUTH:E-UTF8 of CREDENTIAL-INVALID USER-ACTION endof
      AUTH:E-TOO-LARGE of CREDENTIAL-INVALID USER-ACTION endof
      AUTH:E-VERSION of CREDENTIAL-INVALID USER-ACTION endof
      SECRET:E-CONFIG of CREDENTIALS ENVIRONMENTAL endof
      INTERNAL INVARIANT swap
   endcase ;

\ Rust's dropbox_policy and transport_policy. E-TRANSPORT is a call
\ that got no HTTP answer, which Rust retries.
: DROPBOX-POLICY ( n -- failure )
   case
      DROPBOX:E-REDIRECT of INTERNAL INVARIANT endof
      DROPBOX:E-BAD-REQUEST of INTERNAL INVARIANT endof
      DROPBOX:E-STATUS of INTERNAL INVARIANT endof
      DROPBOX:E-ANSWER of INTERNAL INVARIANT endof
      DROPBOX:E-AUTH of BINDING USER-ACTION endof
      DROPBOX:E-TRANSPORT of 5000 UNREACHABLE RETRY endof
      DROPBOX:E-NOT-STORED of CREDENTIALS ENVIRONMENTAL endof
      DROPBOX:E-STAGE of STATE ENVIRONMENTAL endof
      DROPBOX:E-UNUSABLE of DROPBOX ENVIRONMENTAL endof
      INTERNAL INVARIANT swap
   endcase ;

\ Rust's local_policy. E-SOURCE-CHANGED is an upload source that
\ changed during its read.
: LOCAL-POLICY ( n -- failure )
   case
      LOCAL:E-UNSAFE-PATH of INTERNAL INVARIANT endof
      LOCAL:E-UNSUPPORTED of SYNC-ERRORS ENVIRONMENTAL endof
      LOCAL:E-UNREADABLE of SYNC-ROOT ENVIRONMENTAL endof
      LOCAL:E-CHANGED of SYNC-ERRORS ENVIRONMENTAL endof
      LOCAL:E-CONTENT-HASH of INTERNAL INVARIANT endof
      LOCAL:E-CORRUPT of SYNC-ERRORS ENVIRONMENTAL endof
      LOCAL:E-OCCUPIED of SYNC-ERRORS ENVIRONMENTAL endof
      LOCAL:E-IO of SYNC-ROOT ENVIRONMENTAL endof
      LOCAL:E-STAGE-READ of SYNC-ROOT ENVIRONMENTAL endof
      LOCAL:E-DISK-FULL of DISK-FULL ENVIRONMENTAL endof
      LOCAL:E-SOURCE-CHANGED of SYNC-ERRORS ENVIRONMENTAL endof
      INTERNAL INVARIANT swap
   endcase ;

\ Rust's recovery_policy and reconcile_policy. E-LISTING is a listing
\ outside the root or a root that is no usable folder.
: PASS-POLICY ( n -- failure )
   case
      REPLAY:E-INVALID-STATE of JOURNAL-INVALID INVARIANT endof
      RECONCILE:E-INVALID-STATE of INTERNAL INVARIANT endof
      RECONCILE:E-CASE-COLLISION of SYNC-ERRORS ENVIRONMENTAL endof
      RECONCILE:E-LISTING of DROPBOX ENVIRONMENTAL endof
      INTERNAL INVARIANT swap
   endcase ;

\ Whether code lies in the block from first down to last.
: IN? ( n n n -- bool )
   {: code first last :}
   code first <= code last >= and ;

\ The failure a thrown code stands for. JOURNAL's and SQLITE's codes,
\ and every code no block below holds, go to JOURNAL-POLICY.
: CODE-FAILURE ( n -- failure )
   {: c :}
   c CONFIG:E-FIRST CONFIG:E-LAST IN? if c CONFIG-POLICY exit then
   c AUTH:E-FIRST AUTH:E-LAST IN? if c AUTH-POLICY exit then
   c SECRET:E-FIRST SECRET:E-LAST IN? if c AUTH-POLICY exit then
   c DROPBOX:E-FIRST DROPBOX:E-LAST IN? if c DROPBOX-POLICY exit then
   c LOCAL:E-FIRST LOCAL:E-LAST IN? if c LOCAL-POLICY exit then
   c REPLAY:E-FIRST REPLAY:E-LAST IN? if c PASS-POLICY exit then
   c RECONCILE:E-FIRST RECONCILE:E-LAST IN?
   if c PASS-POLICY exit then
   c JOURNAL-POLICY ;

\ done ends no step, so a failure for it is an invariant's. k is the
\ client whose last call gave the reply.
: REPLY-FAILURE ( DROPBOX:reply ^DROPBOX:client -- failure )
   {: k :}
   MATCH DROPBOX:reply
      done OF INTERNAL INVARIANT ENDOF
      refused OF drop DROPBOX ENVIRONMENTAL ENDOF
      retry OF
         k DROPBOX:ANSWERED? if DROPBOX else UNREACHABLE then RETRY
      ENDOF
      unlinked OF BINDING USER-ACTION ENDOF
   ;MATCH ;

\ A pass's failure: E-DROPBOX by the reply the link keeps.
: PASS-FAILURE ( n ^REPLAY:link -- failure )
   {: c l :}
   c REPLAY:E-DROPBOX =
   if l REPLAY-LINK:REPLY @ l REPLAY-LINK:CLIENT @ REPLY-FAILURE exit then
   c CODE-FAILURE ;

\ The process's exit status; systemd restarts neither 70 nor 78.
: EXIT-CODE ( disposition -- n )
   MATCH disposition
      retry OF drop 70 ENDOF
      environmental OF 70 ENDOF
      user-action OF 78 ENDOF
      invariant OF 70 ENDOF
   ;MATCH ;

\ Waits in ms: the first and after a reset, the most a doubling
\ reaches, and the most a floor Dropbox asks for may hold.
5000 constant RETRY-BASE
300000 constant RETRY-CEILING
900000 constant MAX-RETRY-AFTER

\ Rust's RetrySchedule; RESET makes one new.
STRUCTURE schedule DERIVE addr
   FIELD next n
;STRUCTURE

: RESET ( ^schedule -- ) RETRY-BASE swap SCHEDULE-NEXT ! ;

\ The wait in ms after a failure whose floor is n ms.
: ADVANCE ( n ^schedule -- n )
   {: floor s :}
   s SCHEDULE-NEXT @ {: next :}
   next 2 * RETRY-CEILING min s SCHEDULE-NEXT !
   next floor MAX-RETRY-AFTER min max ;

\ ---- account ----

\ A client and the binding the journal was set up for; validated once
\ this client's account and remote root were checked.
STRUCTURE session DERIVE addr
   FIELD client ^DROPBOX:client
   FIELD binding JOURNAL:dropbox-binding
   FIELD validated bool
;STRUCTURE

ARENA SESSIONS session

\ Rust's AccountValidation and two arms more: root-unavailable for its
\ three RemoteRoot errors, failed for a call that did not answer done.
ENUM account-check
   VARIANT valid ;VARIANT
   VARIANT account-changed ;VARIANT
   VARIANT root-changed ;VARIANT
   VARIANT journal-binding-changed ;VARIANT
   VARIANT root-unavailable ;VARIANT
   VARIANT failed FIELD reply DROPBOX:reply ;VARIANT
;ENUM

: VALID? ( account-check -- bool )
   MATCH account-check
      valid OF true ENDOF
      account-changed OF false ENDOF
      root-changed OF false ENDOF
      journal-binding-changed OF false ENDOF
      root-unavailable OF false ENDOF
      failed OF drop false ENDOF
   ;MATCH ;

: BOUND? ( JOURNAL:dropbox-binding-write -- bool )
   MATCH JOURNAL:dropbox-binding-write
      bound OF true ENDOF
      already-bound OF true ENDOF
      mismatch OF drop false ENDOF
   ;MATCH ;

: ACCOUNT$ ( ^session -- str )
   SESSION-BINDING @ JOURNAL-DROPBOX--BINDING:UNMAKE
   {: a:str n:str r:str :} a ;

: NAMESPACE$ ( ^session -- str )
   SESSION-BINDING @ JOURNAL-DROPBOX--BINDING:UNMAKE
   {: a:str n:str r:str :} n ;

: REMOTE-ROOT$ ( ^session -- str )
   SESSION-BINDING @ JOURNAL-DROPBOX--BINDING:UNMAKE
   {: a:str n:str r:str :} r ;

\ DROPBOX's check of the binding's remote root, its three refusals
\ root-unavailable; unbound, which only LINK answers, a root that changed.
: VALIDATE-REMOTE-ROOT ( ^session -- account-check )
   {: s :}
   s REMOTE-ROOT$ s SESSION-CLIENT @ DROPBOX:CHECK-ROOT
   MATCH DROPBOX:root-check
      valid OF construct account-check valid ENDOF
      failed OF construct account-check failed ENDOF
      unbound OF construct account-check root-changed ENDOF
      unavailable OF construct account-check root-unavailable ENDOF
      not-folder OF construct account-check root-unavailable ENDOF
      restricted OF construct account-check root-unavailable ENDOF
   ;MATCH ;

: VALIDATE-CLIENT ( ^session -- account-check )
   {: s :}
   s SESSION-CLIENT @ {: c :}
   c DROPBOX:ACCOUNT {: r :}
   r DROPBOX:DONE? 0= if r construct account-check failed exit then
   c DROPBOX:ACCOUNT-ID s ACCOUNT$ STR:= 0= if
      construct account-check account-changed exit
   then
   c DROPBOX:ROOT-NAMESPACE s NAMESPACE$ STR:= 0= if
      construct account-check root-changed exit
   then
   s VALIDATE-REMOTE-ROOT ;

: CLIENT-CHECK ( ^session -- account-check )
   {: s :}
   s SESSION-VALIDATED @ if construct account-check valid exit then
   s VALIDATE-CLIENT ;

\ Rust's validate_account: the client once, the journal's binding each
\ time.
: VALIDATE ( JOURNAL:journal ^session ^ARENA:arena -- account-check )
   {: j s ar :}
   s CLIENT-CHECK {: k :}
   k VALID? 0= if k exit then
   j s SESSION-BINDING @ ar JOURNAL:BIND-DROPBOX-ROOT BOUND? 0= if
      construct account-check journal-binding-changed exit
   then
   true s SESSION-VALIDATED !
   construct account-check valid ;

\ ---- run ----

30 constant LONG-POLL-S     \ the most a long poll waits for changes
1000 constant FRESH-MS      \ the wait before a fresh observation

ENUM daemon-state DERIVE eq
   preparing locking opening notifying configuring
   starting validating syncing polling stopped ;ENUM

ENUM step-event ok retry stop ;ENUM
\ clean and dirty: a complete pass without and with sync errors.
ENUM sync-event clean dirty fresh retry stop ;ENUM

\ code is 0 for a failure a step answered; backoff the s the last long
\ poll asked for, 0 for none.
STRUCTURE run DERIVE addr
   FIELD arena ^ARENA:arena
   FIELD preparing ^ARENA:arena
   FIELD configuring ^ARENA:arena
   FIELD sessions ^ARENA:arena
   FIELD passes ^ARENA:arena
   FIELD wait [ n -- ]
   FIELD status ^STATUS:status
   FIELD document ^CONFIG:document
   FIELD paths ^CONFIG:paths
   FIELD config ^CONFIG:config
   FIELD lock ^option<CONFIG:lock>
   FIELD journal-held ^option<JOURNAL:journal>
   FIELD journal JOURNAL:journal
   FIELD dropbox DROPBOX:config
   FIELD session ^session
   FIELD link ^REPLAY:link
   FIELD watch ^LOCAL:watch
   FIELD schedule schedule
   FIELD failure failure
   FIELD code n
   FIELD backoff n
   FIELD passed sync-event
;STRUCTURE

ARENA RUNS run
ARENA LOCKS option<CONFIG:lock>
ARENA JOURNALS option<JOURNAL:journal>
: NO-LOCK ( -- option<CONFIG:lock> ) OPTION:NONE ;
: NO-JOURNAL ( -- option<JOURNAL:journal> ) OPTION:NONE ;
ARENA LINKS REPLAY:link

\ The binding a rotated refresh token is stored with: the session's.
TYPED-VARIABLE STORED JOURNAL:dropbox-binding

\ The code's number, name and text in parentheses; nothing for 0.
: CAUSE+ ( n -- )
   {: code :}
   code 0= if exit then
   s"  (" LOG:TEXT+ code LOG:CODE+ s" )" LOG:TEXT+ ;

: STATUS@ ( ^run -- ^STATUS:status ) RUN-STATUS @ ;
: JOURNAL@ ( ^run -- JOURNAL:journal ) RUN-JOURNAL @ ;
: CLIENT@ ( ^run -- ^DROPBOX:client ) RUN-SESSION @ SESSION-CLIENT @ ;
: PHASE! ( STATUS:phase ^run -- ) STATUS@ STATUS:PHASE ;
PROCESS-SYMBOLS
FUNCTION: MALLOC-TRIM malloc_trim ( n -- i32 )
;FUNCTION

\ Freed heap pages go back to the system before the daemon blocks: glibc
\ returns only the heap's top by itself.
: RELEASE-HEAP ( -- ) 0 MALLOC-TRIM drop ;

: SLEEP ( n ^run -- ) RELEASE-HEAP RUN-WAIT @ execute ;

: FAILED ( n failure ^run -- )
   {: code f x :}
   code x RUN-CODE !
   f x RUN-FAILURE ! ;

\ A failure a step answered, not threw; answers false, as TRIED does.
: FAIL ( failure ^run -- bool )
   {: f x :}
   0 f x FAILED false ;

\ Runs step on x; a code it throws becomes its failure through map.
: ATTEMPT ( ^run [ ^run -- bool ] [ n -- failure ] -- bool )
   {: x step map :}
   false [: drop x step execute ;] catch {: ok code :}
   code 0= if ok exit then
   code code map execute x FAILED false ;

: TRIED ( ^run [ ^run -- bool ] -- bool ) [: CODE-FAILURE ;] ATTEMPT ;

: DISPOSITION@ ( ^run -- disposition )
   RUN-FAILURE @ FAILURE-UNMAKE {: d t:str :} d ;

: STOPS? ( disposition -- bool )
   MATCH disposition
      retry OF drop false ENDOF
      environmental OF false ENDOF
      user-action OF true ENDOF
      invariant OF true ENDOF
   ;MATCH ;

\ The failure recorded: stop if it stops the daemon, else retry.
: WEIGH ( ^run -- step-event )
   DISPOSITION@ STOPS? if construct step-event stop exit then
   construct step-event retry ;

: WEIGH-PASS ( ^run -- sync-event )
   DISPOSITION@ STOPS? if construct sync-event stop exit then
   construct sync-event retry ;

\ ok if step on x succeeds, else its failure weighed.
: TRIED-STEP ( ^run [ ^run -- bool ] -- step-event )
   {: x step :}
   x step TRIED if construct step-event ok exit then
   x WEIGH ;

\ ---- the process's states

: PREPARED ( ^run -- bool )
   {: x :}
   x RUN-PREPARING @ {: ar :}
   ar ARENA:RESET
   ar CONFIG:XDG-ENV {: xdg :}
   xdg ar CONFIG:DOCUMENT-LOAD-FROM x RUN-DOCUMENT !
   xdg ar CONFIG:RESOLVE-PRIVATE x RUN-PATHS !
   x RUN-PATHS @ x RUN-DOCUMENT @ CONFIG:DOCUMENT-ROOT
   CONFIG:PREPARE-PATHS
   true ;

: PREPARE ( ^run -- step-event ) [: PREPARED ;] TRIED-STEP ;

: UNLOCKED ( ^option<CONFIG:lock> -- )
   @ MATCH option
      some OF CONFIG:UNLOCK ENDOF
      none OF ENDOF
   ;MATCH ;

\ Held until the process's arena is released.
: LOCKED ( ^run -- bool )
   {: x :}
   x RUN-PATHS @ CONFIG:LOCK OPTION:SOME x RUN-LOCK @ !
   true ;

: LOCKING ( ^run -- step-event ) [: LOCKED ;] TRIED-STEP ;

: CLOSED ( ^option<JOURNAL:journal> -- )
   @ MATCH option
      some OF JOURNAL:CLOSE ENDOF
      none OF ENDOF
   ;MATCH ;

\ The run's journal at path, open until the process's arena is released.
: HOLD-JOURNAL ( str ^run -- )
   {: path:str x :}
   path JOURNAL:OPEN {: j :}
   j OPTION:SOME x RUN-JOURNAL-HELD @ !
   j x RUN-JOURNAL ! ;

: OPENED ( ^run -- bool )
   {: x :}
   x RUN-PATHS @ CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR
   x HOLD-JOURNAL
   true ;

: OPENING ( ^run -- step-event ) [: OPENED ;] TRIED-STEP ;

: UNNOTIFIED ( n ^run -- bool )
   {: errno x :}
   LOG:WARN s" daemon" LOG:LINE
   s" could not send the systemd readiness notification: " LOG:TEXT+
   errno FS:ERRNO$ LOG:TEXT+ LOG:;LINE
   READINESS ENVIRONMENTAL x FAIL ;

: NOTIFIED ( ^run -- bool )
   {: x :}
   SYSTEMD:NOTIFY-READY MATCH SYSTEMD:status
      ok OF true ENDOF
      failed OF SYSTEMD:ERRNO>N x UNNOTIFIED ENDOF
   ;MATCH ;

: NOTIFYING ( ^run -- step-event ) [: NOTIFIED ;] TRIED-STEP ;

: CONFIGURED ( ^run -- bool )
   {: x :}
   x RUN-CONFIGURING @ {: ar :}
   ar ARENA:RESET
   x RUN-DOCUMENT @ x RUN-PATHS @ ar CONFIG:VALIDATE-WITH
   {: c :}
   c CONFIG:PREPARE
   c x RUN-CONFIG !
   true ;

: CONFIGURING ( ^run -- step-event ) [: CONFIGURED ;] TRIED-STEP ;

\ ---- the session's states

: NO-FAILURE ( -- option<failure> ) OPTION:NONE ;

\ Rust's root_from_bindings: none when the credential holds the
\ binding the journal was set up with.
: BINDING-FAILURE
   ( option<JOURNAL:dropbox-binding> JOURNAL:dropbox-binding
     -- option<failure> )
   {: b :}
   MATCH option
      none OF SETUP USER-ACTION OPTION:SOME ENDOF
      some OF
         b JOURNAL:BINDING= if NO-FAILURE exit then
         BINDING USER-ACTION OPTION:SOME
      ENDOF
   ;MATCH ;

: ROTATED ( str -- )
   {: t:str :}
   STORED @ t AUTH:STORE ;

\ The client's config: production's origins, the binding's namespace as
\ its root.
: CLIENT-CONFIG
   ( JOURNAL:dropbox-binding str ^run -- ^DROPBOX:config )
   {: b token:str x :}
   x RUN-DROPBOX {: cfg :}
   cfg DROPBOX:PRODUCTION
   x RUN-CONFIG @ CONFIG:APP-KEY str> SPAN:MAKE cfg DROPBOX-CONFIG:KEY !
   token str> SPAN:MAKE cfg DROPBOX-CONFIG:TOKEN !
   [: ROTATED ;] cfg DROPBOX-CONFIG:STORE !
   b JOURNAL-DROPBOX--BINDING:UNMAKE {: a:str n:str r:str :}
   n str> SPAN:MAKE cfg DROPBOX-CONFIG:ROOT !
   b STORED !
   cfg ;

\ A session not yet given its client holds a null one.
: SESSION-CLOSED ( ^session -- )
   SESSION-CLIENT @ {: c :}
   c NULL-PTR - 0= if exit then
   c DROPBOX:CLOSE ;

\ A session whose client is closed when its arena is reset or released.
: OWNED-SESSION
   ( ^DROPBOX:client JOURNAL:dropbox-binding ^ARENA:arena -- ^session )
   {: c b ar :}
   ar [: SESSION-CLOSED ;] SESSIONS-NEW-DISPOSE {: s :}
   c s SESSION-CLIENT ! b s SESSION-BINDING !
   s ;

: NEW-LINK ( ^session ^run -- ^REPLAY:link )
   {: s x :}
   x RUN-SESSIONS @ LINKS-NEW {: l :}
   s SESSION-CLIENT @ l REPLAY-LINK:CLIENT !
   s REMOTE-ROOT$ l REPLAY-LINK:ROOT !
   x STATUS@ l REPLAY-LINK:STATUS !
   l ;

\ The session is allocated before its client is opened, so a refused
\ allocation opens nothing.
: SESSION-OPENED ( JOURNAL:dropbox-binding str ^run -- bool )
   {: b token:str x :}
   x RUN-SESSIONS @ {: ar :}
   NULL-PTR b ar OWNED-SESSION {: s :}
   b token x CLIENT-CONFIG ar DROPBOX:OPEN
   s SESSION-CLIENT !
   s x RUN-SESSION !
   s x NEW-LINK x RUN-LINK !
   true ;

: CREDENTIAL-FOUND ( JOURNAL:dropbox-binding str ^run -- bool )
   {: b token:str x :}
   x JOURNAL@ x RUN-SESSIONS @ JOURNAL:DROPBOX-BINDING b BINDING-FAILURE
   MATCH option
      some OF x FAIL ENDOF
      none OF b token x SESSION-OPENED ENDOF
   ;MATCH ;

\ The reset closes the last session's client.
: LOADED ( ^run -- bool )
   {: x :}
   x RUN-SESSIONS @ {: ar :}
   ar ARENA:RESET
   ar AUTH:LOAD MATCH AUTH:lookup
      found OF x CREDENTIAL-FOUND ENDOF
      unavailable OF CREDENTIALS ENVIRONMENTAL x FAIL ENDOF
   ;MATCH ;

: START ( ^run -- step-event )
   {: x :}
   STATUS-PHASE:STARTING x PHASE!
   x [: LOADED ;] TRIED-STEP ;

\ valid fails nothing, so a failure for it is an invariant's.
: CHECK-FAILURE ( account-check ^DROPBOX:client -- failure )
   {: k :}
   MATCH account-check
      valid OF INTERNAL INVARIANT ENDOF
      account-changed OF BINDING USER-ACTION ENDOF
      root-changed OF BINDING USER-ACTION ENDOF
      journal-binding-changed OF BINDING USER-ACTION ENDOF
      root-unavailable OF DROPBOX ENVIRONMENTAL ENDOF
      failed OF k REPLY-FAILURE ENDOF
   ;MATCH ;

: VALIDATED ( ^run -- bool )
   {: x :}
   x JOURNAL@ x RUN-SESSION @ x RUN-SESSIONS @ VALIDATE {: k :}
   k VALID? if true exit then
   k x CLIENT@ CHECK-FAILURE x FAIL ;

\ Rested however the step ends, so a retry's backoff holds no api connection.
: VALIDATING ( ^run -- step-event )
   {: x :}
   [: x [: VALIDATED ;] TRIED-STEP ;] [: x CLIENT@ DROPBOX:REST ;] finally ;

: SESSION-STARTED ( ^run -- )
   drop LOG:INFO s" daemon" LOG:LINE s" Omabox daemon session started" LOG:TEXT+
   LOG:;LINE ;

\ ---- syncing

: ROOT-UNAVAILABLE ( -- failure ) SYNC-ROOT ENVIRONMENTAL ;

: GENERATION-LOGGED ( JOURNAL:local-root-record -- )
   JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b g :}
   LOG:INFO s" daemon" LOG:LINE
   s" initialized a new local sync-root generation generation=" LOG:TEXT+
   g LOG:INT+ LOG:;LINE ;

\ A new generation puts the watch in doubt: its folders may be another
\ root's.
: ACTIVATION ( JOURNAL:local-root-activation ^run -- bool )
   {: x :}
   MATCH JOURNAL:local-root-activation
      activated OF
         GENERATION-LOGGED x JOURNAL@ x RUN-WATCH @ LOCAL:WATCH-DOUBT true
      ENDOF
      current OF drop true ENDOF
      unavailable OF drop drop ROOT-UNAVAILABLE x FAIL ENDOF
   ;MATCH ;

\ Rust's activate_configured_root on the pass's arena; none is another
\ directory standing in for the root.
: ROOT-ACTIVE ( ^run -- bool )
   {: x :}
   x RUN-PASSES @ {: ar :}
   x RUN-CONFIG @ CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR
   x JOURNAL@ ar JOURNAL:INSPECT-ROOT MATCH option
      none OF ROOT-UNAVAILABLE x FAIL ENDOF
      some OF
         {: b :} x JOURNAL@ b ar JOURNAL:ACTIVATE-LOCAL-ROOT x ACTIVATION
      ENDOF
   ;MATCH ;

: REPORT-LOGGED ( RECONCILE:report -- )
   RECONCILE-REPORT:UNMAKE drop {: r n p b e c :}
   LOG:INFO s" daemon" LOG:LINE s" reconciliation pass completed" LOG:TEXT+
   s"  replayed_operations=" LOG:TEXT+ r LOG:INT+
   s"  noops=" LOG:TEXT+ n LOG:INT+
   s"  planned=" LOG:TEXT+ p LOG:INT+
   s"  blocked=" LOG:TEXT+ b LOG:INT+
   s"  sync_errors=" LOG:TEXT+ e LOG:INT+
   s"  conflicts=" LOG:TEXT+ c LOG:INT+ LOG:;LINE ;

: COMPLETED ( RECONCILE:report -- sync-event )
   {: rep :}
   rep REPORT-LOGGED
   rep RECONCILE-REPORT:UNMAKE drop {: r n p b e c :}
   e 0= if construct sync-event clean exit then
   construct sync-event dirty ;

: RECONCILED ( ^run -- sync-event )
   {: x :}
   x RUN-CONFIG @ {: c :}
   c CONFIG:PATHS {: p :}
   x JOURNAL@ x RUN-LINK @ x RUN-WATCH @
   c CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR
   p CONFIG:UPLOAD-STAGING-DIRECTORY CONFIG:ABS-PATH>STR
   p CONFIG:RECOVERY-DIRECTORY CONFIG:ABS-PATH>STR
   x RUN-PASSES @ RECONCILE:PASS MATCH RECONCILE:outcome
      complete OF COMPLETED ENDOF
      fresh OF construct sync-event fresh ENDOF
      root-changed OF
         0 ROOT-UNAVAILABLE x FAILED x WEIGH-PASS
      ENDOF
   ;MATCH ;

\ A pass's throw becomes a failure through PASS-FAILURE.
: PASSED ( ^run -- sync-event )
   {: x :}
   [: x RECONCILED x RUN-PASSED ! ;] catch {: code :}
   code 0= if x RUN-PASSED @ exit then
   code code x RUN-LINK @ PASS-FAILURE x FAILED
   x WEIGH-PASS ;

: SYNCED ( ^run -- sync-event )
   {: x :}
   x [: ROOT-ACTIVE ;] TRIED 0= if x WEIGH-PASS exit then
   x PASSED ;

\ The pass's arena is emptied and its connections closed as the pass
\ ends, so a waiting daemon holds none of its memory and only the long
\ poll's connection.
: SYNC ( ^run -- sync-event )
   {: x :}
   STATUS-PHASE:SYNCING x PHASE!
   [: x SYNCED ;] [: x RUN-PASSES @ ARENA:RESET x CLIENT@ DROPBOX:REST ;]
   finally ;

\ Rust's clean_sync_pass, then the phase.
: CLEANED ( ^run -- )
   {: x :}
   x STATUS@ STATUS:CLEAR-ERROR
   STATUS-PHASE:WAITING x PHASE! ;

: DIRTIED ( ^run -- ) STATUS@ STATUS:SYNC-ERROR ;

: REOBSERVE ( ^run -- )
   {: x :}
   LOG:INFO s" daemon" LOG:LINE s" local state changed during reconciliation"
   LOG:TEXT+ LOG:;LINE
   STATUS-PHASE:SYNCING x PHASE!
   FRESH-MS x SLEEP ;

\ ---- polling

\ The backoff the last long poll asked for, waited once.
: BACKED-OFF ( ^run -- )
   {: x :}
   x RUN-BACKOFF @ {: secs :}
   secs 0= if exit then
   0 x RUN-BACKOFF !
   LOG:INFO s" daemon" LOG:LINE s" honoring Dropbox backoff seconds=" LOG:TEXT+
   secs LOG:INT+ LOG:;LINE
   STATUS-PHASE:BACKOFF x PHASE!
   secs 1000 * x SLEEP ;

: RESET? ( DROPBOX:reply -- bool )
   MATCH DROPBOX:reply
      done OF false ENDOF
      refused OF DROPBOX-ERROR:RESET DROPBOX-ERROR:EQ ENDOF
      retry OF drop false ENDOF
      unlinked OF false ENDOF
   ;MATCH ;

\ done and a cursor reset complete a cycle; done keeps the backoff.
: WOKEN ( DROPBOX:reply ^run -- bool )
   {: r x :}
   r DROPBOX:DONE? if x CLIENT@ DROPBOX:BACKOFF x RUN-BACKOFF ! true exit then
   r RESET? if true exit then
   r x CLIENT@ REPLY-FAILURE x FAIL ;

\ None, a poll a local change ended, completes a cycle, so a pass runs.
: CURSOR-POLLED ( DROPBOX:cursor ^run -- bool )
   {: k:DROPBOX:cursor x :}
   RELEASE-HEAP
   k DROPBOX:CURSOR>STR LONG-POLL-S OPTION:NONE x CLIENT@ DROPBOX:WAIT
   MATCH option
      some OF x WOKEN ENDOF
      none OF true ENDOF
   ;MATCH ;

\ The cursor stays in the pass's arena until the next pass ends.
: POLLED ( ^run -- bool )
   {: x :}
   x JOURNAL@ x RUN-PASSES @ JOURNAL:REMOTE-CURSOR MATCH option
      none OF CURSOR ENVIRONMENTAL x FAIL ENDOF
      some OF x CURSOR-POLLED ENDOF
   ;MATCH ;

: POLL ( ^run -- step-event )
   {: x :}
   x BACKED-OFF
   x [: POLLED ;] TRIED-STEP ;

\ Rust's cycle_completed.
: CYCLED ( ^run -- ) RUN-SCHEDULE RESET ;

\ ---- waiting and stopping

: TEXT@ ( ^run -- str )
   RUN-FAILURE @ FAILURE-UNMAKE {: d t:str :} t ;

: FLOOR ( disposition -- n )
   MATCH disposition
      retry OF ENDOF
      environmental OF 0 ENDOF
      user-action OF 0 ENDOF
      invariant OF 0 ENDOF
   ;MATCH ;

: RETRY? ( disposition -- bool )
   MATCH disposition
      retry OF drop true ENDOF
      environmental OF false ENDOF
      user-action OF false ENDOF
      invariant OF false ENDOF
   ;MATCH ;

\ For a pass a Dropbox answer ended, the call that answered.
: CALL+ ( ^run -- )
   {: x :}
   x RUN-CODE @ REPLAY:E-DROPBOX <> if exit then
   s" ; " LOG:TEXT+ x CLIENT@ DROPBOX:LAST-CALL+ ;

: RETRY-LOGGED ( n ^run -- )
   {: ms x :}
   LOG:WARN s" daemon" LOG:LINE
   s" daemon operation failed; retrying in process seconds=" LOG:TEXT+
   ms 1000 / LOG:INT+ s"  error=" LOG:TEXT+ x TEXT@ LOG:TEXT+
   x RUN-CODE @ CAUSE+ x CALL+ LOG:;LINE ;

\ Rust's wait_for_failure for a failure that does not stop.
: WAITED ( ^run -- )
   {: x :}
   x DISPOSITION@ {: d :}
   x TEXT@ x STATUS@ STATUS:ERROR
   d FLOOR x RUN-SCHEDULE ADVANCE {: ms :}
   ms x RETRY-LOGGED
   d RETRY? if STATUS-PHASE:BACKOFF x PHASE! then
   ms x SLEEP ;

: STOP ( ^run -- )
   {: x :}
   x TEXT@ x STATUS@ STATUS:STOPPED
   LOG:ERROR s" daemon" LOG:LINE
   s" daemon stopped: " LOG:TEXT+ x TEXT@ LOG:TEXT+
   x RUN-CODE @ CAUSE+ x CALL+ LOG:;LINE ;

: EXIT-STATUS ( ^run -- n ) DISPOSITION@ EXIT-CODE ;

\ Rust's run, run_owned and run_session: a failure that stops ends the run;
\ any other waits and tries its state again, polling's from syncing.
FSM:DEFINE DAEMON-RUN ( ^run ) daemon-state step-event
   IN preparing  PREPARE
      ok     -                >locking
      retry  WAITED           >preparing
      stop   -                >stopped
   IN locking  LOCKING
      ok     -                >opening
      retry  WAITED           >locking
      stop   -                >stopped
   IN opening  OPENING
      ok     -                >notifying
      retry  WAITED           >opening
      stop   -                >stopped
   IN notifying  NOTIFYING
      ok     -                >configuring
      retry  WAITED           >notifying
      stop   -                >stopped
   IN configuring  CONFIGURING
      ok     -                >starting
      retry  WAITED           >configuring
      stop   -                >stopped
   IN starting  START
      ok     -                >validating
      retry  WAITED           >starting
      stop   -                >stopped
   IN validating  VALIDATING
      ok     SESSION-STARTED  >syncing
      retry  WAITED           >validating
      stop   -                >stopped
   IN syncing  SYNC ( sync-event )
      clean  CLEANED          >polling
      dirty  DIRTIED          >polling
      fresh  REOBSERVE        >syncing
      retry  WAITED           >syncing
      stop   -                >stopped
   IN polling  POLL
      ok     CYCLED           >syncing
      retry  WAITED           >syncing
      stop   -                >stopped
   FINAL stopped  STOP
;DEFINE

\ ---- the process

\ The lock's and the journal's holders are made once, empty, so a failed
\ attempt to lock or open allocates nothing. The watch lives in ar across
\ passes; ar's release closes its instance.
: NEW-RUN ( ^STATUS:status [ n -- ] ^ARENA:arena -- ^run )
   {: s w ar :}
   ar RUNS-NEW {: x :}
   ar x RUN-ARENA !
   ar [: UNLOCKED ;] LOCKS-NEW-DISPOSE {: l :}
   NO-LOCK l ! l x RUN-LOCK !
   ar [: CLOSED ;] JOURNALS-NEW-DISPOSE {: j :}
   NO-JOURNAL j ! j x RUN-JOURNAL-HELD !
   ar ARENA:NEW-IN x RUN-PREPARING !
   ar ARENA:NEW-IN x RUN-CONFIGURING !
   ar ARENA:NEW-IN x RUN-SESSIONS !
   ar ARENA:NEW-IN x RUN-PASSES !
   ar LOCAL:NEW-WATCH x RUN-WATCH !
   w x RUN-WAIT !
   s x RUN-STATUS !
   x RUN-SCHEDULE RESET
   x ;

\ The status in XDG_RUNTIME_DIR, else one that writes nothing.
: STATUS-FOR ( ^ARENA:arena -- ^STATUS:status )
   {: ar :}
   NULL-PTR [: drop ar STATUS:FROM-ENVIRONMENT ;] catch {: s code :}
   code 0= if s exit then
   LOG:WARN s" daemon" LOG:LINE
   s" runtime status is unavailable; syncing will continue" LOG:TEXT+
   code CAUSE+ LOG:;LINE
   ar STATUS:DETACHED ;

: MACHINE ( ^run -- )
   {: x :}
   [: x construct daemon-state preparing DAEMON-RUN ;] DROPBOX:WITH-LOOP ;

\ A code the machine does not catch stops it as an invariant.
: GUARDED ( ^run -- )
   {: x :}
   [: x MACHINE ;] catch {: code :}
   code 0= if exit then
   code INTERNAL INVARIANT x FAILED
   x STOP ;

\ What ended the heartbeat is logged and never changes the exit status.
: HEARTBEAT-ENDED ( ^STATUS:status -- )
   {: s :}
   [: s STATUS:HEARTBEAT-STOP ;] catch {: code :}
   code 0= if exit then
   LOG:WARN s" daemon" LOG:LINE
   s" the runtime status heartbeat failed" LOG:TEXT+
   code CAUSE+ LOG:;LINE ;

\ A heartbeat that does not start was logged by STATUS; the daemon runs
\ on without one.
: BEATING ( ^run -- )
   {: x :}
   x STATUS@ {: s :}
   [: s STATUS:HEARTBEAT-START ;] catch {: code :}
   code 0<> if x GUARDED exit then
   [: x GUARDED ;] [: s HEARTBEAT-ENDED ;] finally ;

\ w waits n ms.
: RUN-IN ( [ n -- ] ^ARENA:arena -- n )
   {: w ar :}
   ar STATUS-FOR w ar NEW-RUN {: x :}
   x BEATING
   x EXIT-STATUS ;

\ A hint can end TASK:WAIT-MS early, so each wait runs to its deadline.
: SLEEPS ( n -- )
   TIME:MONO-NS swap 1000000 * + {: end :}
   begin end TIME:MONO-NS - dup 0 > while
      1000000 / 1 max >MS TASK:WAIT-MS drop
   repeat drop ;

public

\ Runs the daemon until a failure stops it, then answers the exit
\ status: 78 when the user must act, else 70.
: RUN ( -- n )
   0 [: drop [: [: SLEEPS ;] swap RUN-IN ;] ARENA:WITH ;]
   catch {: n code :}
   code 0= if n exit then
   LOG:ERROR s" daemon" LOG:LINE s" daemon stopped: " LOG:TEXT+ INTERNAL
   LOG:TEXT+ code CAUSE+ LOG:;LINE
   70 ;

;package
