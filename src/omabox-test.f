\ omabox-test.f - the omabox program against the Rust version's
\ src/bin/omabox.rs tests, under their names, for the forms it parses:
\ - parser_accepts_documented_forms
\ - parser_rejects_incomplete_or_secret_bearing_forms and
\   parser_names_the_setup_option_fault, each refusal's two log lines
\   checked in a file under TMPDIR; setup's forms through PARSE-SETUP
\ - default_sync_root_is_a_private_home_dropbox_created_once, the home a
\   directory under TMPDIR
\ - failed_initial_setup_leaves_no_config_and_same_command_can_retry,
\   the sync root and XDG homes in a directory under TMPDIR
\ - an_overlong_authorization_code_is_rejected_within_the_bound,
\   an_authorization_code_at_the_limit_is_accepted,
\   an_authorization_code_is_trimmed and
\   a_blank_or_non_utf8_authorization_code_is_rejected, each code read
\   from a pipe
\ - config_errors_show_their_own_help: status over a config.toml that
\   does not parse logs CONFIG's error and help, then OMABOX's Config
\   line with no help of its own
\ - status_reports_the_journal_when_the_root_is_unavailable,
\   settings_show_the_stored_root_when_it_is_unavailable and
\   settings_json_is_one_document_when_the_root_is_available, where
\   Rust's stdout line is CONFIG's refusal on stderr; each over Rust's
\   fixture, XDG homes and sync root in a directory under TMPDIR
\ - service_commands_reset_the_start_limit_before_a_start, each row's
\   systemctl a script in a directory of its own under TMPDIR, which
\   logs each verb and answers show with the row's state
\ - restore_goal_restores_only_after_a_spawned_release
\ - a_change_runs_while_the_service_is_released,
\   a_failed_change_still_restores_the_service, where E-IO stands in for
\   Rust's InvalidAuthorizationCode, and
\   a_failed_release_skips_the_change_and_restores, each systemctl Rust's
\   stateful script in a directory of its own under TMPDIR
\ and the program built with README's command into a directory under
\ TMPDIR, whose --version prints its name and version and exits 0.
\ White-box: OMABOX is reopened for PARSE, PARSE-SETUP, HOME-ROOT,
\ COMPLETE-SETUP, READ-CODE, RUN-SERVICE, STATUS-TEXT, SETTINGS-TEXT,
\ RESTORE-GOAL and RELEASED.
\ Run from the repository root: hb --load src/omabox-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/lib/adt/option.f
require src/lib/process.f
require src/lib/process-argv.f
require src/lib/process-env.f
require src/lib/engine-candidate.f
require src/lib/vector.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/stale.f
require src/config.f
require src/attention.f
require src/service.f
require src/stale.f
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

\ The text a command answered under a capture.
TYPED-VARIABLE SHOWN str

\ The service trace a change saw, and how many changes ran.
TYPED-VARIABLE DURING-LOG str
TYPED-VARIABLE DURING-STATE str
variable CHANGES

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
: FILE-TEXT ( str -- ^u8 n )
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

\ The command as text, its variant and payload, for a test to compare.
: COMMAND$ ( command -- ^u8 n )
   SB-RESET
   MATCH command
      help OF s" help" SB-APPEND ENDOF
      version OF s" version" SB-APPEND ENDOF
      status OF s" status" SB-APPEND ENDOF
      settings OF
         s" settings " SB-APPEND FORM-TAG FMT:INT$ SB-APPEND
      ENDOF
      service OF
         s" service " SB-APPEND SERVICE-ACTION:TAG FMT:INT$ SB-APPEND
      ENDOF
      logs OF s" logs" SB-APPEND ENDOF
   ;MATCH SB$ ;

: ACCEPTS-IN ( command ^ARENA:arena -- )
   {: c ar :}
   c COMMAND$ ar COPIED str> PARSED COMMAND$ T$= ;

: ACCEPTS ( command -- ) {: c :} [: c swap ACCEPTS-IN ;] ARENA:WITH ;

: SETUP-PARSED ( -- setup-options ) ARGC @ [: ARG ;] PARSE-SETUP ;

\ The bytes and whether there are any.
: SOME$ ( option<str> -- ^u8 n bool )
   MATCH option
      some OF str> true ENDOF
      none OF s" " false ENDOF
   ;MATCH ;

: SAME-BOOL? ( bool bool -- bool ) bool>n swap bool>n = ;

: STRS= ( option<str> option<str> -- bool )
   SOME$ {: b:^ bu:n bf:bool :} SOME$ {: a:^ au:n af:bool :}
   af bf SAME-BOOL? a au b bu STR= and ;

\ The sync root, the key and whether there is an initial config.
: INITIAL$ ( option<initial-config> -- option<str> ^u8 n bool )
   MATCH option
      some OF INITIAL-CONFIG-UNMAKE str> true ENDOF
      none OF NO-STR s" " false ENDOF
   ;MATCH ;

: INITIALS= ( option<initial-config> option<initial-config> -- bool )
   INITIAL$ {: bs bk:^ bku:n bf:bool :}
   INITIAL$ {: as ak:^ aku:n af:bool :}
   af bf SAME-BOOL? ak aku bk bku STR= and as bs STRS= and ;

\ Rust's derived PartialEq of SetupOptions.
: OPTIONS= ( setup-options setup-options -- bool )
   SETUP-OPTIONS-UNMAKE {: br bi :}
   SETUP-OPTIONS-UNMAKE {: ar ai :}
   ar str> br str> STR= ai bi INITIALS= and ;

: SETUP-ACCEPTS ( setup-options -- ) SETUP-PARSED OPTIONS= TTRUE ;

\ The remote root and initial config.
: OPTIONS ( ^u8 n option<initial-config> -- setup-options )
   {: r:^ ru:n i :}
   r ru >str i SETUP-OPTIONS-MAKE ;

\ The sync root and app key of a setup driven by flags.
: FLAGS ( option<str> ^u8 n -- option<initial-config> )
   >str INITIAL-CONFIG-MAKE OPTION:SOME ;

: SOME-STR ( ^u8 n -- option<str> ) >str OPTION:SOME ;

: SERVICE-COMMAND ( SERVICE:action -- command ) COMMAND-SERVICE ;

: PARSER-ACCEPTS-DOCUMENTED-FORMS ( -- )
   s" parser_accepts_documented_forms" T-LABEL
   s" --help" ONE construct command help ACCEPTS
   s" --version" ONE construct command version ACCEPTS
   s" pause" ONE SERVICE-ACTION:STOP SERVICE-COMMAND ACCEPTS
   s" resume" ONE
   SERVICE-ACTION:START SERVICE-COMMAND ACCEPTS
   s" setup" ONE s" " NO-INITIAL OPTIONS SETUP-ACCEPTS
   s" setup" s" /Work" TWO s" /Work" NO-INITIAL OPTIONS SETUP-ACCEPTS
   s" setup" s" --remote-root" TWO s" /Work" ARG+
   s" --app-key" ARG+ s" key" ARG+
   s" --sync-root" ARG+ s" /tmp/Dropbox" ARG+
   s" /Work" s" /tmp/Dropbox" SOME-STR s" key" FLAGS OPTIONS
   SETUP-ACCEPTS
   s" setup" s" --app-key" TWO s" key" ARG+
   s" " NO-STR s" key" FLAGS OPTIONS SETUP-ACCEPTS
   s" service" s" restart" TWO
   SERVICE-ACTION:RESTART SERVICE-COMMAND ACCEPTS
   s" logs" ONE construct command logs ACCEPTS
   s" status" ONE construct command status ACCEPTS
   s" settings" ONE construct form text COMMAND-SETTINGS ACCEPTS
   s" settings" s" --json" TWO
   construct form json COMMAND-SETTINGS ACCEPTS ;

: LINES ( ^u8 n -- n )
   {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;

\ Whether the log holds "omabox: " t and LF.
: LOGGED? ( ^u8 n ^u8 n -- bool )
   {: a:^ u:n t:^ tu:n :}
   SB-RESET s" omabox: " SB-APPEND t tu SB-APPEND 10 SB-APPEND-C
   a u SB$ CONTAINS? ;

\ A Usage refusal: the fault m's line, then the help line.
: USAGE-LOGGED ( n ^u8 n ^u8 n -- )
   {: code:n e:^ eu:n m:^ mu:n :}
   code E-USAGE T=
   e eu LINES 2 T=
   e eu m mu LOGGED? TTRUE
   e eu s" help: Run `omabox --help` for usage." LOGGED? TTRUE ;

\ The arguments are refused as Usage with the fault m, captured in the
\ file at p.
: REJECTS ( ^u8 n str ^ARENA:arena -- )
   {: m:^ mu:n p ar :}
   [: PARSED drop ;] p str> ar STDERR:CAPTURING m mu USAGE-LOGGED ;

\ REJECTS of setup's arguments, through PARSE-SETUP.
: SETUP-REJECTS ( ^u8 n str ^ARENA:arena -- )
   {: m:^ mu:n p ar :}
   [: SETUP-PARSED drop ;] p str> ar STDERR:CAPTURING m mu USAGE-LOGGED ;

: PARSER-REJECTS-INCOMPLETE-OR-SECRET-BEARING-FORMS
   ( ^ARENA:arena -- )
   {: ar :}
   s" parser_rejects_incomplete_or_secret_bearing_forms" T-LABEL
   ar TEMPORARY {: d :}
   d s" stderr.txt" ar INSIDE {: p :}
   ARGS-RESET s" a command is required" p ar REJECTS
   s" unknown" ONE s" unknown command" p ar REJECTS
   s" status" s" extra" TWO s" too many arguments" p ar REJECTS
   s" pause" s" extra" TWO s" too many arguments" p ar REJECTS
   s" resume" s" extra" TWO s" too many arguments" p ar REJECTS
   s" install" s" extra" TWO s" unknown command" p ar REJECTS
   s" settings" s" set-root" TWO
   s" invalid settings command" p ar REJECTS
   s" settings" s" --yaml" TWO s" invalid settings command" p ar REJECTS
   s" service" s" unknown" TWO s" unknown service action" p ar REJECTS
   s" setup" s" --sync-root" TWO s" /tmp/Dropbox" ARG+
   s" flag-driven setup requires --app-key" p ar SETUP-REJECTS
   s" setup" s" --sync-root" TWO s" /tmp/Dropbox" ARG+
   s" --app-key" ARG+ s" key" ARG+
   s" --app-secret" ARG+ s" secret" ARG+
   s" unknown setup option" p ar SETUP-REJECTS
   d str> FS:REMOVE-TREE ;

: ROOT-FAULT$ ( -- ^u8 n )
   s" the Dropbox root must be empty or an absolute folder path such as /Work, with no trailing slash and no empty, . or .. parts" ;

: PARSER-NAMES-THE-SETUP-OPTION-FAULT ( ^ARENA:arena -- )
   {: ar :}
   s" parser_names_the_setup_option_fault" T-LABEL
   ar TEMPORARY {: d :}
   d s" stderr.txt" ar INSIDE {: p :}
   s" setup" s" --help" TWO s" unknown setup option" p ar SETUP-REJECTS
   s" setup" s" --sync-root" TWO s" /tmp/Dropbox" ARG+ s" --bogus" ARG+
   s" unknown setup option" p ar SETUP-REJECTS
   s" setup" s" --app-key" TWO
   s" a setup option is missing its value" p ar SETUP-REJECTS
   s" setup" s" --app-key" TWO s" key" ARG+ s" --app-key" ARG+
   s" a setup option was provided more than once" p ar SETUP-REJECTS
   s" setup" s" -h" TWO ROOT-FAULT$ p ar SETUP-REJECTS
   s" setup" s" Work" TWO ROOT-FAULT$ p ar SETUP-REJECTS
   s" setup" s" /Work/" TWO ROOT-FAULT$ p ar SETUP-REJECTS
   s" setup" s" /Work/../Home" TWO ROOT-FAULT$ p ar SETUP-REJECTS
   s" setup" s" --sync-root" TWO s" /tmp/Dropbox" ARG+
   s" --app-key" ARG+ s" key" ARG+ s" --remote-root" ARG+ s" Work" ARG+
   ROOT-FAULT$ p ar SETUP-REJECTS
   d str> FS:REMOVE-TREE ;


\ ---- setup's local steps

\ HOME-ROOT of the home, refused with the code, captured in p.
: NO-ROOT ( option<str> str ^ARENA:arena -- )
   {: home p ar :}
   [: home ar HOME-ROOT drop ;] p str> ar STDERR:CAPTURING
   {: code:n e:^ eu:n :}
   code E-NO-DEFAULT-ROOT T=
   e eu LINES 2 T= ;

\ HOME-ROOT of the home is root, a directory of mode 0700.
: PRIVATE-ROOT ( str str ^ARENA:arena -- )
   {: home root ar :}
   home OPTION:SOME ar HOME-ROOT str> root str> T$=
   root str> FS:STAT-MODE $1FF and FS:MODE-PRIVATE-DIR T= ;

: DEFAULT-SYNC-ROOT-IS-A-PRIVATE-HOME-DROPBOX-CREATED-ONCE
   ( ^ARENA:arena -- )
   {: ar :}
   s" default_sync_root_is_a_private_home_dropbox_created_once" T-LABEL
   ar TEMPORARY {: d :}
   d s" home" ar INSIDE {: home :}
   home str> FS:MAKE-DIR
   home s" Dropbox" ar INSIDE {: root :}
   home root ar PRIVATE-ROOT
   home root ar PRIVATE-ROOT
   d s" stderr.txt" ar INSIDE {: p :}
   NO-STR p ar NO-ROOT
   s" relative/home" SOME-STR p ar NO-ROOT
   d str> FS:REMOVE-TREE ;

\ setup --sync-root root --app-key public-app-key.
: SETUP-ARGS ( str -- )
   {: root :}
   s" setup" s" --sync-root" TWO root str> ARG+
   s" --app-key" ARG+ s" public-app-key" ARG+ ;

\ The documented setup form parsed, its config made and prepared, and
\ COMPLETE-SETUP run with bind: the code, the log captured in p.
: ATTEMPT ( str ^CONFIG:xdg [ -- ] str ^ARENA:arena -- n )
   {: root x bind p ar :}
   root SETUP-ARGS
   SETUP-PARSED s" " root str> SOME-STR s" public-app-key" FLAGS OPTIONS
   OPTIONS= TTRUE
   x root s" public-app-key" >str ar CONFIG:FROM-VALUES {: c :}
   c CONFIG:PREPARE
   [: c true bind ar COMPLETE-SETUP drop ;] p str> ar STDERR:CAPTURING
   {: code:n e:^ eu:n :}
   code ;

: FAILED-INITIAL-SETUP-LEAVES-NO-CONFIG-AND-SAME-COMMAND-CAN-RETRY
   ( ^ARENA:arena -- )
   {: ar :}
   s" failed_initial_setup_leaves_no_config_and_same_command_can_retry"
   T-LABEL
   ar TEMPORARY {: d :}
   d s" Dropbox" ar INSIDE {: root :}
   root str> FS:MAKE-DIR
   d s" config" ar INSIDE CONFIG:>ABS-PATH
   d s" state" ar INSIDE CONFIG:>ABS-PATH ar CONFIG:XDG-NEW {: x :}
   x ar CONFIG:XDG-CONFIG-FILE CONFIG:ABS-PATH>STR {: file :}
   d s" stderr.txt" ar INSIDE {: p :}
   root x [: E-INVALID-CODE throw ;] p ar ATTEMPT E-INVALID-CODE T=
   file str> FS:TRY-STAT TFALSE
   root x [: ;] p ar ATTEMPT 0 T=
   x ar CONFIG:LOAD-FROM CONFIG:APP-KEY str> s" public-app-key" T$=
   d str> FS:REMOVE-TREE ;

\ A pipe holding the bytes, its write end closed: the read end.
: PIPED ( ^u8 n -- fd )
   {: a:^ u:n :}
   FD:PIPE {: r:fd w:fd :}
   w a u FD:WRITE-FULL
   w FD>N close
   r ;

\ The bytes left in the pipe; closes it.
: REST ( fd -- n )
   {: f:fd :}
   0 begin f FD>N SEEN CAP read dup 0 > while + repeat drop
   f FD>N close ;

\ READ-CODE of the bytes from a pipe, captured in p: the code, the text
\ read in SHOWN, and the pipe's read end.
: CODE-READ ( ^u8 n str ^ARENA:arena -- n fd )
   {: a:^ u:n p ar :}
   a u PIPED {: f:fd :}
   [: f ar READ-CODE SHOWN ! ;] p str> ar STDERR:CAPTURING
   {: code:n e:^ eu:n :}
   code f ;

\ The bytes read as the code c.
: CODE-ACCEPTED ( ^u8 n ^u8 n str ^ARENA:arena -- )
   {: a:^ u:n c:^ cu:n p ar :}
   a u p ar CODE-READ {: code:n f:fd :}
   code 0 T=
   SHOWN @ str> c cu T$=
   f REST drop ;

\ The bytes refused as E-INVALID-CODE: the bytes left unread.
: CODE-REFUSED ( ^u8 n str ^ARENA:arena -- n )
   {: a:^ u:n p ar :}
   a u p ar CODE-READ {: code:n f:fd :}
   code E-INVALID-CODE T=
   f REST ;

\ n bytes a in the arena.
: AS ( n ^ARENA:arena -- ^u8 n )
   {: n:n ar :}
   ar n ARENA:ALLOC {: b:^ u:n :}
   u 0 ?do 97 b i + c! loop
   b u ;

\ n bytes a, then LF.
: AS-LINE ( n ^ARENA:arena -- ^u8 n )
   {: n:n ar :}
   n 1+ ar AS {: b:^ u:n :}
   10 b n + c!
   b u ;

\ The file at p, under a new directory: the directory and p.
: LOG-FILE ( ^ARENA:arena -- str str )
   {: ar :}
   ar TEMPORARY {: d :}
   d d s" stderr.txt" ar INSIDE ;

\ The read stops within the bound: the bytes it took are total less
\ those left.
: OVERLONG ( n str ^ARENA:arena -- )
   {: extra:n p ar :}
   CODE-LIMIT extra + {: total:n :}
   total ar AS p ar CODE-REFUSED {: left:n :}
   total left - CODE-LIMIT 1+ <= TTRUE ;

: AN-OVERLONG-AUTHORIZATION-CODE-IS-REJECTED-WITHIN-THE-BOUND
   ( ^ARENA:arena -- )
   {: ar :}
   s" an_overlong_authorization_code_is_rejected_within_the_bound" T-LABEL
   ar LOG-FILE {: d p :}
   1 p ar OVERLONG
   2 p ar OVERLONG
   4096 p ar OVERLONG
   d str> FS:REMOVE-TREE ;

: AN-AUTHORIZATION-CODE-AT-THE-LIMIT-IS-ACCEPTED ( ^ARENA:arena -- )
   {: ar :}
   s" an_authorization_code_at_the_limit_is_accepted" T-LABEL
   ar LOG-FILE {: d p :}
   CODE-LIMIT ar AS-LINE CODE-LIMIT ar AS p ar CODE-ACCEPTED
   SHOWN @ str> nip CODE-LIMIT T=
   d str> FS:REMOVE-TREE ;

: AN-AUTHORIZATION-CODE-IS-TRIMMED ( ^ARENA:arena -- )
   {: ar :}
   s" an_authorization_code_is_trimmed" T-LABEL
   ar LOG-FILE {: d p :}
   S\" \x20\tcode \r\n" s" code" p ar CODE-ACCEPTED
   s" code" s" code" p ar CODE-ACCEPTED
   d str> FS:REMOVE-TREE ;

: A-BLANK-OR-NON-UTF8-AUTHORIZATION-CODE-IS-REJECTED ( ^ARENA:arena -- )
   {: ar :}
   s" a_blank_or_non_utf8_authorization_code_is_rejected" T-LABEL
   ar LOG-FILE {: d p :}
   S\" \x20\x20\n" p ar CODE-REFUSED 0 T=
   S\" \xff\n" p ar CODE-REFUSED 0 T=
   d str> FS:REMOVE-TREE ;


\ ---- status and settings

\ Rust's fixture: DIR/first the sync root, XDG over DIR/config and
\ DIR/state, the config written with public-app-key; answers DIR, the
\ XDG and first.
: FIXTURE ( ^ARENA:arena -- str ^CONFIG:xdg str )
   {: ar :}
   ar TEMPORARY {: d :}
   d s" first" ar INSIDE {: first :}
   first str> FS:MAKE-DIRS
   d s" config" ar INSIDE CONFIG:>ABS-PATH
   d s" state" ar INSIDE CONFIG:>ABS-PATH ar CONFIG:XDG-NEW {: x :}
   x first s" public-app-key" >str ar CONFIG:FROM-VALUES
   {: c :}
   c CONFIG:PREPARE
   c ar CONFIG:WRITE drop
   d x first ;

: STORED ( ^CONFIG:xdg ^ARENA:arena -- str )
   CONFIG:DOCUMENT-LOAD-FROM CONFIG:DOCUMENT-ROOT CONFIG:ABS-PATH>STR ;

\ Whether the log ends with "omabox: " t and LF.
: ENDS-LOGGED? ( ^u8 n ^u8 n -- bool )
   {: a:^ u:n t:^ tu:n :}
   SB-RESET s" omabox: " SB-APPEND t tu SB-APPEND 10 SB-APPEND-C
   SB$ {: w:^ wu:n :}
   u wu < if false exit then
   a u + wu - wu w wu STR= ;

\ Whether the log holds "config: " t and LF.
: CONFIG-LOGGED? ( ^u8 n ^u8 n -- bool )
   {: a:^ u:n t:^ tu:n :}
   SB-RESET s" config: " SB-APPEND t tu SB-APPEND 10 SB-APPEND-C
   a u SB$ CONTAINS? ;

\ Whether the log holds "config: " t, the path p in backticks, and LF.
: PATH-LOGGED? ( ^u8 n ^u8 n str -- bool )
   {: a:^ u:n t:^ tu:n p :}
   SB-RESET s" config: " SB-APPEND t tu SB-APPEND s" `" SB-APPEND
   p str> SB-APPEND s" `" SB-APPEND 10 SB-APPEND-C
   a u SB$ CONTAINS? ;

\ CONFIG's refusal of the stored root once it is gone: its two lines
\ alone, Rust's unavailable_line.
: UNAVAILABLE ( ^u8 n str -- )
   {: e:^ eu:n root :}
   e eu LINES 2 T=
   e eu s" could not resolve sync root " root PATH-LOGGED? TTRUE
   e eu
   s" help: Create the sync root as a local directory and ensure it is accessible."
   CONFIG-LOGGED? TTRUE ;

: CONFIG-ERRORS-SHOW-THEIR-OWN-HELP ( ^ARENA:arena -- )
   {: ar :}
   s" config_errors_show_their_own_help" T-LABEL
   ar FIXTURE {: d x first :}
   x ar CONFIG:XDG-CONFIG-FILE CONFIG:ABS-PATH>STR {: file :}
   file str> s" app_secret = 'secret'" FS:WRITE-ALL
   d s" stderr.txt" ar INSIDE {: p :}
   [: x ar STATUS-TEXT drop ;] p str> ar STDERR:CAPTURING
   {: code:n e:^ eu:n :}
   code CONFIG:E-PARSE T=
   e eu LINES 3 T=
   e eu s" could not parse Omabox configuration at " file PATH-LOGGED?
   TTRUE
   e eu
   s" help: The file may contain only `sync_root` and `dropbox_app_key`; credentials do not belong in configuration."
   CONFIG-LOGGED? TTRUE
   e eu s" could not load configuration" ENDS-LOGGED? TTRUE
   e eu s" omabox: help:" CONTAINS? TFALSE
   d str> FS:REMOVE-TREE ;

: BOUND? ( JOURNAL:dropbox-binding-write -- bool )
   MATCH JOURNAL:dropbox-binding-write
      bound OF true ENDOF
      already-bound OF false ENDOF
      mismatch OF drop false ENDOF
   ;MATCH ;

: REMOTE-UNKNOWN
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:UNKNOWN ;

\ Rust's journal: bound, and stale.txt published as stale.
: STALE-JOURNAL ( str ^ARENA:arena -- )
   {: jp ar :}
   jp JOURNAL:OPEN {: j :}
   s" account" >str s" namespace" >str s" /remote" >str
   JOURNAL-DROPBOX--BINDING:MAKE {: b :}
   j b ar JOURNAL:BIND-DROPBOX-ROOT BOUND? TTRUE
   s" stale.txt" >str MODEL:>PATH {: sp :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: v :}
   sp ar MODEL:FOLD sp MODEL-UNKNOWN--REASON:STALE REMOTE-UNKNOWN
   MODEL-REMOTE--RECORD:MAKE v VEC:PUSH !
   j s" remote-cursor" >str DROPBOX:>CURSOR v
   JOURNAL:PUBLISH-REMOTE-INVENTORY
   j JOURNAL:CLOSE ;

: STATUS-REPORTS-THE-JOURNAL-WHEN-THE-ROOT-IS-UNAVAILABLE
   ( ^ARENA:arena -- )
   {: ar :}
   s" status_reports_the_journal_when_the_root_is_unavailable" T-LABEL
   ar FIXTURE {: d x first :}
   x ar STORED {: stored :}
   x ar CONFIG:RESOLVE-PRIVATE CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR
   {: jp :}
   jp ar STALE-JOURNAL
   first str> FS:REMOVE-DIR
   jp ar ATTENTION:RENDER {: journal :}
   journal str> s" stale.txt" CONTAINS? TTRUE
   d s" stderr.txt" ar INSIDE {: p :}
   [: x ar STATUS-TEXT SHOWN ! ;] p str> ar STDERR:CAPTURING
   {: code:n e:^ eu:n :}
   code 0 T=
   SHOWN @ str> journal str> T$=
   e eu stored UNAVAILABLE
   d str> FS:REMOVE-TREE ;

\ Rust's assert_settings_json, as serde_json's exact bytes.
: SETTINGS-JSON? ( str str -- )
   {: json stored :}
   SB-RESET S\" {\n  \"sync_root\": \"" SB-APPEND stored str> SB-APPEND
   S\" \",\n  \"dropbox_app_key\": \"public-app-key\"\n}\n" SB-APPEND
   json str> SB$ T$= ;

\ The settings in the form, captured in p: the text, then the log.
: SETTINGS ( ^CONFIG:xdg form str ^ARENA:arena -- str ^u8 n )
   {: x f p ar :}
   [: x f ar SETTINGS-TEXT SHOWN ! ;] p str> ar STDERR:CAPTURING
   {: code:n e:^ eu:n :}
   code 0 T=
   SHOWN @ e eu ;

: SETTINGS-SHOW-THE-STORED-ROOT-WHEN-IT-IS-UNAVAILABLE ( ^ARENA:arena -- )
   {: ar :}
   s" settings_show_the_stored_root_when_it_is_unavailable" T-LABEL
   ar FIXTURE {: d x first :}
   x ar STORED {: stored :}
   first str> FS:REMOVE-DIR
   d s" stderr.txt" ar INSIDE {: p :}
   x construct form text p ar SETTINGS {: text e:^ eu:n :}
   e eu stored UNAVAILABLE
   SB-RESET s" Sync root: " SB-APPEND stored str> SB-APPEND
   S\" \nDropbox app key: public-app-key\n" SB-APPEND
   text str> SB$ T$=
   x construct form json p ar SETTINGS {: json je:^ jeu:n :}
   je jeu stored UNAVAILABLE
   json stored SETTINGS-JSON?
   d str> FS:REMOVE-TREE ;

: SETTINGS-JSON-IS-ONE-DOCUMENT-WHEN-THE-ROOT-IS-AVAILABLE
   ( ^ARENA:arena -- )
   {: ar :}
   s" settings_json_is_one_document_when_the_root_is_available" T-LABEL
   ar FIXTURE {: d x first :}
   x ar STORED {: stored :}
   d s" stderr.txt" ar INSIDE {: p :}
   x construct form json p ar SETTINGS {: json e:^ eu:n :}
   eu 0 T=
   json stored SETTINGS-JSON?
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
   log FILE-TEXT w wu T$=
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


\ ---- a change while the service is released

: RESTORES-RUNNING? ( option<SERVICE:goal> -- bool )
   MATCH option
      none OF false ENDOF
      some OF
         MATCH SERVICE:goal
            restore OF
               MATCH option
                  none OF false ENDOF
                  some OF
                     SERVICE-UNIT--STATE:RUNNING SERVICE-UNIT--STATE:EQ
                  ENDOF
               ;MATCH
            ENDOF
            start OF false ENDOF
            restart OF false ENDOF
            recover OF false ENDOF
            halt OF false ENDOF
            release OF false ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

: NONE? ( option<SERVICE:goal> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: RESTORE-GOAL-RESTORES-ONLY-AFTER-A-SPAWNED-RELEASE ( ^ARENA:arena -- )
   {: ar :}
   s" restore_goal_restores_only_after_a_spawned_release" T-LABEL
   ar DRIVENS-NEW {: v :}
   SERVICE-UNIT--STATE:RUNNING OPTION:SOME v SERVICE-DRIVEN:FIRST !
   SERVICE-UNIT--STATE:RUNNING OPTION:SOME v SERVICE-DRIVEN:LAST !
   false v SERVICE-DRIVEN:LAUNCHED !
   false v SERVICE-DRIVEN:ACTED !
   v RESTORE-GOAL NONE? TTRUE
   true v SERVICE-DRIVEN:ACTED !
   v RESTORE-GOAL RESTORES-RUNNING? TTRUE ;

\ The path in single quotes.
: QUOTED+ ( str -- ) s" '" SB-APPEND str> SB-APPEND s" '" SB-APPEND ;

: CODE+ ( n -- ) FMT:INT$ SB-APPEND ;

\ The script's case arms for show, stop and reset-failed.
: SETTLING+ ( str n -- )
   {: state stop:n :}
   S\" case \"$2\" in\nshow) cat " SB-APPEND state QUOTED+
   S\"  ;;\nstop) printf '%s\\n' inactive > " SB-APPEND state QUOTED+
   s" ; exit " SB-APPEND stop CODE+
   S\"  ;;\nreset-failed) printf '%s\\n' inactive > " SB-APPEND
   state QUOTED+ S\"  ;;\n" SB-APPEND ;

\ The script's case arms for list-units and start, and its end.
: STARTING+ ( str n -- )
   {: state start:n :}
   s" list-units) printf '%s\n' " SB-APPEND
   S\" 'omabox.service loaded inactive dead Omabox' ;;\n" SB-APPEND
   s" start) [ " SB-APPEND start CODE+ s"  = 0 ] || exit " SB-APPEND
   start CODE+ S\" ; printf '%s\\n' active > " SB-APPEND
   state QUOTED+ S\"  ;;\nesac\nexit 0\n" SB-APPEND ;

\ Rust's stateful_systemctl in a new directory, which it answers with
\ the commands: the unit's state in unit-state, each verb logged to
\ service.log; start exits with start, stop with stop once the unit is
\ inactive, and list-units lists the unit as loaded.
: STATEFUL ( ^u8 n n n ^ARENA:arena -- str ^SERVICE:commands )
   {: i:^ iu:n start:n stop:n ar :}
   ar TEMPORARY {: d :}
   d s" unit-state" ar INSIDE {: state :}
   d s" systemctl" ar INSIDE {: sys :}
   d s" service.log" ar INSIDE {: log :}
   SB-RESET i iu LINE+ state str> SB$ FS:WRITE-ALL
   SB-RESET S\" printf '%s\\n' \"$2\" >> " SB-APPEND
   log QUOTED+ S\" \n" SB-APPEND
   state stop SETTLING+ state start STARTING+
   sys str> SB$ FS:WRITE-ALL
   d sys s" /unused/journalctl" >str ar SERVICE:SCRIPTS ;

\ Rust's service_trace: the service log and the unit state.
: TRACE ( str ^ARENA:arena -- str str )
   {: d ar :}
   d s" service.log" ar INSIDE FILE-TEXT ar COPIED
   d s" unit-state" ar INSIDE FILE-TEXT ar COPIED ;

: NO-LEFTOVERS ( ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   ARENA:ALLOCATOR 0 [type] STALE:leftover VEC:NEW ;

\ A change that keeps the trace it sees in d and leaves nothing behind.
: WATCHED ( str ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: d ar :}
   CHANGES @ 1+ CHANGES !
   d ar TRACE DURING-STATE ! DURING-LOG !
   ar NO-LEFTOVERS ;

\ A change that fails, as Rust's InvalidAuthorizationCode stands for.
: REFUSED ( ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   drop E-IO throw ;

\ Setup, released from c around the change.
: SETUP-RELEASED ( ^SERVICE:commands
     [ ^ARENA:arena -- ^VEC:vector<STALE:leftover> ] ^ARENA:arena -- )
   {: c change ar :}
   c s" setup" s" Omabox setup is complete" change ar RELEASED ;

\ From the unit's state, the trace the change saw, then the one after.
: RUNS-RELEASED ( ^u8 n ^u8 n ^u8 n ^u8 n ^ARENA:arena -- )
   {: i:^ iu:n b:^ bu:n s:^ su:n a:^ au:n ar :}
   i iu 0 0 ar STATEFUL {: d c :}
   0 CHANGES !
   [: c [: d swap WATCHED ;] ar SETUP-RELEASED ;] catch 0 T=
   CHANGES @ 1 T=
   DURING-LOG @ str> b bu T$=
   DURING-STATE @ str> s su T$=
   d ar TRACE {: log state :}
   log str> a au T$=
   state str> S\" active\n" T$=
   d str> FS:REMOVE-TREE ;

: A-CHANGE-RUNS-WHILE-THE-SERVICE-IS-RELEASED ( ^ARENA:arena -- )
   {: ar :}
   s" a_change_runs_while_the_service_is_released" T-LABEL
   s" active" S\" show\nstop\n" S\" inactive\n"
   S\" show\nstop\nreset-failed\nstart\n" ar RUNS-RELEASED
   s" failed" S\" show\n" S\" failed\n"
   S\" show\nshow\nreset-failed\nstart\n" ar RUNS-RELEASED ;

: A-FAILED-CHANGE-STILL-RESTORES-THE-SERVICE ( ^ARENA:arena -- )
   {: ar :}
   s" a_failed_change_still_restores_the_service" T-LABEL
   s" active" 0 0 ar STATEFUL {: d c :}
   [: c [: REFUSED ;] ar SETUP-RELEASED ;] catch E-IO T=
   d ar TRACE {: log state :}
   log str> S\" show\nstop\nreset-failed\nstart\n" T$=
   state str> S\" active\n" T$=
   d str> FS:REMOVE-TREE ;

\ list-units runs once the stop fails, to tell an unloaded unit from a
\ failed stop; SERVICE logs the stop's failure.
: A-FAILED-RELEASE-SKIPS-THE-CHANGE-AND-RESTORES ( ^ARENA:arena -- )
   {: ar :}
   s" a_failed_release_skips_the_change_and_restores" T-LABEL
   s" active" 0 1 ar STATEFUL {: d c :}
   d s" stderr.txt" ar INSIDE {: p :}
   0 CHANGES !
   [: c [: d swap WATCHED ;] ar SETUP-RELEASED ;] p str> ar
   STDERR:CAPTURING {: code:n e:^ eu:n :}
   CHANGES @ 0 T=
   code SERVICE:E-UNSUCCESSFUL T=
   e eu s" service: " CONTAINS? TTRUE
   d ar TRACE {: log state :}
   log str> S\" show\nstop\nlist-units\nreset-failed\nstart\n" T$=
   state str> S\" active\n" T$=
   d str> FS:REMOVE-TREE ;


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
   ar PARSER-NAMES-THE-SETUP-OPTION-FAULT
   ar DEFAULT-SYNC-ROOT-IS-A-PRIVATE-HOME-DROPBOX-CREATED-ONCE
   ar FAILED-INITIAL-SETUP-LEAVES-NO-CONFIG-AND-SAME-COMMAND-CAN-RETRY
   ar AN-OVERLONG-AUTHORIZATION-CODE-IS-REJECTED-WITHIN-THE-BOUND
   ar AN-AUTHORIZATION-CODE-AT-THE-LIMIT-IS-ACCEPTED
   ar AN-AUTHORIZATION-CODE-IS-TRIMMED
   ar A-BLANK-OR-NON-UTF8-AUTHORIZATION-CODE-IS-REJECTED
   ar CONFIG-ERRORS-SHOW-THEIR-OWN-HELP
   ar STATUS-REPORTS-THE-JOURNAL-WHEN-THE-ROOT-IS-UNAVAILABLE
   ar SETTINGS-SHOW-THE-STORED-ROOT-WHEN-IT-IS-UNAVAILABLE
   ar SETTINGS-JSON-IS-ONE-DOCUMENT-WHEN-THE-ROOT-IS-AVAILABLE
   ar SERVICE-COMMANDS-RESET-THE-START-LIMIT-BEFORE-A-START
   ar RESTORE-GOAL-RESTORES-ONLY-AFTER-A-SPAWNED-RELEASE
   ar A-CHANGE-RUNS-WHILE-THE-SERVICE-IS-RELEASED
   ar A-FAILED-CHANGE-STILL-RESTORES-THE-SERVICE
   ar A-FAILED-RELEASE-SKIPS-THE-CHANGE-AND-RESTORES
   ar PROGRAM ;

: RUN-SUITE ( -- )
   T-RESET
   [: SUITE ;] ARENA:WITH
   s" omabox-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN-SUITE

;package
