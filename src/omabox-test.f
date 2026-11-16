\ omabox-test.f - the omabox program against the Rust version's
\ src/bin/omabox.rs tests, under their names, for the forms it parses:
\ - parser_accepts_documented_forms
\ - parser_rejects_incomplete_or_secret_bearing_forms, each refusal's
\   two log lines checked in a file under TMPDIR
\ - service_commands_reset_the_start_limit_before_a_start, each row's
\   systemctl a script in a directory of its own under TMPDIR, which
\   logs each verb and answers show with the row's state
\ and the program built with README's command into a directory under
\ TMPDIR, whose --version prints its name and version and exits 0.
\ White-box: OMABOX is reopened for PARSE and RUN-SERVICE.
\ Run from the repository root: hb --load src/omabox-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/process.f
require src/lib/process-argv.f
require src/lib/process-env.f
require src/lib/engine-candidate.f
require src/service.f
require src/version.f
require src/omabox.f

package OMABOX
private

8 constant ARG-CAP
ARG-CAP TYPED-BUFFER ARGS str
variable ARGC

4096 constant CAP
CAP BUFFER: OUT
CAP BUFFER: ERR
CAP BUFFER: SEEN
PATH-CAP BUFFER: JOINED

600000 constant BUILD-MS
10000 constant RUN-MS


\ ---- paths, laid in the suite's arena

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u:n ar :}
   ar u ARENA:ALLOC {: d:^ du:n :}
   a d u BYTE-COPY
   d du >str ;

\ dir/name.
: INSIDE ( str ^u8 n ^ARENA:arena -- str )
   {: d n:^ nu:n ar :}
   SB-RESET d str> SB-APPEND s" /" SB-APPEND n nu SB-APPEND
   SB$ ar COPIED ;

\ A new directory under TMPDIR.
: TEMPORARY ( ^ARENA:arena -- str )
   s" omabox-test-" FS:MKTEMP-DIR rot COPIED ;

\ The file's text, empty where there is no file.
: READ ( str -- ^u8 n )
   {: p :}
   p str> FS:TRY-STAT 0= if s" " exit then
   p str> SEEN CAP FS:READ-ALL {: u:n :}
   SEEN u ;


\ ---- arguments

: ARGS-RESET ( -- ) 0 ARGC ! ;

: ARG+ ( ^u8 n -- )
   >str ARGC @ ARGS !
   ARGC @ 1+ ARGC ! ;

: ARG ( n -- ^u8 n ) ARGS @ str> ;

: PARSED ( -- command ) ARGC @ [: ARG ;] PARSE ;

: ONE ( ^u8 n -- ) ARGS-RESET ARG+ ;
: TWO ( ^u8 n ^u8 n -- ) 2swap ONE ARG+ ;


\ ---- the parser

: ACCEPTS ( command -- ) PARSED COMMAND-EQ TTRUE ;

: SERVICE-COMMAND ( SERVICE:action -- command ) COMMAND-SERVICE ;

: PARSER-ACCEPTS-DOCUMENTED-FORMS ( -- )
   s" parser_accepts_documented_forms" T-LABEL
   s" --help" ONE construct command help ACCEPTS
   s" --version" ONE construct command version ACCEPTS
   s" pause" ONE SERVICE-ACTION:STOP SERVICE-COMMAND ACCEPTS
   s" resume" ONE
   SERVICE-ACTION:START SERVICE-COMMAND ACCEPTS
   s" service" s" restart" TWO
   SERVICE-ACTION:RESTART SERVICE-COMMAND ACCEPTS
   s" logs" ONE construct command logs ACCEPTS ;

: LINES ( ^u8 n -- n )
   {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;

\ Whether the log holds "omabox: " t and LF.
: LOGGED? ( ^u8 n ^u8 n -- bool )
   {: a:^ u:n t:^ tu:n :}
   SB-RESET s" omabox: " SB-APPEND t tu SB-APPEND 10 SB-APPEND-C
   a u SB$ CONTAINS? ;

\ The arguments are refused as Usage: the fault m's line, then the help
\ line, captured in the file at p.
: REJECTS ( ^u8 n str ^ARENA:arena -- )
   {: m:^ mu:n p ar :}
   [: PARSED drop ;] p str> ar STDERR:CAPTURING {: code:n e:^ eu:n :}
   code E-USAGE T=
   e eu LINES 2 T=
   e eu m mu LOGGED? TTRUE
   e eu s" help: Run `omabox --help` for usage." LOGGED? TTRUE ;

: PARSER-REJECTS-INCOMPLETE-OR-SECRET-BEARING-FORMS
   ( ^ARENA:arena -- )
   {: ar :}
   s" parser_rejects_incomplete_or_secret_bearing_forms" T-LABEL
   ar TEMPORARY {: d :}
   d s" stderr.txt" ar INSIDE {: p :}
   ARGS-RESET s" a command is required" p ar REJECTS
   s" unknown" ONE s" unknown command" p ar REJECTS
   s" status" s" extra" TWO s" unknown command" p ar REJECTS
   s" pause" s" extra" TWO s" too many arguments" p ar REJECTS
   s" resume" s" extra" TWO s" too many arguments" p ar REJECTS
   s" install" s" extra" TWO s" unknown command" p ar REJECTS
   s" settings" s" set-root" TWO s" unknown command" p ar REJECTS
   s" service" s" unknown" TWO s" unknown service action" p ar REJECTS
   d str> FS:REMOVE-TREE ;


\ ---- the service commands

\ Rust's fake_systemctl: logs each verb to log and answers show with
\ the state.
: FAKE-SYSTEMCTL ( str ^u8 n str -- )
   {: p s:^ su:n log :}
   SB-RESET S\" printf '%s\\n' \"$2\" >> '" SB-APPEND
   log str> SB-APPEND
   S\" '\nif [ \"$2\" = show ]; then printf '%s\\n' " SB-APPEND
   s su SB-APPEND S\" ; fi\nexit 0\n" SB-APPEND
   p str> SB$ FS:WRITE-ALL ;

\ The action run on a unit in the state logs the verbs w.
: RESETS ( SERVICE:action ^u8 n ^u8 n ^ARENA:arena -- )
   {: act s:^ su:n w:^ wu:n ar :}
   ar TEMPORARY {: d :}
   d s" service.log" ar INSIDE {: log :}
   d s" systemctl" ar INSIDE {: sys :}
   sys s su log FAKE-SYSTEMCTL
   sys s" /unused/journalctl" >str ar SERVICE:SCRIPTS {: c :}
   [: c act ar RUN-SERVICE ;] catch 0 T=
   log READ w wu T$=
   d str> FS:REMOVE-TREE ;

: SERVICE-COMMANDS-RESET-THE-START-LIMIT-BEFORE-A-START
   ( ^ARENA:arena -- )
   {: ar :}
   s" service_commands_reset_the_start_limit_before_a_start" T-LABEL
   SERVICE-ACTION:START s" failed"
   S\" reset-failed\nstart\n" ar RESETS
   SERVICE-ACTION:START s" inactive"
   S\" reset-failed\nstart\n" ar RESETS
   SERVICE-ACTION:RESTART s" active"
   S\" reset-failed\nrestart\n" ar RESETS
   SERVICE-ACTION:STOP s" failed"
   S\" show\nreset-failed\n" ar RESETS
   SERVICE-ACTION:STOP s" active"
   S\" show\nstop\nshow\n" ar RESETS
   SERVICE-ACTION:STOP s" inactive" S\" show\n" ar RESETS
   SERVICE-ACTION:STOP s" deactivating"
   S\" show\nstop\nshow\n" ar RESETS ;


\ ---- the built program

: BUILD-ARGS ( str -- )
   {: bin :}
   PROC-ARGV-ENV-RESET
   s" --load" >LEN PROC-ARGV+
   SOURCE-ROOT:ENGINE$ s" tools/hb-build.f" JOINED FS:JOIN-PATH
   {: n:n :} JOINED n >LEN PROC-ARGV+
   s" --" >LEN PROC-ARGV+
   s" src/omabox.f" >LEN PROC-ARGV+
   s" -o" >LEN PROC-ARGV+
   bin str> >LEN PROC-ARGV+
   PROC-ENV-INHERIT-MISSING ;

\ README's command, with this engine's hb and tree, writes bin.
: BUILT? ( str -- bool )
   {: bin :}
   s" hb-build builds omabox" T-LABEL
   bin BUILD-ARGS
   ENGINE-CANDIDATE:PATH$ >LEN OUT CAP >LEN ERR CAP >LEN
   BUILD-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   PROCESS:ENDING>RC RC>N {: outu:len erru:len rc:n :}
   rc 0<> if ERR erru LEN>N type then
   rc 0 T=
   rc 0= ;

: VERSION-PRINTED ( str -- )
   {: bin :}
   s" the built omabox prints its version" T-LABEL
   PROC-ARGV-ENV-RESET
   s" --version" >LEN PROC-ARGV+
   bin str> >LEN OUT CAP >LEN ERR CAP >LEN
   RUN-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   PROCESS:ENDING>RC RC>N {: outu:len erru:len rc:n :}
   rc 0 T=
   OUT outu LEN>N S\" omabox 0.1.0\n" T$=
   erru LEN>N 0 T= ;

: PROGRAM ( ^ARENA:arena -- )
   {: ar :}
   ar TEMPORARY {: d :}
   d s" omabox" ar INSIDE {: bin :}
   [: bin BUILT? if bin VERSION-PRINTED then ;]
   [: d str> FS:REMOVE-TREE ;] finally ;


\ ---- the suite

: SUITE ( ^ARENA:arena -- )
   {: ar :}
   PARSER-ACCEPTS-DOCUMENTED-FORMS
   ar PARSER-REJECTS-INCOMPLETE-OR-SECRET-BEARING-FORMS
   ar SERVICE-COMMANDS-RESET-THE-START-LIMIT-BEFORE-A-START
   ar PROGRAM ;

: RUN-SUITE ( -- )
   T-RESET
   [: SUITE ;] ARENA:WITH
   s" omabox-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN-SUITE

;package
