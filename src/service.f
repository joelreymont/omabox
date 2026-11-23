\ service.f - package SERVICE: the Omabox systemd user unit, controlled
\ and inspected through systemctl and journalctl as the Rust version's
\ service.rs does, and a launch, spawn.rs's way of starting a program.
\ DRIVE moves the unit toward a goal through the machine DRIVING, whose
\ states are Rust's phases. Each state's step word is Rust's next for that
\ state: from the goal and the unit state last observed it answers the step
\ to run, and the step's line names the next state; a step that throws ends
\ the drive, as Rust's loop breaks on an error.
\ systemd's activating includes the wait before an automatic restart, and
\ deactivating can still end failed; systemd unloads a disabled, stopped unit.
\ recover follows a change that may fix a fatal cause. release stops a
\ unit that can hold the instance lock and leaves its failed state for a
\ later recover.
\ A child's stdio is Rust's: inherited for a control, status, logs and
\ daemon-reload; stdout and stderr /dev/null for is-enabled; stdin and
\ stderr /dev/null and stdout read for show and list-units; stdin and stdout
\ /dev/null and stderr read for stop and reset-failed.
\ A failure logs two lines, the Rust error's text with the command it
\ names and then its help, and throws. E-START-COMMAND is a failure before
\ the child ran, so a drive does not count it as acted; E-WAIT-COMMAND one
\ after.
\ STORAGE CLASS. CALLER-OWNED: commands, with copies of their scripts'
\ paths, live in the arena the caller passes; a driven record is the
\ caller's. Each run owns an arena, released on return, that holds what
\ its child wrote; each drive owns one that holds its state.
\ PROCESS-WIDE: FOUND, a program's path as PATH resolves it; one run uses
\ it at a time, on the main thread.

require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/span.f
require src/lib/adt/option.f
require src/lib/log.f
require src/lib/fd.f
require src/lib/spawn.f
require src/lib/process.f
require src/lib/process-env.f
require src/lib/utf8-scalar.f
require src/lib/utf8-lossy.f
require src/lib/unicode/class.f
require src/lib/fsm.f

package SERVICE
public

-101000 constant E-FIRST
-101099 constant E-LAST
-101000 s" a system command could not be spawned"
   ERROR:CODE E-START-COMMAND
-101001 s" a system command was started but could not be waited for"
   ERROR:CODE E-WAIT-COMMAND
-101002 s" a system command was terminated by a signal"
   ERROR:CODE E-TERMINATED
-101003 s" a system command reported failure" ERROR:CODE E-UNSUCCESSFUL
-101004 s" systemd reported an ActiveState this version does not know"
   ERROR:CODE E-UNKNOWN-STATE

\ A program, found through PATH when its path holds no slash, or a script
\ /bin/sh reads and never executes, so writing one cannot race a spawn.
ENUM launch
   VARIANT program FIELD path str ;VARIANT
   VARIANT script FIELD path str ;VARIANT
;ENUM

\ What systemd's ActiveState lets the CLI do with the unit; an unloaded
\ unit reports inactive, so it reads stopped.
ENUM unit-state DERIVE eq running starting failed stopping stopped ;ENUM

\ What a command wants from the unit; each state's step word holds what a
\ goal does there. restore carries the state observed before a change.
ENUM goal
   VARIANT start ;VARIANT
   VARIANT restart ;VARIANT
   VARIANT recover ;VARIANT
   VARIANT halt ;VARIANT
   VARIANT release ;VARIANT
   VARIANT restore FIELD before option<unit-state> ;VARIANT
;ENUM

\ What a drive observed and did. acted: a stop, reset-failed, start or
\ restart was spawned, so the unit may have changed.
STRUCTURE driven DERIVE addr
   FIELD first option<unit-state>
   FIELD last option<unit-state>
   FIELD launched bool
   FIELD acted bool
;STRUCTURE

\ The programs that control and inspect the unit.
STRUCTURE commands OPAQUE DERIVE addr
   FIELD systemctl launch
   FIELD journalctl launch
;STRUCTURE

private

: UNIT ( -- str ) s" omabox.service" ;
: SHELL ( -- str ) s" /bin/sh" ;

ARENA COMMAND-SETS commands

PATH-CAP BUFFER: FOUND


\ ---- errors

: LOG-OPEN ( -- ) LOG:ERROR s" service" LOG:LINE ;

\ Ends the error's line and opens its help line with the text.
: HELP ( str -- )
   {: h :}
   LOG:;LINE LOG-OPEN s" help: " LOG:TEXT+ h LOG:TEXT+ ;

: FAIL ( n -- ) LOG:;LINE throw ;

: QUOTED+ ( str -- )
   {: s :}
   s" `" LOG:TEXT+ s LOG:TEXT+ s" `" LOG:TEXT+ ;

: RETRY-HELP ( -- )
   s" Retry the command; inspect the user session if it happens" HELP
   s"  repeatedly." LOG:TEXT+ ;

: START-FAILED ( str -- )
   LOG-OPEN s" could not run " LOG:TEXT+ QUOTED+
   s" Ensure systemd user services and the system journal are" HELP
   s"  available, then retry." LOG:TEXT+
   E-START-COMMAND FAIL ;

: WAIT-FAILED ( str -- )
   LOG-OPEN QUOTED+
   s"  was started but could not be waited for" LOG:TEXT+
   RETRY-HELP E-WAIT-COMMAND FAIL ;

: TERMINATED ( str -- )
   LOG-OPEN QUOTED+
   s"  was terminated before it reported a result" LOG:TEXT+
   RETRY-HELP E-TERMINATED FAIL ;

\ Rust prints the status as Option's Debug form.
: UNSUCCESSFUL ( n str -- )
   {: code:n name :}
   LOG-OPEN name QUOTED+ s"  failed with status Some(" LOG:TEXT+
   code LOG:INT+ s" )" LOG:TEXT+
   s" Review the command output and `omabox logs`, then retry." HELP
   E-UNSUCCESSFUL FAIL ;

: UNKNOWN-STATE ( str -- )
   LOG-OPEN s" systemd reported the unknown service state " LOG:TEXT+
   QUOTED+
   s" Update Omabox, or report this state if Omabox is current." HELP
   E-UNKNOWN-STATE FAIL ;


\ ---- a launch

: PROGRAM-REQUEST ( str -- PROCESS:request )
   FOUND RESOLVE-EXECUTABLE {: u:n :}
   FOUND u >str PROCESS:NEW ;

: SCRIPT-REQUEST ( str -- PROCESS:request )
   {: s :}
   SHELL PROCESS:NEW s PROCESS:ARG ;

public

\ Rust's Launch::command: the program at its path as PATH resolves it, or
\ /bin/sh with the script as its argument. E-PROC-PATH when PATH lacks it.
: REQUEST ( launch -- PROCESS:request )
   MATCH launch
      program OF PROGRAM-REQUEST ENDOF
      script OF SCRIPT-REQUEST ENDOF
   ;MATCH ;

private


\ ---- the commands

: KEEP ( str ^ARENA:arena -- str )
   {: s ar :}
   s STR:len {: u:n :}
   ar u ARENA:ALLOC {: d:^ du:n :}
   s STR:data d u BYTE-COPY
   d du >str ;

: LAUNCHING ( launch launch ^ARENA:arena -- ^commands )
   {: s j ar :}
   ar COMMAND-SETS-NEW {: c :}
   s c COMMANDS-SYSTEMCTL !
   j c COMMANDS-JOURNALCTL !
   c ;

: SYSTEMCTL@ ( ^commands -- launch ) COMMANDS-SYSTEMCTL @ ;
: JOURNALCTL@ ( ^commands -- launch ) COMMANDS-JOURNALCTL @ ;

public

\ The installed systemctl and journalctl, Rust's default.
: COMMANDS ( ^ARENA:arena -- ^commands )
   {: ar :}
   s" systemctl" SERVICE-LAUNCH:PROGRAM
   s" journalctl" SERVICE-LAUNCH:PROGRAM
   ar LAUNCHING ;

\ Scripts at the paths in place of systemctl and journalctl, which keeps
\ a test's subprocesses deterministic.
: SCRIPTS ( str str ^ARENA:arena -- ^commands )
   {: s j ar :}
   s ar KEEP SERVICE-LAUNCH:SCRIPT
   j ar KEEP SERVICE-LAUNCH:SCRIPT
   ar LAUNCHING ;

private


\ ---- running a command

ENUM wiring inherited quiet output errors ;ENUM

\ A child that ran: what it wrote to its piped stream, empty for none,
\ and how it ended.
STRUCTURE child DERIVE addr
   FIELD out str
   FIELD status PROCESS:status
;STRUCTURE

ARENA CHILDREN child

\ The bytes a piped stream may hold; a child that writes more fails its
\ run.
4096 constant ROOM

: STREAMS ( wiring SPAN:span<u8> -- PROCESS:stdio PROCESS:stdio PROCESS:stdio )
   {: w room :}
   w MATCH wiring
      inherited OF
         PROCESS-STDIO:INHERIT PROCESS-STDIO:INHERIT PROCESS-STDIO:INHERIT
      ENDOF
      quiet OF
         PROCESS-STDIO:INHERIT PROCESS-STDIO:NULL PROCESS-STDIO:NULL
      ENDOF
      output OF
         PROCESS-STDIO:NULL room PROCESS-STDIO:PIPE PROCESS-STDIO:NULL
      ENDOF
      errors OF
         PROCESS-STDIO:NULL PROCESS-STDIO:NULL room PROCESS-STDIO:PIPE
      ENDOF
   ;MATCH ;

\ The room is taken before the request is built, so a failed allocation
\ leaves no request unfreed.
: ENDED ( launch [ PROCESS:request -- PROCESS:request ] wiring ^ARENA:arena ^child -- )
   {: l args w ar k :}
   ar ROOM ARENA:ALLOC {: room:^ ru:n :}
   l REQUEST args execute
   w room ru SPAN:MAKE STREAMS PROCESS:RUN {: o:len e:len s :}
   s k CHILD-STATUS !
   \ At most one stream is piped.
   room o LEN>N e LEN>N + >str k CHILD-OUT ! ;

\ Rust's run. A failure before the child runs logs E-START-COMMAND for
\ name, one after it E-WAIT-COMMAND.
: RAN ( launch [ PROCESS:request -- PROCESS:request ] wiring str ^ARENA:arena -- ^child )
   {: l args w name ar :}
   ar CHILDREN-NEW {: k :}
   [: l args w ar k ENDED ;] catch {: code:n :}
   code 0<> if
      code E-PROC-OUTPUT = code E-PROC-WAIT = or
      code E-PROC-STDOUT-CAPACITY = or code E-PROC-STDERR-CAPACITY = or
      if name WAIT-FAILED else name START-FAILED then
   then
   k ;

: STATUS@ ( ^child -- PROCESS:status ) CHILD-STATUS @ ;

: EXITED ( n str -- )
   {: code:n name :}
   code 0= if exit then
   code name UNSUCCESSFUL ;

\ Rust's status_result: an exit of 0 passes, any other is Unsuccessful,
\ a signal Terminated.
: SUCCEEDED ( ^child str -- )
   {: k name :}
   k STATUS@ MATCH PROCESS:status
      exited OF name EXITED ENDOF
      signaled OF drop name TERMINATED ENDOF
   ;MATCH ;

\ An exit with a status other than 0.
: REFUSED? ( ^child -- bool )
   STATUS@ MATCH PROCESS:status
      exited OF 0<> ENDOF
      signaled OF drop false ENDOF
   ;MATCH ;

: PASSED? ( ^child -- bool )
   STATUS@ MATCH PROCESS:status
      exited OF 0= ENDOF
      signaled OF drop false ENDOF
   ;MATCH ;

\ systemctl's own arguments: --user, then the verb.
: VERB ( PROCESS:request str -- PROCESS:request )
   {: v :}
   s" --user" PROCESS:ARG v PROCESS:ARG ;

: UNIT+ ( PROCESS:request -- PROCESS:request ) UNIT PROCESS:ARG ;


\ ---- what systemctl printed

\ The scalar at the cursor and the cursor after it; a byte no scalar
\ holds answers -1.
: SCALAR ( str n -- n n )
   UTF8:NEXT MATCH UTF8:scalar-step
      scalar OF ENDOF
      raw-byte OF nip -1 swap ENDOF
   ;MATCH ;

: BLANK? ( n -- bool )
   dup 0 < if drop false exit then
   UNICODE-CLASS:WHITE-SPACE? ;

\ Rust's trim of the lossy text: White_Space scalars off both ends; a byte
\ no scalar holds is U+FFFD there, so it stays.
: TRIMMED ( str -- str )
   {: s :}
   s STR:len {: u:n :}
   u 0 0 begin dup u < while
      {: from:n to:n at:n :}
      s at SCALAR {: cp:n next:n :}
      cp BLANK? if from to next
      else from at min next next then
   repeat drop
   {: from:n to:n :}
   s STR:data from +  to from - 0 max >str ;

: ACTIVE-STATE ( str -- option<unit-state> )
   {: a :}
   a s" active" STR= a s" reloading" STR= or
   a s" refreshing" STR= or
   if construct unit-state running OPTION:SOME exit then
   a s" activating" STR=
   if construct unit-state starting OPTION:SOME exit then
   a s" failed" STR=
   if construct unit-state failed OPTION:SOME exit then
   a s" deactivating" STR=
   if construct unit-state stopping OPTION:SOME exit then
   a s" inactive" STR= a s" maintenance" STR= or
   if construct unit-state stopped OPTION:SOME exit then
   OPTION:NONE ;

: STATE-OF ( str ^ARENA:arena -- unit-state )
   {: a ar :}
   a ACTIVE-STATE MATCH option
      some OF ENDOF
      none OF a ar UTF8-LOSSY:REPAIR UNKNOWN-STATE ENDOF
   ;MATCH ;

: STATE-IN ( ^commands ^ARENA:arena -- unit-state )
   {: c ar :}
   c SYSTEMCTL@
   [: s" show" VERB s" --property=ActiveState" PROCESS:ARG
      s" --value" PROCESS:ARG UNIT+ ;]
   construct wiring output s" systemctl show" ar RAN {: k :}
   k s" systemctl show" SUCCEEDED
   k CHILD-OUT @ TRIMMED ar STATE-OF ;

\ list-units lists only loaded units and loads none, unlike show.
: LISTED-NONE ( ^commands ^ARENA:arena ^child -- )
   {: c ar k :}
   c SYSTEMCTL@
   [: s" list-units" VERB s" --all" PROCESS:ARG
      s" --plain" PROCESS:ARG s" --no-legend" PROCESS:ARG UNIT+ ;]
   construct wiring output ar k ENDED ;

\ Rust's unloaded: systemd confirms the unit is not loaded; a list-units
\ that fails to run or reports a failure confirms nothing.
: UNLOADED-IN ( ^commands ^ARENA:arena -- bool )
   {: c ar :}
   ar CHILDREN-NEW {: k :}
   [: c ar k LISTED-NONE ;] catch {: code:n :}
   code 0<> if false exit then
   k PASSED? 0= if false exit then
   k CHILD-OUT @ TRIMMED STR:len 0= ;

: UNLOADED? ( ^commands -- bool ) [: UNLOADED-IN ;] ARENA:WITH ;

\ Rust's settle. An unloaded unit refuses stop and reset-failed; that
\ refusal passes, checked after it as the unit can unload between calls.
: SETTLE-IN ( ^commands [ PROCESS:request -- PROCESS:request ] str ^ARENA:arena -- )
   {: c args name ar :}
   c SYSTEMCTL@ args construct wiring errors name ar RAN {: k :}
   k REFUSED? if c UNLOADED? if exit then then
   FD:STDERR [: FD:STDERR k CHILD-OUT @ FD:TRY-WRITE-FULL drop ;]
   FD:WITH-NOSIGPIPE
   k name SUCCEEDED ;

: SETTLE ( ^commands [ PROCESS:request -- PROCESS:request ] str -- )
   [: SETTLE-IN ;] ARENA:WITH ;

: SETTLE-STOP ( ^commands -- )
   [: s" stop" VERB UNIT+ ;] s" systemctl stop" SETTLE ;

: SETTLE-RESET ( ^commands -- )
   [: s" reset-failed" VERB UNIT+ ;] s" systemctl reset-failed" SETTLE ;


\ ---- direct operations

public

\ Rust's ServiceAction.
ENUM action DERIVE eq start stop restart enable disable status ;ENUM

private

: ACTION$ ( action -- str )
   MATCH action
      start OF s" start" ENDOF
      stop OF s" stop" ENDOF
      restart OF s" restart" ENDOF
      enable OF s" enable" ENDOF
      disable OF s" disable" ENDOF
      status OF s" status" ENDOF
   ;MATCH ;

: STATUS? ( action -- bool )
   MATCH action
      status OF true ENDOF
      start OF false ENDOF
      stop OF false ENDOF
      restart OF false ENDOF
      enable OF false ENDOF
      disable OF false ENDOF
   ;MATCH ;

\ systemctl status exits 3 for a unit that is not running.
: CONTROLLED ( ^child action -- )
   {: k a :}
   k STATUS@ MATCH PROCESS:status
      exited OF
         dup 3 = a STATUS? and if drop 0 then
         s" systemctl" EXITED
      ENDOF
      signaled OF drop s" systemctl" TERMINATED ENDOF
   ;MATCH ;

: CONTROL-IN ( ^commands action ^ARENA:arena -- )
   {: c a ar :}
   c SYSTEMCTL@
   [: a ACTION$ VERB
      a STATUS? if s" --no-pager" PROCESS:ARG then UNIT+ ;]
   construct wiring inherited s" systemctl" ar RAN
   a CONTROLLED ;

\ Rust's control: one direct systemctl operation.
: CONTROL ( ^commands action -- ) [: CONTROL-IN ;] ARENA:WITH ;

: RELOAD-IN ( ^commands ^ARENA:arena -- )
   {: c ar :}
   c SYSTEMCTL@ [: s" daemon-reload" VERB ;]
   construct wiring inherited s" systemctl daemon-reload" ar RAN
   s" systemctl daemon-reload" SUCCEEDED ;

: LOGS-IN ( ^commands ^ARENA:arena -- )
   {: c ar :}
   c JOURNALCTL@
   [: s" --user-unit" PROCESS:ARG UNIT+ s" --no-pager" PROCESS:ARG
      s" --lines" PROCESS:ARG s" 200" PROCESS:ARG ;]
   construct wiring inherited s" journalctl" ar RAN
   s" journalctl" SUCCEEDED ;

\ is-enabled exits 1 for a disabled unit, 3 and 4 for one it cannot read
\ as enabled.
: ENABLED? ( ^child -- bool )
   STATUS@ MATCH PROCESS:status
      exited OF
         {: code:n :}
         code 0= if true else
            code 1 = code 3 = or code 4 = or if false else
               code s" systemctl is-enabled" UNSUCCESSFUL
            then
         then
      ENDOF
      signaled OF drop s" systemctl is-enabled" TERMINATED ENDOF
   ;MATCH ;

: IS-ENABLED-IN ( ^commands ^ARENA:arena -- bool )
   {: c ar :}
   c SYSTEMCTL@ [: s" is-enabled" VERB s" --quiet" PROCESS:ARG UNIT+ ;]
   construct wiring quiet s" systemctl is-enabled" ar RAN
   ENABLED? ;

public

\ Whether the unit starts at login.
: IS-ENABLED ( ^commands -- bool ) [: IS-ENABLED-IN ;] ARENA:WITH ;

\ The unit's ActiveState as systemd reports it.
: STATE ( ^commands -- unit-state ) [: STATE-IN ;] ARENA:WITH ;

\ Reloads the user unit files after an installation changes them.
: DAEMON-RELOAD ( ^commands -- ) [: RELOAD-IN ;] ARENA:WITH ;

: ENABLE ( ^commands -- ) construct action enable CONTROL ;
: DISABLE ( ^commands -- ) construct action disable CONTROL ;

\ Shows systemd's status of the unit; a unit that is not running passes.
: STATUS ( ^commands -- ) construct action status CONTROL ;

\ Shows the unit's last 200 journal lines.
: LOGS ( ^commands -- ) [: LOGS-IN ;] ARENA:WITH ;

private


\ ---- the drive

\ Where a drive is, Rust's Phase. settled: the state observed after a
\ stop; cleared: the failed state and the start limit cleared.
ENUM phase
   initial seen after-stop settled cleared launched reached
;ENUM

\ The steps each phase can take next, Rust's Step.
ENUM initial-step observe clear done ;ENUM
ENUM seen-step stop clear done ;ENUM
ENUM after-stop-step observe done ;ENUM
ENUM settled-step clear done ;ENUM
ENUM cleared-step start restart done ;ENUM

\ A drive's commands and goal, the record it fills, and the state its
\ last observation read.
STRUCTURE drive DERIVE addr
   FIELD commands ^commands
   FIELD goal goal
   FIELD driven ^driven
   FIELD unit unit-state
;STRUCTURE

ARENA DRIVES drive

: GOAL@ ( ^drive -- goal ) DRIVE-GOAL @ ;
: UNIT@ ( ^drive -- unit-state ) DRIVE-UNIT @ ;
: DRIVEN@ ( ^drive -- ^driven ) DRIVE-DRIVEN @ ;
: COMMANDS@ ( ^drive -- ^commands ) DRIVE-COMMANDS @ ;

\ A unit observed running or starting.
: LIVE? ( unit-state -- bool )
   MATCH unit-state
      running OF true ENDOF
      starting OF true ENDOF
      failed OF false ENDOF
      stopping OF false ENDOF
      stopped OF false ENDOF
   ;MATCH ;

: FAILED? ( unit-state -- bool )
   construct unit-state failed SERVICE-UNIT--STATE:EQ ;

: RESTORING? ( option<unit-state> -- bool )
   MATCH option
      some OF LIVE? ENDOF
      none OF false ENDOF
   ;MATCH ;

\ next from initial.
: AT-INITIAL ( ^drive -- initial-step )
   GOAL@ MATCH goal
      start OF construct initial-step clear ENDOF
      restart OF construct initial-step clear ENDOF
      recover OF construct initial-step observe ENDOF
      halt OF construct initial-step observe ENDOF
      release OF construct initial-step observe ENDOF
      restore OF
         RESTORING? if construct initial-step clear
         else construct initial-step done then
      ENDOF
   ;MATCH ;

: RECOVER-SEEN ( unit-state -- seen-step )
   MATCH unit-state
      failed OF construct seen-step clear ENDOF
      stopping OF construct seen-step stop ENDOF
      running OF construct seen-step done ENDOF
      starting OF construct seen-step done ENDOF
      stopped OF construct seen-step done ENDOF
   ;MATCH ;

: HALT-SEEN ( unit-state -- seen-step )
   MATCH unit-state
      failed OF construct seen-step clear ENDOF
      stopped OF construct seen-step done ENDOF
      running OF construct seen-step stop ENDOF
      starting OF construct seen-step stop ENDOF
      stopping OF construct seen-step stop ENDOF
   ;MATCH ;

: RELEASE-SEEN ( unit-state -- seen-step )
   dup FAILED? swap construct unit-state stopped SERVICE-UNIT--STATE:EQ
   or if construct seen-step done exit then
   construct seen-step stop ;

\ next from seen, for the state observed.
: AT-SEEN ( ^drive -- seen-step )
   {: d :}
   d UNIT@ {: u :}
   d GOAL@ MATCH goal
      recover OF u RECOVER-SEEN ENDOF
      halt OF u HALT-SEEN ENDOF
      release OF u RELEASE-SEEN ENDOF
      start OF construct seen-step done ENDOF
      restart OF construct seen-step done ENDOF
      restore OF drop construct seen-step done ENDOF
   ;MATCH ;

\ Recover and halt look again after a stop.
: LOOKS? ( goal -- bool )
   MATCH goal
      recover OF true ENDOF
      halt OF true ENDOF
      start OF false ENDOF
      restart OF false ENDOF
      release OF false ENDOF
      restore OF drop false ENDOF
   ;MATCH ;

: AT-AFTER-STOP ( ^drive -- after-stop-step )
   GOAL@ LOOKS? if construct after-stop-step observe exit then
   construct after-stop-step done ;

\ next from settled: recover and halt clear a unit that ended failed.
: AT-SETTLED ( ^drive -- settled-step )
   {: d :}
   d GOAL@ LOOKS? d UNIT@ FAILED? and
   if construct settled-step clear exit then
   construct settled-step done ;

: AT-CLEARED ( ^drive -- cleared-step )
   GOAL@ MATCH goal
      start OF construct cleared-step start ENDOF
      restart OF construct cleared-step restart ENDOF
      recover OF construct cleared-step start ENDOF
      restore OF drop construct cleared-step start ENDOF
      halt OF construct cleared-step done ENDOF
      release OF construct cleared-step done ENDOF
   ;MATCH ;

\ Rust's acting: a step whose command was spawned may have changed the
\ unit; one whose command could not be spawned did not.
: ACTING ( ^drive [ -- ] -- )
   {: d step :}
   step catch {: code:n :}
   code E-START-COMMAND <> if true d DRIVEN@ SERVICE-DRIVEN:ACTED ! then
   code 0<> if code throw then ;

: OBSERVE ( ^drive -- )
   {: d :}
   d COMMANDS@ STATE {: u :}
   u d DRIVE-UNIT !
   u OPTION:SOME d DRIVEN@ SERVICE-DRIVEN:LAST ! ;

: OBSERVE-FIRST ( ^drive -- )
   {: d :}
   d OBSERVE
   d UNIT@ OPTION:SOME d DRIVEN@ SERVICE-DRIVEN:FIRST ! ;

: STOP ( ^drive -- ) {: d :} d [: d COMMANDS@ SETTLE-STOP ;] ACTING ;
: CLEAR ( ^drive -- ) {: d :} d [: d COMMANDS@ SETTLE-RESET ;] ACTING ;

: LAUNCHED ( ^drive action -- )
   {: d a :}
   d COMMANDS@ a CONTROL
   true d DRIVEN@ SERVICE-DRIVEN:LAUNCHED ! ;

: START ( ^drive -- )
   {: d :} d [: d construct action start LAUNCHED ;] ACTING ;

: RESTART ( ^drive -- )
   {: d :} d [: d construct action restart LAUNCHED ;] ACTING ;

\ Rust's drive_recorded loop, after formal/ServiceDrive.tla.
FSM:DEFINE DRIVING ( ^drive ) phase initial-step
   IN initial  AT-INITIAL
      observe  OBSERVE-FIRST  >seen
      clear    CLEAR          >cleared
      done     -              >reached
   IN seen  AT-SEEN ( seen-step )
      stop     STOP           >after-stop
      clear    CLEAR          >cleared
      done     -              >reached
   IN after-stop  AT-AFTER-STOP ( after-stop-step )
      observe  OBSERVE        >settled
      done     -              >reached
   IN settled  AT-SETTLED ( settled-step )
      clear    CLEAR          >cleared
      done     -              >reached
   IN cleared  AT-CLEARED ( cleared-step )
      start    START          >launched
      restart  RESTART        >launched
      done     -              >reached
   FINAL launched  -
   FINAL reached  -
;DEFINE

: UNDRIVEN ( ^driven -- )
   {: v :}
   OPTION:NONE v SERVICE-DRIVEN:FIRST !
   OPTION:NONE v SERVICE-DRIVEN:LAST !
   false v SERVICE-DRIVEN:LAUNCHED !
   false v SERVICE-DRIVEN:ACTED ! ;

: DRIVE-IN ( ^commands goal ^driven ^ARENA:arena -- n )
   {: c g v ar :}
   ar DRIVES-NEW {: d :}
   c d DRIVE-COMMANDS !
   g d DRIVE-GOAL !
   v d DRIVE-DRIVEN !
   [: d construct phase initial DRIVING ;] catch ;

public

\ Rust's drive_recorded: the record is filled even when a step fails.
\ Answers the code of the step that ended the drive, 0 for none.
: DRIVE-RECORDED ( ^commands goal ^driven -- n )
   {: c g v :}
   v UNDRIVEN
   c g v [: DRIVE-IN ;] ARENA:WITH ;

\ Rust's drive: DRIVE-RECORDED, throwing the code of a step that failed.
: DRIVE ( ^commands goal ^driven -- )
   DRIVE-RECORDED {: code:n :}
   code 0<> if code throw then ;

;package
