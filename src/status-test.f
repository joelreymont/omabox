\ status-test.f - STATUS on runtime directories under TMPDIR: the six
\ tests of the Rust version under their names, each reading status.json back and comparing its bytes with what
\ the Rust version writes for the snapshot, updated_at the status's own;
\ and the heartbeat, which rewrites the file on a short period and stops
\ at once on a long one. The snapshot holds one transfer, so the
\ finished-transfer test follows one transfer at a time. A retry's error
\ clears once an operation completes, back to a dirty pass's if it
\ replaced one; a finished transfer leaves it, and a dirty pass's and a
\ stop's stay. Then a link at
\ status.json or at the temporary's name, a restart over loosened modes,
\ the transfer path's display rules, NEW's refusals, a runtime
\ directory reached through a link and a detached status, which logs
\ nothing. Each case removes its directory; the log lines of the failed
\ replace, of the refusals and of the detached status are captured in
\ TMPDIR, checked and removed.
\ Run from the repository root: hb --load src/status-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test/assert.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-list.f
require src/lib/task.f
require src/lib/time.f
require src/status.f

\ STATUS reopened: a case reads a status's updated_at and passes the
\ heartbeat its period.
package STATUS
private

4096 constant CAP
CAP BUFFER: BODY
CAP BUFFER: WANT
CAP BUFFER: NAMES
CAP BUFFER: PRE
CAP BUFFER: PATHS
512 constant LONG-U
LONG-U BUFFER: LONG
100 constant SHORT-MS
60000 constant LONG-MS
$1C0 constant DIR-MODE
$180 constant FILE-MODE
$1ED constant LOOSE-DIR
$1A4 constant LOOSE-FILE


\ ---- a runtime directory -----------------------------------------

: RUNTIME ( ^ARENA:arena -- str )
   {: ar :}
   s" status-test" FS:MKTEMP-DIR str> {: p:^ u :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   p dst u BYTE-COPY
   dst u >str ;


: GONE ( str -- )
   FS:REMOVE-TREE ;


\ ---- the file ----------------------------------------------------

\ status.json's path, in PATHS.
: FILE-PATH ( ^status -- str )
   STATUS-DIR @ FILE$ PATHS CAP SPAN:MAKE
   FS:JOIN-PATH-INTO {: u :}
   PATHS u >str ;


: READ ( ^status -- str )
   FILE-PATH BODY CAP FS:READ-ALL {: u :}
   BODY u >str ;


: PUT ( str n -- n )
   {: s at :}
   s str> {: a:^ u :}
   a WANT at + u BYTE-COPY
   at u + ;


\ want's prefix, then s's updated_at and the closing brace.
: WANTED ( ^status str -- str )
   {: s want :}
   want 0 PUT
   s STATUS-UPDATED @ FMT:INT$ swap PUT
   s" }" swap PUT {: u :}
   WANT u >str ;


: READS ( ^status str -- )
   {: s want :}
   s READ s want WANTED T$= ;


: LISTED ( ^status -- str )
   STATUS-DIR @ NAMES CAP FS-LIST:NAMES {: u :}
   NAMES u >str ;


: PROGRESS ( ^status direction str n option<n> -- )
   {: s d:direction a done total :}
   d a done total STATUS-TRANSFER:MAKE
   STATUS-EVENT:PROGRESS s TRANSFER ;


: FINISH ( ^status direction str n option<n> -- )
   {: s d:direction a done total :}
   d a done total STATUS-TRANSFER:MAKE
   STATUS-EVENT:FINISHED s TRANSFER ;


: UP ( -- direction ) construct direction upload ;
: DOWN ( -- direction ) construct direction download ;
: OF-N ( n -- option<n> ) OPTION:SOME ;
: UNKNOWN ( -- option<n> ) OPTION:NONE ;


\ ---- the Rust version's tests -----------------------------------

: STATUS-IS-PRIVATE-VERSIONED-AND-ATOMICALLY-REPLACED ( ^ARENA:arena -- )
   {: ar :}
   s" status_is_private_versioned_and_atomically_replaced" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   construct phase waiting s PHASE
   s HEARTBEAT
   s STATUS-DIR @ FS:STAT-MODE MODE-BITS and DIR-MODE T=
   s FILE-PATH FS:STAT-MODE MODE-BITS and FILE-MODE T=
   s s\" {\"version\":3,\"phase\":\"waiting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   s LISTED FILE$ T$=
   rt GONE ;


: TRANSFER-PATH-IS-RELATIVE-AND-ERROR-IS-FIXED-TEXT ( ^ARENA:arena -- )
   {: ar :}
   s" transfer_path_is_relative_and_error_is_fixed_text" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s DOWN s" folder/report.txt" 4 10 OF-N PROGRESS
   s HEARTBEAT
   s s\" {\"version\":3,\"phase\":\"starting\",\"transfers\":[{\"direction\":\"download\",\"path\":\"folder/report.txt\",\"bytes_done\":4,\"bytes_total\":10}],\"last_error\":null,\"updated_at\":" READS
   s DOWN s" folder/report.txt" 0 UNKNOWN FINISH
   s" Dropbox authentication is unavailable." s ERROR
   s s\" {\"version\":3,\"phase\":\"error\",\"transfers\":[],\"last_error\":\"Dropbox authentication is unavailable.\",\"updated_at\":" READS
   rt GONE ;


: STOPPED-STATUS-CLEARS-TRANSFERS-AND-KEEPS-THE-FATAL-TEXT ( ^ARENA:arena -- )
   {: ar :}
   s" stopped_status_clears_transfers_and_keeps_the_fatal_text" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s UP s" folder/report.txt" 4 10 OF-N PROGRESS
   s" Omabox setup is required." s STOPPED
   s s\" {\"version\":3,\"phase\":\"stopped\",\"transfers\":[],\"last_error\":\"Omabox setup is required.\",\"updated_at\":" READS
   rt GONE ;


: SYNC-ERROR-SURVIVES-PHASE-CHANGES-UNTIL-A-CLEAN-PASS ( ^ARENA:arena -- )
   {: ar :}
   s" sync_error_survives_phase_changes_until_a_clean_pass" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   construct phase syncing s PHASE
   s UP s" good.txt" 4 10 OF-N PROGRESS
   s SYNC-ERROR
   s s\" {\"version\":3,\"phase\":\"error\",\"transfers\":[{\"direction\":\"upload\",\"path\":\"good.txt\",\"bytes_done\":4,\"bytes_total\":10}],\"last_error\":\"One or more files could not be synchronized.\",\"updated_at\":" READS
   construct phase waiting s PHASE
   s s\" {\"version\":3,\"phase\":\"waiting\",\"transfers\":[],\"last_error\":\"One or more files could not be synchronized.\",\"updated_at\":" READS
   s CLEAR-ERROR
   s s\" {\"version\":3,\"phase\":\"waiting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   rt GONE ;


\ One transfer: a second's progress replaces the first, whose finish
\ then changes nothing.
: FINISHED-TRANSFER-REMAINS-VISIBLE-UNTIL-ACTIVITY-OR-PHASE-CHANGES ( ^ARENA:arena -- )
   {: ar :}
   s" finished_transfer_remains_visible_until_activity_or_phase_changes" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   construct phase syncing s PHASE
   s DOWN s" first.txt" 3 10 OF-N PROGRESS
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[{\"direction\":\"download\",\"path\":\"first.txt\",\"bytes_done\":3,\"bytes_total\":10}],\"last_error\":null,\"updated_at\":" READS
   s DOWN s" second.txt" 7 20 OF-N PROGRESS
   s DOWN s" first.txt" 3 10 OF-N FINISH
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[{\"direction\":\"download\",\"path\":\"second.txt\",\"bytes_done\":7,\"bytes_total\":20}],\"last_error\":null,\"updated_at\":" READS
   s DOWN s" second.txt" 20 20 OF-N FINISH
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[{\"direction\":\"download\",\"path\":\"second.txt\",\"bytes_done\":20,\"bytes_total\":20}],\"last_error\":null,\"updated_at\":" READS
   construct phase syncing s PHASE
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[{\"direction\":\"download\",\"path\":\"second.txt\",\"bytes_done\":20,\"bytes_total\":20}],\"last_error\":null,\"updated_at\":" READS
   s UP s" third.txt" 2 9 OF-N PROGRESS
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[{\"direction\":\"upload\",\"path\":\"third.txt\",\"bytes_done\":2,\"bytes_total\":9}],\"last_error\":null,\"updated_at\":" READS
   construct phase waiting s PHASE
   s s\" {\"version\":3,\"phase\":\"waiting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   rt GONE ;


: FAILED-REPLACEMENT-DOES-NOT-LEAVE-A-TEMPORARY-FILE ( ^ARENA:arena -- )
   {: ar :}
   s" failed_replacement_does_not_leave_a_temporary_file" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s FILE-PATH FS:REMOVE-FILE
   s FILE-PATH FS:MAKE-DIR
   ar RUNTIME {: log:str :}
   log s" status.log" ar JOINED {: path:str :}
   [: construct phase syncing s PHASE ;] path ar STDERR:CAPTURING
   {: code:n e :}
   code 0<> if code throw then
   s LISTED FILE$ T$=
   e s" status: could not replace the status file: " STR:CONTAINS?
   TTRUE
   log GONE
   rt GONE ;


\ ---- a retry's error --------------------------------------------

: A-RETRY-ERROR-CLEARS-ONCE-WORK-COMPLETES ( ^ARENA:arena -- )
   {: ar :}
   s" a retry's error clears once work completes" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s" Dropbox could not be reached." s ERROR
   construct phase syncing s PHASE
   s COMPLETED
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   s" Dropbox could not be reached." s ERROR
   s UP s" good.txt" 4 10 OF-N PROGRESS
   s UP s" good.txt" 10 10 OF-N FINISH
   s s\" {\"version\":3,\"phase\":\"error\",\"transfers\":[{\"direction\":\"upload\",\"path\":\"good.txt\",\"bytes_done\":10,\"bytes_total\":10}],\"last_error\":\"Dropbox could not be reached.\",\"updated_at\":" READS
   s SYNC-ERROR
   s COMPLETED
   s s\" {\"version\":3,\"phase\":\"error\",\"transfers\":[{\"direction\":\"upload\",\"path\":\"good.txt\",\"bytes_done\":10,\"bytes_total\":10}],\"last_error\":\"One or more files could not be synchronized.\",\"updated_at\":" READS
   s" Dropbox could not be reached." s ERROR
   s" Dropbox could not be reached." s ERROR
   s COMPLETED
   s s\" {\"version\":3,\"phase\":\"error\",\"transfers\":[],\"last_error\":\"One or more files could not be synchronized.\",\"updated_at\":" READS
   s CLEAR-ERROR
   s s\" {\"version\":3,\"phase\":\"error\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   s" Omabox setup is required." s STOPPED
   s COMPLETED
   s s\" {\"version\":3,\"phase\":\"stopped\",\"transfers\":[],\"last_error\":\"Omabox setup is required.\",\"updated_at\":" READS
   rt GONE ;


\ ---- status.json's entry, a restart, paths and refusals -----------

\ status.json is a regular 0600 file, never a link.
: PRIVATE-FILE ( ^status -- )
   FILE-PATH {: file :}
   file FS:SYMLINK? TFALSE
   file FS:FILE? TTRUE
   file FS:STAT-MODE MODE-BITS and FILE-MODE T= ;


: LINK-AT-STATUS-IS-REPLACED-NEVER-FOLLOWED ( ^ARENA:arena -- )
   {: ar :}
   s" a link at status.json is replaced, never followed" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s STATUS-DIR @ FILE$ ar JOINED {: file:str :}
   rt s" missing" ar JOINED {: gone:str :}
   rt s" target" ar JOINED {: kept:str :}
   kept s" keep" FS:WRITE-ALL
   kept LOOSE-FILE FS:CHMOD-MODE
   file FS:REMOVE-FILE
   gone file FS:MAKE-SYMLINK
   construct phase waiting s PHASE
   s PRIVATE-FILE
   s s\" {\"version\":3,\"phase\":\"waiting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   gone FS:TRY-STAT TFALSE
   file FS:REMOVE-FILE
   kept file FS:MAKE-SYMLINK
   construct phase syncing s PHASE
   s PRIVATE-FILE
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   kept BODY CAP FS:READ-ALL {: u :}
   BODY u >str s" keep" T$=
   kept FS:STAT-MODE MODE-BITS and LOOSE-FILE T=
   s LISTED FILE$ T$=
   rt GONE ;


: STALE-TEMPORARY-LINK-IS-SWEPT ( ^ARENA:arena -- )
   {: ar :}
   s" a link at the temporary's name is swept" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s STATUS-DIR @ s STATUS-TEMP @ ar JOINED {: temp:str :}
   rt s" outside" ar JOINED {: kept:str :}
   rt s" missing" ar JOINED {: gone:str :}
   kept s" keep" FS:WRITE-ALL
   kept LOOSE-FILE FS:CHMOD-MODE
   kept temp FS:MAKE-SYMLINK
   construct phase waiting s PHASE
   s s\" {\"version\":3,\"phase\":\"waiting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   s LISTED FILE$ T$=
   kept BODY CAP FS:READ-ALL {: u :}
   BODY u >str s" keep" T$=
   kept FS:STAT-MODE MODE-BITS and LOOSE-FILE T=
   gone temp FS:MAKE-SYMLINK
   construct phase syncing s PHASE
   s s\" {\"version\":3,\"phase\":\"syncing\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   s LISTED FILE$ T$=
   gone FS:TRY-STAT TFALSE
   rt GONE ;


: RESTART-SECURES-THE-DIRECTORY-AND-FILE-AGAIN ( ^ARENA:arena -- )
   {: ar :}
   s" a restart secures the directory and status.json again" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s STATUS-DIR @ LOOSE-DIR FS:CHMOD-MODE
   s FILE-PATH LOOSE-FILE FS:CHMOD-MODE
   s STATUS-DIR @ FS:STAT-MODE MODE-BITS and LOOSE-DIR T=
   s FILE-PATH FS:STAT-MODE MODE-BITS and LOOSE-FILE T=
   rt ar NEW {: again :}
   again STATUS-DIR @ FS:STAT-MODE MODE-BITS and DIR-MODE T=
   again PRIVATE-FILE
   again s\" {\"version\":3,\"phase\":\"starting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   again LISTED FILE$ T$=
   rt GONE ;


\ a's bytes at PRE's offset at.
: APPEND ( str n -- n )
   {: s at :}
   s str> {: a:^ u :}
   a PRE at + u BYTE-COPY
   at u + ;


\ An upload of path shows as shown, byte for byte.
: SHOWS ( ^status str str -- )
   {: s p w :}
   s UP p 1 2 OF-N PROGRESS
   s\" {\"version\":3,\"phase\":\"starting\",\"transfers\":[{\"direction\":\"upload\",\"path\":\"" 0 APPEND
   w swap APPEND
   s\" \",\"bytes_done\":1,\"bytes_total\":2}],\"last_error\":null,\"updated_at\":" swap APPEND {: u :}
   s PRE u >str READS ;


\ deep/ and x up to LONG-U bytes, past the shown buffers' first 256.
: LONG-PATH ( -- str )
   s" deep/" str> {: a:^ u :}
   a LONG u BYTE-COPY
   LONG-U u ?do $78 LONG i + c! loop
   LONG LONG-U >str ;


\ Rust's display_path and to_string_lossy: one U+FFFD per maximal invalid
\ subpart ($FF alone, $E2 $82 cut short), which serde_json writes unescaped.
: TRANSFER-PATHS-DISPLAY-AS-RUST-DISPLAYS-THEM ( ^ARENA:arena -- )
   {: ar :}
   s" transfer paths display as the Rust version displays them" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s s" /home/user/Dropbox/a.txt" s" (invalid synchronized path)" SHOWS
   s s" " s" ." SHOWS
   s s\" a\xFFb\xE2\x82c" s\" a\xEF\xBF\xBDb\xEF\xBF\xBDc" SHOWS
   s LONG-PATH LONG-PATH SHOWS
   rt GONE ;


: NEW-REFUSES-A-RELATIVE-OR-MISSING-RUNTIME ( ^ARENA:arena -- )
   {: ar :}
   s" new refuses a relative or missing runtime directory" T-LABEL
   ar RUNTIME {: rt:str :}
   rt s" absent" ar JOINED {: absent:str :}
   ar RUNTIME {: log:str :}
   log s" status.log" ar JOINED {: path:str :}
   [: [: s" run/user" ar NEW drop ;] E-RUNTIME-NOT-ABSOLUTE TTHROWS
      [: absent ar NEW drop ;] E-RUNTIME-UNAVAILABLE TTHROWS ;]
   path ar STDERR:CAPTURING {: code:n e :}
   code 0<> if code throw then
   e s" STATUS:E-RUNTIME-NOT-ABSOLUTE: XDG_RUNTIME_DIR must be absolute"
   STR:CONTAINS?
   TTRUE
   e s" STATUS:E-RUNTIME-UNAVAILABLE: XDG_RUNTIME_DIR is unavailable"
   STR:CONTAINS? TTRUE
   absent FS:TRY-STAT TFALSE
   log GONE
   rt GONE ;


: RUNTIME-THROUGH-A-LINK-PUBLISHES-INTO-ITS-TARGET ( ^ARENA:arena -- )
   {: ar :}
   s" a runtime directory reached through a link is followed" T-LABEL
   ar RUNTIME {: rt:str :}
   ar RUNTIME {: base:str :}
   base s" runtime" ar JOINED {: link:str :}
   rt link FS:MAKE-SYMLINK
   link ar NEW {: s :}
   rt s" omabox" ar JOINED FILE$ ar JOINED {: file:str :}
   link FS:SYMLINK? TTRUE
   file FS:FILE? TTRUE
   file FS:STAT-MODE MODE-BITS and FILE-MODE T=
   s s\" {\"version\":3,\"phase\":\"starting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   base GONE
   rt GONE ;


\ ---- a detached status ------------------------------------------

\ Every change a detached status takes; a publish would log, as it has
\ no output to encode into.
: CHANGES ( ^status -- )
   {: s :}
   construct phase syncing s PHASE
   s HEARTBEAT
   s UP s" folder/report.txt" 4 10 OF-N PROGRESS
   s UP s" folder/report.txt" 10 10 OF-N FINISH
   s SYNC-ERROR
   s CLEAR-ERROR
   s" Dropbox is temporarily unavailable." s ERROR
   s" Omabox setup is required." s STOPPED ;


: UNBEATING ( ^status -- )
   {: s :}
   s HEARTBEAT-START
   BEAT-LIVE @ 0 T=
   s HEARTBEAT-STOP
   BEAT-LIVE @ 0 T= ;


: DETACHED-STATUS-PUBLISHES-NOTHING-AND-RUNS-NO-HEARTBEAT
   ( ^ARENA:arena -- )
   {: ar :}
   s" a detached status publishes nothing and runs no heartbeat" T-LABEL
   ar DETACHED {: s :}
   ar RUNTIME {: log:str :}
   log s" status.log" ar JOINED {: path:str :}
   [: s CHANGES s UNBEATING ;] path ar STDERR:CAPTURING
   {: code:n e :}
   code 0 T= e STR:len 0 T=
   log GONE ;


\ ---- the heartbeat -----------------------------------------------

: BEATS ( ^status n -- )
   {: s first :}
   30 0 ?do
      s STATUS-UPDATED @ first > if unloop exit then
      SHORT-MS >MS TASK:SLEEP
   loop ;


: HEARTBEAT-REWRITES-AND-STOPS ( ^ARENA:arena -- )
   {: ar :}
   s" the heartbeat rewrites status.json and stops" T-LABEL
   ar RUNTIME {: rt:str :}
   rt ar NEW {: s :}
   s STATUS-UPDATED @ {: first :}
   SHORT-MS s HEARTBEAT-EVERY
   s first BEATS
   s HEARTBEAT-STOP
   s STATUS-UPDATED @ first > TTRUE
   s s\" {\"version\":3,\"phase\":\"starting\",\"transfers\":[],\"last_error\":null,\"updated_at\":" READS
   TIME:MONO-NS {: t0 :}
   LONG-MS s HEARTBEAT-EVERY
   s HEARTBEAT-STOP
   TIME:MONO-NS t0 - 1000000000 < TTRUE
   rt GONE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar STATUS-IS-PRIVATE-VERSIONED-AND-ATOMICALLY-REPLACED
   ar TRANSFER-PATH-IS-RELATIVE-AND-ERROR-IS-FIXED-TEXT
   ar STOPPED-STATUS-CLEARS-TRANSFERS-AND-KEEPS-THE-FATAL-TEXT
   ar SYNC-ERROR-SURVIVES-PHASE-CHANGES-UNTIL-A-CLEAN-PASS
   ar A-RETRY-ERROR-CLEARS-ONCE-WORK-COMPLETES
   ar FINISHED-TRANSFER-REMAINS-VISIBLE-UNTIL-ACTIVITY-OR-PHASE-CHANGES
   ar FAILED-REPLACEMENT-DOES-NOT-LEAVE-A-TEMPORARY-FILE
   ar LINK-AT-STATUS-IS-REPLACED-NEVER-FOLLOWED
   ar STALE-TEMPORARY-LINK-IS-SWEPT
   ar RESTART-SECURES-THE-DIRECTORY-AND-FILE-AGAIN
   ar TRANSFER-PATHS-DISPLAY-AS-RUST-DISPLAYS-THEM
   ar NEW-REFUSES-A-RELATIVE-OR-MISSING-RUNTIME
   ar RUNTIME-THROUGH-A-LINK-PUBLISHES-INTO-ITS-TARGET
   ar DETACHED-STATUS-PUBLISHES-NOTHING-AND-RUNS-NO-HEARTBEAT
   ar HEARTBEAT-REWRITES-AND-STOPS ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" status-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
