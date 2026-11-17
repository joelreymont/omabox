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
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
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
PTR-VARIABLE ERR         \ the captured stderr, in AR
variable ERR-U


\ ---- strings and files, laid in the case's arena

: KEEP ( ^u8 n -- str )
   {: a:^ u:n :}
   AR @ u ARENA:ALLOC {: d:^ du:n :}
   a d u BYTE-COPY
   d du >str ;

: CAT ( str str -- str )
   {: a b :}
   a str> {: ap:^ au:n :}
   b str> {: bp:^ bu:n :}
   AR @ au bu + ARENA:ALLOC {: d:^ du:n :}
   ap d au BYTE-COPY
   bp d au + bu BYTE-COPY
   d du >str ;

: S+ ( str ^u8 n -- str ) >str CAT ;

\ DIR/name.
: UNDER ( ^u8 n -- str )
   {: n:^ u:n :}
   DIR @ s" /" S+ n u S+ ;

\ The path in single quotes, as the scripts name it.
: QUOTED ( str -- str ) {: p :} s" '" >str p CAT s" '" S+ ;

: WRITE ( str str -- ) {: p t :} p str> t str> FS:WRITE-ALL ;

\ The file's text, empty where there is no file.
: READ ( str -- ^u8 n )
   {: p :}
   p str> FS:TRY-STAT 0= if s" " exit then
   AR @ 4096 ARENA:ALLOC {: d:^ du:n :}
   p str> d du FS:READ-ALL {: u:n :}
   d u ;

: FILE= ( str ^u8 n -- ) {: p w:^ wu:n :} p READ w wu T$= ;

: REMOVE ( str -- )
   {: p :}
   p str> FS:TRY-STAT if p str> FS:REMOVE-FILE then ;

: OK ( [ -- ] -- ) catch 0 T= ;


\ ---- the case's frame

: CLEANUP ( -- )
   DIR @ str> FS:REMOVE-TREE
   AR @ ARENA:RELEASE ;

\ Runs the body with AR and DIR fresh; the directory goes after.
: RUN-CASE ( ^u8 n [ -- ] -- )
   BODY ! T-LABEL
   ARENA:NEW AR !
   s" TMPDIR" GETENV s" service-test-" FS:MKTEMP-DIR-IN KEEP DIR !
   [: BODY @ execute ;] [: CLEANUP ;] finally ;


\ ---- the log a failure writes

: ERR$ ( -- ^u8 n ) ERR @ ERR-U @ ;
: ERR-PATH ( -- str ) s" stderr.txt" UNDER ;

\ The code the action throws, 0 for none, with fd 2 sent to the case's
\ stderr.txt, which ERR$ then holds and which is removed.
: LOGGED ( [ -- ] -- n )
   ERR-PATH str> AR @ STDERR:CAPTURING ERR-U ! ERR ! ;

: LINES ( ^u8 n -- n )
   {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;

\ The text a u ends in SERVICE's tag, t and a newline.
: ENDS? ( ^u8 n str -- bool )
   {: a:^ u:n t :}
   s" service: " >str t CAT s\" \n" S+ str> {: w:^ wu:n :}
   u wu < if false exit then
   a u wu - + wu w wu T-STR= ;

\ The length of a u's first line, its newline included.
: FIRST-LINE ( ^u8 n -- n )
   {: a:^ u:n :}
   u 0 ?do a i + c@ 10 = if i 1+ unloop exit then loop
   u ;

\ a u is the line t, then the help line h.
: HELPED? ( ^u8 n str str -- bool )
   {: a:^ u:n t h :}
   a u LINES 2 <> if false exit then
   a a u FIRST-LINE t ENDS? 0= if false exit then
   a u FIRST-LINE {: f:n :}
   a f + u f - s" help: " >str h CAT ENDS? ;

\ Asserts the flag, showing what ERR$ should have held.
: ASSERT-LOG ( bool str -- )
   {: ok:bool t :}
   ok T-ASSERT ok if exit then
   s" want: " type t str> type cr s" got: " type ERR$ type ;

\ What was logged after the text p: the line t, then the help line h.
: AFTER ( ^u8 n str str -- )
   {: p:^ pu:n t h :}
   ERR-U @ pu < if false t ASSERT-LOG exit then
   ERR @ pu p pu T-STR= TTRUE
   ERR @ pu + ERR-U @ pu - t h HELPED?
   t s"  / help: " S+ h CAT ASSERT-LOG ;

\ The action throws the code and logs the line t and the help line h.
: REFUSED ( [ -- ] n str str -- )
   {: xt want:n t h :}
   xt LOGGED want T=
   s" " t h AFTER ;

: START-HELP ( -- str )
   s" Ensure systemd user services and the system journal are available, then retry." >str ;
: RETRY-HELP ( -- str )
   s" Retry the command; inspect the user session if it happens repeatedly." >str ;
: REVIEW-HELP ( -- str )
   s" Review the command output and `omabox logs`, then retry." >str ;
: UPDATE-HELP ( -- str )
   s" Update Omabox, or report this state if Omabox is current." >str ;

: FAILED-WITH ( ^u8 n ^u8 n -- str )
   {: c:^ cu:n s:^ su:n :}
   s" `" >str c cu S+ s" ` failed with status Some(" S+ s su S+ s" )" S+ ;


\ ---- the Rust fixtures

\ DIR/name, holding the text.
: SCRIPT ( ^u8 n str -- str )
   {: n:^ nu:n t :}
   n nu UNDER {: p :}
   p t WRITE p ;

\ Rust's recording_script: records its arguments in the file out, then
\ exits with the status. It is never executable: /bin/sh reads it.
: RECORDING ( ^u8 n str ^u8 n -- str )
   {: n:^ nu:n out x:^ xu:n :}
   n nu
   s\" printf '%s\\n' \"$@\" > " >str out QUOTED CAT
   s\" \nexit " S+ x xu S+ s\" \n" S+
   SCRIPT ;

\ Rust's terminating_script.
: TERMINATING ( ^u8 n -- str ) s\" kill -TERM $$\n" >str SCRIPT ;

\ Rust's scripted_systemctl: logs each verb to log and answers each show
\ with the next line of DIR/states, which holds the text queue.
: SCRIPTED ( str str -- str )
   {: log queue :}
   s" states" UNDER {: q :}
   q queue WRITE
   q QUOTED {: qq :}
   q s" .next" S+ QUOTED {: qn :}
   s" systemctl"
   s\" printf '%s\\n' \"$2\" >> " >str log QUOTED CAT
   s\" \nif [ \"$2\" = show ]; then\nhead -n 1 " S+ qq CAT
   s\" \ntail -n +2 " S+ qq CAT s"  > " S+ qn CAT
   s\" \nmv " S+ qn CAT s"  " S+ qq CAT
   s\" \nfi\n" S+
   SCRIPT ;

: SCRIPTS ( str str -- ^SERVICE:commands ) AR @ SERVICE:SCRIPTS ;
: UNUSED ( -- str ) s" /unused/journalctl" >str ;

: ARGS= ( str ^u8 n -- ) FILE= ;

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
   s" systemd reported the unknown service state ``" >str UPDATE-HELP
   REFUSED
   sa s\" --user\nshow\n--property=ActiveState\n--value\nomabox.service\n"
   ARGS=

   [: c SERVICE-TEST:SETTLE-RESET ;] OK
   sa s\" --user\nreset-failed\nomabox.service\n" ARGS=

   [: c SERVICE-TEST:SETTLE-STOP ;] OK
   sa s\" --user\nstop\nomabox.service\n" ARGS=

   \ A failed reset-failed asks list-units whether the unit is loaded.
   s" systemctl"
   s\" printf '%s\\n' \"$@\" > " >str sa QUOTED CAT s\" \nexit 1\n" S+
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

: MAPS ( ^u8 n n -- )
   {: p:^ pu:n want:n :}
   s" systemctl" s\" printf '%s\\n' " >str p pu S+ s\" \n" S+ SCRIPT
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
   s" systemctl" s\" printf '%s\\n' bogus\n" >str SCRIPT UNUSED SCRIPTS {: c :}
   [: c SERVICE:STATE drop ;] SERVICE:E-UNKNOWN-STATE
   s" systemd reported the unknown service state `bogus`" >str UPDATE-HELP
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
: ROW ( n n n ^u8 n -- )
   {: g:n f:n s:n w:^ wu:n :}
   g GOAL @ <> if exit then
   f NONE <> f FIRST @ <> and if exit then
   s NONE <> s SETTLED @ <> and if exit then
   1 HITS +!
   w wu >str WANT ! ;

: STOP-LOOK ( -- ^u8 n ) s\" show\nstop\nshow\n" ;
: STOP-CLEAR ( -- ^u8 n ) s\" show\nstop\nshow\nreset-failed\n" ;

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
: ACTIVE$ ( n -- ^u8 n )
   case
      RUNNING of s" active" endof
      STARTING of s" activating" endof
      FAILED of s" failed" endof
      STOPPING of s" deactivating" endof
      s" inactive" rot
   endcase ;

: STATE$ ( n -- ^u8 n )
   case
      RUNNING of s" Running" endof
      STARTING of s" Starting" endof
      FAILED of s" Failed" endof
      STOPPING of s" Stopping" endof
      s" Stopped" rot
   endcase ;

: GOAL$ ( n -- str )
   case
      START of s" Start" >str endof
      RESTART of s" Restart" >str endof
      RECOVER of s" Recover" >str endof
      HALT of s" Halt" >str endof
      RELEASE of s" Release" >str endof
      RESTORE-NONE of s" Restore(None)" >str endof
      dup RESTORE - {: i:n :}
      s" Restore(Some(" >str i STATE$ S+ s" ))" S+ swap
   endcase ;

\ Drives the goal with first observed, then settled after a stop, and
\ checks the verbs systemctl ran against the one row that matches.
: WALK ( -- )
   GOAL @ GOAL$ s"  seeing " S+ FIRST @ STATE$ S+
   s"  settling " S+ SETTLED @ STATE$ S+ str> T-LABEL
   0 HITS ! s" " >str WANT !
   TABLE
   HITS @ 1 T=
   s" systemctl.log" UNDER {: log :}
   log REMOVE
   FIRST @ ACTIVE$ >str s\" \n" S+ SETTLED @ ACTIVE$ S+ s\" \n" S+ {: q :}
   log q SCRIPTED UNUSED SCRIPTS {: c :}
   AR @ SERVICE-TEST:DRIVEN {: v :}
   \ Ends at Done: the drive answers no failure.
   c GOAL @ SERVICE-TEST:GOAL-AT v SERVICE:DRIVE-RECORDED 0 T=
   log WANT @ str> FILE= ;

: EACH-SETTLED ( -- ) STATES 0 ?do i SETTLED ! WALK loop ;
: EACH-FIRST ( -- ) STATES 0 ?do i FIRST ! EACH-SETTLED loop ;
: EVERY-GOAL ( -- ) GOALS 0 ?do i GOAL ! EACH-FIRST loop ;


\ ---- drive_runs_each_step_through_systemctl

: EACH-STEP ( -- )
   s" systemctl.log" UNDER {: log :}
   AR @ SERVICE-TEST:DRIVEN {: v :}

   log s\" active\nfailed\n" >str SCRIPTED UNUSED SCRIPTS {: c :}
   [: c SERVICE-GOAL:HALT v SERVICE:DRIVE ;] OK
   v RUNNING FAILED false true DRIVEN=
   log s\" show\nstop\nshow\nreset-failed\n" FILE=

   log REMOVE
   log s\" failed\n" >str SCRIPTED UNUSED SCRIPTS {: c2 :}
   [: c2 SERVICE-GOAL:RECOVER v SERVICE:DRIVE ;] OK
   v FAILED FAILED true true DRIVEN=
   log s\" show\nreset-failed\nstart\n" FILE= ;


\ ---- settling_an_unloaded_unit_succeeds

\ The Rust test's script: refuses the verb on stderr, and lists listed.
: REFUSING ( ^u8 n str ^u8 n -- str )
   {: v:^ vu:n refusal l:^ lu:n :}
   s" systemctl"
   s\" if [ \"$2\" = " >str v vu S+ s"  ]; then echo '" S+ refusal CAT
   s\" ' >&2; exit 1; fi\nprintf '" S+ l lu S+ s\" '\n" S+
   SCRIPT ;

\ settle runs the verb that names the command.
: UNLOADED-VERB ( ^u8 n ^u8 n [ ^SERVICE:commands -- ] -- )
   {: v:^ vu:n n:^ nu:n settle :}
   v vu s" Unit omabox.service not loaded." >str s" " REFUSING
   UNUSED SCRIPTS {: c :}
   [: c settle execute ;] LOGGED 0 T=
   ERR$ s" " T$=

   s" Failed to " >str v vu S+ s"  unit omabox.service: Access denied" S+
   {: refusal :}
   v vu refusal s\" omabox.service loaded inactive dead Omabox\\n" REFUSING
   UNUSED SCRIPTS {: c2 :}
   [: c2 settle execute ;] LOGGED SERVICE:E-UNSUCCESSFUL T=
   refusal s\" \n" S+ str> n nu s" 1" FAILED-WITH REVIEW-HELP AFTER

   s" Warning: The unit file, source configuration file or drop-ins of omabox.service changed on disk."
   >str {: warning :}
   s" systemctl" s" echo '" >str warning CAT s\" ' >&2\n" S+ SCRIPT
   UNUSED SCRIPTS {: c3 :}
   [: c3 settle execute ;] LOGGED 0 T=
   ERR$ warning s\" \n" S+ str> T$= ;

: UNLOADED ( -- )
   s" stop" s" systemctl stop" [: SERVICE-TEST:SETTLE-STOP ;] UNLOADED-VERB
   s" reset-failed" s" systemctl reset-failed"
   [: SERVICE-TEST:SETTLE-RESET ;] UNLOADED-VERB ;


\ ---- a_failed_clear_stops_the_drive

\ The Rust test's script: logs each verb to log, refuses reset-failed
\ and lists listed.
: CLEAR-REFUSING ( str ^u8 n -- str )
   {: log l:^ lu:n :}
   s" systemctl"
   s\" printf '%s\\n' \"$2\" >> " >str log QUOTED CAT
   s\" \ncase \"$2\" in\nreset-failed) exit 1;;\nlist-units) printf '" S+
   l lu S+ s\" ';;\nesac\n" S+
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
   q s\" active\ninactive\n" >str WRITE
   q QUOTED {: qq :}
   q s" .next" S+ QUOTED {: qn :}
   s" systemctl"
   s\" printf '%s\\n' \"$2\" >> " >str log QUOTED CAT
   s\" \ncase \"$2\" in\nshow) head -n 1 " S+ qq CAT
   s" ; tail -n +2 " S+ qq CAT s"  > " S+ qn CAT
   s" ; mv " S+ qn CAT s"  " S+ qq CAT
   s\" ;;\nstop) exit 5;;\nesac\n" S+
   SCRIPT UNUSED SCRIPTS {: c3 :}
   [: c3 SERVICE-GOAL:HALT v SERVICE:DRIVE ;] OK
   v RUNNING STOPPED false true DRIVEN=
   log s\" show\nstop\nlist-units\nshow\n" FILE= ;


\ ---- a_systemctl_that_cannot_spawn_has_not_acted

: CANNOT-SPAWN ( -- )
   s" /nonexistent/omabox-test/systemctl" >str
   s" /nonexistent/omabox-test/journalctl" >str
   AR @ SERVICE-TEST:PROGRAMS {: c :}
   AR @ SERVICE-TEST:DRIVEN {: v :}
   [: c SERVICE-GOAL:RESTART v SERVICE:DRIVE-RECORDED CODE ! ;] LOGGED 0 T=
   CODE @ SERVICE:E-START-COMMAND T=
   v SERVICE-DRIVEN:ACTED @ TFALSE
   s" " s" could not run `systemctl reset-failed`" >str START-HELP AFTER ;


\ ---- a_systemctl_that_ran_and_failed_has_acted

: RAN-AND-FAILED ( -- )
   \ The unit stays listed, so the refusal is not an unloaded unit's.
   s" systemctl"
   s\" case \"$2\" in\nreset-failed) exit 1;;\nlist-units) printf 'omabox.service loaded failed failed Omabox\\n';;\nesac\n"
   >str SCRIPT UNUSED SCRIPTS {: c :}
   AR @ SERVICE-TEST:DRIVEN {: v :}
   [: c SERVICE-GOAL:RESTART v SERVICE:DRIVE-RECORDED CODE ! ;] LOGGED 0 T=
   CODE @ SERVICE:E-UNSUCCESSFUL T=
   v SERVICE-DRIVEN:ACTED @ TTRUE
   s" " s" systemctl reset-failed" s" 1" FAILED-WITH REVIEW-HELP AFTER ;


\ ---- signal_terminated_controls_have_a_distinct_error

: SIGNALED ( -- )
   s" systemctl" TERMINATING s" journalctl" TERMINATING SCRIPTS {: c :}
   [: c SERVICE-TEST:START ;] SERVICE:E-TERMINATED
   s" `systemctl` was terminated before it reported a result" >str
   RETRY-HELP REFUSED
   [: c SERVICE:LOGS ;] SERVICE:E-TERMINATED
   s" `journalctl` was terminated before it reported a result" >str
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
   s" formal_holds_the_drive_table" ['] FORMAL-HOLDS RUN-CASE
   s" service-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

SERVICE-TEST:RUN
