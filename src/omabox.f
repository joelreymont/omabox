\ omabox.f - the omabox program (rust src/bin/omabox.rs), whose global
\ MAIN is the build's entry. PARSE reads the arguments as Rust's parse
\ does: help, version, pause, resume, service ACTION and logs. A command
\ that fails exits 1, as Rust's main returning an error does.
\ A failure logs as CONFIG's refusals do: the library that failed logs
\ its own lines, then OMABOX logs Rust's CliError text and, where the
\ error has one, its help line; a SERVICE failure is SERVICE's alone.
\ STORAGE CLASS. CALLER-OWNED: a command's service commands and drive
\ record live in an arena the run holds; help and the version line are
\ built in string.f's task-local builder.
require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/adt/option.f
require src/lib/log.f
require src/lib/fd.f
require src/lib/fs.f
require src/lib/utf8-scalar.f
require src/service.f
require src/version.f

package OMABOX
public

-101100 constant E-FIRST
-101199 constant E-LAST
-101100 s" the command line is not one omabox accepts"
   ERROR:CODE E-USAGE
-101101 s" omabox could not read or write the terminal" ERROR:CODE E-IO

private

\ Appends the line and its LF.
: LINE+ ( ^u8 n -- ) SB-APPEND 10 SB-APPEND-C ;

\ Rust's HELP, with the usage lines of the commands PARSE knows.
: HELP-TEXT ( -- ^u8 n )
   SB-RESET
   s" Omabox synchronizes a local directory with Dropbox." LINE+
   s" " LINE+
   s" Usage:" LINE+
   s"   omabox pause|resume" LINE+
   s"   omabox service start|stop|restart|enable|disable|status" LINE+
   s"   omabox logs" LINE+
   s"   omabox --help" LINE+
   s"   omabox --version" LINE+
   SB$ ;

: VERSION-LINE ( -- ^u8 n )
   SB-RESET s" omabox " SB-APPEND RELEASE:VERSION$ LINE+ SB$ ;

\ Rust's Command, the forms this program parses.
ENUM command DERIVE eq
   VARIANT help ;VARIANT
   VARIANT version ;VARIANT
   VARIANT service FIELD action SERVICE:action ;VARIANT
   VARIANT logs ;VARIANT
;ENUM

ARENA DRIVENS SERVICE:driven


\ ---- errors

: LOG-OPEN ( -- ) LOG:ERROR s" omabox" LOG:LINE ;

\ Ends the error's line and opens its help line with the text.
: HELP ( ^u8 n -- )
   {: h:^ hu:n :}
   LOG:;LINE LOG-OPEN s" help: " LOG:TEXT+ h hu LOG:TEXT+ ;

\ Rust's Usage: the fault, then the pointer to --help.
: USAGE ( ^u8 n -- )
   {: m:^ mu:n :}
   LOG-OPEN m mu LOG:TEXT+
   s" Run `omabox --help` for usage." HELP
   LOG:;LINE E-USAGE throw ;

\ Rust's Io for the operation; the cause stays FS:ERRNO's on entry.
: IO-FAILED ( ^u8 n -- )
   {: op:^ opu:n :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op opu LOG:TEXT+
   s" Check the terminal input and output, then retry." HELP
   LOG:;LINE cause FS:CAUSE! E-IO throw ;


\ ---- output

\ A closed reader refuses the write rather than ending the process.
: WRITE-FULL ( ^u8 n -- )
   {: a:^ u:n :}
   FD:STDOUT [: FD:STDOUT a u FD:WRITE-FULL ;] FD:WITH-NOSIGPIPE ;

: WRITE-OUT ( ^u8 n -- )
   {: a:^ u:n :}
   [: a u WRITE-FULL ;] catch {: code:n :}
   code 0<> if s" write command output" IO-FAILED then ;


\ ---- parsing

: HELP? ( ^u8 n -- bool )
   {: a:^ u:n :}
   a u s" --help" STR= a u s" -h" STR= or a u s" help" STR= or ;

: VERSION? ( ^u8 n -- bool )
   {: a:^ u:n :}
   a u s" --version" STR= a u s" -V" STR= or ;

: ACTION-COMMAND ( SERVICE:action -- option<command> )
   COMMAND-SERVICE OPTION:SOME ;

\ The command a name alone selects, none for one that takes arguments
\ or is unknown.
: ALONE ( ^u8 n -- option<command> )
   {: a:^ u:n :}
   a u HELP? if construct command help OPTION:SOME exit then
   a u VERSION? if construct command version OPTION:SOME exit then
   a u s" pause" STR= if
      SERVICE-ACTION:STOP ACTION-COMMAND exit
   then
   a u s" resume" STR= if
      SERVICE-ACTION:START ACTION-COMMAND exit
   then
   a u s" logs" STR= if construct command logs OPTION:SOME exit then
   OPTION:NONE ;

\ Rust's parse_service's action; bytes that are not UTF-8 name none.
: ACTION ( ^u8 n -- SERVICE:action )
   {: a:^ u:n :}
   a u s" start" STR= if SERVICE-ACTION:START exit then
   a u s" stop" STR= if SERVICE-ACTION:STOP exit then
   a u s" restart" STR= if SERVICE-ACTION:RESTART exit then
   a u s" enable" STR= if SERVICE-ACTION:ENABLE exit then
   a u s" disable" STR= if SERVICE-ACTION:DISABLE exit then
   a u s" status" STR= if SERVICE-ACTION:STATUS exit then
   s" unknown service action" USAGE ;

: PARSE-SERVICE ( n [ n -- ^u8 n ] -- command )
   {: argc:n arg :}
   argc 2 <> if s" service requires exactly one action" USAGE then
   1 arg execute ACTION COMMAND-SERVICE ;

\ The command a name alone selects, refusing further arguments.
: SOLE ( option<command> n -- command )
   {: argc:n :}
   MATCH option
      some OF
         argc 1 > if s" too many arguments" USAGE then
      ENDOF
      none OF s" unknown command" USAGE ENDOF
   ;MATCH ;

\ Rust's parse over argc arguments, arg answering the one at an index.
: PARSE ( n [ n -- ^u8 n ] -- command )
   {: argc:n arg :}
   argc 0= if s" a command is required" USAGE then
   0 arg execute {: c:^ cu:n :}
   c cu UTF8:VALID? 0= if
      s" the command must be valid UTF-8" USAGE
   then
   c cu s" service" STR= if argc arg PARSE-SERVICE exit then
   c cu ALONE argc SOLE ;


\ ---- running

\ Rust's run_service: a start, restart or stop drives the unit toward
\ its goal.
: RUN-SERVICE ( ^SERVICE:commands SERVICE:action ^ARENA:arena -- )
   {: c act ar :}
   act MATCH SERVICE:action
      start OF c SERVICE-GOAL:START ar DRIVENS-NEW SERVICE:DRIVE ENDOF
      restart OF
         c SERVICE-GOAL:RESTART ar DRIVENS-NEW SERVICE:DRIVE
      ENDOF
      stop OF c SERVICE-GOAL:HALT ar DRIVENS-NEW SERVICE:DRIVE ENDOF
      enable OF c SERVICE:ENABLE ENDOF
      disable OF c SERVICE:DISABLE ENDOF
      status OF c SERVICE:STATUS ENDOF
   ;MATCH ;

: PERFORM ( command ^ARENA:arena -- )
   {: cmd ar :}
   cmd MATCH command
      help OF HELP-TEXT WRITE-OUT ENDOF
      version OF VERSION-LINE WRITE-OUT ENDOF
      service OF {: act :} ar SERVICE:COMMANDS act ar RUN-SERVICE ENDOF
      logs OF ar SERVICE:COMMANDS SERVICE:LOGS ENDOF
   ;MATCH ;

: RUN ( -- )
   SCRIPT-ARGC [: SCRIPT-ARGV$ ;] PARSE {: cmd :}
   [: cmd swap PERFORM ;] ARENA:WITH ;

global

: MAIN ( -- )
   [: RUN ;] catch {: code:n :}
   code 0<> if s" " 1 die then ;

;package
