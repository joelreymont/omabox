\ omabox.f - the omabox program (rust src/bin/omabox.rs), whose global
\ MAIN is the build's entry. PARSE reads the arguments as Rust's parse
\ does: help, version, status, pause, resume, settings [--json], settings
\ set-root PATH, service ACTION, logs and setup. A command that fails
\ exits 1, as Rust's main returning an error does.
\ A failure logs as CONFIG's refusals do: the library that failed logs
\ its own lines, then OMABOX logs Rust's CliError text and, where the
\ error has one, its help line; a SERVICE or ATTENTION failure is that
\ package's alone. A CONFIG refusal of an operation keeps CONFIG's code,
\ help and FS:ERRNO, as Rust's Config forwards its source's.
\ status and settings check the stored sync root once their text is
\ built: CONFIG logs its refusal of an unusable root, and the command
\ still writes its text and succeeds.
\ settings set-root is Rust's: the replacement config validated, then,
\ while the service is released and under the daemon lock, the new root
\ inspected, the config written and the journal, where there is one,
\ made to adopt the root.
\ setup is Rust's, with the Omarchy widget linked once its options are
\ parsed whole and before the config, so a refused link makes no
\ ~/Dropbox: the config made or loaded and its state prepared, a
\ browser login exchanged and checked against the account and remote
\ root while the service still syncs, then, with the service released
\ and under the daemon lock, the journal bound, the refresh token
\ stored and a new config written. DROPBOX's calls run under AIO's loop,
\ started for them alone.
\ From just before the release until the restore drive has run, SIGINT,
\ SIGTERM and SIGHUP are caught through SIGNAL's pipe: one ends the window
\ at its next step as a failure would, and after the restore drive the CLI
\ dies of it, with the status its default gives.
\ STORAGE CLASS. CALLER-OWNED: a command's service commands, drive
\ record, released window, configuration, text, lock, default root,
\ authorization code, root binding, Dropbox client, login and journal
\ live in an arena the run holds, as does every text holding a path,
\ the app key or the login URL; help and the version line alone, whose
\ text is fixed, are built in string.f's task-local builder.
\ PROCESS-WIDE: SIGNAL's facility, set up by RELEASED and released when
\ the window closes, on the main thread.
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
require src/lib/secret.f
require src/lib/json/write.f
require src/lib/signal.f
require src/lib/at-exit.f
require src/lib/process.f
require src/lib/fsm.f
require src/config.f
require src/auth.f
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
-101112 s" a Dropbox authorization step failed" ERROR:CODE E-AUTH
-101113 s" a Dropbox account or root check failed" ERROR:CODE E-DROPBOX
-101114 s" Dropbox authorization returned a different account"
   ERROR:CODE E-ACCOUNT-CHANGED
-101115
   s" this Omabox journal is already bound to a different Dropbox account or root"
   ERROR:CODE E-BINDING-MISMATCH
-101116 s" could not inspect the sync folder" ERROR:CODE E-SYNC-ROOT
-101117
   s" could not inspect the Omabox journal before changing the sync root"
   ERROR:CODE E-INSPECT-JOURNAL
-101118
   s" ~/.config/omarchy/plugins/local.omabox is not the Omabox widget's link"
   ERROR:CODE E-WIDGET-TAKEN
-101119 s" HOME must be an absolute path to link the Omarchy widget"
   ERROR:CODE E-NO-HOME
-101120 s" could not link the Omarchy widget" ERROR:CODE E-LINK-WIDGET

private

\ Appends the line and its LF.
: LINE+ ( str -- ) SB-APPEND 10 SB-APPEND-C ;

\ Rust's HELP, with the usage lines of the commands PARSE knows.
: HELP-TEXT ( -- str )
   SB-RESET
   s" Omabox synchronizes a local directory with Dropbox." LINE+
   s" " LINE+
   s" Usage:" LINE+
   s"   omabox setup [REMOTE_ROOT]" LINE+
   s"   omabox setup --app-key KEY [--sync-root PATH]" SB-APPEND
   s"  [--remote-root ROOT]" LINE+
   s"   omabox status" LINE+
   s"   omabox pause|resume" LINE+
   s"   omabox settings [--json]" LINE+
   s"   omabox settings set-root PATH" LINE+
   s"   omabox service start|stop|restart|enable|disable|status" LINE+
   s"   omabox logs" LINE+
   s"   omabox --help" LINE+
   s"   omabox --version" LINE+
   s" " LINE+
   s" Setup with --app-key syncs ~/Dropbox, creating it if missing,"
   SB-APPEND s"  unless --sync-root" LINE+
   s" names another existing directory. The Dropbox app key is"
   SB-APPEND s"  public. Omabox never" LINE+
   s" requests or stores an app secret." LINE+
   SB$ ;

: VERSION-LINE ( -- str )
   SB-RESET s" omabox " SB-APPEND RELEASE:VERSION$ LINE+ SB$ ;

\ Rust's Settings { json }: how settings shows the stored settings.
ENUM form DERIVE eq text json ;ENUM

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

\ Rust's Command, the forms this program parses. It derives no eq: a
\ str or option payload has none.
ENUM command
   VARIANT help ;VARIANT
   VARIANT version ;VARIANT
   VARIANT status ;VARIANT
   VARIANT settings FIELD shown form ;VARIANT
   VARIANT set-root FIELD path str ;VARIANT
   VARIANT service FIELD action SERVICE:action ;VARIANT
   VARIANT logs ;VARIANT
   VARIANT setup FIELD options setup-options ;VARIANT
;ENUM

\ Rust's Authorized: a Dropbox login checked against the account and
\ root, not yet stored.
STRUCTURE authorized DERIVE addr
   FIELD binding JOURNAL:dropbox-binding
   FIELD refresh-token str
;STRUCTURE

\ Rust's AUTHORIZATION_CODE_LIMIT, in bytes.
8192 constant CODE-LIMIT
ARENA DRIVENS SERVICE:driven
ARENA WRITERS JSON:writer
ARENA LOCKS CONFIG:lock
ARENA BINDINGS JOURNAL:local-root-binding
ARENA LOGINS authorized
ARENA CLIENT-CONFIGS DROPBOX:config
ARENA JOURNALS JOURNAL:journal


\ ---- errors

: LOG-OPEN ( -- ) LOG:ERROR s" omabox" LOG:LINE ;

\ Ends the error's line and opens its help line with the text.
: HELP ( str -- )
   {: h:str :}
   LOG:;LINE LOG-OPEN s" help: " LOG:TEXT+ h LOG:TEXT+ ;

\ Ends Rust's Usage after its fault: the pointer to --help.
: USAGE-END ( -- )
   s" Run `omabox --help` for usage." HELP
   LOG:;LINE E-USAGE throw ;

\ Rust's Usage: the fault, then the pointer to --help.
: USAGE ( str -- )
   {: m:str :}
   LOG-OPEN m LOG:TEXT+ USAGE-END ;

\ Rust's dropbox_root fault, a Usage.
: ROOT-FAULT ( -- )
   LOG-OPEN
   s" the Dropbox root must be empty or an absolute folder path" LOG:TEXT+
   s"  such as /Work, with no trailing slash and no empty, . or .."
   LOG:TEXT+ s"  parts" LOG:TEXT+ USAGE-END ;

\ Rust's Io for the operation; the cause stays FS:ERRNO's on entry.
: IO-FAILED ( str -- )
   {: op:str :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op LOG:TEXT+
   s" Check the terminal input and output, then retry." HELP
   LOG:;LINE cause FS:CAUSE! E-IO throw ;

: CONFIG-CODE? ( n -- bool )
   {: c:n :}
   c CONFIG:E-LAST >= c CONFIG:E-FIRST <= and ;

\ Rust's Config for the operation, after CONFIG's own lines; a code of
\ another package goes on.
: CONFIG-FAILED ( n str -- )
   {: code:n op:str :}
   code CONFIG-CODE? 0= if code throw then
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op LOG:TEXT+
   LOG:;LINE cause FS:CAUSE! code throw ;

: SERIALIZE-FAILED ( -- )
   LOG-OPEN s" could not serialize settings output" LOG:TEXT+
   s" Use `omabox settings` for human-readable output." HELP
   LOG:;LINE 0 FS:CAUSE! E-SERIALIZE-OUTPUT throw ;

\ Rust's ChangeAndRestore's line for the change c.
: CHANGE-AND-RESTORE-TOLD ( str -- )
   {: c:str :}
   LOG-OPEN c LOG:TEXT+
   s"  failed, and the Omabox service could not be restarted;"
   LOG:TEXT+
   s"  run `omabox resume` once the errors above are fixed" LOG:TEXT+
   LOG:;LINE ;

\ Rust's ChangeAndRestore, after the change's lines and the restore's.
: CHANGE-AND-RESTORE ( str -- )
   {: c:str :}
   FS:ERRNO {: cause:n :}
   c CHANGE-AND-RESTORE-TOLD
   cause FS:CAUSE! E-CHANGE-AND-RESTORE throw ;

\ Rust's StartAfterChange's error and help lines for the done text d.
: START-AFTER-CHANGE-TOLD ( str -- )
   {: d:str :}
   LOG-OPEN d LOG:TEXT+
   s" , but the Omabox service could not be started or checked"
   LOG:TEXT+
   s" The change is kept. Run `omabox status` and `omabox logs` to see why, then `omabox resume`."
   HELP LOG:;LINE ;

\ Rust's StartAfterChange for the done text, after the drive's lines.
: START-AFTER-CHANGE ( str -- )
   {: d:str :}
   FS:ERRNO {: cause:n :}
   d START-AFTER-CHANGE-TOLD
   cause FS:CAUSE! E-START-AFTER-CHANGE throw ;

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

\ Rust's Journal for the operation, in place of the code caught,
\ after the lines its cause logged.
: JOURNAL-FAILED ( n str -- )
   {: op:str :} drop
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op LOG:TEXT+
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
   {: root:str cause:n :}
   LOG-OPEN s" could not create the default sync root " LOG:TEXT+
   root LOG:TEXT+
   s" Create the directory, or pass --sync-root PATH." HELP
   E-CREATE-DEFAULT-ROOT cause FAIL ;

: WIDGET-TAKEN ( str -- )
   {: link:str :}
   LOG-OPEN link LOG:TEXT+
   s"  is not the Omabox widget's link" LOG:TEXT+
   s" Move what is there, then run `omabox setup` again." HELP
   E-WIDGET-TAKEN 0 FAIL ;

: NO-HOME ( -- )
   LOG-OPEN s" HOME must be an absolute path to link the Omarchy" LOG:TEXT+
   s"  widget" LOG:TEXT+
   s" Set HOME, then run `omabox setup` again." HELP
   E-NO-HOME 0 FAIL ;

: LINK-FAILED ( str n -- )
   {: link:str cause:n :}
   LOG-OPEN s" could not link the Omarchy widget at " LOG:TEXT+
   link LOG:TEXT+
   s" Make ~/.config/omarchy/plugins a writable folder," HELP
   s"  then run `omabox setup` again." LOG:TEXT+
   E-LINK-WIDGET cause FAIL ;

\ Whether code lies in the block from first down to last.
: IN? ( n n n -- bool )
   {: code:n first:n last:n :}
   code first <= code last >= and ;

\ AUTH's codes and the SECRET codes AUTH passes on: Rust's AuthError.
: AUTH-CODE? ( n -- bool )
   {: c:n :}
   c AUTH:E-FIRST AUTH:E-LAST IN?
   c SECRET:E-FIRST SECRET:E-LAST IN? or ;

: DROPBOX-CODE? ( n -- bool ) DROPBOX:E-FIRST DROPBOX:E-LAST IN? ;

\ Rust's Auth for the operation, after the lines its cause logged.
: AUTH-FAILED ( str -- )
   {: op:str :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op LOG:TEXT+
   s" Check the network connection and Dropbox app key," HELP
   s"  then retry setup." LOG:TEXT+
   E-AUTH cause FAIL ;

: EXCHANGE-FAILED ( -- )
   s" exchange the Dropbox authorization code" AUTH-FAILED ;

\ Rust's AuthError::Sdk, a line of its own where DROPBOX logged none.
: NOT-ISSUED ( -- )
   LOG-OPEN s" Dropbox OAuth could not issue an access token"
   LOG:TEXT+ LOG:;LINE ;

\ Rust's Dropbox validating the account and root, after the lines its
\ cause logged.
: VALIDATE-FAILED ( -- )
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not validate the Dropbox account and root"
   LOG:TEXT+
   s" Check the selected Dropbox root and account permissions," HELP
   s"  then retry setup." LOG:TEXT+
   E-DROPBOX cause FAIL ;

\ Rust's line for a remote root LINK refused, then VALIDATE-FAILED.
: ROOT-REFUSED ( str -- )
   {: m:str :}
   LOG-OPEN s" configured Dropbox root " LOG:TEXT+ m LOG:TEXT+
   LOG:;LINE VALIDATE-FAILED ;

: ACCOUNT-CHANGED ( -- )
   LOG-OPEN s" Dropbox authorization returned a different account"
   LOG:TEXT+
   s" Restart setup and authorize one Dropbox account for the" HELP
   s"  entire flow." LOG:TEXT+
   E-ACCOUNT-CHANGED 0 FAIL ;

: BINDING-MISMATCH ( -- )
   LOG-OPEN s" this Omabox journal is already bound to a different"
   LOG:TEXT+ s"  Dropbox account or root" LOG:TEXT+
   s" Use the Dropbox account and remote root originally" HELP
   s"  selected for this sync root." LOG:TEXT+
   E-BINDING-MISMATCH 0 FAIL ;

\ Rust's SyncRoot, in place of the code it caught, after the lines its
\ cause logged, all Rust's JournalError.
: SYNC-ROOT-FAILED ( n -- )
   drop FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not inspect the sync folder" LOG:TEXT+
   s" Ensure the sync folder exists, is readable and is on a filesystem"
   HELP s"  that records file creation times, or choose another folder."
   LOG:TEXT+ E-SYNC-ROOT cause FAIL ;

: INSPECT-JOURNAL-FAILED ( n -- )
   {: cause:n :}
   LOG-OPEN s" could not inspect the Omabox journal before changing the"
   LOG:TEXT+ s"  sync root" LOG:TEXT+
   s" Ensure the Omabox state directory is accessible and retry." HELP
   E-INSPECT-JOURNAL cause FAIL ;


\ ---- output

\ A closed reader refuses the write rather than ending the process.
: WRITE-FULL ( str -- )
   {: s:str :}
   FD:STDOUT [: FD:STDOUT s FD:WRITE-FULL ;] FD:WITH-NOSIGPIPE ;

: WRITE-OUT ( str -- )
   {: s:str :}
   [: s WRITE-FULL ;] catch {: code:n :}
   code 0<> if s" write command output" IO-FAILED then ;

\ The text, then the leftovers' lines, with SIGPIPE held off.
: REPORT-FULL ( str ^VEC:vector<STALE:leftover> -- )
   {: s:str left :}
   FD:STDOUT [:
      FD:STDOUT s FD:WRITE-FULL
      left FD:STDOUT STALE:REPORT
   ;] FD:WITH-NOSIGPIPE ;

: REPORT-OUT ( str ^VEC:vector<STALE:leftover> -- )
   {: s:str left :}
   [: s left REPORT-FULL ;] catch {: code:n :}
   code 0<> if s" write command output" IO-FAILED then ;


\ ---- parsing

: HELP? ( str -- bool )
   {: a:str :}
   a s" --help" STR:= a s" -h" STR:= or a s" help" STR:= or ;

: VERSION? ( str -- bool )
   {: a:str :}
   a s" --version" STR:= a s" -V" STR:= or ;

: ACTION-COMMAND ( SERVICE:action -- option<command> )
   COMMAND-SERVICE OPTION:SOME ;

\ The command a name alone selects, none for one that takes arguments
\ or is unknown.
: ALONE ( str -- option<command> )
   {: a:str :}
   a HELP? if construct command help OPTION:SOME exit then
   a VERSION? if construct command version OPTION:SOME exit then
   a s" pause" STR:= if
      SERVICE-ACTION:STOP ACTION-COMMAND exit
   then
   a s" resume" STR:= if
      SERVICE-ACTION:START ACTION-COMMAND exit
   then
   a s" status" STR:= if construct command status OPTION:SOME exit then
   a s" logs" STR:= if construct command logs OPTION:SOME exit then
   OPTION:NONE ;

\ Rust's parse_service's action; bytes that are not UTF-8 name none.
: ACTION ( str -- SERVICE:action )
   {: a:str :}
   a s" start" STR:= if SERVICE-ACTION:START exit then
   a s" stop" STR:= if SERVICE-ACTION:STOP exit then
   a s" restart" STR:= if SERVICE-ACTION:RESTART exit then
   a s" enable" STR:= if SERVICE-ACTION:ENABLE exit then
   a s" disable" STR:= if SERVICE-ACTION:DISABLE exit then
   a s" status" STR:= if SERVICE-ACTION:STATUS exit then
   s" unknown service action" USAGE ;

: PARSE-SERVICE ( n [ n -- str ] -- command )
   {: argc:n arg :}
   argc 2 <> if s" service requires exactly one action" USAGE then
   1 arg execute ACTION COMMAND-SERVICE ;

\ Rust's parse_settings; set-root takes its path as any bytes, as
\ PathBuf::from does.
: PARSE-SETTINGS ( n [ n -- str ] -- command )
   {: argc:n arg :}
   argc 1 = if construct form text COMMAND-SETTINGS exit then
   argc 2 = if
      1 arg execute s" --json" STR:= if
         construct form json COMMAND-SETTINGS exit
      then
   then
   argc 3 = if
      1 arg execute s" set-root" STR:= if
         2 arg execute COMMAND-SET-ROOT exit
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

\ Rust's is_option.
: OPTION-ARG? ( str -- bool ) s" --" STR:STARTS-WITH? ;

\ Rust's utf8: the bytes, or Usage with the fault m.
: VALID-ARG ( str str -- str )
   {: a:str m:str :}
   a UTF8:VALID? 0= if m USAGE then
   a ;

\ Rust's dropbox_root, refused before setup sends the user through the
\ browser.
: REMOTE-ROOT ( str -- str )
   s" the Dropbox root must be valid UTF-8" VALID-ARG {: r :}
   r DROPBOX:ROOT-PATH? 0= if ROOT-FAULT then
   r ;

: NO-STR ( -- option<str> ) OPTION:NONE ;

\ The value after the option at index at.
: VALUE ( n [ n -- str ] n -- str )
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
: STEP ( option<str> option<str> option<str> n [ n -- str ] n
     -- option<str> option<str> option<str> )
   {: sync key remote argc:n arg at:n :}
   at arg execute {: o:str :}
   o UTF8:VALID? 0= if s" setup options must be valid UTF-8" USAGE then
   o s" --sync-root" STR:= if
      sync UNSET argc arg at VALUE OPTION:SOME key remote exit
   then
   o s" --app-key" STR:= if
      key UNSET sync argc arg at VALUE
      s" the Dropbox app key must be valid UTF-8" VALID-ARG OPTION:SOME
      remote exit
   then
   o s" --remote-root" STR:= if
      remote UNSET sync key argc arg at VALUE REMOTE-ROOT OPTION:SOME exit
   then
   s" unknown setup option" USAGE ;

\ The sync root, app key and remote root the options from index 1 give.
: SETUP-FLAGS ( n [ n -- str ] -- option<str> option<str> option<str> )
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
      none OF s" " ENDOF
   ;MATCH
   sync k INITIAL-CONFIG-MAKE OPTION:SOME SETUP-OPTIONS-MAKE ;

: NO-INITIAL ( -- option<initial-config> ) OPTION:NONE ;

\ Setup of the stored configuration, for the remote root.
: STORED-SETUP ( str -- setup-options ) NO-INITIAL SETUP-OPTIONS-MAKE ;

\ Rust's parse_setup over the whole argument list, index 0 being setup.
: PARSE-SETUP ( n [ n -- str ] -- setup-options )
   {: argc:n arg :}
   argc 1 = if s" " STORED-SETUP exit then
   argc 2 = if
      1 arg execute OPTION-ARG? 0= if
         1 arg execute REMOTE-ROOT STORED-SETUP exit
      then
   then
   argc arg SETUP-FLAGS FLAGGED ;

\ Rust's parse over argc arguments, arg answering the one at an index.
: PARSE ( n [ n -- str ] -- command )
   {: argc:n arg :}
   argc 0= if s" a command is required" USAGE then
   0 arg execute {: c:str :}
   c UTF8:VALID? 0= if
      s" the command must be valid UTF-8" USAGE
   then
   c s" settings" STR:= if argc arg PARSE-SETTINGS exit then
   c s" service" STR:= if argc arg PARSE-SERVICE exit then
   c s" setup" STR:= if argc arg PARSE-SETUP COMMAND-SETUP exit then
   c ALONE argc SOLE ;


\ ---- the configuration
\ Each step's failure is Rust's Config for its operation, op where given.

: XDG ( ^ARENA:arena -- ^CONFIG:xdg )
   {: ar :}
   NULL-PTR [: drop ar CONFIG:XDG-ENV ;] catch {: x code :}
   code 0= if x exit then
   code s" resolve XDG paths" CONFIG-FAILED ;

: DOCUMENT ( ^CONFIG:xdg str ^ARENA:arena -- ^CONFIG:document )
   {: x op:str ar :}
   NULL-PTR [: drop x ar CONFIG:DOCUMENT-LOAD-FROM ;] catch {: d code :}
   code 0= if d exit then
   code op CONFIG-FAILED ;

: STATE-PATHS ( ^CONFIG:xdg str ^ARENA:arena -- ^CONFIG:paths )
   {: x op:str ar :}
   NULL-PTR [: drop x ar CONFIG:RESOLVE-PRIVATE ;] catch {: p code :}
   code 0= if p exit then
   code op CONFIG-FAILED ;

\ Rust's unusable_root_line: CONFIG logs its refusal of the stored root,
\ which leaves the command's text standing; any other code goes on.
: ROOT-CHECKED ( ^CONFIG:document ^CONFIG:xdg ^ARENA:arena -- )
   {: d x ar :}
   [: d x ar CONFIG:VALIDATE drop ;] catch {: code:n :}
   code 0= if exit then
   code CONFIG-CODE? 0= if code throw then ;


\ ---- status and settings

\ The str s, then the str t, copied into the arena as ARENA:COPY copies; s
\ stays as it was.
: FOLLOWED ( str str ^ARENA:arena -- str )
   {: s:str t:str ar :}
   s str> {: sa:^ su:n :}
   t str> {: a:^ u:n :}
   ar su u + ARENA:ALLOC drop {: d:^ :}
   sa d su BYTE-COPY
   a d su + u BYTE-COPY
   d su u + >str ;

\ Rust's status_output: the journal's text.
: STATUS-TEXT ( ^CONFIG:xdg ^ARENA:arena -- str )
   {: x ar :}
   x s" load configuration" ar DOCUMENT {: d :}
   x s" resolve state paths" ar STATE-PATHS {: p :}
   p CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR ar ATTENTION:RENDER {: t :}
   d x ar ROOT-CHECKED
   t ;

: SETTINGS-LINES ( ^CONFIG:document ^ARENA:arena -- str )
   {: d ar :}
   s" Sync root: " ar ARENA:COPY
   d CONFIG:DOCUMENT-ROOT CONFIG:ABS-PATH>STR ar FOLLOWED
   S\" \nDropbox app key: " ar FOLLOWED
   d CONFIG:DOCUMENT-KEY ar FOLLOWED S\" \n" ar FOLLOWED ;

: SETTINGS-FIELDS ( ^CONFIG:document ^JSON:writer -- )
   {: d w :}
   w 2 JSON:WRITE-INDENT! JSON:WRITE-OBJECT-START
   s" sync_root" d CONFIG:DOCUMENT-ROOT CONFIG:ABS-PATH>STR
   JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" dropbox_app_key" d CONFIG:DOCUMENT-KEY JSON:WRITE-FIELD-S
   JSON:WRITE-OBJECT-END drop ;

\ serde_json's to_string_pretty of the document, then LF; text that
\ is not UTF-8 is Rust's SerializeOutput.
: SETTINGS-JSON ( ^CONFIG:document ^ARENA:arena -- str )
   {: d ar :}
   ar ARENA:ALLOCATOR 0 [type] u8 VEC:NEW {: v :}
   ar WRITERS-NEW v JSON:OPEN {: w :}
   [: d w SETTINGS-FIELDS ;] catch {: code:n :}
   code E-JSON-WRITE-BYTE = if SERIALIZE-FAILED then
   code 0<> if code throw then
   w JSON:CLOSE
   10 v VEC:PUSH c!
   v VEC:SPAN SPAN:$ ;

\ Rust's settings_output: the stored settings, as text or JSON.
: SETTINGS-TEXT ( ^CONFIG:xdg form ^ARENA:arena -- str )
   {: x f ar :}
   x s" load configuration" ar DOCUMENT {: d :}
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
: RECOVERED ( ^SERVICE:commands bool str ^ARENA:arena -- bool )
   {: c launched:bool d:str ar :}
   launched if false exit then
   ar DRIVENS-NEW {: v :}
   c SERVICE-GOAL:RECOVER v SERVICE:DRIVE-RECORDED
   0<> if d START-AFTER-CHANGE then
   v SERVICE-DRIVEN:LAUNCHED @ ;

: NOTE ( bool -- str )
   if s"  The stopped service has been started again." exit then s" " ;

\ "{done}.{note}", LF and the leftovers' lines on stdout, the text
\ built in ar.
: DONE-OUT ( str bool ^VEC:vector<STALE:leftover> ^ARENA:arena -- )
   {: d:str recovered:bool left ar :}
   d ar ARENA:COPY s" ." ar FOLLOWED recovered NOTE ar FOLLOWED
   S\" \n" ar FOLLOWED left REPORT-OUT ;

\ Rust's match on the change's outcome and the restore's: c the
\ commands, n the change's name, d its done text.
: DECIDED ( ^SERVICE:commands str str
     ^VEC:vector<STALE:leftover> n bool n ^ARENA:arena -- )
   {: c n:str d:str left changed:n
      launched:bool restored:n ar :}
   changed 0<> restored 0<> and if n CHANGE-AND-RESTORE then
   changed 0<> if changed throw then
   restored 0<> if d START-AFTER-CHANGE then
   c launched d ar RECOVERED {: recovered:bool :}
   d recovered left ar DONE-OUT ;


\ ---- setup's local steps

\ The errno of a path FS refuses before stat: ENAMETOOLONG for one too
\ long, 0 for one holding a NUL byte; any other code goes on.
: STAT-CAUSE ( n -- n )
   {: code:n :}
   code E-FS-PATH = if FS:ENAMETOOLONG exit then
   code E-FFI-NUL = if 0 exit then
   code throw ;

\ Rust's Path::try_exists of p: false only where stat answers ENOENT;
\ fail, which throws, takes the errno of any other failure.
: EXISTS? ( str [ n -- ] -- bool )
   {: p fail :}
   false [: drop p FS:TRY-STAT ;] catch {: there code:n :}
   code 0<> if code STAT-CAUSE fail execute code throw then
   there if true exit then
   FS:ERRNO FS:ENOENT <> if FS:ERRNO fail execute then
   false ;

\ Rust's refuse_existing_config.
: REFUSE-EXISTING ( CONFIG:abs-path -- )
   CONFIG:ABS-PATH>STR [: INSPECT-FAILED ;] EXISTS?
   if CONFIG-EXISTS then ;

\ Rust's Path::is_absolute.
: ABSOLUTE? ( str -- bool )
   str> {: a:^ u:n :}
   u 0= if false exit then
   a c@ [char] / = ;

\ dir/name, joined as PathBuf::join: no second separator.
: IN-DIR ( str str ^ARENA:arena -- str )
   {: d:str name:str ar :}
   d d str> + 1- c@ [char] / <> if s" /" ar FOLLOWED then
   name ar FOLLOWED ;

\ The home where it is absolute; fail, which throws, refuses a missing
\ or relative one.
: ABSOLUTE-HOME ( option<str> [ -- ] -- str )
   {: home fail :}
   home MATCH option
      some OF ENDOF
      none OF s" " ENDOF
   ;MATCH {: h :}
   h ABSOLUTE? 0= if fail execute then
   h ;

\ HOME from the environment, none where unset.
: HOME-ENV ( -- option<str> )
   s" HOME" GETENV {: h:str :}
   h str> drop NULL-PTR = if NO-STR else h OPTION:SOME then ;

\ The directory made 0700, under the umask; an entry already there
\ stays, as Rust's AlreadyExists does.
: MADE ( str -- )
   {: root :}
   [: root FS:MODE-PRIVATE-DIR FS:MKDIR-MODE ;] catch {: code:n :}
   code 0= if exit then
   code E-FS-IO = FS:ERRNO FS:EEXIST = and if exit then
   code E-FS-PATH = if root FS:ENAMETOOLONG CREATE-ROOT-FAILED then
   code E-FFI-NUL = if root 0 CREATE-ROOT-FAILED then
   code E-FS-IO = if root FS:ERRNO CREATE-ROOT-FAILED then
   code throw ;

\ Rust's create_default_sync_root for the home: home/Dropbox.
: HOME-ROOT ( option<str> ^ARENA:arena -- str )
   {: home ar :}
   home [: NO-DEFAULT-ROOT ;] ABSOLUTE-HOME
   s" Dropbox" ar IN-DIR {: root :}
   root MADE
   root ;

\ The errno behind a code FS threw: FS:ERRNO for E-FS-IO, else
\ STAT-CAUSE's.
: FS-CAUSE ( n -- n )
   {: code:n :}
   code E-FS-IO = if FS:ERRNO exit then
   code STAT-CAUSE ;

\ The widget the package installs.
: WIDGET ( -- str ) s" /usr/share/omabox/omarchy/plugins/local.omabox" ;

\ Omarchy's plugins folder under the home: Omarchy reads $HOME/.config,
\ never XDG_CONFIG_HOME (omarchy-plugin-add:14).
: PLUGINS-DIR ( option<str> ^ARENA:arena -- str )
   {: home ar :}
   home [: NO-HOME ;] ABSOLUTE-HOME
   s" .config/omarchy/plugins" ar IN-DIR ;

\ Whether link is the widget's link; false only where readlink answers
\ ENOENT. Another link, a file or a folder (EINVAL) is WIDGET-TAKEN.
: WIDGET-THERE? ( str ^ARENA:arena -- bool )
   {: link ar :}
   link ar CONFIG:READLINK MATCH option
      some OF WIDGET STR:= 0= if link WIDGET-TAKEN then true ENDOF
      none OF false ENDOF
   ;MATCH if true exit then
   FS:ERRNO FS:EINVAL = if link WIDGET-TAKEN then
   FS:ERRNO FS:ENOENT <> if link FS:ERRNO LINK-FAILED then
   false ;

\ The folders to dir and the widget's link at link, made.
: WIDGET-MADE ( str str -- )
   {: dir link :}
   [: dir FS:MAKE-DIRS WIDGET link FS:MAKE-SYMLINK ;] catch
   {: code:n :}
   code 0<> if link code FS-CAUSE LINK-FAILED then ;

\ The widget linked under the home, where its link is not already there.
: HOME-WIDGET ( option<str> ^ARENA:arena -- )
   {: home ar :}
   home ar PLUGINS-DIR {: dir :}
   dir s" local.omabox" ar IN-DIR {: link :}
   link ar WIDGET-THERE? if exit then
   dir link WIDGET-MADE ;

\ HOME/Dropbox, made where missing; a root named with --sync-root
\ must already exist, so a mistyped one fails instead.
: DEFAULT-ROOT ( ^ARENA:arena -- str )
   {: ar :}
   HOME-ENV ar HOME-ROOT ;

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
: TRIMMED ( str -- str )
   {: s:str :}
   s str> {: a:^ u:n :}
   u 0 0 begin dup u < while
      {: start:n end:n at:n :}
      s at UTF8:NEXT MATCH UTF8:scalar-step
         scalar OF {: cp:n next:n :}
            cp UNICODE-CLASS:WHITE-SPACE? if start end next
            else start at min next next then
         ENDOF
         raw-byte OF {: byte:n next:n :} start at min next next ENDOF
      ;MATCH
   repeat drop {: start:n end:n :}
   start end >= if a 0 >str exit then
   a start + end start - >str ;

\ Rust's read_authorization_code: one line of at most CODE-LIMIT bytes
\ and its LF, read from f and trimmed.
: READ-CODE ( fd ^ARENA:arena -- str )
   {: f:fd ar :}
   ar CODE-LIMIT 1+ ARENA:ALLOC drop {: b:^ :}
   f b CODE-LIMIT 1+ READ-LINE {: u:n :}
   u CODE-LIMIT 1+ = if b u + 1- c@ 10 <> if INVALID-CODE then then
   b u >str {: line:str :}
   line UTF8:VALID? 0= if INVALID-CODE then
   line TRIMMED {: c:str :}
   c STR:len {: cu:n :}
   cu 0= cu CODE-LIMIT > or if INVALID-CODE then
   c ;

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


\ ---- the sync-root change

\ Rust's LocalRootBinding::inspect of the replacement's root.
: ROOT-BINDING ( ^CONFIG:config ^ARENA:arena -- JOURNAL:local-root-binding )
   {: r ar :}
   r CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR {: root :}
   ar BINDINGS-NEW {: slot :}
   [: root JOURNAL:INSPECT slot ! ;] catch {: code:n :}
   code 0<> if code SYNC-ROOT-FAILED then
   slot @ ;

\ Rust's Journal::open of the file p, failing as Journal for the
\ operation.
: JOURNAL-OPENED ( str str ^ARENA:arena -- JOURNAL:journal )
   {: p op:str ar :}
   ar JOURNALS-NEW {: slot :}
   [: p JOURNAL:OPEN slot ! ;] catch {: code:n :}
   code 0<> if code op JOURNAL-FAILED then
   slot @ ;

\ The replacement written over config.toml: the stale temporaries the
\ write left in place.
: ROOT-WRITTEN ( ^CONFIG:config ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: r ar :}
   NULL-PTR [: drop r ar CONFIG:WRITE ;] catch {: v code:n :}
   code 0= if v exit then
   code s" write the new sync root" CONFIG-FAILED ;

\ ROOT-WRITTEN, then the journal adopts the root the binding names.
: ADOPTED ( JOURNAL:journal JOURNAL:local-root-binding ^CONFIG:config
     ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: j b r ar :}
   r ar ROOT-WRITTEN {: left :}
   [: j b ar JOURNAL:ADOPT-LOCAL-ROOT drop ;] catch {: code:n :}
   code 0<> if code s" adopt the selected sync root" JOURNAL-FAILED then
   left ;

\ The change under the lock: the journal, opened where it exists, is
\ closed on every path out.
: ROOT-CHANGED ( ^CONFIG:paths ^CONFIG:config ^ARENA:arena
     -- ^VEC:vector<STALE:leftover> )
   {: p r ar :}
   r ar ROOT-BINDING {: b :}
   p CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR {: jp :}
   jp [: INSPECT-JOURNAL-FAILED ;] EXISTS? 0= if
      r ar ROOT-WRITTEN exit
   then
   jp s" open the sync journal before changing the sync root" ar
   JOURNAL-OPENED {: j :}
   [: j b r ar ADOPTED ;] [: j JOURNAL:CLOSE ;] finally ;

\ Rust's change_sync_root_while_stopped under the daemon lock, which
\ is released on every path out.
: CHANGE-ROOT ( ^CONFIG:paths ^CONFIG:config ^ARENA:arena
     -- ^VEC:vector<STALE:leftover> )
   {: p r ar :}
   p ar LOCKED {: l :}
   [: p r ar ROOT-CHANGED ;] [: l CONFIG:UNLOCK ;] finally ;

\ Rust's Config::from_values of the root and key, failing as Config for
\ the operation.
: VALIDATED ( ^CONFIG:xdg str str str ^ARENA:arena -- ^CONFIG:config )
   {: x root key op:str ar :}
   NULL-PTR [: drop x root key ar CONFIG:FROM-VALUES ;] catch {: c code :}
   code 0= if c exit then
   code op CONFIG-FAILED ;

\ "Omabox sync root is now {root}", kept in the arena.
: ROOT-DONE ( ^CONFIG:config ^ARENA:arena -- str )
   {: r ar :}
   s" Omabox sync root is now " ar ARENA:COPY
   r CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR ar FOLLOWED ;


\ ---- the login

\ AUTH:START for the app key k, Rust's Auth starting authorization.
: STARTED ( str ^ARENA:arena -- ^AUTH:pending )
   {: k ar :}
   NULL-PTR [: drop k ar AUTH:START ;] catch {: p code:n :}
   code 0= if p exit then
   code AUTH-CODE? 0= if code throw then
   s" start Dropbox authorization" AUTH-FAILED ;

\ Rust's prompt for the login p, on stdout, built in ar.
: PROMPT ( ^AUTH:pending ^ARENA:arena -- )
   {: p ar :}
   S\" Open this URL in a browser:\n" ar ARENA:COPY p AUTH:URL ar FOLLOWED
   S\" \n\nPaste the authorization code: " ar FOLLOWED WRITE-OUT ;

\ The token store of a client that keeps nothing.
: KEEP-NONE ( str -- ) drop ;

\ A client for the app key k on Dropbox's origins: no token yet, the
\ account's own root, and a store that keeps nothing.
: CLIENT ( str ^ARENA:arena -- ^DROPBOX:client )
   {: k ar :}
   ar CLIENT-CONFIGS-NEW {: cfg :}
   cfg DROPBOX:PRODUCTION
   k str> SPAN:MAKE cfg DROPBOX-CONFIG:KEY !
   s" " str> SPAN:MAKE cfg DROPBOX-CONFIG:TOKEN !
   [: KEEP-NONE ;] cfg DROPBOX-CONFIG:STORE !
   s" " str> SPAN:MAKE cfg DROPBOX-CONFIG:ROOT !
   cfg ar DROPBOX:OPEN ;

: EXCHANGE-DONE ( str ^AUTH:pending ^DROPBOX:client -- )
   {: ac p cl :}
   ac p AUTH:VERIFIER cl DROPBOX:EXCHANGE DROPBOX:DONE?
   if exit then
   NOT-ISSUED EXCHANGE-FAILED ;

\ DROPBOX:EXCHANGE of the code ac and the login p's verifier.
: EXCHANGED ( str ^AUTH:pending ^DROPBOX:client -- )
   {: ac p cl :}
   [: ac p cl EXCHANGE-DONE ;] catch {: code:n :}
   code 0= if exit then
   code DROPBOX-CODE? 0= if code throw then
   EXCHANGE-FAILED ;

: LINK-CHECKED ( str ^DROPBOX:client ^ARENA:arena -- )
   {: r cl ar :}
   r cl ar DROPBOX:LINK MATCH DROPBOX:root-check
      valid OF ENDOF
      failed OF drop VALIDATE-FAILED ENDOF
      unbound OF ACCOUNT-CHANGED ENDOF
      unavailable OF s" is unavailable" ROOT-REFUSED ENDOF
      not-folder OF s" is not a folder" ROOT-REFUSED ENDOF
      restricted OF
         s" cannot be traversed completely" ROOT-REFUSED
      ENDOF
   ;MATCH ;

\ Rust's link_authorized of the client to the remote root r.
: LINKED ( str ^DROPBOX:client ^ARENA:arena -- )
   {: r cl ar :}
   [: r cl ar LINK-CHECKED ;] catch {: code:n :}
   code 0= if exit then
   code DROPBOX-CODE? 0= if code throw then
   VALIDATE-FAILED ;

\ The client's binding for the remote root r and its refresh token
\ in a; the token is copied, as CLOSE discards the client's.
: KEEP-LOGIN ( str ^DROPBOX:client ^authorized ^ARENA:arena -- )
   {: r cl a ar :}
   cl DROPBOX:ACCOUNT-ID cl DROPBOX:ROOT-NAMESPACE
   r JOURNAL-DROPBOX--BINDING:MAKE a AUTHORIZED-BINDING !
   cl DROPBOX:REFRESH-TOKEN ar ARENA:COPY a AUTHORIZED-REFRESH-TOKEN ! ;

\ The code ac exchanged for the login p and checked against the root
\ r, kept in a; the client is closed on every path out.
: LINK-LOGIN ( ^CONFIG:config str ^AUTH:pending str ^authorized
     ^ARENA:arena -- )
   {: c ac p r a ar :}
   c CONFIG:APP-KEY ar CLIENT {: cl :}
   [: ac p cl EXCHANGED
      r cl ar LINKED
      r cl a ar KEEP-LOGIN ;] [: cl DROPBOX:CLOSE ;] finally ;

\ Rust's authorize: a browser login whose code, read from stdin, is
\ exchanged and checked against the remote root r.
: AUTHORIZE ( ^CONFIG:config str ^ARENA:arena -- ^authorized )
   {: c r ar :}
   c CONFIG:APP-KEY ar STARTED {: p :}
   p ar PROMPT
   FD:STDIN ar READ-CODE {: ac :}
   ar LOGINS-NEW {: a :}
   [: c ac p r a ar LINK-LOGIN ;] DROPBOX:WITH-LOOP
   a ;


\ ---- binding the journal

\ What the journal held before setup: no binding, the new one, or
\ another.
ENUM prior none same other ;ENUM
ARENA PRIORS prior

: PRIOR-OF ( JOURNAL:journal JOURNAL:dropbox-binding ^ARENA:arena
     -- prior )
   {: j b ar :}
   j ar JOURNAL:DROPBOX-BINDING MATCH option
      none OF construct prior none ENDOF
      some OF
         b JOURNAL:BINDING= if construct prior same
         else construct prior other then
      ENDOF
   ;MATCH ;

\ The journal's binding against the new one b.
: PRIOR-READ ( JOURNAL:journal JOURNAL:dropbox-binding ^ARENA:arena
     -- prior )
   {: j b ar :}
   ar PRIORS-NEW {: slot :}
   [: j b ar PRIOR-OF slot ! ;] catch {: code:n :}
   code 0<> if code s" read the Dropbox journal binding" JOURNAL-FAILED then
   slot @ ;

: MISMATCH? ( JOURNAL:dropbox-binding-write -- bool )
   MATCH JOURNAL:dropbox-binding-write
      bound OF false ENDOF
      already-bound OF false ENDOF
      mismatch OF drop true ENDOF
   ;MATCH ;

\ Rust's bind_dropbox_root of b.
: ROOT-BOUND ( JOURNAL:journal JOURNAL:dropbox-binding ^ARENA:arena -- )
   {: j b ar :}
   false [: drop j b ar JOURNAL:BIND-DROPBOX-ROOT MISMATCH? ;] catch
   {: m code:n :}
   code 0= if m if BINDING-MISMATCH then exit then
   code s" bind the journal to Dropbox" JOURNAL-FAILED ;

\ AUTH:STORE of the binding and refresh token in a.
: TOKEN-STORED ( ^authorized -- )
   {: a :}
   [: a AUTHORIZED-BINDING @ a AUTHORIZED-REFRESH-TOKEN @ AUTH:STORE ;]
   catch {: code:n :}
   code 0= if exit then
   code AUTH-CODE? 0= if code throw then
   s" store the Dropbox refresh token" AUTH-FAILED ;

: BOUND-IN ( JOURNAL:journal ^authorized ^ARENA:arena -- )
   {: j a ar :}
   a AUTHORIZED-BINDING @ {: b :}
   j b ar PRIOR-READ MATCH prior
      other OF BINDING-MISMATCH ENDOF
      same OF a TOKEN-STORED ENDOF
      none OF a TOKEN-STORED j b ar ROOT-BOUND ENDOF
   ;MATCH ;

\ Rust's bind: the login a's token stored and the journal bound to
\ its account and root; the journal is closed on every path out.
: BIND ( ^CONFIG:config ^authorized ^ARENA:arena -- )
   {: c a ar :}
   c CONFIG:PATHS CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR
   s" open the journal" ar JOURNAL-OPENED {: j :}
   [: j a ar BOUND-IN ;] [: j JOURNAL:CLOSE ;] finally ;


\ ---- setup

\ The config of a setup driven by flags: refused where one exists,
\ before any login or default root; the root given, else ~/Dropbox.
: FRESH-CONFIG ( initial-config ^ARENA:arena -- ^CONFIG:config )
   {: i ar :}
   ar XDG {: x :}
   x ar CONFIG:XDG-CONFIG-FILE REFUSE-EXISTING
   i INITIAL-CONFIG-UNMAKE {: root key :}
   root MATCH option
      some OF ENDOF
      none OF ar DEFAULT-ROOT ENDOF
   ;MATCH {: r :}
   x r key s" validate initial configuration" ar VALIDATED ;

\ Rust's Config::load: the XDG paths and the stored config.
: LOADED ( ^ARENA:arena -- ^CONFIG:config )
   {: ar :}
   NULL-PTR [: drop ar CONFIG:LOAD ;] catch {: c code :}
   code 0= if c exit then
   code s" load configuration" CONFIG-FAILED ;

\ The config and whether setup writes it new.
: SETUP-CONFIG ( option<initial-config> ^ARENA:arena
     -- ^CONFIG:config bool )
   {: i ar :}
   i MATCH option
      some OF ar FRESH-CONFIG true ENDOF
      none OF ar LOADED false ENDOF
   ;MATCH ;

: STATE-PREPARED ( ^CONFIG:config -- )
   {: c :}
   [: c CONFIG:PREPARE ;] catch {: code:n :}
   code 0<> if code s" prepare state directories" CONFIG-FAILED then ;

\ COMPLETE-SETUP of the config c, w asking for a new config file, with
\ BIND of the login a as its bind.
: COMPLETED ( ^CONFIG:config bool ^authorized ^ARENA:arena
     -- ^VEC:vector<STALE:leftover> )
   {: c w:bool a ar :}
   c w [: c a ar BIND ;] ar COMPLETE-SETUP ;


\ ---- the window while the service is released

\ What changes while the service is released. setup's write asks for a
\ new config file; its login is bound and its token stored.
ENUM change
   VARIANT sync-root FIELD paths ^CONFIG:paths FIELD config ^CONFIG:config
   ;VARIANT
   VARIANT setup FIELD config ^CONFIG:config FIELD write bool
      FIELD login ^authorized
   ;VARIANT
;ENUM

\ Each state is named for the step that ran last: released the release
\ drive, changing the change, restoring the restore drive.
ENUM window-state released changing restoring ;ENUM

\ What a step answered; interrupted, whatever it answered, once a SIGINT,
\ SIGTERM or SIGHUP has been taken in the window.
ENUM outcome ok failed interrupted ;ENUM

\ The closed window, and its two ends: the change's end told, or death
\ by the signal taken.
ENUM close-state closed decided died ;ENUM

\ What the window had come to when it closed: no signal taken; a signal
\ taken, the service restored; or taken, the service not restarted, and
\ the change made or not.
ENUM heard quiet signaled kept unmade ;ENUM

\ changed holds the release's code until the change runs; left holds the
\ made change's leftovers, null until the change is made; signal is the
\ first signal taken, 0 for none.
STRUCTURE window DERIVE addr
   FIELD commands ^SERVICE:commands
   FIELD change change
   FIELD name str
   FIELD done str
   FIELD arena ^ARENA:arena
   FIELD driven ^SERVICE:driven
   FIELD left ^VEC:vector<STALE:leftover>
   FIELD changed n
   FIELD launched bool
   FIELD restored n
   FIELD signal n
;STRUCTURE

ARENA WINDOWS window

\ The change made, its leftovers in ar.
: CHANGE-MADE ( change ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: ch ar :}
   ch MATCH change
      sync-root OF {: p r :} p r ar CHANGE-ROOT ENDOF
      setup OF {: c w:bool a :} c w a ar COMPLETED ENDOF
   ;MATCH ;

\ The change's leftovers and code, 0 for none.
: CHANGED ( change ^ARENA:arena -- ^VEC:vector<STALE:leftover> n )
   {: ch ar :}
   NULL-PTR [: drop ch ar CHANGE-MADE ;] catch {: left code:n :}
   code 0= if left 0 exit then
   NULL-PTR code ;

\ Keeps the first signal delivered, if none is kept yet.
: TAKEN ( ^window -- )
   {: w :}
   w WINDOW-SIGNAL @ 0<> if exit then
   SIGNAL:TAKE MATCH SIGNAL:signal-result
      signal OF w WINDOW-SIGNAL ! ENDOF
      timeout OF ENDOF
   ;MATCH ;

\ The outcome of a step that answered the code.
: OUTCOME ( n ^window -- outcome )
   {: code:n w :}
   w WINDOW-SIGNAL @ 0<> if construct outcome interrupted exit then
   code 0<> if construct outcome failed exit then
   construct outcome ok ;

: AT-STEP ( ^window -- outcome )
   {: w :} w TAKEN w WINDOW-CHANGED @ w OUTCOME ;

: CHANGE ( ^window -- )
   {: w :}
   w WINDOW-CHANGE @ w WINDOW-ARENA @ CHANGED {: left changed:n :}
   left w WINDOW-LEFT !
   changed w WINDOW-CHANGED ! ;

: RESTORE ( ^window -- )
   {: w :}
   w WINDOW-COMMANDS @ w WINDOW-DRIVEN @ w WINDOW-ARENA @ RESTORED
   {: launched:bool restored:n :}
   launched w WINDOW-LAUNCHED !
   restored w WINDOW-RESTORED ! ;

\ RELEASED's steps, after formal/ReleaseWindow.tla.
FSM:DEFINE RELEASING ( ^window ) window-state outcome
   IN released  AT-STEP
      ok           CHANGE   >changing
      failed       RESTORE  >restoring
      interrupted  RESTORE  >restoring
   IN changing  AT-STEP
      ok           RESTORE  >restoring
      failed       RESTORE  >restoring
      interrupted  RESTORE  >restoring
   FINAL restoring  -
;DEFINE

: STEPS ( ^window -- )
   {: w :}
   w WINDOW-COMMANDS @ SERVICE-GOAL:RELEASE w WINDOW-DRIVEN @
   SERVICE:DRIVE-RECORDED w WINDOW-CHANGED !
   w construct window-state released RELEASING ;

\ The window closes: RELEASE answers a signal delivered after the last
\ TAKE, which becomes the window's when it took none.
: SHUT ( ^window -- )
   {: w :}
   SIGNAL:RELEASE {: sig:n :}
   w WINDOW-SIGNAL @ 0<> if exit then
   sig w WINDOW-SIGNAL ! ;

: DECIDE ( ^window -- )
   {: w :}
   w WINDOW-COMMANDS @ w WINDOW-NAME @ w WINDOW-DONE @ w WINDOW-LEFT @
   w WINDOW-CHANGED @ w WINDOW-LAUNCHED @ w WINDOW-RESTORED @
   w WINDOW-ARENA @ DECIDED ;

\ SIGNAL:DIE-OF without its RELEASE, which closed the window: the exit
\ actions, then death by the signal taken.
: SIGNALED ( ^window -- )
   WINDOW-SIGNAL @ {: sig:n :}
   AT-EXIT:RUN-NOW
   getpid >PID sig PROCESS:KILL-RAW drop
   s" " 128 sig + die ;

\ The made change's START-AFTER-CHANGE text, then death by the signal.
: KEPT ( ^window -- )
   {: w :} w WINDOW-DONE @ START-AFTER-CHANGE-TOLD w SIGNALED ;

\ The unmade change's CHANGE-AND-RESTORE text, then death by the signal.
: UNMADE ( ^window -- )
   {: w :} w WINDOW-NAME @ CHANGE-AND-RESTORE-TOLD w SIGNALED ;

: AT-CLOSED ( ^window -- heard )
   {: w :}
   w WINDOW-SIGNAL @ 0= if construct heard quiet exit then
   w WINDOW-RESTORED @ 0= if construct heard signaled exit then
   w WINDOW-LEFT @ NULL-PTR <> if construct heard kept exit then
   construct heard unmade ;

\ The closed window's end, after formal/ReleaseWindow.tla.
FSM:DEFINE CLOSING ( ^window ) close-state heard
   IN closed  AT-CLOSED
      quiet     DECIDE    >decided
      signaled  SIGNALED  >died
      kept      KEPT      >died
      unmade    UNMADE    >died
   FINAL decided  -
   FINAL died  -
;DEFINE

\ Rust's change_while_released: releases the unit, makes the change named
\ n and restores the unit; d states the finished change.
: RELEASED ( ^SERVICE:commands change str str ^ARENA:arena -- )
   {: c ch n:str d:str ar :}
   ar DRIVENS-NEW {: v :}
   ar WINDOWS-NEW {: w :}
   c w WINDOW-COMMANDS !
   ch w WINDOW-CHANGE !
   n w WINDOW-NAME !
   d w WINDOW-DONE !
   ar w WINDOW-ARENA !
   v w WINDOW-DRIVEN !
   SIGNAL:CATCH-STOPS
   [: w STEPS ;] [: w SHUT ;] finally
   w construct close-state closed CLOSING ;


\ ---- the changes

\ Rust's set_sync_root: the root validated against the stored config,
\ then changed while the service c is released.
: SET-ROOT ( str ^CONFIG:xdg ^SERVICE:commands ^ARENA:arena -- )
   {: root x c ar :}
   x s" load configuration for sync-root change" ar DOCUMENT {: d :}
   x s" resolve state paths for sync-root change" ar STATE-PATHS {: p :}
   x root d CONFIG:DOCUMENT-KEY s" validate the new sync root" ar
   VALIDATED {: r :}
   r ar ROOT-DONE {: done :}
   c p r CHANGE-SYNC-ROOT s" the sync-root change" done ar RELEASED ;

\ Rust's setup: the login runs while the service syncs, as it waits on
\ the browser; the bind and the config's write run with it released.
: SETUP ( setup-options ^SERVICE:commands ^ARENA:arena -- )
   {: o s ar :}
   o SETUP-OPTIONS-UNMAKE {: r i :}
   HOME-ENV ar HOME-WIDGET
   i ar SETUP-CONFIG {: c w:bool :}
   c STATE-PREPARED
   c r ar AUTHORIZE {: a :}
   s c w a CHANGE-SETUP s" setup" s" Omabox setup is complete" ar
   RELEASED ;


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
      status OF ar XDG ar STATUS-TEXT WRITE-OUT ENDOF
      settings OF
         {: f :} ar XDG f ar SETTINGS-TEXT WRITE-OUT
      ENDOF
      set-root OF
         {: root :} root ar XDG ar SERVICE:COMMANDS ar SET-ROOT
      ENDOF
      service OF {: act :} ar SERVICE:COMMANDS act ar RUN-SERVICE ENDOF
      logs OF ar SERVICE:COMMANDS SERVICE:LOGS ENDOF
      setup OF {: o :} o ar SERVICE:COMMANDS ar SETUP ENDOF
   ;MATCH ;

: RUN ( -- )
   AUTH:BIND
   SCRIPT-ARGC [: SCRIPT-ARGV$ ;] PARSE {: cmd :}
   [: cmd swap PERFORM ;] ARENA:WITH ;

\ A code outside the application block -999999..-100000, which no
\ omabox word logged, on a line of its own.
: UNEXPECTED ( n -- )
   {: code:n :}
   code -100000 -999999 IN? if exit then
   LOG-OPEN s" the command failed unexpectedly (" LOG:TEXT+
   code LOG:CODE+ s" )" LOG:TEXT+ LOG:;LINE ;

global

: MAIN ( -- )
   [: RUN ;] catch {: code:n :}
   code 0<> if code UNEXPECTED s" " 1 die then ;

;package
