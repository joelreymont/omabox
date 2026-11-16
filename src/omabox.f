\ omabox.f - the omabox program (rust src/bin/omabox.rs), whose global
\ MAIN is the build's entry. PARSE reads the arguments as Rust's parse
\ does: help, version, status, pause, resume, settings [--json], service
\ ACTION and logs. A command that fails exits 1, as Rust's main
\ returning an error does.
\ A failure logs as CONFIG's refusals do: the library that failed logs
\ its own lines, then OMABOX logs Rust's CliError text and, where the
\ error has one, its help line; a SERVICE or ATTENTION failure is that
\ package's alone. A CONFIG refusal of an operation keeps CONFIG's code,
\ help and FS:ERRNO, as Rust's Config forwards its source's.
\ status and settings check the stored sync root once their text is
\ built: CONFIG logs its refusal of an unusable root, and the command
\ still writes its text and succeeds.
\ setup's local steps are Rust's: its options parsed whole, the default
\ sync root made, the authorization code read, and the config written
\ under the daemon lock.
\ STORAGE CLASS. CALLER-OWNED: a command's service commands, drive
\ record, configuration, text, lock, default root and authorization
\ code live in an arena the run holds; help and the version line are
\ built in string.f's task-local builder.
require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/adt/option.f
require src/lib/log.f
require src/lib/fd.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/utf8-scalar.f
require src/lib/unicode/class.f
require src/lib/vector.f
require src/lib/json.f
require src/config.f
require src/journal.f
require src/dropbox.f
require src/attention.f
require src/service.f
require src/stale.f
require src/version.f

package OMABOX
public

-101100 constant E-FIRST
-101199 constant E-LAST
-101100 s" the command line is not one omabox accepts"
   ERROR:CODE E-USAGE
-101101 s" omabox could not read or write the terminal" ERROR:CODE E-IO
-101102 s" could not serialize settings output"
   ERROR:CODE E-SERIALIZE-OUTPUT
-101103 s" a change failed and the Omabox service could not be restarted"
   ERROR:CODE E-CHANGE-AND-RESTORE
-101104 s" a change was made, but the Omabox service could not be started or checked"
   ERROR:CODE E-START-AFTER-CHANGE
-101105 s" could not inspect the Omabox configuration path"
   ERROR:CODE E-INSPECT-CONFIG
-101106 s" Omabox configuration already exists" ERROR:CODE E-CONFIG-EXISTS
-101107 s" could not acquire the Omabox daemon lock" ERROR:CODE E-LOCK
-101108 s" the Dropbox authorization code was empty or too long"
   ERROR:CODE E-INVALID-CODE
-101109
   s" HOME must be an absolute path to find the default sync root ~/Dropbox"
   ERROR:CODE E-NO-DEFAULT-ROOT
-101110 s" could not create the default sync root"
   ERROR:CODE E-CREATE-DEFAULT-ROOT
-101111 s" an Omabox journal operation failed" ERROR:CODE E-JOURNAL

private

\ Appends the line and its LF.
: LINE+ ( ^u8 n -- ) SB-APPEND 10 SB-APPEND-C ;

\ Rust's HELP, with the usage lines of the commands PARSE knows.
: HELP-TEXT ( -- ^u8 n )
   SB-RESET
   s" Omabox synchronizes a local directory with Dropbox." LINE+
   s" " LINE+
   s" Usage:" LINE+
   s"   omabox status" LINE+
   s"   omabox pause|resume" LINE+
   s"   omabox settings [--json]" LINE+
   s"   omabox service start|stop|restart|enable|disable|status" LINE+
   s"   omabox logs" LINE+
   s"   omabox --help" LINE+
   s"   omabox --version" LINE+
   SB$ ;

: VERSION-LINE ( -- ^u8 n )
   SB-RESET s" omabox " SB-APPEND RELEASE:VERSION$ LINE+ SB$ ;

\ Rust's Settings { json }: how settings shows the stored settings.
ENUM form DERIVE eq text json ;ENUM

\ Rust's Command, the forms this program parses. It derives no eq: a
\ str or option payload has none.
ENUM command
   VARIANT help ;VARIANT
   VARIANT version ;VARIANT
   VARIANT status ;VARIANT
   VARIANT settings FIELD shown form ;VARIANT
   VARIANT service FIELD action SERVICE:action ;VARIANT
   VARIANT logs ;VARIANT
;ENUM

\ Rust's InitialConfig: the sync root, none for ~/Dropbox, and the app
\ key.
STRUCTURE initial-config
   FIELD sync-root option<str>
   FIELD app-key str
;STRUCTURE

\ Rust's SetupOptions: the remote root, empty for the account's own, and
\ the initial config of a setup driven by flags.
STRUCTURE setup-options
   FIELD remote-root str
   FIELD initial option<initial-config>
;STRUCTURE

\ Rust's AUTHORIZATION_CODE_LIMIT, in bytes.
8192 constant CODE-LIMIT
ARENA DRIVENS SERVICE:driven
ARENA WRITERS JSON:writer
ARENA LOCKS CONFIG:lock


\ ---- errors

: LOG-OPEN ( -- ) LOG:ERROR s" omabox" LOG:LINE ;

\ Ends the error's line and opens its help line with the text.
: HELP ( ^u8 n -- )
   {: h:^ hu:n :}
   LOG:;LINE LOG-OPEN s" help: " LOG:TEXT+ h hu LOG:TEXT+ ;

\ Ends Rust's Usage after its fault: the pointer to --help.
: USAGE-END ( -- )
   s" Run `omabox --help` for usage." HELP
   LOG:;LINE E-USAGE throw ;

\ Rust's Usage: the fault, then the pointer to --help.
: USAGE ( ^u8 n -- )
   {: m:^ mu:n :}
   LOG-OPEN m mu LOG:TEXT+ USAGE-END ;

\ Rust's dropbox_root fault, a Usage.
: ROOT-FAULT ( -- )
   LOG-OPEN
   s" the Dropbox root must be empty or an absolute folder path" LOG:TEXT+
   s"  such as /Work, with no trailing slash and no empty, . or .."
   LOG:TEXT+ s"  parts" LOG:TEXT+ USAGE-END ;

\ Rust's Io for the operation; the cause stays FS:ERRNO's on entry.
: IO-FAILED ( ^u8 n -- )
   {: op:^ opu:n :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op opu LOG:TEXT+
   s" Check the terminal input and output, then retry." HELP
   LOG:;LINE cause FS:CAUSE! E-IO throw ;

: CONFIG-CODE? ( n -- bool )
   {: c:n :}
   c CONFIG:E-LAST >= c CONFIG:E-FIRST <= and ;

\ Rust's Config for the operation, after CONFIG's own lines; a code of
\ another package goes on.
: CONFIG-FAILED ( n ^u8 n -- )
   {: code:n op:^ opu:n :}
   code CONFIG-CODE? 0= if code throw then
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op opu LOG:TEXT+
   LOG:;LINE cause FS:CAUSE! code throw ;

: SERIALIZE-FAILED ( -- )
   LOG-OPEN s" could not serialize settings output" LOG:TEXT+
   s" Use `omabox settings` for human-readable output." HELP
   LOG:;LINE 0 FS:CAUSE! E-SERIALIZE-OUTPUT throw ;

\ Rust's ChangeAndRestore, after the change's lines and the restore's.
: CHANGE-AND-RESTORE ( ^u8 n -- )
   {: c:^ cu:n :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN c cu LOG:TEXT+
   s"  failed, and the Omabox service could not be restarted;"
   LOG:TEXT+
   s"  run `omabox resume` once the errors above are fixed" LOG:TEXT+
   LOG:;LINE cause FS:CAUSE! E-CHANGE-AND-RESTORE throw ;

\ Rust's StartAfterChange for the done text, after the drive's lines.
: START-AFTER-CHANGE ( ^u8 n -- )
   {: d:^ du:n :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN d du LOG:TEXT+
   s" , but the Omabox service could not be started or checked"
   LOG:TEXT+
   s" The change is kept. Run `omabox status` and `omabox logs` to see why, then `omabox resume`."
   HELP LOG:;LINE cause FS:CAUSE! E-START-AFTER-CHANGE throw ;

\ Ends the help line, then throws code with cause as FS:ERRNO.
: FAIL ( n n -- )
   {: code:n cause:n :}
   LOG:;LINE cause FS:CAUSE! code throw ;

: INSPECT-FAILED ( n -- )
   {: cause:n :}
   LOG-OPEN s" could not inspect the Omabox configuration path" LOG:TEXT+
   s" Ensure the XDG configuration location is accessible" HELP
   s"  and retry." LOG:TEXT+
   E-INSPECT-CONFIG cause FAIL ;

: CONFIG-EXISTS ( -- )
   LOG-OPEN s" Omabox configuration already exists" LOG:TEXT+
   s" Use `omabox settings` or `omabox settings set-root PATH`" HELP
   s"  to change configuration." LOG:TEXT+
   E-CONFIG-EXISTS 0 FAIL ;

\ Rust's Lock, after CONFIG's own lines; a code of another package goes
\ on.
: LOCK-FAILED ( n -- )
   {: code:n :}
   code CONFIG-CODE? 0= if code throw then
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not acquire the Omabox daemon lock" LOG:TEXT+
   s" Stop any manually started Omabox daemon, then retry." HELP
   E-LOCK cause FAIL ;

\ Rust's Journal for the operation, in place of the code it caught, after
\ the lines its cause logged: JOURNAL's, SQLITE's or the file system's,
\ all Rust's JournalError.
: JOURNAL-FAILED ( n ^u8 n -- )
   {: op:^ opu:n :} drop
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op opu LOG:TEXT+
   s" Ensure the Omabox state directory is accessible and retry." HELP
   E-JOURNAL cause FAIL ;

: INVALID-CODE ( -- )
   LOG-OPEN
   s" the Dropbox authorization code was empty or too long" LOG:TEXT+
   s" Paste the short-lived code shown by Dropbox and retry setup." HELP
   E-INVALID-CODE 0 FAIL ;

: NO-DEFAULT-ROOT ( -- )
   LOG-OPEN s" HOME must be an absolute path to find the default" LOG:TEXT+
   s"  sync root ~/Dropbox" LOG:TEXT+
   s" Set HOME, or pass --sync-root PATH." HELP
   E-NO-DEFAULT-ROOT 0 FAIL ;

: CREATE-ROOT-FAILED ( str n -- )
   {: root cause:n :}
   LOG-OPEN s" could not create the default sync root " LOG:TEXT+
   root str> LOG:TEXT+
   s" Create the directory, or pass --sync-root PATH." HELP
   E-CREATE-DEFAULT-ROOT cause FAIL ;


\ ---- output

\ A closed reader refuses the write rather than ending the process.
: WRITE-FULL ( ^u8 n -- )
   {: a:^ u:n :}
   FD:STDOUT [: FD:STDOUT a u FD:WRITE-FULL ;] FD:WITH-NOSIGPIPE ;

: WRITE-OUT ( ^u8 n -- )
   {: a:^ u:n :}
   [: a u WRITE-FULL ;] catch {: code:n :}
   code 0<> if s" write command output" IO-FAILED then ;

\ The text, then the leftovers' lines, with SIGPIPE held off.
: REPORT-FULL ( ^u8 n ^VEC:vector<STALE:leftover> -- )
   {: a:^ u:n left :}
   FD:STDOUT [:
      FD:STDOUT a u FD:WRITE-FULL
      left FD:STDOUT STALE:REPORT
   ;] FD:WITH-NOSIGPIPE ;

: REPORT-OUT ( ^u8 n ^VEC:vector<STALE:leftover> -- )
   {: a:^ u:n left :}
   [: a u left REPORT-FULL ;] catch {: code:n :}
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
   a u s" status" STR= if construct command status OPTION:SOME exit then
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

\ Rust's parse_settings, but for set-root.
: PARSE-SETTINGS ( n [ n -- ^u8 n ] -- command )
   {: argc:n arg :}
   argc 1 = if construct form text COMMAND-SETTINGS exit then
   argc 2 = if
      1 arg execute s" --json" STR= if
         construct form json COMMAND-SETTINGS exit
      then
   then
   s" invalid settings command" USAGE ;

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
   c cu s" settings" STR= if argc arg PARSE-SETTINGS exit then
   c cu s" service" STR= if argc arg PARSE-SERVICE exit then
   c cu ALONE argc SOLE ;

\ Rust's is_option.
: OPTION-ARG? ( ^u8 n -- bool ) 2 min s" --" STR= ;

\ Rust's utf8: the bytes, or Usage with the fault m.
: VALID-ARG ( ^u8 n ^u8 n -- str )
   {: a:^ u:n m:^ mu:n :}
   a u UTF8:VALID? 0= if m mu USAGE then
   a u >str ;

\ Rust's dropbox_root, refused before setup sends the user through the
\ browser.
: REMOTE-ROOT ( ^u8 n -- str )
   s" the Dropbox root must be valid UTF-8" VALID-ARG {: r :}
   r str> DROPBOX:ROOT-PATH? 0= if ROOT-FAULT then
   r ;

: NO-STR ( -- option<str> ) OPTION:NONE ;

\ The value after the option at index at.
: VALUE ( n [ n -- ^u8 n ] n -- ^u8 n )
   {: argc:n arg at:n :}
   at 1+ argc >= if s" a setup option is missing its value" USAGE then
   at 1+ arg execute ;

\ Refuses an option given before.
: UNSET ( option<str> -- )
   MATCH option
      some OF
         drop s" a setup option was provided more than once" USAGE
      ENDOF
      none OF ENDOF
   ;MATCH ;

\ The option at index at and its value taken into the sync root, app
\ key and remote root given so far.
: STEP ( option<str> option<str> option<str> n [ n -- ^u8 n ] n
     -- option<str> option<str> option<str> )
   {: sync key remote argc:n arg at:n :}
   at arg execute {: o:^ ou:n :}
   o ou UTF8:VALID? 0= if s" setup options must be valid UTF-8" USAGE then
   o ou s" --sync-root" STR= if
      sync UNSET argc arg at VALUE >str OPTION:SOME key remote exit
   then
   o ou s" --app-key" STR= if
      key UNSET sync argc arg at VALUE
      s" the Dropbox app key must be valid UTF-8" VALID-ARG OPTION:SOME
      remote exit
   then
   o ou s" --remote-root" STR= if
      remote UNSET sync key argc arg at VALUE REMOTE-ROOT OPTION:SOME exit
   then
   s" unknown setup option" USAGE ;

\ The sync root, app key and remote root the options from index 1 give.
: SETUP-FLAGS ( n [ n -- ^u8 n ] -- option<str> option<str> option<str> )
   {: argc:n arg :}
   NO-STR NO-STR NO-STR
   argc 1 ?do argc arg i STEP 2 +loop ;

: FLAGGED ( option<str> option<str> option<str> -- setup-options )
   {: sync key remote :}
   key MATCH option
      some OF ENDOF
      none OF s" flag-driven setup requires --app-key" USAGE ENDOF
   ;MATCH {: k :}
   remote MATCH option
      some OF ENDOF
      none OF s" " >str ENDOF
   ;MATCH
   sync k INITIAL-CONFIG-MAKE OPTION:SOME SETUP-OPTIONS-MAKE ;

: NO-INITIAL ( -- option<initial-config> ) OPTION:NONE ;

\ Setup of the stored configuration, for the remote root.
: STORED-SETUP ( str -- setup-options ) NO-INITIAL SETUP-OPTIONS-MAKE ;

\ Rust's parse_setup over the whole argument list, index 0 being setup.
: PARSE-SETUP ( n [ n -- ^u8 n ] -- setup-options )
   {: argc:n arg :}
   argc 1 = if s" " >str STORED-SETUP exit then
   argc 2 = if
      1 arg execute OPTION-ARG? 0= if
         1 arg execute REMOTE-ROOT STORED-SETUP exit
      then
   then
   argc arg SETUP-FLAGS FLAGGED ;


\ ---- the configuration

: XDG ( ^ARENA:arena -- ^CONFIG:xdg )
   {: ar :}
   NULL-PTR [: drop ar CONFIG:XDG-ENV ;] catch {: x code :}
   code 0= if x exit then
   code s" resolve XDG paths" CONFIG-FAILED ;

: DOCUMENT ( ^CONFIG:xdg ^ARENA:arena -- ^CONFIG:document )
   {: x ar :}
   NULL-PTR [: drop x ar CONFIG:DOCUMENT-LOAD-FROM ;] catch {: d code :}
   code 0= if d exit then
   code s" load configuration" CONFIG-FAILED ;

: STATE-PATHS ( ^CONFIG:xdg ^ARENA:arena -- ^CONFIG:paths )
   {: x ar :}
   NULL-PTR [: drop x ar CONFIG:RESOLVE-PRIVATE ;] catch {: p code :}
   code 0= if p exit then
   code s" resolve state paths" CONFIG-FAILED ;

\ Rust's unusable_root_line: CONFIG logs its refusal of the stored root,
\ which leaves the command's text standing; any other code goes on.
: ROOT-CHECKED ( ^CONFIG:document ^CONFIG:xdg ^ARENA:arena -- )
   {: d x ar :}
   [: d x ar CONFIG:VALIDATE drop ;] catch {: code:n :}
   code 0= if exit then
   code CONFIG-CODE? 0= if code throw then ;


\ ---- status and settings

\ The bytes copied into the arena.
: KEPT ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u:n ar :}
   ar u ARENA:ALLOC {: d:^ du:n :}
   a d u BYTE-COPY
   d du >str ;

\ Rust's status_output: the journal's text.
: STATUS-TEXT ( ^CONFIG:xdg ^ARENA:arena -- str )
   {: x ar :}
   x ar DOCUMENT {: d :}
   x ar STATE-PATHS {: p :}
   p CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR ar ATTENTION:RENDER {: t :}
   d x ar ROOT-CHECKED
   t ;

: SETTINGS-LINES ( ^CONFIG:document ^ARENA:arena -- str )
   {: d ar :}
   SB-RESET s" Sync root: " SB-APPEND
   d CONFIG:DOCUMENT-ROOT CONFIG:ABS-PATH>STR str> LINE+
   s" Dropbox app key: " SB-APPEND d CONFIG:DOCUMENT-KEY str> LINE+
   SB$ ar KEPT ;

: SETTINGS-FIELDS ( ^CONFIG:document ^JSON:writer -- )
   {: d w :}
   w 2 JSON:WRITE-INDENT! JSON:WRITE-OBJECT-START
   s" sync_root" d CONFIG:DOCUMENT-ROOT CONFIG:ABS-PATH>STR str>
   JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" dropbox_app_key" d CONFIG:DOCUMENT-KEY str> JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END drop ;

\ serde_json's to_string_pretty of the document, then LF, in a buffer
\ every byte escaped to six fits; text that is not UTF-8 is Rust's
\ SerializeOutput.
: SETTINGS-JSON ( ^CONFIG:document ^ARENA:arena -- str )
   {: d ar :}
   d CONFIG:DOCUMENT-ROOT CONFIG:ABS-PATH>STR str> nip
   d CONFIG:DOCUMENT-KEY str> nip + 6 * 64 + {: cap:n :}
   ar cap 1+ ARENA:ALLOC drop {: buf:^ :}
   ar WRITERS-NEW {: w :}
   w buf cap JSON:WRITE-OPEN drop
   [: d w SETTINGS-FIELDS ;] catch {: code:n :}
   code E-JSON-WRITE-BYTE = if SERIALIZE-FAILED then
   code 0<> if code throw then
   w JSON:WRITTEN$ {: r:^ ru:n :}
   w JSON:WRITE-CLOSE
   10 r ru + c!
   r ru 1+ >str ;

\ Rust's settings_output: the stored settings, as text or JSON.
: SETTINGS-TEXT ( ^CONFIG:xdg form ^ARENA:arena -- str )
   {: x f ar :}
   x ar DOCUMENT {: d :}
   f MATCH form
      text OF d ar SETTINGS-LINES ENDOF
      json OF d ar SETTINGS-JSON ENDOF
   ;MATCH {: t :}
   d x ar ROOT-CHECKED
   t ;


\ ---- a change while the service is released

\ Rust's restore_goal: the drive that puts back what a release changed.
: RESTORE-GOAL ( ^SERVICE:driven -- option<SERVICE:goal> )
   {: v :}
   v SERVICE-DRIVEN:ACTED @ 0= if OPTION:NONE exit then
   v SERVICE-DRIVEN:FIRST @ SERVICE-GOAL:RESTORE OPTION:SOME ;

\ The change's leftovers and code, 0 for none; it runs only after the
\ release, whose code r is the change's when it failed.
: CHANGED ( n [ ^ARENA:arena -- ^VEC:vector<STALE:leftover> ]
     ^ARENA:arena -- ^VEC:vector<STALE:leftover> n )
   {: r:n change ar :}
   r 0<> if NULL-PTR r exit then
   NULL-PTR [: drop ar change execute ;] catch {: left code:n :}
   code 0= if left 0 exit then
   NULL-PTR code ;

\ Whether the restore drive launched the unit, and its code; a release
\ that spawned nothing has nothing to restore.
: RESTORED ( ^SERVICE:commands ^SERVICE:driven ^ARENA:arena -- bool n )
   {: c v ar :}
   v RESTORE-GOAL MATCH option
      none OF false 0 ENDOF
      some OF
         {: g :} ar DRIVENS-NEW {: r :}
         c g r SERVICE:DRIVE-RECORDED {: code:n :}
         r SERVICE-DRIVEN:LAUNCHED @ code
      ENDOF
   ;MATCH ;

\ The change may fix the fatal cause of a unit the release left failed:
\ unless the restore launched it, a recover drive answers whether it did.
: RECOVERED ( ^SERVICE:commands bool ^u8 n ^ARENA:arena -- bool )
   {: c launched:bool d:^ du:n ar :}
   launched if false exit then
   ar DRIVENS-NEW {: v :}
   c SERVICE-GOAL:RECOVER v SERVICE:DRIVE-RECORDED
   0<> if d du START-AFTER-CHANGE then
   v SERVICE-DRIVEN:LAUNCHED @ ;

: NOTE ( bool -- ^u8 n )
   if s"  The stopped service has been started again." exit then s" " ;

\ "{done}.{note}", LF and the leftovers' lines on stdout.
: DONE-OUT ( ^u8 n bool ^VEC:vector<STALE:leftover> -- )
   {: d:^ du:n recovered:bool left :}
   SB-RESET d du SB-APPEND s" ." SB-APPEND recovered NOTE LINE+
   SB$ left REPORT-OUT ;

\ Rust's match on the change's outcome and the restore's: c the
\ commands, n the change's name, d its done text.
: DECIDED ( ^SERVICE:commands ^u8 n ^u8 n
     ^VEC:vector<STALE:leftover> n bool n ^ARENA:arena -- )
   {: c n:^ nu:n d:^ du:n left changed:n
      launched:bool restored:n ar :}
   changed 0<> restored 0<> and if n nu CHANGE-AND-RESTORE then
   changed 0<> if changed throw then
   restored 0<> if d du START-AFTER-CHANGE then
   c launched d du ar RECOVERED {: recovered:bool :}
   d du recovered left DONE-OUT ;

\ Rust's change_while_released: releases a unit that can hold the
\ instance lock, runs the change, the name n's, and restores what the
\ release changed; the done text d states the finished change.
: RELEASED ( ^SERVICE:commands ^u8 n ^u8 n
     [ ^ARENA:arena -- ^VEC:vector<STALE:leftover> ] ^ARENA:arena -- )
   {: c n:^ nu:n d:^ du:n change ar :}
   ar DRIVENS-NEW {: v :}
   c SERVICE-GOAL:RELEASE v SERVICE:DRIVE-RECORDED
   change ar CHANGED {: left changed:n :}
   c v ar RESTORED {: launched:bool restored:n :}
   c n nu d du left changed launched restored ar DECIDED ;


\ ---- setup's local steps

\ A path FS refuses before stat: too long, or holding a NUL byte.
: STAT-CAUGHT ( n -- )
   {: code:n :}
   code E-FS-PATH = if FS:ENAMETOOLONG INSPECT-FAILED then
   code E-FFI-NUL = if 0 INSPECT-FAILED then
   code throw ;

\ Rust's refuse_existing_config: Path::try_exists is false only where
\ stat answers ENOENT.
: REFUSE-EXISTING ( CONFIG:abs-path -- )
   CONFIG:ABS-PATH>STR {: p :}
   false [: drop p str> FS:TRY-STAT ;] catch {: code:n :}
   code 0<> if code STAT-CAUGHT then
   if CONFIG-EXISTS then
   FS:ERRNO FS:ENOENT <> if FS:ERRNO INSPECT-FAILED then ;

\ Rust's Path::is_absolute.
: ABSOLUTE? ( str -- bool )
   str> {: a:^ u:n :}
   u 0= if false exit then
   a c@ [char] / = ;

\ dir/Dropbox, joined as PathBuf::join: no second separator.
: DROPBOX-IN ( str ^ARENA:arena -- str )
   {: h ar :}
   SB-RESET h str> SB-APPEND
   h str> + 1- c@ [char] / <> if [char] / SB-APPEND-C then
   s" Dropbox" SB-APPEND SB$ ar KEPT ;

\ The directory made 0700, under the umask; an entry already there
\ stays, as Rust's AlreadyExists does.
: MADE ( str -- )
   {: root :}
   [: root str> FS:MODE-PRIVATE-DIR FS:MKDIR-MODE ;] catch {: code:n :}
   code 0= if exit then
   code E-FS-IO = FS:ERRNO FS:EEXIST = and if exit then
   code E-FS-PATH = if root FS:ENAMETOOLONG CREATE-ROOT-FAILED then
   code E-FFI-NUL = if root 0 CREATE-ROOT-FAILED then
   code E-FS-IO = if root FS:ERRNO CREATE-ROOT-FAILED then
   code throw ;

\ Rust's create_default_sync_root for the home: home/Dropbox.
: HOME-ROOT ( option<str> ^ARENA:arena -- str )
   {: home ar :}
   home MATCH option
      some OF ENDOF
      none OF NO-DEFAULT-ROOT ENDOF
   ;MATCH {: h :}
   h ABSOLUTE? 0= if NO-DEFAULT-ROOT then
   h ar DROPBOX-IN {: root :}
   root MADE
   root ;

\ HOME/Dropbox, made where missing; a root named with --sync-root
\ must already exist, so a mistyped one fails instead.
: DEFAULT-ROOT ( ^ARENA:arena -- str )
   {: ar :}
   s" HOME" GETENV {: a:^ u:n :}
   a NULL-PTR = if NO-STR else a u >str OPTION:SOME then
   ar HOME-ROOT ;

\ The index of the first LF in the bytes from..to, or -1.
: LF-AT ( ^u8 n n -- n )
   {: b:^ from:n to:n :}
   to from ?do b i + c@ 10 = if i unloop exit then loop -1 ;

\ Reads into the buffer through the first LF, at most cap bytes: the
\ bytes read up to and including that LF.
: READ-LINE ( fd ^u8 n -- n )
   {: f:fd b:^ cap:n :}
   0 begin dup cap < while
      {: len:n :}
      f FD>N b len + cap len - read {: k:n :}
      k 0= if len exit then
      k 0 < if
         FS:ERRNO FD:EINTR# <> if s" read the authorization code" IO-FAILED then
         len
      else
         b len len k + LF-AT {: lf:n :}
         lf 0 >= if lf 1+ exit then
         len k +
      then
   repeat ;

\ Rust's str::trim: the bytes inside the leading and trailing Unicode
\ White_Space.
: TRIMMED ( ^u8 n -- ^u8 n )
   {: a:^ u:n :}
   u 0 0 begin dup u < while
      {: start:n end:n at:n :}
      a u at UTF8:NEXT MATCH UTF8:scalar-step
         scalar OF {: cp:n next:n :}
            cp UNICODE-CLASS:WHITE-SPACE? if start end next
            else start at min next next then
         ENDOF
         raw-byte OF {: byte:n next:n :} start at min next next ENDOF
      ;MATCH
   repeat drop {: start:n end:n :}
   start end >= if a 0 exit then
   a start + end start - ;

\ Rust's read_authorization_code: one line of at most CODE-LIMIT bytes
\ and its LF, read from f and trimmed.
: READ-CODE ( fd ^ARENA:arena -- str )
   {: f:fd ar :}
   ar CODE-LIMIT 1+ ARENA:ALLOC drop {: b:^ :}
   f b CODE-LIMIT 1+ READ-LINE {: u:n :}
   u CODE-LIMIT 1+ = if b u + 1- c@ 10 <> if INVALID-CODE then then
   b u UTF8:VALID? 0= if INVALID-CODE then
   b u TRIMMED {: c:^ cu:n :}
   cu 0= cu CODE-LIMIT > or if INVALID-CODE then
   c cu >str ;

\ Rust's InstanceLock::acquire for the paths.
: LOCKED ( ^CONFIG:paths ^ARENA:arena -- CONFIG:lock )
   {: p ar :}
   ar LOCKS-NEW {: slot :}
   [: p CONFIG:LOCK slot ! ;] catch {: code:n :}
   code 0<> if code LOCK-FAILED then
   slot @ ;

\ CONFIG:WRITE-NEW, whose refusal of an existing file is Rust's
\ InitialConfigExists.
: WRITTEN ( ^CONFIG:config ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: c ar :}
   NULL-PTR [: drop c ar CONFIG:WRITE-NEW ;] catch {: v code:n :}
   code 0= if v exit then
   code CONFIG:E-ALREADY-EXISTS = if CONFIG-EXISTS then
   code s" write initial configuration" CONFIG-FAILED ;

: HELD ( ^CONFIG:config bool [ -- ] ^ARENA:arena
     -- ^VEC:vector<STALE:leftover> )
   {: c w:bool bind ar :}
   w if c CONFIG:PATHS ar CONFIG:CONFIG-FILE REFUSE-EXISTING then
   bind execute
   w 0= if ar ARENA:ALLOCATOR 0 [type] STALE:leftover VEC:NEW exit then
   c ar WRITTEN ;

\ Rust's complete_setup: under the daemon lock, bind, then write a new
\ config where w asks for one and none appeared since setup began.
: COMPLETE-SETUP ( ^CONFIG:config bool [ -- ] ^ARENA:arena
     -- ^VEC:vector<STALE:leftover> )
   {: c w:bool bind ar :}
   c CONFIG:PATHS ar LOCKED {: l :}
   [: c w bind ar HELD ;] [: l CONFIG:UNLOCK ;] finally ;


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
      status OF ar XDG ar STATUS-TEXT str> WRITE-OUT ENDOF
      settings OF
         {: f :} ar XDG f ar SETTINGS-TEXT str> WRITE-OUT
      ENDOF
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
