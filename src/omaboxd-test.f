\ omaboxd-test.f - the omaboxd program, built with README's command into
\ a directory under TMPDIR and run as a child, as Rust's
\ tests/daemon_startup.rs runs its binary, under their names:
\ - self_check_ignores_unavailable_configuration_and_prints_version
\ - self_check_fails_on_a_full_stdout, Omabox's own: --self-check
\   writing to /dev/full
\ - initialized_journal_and_held_lock_precede_readiness
\ - unavailable_root_still_signals_readiness, its three fixtures
\ A fixture is Rust's StartupFixture: config, state, runtime, an empty
\ PATH directory, the sync root, config.toml and a bound notify socket,
\ in a directory under TMPDIR that the case removes. The child's
\ environment holds only XDG_CONFIG_HOME, XDG_STATE_HOME,
\ XDG_RUNTIME_DIR, PATH and NOTIFY_SOCKET, and its stdio is /dev/null;
\ SIGKILL stops it, as Rust's Child::kill does, and the case reaps it.
\ Run from the repository root: hb --load src/omaboxd-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/ffi-abi.f
require src/lib/process.f
require src/lib/process-argv.f
require src/lib/process-env.f
require src/lib/engine-candidate.f
require src/lib/task.f
require src/lib/time.f
require src/config.f
require src/journal.f
require src/test-client.f
require src/omaboxd.f

package OMABOXD-TEST
private

$10000 constant CAP
CAP BUFFER: OUT
CAP BUFFER: ERR
CAP BUFFER: SEEN
32 constant GOT-CAP
GOT-CAP BUFFER: GOT
PATH-CAP BUFFER: JOINED
110 BUFFER: ADDR                \ a sockaddr_un

600000 constant BUILD-MS
10000 constant SELF-CHECK-MS
3000 constant READY-MS
100 constant QUIET-MS
3000 constant DEADLINE-MS
10 constant NAP-MS
78 constant EXIT-USER-ACTION

PROCESS-SYMBOLS
FUNCTION: SOCKET-CALL socket ( n n n -- i32 ) ;FUNCTION
FUNCTION: BIND-CALL bind ( n ^u8 n -- i32 ) ;FUNCTION
FUNCTION: RECV-CALL recv ( n ^u8 n n -- n ) ;FUNCTION

1 constant AF-UNIX
$80002 constant DGRAM-CLOEXEC   \ SOCK_DGRAM | SOCK_CLOEXEC
$40 constant MSG-DONTWAIT
2 constant O-RDWR

\ The status's last_error texts.
: SYNC-ROOT ( -- ^u8 n )
   s" The configured sync folder is temporarily unavailable." ;
: CONFIGURATION-INVALID ( -- ^u8 n )
   s" Omabox configuration needs attention." ;


\ ---- the build ----

: BUILD-ARGS ( str -- )
   {: bin :}
   PROC-ARGV-ENV-RESET
   s" --load" >LEN PROC-ARGV+
   SOURCE-ROOT:ENGINE$ s" tools/hb-build.f" JOINED FS:JOIN-PATH
   {: n :} JOINED n >LEN PROC-ARGV+
   s" --" >LEN PROC-ARGV+
   s" src/omaboxd.f" >LEN PROC-ARGV+
   s" -o" >LEN PROC-ARGV+
   bin str> >LEN PROC-ARGV+
   PROC-ENV-INHERIT-MISSING ;

\ README's command, with this engine's hb and tree, writes bin.
: BUILT? ( str -- bool )
   {: bin :}
   s" hb-build builds omaboxd" T-LABEL
   bin BUILD-ARGS
   ENGINE-CANDIDATE:PATH$ >LEN OUT CAP >LEN ERR CAP >LEN
   BUILD-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   PROCESS:ENDING>RC RC>N {: outu:len erru:len rc :}
   rc 0<> if ERR erru LEN>N type then
   rc 0 T=
   rc 0= ;


\ ---- the self-check ----

: VERSION-LINE ( -- ^u8 n )
   SB-RESET s" omaboxd " SB-APPEND RELEASE:VERSION$ SB-APPEND 10 SB-APPEND-C SB$ ;

: SELF-CHECK-IGNORES-UNAVAILABLE-CONFIGURATION-AND-PRINTS-VERSION
   ( str -- )
   {: bin :}
   s" self_check_ignores_unavailable_configuration_and_prints_version"
   T-LABEL
   PROC-ARGV-ENV-RESET
   s" --self-check" >LEN PROC-ARGV+
   s" XDG_CONFIG_HOME" >LEN s" relative-and-invalid" >LEN PROC-ENV+
   s" XDG_STATE_HOME" >LEN s" relative-and-invalid" >LEN PROC-ENV+
   bin str> >LEN OUT CAP >LEN ERR CAP >LEN
   SELF-CHECK-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   PROCESS:ENDING>RC RC>N {: outu:len erru:len rc :}
   rc 0 T=
   OUT outu LEN>N VERSION-LINE T$=
   erru LEN>N 0 T= ;

\ How the child ended, its exit code or 128 + its signal; past the
\ self-check's deadline it is killed and reaped, and -1.
: OUTCOME ( pid -- n )
   {: p :}
   p SELF-CHECK-MS >MS PROCESS:WAIT-BOUNDED
   MATCH PROCESS:ending
      exited OF ENDOF
      signaled OF 128 + ENDOF
      timeout OF
         p PROCESS:SIGKILL PROCESS:KILL-RAW drop
         p PROCESS:WAIT drop -1
      ENDOF
   ;MATCH ;

\ ENOSPC on the version line's write: the self-check exits nonzero,
\ neither killed nor hung.
: SELF-CHECK-FAILS-ON-A-FULL-STDOUT ( str -- )
   {: bin :}
   s" self_check_fails_on_a_full_stdout" T-LABEL
   S\" /dev/full\z" drop O-RDWR 0 open {: full :}
   S\" /dev/null\z" drop O-RDWR 0 open {: null :}
   full 0 >= TTRUE
   null 0 >= TTRUE
   bin str> PROCESS:NEW PROCESS:HERMETIC
   s" --self-check" PROCESS:ARG
   0 >FD null >FD PROCESS:FD
   1 >FD full >FD PROCESS:FD
   2 >FD null >FD PROCESS:FD
   PROCESS:SPAWN {: p :}
   full close null close
   p OUTCOME {: rc :}
   rc 0 > rc 128 < and TTRUE ;


\ ---- the fixture ----

\ ended is the child's exit code, or 128 + its signal, once it is
\ reaped, and -1 until then.
STRUCTURE fixture DERIVE addr
   FIELD dir str
   FIELD config ^CONFIG:config
   FIELD config-home str
   FIELD state-home str
   FIELD runtime str
   FIELD command-path str
   FIELD notify-path str
   FIELD notify n
   FIELD pid n
   FIELD ended n
;STRUCTURE

ARENA FIXTURES fixture

: MADE ( str ^u8 n ^ARENA:arena -- str )
   TEST-CLIENT:INSIDE dup str> FS:MAKE-DIR ;

\ sockaddr_un for path; answers its length.
: ADDRESS ( ^u8 n -- n )
   {: p:^ u:n :}
   u 108 < TTRUE
   AF-UNIX ADDR c! 0 ADDR 1 + c!
   p ADDR 2 + u BYTE-COPY 0 ADDR 2 + u + c!
   u 3 + ;

: BOUND ( str -- n )
   {: p :}
   AF-UNIX DGRAM-CLOEXEC 0 SOCKET-CALL {: fd :}
   fd 0 >= TTRUE
   fd ADDR p str> ADDRESS BIND-CALL 0 T=
   fd ;

\ config.toml as Rust's Config::write_new writes it.
: WRITE-CONFIG ( ^fixture ^ARENA:arena -- )
   {: x ar :}
   x FIXTURE-CONFIG-HOME @ s" omabox" ar TEST-CLIENT:INSIDE FS:MAKE-DIRS
   x FIXTURE-CONFIG-HOME @ s" omabox/config.toml" ar TEST-CLIENT:INSIDE
   {: file :}
   SB-RESET S\" sync_root = \q" SB-APPEND
   x FIXTURE-CONFIG @ CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR str> SB-APPEND
   S\" \q\ndropbox_app_key = \qtest-app-key\q\n" SB-APPEND
   file str> SB$ FS:WRITE-ALL ;

: CONFIGURED ( ^fixture str ^ARENA:arena -- )
   {: x root ar :}
   x FIXTURE-CONFIG-HOME @ CONFIG:>ABS-PATH
   x FIXTURE-STATE-HOME @ CONFIG:>ABS-PATH ar CONFIG:XDG-NEW {: xdg :}
   xdg root s" test-app-key" >str ar CONFIG:FROM-VALUES
   x FIXTURE-CONFIG !
   x ar WRITE-CONFIG ;

: NEW-FIXTURE ( ^ARENA:arena -- ^fixture )
   {: ar :}
   ar FIXTURES-NEW {: x :}
   s" omaboxd-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: d :}
   d x FIXTURE-DIR !
   -1 x FIXTURE-ENDED !
   d s" config" ar TEST-CLIENT:INSIDE x FIXTURE-CONFIG-HOME !
   d s" state" ar TEST-CLIENT:INSIDE x FIXTURE-STATE-HOME !
   d s" runtime" ar MADE x FIXTURE-RUNTIME !
   d s" empty-bin" ar MADE x FIXTURE-COMMAND-PATH !
   x d s" Dropbox" ar MADE ar CONFIGURED
   d s" notify.sock" ar TEST-CLIENT:INSIDE {: sock :}
   sock x FIXTURE-NOTIFY-PATH !
   sock BOUND x FIXTURE-NOTIFY !
   x ;

: ROOT$ ( ^fixture -- ^u8 n )
   FIXTURE-CONFIG @ CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR str> ;

: PATHS ( ^fixture -- ^CONFIG:paths ) FIXTURE-CONFIG @ CONFIG:PATHS ;

: JOURNAL$ ( ^fixture -- ^u8 n )
   PATHS CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR str> ;

\ The bytes of one datagram in GOT, or -1 when none came within n ms.
: RECEIVED ( ^fixture n -- n )
   {: x ms :}
   x FIXTURE-NOTIFY @ {: fd :}
   fd >FD ms >MS PROCESS:POLL-IN COUNT>N 0 <= if -1 exit then
   fd GOT GOT-CAP MSG-DONTWAIT RECV-CALL ;

: READY ( ^fixture -- )
   READY-MS RECEIVED {: n :}
   GOT n 0 max s" READY=1" T$= ;

\ The lock is another daemon's: CONFIG:LOCK refuses it.
: LOCK-HELD ( ^fixture ^ARENA:arena -- )
   {: x ar :}
   x PATHS {: p :}
   [: p CONFIG:LOCK CONFIG:UNLOCK ;]
   x FIXTURE-DIR @ s" lock-stderr.txt" ar TEST-CLIENT:INSIDE ar
   STDERR:CAPTURING drop
   CONFIG:E-ALREADY-RUNNING T= ;

\ Whether the status's file holds last_error t.
: SAYS? ( ^fixture ^u8 n ^ARENA:arena -- bool )
   {: x t:^ tu ar :}
   x FIXTURE-RUNTIME @ s" omabox/status.json" ar TEST-CLIENT:INSIDE {: f :}
   f FS:FILE? 0= if false exit then
   f str> SEEN CAP FS:READ-ALL {: u :}
   SB-RESET S\" \qlast_error\q:" SB-APPEND t tu TEST-CLIENT:QUOTED+
   SEEN u SB$ CONTAINS? ;


\ ---- the child ----

: SPAWNED ( ^fixture str -- )
   {: x bin :}
   S\" /dev/null\z" drop O-RDWR 0 open {: null :}
   null 0 >= TTRUE
   bin str> PROCESS:NEW PROCESS:HERMETIC
   s" XDG_CONFIG_HOME" x FIXTURE-CONFIG-HOME @ str> PROCESS:ENV
   s" XDG_STATE_HOME" x FIXTURE-STATE-HOME @ str> PROCESS:ENV
   s" XDG_RUNTIME_DIR" x FIXTURE-RUNTIME @ str> PROCESS:ENV
   s" PATH" x FIXTURE-COMMAND-PATH @ str> PROCESS:ENV
   s" NOTIFY_SOCKET" x FIXTURE-NOTIFY-PATH @ str> PROCESS:ENV
   0 >FD null >FD PROCESS:FD
   1 >FD null >FD PROCESS:FD
   2 >FD null >FD PROCESS:FD
   PROCESS:SPAWN PID>N x FIXTURE-PID !
   null close ;

: ENDED? ( PROCESS:ending -- bool )
   MATCH PROCESS:ending
      exited OF drop true ENDOF
      signaled OF drop true ENDOF
      timeout OF false ENDOF
   ;MATCH ;

\ Reaps the child if it has ended.
: RUNNING? ( ^fixture -- bool )
   {: x :}
   x FIXTURE-ENDED @ 0 >= if false exit then
   x FIXTURE-PID @ >PID 0 >MS PROCESS:WAIT-BOUNDED {: e :}
   e ENDED? 0= if true exit then
   e PROCESS:ENDING>RC RC>N x FIXTURE-ENDED !
   false ;

\ Stops the child with SIGKILL unless it has ended; answers how it ended.
: TERMINATE ( ^fixture -- n )
   {: x :}
   x RUNNING? if
      x FIXTURE-PID @ >PID {: p :}
      p PROCESS:SIGKILL PROCESS:KILL-RAW drop
      p PROCESS:WAIT PROCESS:STATUS>RC RC>N x FIXTURE-ENDED !
   then
   x FIXTURE-ENDED @ ;

\ Stops a spawned child, then removes the fixture.
: GONE ( ^fixture -- )
   {: x :}
   x FIXTURE-PID @ 0 > if x TERMINATE drop then
   x FIXTURE-NOTIFY @ close
   x FIXTURE-DIR @ str> FS:REMOVE-TREE ;

: FIXTURED ( [ ^fixture ^ARENA:arena -- ] ^ARENA:arena -- )
   {: q ar :}
   ar NEW-FIXTURE {: x :}
   [: x ar q execute ;] [: x GONE ;] finally ;

\ Runs the case's body on a fresh fixture, removed after.
: WITH-FIXTURE ( [ ^fixture ^ARENA:arena -- ] -- )
   [: FIXTURED ;] ARENA:WITH ;

: DEADLINE ( -- n ) DEADLINE-MS 1000000 * TIME:MONO-NS + ;
: PAST? ( n -- bool ) TIME:MONO-NS <= ;
: NAP ( -- ) NAP-MS >MS TASK:SLEEP ;

\ Whether the status says t before the deadline.
: AWAITED ( ^fixture ^u8 n ^ARENA:arena -- bool )
   {: x t:^ tu ar :}
   DEADLINE {: end :}
   begin x t tu ar SAYS? 0= while
      end PAST? if false exit then
      NAP
   repeat true ;

\ Until the child ends or the deadline passes.
: SETTLED ( ^fixture -- )
   {: x :}
   DEADLINE {: end :}
   begin x RUNNING? end PAST? 0= and while NAP repeat ;


\ ---- startup ----

: INITIALIZED ( ^fixture ^ARENA:arena str -- )
   {: x ar bin :}
   x bin SPAWNED
   x READY
   x ar LOCK-HELD
   x JOURNAL$ >str FS:FILE? TTRUE
   x RUNNING? TTRUE
   x TERMINATE drop
   [: x JOURNAL$ >str JOURNAL:OPEN JOURNAL:CLOSE ;] catch 0 T= ;

: INITIALIZED-JOURNAL-AND-HELD-LOCK-PRECEDE-READINESS ( str -- )
   {: bin :}
   s" initialized_journal_and_held_lock_precede_readiness" T-LABEL
   [: bin INITIALIZED ;] WITH-FIXTURE ;

\ The root removed, or a link to a missing sibling when dangling.
: UNAVAILABLE ( ^fixture ^ARENA:arena str bool -- )
   {: x ar bin dangling :}
   x ROOT$ >str FS:REMOVE-DIR
   dangling if
      x FIXTURE-DIR @ s" missing" ar TEST-CLIENT:INSIDE
      x ROOT$ >str FS:MAKE-SYMLINK
   then
   x bin SPAWNED
   x READY
   x RUNNING? TTRUE
   x ar LOCK-HELD
   x JOURNAL$ >str FS:FILE? TTRUE
   x SYNC-ROOT ar AWAITED TTRUE
   x RUNNING? TTRUE
   x TERMINATE drop ;

\ A link to the state directory, which would hold the state once it
\ appears: refused before readiness.
: CONTAINING ( ^fixture ^ARENA:arena str -- )
   {: x ar bin :}
   x ROOT$ >str FS:REMOVE-DIR
   x FIXTURE-STATE-HOME @ x ROOT$ >str FS:MAKE-SYMLINK
   x bin SPAWNED
   x SETTLED
   x TERMINATE EXIT-USER-ACTION T=
   x QUIET-MS RECEIVED -1 T=
   x FIXTURE-STATE-HOME @ FS:EXISTS? TFALSE
   x CONFIGURATION-INVALID ar SAYS? TTRUE ;

: UNAVAILABLE-ROOT-STILL-SIGNALS-READINESS ( str -- )
   {: bin :}
   s" unavailable_root_still_signals_readiness" T-LABEL
   [: bin false UNAVAILABLE ;] WITH-FIXTURE
   [: bin true UNAVAILABLE ;] WITH-FIXTURE
   [: bin CONTAINING ;] WITH-FIXTURE ;


\ ---- the suite ----

: CASES ( str -- )
   {: bin :}
   bin SELF-CHECK-IGNORES-UNAVAILABLE-CONFIGURATION-AND-PRINTS-VERSION
   bin SELF-CHECK-FAILS-ON-A-FULL-STDOUT
   bin INITIALIZED-JOURNAL-AND-HELD-LOCK-PRECEDE-READINESS
   bin UNAVAILABLE-ROOT-STILL-SIGNALS-READINESS ;

: SUITE ( ^ARENA:arena -- )
   {: ar :}
   s" omaboxd-test" FS:MKTEMP-DIR ar TEST-CLIENT:COPIED {: d :}
   d s" bin" ar MADE s" omaboxd" ar TEST-CLIENT:INSIDE {: bin :}
   [: bin BUILT? if bin CASES then ;]
   [: d str> FS:REMOVE-TREE ;] finally ;

: RUN-SUITE ( -- )
   T-RESET
   [: SUITE ;] ARENA:WITH
   s" omaboxd-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN-SUITE

;package
