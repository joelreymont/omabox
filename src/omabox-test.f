\ omabox-test.f - the omabox program against the Rust version's
\ src/bin/omabox.rs tests, under their names, for the forms it parses:
\ - parser_accepts_documented_forms
\ - parser_rejects_incomplete_or_secret_bearing_forms and
\   parser_names_the_setup_option_fault, each refusal's two log lines
\   checked in a file under TMPDIR; setup's forms through PARSE, their
\   options compared with OPTIONS=
\ - default_sync_root_is_a_private_home_dropbox_created_once, the home a
\   directory under TMPDIR
\ - the_widget_link_is_made_once_and_never_replaces_an_entry and
\   the_widget_link_refuses_a_bad_home_or_plugins_folder, Omabox's own:
\   HOME-WIDGET of a home under TMPDIR, each refusal's log in a file
\   there
\ - failed_initial_setup_leaves_no_config_and_same_command_can_retry,
\   the sync root and XDG homes in a directory under TMPDIR
\ - an_overlong_authorization_code_is_rejected_within_the_bound,
\   an_authorization_code_at_the_limit_is_accepted,
\   an_authorization_code_is_trimmed and
\   a_blank_or_non_utf8_authorization_code_is_rejected, each code read
\   from a pipe
\ - config_errors_show_their_own_help: set-root to a regular file logs
\   CONFIG's error and help, then OMABOX's Config line with no help of
\   its own
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
\   a_failed_change_still_restores_the_service, where a held daemon lock
\   stands in for Rust's InvalidAuthorizationCode, and
\   a_failed_release_skips_the_change_and_restores, each set-root over
\   Rust's fixture, systemctl Rust's stateful script in a directory of its
\   own under TMPDIR; the first's script also records, at each verb,
\   whether the config names the new root yet
\ - set_root_retires_live_intent_and_preserves_payloads,
\   set_root_starts_a_failed_service_after_the_change,
\   set_root_restarts_a_starting_service,
\   set_root_waits_out_a_stopping_service, the set-root half of
\   a_completed_change_reports_a_failed_start,
\   set_root_requires_the_daemon_lock_before_writing_config,
\   config_write_failure_preserves_root_generation_and_live_intent,
\   a_failed_change_and_restart_report_both,
\   set_root_works_when_the_prior_root_is_unavailable and
\   set_root_explicitly_adopts_a_replacement_at_the_same_path, each over
\   Rust's fixture with its systemctl script in the fixture's directory,
\   the journal seeded through JOURNAL and PLANNER
\ - setup_reports_a_held_lock_and_restores_the_service,
\   a_failed_change_and_restore_render_both,
\   setup_releases_the_lock_before_starting_a_failed_service and the
\   setup half of a_completed_change_reports_a_failed_start, each over
\   Rust's fixture with setup's change, writing no config, of a login
\   bound through the recording store, systemctl Rust's script for
\   the test under TMPDIR, and the log captured in a file there
\ - bind_stores_the_token_and_binds_an_unbound_journal,
\   bind_stores_the_token_for_a_journal_bound_to_the_login,
\   bind_refuses_a_journal_bound_elsewhere and
\   bind_writes_the_token_to_a_new_credential_file, Omabox's own:
\   Rust's fixture's journal, with a recording store bound in place of
\   the keyring, the credential file under TMPDIR
\ - exchanged_passes_a_token_dropbox_issues,
\   exchanged_refuses_a_token_dropbox_does_not_issue,
\   linked_refuses_an_unavailable_account,
\   linked_refuses_a_root_not_a_folder and
\   linked_refuses_an_account_of_another_root_tag, Omabox's own:
\   against test-dropbox.f's fake under DROPBOX:WITH-LOOP, each log
\   captured in a file under TMPDIR
\ - settings_show_a_root_of_any_length, Omabox's own: Rust's fixture
\   with config.toml naming a root of over 1024 bytes that is made nowhere
\ - an_unexpected_code_is_logged, Omabox's own: UNEXPECTED of a Habu
\   library code and of an OMABOX code, its log in a file under TMPDIR
\ and the program built with README's command into a directory under
\ TMPDIR, whose --version prints its name and version and exits 0, and
\ set_root_interrupted_by_sigint_restores_the_service,
\ set_root_interrupted_by_sigterm_restores_the_service,
\ set_root_interrupted_by_sighup_restores_the_service,
\ set_root_killed_during_restart_keeps_the_change,
\ set_root_killed_with_a_failed_restart_keeps_the_change and
\ set_root_interrupted_without_restart_tells_the_change_failed,
\ set_root_interrupted_during_recovery_finishes_it and
\ set_root_revives_a_failed_service, Omabox's own: that program's
\ set-root over Rust's fixture, its systemctl a script on PATH whose
\ stop, start or reset-failed sends the signal to the CLI, or none, and
\ setup_refuses_a_taken_credential_file_before_the_login, Omabox's own:
\ that program's setup of an existing file and of a dangling link under
\ TMPDIR, HOME, the XDG homes and an empty PATH directory there
\ - formal_holds_the_release_window_tables: RELEASING and CLOSING
\   against formal/ReleaseWindow.tla through TEST-FORMAL:HOLDS, which
\   runs TLC
\ White-box: OMABOX is reopened for PARSE, HOME-ROOT, HOME-WIDGET,
\ COMPLETE-SETUP, READ-CODE, RUN-SERVICE, STATUS-TEXT, SETTINGS-TEXT,
\ RESTORE-GOAL, RELEASED, CHANGE-SETUP, SET-ROOT, UNEXPECTED, EXCHANGED,
\ LINKED and BIND.
\ Run from the repository root: hb --load src/omabox-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test/assert.f
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
require src/lib/secret.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f
require src/planner.f
require src/stale.f
require src/config.f
require src/attention.f
require src/service.f
require src/stale.f
require src/version.f
require src/omabox.f
require src/test-dropbox.f
require src/test-client.f
require src/auth.f
require src/test-formal.f

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

600000 constant BUILD-MS
10000 constant RUN-MS


\ ---- paths, laid in the suite's arena

\ dir/name.
: INSIDE ( str str ^ARENA:arena -- str )
   {: d n:str ar :}
   SB-RESET d SB-APPEND s" /" SB-APPEND n SB-APPEND
   SB$ ar ARENA:COPY ;

\ A new directory under TMPDIR.
: TEMPORARY ( ^ARENA:arena -- str )
   s" omabox-test-" FS:MKTEMP-DIR swap ARENA:COPY ;

\ The file's text, empty where there is no file.
: FILE-TEXT ( str -- str )
   {: p :}
   p FS:TRY-STAT 0= if s" " exit then
   p SEEN CAP FS:READ-ALL {: u:n :}
   SEEN u >str ;


\ ---- arguments

: ARGS-RESET ( -- ) 0 ARGC ! ;

: ARG+ ( str -- )
   ARGC @ ARGS !
   ARGC @ 1+ ARGC ! ;

: ARG ( n -- str ) ARGS @ ;

: PARSED ( -- command ) ARGC @ [: ARG ;] PARSE ;

: ONE ( str -- ) ARGS-RESET ARG+ ;
: TWO ( str str -- ) swap ONE ARG+ ;


\ ---- the parser

\ The command as text, its variant and payload, for a test to compare.
: COMMAND$ ( command -- str )
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
      set-root OF s" set-root " SB-APPEND SB-APPEND ENDOF
      setup OF
         SETUP-OPTIONS-UNMAKE drop drop s" setup " SB-APPEND SB-APPEND
      ENDOF
   ;MATCH SB$ ;

: ACCEPTS-IN ( command ^ARENA:arena -- )
   {: c ar :}
   c COMMAND$ ar ARENA:COPY PARSED COMMAND$ T$= ;

: ACCEPTS ( command -- ) {: c :} [: c swap ACCEPTS-IN ;] ARENA:WITH ;

\ Options no setup form parses to, for a command other than setup.
: NOT-SETUP ( -- setup-options )
   s" not setup" NO-INITIAL NO-STR SETUP-OPTIONS-MAKE ;

\ The setup options PARSE answers for the arguments.
: SETUP-PARSED ( -- setup-options )
   PARSED MATCH command
      setup OF ENDOF
      help OF NOT-SETUP ENDOF
      version OF NOT-SETUP ENDOF
      status OF NOT-SETUP ENDOF
      settings OF drop NOT-SETUP ENDOF
      set-root OF drop NOT-SETUP ENDOF
      service OF drop NOT-SETUP ENDOF
      logs OF NOT-SETUP ENDOF
   ;MATCH ;

\ The bytes and whether there are any.
: SOME$ ( option<str> -- str bool )
   MATCH option
      some OF true ENDOF
      none OF s" " false ENDOF
   ;MATCH ;

: SAME-BOOL? ( bool bool -- bool ) bool>n swap bool>n = ;

: STRS= ( option<str> option<str> -- bool )
   SOME$ {: b:str bf:bool :} SOME$ {: a:str af:bool :}
   af bf SAME-BOOL? a b STR:= and ;

\ The sync root, the key and whether there is an initial config.
: INITIAL$ ( option<initial-config> -- option<str> str bool )
   MATCH option
      some OF INITIAL-CONFIG-UNMAKE true ENDOF
      none OF NO-STR s" " false ENDOF
   ;MATCH ;

: INITIALS= ( option<initial-config> option<initial-config> -- bool )
   INITIAL$ {: bs bk:str bf:bool :}
   INITIAL$ {: as ak:str af:bool :}
   af bf SAME-BOOL? ak bk STR:= and as bs STRS= and ;

\ Rust's derived PartialEq of SetupOptions.
: OPTIONS= ( setup-options setup-options -- bool )
   SETUP-OPTIONS-UNMAKE {: br bi bc :}
   SETUP-OPTIONS-UNMAKE {: ar ai ac :}
   ar br STR:= ai bi INITIALS= and ac bc STRS= and ;

: SETUP-ACCEPTS ( setup-options -- ) SETUP-PARSED OPTIONS= TTRUE ;

\ The remote root, initial config and credential file.
: FILE-OPTIONS ( str option<initial-config> option<str> -- setup-options )
   SETUP-OPTIONS-MAKE ;

\ The remote root and initial config, for the Secret Service.
: OPTIONS ( str option<initial-config> -- setup-options )
   NO-STR FILE-OPTIONS ;

\ The sync root and app key of a setup driven by flags.
: FLAGS ( option<str> str -- option<initial-config> )
   INITIAL-CONFIG-MAKE OPTION:SOME ;

: SOME-STR ( str -- option<str> ) OPTION:SOME ;

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
   s" setup" s" --app-key" TWO s" key" ARG+
   s" --credential-file" ARG+ s" /tmp/credential" ARG+
   s" " NO-STR s" key" FLAGS s" /tmp/credential" SOME-STR FILE-OPTIONS
   SETUP-ACCEPTS
   s" setup" s" --credential-file" TWO s" /tmp/credential" ARG+
   s" " NO-INITIAL s" /tmp/credential" SOME-STR FILE-OPTIONS SETUP-ACCEPTS
   s" setup" s" --remote-root" TWO s" /Work" ARG+
   s" --credential-file" ARG+ s" /tmp/credential" ARG+
   s" /Work" NO-INITIAL s" /tmp/credential" SOME-STR FILE-OPTIONS
   SETUP-ACCEPTS
   s" service" s" restart" TWO
   SERVICE-ACTION:RESTART SERVICE-COMMAND ACCEPTS
   s" logs" ONE construct command logs ACCEPTS
   s" status" ONE construct command status ACCEPTS
   s" settings" ONE construct form text COMMAND-SETTINGS ACCEPTS
   s" settings" s" --json" TWO
   construct form json COMMAND-SETTINGS ACCEPTS
   s" settings" s" set-root" TWO s" /tmp/new" ARG+
   s" /tmp/new" COMMAND-SET-ROOT ACCEPTS ;

: LINES ( str -- n )
   {: s:str :}
   s str> {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;

\ Whether the log holds "omabox: " t and LF.
: LOGGED? ( str str -- bool )
   {: a:str t:str :}
   SB-RESET s" omabox: " SB-APPEND t SB-APPEND 10 SB-APPEND-C
   a SB$ STR:CONTAINS? ;

\ A Usage refusal: the fault m's line, then the help line.
: USAGE-LOGGED ( n str str -- )
   {: code:n e:str m:str :}
   code E-USAGE T=
   e LINES 2 T=
   e m LOGGED? TTRUE
   e s" help: Run `omabox --help` for usage." LOGGED? TTRUE ;

\ The arguments are refused as Usage with the fault m, captured in the
\ file at p.
: REJECTS ( str str ^ARENA:arena -- )
   {: m:str p ar :}
   [: PARSED drop ;] p ar STDERR:CAPTURING m USAGE-LOGGED ;

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
   s" flag-driven setup requires --app-key" p ar REJECTS
   s" setup" s" --credential-file" TWO s" /tmp/credential" ARG+
   s" --sync-root" ARG+ s" /tmp/Dropbox" ARG+
   s" flag-driven setup requires --app-key" p ar REJECTS
   s" setup" s" --remote-root" TWO s" /Work" ARG+
   s" flag-driven setup requires --app-key" p ar REJECTS
   s" setup" s" --credential-file" TWO s" " ARG+
   s" the credential file must not be empty" p ar REJECTS
   s" setup" s" --sync-root" TWO s" /tmp/Dropbox" ARG+
   s" --app-key" ARG+ s" key" ARG+
   s" --app-secret" ARG+ s" secret" ARG+
   s" unknown setup option" p ar REJECTS
   d FS:REMOVE-TREE ;

: ROOT-FAULT$ ( -- str )
   s" the Dropbox root must be empty or an absolute folder path such as /Work, with no trailing slash and no empty, . or .. parts" ;

: PARSER-NAMES-THE-SETUP-OPTION-FAULT ( ^ARENA:arena -- )
   {: ar :}
   s" parser_names_the_setup_option_fault" T-LABEL
   ar TEMPORARY {: d :}
   d s" stderr.txt" ar INSIDE {: p :}
   s" setup" s" --help" TWO s" unknown setup option" p ar REJECTS
   s" setup" s" --sync-root" TWO s" /tmp/Dropbox" ARG+ s" --bogus" ARG+
   s" unknown setup option" p ar REJECTS
   s" setup" s" --app-key" TWO
   s" a setup option is missing its value" p ar REJECTS
   s" setup" s" --app-key" TWO s" key" ARG+ s" --app-key" ARG+
   s" a setup option was provided more than once" p ar REJECTS
   s" setup" s" --app-key" TWO s" key" ARG+
   s" --credential-file" ARG+ s" /tmp/a" ARG+
   s" --credential-file" ARG+ s" /tmp/b" ARG+
   s" a setup option was provided more than once" p ar REJECTS
   s" setup" s" -h" TWO ROOT-FAULT$ p ar REJECTS
   s" setup" s" Work" TWO ROOT-FAULT$ p ar REJECTS
   s" setup" s" /Work/" TWO ROOT-FAULT$ p ar REJECTS
   s" setup" s" /Work/../Home" TWO ROOT-FAULT$ p ar REJECTS
   s" setup" s" --sync-root" TWO s" /tmp/Dropbox" ARG+
   s" --app-key" ARG+ s" key" ARG+ s" --remote-root" ARG+ s" Work" ARG+
   ROOT-FAULT$ p ar REJECTS
   d FS:REMOVE-TREE ;


\ ---- setup's local steps

\ HOME-ROOT of the home, refused with the code, captured in p.
: NO-ROOT ( option<str> str ^ARENA:arena -- )
   {: home p ar :}
   [: home ar HOME-ROOT drop ;] p ar STDERR:CAPTURING
   {: code:n e:str :}
   code E-NO-DEFAULT-ROOT T=
   e LINES 2 T= ;

\ HOME-ROOT of the home is root, a directory of mode 0700.
: PRIVATE-ROOT ( str str ^ARENA:arena -- )
   {: home root ar :}
   home OPTION:SOME ar HOME-ROOT root T$=
   root FS:STAT-MODE $1FF and FS:MODE-PRIVATE-DIR T= ;

: DEFAULT-SYNC-ROOT-IS-A-PRIVATE-HOME-DROPBOX-CREATED-ONCE
   ( ^ARENA:arena -- )
   {: ar :}
   s" default_sync_root_is_a_private_home_dropbox_created_once" T-LABEL
   ar TEMPORARY {: d :}
   d s" home" ar INSIDE {: home :}
   home FS:MAKE-DIR
   home s" Dropbox" ar INSIDE {: root :}
   home root ar PRIVATE-ROOT
   home root ar PRIVATE-ROOT
   d s" stderr.txt" ar INSIDE {: p :}
   NO-STR p ar NO-ROOT
   s" relative/home" SOME-STR p ar NO-ROOT
   d FS:REMOVE-TREE ;

\ The symlink at link reads as the target.
: LINKS-TO ( str str ^ARENA:arena -- )
   {: link t:str ar :}
   link ar CONFIG:READLINK MATCH option
      some OF t T$= ENDOF
      none OF false TTRUE ENDOF
   ;MATCH ;

\ HOME-WIDGET of the home, refused with the code, captured in p.
: WIDGET-REFUSED ( option<str> n str ^ARENA:arena -- )
   {: home want:n p ar :}
   [: home ar HOME-WIDGET ;] p ar STDERR:CAPTURING
   {: code:n e:str :}
   code want T=
   e LINES 2 T= ;

\ HOME-WIDGET of the home links link, then leaves it as it is.
: LINKED-ONCE ( str str ^ARENA:arena -- )
   {: home link ar :}
   home OPTION:SOME ar HOME-WIDGET
   link WIDGET ar LINKS-TO
   home OPTION:SOME ar HOME-WIDGET
   link WIDGET ar LINKS-TO ;

\ A link at link to another target is refused and kept.
: OTHER-LINK-KEPT ( str str str ^ARENA:arena -- )
   {: home link p ar :}
   link FS:REMOVE-FILE
   s" /elsewhere" link FS:MAKE-SYMLINK
   home OPTION:SOME E-WIDGET-TAKEN p ar WIDGET-REFUSED
   link s" /elsewhere" ar LINKS-TO ;

\ A folder at link with no manifest is refused and kept with what it holds.
: FOLDER-KEPT ( str str str ^ARENA:arena -- )
   {: home link p ar :}
   link FS:REMOVE-FILE
   link s" kept" ar INSIDE {: kept :}
   kept FS:MAKE-DIRS
   home OPTION:SOME E-WIDGET-TAKEN p ar WIDGET-REFUSED
   link FS:SYMLINK? TFALSE
   kept FS:DIR? TTRUE ;

: OTHER-MANIFEST ( -- str ) s\" {\"id\": \"local.other\"}" ;

: OWN-MANIFEST ( -- str )
   s\" {\"id\": \"local.omabox\", \"name\": \"Omabox\"}" ;

\ The folder at link, given a manifest naming another id, is refused and
\ kept with its manifest.
: OTHER-ID-KEPT ( str str str ^ARENA:arena -- )
   {: home link p ar :}
   link s" manifest.json" ar INSIDE {: m :}
   m OTHER-MANIFEST FS:WRITE-ALL
   home OPTION:SOME E-WIDGET-TAKEN p ar WIDGET-REFUSED
   link FS:SYMLINK? TFALSE
   m FILE-TEXT OTHER-MANIFEST T$= ;

\ The folder at link, given a manifest naming local.omabox, is the widget
\ Rust's setup installed: accepted and kept as it is, with no link made.
: OWN-FOLDER-KEPT ( str str ^ARENA:arena -- )
   {: home link ar :}
   link s" manifest.json" ar INSIDE {: m :}
   link s" Widget.qml" ar INSIDE {: q :}
   m OWN-MANIFEST FS:WRITE-ALL
   q s" Item {}" FS:WRITE-ALL
   home OPTION:SOME ar HOME-WIDGET
   link FS:SYMLINK? TFALSE
   link FS:DIR? TTRUE
   m FILE-TEXT OWN-MANIFEST T$=
   q FILE-TEXT s" Item {}" T$=
   link s" kept" ar INSIDE FS:DIR? TTRUE ;

: THE-WIDGET-LINK-IS-MADE-ONCE-AND-NEVER-REPLACES-AN-ENTRY
   ( ^ARENA:arena -- )
   {: ar :}
   s" the_widget_link_is_made_once_and_never_replaces_an_entry" T-LABEL
   ar TEMPORARY {: d :}
   d s" home" ar INSIDE {: home :}
   home FS:MAKE-DIR
   home s" .config/omarchy/plugins/local.omabox" ar INSIDE {: link :}
   d s" stderr.txt" ar INSIDE {: p :}
   home link ar LINKED-ONCE
   home link p ar OTHER-LINK-KEPT
   home link p ar FOLDER-KEPT
   home link p ar OTHER-ID-KEPT
   home link ar OWN-FOLDER-KEPT
   d FS:REMOVE-TREE ;

\ A file at home/.config is refused and kept.
: CONFIG-FILE-KEPT ( str str ^ARENA:arena -- )
   {: home p ar :}
   home s" .config" ar INSIDE {: f :}
   f s" not a directory" FS:WRITE-ALL
   home OPTION:SOME E-LINK-WIDGET p ar WIDGET-REFUSED
   f FS:FILE? TTRUE
   f FS:REMOVE-FILE ;

\ A plugins folder of mode 0500 is refused and left with no link.
: READ-ONLY-PLUGINS ( str str ^ARENA:arena -- )
   {: home p ar :}
   home s" .config/omarchy/plugins" ar INSIDE {: dir :}
   dir FS:MAKE-DIRS
   dir $140 FS:CHMOD-MODE
   home OPTION:SOME E-LINK-WIDGET p ar WIDGET-REFUSED
   dir FS:MODE-PRIVATE-DIR FS:CHMOD-MODE
   dir s" local.omabox" ar INSIDE FS:SYMLINK? TFALSE ;

: THE-WIDGET-LINK-REFUSES-A-BAD-HOME-OR-PLUGINS-FOLDER
   ( ^ARENA:arena -- )
   {: ar :}
   s" the_widget_link_refuses_a_bad_home_or_plugins_folder" T-LABEL
   ar TEMPORARY {: d :}
   d s" stderr.txt" ar INSIDE {: p :}
   NO-STR E-NO-HOME p ar WIDGET-REFUSED
   s" relative/home" SOME-STR E-NO-HOME p ar WIDGET-REFUSED
   d s" home" ar INSIDE {: home :}
   home FS:MAKE-DIR
   home p ar CONFIG-FILE-KEPT
   home p ar READ-ONLY-PLUGINS
   d FS:REMOVE-TREE ;

\ setup --sync-root root --app-key public-app-key.
: SETUP-ARGS ( str -- )
   {: root :}
   s" setup" s" --sync-root" TWO root ARG+
   s" --app-key" ARG+ s" public-app-key" ARG+ ;

\ The documented setup form parsed, its config made and prepared, and
\ COMPLETE-SETUP run with bind: the code, the log captured in p.
: ATTEMPT ( str ^CONFIG:xdg [ -- ] str ^ARENA:arena -- n )
   {: root x bind p ar :}
   root SETUP-ARGS
   SETUP-PARSED s" " root SOME-STR s" public-app-key" FLAGS OPTIONS
   OPTIONS= TTRUE
   x root s" public-app-key" ar CONFIG:FROM-VALUES {: c :}
   c CONFIG:PREPARE
   [: c true bind ar COMPLETE-SETUP drop ;] p ar STDERR:CAPTURING
   {: code:n e:str :}
   code ;

: FAILED-INITIAL-SETUP-LEAVES-NO-CONFIG-AND-SAME-COMMAND-CAN-RETRY
   ( ^ARENA:arena -- )
   {: ar :}
   s" failed_initial_setup_leaves_no_config_and_same_command_can_retry"
   T-LABEL
   ar TEMPORARY {: d :}
   d s" Dropbox" ar INSIDE {: root :}
   root FS:MAKE-DIR
   d s" config" ar INSIDE CONFIG:>ABS-PATH
   d s" state" ar INSIDE CONFIG:>ABS-PATH ar CONFIG:XDG-NEW {: x :}
   x ar CONFIG:XDG-CONFIG-FILE CONFIG:ABS-PATH>STR {: file :}
   d s" stderr.txt" ar INSIDE {: p :}
   root x [: E-INVALID-CODE throw ;] p ar ATTEMPT E-INVALID-CODE T=
   file FS:TRY-STAT TFALSE
   root x [: ;] p ar ATTEMPT 0 T=
   x ar CONFIG:LOAD-FROM CONFIG:APP-KEY s" public-app-key" T$=
   d FS:REMOVE-TREE ;

\ A pipe holding the bytes, its write end closed: the read end.
: PIPED ( str -- fd )
   {: s:str :}
   FD:PIPE {: r:fd w:fd :}
   w s FD:WRITE-FULL
   w FD>N close
   r ;

\ The bytes left in the pipe; closes it.
: REST ( fd -- n )
   {: f:fd :}
   0 begin f FD>N SEEN CAP SPAN:MAKE read dup 0 > while + repeat drop
   f FD>N close ;

\ READ-CODE of the bytes from a pipe, captured in p: the code, the text
\ read in SHOWN, and the pipe's read end.
: CODE-READ ( str str ^ARENA:arena -- n fd )
   {: s:str p ar :}
   s PIPED {: f:fd :}
   [: f ar READ-CODE SHOWN ! ;] p ar STDERR:CAPTURING
   {: code:n e:str :}
   code f ;

\ The bytes read as the code c.
: CODE-ACCEPTED ( str str str ^ARENA:arena -- )
   {: s:str c:str p ar :}
   s p ar CODE-READ {: code:n f:fd :}
   code 0 T=
   SHOWN @ c T$=
   f REST drop ;

\ The bytes refused as E-INVALID-CODE: the bytes left unread.
: CODE-REFUSED ( str str ^ARENA:arena -- n )
   {: s:str p ar :}
   s p ar CODE-READ {: code:n f:fd :}
   code E-INVALID-CODE T=
   f REST ;

\ n bytes a in the arena.
: AS ( n ^ARENA:arena -- str )
   {: n:n ar :}
   ar n ARENA:ALLOC {: b:^ u:n :}
   u 0 ?do 97 b i + c! loop
   b u >str ;

\ n bytes a, then LF.
: AS-LINE ( n ^ARENA:arena -- str )
   {: n:n ar :}
   n 1+ ar AS {: s:str :}
   s str> {: b:^ u:n :}
   10 b n + c!
   s ;

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
   d FS:REMOVE-TREE ;

: AN-AUTHORIZATION-CODE-AT-THE-LIMIT-IS-ACCEPTED ( ^ARENA:arena -- )
   {: ar :}
   s" an_authorization_code_at_the_limit_is_accepted" T-LABEL
   ar LOG-FILE {: d p :}
   CODE-LIMIT ar AS-LINE CODE-LIMIT ar AS p ar CODE-ACCEPTED
   SHOWN @ str> nip CODE-LIMIT T=
   d FS:REMOVE-TREE ;

: AN-AUTHORIZATION-CODE-IS-TRIMMED ( ^ARENA:arena -- )
   {: ar :}
   s" an_authorization_code_is_trimmed" T-LABEL
   ar LOG-FILE {: d p :}
   S\" \x20\tcode \r\n" s" code" p ar CODE-ACCEPTED
   s" code" s" code" p ar CODE-ACCEPTED
   d FS:REMOVE-TREE ;

: A-BLANK-OR-NON-UTF8-AUTHORIZATION-CODE-IS-REJECTED ( ^ARENA:arena -- )
   {: ar :}
   s" a_blank_or_non_utf8_authorization_code_is_rejected" T-LABEL
   ar LOG-FILE {: d p :}
   S\" \x20\x20\n" p ar CODE-REFUSED 0 T=
   S\" \xff\n" p ar CODE-REFUSED 0 T=
   d FS:REMOVE-TREE ;


\ ---- status and settings

\ Rust's fixture: answers DIR, the XDG over DIR/config and DIR/state,
\ and the sync root DIR/first; the config holds public-app-key.
: FIXTURE ( ^ARENA:arena -- str ^CONFIG:xdg str )
   {: ar :}
   ar TEMPORARY {: d :}
   d s" first" ar INSIDE {: first :}
   first FS:MAKE-DIRS
   d s" config" ar INSIDE CONFIG:>ABS-PATH
   d s" state" ar INSIDE CONFIG:>ABS-PATH ar CONFIG:XDG-NEW {: x :}
   x first s" public-app-key" ar CONFIG:FROM-VALUES
   {: c :}
   c CONFIG:PREPARE
   c ar CONFIG:WRITE drop
   d x first ;

: STORED ( ^CONFIG:xdg ^ARENA:arena -- str )
   CONFIG:DOCUMENT-LOAD-FROM CONFIG:DOCUMENT-ROOT CONFIG:ABS-PATH>STR ;

\ Whether the log ends with "omabox: " t and LF.
: ENDS-LOGGED? ( str str -- bool )
   {: a:str t:str :}
   SB-RESET s" omabox: " SB-APPEND t SB-APPEND 10 SB-APPEND-C
   a SB$ STR:ENDS-WITH? ;

\ Whether the log holds "config: " t and LF.
: CONFIG-LOGGED? ( str str -- bool )
   {: a:str t:str :}
   SB-RESET s" config: " SB-APPEND t SB-APPEND 10 SB-APPEND-C
   a SB$ STR:CONTAINS? ;

\ Whether the log holds "config: " t, the path p in backticks, and LF.
: PATH-LOGGED? ( str str str -- bool )
   {: a:str t:str p :}
   SB-RESET s" config: " SB-APPEND t SB-APPEND s" `" SB-APPEND
   p SB-APPEND s" `" SB-APPEND 10 SB-APPEND-C
   a SB$ STR:CONTAINS? ;

\ CONFIG's refusal of the stored root once it is gone: its two lines
\ alone, Rust's unavailable_line.
: UNAVAILABLE ( str str -- )
   {: e:str root :}
   e LINES 2 T=
   e s" could not resolve sync root " root PATH-LOGGED? TTRUE
   e
   s" help: Create the sync root as a local directory and ensure it is accessible."
   CONFIG-LOGGED? TTRUE ;

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
   s" account" s" namespace" s" /remote"
   JOURNAL-DROPBOX--BINDING:MAKE {: b :}
   j b ar JOURNAL:BIND-DROPBOX-ROOT BOUND? TTRUE
   s" stale.txt" MODEL:>PATH {: sp :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: v :}
   sp ar MODEL:FOLD sp MODEL-UNKNOWN--REASON:STALE REMOTE-UNKNOWN
   MODEL-REMOTE--RECORD:MAKE v VEC:PUSH !
   j s" remote-cursor" DROPBOX:>CURSOR v
   JOURNAL:UPSERT-REMOTE-RECORDS
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
   first FS:REMOVE-DIR
   jp ar ATTENTION:RENDER {: journal :}
   journal s" stale.txt" STR:CONTAINS? TTRUE
   d s" stderr.txt" ar INSIDE {: p :}
   [: x ar STATUS-TEXT SHOWN ! ;] p ar STDERR:CAPTURING
   {: code:n e:str :}
   code 0 T=
   SHOWN @ journal T$=
   e stored UNAVAILABLE
   d FS:REMOVE-TREE ;

\ Rust's assert_settings_json, as serde_json's exact bytes.
: SETTINGS-JSON? ( str str -- )
   {: json stored :}
   SB-RESET S\" {\n  \"sync_root\": \"" SB-APPEND stored SB-APPEND
   S\" \",\n  \"dropbox_app_key\": \"public-app-key\"\n}\n" SB-APPEND
   json SB$ T$= ;

\ The settings in the form, captured in p: the text, then the log.
: SETTINGS ( ^CONFIG:xdg form str ^ARENA:arena -- str str )
   {: x f p ar :}
   [: x f ar SETTINGS-TEXT SHOWN ! ;] p ar STDERR:CAPTURING
   {: code:n e:str :}
   code 0 T=
   SHOWN @ e ;

: SETTINGS-SHOW-THE-STORED-ROOT-WHEN-IT-IS-UNAVAILABLE ( ^ARENA:arena -- )
   {: ar :}
   s" settings_show_the_stored_root_when_it_is_unavailable" T-LABEL
   ar FIXTURE {: d x first :}
   x ar STORED {: stored :}
   first FS:REMOVE-DIR
   d s" stderr.txt" ar INSIDE {: p :}
   x construct form text p ar SETTINGS {: text e:str :}
   e stored UNAVAILABLE
   SB-RESET s" Sync root: " SB-APPEND stored SB-APPEND
   S\" \nDropbox app key: public-app-key\n" SB-APPEND
   text SB$ T$=
   x construct form json p ar SETTINGS {: json je:str :}
   je stored UNAVAILABLE
   json stored SETTINGS-JSON?
   d FS:REMOVE-TREE ;

: SETTINGS-JSON-IS-ONE-DOCUMENT-WHEN-THE-ROOT-IS-AVAILABLE
   ( ^ARENA:arena -- )
   {: ar :}
   s" settings_json_is_one_document_when_the_root_is_available" T-LABEL
   ar FIXTURE {: d x first :}
   x ar STORED {: stored :}
   d s" stderr.txt" ar INSIDE {: p :}
   x construct form json p ar SETTINGS {: json e:str :}
   e str> nip 0 T=
   json stored SETTINGS-JSON?
   d FS:REMOVE-TREE ;

\ The str s, then the bytes, laid in the arena.
: APPENDED ( str str ^ARENA:arena -- str )
   {: s t:str ar :}
   s str> {: sa:^ su:n :}
   t str> {: a:^ u:n :}
   ar su u + ARENA:ALLOC drop {: b:^ :}
   sa b su BYTE-COPY
   a b su + u BYTE-COPY
   b su u + >str ;

\ DIR and five components of 255 bytes each, made nowhere.
: LONG-ROOT ( str ^ARENA:arena -- str )
   {: d ar :}
   ar 255 ARENA:ALLOC drop {: part:^ :}
   255 0 ?do [char] x part i + c! loop
   d 5 0 ?do s" /" ar APPENDED part 255 >str ar APPENDED loop ;

\ A sync root longer than string.f's builder holds shows whole.
: SETTINGS-SHOW-A-ROOT-OF-ANY-LENGTH ( ^ARENA:arena -- )
   {: ar :}
   s" settings_show_a_root_of_any_length" T-LABEL
   ar FIXTURE {: d x first :}
   d ar LONG-ROOT {: root :}
   root str> nip 1024 > TTRUE
   S\" sync_root = \"" root ar APPENDED
   S\" \"\ndropbox_app_key = \"public-app-key\"\n" ar APPENDED {: toml :}
   x ar CONFIG:XDG-CONFIG-FILE CONFIG:ABS-PATH>STR toml FS:WRITE-ALL
   d s" stderr.txt" ar INSIDE {: p :}
   x construct form text p ar SETTINGS {: text e:str :}
   e s" could not resolve sync root " STR:CONTAINS? TTRUE
   e root STR:CONTAINS? TTRUE
   s" Sync root: " root ar APPENDED
   S\" \nDropbox app key: public-app-key\n" ar APPENDED {: want :}
   text want T$=
   d FS:REMOVE-TREE ;


\ ---- the service commands

\ Rust's fake_systemctl: logs each verb to log and answers show with
\ the state.
: FAKE-SYSTEMCTL ( str str str -- )
   {: p s:str log :}
   SB-RESET S\" printf '%s\\n' \"$2\" >> '" SB-APPEND
   log SB-APPEND
   S\" '\nif [ \"$2\" = show ]; then printf '%s\\n' " SB-APPEND
   s SB-APPEND S\" ; fi\nexit 0\n" SB-APPEND
   p SB$ FS:WRITE-ALL ;

\ The action run on a unit in the state logs the verbs w.
: RESETS ( SERVICE:action str str ^ARENA:arena -- )
   {: act s:str w:str ar :}
   ar TEMPORARY {: d :}
   d s" service.log" ar INSIDE {: log :}
   d s" systemctl" ar INSIDE {: sys :}
   sys s log FAKE-SYSTEMCTL
   sys s" /unused/journalctl" ar SERVICE:SCRIPTS {: c :}
   [: c act ar RUN-SERVICE ;] catch 0 T=
   log FILE-TEXT w T$=
   d FS:REMOVE-TREE ;

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
: QUOTED+ ( str -- ) s" '" SB-APPEND SB-APPEND s" '" SB-APPEND ;

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

\ A stateful systemctl's script, appended: it logs each verb to log,
\ runs the shell line w, then answers the verb over the unit state in
\ state, stop and start exiting with their codes.
: SCRIPT+ ( str str n n str -- )
   {: state log start:n stop:n w:str :}
   S\" printf '%s\\n' \"$2\" >> " SB-APPEND
   log QUOTED+ S\" \n" SB-APPEND w SB-APPEND
   state stop SETTLING+ state start STARTING+ ;

\ Rust's stateful_systemctl, running the shell line w after it logs each
\ verb: a new directory, holding unit-state and service.log, and commands.
: WATCHING ( str n n str ^ARENA:arena -- str ^SERVICE:commands )
   {: i:str start:n stop:n w:str ar :}
   ar TEMPORARY {: d :}
   d s" unit-state" ar INSIDE {: state :}
   d s" systemctl" ar INSIDE {: sys :}
   d s" service.log" ar INSIDE {: log :}
   SB-RESET i LINE+ state SB$ FS:WRITE-ALL
   SB-RESET state log start stop w SCRIPT+
   sys SB$ FS:WRITE-ALL
   d sys s" /unused/journalctl" ar SERVICE:SCRIPTS ;

\ Rust's stateful_systemctl.
: STATEFUL ( str n n ^ARENA:arena -- str ^SERVICE:commands )
   {: i:str start:n stop:n ar :}
   i start stop s" " ar WATCHING ;

\ Rust's service_trace: the service log and the unit state.
: TRACE ( str ^ARENA:arena -- str str )
   {: d ar :}
   d s" service.log" ar INSIDE FILE-TEXT ar ARENA:COPY
   d s" unit-state" ar INSIDE FILE-TEXT ar ARENA:COPY ;

\ SET-ROOT of root over the XDG with the commands, its log captured in
\ DIR/stderr.txt: the code and the log.
: SET ( str ^CONFIG:xdg ^SERVICE:commands str ^ARENA:arena -- n str )
   {: root x c d ar :}
   d s" stderr.txt" ar INSIDE {: p :}
   [: root x c ar SET-ROOT ;] p ar STDERR:CAPTURING ;

\ A shell line that appends the verb $2 and whether the config file f
\ names the root r to the file at w.
: CHANGE-SEEN ( str str str ^ARENA:arena -- str )
   {: f:str r:str w:str ar :}
   SB-RESET r SB-APPEND S\" \q" SB-APPEND SB$ ar ARENA:COPY {: n :}
   SB-RESET s" if grep -qF " SB-APPEND n QUOTED+ s"  " SB-APPEND f QUOTED+
   S\" ; then echo \"$2 changed\"; else echo \"$2 unchanged\"; fi >> "
   SB-APPEND w QUOTED+ S\" \n" SB-APPEND SB$ ar ARENA:COPY ;

\ set-root to DIR/second from a unit in the state i: w the verbs as the
\ config stood at each, a the service log; the unit ends active.
: RUNS-RELEASED ( str str str ^ARENA:arena -- )
   {: i:str w:str a:str ar :}
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   d s" watch.log" ar INSIDE {: watch :}
   x ar CONFIG:RESOLVE-PRIVATE ar CONFIG:CONFIG-FILE CONFIG:ABS-PATH>STR
   second watch ar CHANGE-SEEN {: line :}
   i 0 0 line ar WATCHING {: sd c :}
   second x c d ar SET {: code:n e:str :}
   code 0 T=
   x ar STORED second T$=
   watch FILE-TEXT w T$=
   sd ar TRACE {: log state :}
   log a T$=
   state S\" active\n" T$=
   sd FS:REMOVE-TREE
   d FS:REMOVE-TREE ;

: A-CHANGE-RUNS-WHILE-THE-SERVICE-IS-RELEASED ( ^ARENA:arena -- )
   {: ar :}
   s" a_change_runs_while_the_service_is_released" T-LABEL
   s" active"
   S\" show unchanged\nstop unchanged\nreset-failed changed\nstart changed\n"
   S\" show\nstop\nreset-failed\nstart\n" ar RUNS-RELEASED
   s" failed"
   S\" show unchanged\nshow changed\nreset-failed changed\nstart changed\n"
   S\" show\nshow\nreset-failed\nstart\n" ar RUNS-RELEASED ;

\ The change refused under a held daemon lock.
: A-FAILED-CHANGE-STILL-RESTORES-THE-SERVICE ( ^ARENA:arena -- )
   {: ar :}
   s" a_failed_change_still_restores_the_service" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   x ar CONFIG:RESOLVE-PRIVATE CONFIG:LOCK {: held :}
   s" active" 0 0 ar STATEFUL {: sd c :}
   second x c d ar SET {: code:n e:str :}
   held CONFIG:UNLOCK
   code E-LOCK T=
   x ar STORED first T$=
   sd ar TRACE {: log state :}
   log S\" show\nstop\nreset-failed\nstart\n" T$=
   state S\" active\n" T$=
   sd FS:REMOVE-TREE
   d FS:REMOVE-TREE ;

\ list-units runs once the stop fails, to tell an unloaded unit from a
\ failed stop; SERVICE logs the stop's failure.
: A-FAILED-RELEASE-SKIPS-THE-CHANGE-AND-RESTORES ( ^ARENA:arena -- )
   {: ar :}
   s" a_failed_release_skips_the_change_and_restores" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   s" active" 0 1 ar STATEFUL {: sd c :}
   second x c d ar SET {: code:n e:str :}
   code SERVICE:E-UNSUCCESSFUL T=
   e s" service: " STR:CONTAINS? TTRUE
   x ar STORED first T$=
   sd ar TRACE {: log state :}
   log S\" show\nstop\nlist-units\nreset-failed\nstart\n" T$=
   state S\" active\n" T$=
   sd FS:REMOVE-TREE
   d FS:REMOVE-TREE ;


\ ---- the sync-root change

\ The commands no test of a refused root reaches.
: UNUSED ( ^ARENA:arena -- ^SERVICE:commands )
   {: ar :}
   s" /unused/systemctl" s" /unused/journalctl" ar SERVICE:SCRIPTS ;


: CONFIG-ERRORS-SHOW-THEIR-OWN-HELP ( ^ARENA:arena -- )
   {: ar :}
   s" config_errors_show_their_own_help" T-LABEL
   ar FIXTURE {: d x first :}
   d s" file" ar INSIDE {: file :}
   file s" not a directory" FS:WRITE-ALL
   file x ar UNUSED d ar SET {: code:n e:str :}
   code CONFIG:E-SYNC-ROOT-NOT-DIRECTORY T=
   e LINES 3 T=
   e s" help: Set `sync_root` to an existing local directory."
   CONFIG-LOGGED? TTRUE
   e s" could not validate the new sync root" ENDS-LOGGED? TTRUE
   e s" omabox: help:" STR:CONTAINS? TFALSE
   d FS:REMOVE-TREE ;

\ Rust's fake_systemctl in DIR, answering show with the state: the
\ commands and the service log.
: FAKED ( str str ^ARENA:arena -- ^SERVICE:commands str )
   {: d s:str ar :}
   d s" service.log" ar INSIDE {: log :}
   d s" systemctl" ar INSIDE {: sys :}
   sys s log FAKE-SYSTEMCTL
   sys s" /unused/journalctl" ar SERVICE:SCRIPTS log ;

: PATHS-OF ( ^CONFIG:xdg ^ARENA:arena -- ^CONFIG:paths )
   CONFIG:RESOLVE-PRIVATE ;

: JOURNAL-PATH ( ^CONFIG:xdg ^ARENA:arena -- str )
   PATHS-OF CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR ;

\ The journal at the fixture's state path, its root activated at first.
: ACTIVE-JOURNAL ( ^CONFIG:xdg str ^ARENA:arena -- JOURNAL:journal )
   {: x first ar :}
   x ar JOURNAL-PATH JOURNAL:OPEN {: j :}
   j first JOURNAL:INSPECT ar JOURNAL:ACTIVATE-LOCAL-ROOT drop
   j ;

: ONE-PLAN ( MODEL:operation ^ARENA:arena -- JOURNAL:operation-plan )
   {: o ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:operation VEC:NEW {: ops :}
   o ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

\ Rust's let Decision::Operations(plan) = plan(...) else fail.
: OPERATIONS ( MODEL:decision ^ARENA:arena -- JOURNAL:operation-plan )
   {: ar :}
   MATCH MODEL:decision
      operate OF ENDOF
      noop OF drop false TTRUE MODEL-OPERATION:CREATE-LOCAL-DIRECTORY ENDOF
      blocked OF
         drop false TTRUE MODEL-OPERATION:CREATE-LOCAL-DIRECTORY
      ENDOF
      conflicted OF
         drop false TTRUE MODEL-OPERATION:CREATE-LOCAL-DIRECTORY
      ENDOF
      collided OF
         drop false TTRUE MODEL-OPERATION:CREATE-LOCAL-DIRECTORY
      ENDOF
   ;MATCH ar ONE-PLAN ;

\ Rust's let Decision::NoOp(agreement) = plan(...) else fail.
: AGREEMENT ( MODEL:decision -- MODEL:baseline )
   MATCH MODEL:decision
      noop OF ENDOF
      operate OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
      blocked OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
      conflicted OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
      collided OF drop false TTRUE MODEL-BASELINE:ABSENT ENDOF
   ;MATCH ;

: CONTENT ( str -- DROPBOX:hash ) DROPBOX:>HASH ;

: REMOTE-ABSENT ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:ABSENT ;

\ The planner's plan for a new local file of the content, no remote one
\ and no baseline.
: NEW-FILE-PLAN ( str ^ARENA:arena -- JOURNAL:operation-plan )
   {: c:str ar :}
   MODEL-BASELINE:ABSENT c CONTENT MODEL-LOCAL:MAKE
   MODEL-OBSERVATION:PRESENT REMOTE-ABSENT MODEL-SUBTREE:EMPTY PLANNER:PLAN
   ar OPERATIONS ;

\ The planner's agreement where both sides hold the remote file and no
\ baseline is recorded.
: AGREED ( MODEL:remote -- MODEL:baseline )
   {: rf :}
   rf MODEL-REMOTE:UNMAKE drop {: c :}
   MODEL-BASELINE:ABSENT c MODEL-LOCAL:MAKE MODEL-OBSERVATION:PRESENT
   rf MODEL-OBSERVATION:PRESENT MODEL-SUBTREE:EMPTY PLANNER:PLAN AGREEMENT ;

: RECORDED ( JOURNAL:plan-write -- JOURNAL:plan-record )
   MATCH JOURNAL:plan-write
      recorded OF ENDOF
      already-live OF false TTRUE ENDOF
   ;MATCH ;

: NOOP-RECORDED? ( JOURNAL:noop-write -- bool )
   MATCH JOURNAL:noop-write
      recorded OF true ENDOF
      live-plan OF drop false ENDOF
   ;MATCH ;

: BLOCKED? ( JOURNAL:plan-block -- bool )
   MATCH JOURNAL:plan-block
      not-found OF false ENDOF
      already-completed OF false ENDOF
      blocked OF true ENDOF
   ;MATCH ;

: DISPLAY ( str -- MODEL:path ) MODEL:>PATH ;

: PATH$ ( MODEL:path -- str ) MODEL:PATH>STR ;

\ Rust's derived PartialEq of two birth times, either one absent.
: BIRTH$ ( option<JOURNAL:birth-time> -- n n bool )
   MATCH option
      some OF JOURNAL-BIRTH--TIME:UNMAKE true ENDOF
      none OF 0 0 false ENDOF
   ;MATCH ;

: SUBVOLUME$ ( option<n> -- n bool )
   MATCH option
      some OF true ENDOF
      none OF 0 false ENDOF
   ;MATCH ;

: BINDINGS= ( JOURNAL:local-root-binding JOURNAL:local-root-binding
     -- bool )
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: q i2 b2 s2 :}
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p i1 b1 s1 :}
   b1 BIRTH$ {: bs1:n bn1:n bf1:bool :}
   b2 BIRTH$ {: bs2:n bn2:n bf2:bool :}
   s1 SUBVOLUME$ {: v1:n vf1:bool :}
   s2 SUBVOLUME$ {: v2:n vf2:bool :}
   p q STR:= i1 i2 = and
   bf1 bf2 SAME-BOOL? and bs1 bs2 = and bn1 bn2 = and
   vf1 vf2 SAME-BOOL? and v1 v2 = and ;

: NO-BIRTH ( -- option<JOURNAL:birth-time> ) OPTION:NONE ;
: NO-SUB ( -- option<n> ) OPTION:NONE ;

\ The recorded root's binding and generation, none where there is none.
: RECORD$ ( option<JOURNAL:local-root-record>
     -- JOURNAL:local-root-binding n bool )
   MATCH option
      some OF JOURNAL-LOCAL--ROOT--RECORD:UNMAKE true ENDOF
      none OF s" " 0 NO-BIRTH NO-SUB
         JOURNAL-LOCAL--ROOT--BINDING:MAKE 0 false
      ENDOF
   ;MATCH ;

: RECORDS= ( option<JOURNAL:local-root-record>
     option<JOURNAL:local-root-record> -- bool )
   RECORD$ {: b2 g2:n f2:bool :}
   RECORD$ {: b1 g1:n f1:bool :}
   f1 f2 SAME-BOOL? g1 g2 = and b1 b2 BINDINGS= and ;

\ The status as a number: 0 pending, 1 blocked, 2 completed.
: STATUS# ( JOURNAL:plan-status -- n )
   MATCH JOURNAL:plan-status
      pending OF 0 ENDOF
      blocked OF 2drop 1 ENDOF
      completed OF 2 ENDOF
   ;MATCH ;

\ The plans alike in id, path, operation count and status.
: PLAN= ( JOURNAL:plan-record JOURNAL:plan-record -- bool )
   JOURNAL-PLAN--RECORD:UNMAKE {: j q o2 t :}
   JOURNAL-PLAN--RECORD:UNMAKE {: i p o1 s :}
   i JOURNAL:PLAN-ID>N j JOURNAL:PLAN-ID>N =
   p PATH$ q PATH$ STR:= and
   o1 VEC:COUNT o2 VEC:COUNT = and
   s STATUS# t STATUS# = and ;

: PLANS= ( ^VEC:vector<JOURNAL:plan-record>
     ^VEC:vector<JOURNAL:plan-record> -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ PLAN= 0= if false unloop exit then
   loop true ;

\ The pending plan for path recorded from a new file of the content.
: PENDING ( JOURNAL:journal str str ^ARENA:arena
     -- JOURNAL:plan-record )
   {: j p:str c:str ar :}
   j p DISPLAY c ar NEW-FILE-PLAN ar JOURNAL:RECORD-PLAN RECORDED ;

\ The root stored in the XDG's config.
: STORED-ROOT ( ^CONFIG:xdg ^ARENA:arena -- str ) STORED ;

: SET-ROOT-RETIRES-LIVE-INTENT-AND-PRESERVES-PAYLOADS ( ^ARENA:arena -- )
   {: ar :}
   s" set_root_retires_live_intent_and_preserves_payloads" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   x ar PATHS-OF {: paths :}
   x first ar ACTIVE-JOURNAL {: j :}
   j s" pending.txt" s" pending-content" ar PENDING drop
   j s" blocked.txt" s" blocked-content" ar PENDING {: blocked :}
   j blocked JOURNAL-PLAN--RECORD:UNMAKE drop drop drop
   MODEL-BLOCKAGE:STAGE-OCCUPIED 1700000000 ar JOURNAL:BLOCK-PLAN
   BLOCKED? TTRUE
   j JOURNAL:CLOSE
   paths CONFIG:UPLOAD-STAGING-DIRECTORY CONFIG:ABS-PATH>STR
   s" payload" ar INSIDE {: staged :}
   paths CONFIG:RECOVERY-DIRECTORY CONFIG:ABS-PATH>STR
   s" payload" ar INSIDE {: recovery :}
   staged s" staged" FS:WRITE-ALL
   recovery s" recovery" FS:WRITE-ALL
   d s" active" ar FAKED {: c log :}
   second x c d ar SET {: code:n e:str :}
   code 0 T=
   x ar STORED-ROOT second T$=
   log FILE-TEXT S\" show\nstop\nreset-failed\nstart\n" T$=
   x ar JOURNAL-PATH JOURNAL:OPEN {: k :}
   k ar JOURNAL:PENDING-PLANS VEC:COUNT 0 T=
   k ar JOURNAL:BLOCKED-PLANS VEC:COUNT 0 T=
   k JOURNAL:CLOSE
   staged FILE-TEXT s" staged" T$=
   recovery FILE-TEXT s" recovery" T$=
   d FS:REMOVE-TREE ;

\ set-root to DIR/second from a unit in the state succeeds, the root
\ stored and the service log the verbs w.
: SETS-ROOT ( str str ^ARENA:arena -- )
   {: s:str w:str ar :}
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   d s ar FAKED {: c log :}
   second x c d ar SET {: code:n e:str :}
   code 0 T=
   x ar STORED-ROOT second T$=
   log FILE-TEXT w T$=
   d FS:REMOVE-TREE ;

: SET-ROOT-STARTS-A-FAILED-SERVICE-AFTER-THE-CHANGE ( ^ARENA:arena -- )
   {: ar :}
   s" set_root_starts_a_failed_service_after_the_change" T-LABEL
   s" failed" S\" show\nshow\nreset-failed\nstart\n" ar SETS-ROOT ;

: SET-ROOT-RESTARTS-A-STARTING-SERVICE ( ^ARENA:arena -- )
   {: ar :}
   s" set_root_restarts_a_starting_service" T-LABEL
   s" activating" S\" show\nstop\nreset-failed\nstart\n" ar SETS-ROOT ;

: SET-ROOT-WAITS-OUT-A-STOPPING-SERVICE ( ^ARENA:arena -- )
   {: ar :}
   s" set_root_waits_out_a_stopping_service" T-LABEL
   s" deactivating" S\" show\nstop\nshow\nstop\nshow\n" ar SETS-ROOT ;

\ Rust's failing_start in DIR: show answers the state, start exits 1.
: FAILING-START ( str str ^ARENA:arena -- ^SERVICE:commands )
   {: d s:str ar :}
   d s" systemctl" ar INSIDE {: sys :}
   SB-RESET S\" printf '%s\\n' \"$2\" >> " SB-APPEND
   d s" service.log" ar INSIDE QUOTED+
   S\" \ncase \"$2\" in\n  show) printf '%s\\n' " SB-APPEND s SB-APPEND
   S\"  ;;\n  start) exit 1 ;;\nesac\nexit 0\n" SB-APPEND
   sys SB$ FS:WRITE-ALL
   sys s" /unused/journalctl" ar SERVICE:SCRIPTS ;

\ set-root from a unit in the state whose start fails: the change is
\ kept and reported as E-START-AFTER-CHANGE.
: SET-ROOT-START-FAILS ( str ^ARENA:arena -- )
   {: s:str ar :}
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   d s ar FAILING-START {: c :}
   second x c d ar SET {: code:n e:str :}
   code E-START-AFTER-CHANGE T=
   x ar STORED-ROOT second T$=
   d FS:REMOVE-TREE ;

: SET-ROOT-REQUIRES-THE-DAEMON-LOCK-BEFORE-WRITING-CONFIG
   ( ^ARENA:arena -- )
   {: ar :}
   s" set_root_requires_the_daemon_lock_before_writing_config" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   x ar PATHS-OF {: paths :}
   paths ar CONFIG:CONFIG-FILE CONFIG:ABS-PATH>STR {: file :}
   file FILE-TEXT ar ARENA:COPY {: original :}
   paths CONFIG:LOCK {: held :}
   d s" inactive" ar FAKED {: c log :}
   second x c d ar SET {: code:n e:str :}
   held CONFIG:UNLOCK
   code E-LOCK T=
   e s" help: Stop any manually started Omabox daemon, then retry."
   ENDS-LOGGED? TTRUE
   file FILE-TEXT original T$=
   log FILE-TEXT S\" show\n" T$=
   d FS:REMOVE-TREE ;

\ A systemctl whose stop replaces the config directory with a file
\ and whose start exits with start: the commands and the service log.
: CONFIG-BREAKING ( str ^CONFIG:paths n ^ARENA:arena
     -- ^SERVICE:commands str )
   {: d paths start:n ar :}
   paths CONFIG:CONFIG-DIRECTORY CONFIG:ABS-PATH>STR {: cd :}
   d s" saved-config" ar INSIDE {: saved :}
   d s" service.log" ar INSIDE {: log :}
   d s" systemctl-write-failure" ar INSIDE {: sys :}
   SB-RESET S\" printf '%s\\n' \"$2\" >> " SB-APPEND log QUOTED+
   S\" \nif [ \"$2\" = show ]; then printf '%s\\n' active; fi\n" SB-APPEND
   S\" if [ \"$2\" = stop ]; then mv " SB-APPEND cd QUOTED+ s"  " SB-APPEND
   saved QUOTED+ s" ; : > " SB-APPEND cd QUOTED+ S\" ; fi\n" SB-APPEND
   S\" if [ \"$2\" = start ]; then exit " SB-APPEND start CODE+
   S\" ; fi\nexit 0\n" SB-APPEND
   sys SB$ FS:WRITE-ALL
   sys s" /unused/journalctl" ar SERVICE:SCRIPTS log ;

\ The config directory DIR/saved-config put back in place.
: CONFIG-RESTORED ( str ^CONFIG:paths ^ARENA:arena -- )
   {: d paths ar :}
   paths CONFIG:CONFIG-DIRECTORY CONFIG:ABS-PATH>STR {: cd :}
   cd FS:REMOVE-FILE
   d s" saved-config" ar INSIDE cd FS:RENAME-FILE ;

: CONFIG-WRITE-FAILURE-PRESERVES-ROOT-GENERATION-AND-LIVE-INTENT
   ( ^ARENA:arena -- )
   {: ar :}
   s" config_write_failure_preserves_root_generation_and_live_intent"
   T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   x ar PATHS-OF {: paths :}
   x first ar ACTIVE-JOURNAL {: j :}
   j s" pending.txt" s" pending-content" ar PENDING drop
   j ar JOURNAL:LOCAL-ROOT-BINDING {: binding :}
   j ar JOURNAL:PENDING-PLANS {: pending :}
   j JOURNAL:CLOSE
   d paths 0 ar CONFIG-BREAKING {: c log :}
   second x c d ar SET {: code:n e:str :}
   code CONFIG-CODE? TTRUE
   e s" could not write the new sync root" ENDS-LOGGED? TTRUE
   log FILE-TEXT S\" show\nstop\nreset-failed\nstart\n" T$=
   d paths ar CONFIG-RESTORED
   x ar STORED-ROOT first T$=
   x ar JOURNAL-PATH JOURNAL:OPEN {: k :}
   k ar JOURNAL:LOCAL-ROOT-BINDING binding RECORDS= TTRUE
   k ar JOURNAL:PENDING-PLANS pending PLANS= TTRUE
   k JOURNAL:CLOSE
   d FS:REMOVE-TREE ;

: A-FAILED-CHANGE-AND-RESTART-REPORT-BOTH ( ^ARENA:arena -- )
   {: ar :}
   s" a_failed_change_and_restart_report_both" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   x ar PATHS-OF {: paths :}
   d paths 1 ar CONFIG-BREAKING {: c log :}
   second x c d ar SET {: code:n e:str :}
   code E-CHANGE-AND-RESTORE T=
   d paths ar CONFIG-RESTORED
   x ar STORED-ROOT first T$=
   d FS:REMOVE-TREE ;

: REMOTE ( str str -- MODEL:remote )
   {: c:str r:str :}
   c CONTENT r DROPBOX:>REV MODEL-REMOTE:MAKE ;

\ The noop for path, where both sides hold the remote file, recorded.
: AGREEMENT-RECORDED ( JOURNAL:journal str MODEL:remote ^ARENA:arena -- )
   {: j p:str rf ar :}
   j p DISPLAY rf AGREED ar JOURNAL:RECORD-NOOP NOOP-RECORDED? TTRUE ;

\ The remote inventory: remote.txt present as the file, at remote-cursor.
: INVENTORY-PUBLISHED ( JOURNAL:journal MODEL:remote ^ARENA:arena -- )
   {: j rf ar :}
   s" remote.txt" DISPLAY {: rp :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: v :}
   rp ar MODEL:FOLD rp rf MODEL-OBSERVATION:PRESENT
   MODEL-REMOTE--RECORD:MAKE v VEC:PUSH !
   j s" remote-cursor" DROPBOX:>CURSOR v
   JOURNAL:UPSERT-REMOTE-RECORDS ;

: CURSOR-IS? ( option<DROPBOX:cursor> str -- bool )
   {: a:str :}
   MATCH option
      none OF false ENDOF
      some OF DROPBOX:CURSOR>STR a STR:= ENDOF
   ;MATCH ;

: SET-ROOT-WORKS-WHEN-THE-PRIOR-ROOT-IS-UNAVAILABLE ( ^ARENA:arena -- )
   {: ar :}
   s" set_root_works_when_the_prior_root_is_unavailable" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   x first ar ACTIVE-JOURNAL {: j :}
   s" remote-content" s" remote-revision" REMOTE {: rf :}
   j rf ar INVENTORY-PUBLISHED
   j s" remote.txt" rf ar AGREEMENT-RECORDED
   j ar JOURNAL:BASELINE-PATHS {: paths :}
   paths VEC:COUNT 1 T=
   paths 0 VEC:AT @ PATH$ s" remote.txt" T$=
   j JOURNAL:CLOSE
   first d s" unavailable-first" ar INSIDE FS:RENAME-FILE
   d s" inactive" ar FAKED {: c log :}
   second x c d ar SET {: code:n e:str :}
   code 0 T=
   x ar STORED-ROOT second T$=
   log FILE-TEXT S\" show\nshow\n" T$=
   x ar JOURNAL-PATH JOURNAL:OPEN {: k :}
   k ar JOURNAL:BASELINE-PATHS VEC:COUNT 0 T=
   k ar JOURNAL:REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE
   {: cur v :}
   cur s" remote-cursor" CURSOR-IS? TTRUE
   k JOURNAL:CLOSE
   d FS:REMOVE-TREE ;

: CURRENT? ( JOURNAL:local-root-activation -- bool )
   MATCH JOURNAL:local-root-activation
      activated OF drop false ENDOF
      current OF drop true ENDOF
      unavailable OF drop drop false ENDOF
   ;MATCH ;

: SET-ROOT-EXPLICITLY-ADOPTS-A-REPLACEMENT-AT-THE-SAME-PATH
   ( ^ARENA:arena -- )
   {: ar :}
   s" set_root_explicitly_adopts_a_replacement_at_the_same_path" T-LABEL
   ar FIXTURE {: d x first :}
   first JOURNAL:INSPECT {: recorded :}
   x ar JOURNAL-PATH JOURNAL:OPEN {: j :}
   j recorded ar JOURNAL:ACTIVATE-LOCAL-ROOT drop
   s" same-content" s" same-revision" REMOTE {: rf :}
   j s" tracked.txt" rf ar AGREEMENT-RECORDED
   j JOURNAL:CLOSE
   first d s" moved-first" ar INSIDE FS:RENAME-FILE
   first FS:MAKE-DIR
   first JOURNAL:INSPECT {: actual :}
   recorded actual BINDINGS= TFALSE
   d s" inactive" ar FAKED {: c log :}
   first x c d ar SET {: code:n e:str :}
   code 0 T=
   x ar JOURNAL-PATH JOURNAL:OPEN {: k :}
   k ar JOURNAL:LOCAL-ROOT-BINDING RECORD$ {: b g:n f:bool :}
   f TTRUE
   b actual BINDINGS= TTRUE
   g 2 T=
   k ar JOURNAL:BASELINE-PATHS VEC:COUNT 0 T=
   k actual ar JOURNAL:ACTIVATE-LOCAL-ROOT CURRENT? TTRUE
   k JOURNAL:CLOSE
   log FILE-TEXT S\" show\nshow\n" T$=
   d FS:REMOVE-TREE ;


\ ---- setup with the service released

\ A recording store, bound before any SECRET call: no case reaches the
\ keyring. REC holds the last record written.
CAP BUFFER: REC
variable REC-U
variable REC-WRITES

: REC-READ ( str str ^VEC:vector<u8> -- bool )
   {: s:str a:str dest:^VEC:vector<u8> :}
   false ;

: REC-WRITE ( str str str -- )
   {: s:str a:str vs:str :}
   vs str> {: v:^ vu:n :}
   vu CAP min {: k:n :}
   v REC k BYTE-COPY k REC-U !
   1 REC-WRITES +! ;

: REC-ERASE ( str str -- bool ) {: s:str a:str :} false ;

' REC-READ ' REC-WRITE ' REC-ERASE SECRET:STORE!

\ A login for /Sync of the account, holding the token bind-refresh,
\ for the Secret Service.
: LOGIN ( str ^ARENA:arena -- ^authorized )
   {: ac:str ar :}
   ar LOGINS-NEW {: a :}
   ac s" namespace" s" /Sync"
   JOURNAL-DROPBOX--BINDING:MAKE a AUTHORIZED-BINDING !
   s" bind-refresh" a AUTHORIZED-REFRESH-TOKEN !
   NO-STR a AUTHORIZED-CREDENTIAL-FILE !
   a ;

\ Setup's change of c, writing no config, released from s: the account's
\ login bound, its code and the log captured in p.
: SETUP-RUN ( ^SERVICE:commands ^CONFIG:config str ^ARENA:arena
     -- n str )
   {: s c p ar :}
   s" account" ar LOGIN {: a :}
   [: s c false a CHANGE-SETUP s" setup" s" Omabox setup is complete" ar
      RELEASED ;]
   p ar STDERR:CAPTURING ;

\ Rust's fixture's config, loaded, and the log file in its directory.
: LOADED-FIXTURE ( ^ARENA:arena -- str ^CONFIG:config str )
   {: ar :}
   ar FIXTURE {: d x first :}
   x ar CONFIG:LOAD-FROM {: c :}
   d c d s" stderr.txt" ar INSIDE ;

: SETUP-REPORTS-A-HELD-LOCK-AND-RESTORES-THE-SERVICE ( ^ARENA:arena -- )
   {: ar :}
   s" setup_reports_a_held_lock_and_restores_the_service" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   c CONFIG:PATHS CONFIG:LOCK {: held :}
   s" active" 0 0 ar STATEFUL {: sd s :}
   s c p ar SETUP-RUN {: code:n e:str :}
   held CONFIG:UNLOCK
   code E-LOCK T=
   sd ar TRACE {: log state :}
   log S\" show\nstop\nreset-failed\nstart\n" T$=
   state S\" active\n" T$=
   sd FS:REMOVE-TREE
   d FS:REMOVE-TREE ;

\ The offset past the line t in the log from at, -1 where it is not
\ there or at is.
: PAST ( str n str -- n )
   {: a:str at:n t:str :}
   at 0 < if -1 exit then
   a t at STR:FIND-SUB-FROM MATCH option
      none OF -1 ENDOF
      some OF IDX>N t str> nip + ENDOF
   ;MATCH ;

: LOGGED-AFTER ( str n str -- str n )
   {: a:str at:n t:str :}
   a a at t PAST ;

\ The lines of the failed change, then the failed restore's, then the
\ error that names both, in the order they print.
: RENDERED-BOTH ( str -- )
   0 S\" omabox: could not acquire the Omabox daemon lock\n" LOGGED-AFTER
   S\" omabox: help: Stop any manually started Omabox daemon, then retry.\n"
   LOGGED-AFTER
   S\" service: `systemctl` failed with status Some(1)\n" LOGGED-AFTER
   S\" service: help: Review the command output and `omabox logs`, then retry.\n"
   LOGGED-AFTER
   S\" omabox: setup failed, and the Omabox service could not be restarted; run `omabox resume` once the errors above are fixed\n"
   LOGGED-AFTER
   0 >= TTRUE drop ;

: A-FAILED-CHANGE-AND-RESTORE-RENDER-BOTH ( ^ARENA:arena -- )
   {: ar :}
   s" a_failed_change_and_restore_render_both" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   c CONFIG:PATHS CONFIG:LOCK {: held :}
   s" active" 1 0 ar STATEFUL {: sd s :}
   s c p ar SETUP-RUN {: code:n e:str :}
   held CONFIG:UNLOCK
   code E-CHANGE-AND-RESTORE T=
   e RENDERED-BOTH
   sd FS:REMOVE-TREE
   d FS:REMOVE-TREE ;

\ A systemctl in d that logs each verb to d/service.log, then runs the
\ case arms.
: CASED ( str str ^ARENA:arena -- ^SERVICE:commands )
   {: d arms:str ar :}
   d s" systemctl" ar INSIDE {: sys :}
   d s" service.log" ar INSIDE {: log :}
   SB-RESET S\" printf '%s\\n' \"$2\" >> " SB-APPEND log QUOTED+
   S\" \ncase \"$2\" in\n" SB-APPEND arms SB-APPEND
   S\" esac\nexit 0\n" SB-APPEND
   sys SB$ FS:WRITE-ALL
   sys s" /unused/journalctl" ar SERVICE:SCRIPTS ;

\ Rust's arms: show answers failed, start takes the lock file l.
: FLOCK-ARMS ( str ^ARENA:arena -- str )
   {: l ar :}
   SB-RESET S\"   show) printf '%s\\n' failed ;;\n" SB-APPEND
   s"   start) exec flock -n " SB-APPEND l QUOTED+
   S\"  true ;;\n" SB-APPEND SB$ ar ARENA:COPY ;

: SETUP-RELEASES-THE-LOCK-BEFORE-STARTING-A-FAILED-SERVICE
   ( ^ARENA:arena -- )
   {: ar :}
   s" setup_releases_the_lock_before_starting_a_failed_service" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   c CONFIG:PATHS CONFIG:LOCK-FILE CONFIG:ABS-PATH>STR {: l :}
   d l ar FLOCK-ARMS ar CASED {: s :}
   s c p ar SETUP-RUN {: code:n e:str :}
   code 0 T=
   d s" service.log" ar INSIDE FILE-TEXT
   S\" show\nshow\nreset-failed\nstart\n" T$=
   d FS:REMOVE-TREE ;

: A-COMPLETED-CHANGE-REPORTS-A-FAILED-START ( ^ARENA:arena -- )
   {: ar :}
   s" a_completed_change_reports_a_failed_start" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   d s" failed" ar FAILING-START {: s :}
   s c p ar SETUP-RUN {: code:n e:str :}
   code E-START-AFTER-CHANGE T=
   d FS:REMOVE-TREE
   s" failed" ar SET-ROOT-START-FAILS
   s" active" ar SET-ROOT-START-FAILS ;


\ ---- an unexpected code

\ The log UNEXPECTED of the code wrote, captured in DIR/stderr.txt.
: UNEXPECTED-LOG ( n str ^ARENA:arena -- str )
   {: code:n d ar :}
   d s" stderr.txt" ar INSIDE {: p :}
   [: code UNEXPECTED ;] p ar STDERR:CAPTURING
   {: rc:n e:str :}
   rc 0 T=
   e ;

\ "the command failed unexpectedly (", LOG:CODE+ of E-FS-IO, ")".
: UNEXPECTED-LINE ( ^ARENA:arena -- str )
   {: ar :}
   s" the command failed unexpectedly (" ar ARENA:COPY
   E-FS-IO FMT:INT$ ar FOLLOWED s"  E-FS-IO: " ar FOLLOWED
   E-FS-IO ERROR:TEXT$ ar FOLLOWED s" )" ar FOLLOWED ;

: AN-UNEXPECTED-CODE-IS-LOGGED ( ^ARENA:arena -- )
   {: ar :}
   s" an_unexpected_code_is_logged" T-LABEL
   ar TEMPORARY {: d :}
   E-FS-IO d ar UNEXPECTED-LOG {: e:str :}
   e LINES 1 T=
   e ar UNEXPECTED-LINE LOGGED? TTRUE
   E-USAGE d ar UNEXPECTED-LOG str> nip 0 T=
   d FS:REMOVE-TREE ;


\ ---- setup's login and bind

: JOURNAL-OF ( ^CONFIG:config -- str )
   CONFIG:PATHS CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR ;

\ The config c's journal bound to b before setup.
: PREBOUND ( ^CONFIG:config JOURNAL:dropbox-binding ^ARENA:arena -- )
   {: c b ar :}
   c JOURNAL-OF JOURNAL:OPEN {: j :}
   j b ar JOURNAL:BIND-DROPBOX-ROOT BOUND? TTRUE
   j JOURNAL:CLOSE ;

\ Whether the config c's journal is bound to b.
: BOUND-TO? ( ^CONFIG:config JOURNAL:dropbox-binding ^ARENA:arena
     -- bool )
   {: c b ar :}
   c JOURNAL-OF JOURNAL:OPEN {: j :}
   j ar JOURNAL:DROPBOX-BINDING MATCH option
      none OF false ENDOF
      some OF b JOURNAL:BINDING= ENDOF
   ;MATCH
   j JOURNAL:CLOSE ;

\ BIND of the login a for the config c: its code and the log, captured
\ in p; REC-WRITES counts its store writes.
: BIND-RUN ( ^CONFIG:config ^authorized str ^ARENA:arena -- n str )
   {: c a p ar :}
   0 REC-WRITES ! 0 REC-U !
   [: c a ar BIND ;] p ar STDERR:CAPTURING ;

: BIND-STORES-THE-TOKEN-AND-BINDS-AN-UNBOUND-JOURNAL ( ^ARENA:arena -- )
   {: ar :}
   s" bind_stores_the_token_and_binds_an_unbound_journal" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   s" account" ar LOGIN {: a :}
   c a p ar BIND-RUN {: code:n e:str :}
   code 0 T=
   REC-WRITES @ 1 T=
   REC REC-U @ >str s" bind-refresh" STR:CONTAINS? TTRUE
   c a AUTHORIZED-BINDING @ ar BOUND-TO? TTRUE
   d FS:REMOVE-TREE ;

: BIND-STORES-THE-TOKEN-FOR-A-JOURNAL-BOUND-TO-THE-LOGIN
   ( ^ARENA:arena -- )
   {: ar :}
   s" bind_stores_the_token_for_a_journal_bound_to_the_login" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   s" account" ar LOGIN {: a :}
   c a AUTHORIZED-BINDING @ ar PREBOUND
   c a p ar BIND-RUN {: code:n e:str :}
   code 0 T=
   REC-WRITES @ 1 T=
   REC REC-U @ >str s" bind-refresh" STR:CONTAINS? TTRUE
   c a AUTHORIZED-BINDING @ ar BOUND-TO? TTRUE
   d FS:REMOVE-TREE ;

: BIND-REFUSES-A-JOURNAL-BOUND-ELSEWHERE ( ^ARENA:arena -- )
   {: ar :}
   s" bind_refuses_a_journal_bound_elsewhere" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   s" other-account" ar LOGIN AUTHORIZED-BINDING @ {: other :}
   c other ar PREBOUND
   s" account" ar LOGIN {: a :}
   c a p ar BIND-RUN {: code:n e:str :}
   code E-BINDING-MISMATCH T=
   e s" omabox: this Omabox journal is already bound to a different"
   STR:CONTAINS? TTRUE
   REC-WRITES @ 0 T=
   c other ar BOUND-TO? TTRUE
   d FS:REMOVE-TREE ;

\ The record LOGIN's binding and token make.
: LOGIN-RECORD ( -- str )
   s\" {\"version\":1,\"refresh_token\":\"bind-refresh\",\"account_id\":\"account\",\"root_namespace_id\":\"namespace\",\"remote_root\":\"/Sync\"}" ;

: BIND-WRITES-THE-TOKEN-TO-A-NEW-CREDENTIAL-FILE ( ^ARENA:arena -- )
   {: ar :}
   s" bind_writes_the_token_to_a_new_credential_file" T-LABEL
   ar LOADED-FIXTURE {: d c p :}
   d s" credential" ar INSIDE {: f :}
   s" account" ar LOGIN {: a :}
   f OPTION:SOME a AUTHORIZED-CREDENTIAL-FILE !
   c a p ar BIND-RUN {: code:n e:str :}
   code 0 T=
   REC-WRITES @ 0 T=
   f FILE-TEXT LOGIN-RECORD T$=
   c a AUTHORIZED-BINDING @ ar BOUND-TO? TTRUE
   d FS:REMOVE-TREE ;

\ The code and log of xt, captured in a file under TMPDIR.
: LOGGED ( [ -- ] ^ARENA:arena -- n str )
   {: xt ar :}
   ar TEMPORARY {: d :}
   xt d s" stderr.txt" ar INSIDE ar STDERR:CAPTURING
   d FS:REMOVE-TREE ;

\ A client on the fake with no token and no root, as setup's is.
: TOKENLESS ( ^ARENA:arena -- ^DROPBOX:client )
   {: ar :}
   [: KEEP-NONE ;] s" " s" " ar TEST-CLIENT:CLIENT-ON ;

\ A login and a client for the code the fake grants it, if any.
: EXCHANGING ( bool ^ARENA:arena -- ^AUTH:pending ^DROPBOX:client )
   {: granted:bool ar :}
   TEST-DROPBOX:RESET
   s" fake-key" ar AUTH:START {: pd :}
   granted if s" fake-code" pd AUTH:VERIFIER TEST-DROPBOX:GRANT! then
   pd ar TOKENLESS ;

: EXCHANGED-PASSES-A-TOKEN-DROPBOX-ISSUES ( ^ARENA:arena -- )
   {: ar :}
   s" exchanged_passes_a_token_dropbox_issues" T-LABEL
   true ar EXCHANGING {: pd cl :}
   [: s" fake-code" pd cl EXCHANGED ;] ar LOGGED
   {: code:n e:str :}
   code 0 T=
   cl DROPBOX:REFRESH-TOKEN s" fake-refresh-granted" T$=
   cl DROPBOX:CLOSE ;

: EXCHANGED-REFUSES-A-TOKEN-DROPBOX-DOES-NOT-ISSUE ( ^ARENA:arena -- )
   {: ar :}
   s" exchanged_refuses_a_token_dropbox_does_not_issue" T-LABEL
   false ar EXCHANGING {: pd cl :}
   [: s" fake-code" pd cl EXCHANGED ;] ar LOGGED
   {: code:n e:str :}
   code E-AUTH T=
   e S\" omabox: Dropbox OAuth could not issue an access token\n"
   STR:CONTAINS? TTRUE
   cl DROPBOX:CLOSE ;

\ LINKED of /Sync on a client holding its first access token, nothing
\ seen yet, after xt scripts the fake: the code and the log.
: LINK-RUN ( [ -- ] ^ARENA:arena -- n str )
   {: xt ar :}
   TEST-DROPBOX:RESET ar TEST-CLIENT:TOKENED {: cl :}
   TEST-DROPBOX:RESET xt execute
   [: s" /Sync" cl ar LINKED ;] ar LOGGED
   cl DROPBOX:CLOSE ;

: VALIDATE-LOGGED? ( str -- bool )
   S\" omabox: could not validate the Dropbox account and root\n"
   STR:CONTAINS? ;

: LINKED-REFUSES-AN-UNAVAILABLE-ACCOUNT ( ^ARENA:arena -- )
   {: ar :}
   s" linked_refuses_an_unavailable_account" T-LABEL
   [: s" /2/users/get_current_account" 503 s" " s" " s" "
      TEST-DROPBOX:ROUTE-SCRIPT! ;] ar LINK-RUN {: code:n e:str :}
   code E-DROPBOX T=
   e VALIDATE-LOGGED? TTRUE ;

\ Rust's file_metadata for /Sync, empty.
: ROOT-FILE$ ( -- str )
   SB-RESET S\" {\q.tag\q:\qfile\q" SB-APPEND TEST-CLIENT:SYNC-PATHS+
   S\" ,\qrev\q:\qroot-file-revision\q,\qsize\q:0" SB-APPEND
   S\" ,\qcontent_hash\q:\qe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\q"
   SB-APPEND S\" ,\qis_downloadable\q:true}" SB-APPEND SB$ ;

: LINKED-REFUSES-A-ROOT-NOT-A-FOLDER ( ^ARENA:arena -- )
   {: ar :}
   s" linked_refuses_a_root_not_a_folder" T-LABEL
   [: s" /2/files/get_metadata" 200 s" " s" " ROOT-FILE$
      TEST-DROPBOX:ROUTE-SCRIPT! ;] ar LINK-RUN {: code:n e:str :}
   code E-DROPBOX T=
   e S\" omabox: configured Dropbox root is not a folder\n" STR:CONTAINS?
   TTRUE
   e VALIDATE-LOGGED? TTRUE ;

: LINKED-REFUSES-AN-ACCOUNT-OF-ANOTHER-ROOT-TAG ( ^ARENA:arena -- )
   {: ar :}
   s" linked_refuses_an_account_of_another_root_tag" T-LABEL
   [: s" /2/users/get_current_account" 200 s" " s" "
      S\" {\qaccount_id\q:\qdbid:account\q,\qroot_info\q:{\qroot_namespace_id\q:\qnamespace\q,\q.tag\q:\qother\q}}"
      TEST-DROPBOX:ROUTE-SCRIPT! ;] ar LINK-RUN {: code:n e:str :}
   code E-ACCOUNT-CHANGED T=
   e s" omabox: Dropbox authorization returned a different account"
   STR:CONTAINS? TTRUE ;

\ The cases against the fake, under DROPBOX's loops; linking starts
\ at the account's home, so the fake expects no Path-Root.
: SERVED ( ^ARENA:arena -- )
   {: ar :}
   s" fake-key" s" live-token" TEST-DROPBOX:ACCEPT!
   s" " TEST-DROPBOX:ROOT!
   [: TEST-DROPBOX:START
      [: ar EXCHANGED-PASSES-A-TOKEN-DROPBOX-ISSUES
         ar EXCHANGED-REFUSES-A-TOKEN-DROPBOX-DOES-NOT-ISSUE
         ar LINKED-REFUSES-AN-UNAVAILABLE-ACCOUNT
         ar LINKED-REFUSES-A-ROOT-NOT-A-FOLDER
         ar LINKED-REFUSES-AN-ACCOUNT-OF-ANOTHER-ROOT-TAG ;]
      [: TEST-DROPBOX:STOP ;] finally ;] DROPBOX:WITH-LOOP ;

\ BIND's three arms, its credential file, setup's refusal of a taken
\ one, then the login's steps against the fake.
: LOGIN-CASES ( ^ARENA:arena -- )
   {: ar :}
   ar BIND-STORES-THE-TOKEN-AND-BINDS-AN-UNBOUND-JOURNAL
   ar BIND-STORES-THE-TOKEN-FOR-A-JOURNAL-BOUND-TO-THE-LOGIN
   ar BIND-REFUSES-A-JOURNAL-BOUND-ELSEWHERE
   ar BIND-WRITES-THE-TOKEN-TO-A-NEW-CREDENTIAL-FILE
   ar SERVED ;


\ ---- the built program

: BUILD-ARGS ( str -- )
   {: bin :}
   PROC-ARGV-ENV-RESET
   s" --load" PROC-ARGV+
   SOURCE-ROOT:ENGINE$ s" tools/hb-build.f" JOINED FS:JOIN-PATH
   {: n:n :} JOINED n >str PROC-ARGV+
   s" --" PROC-ARGV+
   s" src/omabox.f" PROC-ARGV+
   s" -o" PROC-ARGV+
   bin PROC-ARGV+
   PROC-ENV-INHERIT-MISSING ;

\ README's command, with this engine's hb and tree, writes bin.
: BUILT? ( str -- bool )
   {: bin :}
   s" hb-build builds omabox" T-LABEL
   bin BUILD-ARGS
   ENGINE-CANDIDATE:PATH$ OUT CAP >LEN ERR CAP >LEN
   BUILD-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   PROCESS:ENDING>RC RC>N {: outu:len erru:len rc:n :}
   rc 0<> if ERR erru LEN>N >str type then
   rc 0 T=
   rc 0= ;

: VERSION-PRINTED ( str -- )
   {: bin :}
   s" the built omabox prints its version" T-LABEL
   PROC-ARGV-ENV-RESET
   s" --version" PROC-ARGV+
   bin OUT CAP >LEN ERR CAP >LEN
   RUN-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   PROCESS:ENDING>RC RC>N {: outu:len erru:len rc:n :}
   rc 0 T=
   OUT outu LEN>N >str S\" omabox 0.2.0\n" T$=
   erru LEN>N 0 T= ;

\ A shell line that sends the signal sig, as kill names it, to the CLI
\ that ran the script when the verb is v; none for an empty v.
: KILLING ( str str ^ARENA:arena -- str )
   {: sig:str v:str ar :}
   v STR:LEN 0= if s" " exit then
   SB-RESET S\" [ \"$2\" != " SB-APPEND v SB-APPEND s"  ] || kill -" SB-APPEND
   sig SB-APPEND S\"  \"$PPID\"\n" SB-APPEND SB$ ar ARENA:COPY ;

\ A stateful systemctl in d/bin, the unit first in the state i: its verb v
\ sends sig, as kill names it, to the CLI, and its start exits with start.
\ An empty v sends no signal.
: INTERRUPTING ( str str str str n ^ARENA:arena -- str )
   {: d i:str sig:str v:str start:n ar :}
   d s" bin" ar INSIDE {: b :}
   b FS:MAKE-DIR
   b s" systemctl" ar INSIDE {: sys :}
   d s" unit-state" ar INSIDE {: state :}
   d s" service.log" ar INSIDE {: log :}
   SB-RESET i LINE+ state SB$ FS:WRITE-ALL
   sig v ar KILLING {: w :}
   SB-RESET S\" #!/bin/sh\n" SB-APPEND state log start 0 w SCRIPT+
   sys SB$ FS:WRITE-ALL
   sys FS:CHMOD-X
   b ;

\ The signal that ended a process; -1 for one that exited or ran out
\ its time.
: KILLED-BY ( PROCESS:ending -- n )
   MATCH PROCESS:ending
      exited OF drop -1 ENDOF
      signaled OF ENDOF
      timeout OF -1 ENDOF
   ;MATCH ;

\ The built program's set-root of second over the fixture in d, its
\ systemctl from INTERRUPTING: stdout's and stderr's lengths in OUT and
\ ERR, and the signal that ended it.
: SET-ROOT-KILLED ( str str str str str str n ^ARENA:arena -- len len n )
   {: bin d second i:str sig:str v:str start:n ar :}
   d i sig v start ar INTERRUPTING {: b :}
   PROC-ARGV-ENV-RESET
   s" --default-signal=HUP,INT,TERM" PROC-ARGV+ bin PROC-ARGV+
   s" settings" PROC-ARGV+ s" set-root" PROC-ARGV+ second PROC-ARGV+
   SB-RESET b SB-APPEND s" :/usr/bin:/bin" SB-APPEND s" PATH" SB$ PROC-ENV+
   s" HOME" d PROC-ENV+
   s" XDG_CONFIG_HOME" d s" config" ar INSIDE PROC-ENV+
   s" XDG_STATE_HOME" d s" state" ar INSIDE PROC-ENV+
   s" /usr/bin/env" OUT CAP >LEN ERR CAP >LEN
   RUN-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   KILLED-BY ;

\ The built program's set-root, its systemctl sending sig from the verb
\ v before the change: the change skipped, the unit active again, death
\ by the signal.
: INTERRUPTED ( str str str n ^ARENA:arena -- )
   {: bin sig:str v:str want:n ar :}
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   bin d second s" active" sig v 0 ar SET-ROOT-KILLED
   {: outu:len erru:len got:n :}
   outu LEN>N 0 T=
   got want T=
   d s" service.log" ar INSIDE FILE-TEXT
   S\" show\nstop\nreset-failed\nstart\n" T$=
   d s" unit-state" ar INSIDE FILE-TEXT S\" active\n" T$=
   x ar STORED-ROOT first T$=
   d FS:REMOVE-TREE ;

: SET-ROOT-INTERRUPTED-BY-SIGINT-RESTORES-THE-SERVICE
   ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_interrupted_by_sigint_restores_the_service" T-LABEL
   bin s" INT" s" stop" 2 ar INTERRUPTED ;

: SET-ROOT-INTERRUPTED-BY-SIGTERM-RESTORES-THE-SERVICE
   ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_interrupted_by_sigterm_restores_the_service" T-LABEL
   bin s" TERM" s" stop" 15 ar INTERRUPTED ;

: SET-ROOT-INTERRUPTED-BY-SIGHUP-RESTORES-THE-SERVICE
   ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_interrupted_by_sighup_restores_the_service" T-LABEL
   bin s" HUP" s" stop" 1 ar INTERRUPTED ;

: SET-ROOT-KILLED-DURING-RESTART-KEEPS-THE-CHANGE ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_killed_during_restart_keeps_the_change" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   bin d second s" active" s" TERM" s" start" 0 ar SET-ROOT-KILLED
   {: outu:len erru:len got:n :}
   ERR erru LEN>N >str s" The change is kept" STR:CONTAINS? TFALSE
   outu LEN>N 0 T=
   got 15 T=
   d s" unit-state" ar INSIDE FILE-TEXT S\" active\n" T$=
   x ar STORED-ROOT second T$=
   d FS:REMOVE-TREE ;

: SET-ROOT-KILLED-WITH-A-FAILED-RESTART-KEEPS-THE-CHANGE
   ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_killed_with_a_failed_restart_keeps_the_change" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   bin d second s" active" s" TERM" s" start" 1 ar SET-ROOT-KILLED
   {: outu:len erru:len got:n :}
   ERR erru LEN>N >str {: e :}
   e s" The change is kept" STR:CONTAINS? TTRUE
   e s" could not be restarted" STR:CONTAINS? TFALSE
   got 15 T=
   x ar STORED-ROOT second T$=
   d FS:REMOVE-TREE ;

: SET-ROOT-INTERRUPTED-WITHOUT-RESTART-TELLS-THE-CHANGE-FAILED
   ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_interrupted_without_restart_tells_the_change_failed" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   bin d second s" active" s" INT" s" stop" 1 ar SET-ROOT-KILLED
   {: outu:len erru:len got:n :}
   ERR erru LEN>N >str {: e :}
   e s" could not be restarted" STR:CONTAINS? TTRUE
   e s" The change is kept" STR:CONTAINS? TFALSE
   got 2 T=
   x ar STORED-ROOT first T$=
   d FS:REMOVE-TREE ;

\ The unit starts failed, so only the recover drive runs reset-failed;
\ its SIGTERM waits until that drive has started the unit.
: SET-ROOT-INTERRUPTED-DURING-RECOVERY-FINISHES-IT ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_interrupted_during_recovery_finishes_it" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   bin d second s" failed" s" TERM" s" reset-failed" 0 ar
   SET-ROOT-KILLED {: outu:len erru:len got:n :}
   d s" service.log" ar INSIDE FILE-TEXT
   S\" show\nshow\nreset-failed\nstart\n" T$=
   d s" unit-state" ar INSIDE FILE-TEXT S\" active\n" T$=
   outu LEN>N 0 T=
   ERR erru LEN>N >str s" The change is kept" STR:CONTAINS? TFALSE
   got 15 T=
   x ar STORED-ROOT second T$=
   d FS:REMOVE-TREE ;

\ The unit starts failed and nothing signals, so the recover drive's
\ start is the note on stdout.
: SET-ROOT-REVIVES-A-FAILED-SERVICE ( str ^ARENA:arena -- )
   {: bin ar :}
   s" set_root_revives_a_failed_service" T-LABEL
   ar FIXTURE {: d x first :}
   d s" second" ar INSIDE {: second :}
   second FS:MAKE-DIR
   bin d second s" failed" s" " s" " 0 ar SET-ROOT-KILLED
   {: outu:len erru:len got:n :}
   OUT outu LEN>N >str s" The stopped service has been started again."
   STR:CONTAINS? TTRUE
   erru LEN>N 0 T=
   got -1 T=
   d s" service.log" ar INSIDE FILE-TEXT
   S\" reset-failed\nstart\n" STR:ENDS-WITH? TTRUE
   d s" unit-state" ar INSIDE FILE-TEXT S\" active\n" T$=
   x ar STORED-ROOT second T$=
   d FS:REMOVE-TREE ;

\ The built program's setup of the stored config for the credential
\ file f, HOME, the XDG homes and an empty PATH directory in d: stdout's
\ and stderr's lengths in OUT and ERR, and its exit code, -1 for one
\ that did not exit.
: BUILT-SETUP ( str str str ^ARENA:arena -- len len n )
   {: bin f d ar :}
   PROC-ARGV-ENV-RESET
   bin PROC-ARGV+ s" setup" PROC-ARGV+ s" --credential-file" PROC-ARGV+
   f PROC-ARGV+
   d s" bin" ar INSIDE {: b :}
   b FS:MAKE-DIRS
   s" PATH" b PROC-ENV+
   s" HOME" d PROC-ENV+
   s" XDG_CONFIG_HOME" d s" config" ar INSIDE PROC-ENV+
   s" XDG_STATE_HOME" d s" state" ar INSIDE PROC-ENV+
   s" /usr/bin/env" OUT CAP >LEN ERR CAP >LEN
   RUN-MS >MS RUN-ARGV-ENV-CAPTURE-OUTCOME
   MATCH PROCESS:ending
      exited OF ENDOF
      signaled OF drop -1 ENDOF
      timeout OF -1 ENDOF
   ;MATCH ;

\ The built program's setup for the credential file f, refused with
\ FILE-CHECKED's line and FILE-FAILED's two before any login.
: FILE-REFUSED ( str str str ^ARENA:arena -- )
   {: bin f d ar :}
   bin f d ar BUILT-SETUP {: outu:len erru:len got:n :}
   ERR erru LEN>N >str {: e :}
   e LINES 3 T=
   e s" cannot create the credential file " STR:CONTAINS? TTRUE
   e f STR:CONTAINS? TTRUE
   e FS:EEXIST FS:ERRNO$ STR:CONTAINS? TTRUE
   e s" could not write the credential file" LOGGED? TTRUE
   e s" help: Name a new file in a writable folder, then retry setup."
   LOGGED? TTRUE
   outu LEN>N 0 T=
   got 1 T= ;

: SETUP-REFUSES-A-TAKEN-CREDENTIAL-FILE-BEFORE-THE-LOGIN
   ( str ^ARENA:arena -- )
   {: bin ar :}
   s" setup_refuses_a_taken_credential_file_before_the_login" T-LABEL
   ar TEMPORARY {: d :}
   d s" existing" ar INSIDE {: f :}
   f s" kept" FS:WRITE-ALL
   bin f d ar FILE-REFUSED
   f FILE-TEXT s" kept" T$=
   d s" dangling" ar INSIDE {: l :}
   d s" nowhere" ar INSIDE l FS:MAKE-SYMLINK
   bin l d ar FILE-REFUSED
   d FS:REMOVE-TREE ;

: RUN-BUILT ( str ^ARENA:arena -- )
   {: bin ar :}
   bin VERSION-PRINTED
   bin ar SET-ROOT-INTERRUPTED-BY-SIGINT-RESTORES-THE-SERVICE
   bin ar SET-ROOT-INTERRUPTED-BY-SIGTERM-RESTORES-THE-SERVICE
   bin ar SET-ROOT-INTERRUPTED-BY-SIGHUP-RESTORES-THE-SERVICE
   bin ar SET-ROOT-KILLED-DURING-RESTART-KEEPS-THE-CHANGE
   bin ar SET-ROOT-KILLED-WITH-A-FAILED-RESTART-KEEPS-THE-CHANGE
   bin ar SET-ROOT-INTERRUPTED-WITHOUT-RESTART-TELLS-THE-CHANGE-FAILED
   bin ar SET-ROOT-INTERRUPTED-DURING-RECOVERY-FINISHES-IT
   bin ar SET-ROOT-REVIVES-A-FAILED-SERVICE
   bin ar SETUP-REFUSES-A-TAKEN-CREDENTIAL-FILE-BEFORE-THE-LOGIN ;

: PROGRAM ( ^ARENA:arena -- )
   {: ar :}
   ar TEMPORARY {: d :}
   d s" omabox" ar INSIDE {: bin :}
   [: bin BUILT? if bin ar RUN-BUILT then ;]
   [: d FS:REMOVE-TREE ;] finally ;


\ ---- the window's table against its model

: FORMAL-HOLDS-THE-RELEASE-WINDOW-TABLES ( ^ARENA:arena -- )
   {: ar :}
   s" formal_holds_the_release_window_tables" T-LABEL
   s" src/omabox.f" s" RELEASING" s" ReleaseWindow" ar TEST-FORMAL:HOLDS
   s" src/omabox.f" s" CLOSING" s" ReleaseWindowClose" ar
   TEST-FORMAL:HOLDS ;


\ ---- the suite

: SUITE ( ^ARENA:arena -- )
   {: ar :}
   PARSER-ACCEPTS-DOCUMENTED-FORMS
   ar PARSER-REJECTS-INCOMPLETE-OR-SECRET-BEARING-FORMS
   ar PARSER-NAMES-THE-SETUP-OPTION-FAULT
   ar DEFAULT-SYNC-ROOT-IS-A-PRIVATE-HOME-DROPBOX-CREATED-ONCE
   ar THE-WIDGET-LINK-IS-MADE-ONCE-AND-NEVER-REPLACES-AN-ENTRY
   ar THE-WIDGET-LINK-REFUSES-A-BAD-HOME-OR-PLUGINS-FOLDER
   ar FAILED-INITIAL-SETUP-LEAVES-NO-CONFIG-AND-SAME-COMMAND-CAN-RETRY
   ar AN-OVERLONG-AUTHORIZATION-CODE-IS-REJECTED-WITHIN-THE-BOUND
   ar AN-AUTHORIZATION-CODE-AT-THE-LIMIT-IS-ACCEPTED
   ar AN-AUTHORIZATION-CODE-IS-TRIMMED
   ar A-BLANK-OR-NON-UTF8-AUTHORIZATION-CODE-IS-REJECTED
   ar STATUS-REPORTS-THE-JOURNAL-WHEN-THE-ROOT-IS-UNAVAILABLE
   ar SETTINGS-SHOW-THE-STORED-ROOT-WHEN-IT-IS-UNAVAILABLE
   ar SETTINGS-JSON-IS-ONE-DOCUMENT-WHEN-THE-ROOT-IS-AVAILABLE
   ar SETTINGS-SHOW-A-ROOT-OF-ANY-LENGTH
   ar SERVICE-COMMANDS-RESET-THE-START-LIMIT-BEFORE-A-START
   ar RESTORE-GOAL-RESTORES-ONLY-AFTER-A-SPAWNED-RELEASE
   ar A-CHANGE-RUNS-WHILE-THE-SERVICE-IS-RELEASED
   ar A-FAILED-CHANGE-STILL-RESTORES-THE-SERVICE
   ar A-FAILED-RELEASE-SKIPS-THE-CHANGE-AND-RESTORES
   ar CONFIG-ERRORS-SHOW-THEIR-OWN-HELP
   ar SET-ROOT-RETIRES-LIVE-INTENT-AND-PRESERVES-PAYLOADS
   ar SET-ROOT-STARTS-A-FAILED-SERVICE-AFTER-THE-CHANGE
   ar SET-ROOT-RESTARTS-A-STARTING-SERVICE
   ar SET-ROOT-WAITS-OUT-A-STOPPING-SERVICE
   ar A-COMPLETED-CHANGE-REPORTS-A-FAILED-START
   ar SET-ROOT-REQUIRES-THE-DAEMON-LOCK-BEFORE-WRITING-CONFIG
   ar CONFIG-WRITE-FAILURE-PRESERVES-ROOT-GENERATION-AND-LIVE-INTENT
   ar A-FAILED-CHANGE-AND-RESTART-REPORT-BOTH
   ar SET-ROOT-WORKS-WHEN-THE-PRIOR-ROOT-IS-UNAVAILABLE
   ar SET-ROOT-EXPLICITLY-ADOPTS-A-REPLACEMENT-AT-THE-SAME-PATH
   ar SETUP-REPORTS-A-HELD-LOCK-AND-RESTORES-THE-SERVICE
   ar A-FAILED-CHANGE-AND-RESTORE-RENDER-BOTH
   ar SETUP-RELEASES-THE-LOCK-BEFORE-STARTING-A-FAILED-SERVICE
   ar AN-UNEXPECTED-CODE-IS-LOGGED
   ar LOGIN-CASES
   ar PROGRAM
   ar FORMAL-HOLDS-THE-RELEASE-WINDOW-TABLES ;

: RUN-SUITE ( -- )
   T-RESET
   [: SUITE ;] ARENA:WITH
   s" omabox-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN-SUITE

;package
