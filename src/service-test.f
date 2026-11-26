\ service-test.f - SERVICE against the Rust version's service.rs tests,
\ under their names. Each runs systemctl and journalctl as scripts it
\ writes in a directory of its own under TMPDIR, which /bin/sh reads: a
\ recording script writes its arguments to a file there, a scripted
\ systemctl logs each verb and answers each show from a queue there, as
\ the Rust fixtures do; no case reaches the real systemd. A failure's two
\ log lines, Rust's text and help, are checked, captured in the case's
\ directory, and so is what a settle passes on of systemctl's stderr.
\ The walk of every goal from each state runs each drive through a
\ scripted systemctl and checks the verbs it ran against the Rust test's
\ table, one row of which must match each walk. DRIVING's lines are held
\ to formal/ServiceDrive.tla through TEST-FORMAL:HOLDS, which runs TLC.
\ White-box: SERVICE is reopened for control, settle, commands of
\ programs, and the index of a goal or a state.
\ Run from the repository root: hb --load src/service-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/adt/option.f
require src/lib/test/assert.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fmt.f
require src/service.f
require src/test-formal.f

package SERVICE-TEST
;package


\ SERVICE reopened for what a Rust test calls of its private parts; each
\ name lands in SERVICE-TEST.
package SERVICE

ARENA DRIVENS driven

: SERVICE-TEST:DRIVEN ( ^ARENA:arena -- ^driven ) DRIVENS-NEW ;

\ Commands of the programs at the paths, as the Rust test builds them.
: SERVICE-TEST:PROGRAMS ( str str ^ARENA:arena -- ^commands )
   {: s j ar :}
   s SERVICE-LAUNCH:PROGRAM j SERVICE-LAUNCH:PROGRAM ar LAUNCHING ;

: SERVICE-TEST:RESTART ( ^commands -- ) construct action restart CONTROL ;
: SERVICE-TEST:START ( ^commands -- ) construct action start CONTROL ;
: SERVICE-TEST:SETTLE-STOP ( ^commands -- ) SETTLE-STOP ;
: SERVICE-TEST:SETTLE-RESET ( ^commands -- ) SETTLE-RESET ;

\ A state's index in the Rust test's order: running, starting, failed,
\ stopping, stopped.
: SERVICE-TEST:STATE# ( unit-state -- n )
   MATCH unit-state
      running OF 0 ENDOF
      starting OF 1 ENDOF
      failed OF 2 ENDOF
      stopping OF 3 ENDOF
      stopped OF 4 ENDOF
   ;MATCH ;

\ -1 for none.
: SERVICE-TEST:OPTION# ( option<unit-state> -- n )
   MATCH option
      some OF SERVICE-TEST:STATE# ENDOF
      none OF -1 ENDOF
   ;MATCH ;

: SERVICE-TEST:STATE-AT ( n -- unit-state )
   {: i:n :}
   i 0 = if construct unit-state running exit then
   i 1 = if construct unit-state starting exit then
   i 2 = if construct unit-state failed exit then
   i 3 = if construct unit-state stopping exit then
   construct unit-state stopped ;

\ A goal's index in the Rust test's order: start, restart, recover, halt,
\ release, restore of none, then restore of each state.
: SERVICE-TEST:GOAL-AT ( n -- goal )
   {: i:n :}
   i 0 = if construct goal start exit then
   i 1 = if construct goal restart exit then
   i 2 = if construct goal recover exit then
   i 3 = if construct goal halt exit then
   i 4 = if construct goal release exit then
   i 5 = if OPTION:NONE SERVICE-GOAL:RESTORE exit then
   i 6 - SERVICE-TEST:STATE-AT OPTION:SOME SERVICE-GOAL:RESTORE ;

;package


package SERVICE-TEST
private

TYPED-VARIABLE AR ^ARENA:arena
TYPED-VARIABLE DIR str
TYPED-VARIABLE BODY [ -- ]
TYPED-VARIABLE ERR str   \ the captured stderr, in AR


\ ---- strings and files, laid in the case's arena

: KEEP ( str -- str )
   {: s :}
   s STR:len {: u:n :}
   AR @ u ARENA:ALLOC {: d:^ du:n :}
   s STR:data d u BYTE-COPY
   d du >str ;

: CAT ( str str -- str )
   {: a b :}
   a STR:len {: au:n :}
   b STR:len {: bu:n :}
   AR @ au bu + ARENA:ALLOC {: d:^ du:n :}
   a STR:data d au BYTE-COPY
   b STR:data d au + bu BYTE-COPY
   d du >str ;

\ DIR/name.
: UNDER ( str -- str )
   {: n :}
   DIR @ s" /" CAT n CAT ;

\ The path in single quotes, as the scripts name it.
: QUOTED ( str -- str ) {: p :} s" '" p CAT s" '" CAT ;

: WRITE ( str str -- ) FS:WRITE-ALL ;

\ The file's text, empty where there is no file.
: READ ( str -- str )
   {: p :}
   p FS:TRY-STAT 0= if s" " exit then
   AR @ 4096 ARENA:ALLOC {: d:^ du:n :}
   p d du FS:READ-ALL {: u:n :}
   d u >str ;

: FILE= ( str str -- ) {: p w :} p READ w T$= ;

: REMOVE ( str -- )
   {: p :}
   p FS:TRY-STAT if p FS:REMOVE-FILE then ;

: OK ( [ -- ] -- ) catch 0 T= ;


\ ---- the case's frame

: CLEANUP ( -- )
   DIR @ FS:REMOVE-TREE
   AR @ ARENA:RELEASE ;

\ Runs the body with AR and DIR fresh; the directory goes after.
: RUN-CASE ( str [ -- ] -- )
   BODY ! T-LABEL
   ARENA:NEW AR !
   s" TMPDIR" GETENV s" service-test-" FS:MKTEMP-DIR-IN KEEP DIR !
   [: BODY @ execute ;] [: CLEANUP ;] finally ;


\ ---- the log a failure writes

: ERR$ ( -- str ) ERR @ ;
: ERR-PATH ( -- str ) s" stderr.txt" UNDER ;

\ The code the action throws, 0 for none, with fd 2 sent to the case's
\ stderr.txt, which ERR$ then holds and which is removed.
: LOGGED ( [ -- ] -- n )
   ERR-PATH AR @ STDERR:CAPTURING ERR ! ;

: LINES ( str -- n )
   str> {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;

\ The text s ends in SERVICE's tag, t and a newline.
: ENDS? ( str str -- bool )
   {: s t :}
   s str> {: a:^ u:n :}
   s" service: " t CAT s\" \n" CAT {: w :}
   w STR:len {: wu:n :}
   u wu < if false exit then
   a u wu - + wu >str w T-STR= ;

\ The length of s's first line, its newline included.
: FIRST-LINE ( str -- n )
   str> {: a:^ u:n :}
   u 0 ?do a i + c@ 10 = if i 1+ unloop exit then loop
   u ;

\ s is the line t, then the help line h.
: HELPED? ( str str str -- bool )
   {: s t h :}
   s str> {: a:^ u:n :}
   s LINES 2 <> if false exit then
   a s FIRST-LINE >str t ENDS? 0= if false exit then
   s FIRST-LINE {: f:n :}
   a f + u f - >str s" help: " h CAT ENDS? ;

\ Asserts the flag, showing what ERR$ should have held.
: ASSERT-LOG ( bool str -- )
   {: ok:bool t :}
   ok T-ASSERT ok if exit then
   s" want: " type t type cr s" got: " type ERR$ type ;

\ What was logged after the text p: the line t, then the help line h.
: AFTER ( str str str -- )
   {: p t h :}
   p STR:len {: pu:n :}
   ERR$ str> {: e:^ eu:n :}
   eu pu < if false t ASSERT-LOG exit then
   e pu >str p T-STR= TTRUE
   e pu + eu pu - >str t h HELPED?
   t s"  / help: " CAT h CAT ASSERT-LOG ;

\ The action throws the code and logs the line t and the help line h.
: REFUSED ( [ -- ] n str str -- )
   {: xt want:n t h :}
   xt LOGGED want T=
   s" " t h AFTER ;

: START-HELP ( -- str )
   s" Ensure systemd user services and the system journal are available, then retry." ;
: RETRY-HELP ( -- str )
   s" Retry the command; inspect the user session if it happens repeatedly." ;
: REVIEW-HELP ( -- str )
   s" Review the command output and `omabox logs`, then retry." ;
: UPDATE-HELP ( -- str )
   s" Update Omabox, or report this state if Omabox is current." ;

: FAILED-WITH ( str str -- str )
   {: c s :}
   s" `" c CAT s" ` failed with status Some(" CAT s CAT s" )" CAT ;


\ ---- the Rust fixtures

\ DIR/name, holding the text.
: SCRIPT ( str str -- str )
   {: n t :}
   n UNDER {: p :}
   p t WRITE p ;

\ Rust's recording_script: records its arguments in the file out, then
\ exits with the status. It is never executable: /bin/sh reads it.
: RECORDING ( str str str -- str )
   {: n out x :}
   n
   s\" printf '%s\\n' \"$@\" > " out QUOTED CAT
   s\" \nexit " CAT x CAT s\" \n" CAT
   SCRIPT ;

\ Rust's terminating_script.
: TERMINATING ( str -- str ) s\" kill -TERM $$\n" SCRIPT ;

\ Rust's scripted_systemctl: logs each verb to log and answers each show
\ with the next line of DIR/states, which holds the text queue.
: SCRIPTED ( str str -- str )
   {: log queue :}
   s" states" UNDER {: q :}
   q queue WRITE
   q QUOTED {: qq :}
   q s" .next" CAT QUOTED {: qn :}
   s" systemctl"
   s\" printf '%s\\n' \"$2\" >> " log QUOTED CAT
   s\" \nif [ \"$2\" = show ]; then\nhead -n 1 " CAT qq CAT
   s\" \ntail -n +2 " CAT qq CAT s"  > " CAT qn CAT
   s\" \nmv " CAT qn CAT s"  " CAT qq CAT
   s\" \nfi\n" CAT
   SCRIPT ;

: SCRIPTS ( str str -- ^SERVICE:commands ) AR @ SERVICE:SCRIPTS ;
: UNUSED ( -- str ) s" /unused/journalctl" ;

: ARGS= ( str str -- ) FILE= ;

: BOOL= ( bool bool -- )
   {: got:bool want:bool :}
   want if got TTRUE else got TFALSE then ;

: DRIVEN= ( ^SERVICE:driven n n bool bool -- )
   {: v first:n last:n launched:bool acted:bool :}
   v SERVICE-DRIVEN:FIRST @ SERVICE-TEST:OPTION# first T=
   v SERVICE-DRIVEN:LAST @ SERVICE-TEST:OPTION# last T=
   v SERVICE-DRIVEN:LAUNCHED @ launched BOOL=
   v SERVICE-DRIVEN:ACTED @ acted BOOL= ;

-1 constant NONE
0 constant RUNNING
1 constant STARTING
2 constant FAILED
3 constant STOPPING
4 constant STOPPED


\ ---- service_and_log_commands_use_only_documented_arguments

: DOCUMENTED ( -- )
   s" systemctl.args" UNDER {: sa :}
   s" journalctl.args" UNDER {: ja :}
   s" systemctl" sa s" 0" RECORDING {: s :}
   s" journalctl" ja s" 0" RECORDING {: j :}
   s j SCRIPTS {: c :}

   [: c SERVICE-TEST:RESTART ;] OK
   sa s\" --user\nrestart\nomabox.service\n" ARGS=

   \ The recording script prints nothing, which is not a known state.
   [: c SERVICE:STATE drop ;] SERVICE:E-UNKNOWN-STATE
   s" systemd reported the unknown service state ``" UPDATE-HELP
   REFUSED
   sa s\" --user\nshow\n--property=ActiveState\n--value\nomabox.service\n"
   ARGS=

   [: c SERVICE-TEST:SETTLE-RESET ;] OK
   sa s\" --user\nreset-failed\nomabox.service\n" ARGS=

   [: c SERVICE-TEST:SETTLE-STOP ;] OK
   sa s\" --user\nstop\nomabox.service\n" ARGS=

   \ A failed reset-failed asks list-units whether the unit is loaded.
   s" systemctl"
   s\" printf '%s\\n' \"$@\" > " sa QUOTED CAT s\" \nexit 1\n" CAT
   SCRIPT drop
   [: c SERVICE-TEST:SETTLE-RESET ;] SERVICE:E-UNSUCCESSFUL
   s" systemctl reset-failed" s" 1" FAILED-WITH REVIEW-HELP REFUSED
   sa s\" --user\nlist-units\n--all\n--plain\n--no-legend\nomabox.service\n"
   ARGS=

   [: c SERVICE:LOGS ;] OK
   ja s\" --user-unit\nomabox.service\n--no-pager\n--lines\n200\n" ARGS= ;


\ ---- inactive_is_a_state_instead_of_an_error

: INACTIVE ( -- )
   s" systemctl.args" UNDER {: sa :}
   s" systemctl" sa s" 3" RECORDING UNUSED SCRIPTS {: c :}
   [: c SERVICE:STATUS ;] OK
   sa s\" --user\nstatus\n--no-pager\nomabox.service\n" ARGS= ;


\ ---- state_maps_each_active_state

: MAPS ( str n -- )
   {: p want:n :}
   s" systemctl" s\" printf '%s\\n' " p CAT s\" \n" CAT SCRIPT
   UNUSED SCRIPTS {: c :}
   [: c SERVICE:STATE SERVICE-TEST:STATE# want T= ;] OK ;

: STATE-MAPS ( -- )
   s" active" RUNNING MAPS
   s" reloading" RUNNING MAPS
   s" refreshing" RUNNING MAPS
   s" activating" STARTING MAPS
   s" failed" FAILED MAPS
   s" inactive" STOPPED MAPS
   s" deactivating" STOPPING MAPS
   s" maintenance" STOPPED MAPS
   s" systemctl" s\" printf '%s\\n' bogus\n" SCRIPT UNUSED SCRIPTS {: c :}
   [: c SERVICE:STATE drop ;] SERVICE:E-UNKNOWN-STATE
   s" systemd reported the unknown service state `bogus`" UPDATE-HELP
   REFUSED ;


\ ---- every_goal_takes_its_steps_from_each_state

\ Goals by index, as SERVICE-TEST:GOAL-AT reads them.
0 constant START
1 constant RESTART
2 constant RECOVER
3 constant HALT
4 constant RELEASE
5 constant RESTORE-NONE
6 constant RESTORE      \ plus the state's index
11 constant GOALS
5 constant STATES

variable GOAL
variable FIRST
variable SETTLED
variable HITS
TYPED-VARIABLE WANT str
variable CODE            \ what a recorded drive answered

\ A row of the Rust test's table: the goal, the state first observed and
\ the state observed after a stop, NONE matching any, and the verbs the
\ walk runs before Done. It counts when it matches the walk.
: ROW ( n n n str -- )
   {: g:n f:n s:n w :}
   g GOAL @ <> if exit then
   f NONE <> f FIRST @ <> and if exit then
   s NONE <> s SETTLED @ <> and if exit then
   1 HITS +!
   w WANT ! ;

: STOP-LOOK ( -- str ) s\" show\nstop\nshow\n" ;
: STOP-CLEAR ( -- str ) s\" show\nstop\nshow\nreset-failed\n" ;

: TABLE ( -- )
   START NONE NONE s\" reset-failed\nstart\n" ROW
   RESTART NONE NONE s\" reset-failed\nrestart\n" ROW
   RECOVER RUNNING NONE s\" show\n" ROW
   RECOVER STARTING NONE s\" show\n" ROW
   RECOVER FAILED NONE s\" show\nreset-failed\nstart\n" ROW
   RECOVER STOPPED NONE s\" show\n" ROW
   RECOVER STOPPING RUNNING STOP-LOOK ROW
   RECOVER STOPPING STARTING STOP-LOOK ROW
   RECOVER STOPPING FAILED s\" show\nstop\nshow\nreset-failed\nstart\n" ROW
   RECOVER STOPPING STOPPING STOP-LOOK ROW
   RECOVER STOPPING STOPPED STOP-LOOK ROW
   HALT RUNNING RUNNING STOP-LOOK ROW
   HALT RUNNING STARTING STOP-LOOK ROW
   HALT RUNNING FAILED STOP-CLEAR ROW
   HALT RUNNING STOPPING STOP-LOOK ROW
   HALT RUNNING STOPPED STOP-LOOK ROW
   HALT STARTING RUNNING STOP-LOOK ROW
   HALT STARTING STARTING STOP-LOOK ROW
   HALT STARTING FAILED STOP-CLEAR ROW
   HALT STARTING STOPPING STOP-LOOK ROW
   HALT STARTING STOPPED STOP-LOOK ROW
   HALT STOPPING RUNNING STOP-LOOK ROW
   HALT STOPPING STARTING STOP-LOOK ROW
   HALT STOPPING FAILED STOP-CLEAR ROW
   HALT STOPPING STOPPING STOP-LOOK ROW
   HALT STOPPING STOPPED STOP-LOOK ROW
   HALT FAILED NONE s\" show\nreset-failed\n" ROW
   HALT STOPPED NONE s\" show\n" ROW
   RELEASE RUNNING NONE s\" show\nstop\n" ROW
   RELEASE STARTING NONE s\" show\nstop\n" ROW
   RELEASE STOPPING NONE s\" show\nstop\n" ROW
   RELEASE FAILED NONE s\" show\n" ROW
   RELEASE STOPPED NONE s\" show\n" ROW
   RESTORE-NONE NONE NONE s" " ROW
   RESTORE RUNNING + NONE NONE s\" reset-failed\nstart\n" ROW
   RESTORE STARTING + NONE NONE s\" reset-failed\nstart\n" ROW
   RESTORE FAILED + NONE NONE s" " ROW
   RESTORE STOPPING + NONE NONE s" " ROW
   RESTORE STOPPED + NONE NONE s" " ROW ;

\ The ActiveState systemd prints for a state.
: ACTIVE$ ( n -- str )
   case
      RUNNING of s" active" endof
      STARTING of s" activating" endof
      FAILED of s" failed" endof
      STOPPING of s" deactivating" endof
      s" inactive" swap
   endcase ;

: STATE$ ( n -- str )
   case
      RUNNING of s" Running" endof
      STARTING of s" Starting" endof
      FAILED of s" Failed" endof
      STOPPING of s" Stopping" endof
      s" Stopped" swap
   endcase ;

: GOAL$ ( n -- str )
   case
      START of s" Start" endof
      RESTART of s" Restart" endof
      RECOVER of s" Recover" endof
      HALT of s" Halt" endof
      RELEASE of s" Release" endof
      RESTORE-NONE of s" Restore(None)" endof
      dup RESTORE - {: i:n :}
      s" Restore(Some(" i STATE$ CAT s" ))" CAT swap
   endcase ;

\ Drives the goal with first observed, then settled after a stop, and
\ checks the verbs systemctl ran against the one row that matches.
: WALK ( -- )
   GOAL @ GOAL$ s"  seeing " CAT FIRST @ STATE$ CAT
   s"  settling " CAT SETTLED @ STATE$ CAT T-LABEL
   0 HITS ! s" " WANT !
   TABLE
   HITS @ 1 T=
   s" systemctl.log" UNDER {: log :}
   log REMOVE
   FIRST @ ACTIVE$ s\" \n" CAT SETTLED @ ACTIVE$ CAT s\" \n" CAT {: q :}
   log q SCRIPTED UNUSED SCRIPTS {: c :}
   AR @ SERVICE-TEST:DRIVEN {: v :}
   \ Ends at Done: the drive answers no failure.
   c GOAL @ SERVICE-TEST:GOAL-AT v SERVICE:DRIVE-RECORDED 0 T=
   log WANT @ FILE= ;

: EACH-SETTLED ( -- ) STATES 0 ?do i SETTLED ! WALK loop ;
: EACH-FIRST ( -- ) STATES 0 ?do i FIRST ! EACH-SETTLED loop ;
: EVERY-GOAL ( -- ) GOALS 0 ?do i GOAL ! EACH-FIRST loop ;


\ ---- drive_runs_each_step_through_systemctl

: EACH-STEP ( -- )
   s" systemctl.log" UNDER {: log :}
   AR @ SERVICE-TEST:DRIVEN {: v :}

   log s\" active\nfailed\n" SCRIPTED UNUSED SCRIPTS {: c :}
   [: c SERVICE-GOAL:HALT v SERVICE:DRIVE ;] OK
   v RUNNING FAILED false true DRIVEN=
   log s\" show\nstop\nshow\nreset-failed\n" FILE=

   log REMOVE
   log s\" failed\n" SCRIPTED UNUSED SCRIPTS {: c2 :}
   [: c2 SERVICE-GOAL:RECOVER v SERVICE:DRIVE ;] OK
   v FAILED FAILED true true DRIVEN=
   log s\" show\nreset-failed\nstart\n" FILE= ;


\ ---- settling_an_unloaded_unit_succeeds

\ The Rust test's script: refuses the verb on stderr, and lists listed.
: REFUSING ( str str str -- str )
   {: v refusal l :}
   s" systemctl"
   s\" if [ \"$2\" = " v CAT s"  ]; then echo '" CAT refusal CAT
   s\" ' >&2; exit 1; fi\nprintf '" CAT l CAT s\" '\n" CAT
   SCRIPT ;

\ settle runs the verb that names the command.
: UNLOADED-VERB ( str str [ ^SERVICE:commands -- ] -- )
   {: v n settle :}
   v s" Unit omabox.service not loaded." s" " REFUSING
   UNUSED SCRIPTS {: c :}
   [: c settle execute ;] LOGGED 0 T=
   ERR$ s" " T$=

   s" Failed to " v CAT s"  unit omabox.service: Access denied" CAT
   {: refusal :}
   v refusal s\" omabox.service loaded inactive dead Omabox\\n" REFUSING
   UNUSED SCRIPTS {: c2 :}
   [: c2 settle execute ;] LOGGED SERVICE:E-UNSUCCESSFUL T=
   refusal s\" \n" CAT n s" 1" FAILED-WITH REVIEW-HELP AFTER

   s" Warning: The unit file, source configuration file or drop-ins of omabox.service changed on disk."
   {: warning :}
   s" systemctl" s" echo '" warning CAT s\" ' >&2\n" CAT SCRIPT
   UNUSED SCRIPTS {: c3 :}
   [: c3 settle execute ;] LOGGED 0 T=
   ERR$ warning s\" \n" CAT T$= ;

: UNLOADED ( -- )
   s" stop" s" systemctl stop" [: SERVICE-TEST:SETTLE-STOP ;] UNLOADED-VERB
   s" reset-failed" s" systemctl reset-failed"
   [: SERVICE-TEST:SETTLE-RESET ;] UNLOADED-VERB ;


\ ---- a_failed_clear_stops_the_drive

\ The Rust test's script: logs each verb to log, refuses reset-failed
\ and lists listed.
: CLEAR-REFUSING ( str str -- str )
   {: log l :}
   s" systemctl"
   s\" printf '%s\\n' \"$2\" >> " log QUOTED CAT
   s\" \ncase \"$2\" in\nreset-failed) exit 1;;\nlist-units) printf '" CAT
   l CAT s\" ';;\nesac\n" CAT
   SCRIPT ;

: FAILED-CLEAR ( -- )
   s" systemctl.log" UNDER {: log :}
   AR @ SERVICE-TEST:DRIVEN {: v :}

   log s\" omabox.service loaded failed failed Omabox\\n" CLEAR-REFUSING
   UNUSED SCRIPTS {: c :}
   [: c SERVICE-GOAL:START v SERVICE:DRIVE ;] SERVICE:E-UNSUCCESSFUL
   s" systemctl reset-failed" s" 1" FAILED-WITH REVIEW-HELP REFUSED
   log s\" reset-failed\nlist-units\n" FILE=

   log REMOVE
   log s" " CLEAR-REFUSING UNUSED SCRIPTS {: c2 :}
   [: c2 SERVICE-GOAL:START v SERVICE:DRIVE ;] OK
   v NONE NONE true true DRIVEN=
   log s\" reset-failed\nlist-units\nstart\n" FILE=

   \ systemd can unload the unit between the observation and the stop.
   log REMOVE
   s" states" UNDER {: q :}
   q s\" active\ninactive\n" WRITE
   q QUOTED {: qq :}
   q s" .next" CAT QUOTED {: qn :}
   s" systemctl"
   s\" printf '%s\\n' \"$2\" >> " log QUOTED CAT
   s\" \ncase \"$2\" in\nshow) head -n 1 " CAT qq CAT
   s" ; tail -n +2 " CAT qq CAT s"  > " CAT qn CAT
   s" ; mv " CAT qn CAT s"  " CAT qq CAT
   s\" ;;\nstop) exit 5;;\nesac\n" CAT
   SCRIPT UNUSED SCRIPTS {: c3 :}
   [: c3 SERVICE-GOAL:HALT v SERVICE:DRIVE ;] OK
   v RUNNING STOPPED false true DRIVEN=
   log s\" show\nstop\nlist-units\nshow\n" FILE= ;


\ ---- a_systemctl_that_cannot_spawn_has_not_acted

: CANNOT-SPAWN ( -- )
   s" /nonexistent/omabox-test/systemctl"
   s" /nonexistent/omabox-test/journalctl"
   AR @ SERVICE-TEST:PROGRAMS {: c :}
   AR @ SERVICE-TEST:DRIVEN {: v :}
   [: c SERVICE-GOAL:RESTART v SERVICE:DRIVE-RECORDED CODE ! ;] LOGGED 0 T=
   CODE @ SERVICE:E-START-COMMAND T=
   v SERVICE-DRIVEN:ACTED @ TFALSE
   s" " s" could not run `systemctl reset-failed`" START-HELP AFTER ;


\ ---- a_systemctl_that_ran_and_failed_has_acted

: RAN-AND-FAILED ( -- )
   \ The unit stays listed, so the refusal is not an unloaded unit's.
   s" systemctl"
   s\" case \"$2\" in\nreset-failed) exit 1;;\nlist-units) printf 'omabox.service loaded failed failed Omabox\\n';;\nesac\n"
   SCRIPT UNUSED SCRIPTS {: c :}
   AR @ SERVICE-TEST:DRIVEN {: v :}
   [: c SERVICE-GOAL:RESTART v SERVICE:DRIVE-RECORDED CODE ! ;] LOGGED 0 T=
   CODE @ SERVICE:E-UNSUCCESSFUL T=
   v SERVICE-DRIVEN:ACTED @ TTRUE
   s" " s" systemctl reset-failed" s" 1" FAILED-WITH REVIEW-HELP AFTER ;


\ ---- signal_terminated_controls_have_a_distinct_error

: SIGNALED ( -- )
   s" systemctl" TERMINATING s" journalctl" TERMINATING SCRIPTS {: c :}
   [: c SERVICE-TEST:START ;] SERVICE:E-TERMINATED
   s" `systemctl` was terminated before it reported a result"
   RETRY-HELP REFUSED
   [: c SERVICE:LOGS ;] SERVICE:E-TERMINATED
   s" `journalctl` was terminated before it reported a result"
   RETRY-HELP REFUSED ;


\ ---- a_flooding_systemctl_fails_its_wait

\ show writes one byte past what a run keeps of a stream on stdout; stop
\ does so on stderr.
: FLOODED ( -- )
   s" systemctl" s\" head -c 4097 /dev/zero\n" SCRIPT UNUSED SCRIPTS {: c :}
   [: c SERVICE:STATE drop ;] SERVICE:E-WAIT-COMMAND
   s" `systemctl show` was started but could not be waited for"
   RETRY-HELP REFUSED
   s" systemctl" s\" head -c 4097 /dev/zero >&2\n" SCRIPT drop
   [: c SERVICE-TEST:SETTLE-STOP ;] SERVICE:E-WAIT-COMMAND
   s" `systemctl stop` was started but could not be waited for"
   RETRY-HELP REFUSED ;


\ ---- formal_holds_the_drive_table

: FORMAL-HOLDS ( -- )
   s" src/service.f" s" DRIVING" s" ServiceDrive" AR @ TEST-FORMAL:HOLDS ;


public

: RUN ( -- )
   T-RESET
   s" service_and_log_commands_use_only_documented_arguments" ['] DOCUMENTED RUN-CASE
   s" inactive_is_a_state_instead_of_an_error" ['] INACTIVE RUN-CASE
   s" state_maps_each_active_state" ['] STATE-MAPS RUN-CASE
   s" every_goal_takes_its_steps_from_each_state" ['] EVERY-GOAL RUN-CASE
   s" drive_runs_each_step_through_systemctl" ['] EACH-STEP RUN-CASE
   s" settling_an_unloaded_unit_succeeds" ['] UNLOADED RUN-CASE
   s" a_failed_clear_stops_the_drive" ['] FAILED-CLEAR RUN-CASE
   s" a_systemctl_that_cannot_spawn_has_not_acted" ['] CANNOT-SPAWN RUN-CASE
   s" a_systemctl_that_ran_and_failed_has_acted" ['] RAN-AND-FAILED RUN-CASE
   s" signal_terminated_controls_have_a_distinct_error" ['] SIGNALED RUN-CASE
   s" a_flooding_systemctl_fails_its_wait" ['] FLOODED RUN-CASE
   s" formal_holds_the_drive_table" ['] FORMAL-HOLDS RUN-CASE
   s" service-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

SERVICE-TEST:RUN
