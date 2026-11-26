\ config-test.f - CONFIG against the Rust version's config.rs tests of what
\ it ports, under their names: the XDG paths, the private paths and their
\ symlink projection, the sync root's checks, the refusals of a config
\ that names a protected path inside it, the prepared directories and the
\ daemon lock, contended in this process and by util-linux's flock(1)
\ through /usr/bin/flock. Then config.toml as the toml crate
\ reads it: each string form, each escape, comments, whitespace, CRLF, a
\ BOM and quoted keys, and each refusal with the code the Rust error maps
\ to; then config.toml written as the toml crate writes it, replacing a
\ file or refusing to, sweeping only dead processes' temporaries. A
\ refusal's two log lines, its text and Rust's help, are checked; so are
\ the failures of prepare and the lock. Every case runs in a
\ directory of its own under TMPDIR, sets its own XDG and HOME values and
\ removes the directory after. CONFIG's log lines go to stderr, but those
\ a case checks, which are captured in the case's directory, checked and
\ removed. White-box: CONFIG is reopened for the private words a Rust
\ test calls and the failure words no case reaches.
\ Run from the repository root: hb --load src/config-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/memory.f
require src/lib/adt/option.f
require src/lib/test/assert.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/lib/process.f
require src/lib/fs-list.f
require src/lib/fmt.f
require src/lib/vector.f
require src/lib/spawn.f
require src/stale.f
require src/config.f

package CONFIG-TEST
;package


\ CONFIG reopened for projection, XDG resolution and fields, realpath, three
\ failure words, a write's failed cleanup and a lock's descriptor; each name
\ lands in CONFIG-TEST.
package CONFIG

: CONFIG-TEST:FOLLOW ( abs-path ^ARENA:arena -- abs-path )
   {: p ar :}
   p DANGLING-FOLLOW ar PROJECT ;

: CONFIG-TEST:REFUSE ( abs-path ^ARENA:arena -- abs-path )
   {: p ar :}
   p DANGLING-REFUSE ar PROJECT ;

: CONFIG-TEST:ABSENT ( -- option<str> ) NO-STR ;

: CONFIG-TEST:RESOLVE ( option<str> option<str> option<str> ^ARENA:arena -- ^xdg )
   RESOLVE-XDG ;

: CONFIG-TEST:STATE-HOME ( ^xdg -- abs-path ) XDG-STATE-HOME @ ;

: CONFIG-TEST:STATE-APP ( ^xdg ^ARENA:arena -- abs-path ) XDG-STATE-DIRECTORY ;

: CANON-FAILED ( -- ) E-INSPECT-PATH throw ;

: CONFIG-TEST:CANON ( str ^ARENA:arena -- abs-path )
   CANONICAL MATCH option
      some OF ENDOF
      none OF CANON-FAILED ENDOF
   ;MATCH ;

: CONFIG-TEST:SECURE-FAILED ( abs-path -- )
   {: p :}
   PATH-ROLE-STATE p SECURE-FAILED ;

: CONFIG-TEST:ACQUIRE-FAILED ( abs-path -- ) ACQUIRE-FAILED ;

: CONFIG-TEST:OPEN-FAILED ( abs-path -- ) OPEN-FAILED ;

\ A write of a temporary that failed EPERM, then its failed removal.
: CONFIG-TEST:CLEANUP-FAILS ( abs-path -- )
   {: p :}
   FS:EPERM FS:CAUSE!
   [: s" write a temporary" p WRITE-FAILED ;] catch {: code:n :}
   code E-WRITE <> if code throw then
   p FS:ERRNO CLEANUP-AFTER-WRITE ;

: CONFIG-TEST:LOCK-FD ( lock -- lock n )
   LOCK-UNMAKE {: f:fd p :}
   f p LOCK-MAKE f FD>N ;

;package


package CONFIG-TEST
private

TYPED-VARIABLE AR ^ARENA:arena
\ The case's directory as TMPDIR spells it, and canonical.
TYPED-VARIABLE DIR str
TYPED-VARIABLE REAL str
TYPED-VARIABLE BODY [ -- ]
TYPED-VARIABLE ACTION [ -- ]
TYPED-VARIABLE XDG ^CONFIG:xdg
TYPED-VARIABLE ROOT str
TYPED-VARIABLE SET ^CONFIG:paths
TYPED-VARIABLE HELD ^CONFIG:config
PTR-VARIABLE ERR         \ the captured log, in AR
variable ERR-U
\ FS:ERRNO as the logged action left it.
variable CAUSE


\ ---- strings and paths, laid in the case's arena

: KEEP ( str -- str ) AR @ ARENA:COPY ;

: CAT ( str str -- str )
   {: a b :}
   a str> {: ap:^ au:n :}
   b str> {: bp:^ bu:n :}
   AR @ au bu + ARENA:ALLOC {: d:^ du:n :}
   ap d au BYTE-COPY
   bp d au + bu BYTE-COPY
   d du >str ;

\ DIR/name and REAL/name.
: UNDER ( str -- str )
   {: n :}
   DIR @ s" /" CAT n CAT ;

: REAL-UNDER ( str -- str )
   {: n :}
   REAL @ s" /" CAT n CAT ;

: P ( str -- CONFIG:abs-path ) UNDER CONFIG:>ABS-PATH ;

: MKDIR ( str -- ) FS:MAKE-DIR ;
: MKDIRS ( str -- ) FS:MAKE-DIRS ;
: SYMLINK ( str str -- ) {: target link :} target link FS:MAKE-SYMLINK ;
: EXISTS? ( str -- bool ) FS:TRY-STAT ;
: DIRECTORY? ( CONFIG:abs-path -- bool ) CONFIG:ABS-PATH>STR FS:DIR? ;

\ The permission bits of the entry a path names, links followed.
: MODE ( CONFIG:abs-path -- n )
   CONFIG:ABS-PATH>STR FS:TRY-STAT TTRUE
   FS:STAT-MODE@ $1FF and ;

: PATH= ( CONFIG:abs-path str -- )
   {: p s :}
   p CONFIG:ABS-PATH>STR s T$= ;


\ ---- the case's frame

: CLEANUP ( -- )
   DIR @ FS:REMOVE-TREE
   AR @ ARENA:RELEASE ;

\ Runs the body with AR, DIR and REAL fresh; the directory goes after.
: RUN-CASE ( str [ -- ] -- )
   BODY ! T-LABEL
   ARENA:NEW AR !
   s" TMPDIR" GETENV s" config-test-" FS:MKTEMP-DIR-IN KEEP DIR !
   DIR @ AR @ CONFIG-TEST:CANON CONFIG:ABS-PATH>STR REAL !
   [: BODY @ execute ;] [: CLEANUP ;] finally ;


\ ---- the log a refusal writes

: ERR$ ( -- str ) ERR @ ERR-U @ >str ;
: ERR-PATH ( -- str ) s" stderr.txt" UNDER ;

\ The code the action throws, 0 for none, with fd 2 sent to the case's
\ stderr.txt, which ERR$ then holds and which is removed.
: LOGGED ( [ -- ] -- n )
   ACTION !
   [: ACTION @ [: FS:ERRNO CAUSE ! ;] finally ;]
   ERR-PATH AR @ STDERR:CAPTURING str> ERR-U ! ERR ! ;

: LINES ( str -- n )
   str> {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;

\ The text a u ends in CONFIG's tag, t and a newline.
: ENDS? ( str str -- bool )
   {: s t :}
   s str> {: a:^ u:n :}
   s" config: " t CAT s\" \n" CAT str> {: w:^ wu:n :}
   u wu < if false exit then
   a u wu - + wu >str w wu >str T-STR= ;

\ ERR$'s first line's length, its newline included.
: FIRST-LINE ( -- n )
   ERR-U @ 0 ?do ERR @ i + c@ 10 = if i 1+ unloop exit then loop
   ERR-U @ ;

\ ERR$ is one line, t.
: LINE? ( str -- bool )
   {: t :}
   ERR$ LINES 1 <> if false exit then
   ERR$ t ENDS? ;

\ ERR$ is the line t, then the help line h.
: HELPED? ( str str -- bool )
   {: t h :}
   ERR$ LINES 2 <> if false exit then
   ERR @ FIRST-LINE >str t ENDS? 0= if false exit then
   ERR @ FIRST-LINE + ERR-U @ FIRST-LINE - >str
   s" help: " h CAT ENDS? ;

\ Asserts the flag, showing what ERR$ should have held.
: ASSERT-LOG ( bool str -- )
   {: ok:bool t :}
   ok T-ASSERT ok if exit then
   s" want: " type t type cr s" got: " type ERR$ type ;

\ The action throws the code and logs the line t and the help line h.
: REFUSED-WITH ( [ -- ] n str str -- )
   {: xt want:n t h :}
   xt LOGGED want T=
   t h HELPED? t s"  / help: " CAT h CAT ASSERT-LOG ;

\ Rust's help for each code a case expects; a protected path's names
\ XDG_STATE_HOME, as every role's but the configuration directory's.
: HELP$ ( n -- str )
   case
      CONFIG:E-PATH-NOT-ABSOLUTE of s" Use an absolute path so the unattended service resolves it consistently." endof
      CONFIG:E-READ of s" Create a readable file containing an absolute `sync_root` and a `dropbox_app_key`." endof
      CONFIG:E-MISSING of s" Create a readable file containing an absolute `sync_root` and a `dropbox_app_key`." endof
      CONFIG:E-PARSE of s" The file may contain only `sync_root` and `dropbox_app_key`; credentials do not belong in configuration." endof
      CONFIG:E-EMPTY-APP-KEY of s" Set `dropbox_app_key` to the public app key from the Dropbox developer console." endof
      CONFIG:E-RESOLVE-SYNC-ROOT of s" Create the sync root as a local directory and ensure it is accessible." endof
      CONFIG:E-SYNC-ROOT-NOT-DIRECTORY of s" Set `sync_root` to an existing local directory." endof
      CONFIG:E-INSPECT-PATH of s" Ensure every parent directory is accessible and retry." endof
      CONFIG:E-INSIDE-SYNC-ROOT of s" Set XDG_STATE_HOME to a local directory outside the sync root." endof
      CONFIG:E-CREATE-DIRECTORY of s" Ensure the XDG state location is writable and has sufficient space." endof
      CONFIG:E-SECURE-DIRECTORY of s" Ensure the XDG state location is owned by this user and retry." endof
      CONFIG:E-LOCK-OPEN of s" Ensure the Omabox state directory is writable and retry." endof
      CONFIG:E-ALREADY-RUNNING of s" Use the existing daemon instance; no lock-file cleanup is required." endof
      CONFIG:E-LOCK-ACQUIRE of s" Check filesystem lock support and retry." endof
      CONFIG:E-ALREADY-EXISTS of s" Use Omabox settings commands to change existing configuration." endof
      CONFIG:E-WRITE of s" Ensure the XDG configuration location is owned by this user and writable." endof
      CONFIG:E-HOME-UNAVAILABLE of s" Set HOME, or set both XDG_CONFIG_HOME and XDG_STATE_HOME to absolute paths." endof
      s" " swap
   endcase ;

\ The action throws the code and logs the line t and the code's help.
: REFUSED ( [ -- ] n str -- )
   {: xt want:n t :}
   xt want t want HELP$ REFUSED-WITH ;


\ ---- the Rust fixture

\ DIR/Dropbox made, XDG over DIR/config and DIR/state, DIR/config/omabox made.
: FIXTURE ( -- )
   s" Dropbox" UNDER ROOT !
   ROOT @ MKDIR
   s" config" P s" state" P AR @ CONFIG:XDG-NEW XDG !
   s" config/omabox" UNDER MKDIRS ;

: XDG-AT ( str str -- )
   {: c s :}
   c P s P AR @ CONFIG:XDG-NEW XDG ! ;

: XDG-LINKED ( str str -- )
   {: c s :}
   c P s CONFIG:>ABS-PATH AR @ CONFIG:XDG-NEW XDG ! ;

: CONFIG-FILE ( -- str ) XDG @ AR @ CONFIG:XDG-CONFIG-FILE CONFIG:ABS-PATH>STR ;
: CONFIG-DIR ( -- str ) XDG @ AR @ CONFIG:RESOLVE-PRIVATE CONFIG:CONFIG-DIRECTORY CONFIG:ABS-PATH>STR ;
: STATE-APP ( -- str ) XDG @ AR @ CONFIG-TEST:STATE-APP CONFIG:ABS-PATH>STR ;

: WRITE-CONFIG ( str -- ) {: t :} CONFIG-FILE t FS:WRITE-ALL ;

: ROOT-LINE ( -- str ) s\" sync_root = \"" ROOT @ CAT s\" \"\n" CAT ;

\ The root and test-app-key.
: STANDARD ( -- )
   ROOT-LINE s\" dropbox_app_key = \"test-app-key\"\n" CAT WRITE-CONFIG ;

: LOAD ( -- ^CONFIG:config ) XDG @ AR @ CONFIG:LOAD-FROM ;
: LOAD-DROP ( -- ) LOAD drop ;
: DOCUMENT ( -- ^CONFIG:document ) XDG @ AR @ CONFIG:DOCUMENT-LOAD-FROM ;
: DOCUMENT-DROP ( -- ) DOCUMENT drop ;

: PARSE-TEXT ( -- str )
   s" could not parse Omabox configuration at `" CONFIG-FILE CAT s" `" CAT ;

: READ-TEXT ( -- str )
   s" could not read Omabox configuration at `" CONFIG-FILE CAT s" `" CAT ;

\ "<role> `<path>` must not be inside sync root `<root>`".
: INSIDE-TEXT ( str str str -- str )
   {: r p root :}
   r s"  `" CAT p CAT s" ` must not be inside sync root `" CAT
   root CAT s" `" CAT ;

: SAME-PATHS ( ^CONFIG:paths ^CONFIG:paths -- )
   {: a b :}
   a CONFIG:CONFIG-DIRECTORY b CONFIG:CONFIG-DIRECTORY CONFIG:ABS-PATH>STR PATH=
   a CONFIG:STATE-DIRECTORY b CONFIG:STATE-DIRECTORY CONFIG:ABS-PATH>STR PATH=
   a CONFIG:JOURNAL-FILE b CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR PATH=
   a CONFIG:UPLOAD-STAGING-DIRECTORY b CONFIG:UPLOAD-STAGING-DIRECTORY
   CONFIG:ABS-PATH>STR PATH=
   a CONFIG:RECOVERY-DIRECTORY b CONFIG:RECOVERY-DIRECTORY CONFIG:ABS-PATH>STR PATH=
   a CONFIG:LOCK-FILE b CONFIG:LOCK-FILE CONFIG:ABS-PATH>STR PATH= ;


\ ---- config.rs's tests

\ The Rust test compares the root as spelled, which is canonical under its
\ TMPDIR.
: RESOLVES-XDG-PATHS ( -- )
   FIXTURE STANDARD
   LOAD {: c :}
   c CONFIG:PREPARE
   c CONFIG:PATHS {: p :}
   c CONFIG:SYNC-ROOT s" Dropbox" REAL-UNDER PATH=
   c CONFIG:APP-KEY s" test-app-key" T$=
   p CONFIG:JOURNAL-FILE s" state" UNDER AR @ CONFIG-TEST:CANON
   CONFIG:ABS-PATH>STR s" /omabox/journal.sqlite3" CAT PATH=
   p CONFIG:UPLOAD-STAGING-DIRECTORY DIRECTORY? TTRUE
   p CONFIG:RECOVERY-DIRECTORY DIRECTORY? TTRUE
   p CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR EXISTS? TFALSE ;

: ROOT-UNAVAILABLE ( -- )
   FIXTURE STANDARD
   LOAD {: available :}
   ROOT @ FS:REMOVE-TREE
   ['] LOAD-DROP CONFIG:E-RESOLVE-SYNC-ROOT
   s" could not resolve sync root `" ROOT @ CAT s" `" CAT REFUSED
   CAUSE @ FS:ENOENT T=
   DOCUMENT {: d :}
   d CONFIG:DOCUMENT-ROOT ROOT @ PATH=
   d CONFIG:DOCUMENT-KEY s" test-app-key" T$=
   XDG @ AR @ CONFIG:RESOLVE-PRIVATE available CONFIG:PATHS SAME-PATHS ;

: STATE-INSIDE ( -- )
   FIXTURE
   s" config-two" s" Dropbox/internal-state" XDG-AT
   s" config-two/omabox" UNDER MKDIRS
   STANDARD
   ['] LOAD-DROP CONFIG:E-INSIDE-SYNC-ROOT
   s" state directory" s" Dropbox/internal-state/omabox" REAL-UNDER
   s" Dropbox" REAL-UNDER INSIDE-TEXT REFUSED
   STATE-APP EXISTS? TFALSE ;

\ The Rust test checks only the variant; the line names the role.
: SYMLINKED-STATE ( -- )
   FIXTURE
   ROOT @ s" state-link" UNDER SYMLINK
   s" config-three" s" state-link" UNDER XDG-LINKED
   s" config-three/omabox" UNDER MKDIRS
   STANDARD
   ['] LOAD-DROP CONFIG:E-INSIDE-SYNC-ROOT
   s" state directory" s" Dropbox/omabox" REAL-UNDER
   s" Dropbox" REAL-UNDER INSIDE-TEXT REFUSED ;

\ The Rust test also accepts the error from prepare; loading refuses first.
: DANGLING-STATE ( -- )
   FIXTURE
   s" Dropbox/not-yet-existing-state" UNDER s" dangling-state-link" UNDER
   SYMLINK
   s" config-four" s" dangling-state-link" UNDER XDG-LINKED
   s" config-four/omabox" UNDER MKDIRS
   STANDARD
   ['] LOAD-DROP CONFIG:E-INSPECT-PATH
   s" could not inspect `" s" dangling-state-link" UNDER CAT
   s" ` while validating configuration paths" CAT REFUSED
   s" Dropbox/not-yet-existing-state" UNDER EXISTS? TFALSE ;

\ Its loading half: the Rust test then prepares, which leaves the path.
: RELINKED-LEAVES ( -- )
   FIXTURE
   s" elsewhere" UNDER MKDIR
   STATE-APP MKDIRS
   s" elsewhere" UNDER STATE-APP s" /upload-staging" CAT SYMLINK
   STANDARD
   LOAD CONFIG:PATHS CONFIG:UPLOAD-STAGING-DIRECTORY
   s" elsewhere" REAL-UNDER PATH= ;

: FOLLOWS-ABSOLUTE ( -- )
   s" data/sub" UNDER s" link" UNDER SYMLINK
   s" link/leaf" P AR @ CONFIG-TEST:FOLLOW s" data/sub/leaf" REAL-UNDER PATH= ;

: FOLLOWS-RELATIVE ( -- )
   s" links" UNDER MKDIR
   s" ../data/sub" s" links/link" UNDER SYMLINK
   s" links/link/leaf" P AR @ CONFIG-TEST:FOLLOW
   s" data/sub/leaf" REAL-UNDER PATH= ;

: MISSING-ON-PARENT ( -- )
   s" links" UNDER MKDIR
   s" ../missing/../data" s" links/link" UNDER SYMLINK
   s" links/link/leaf" P AR @ CONFIG-TEST:FOLLOW s" data/leaf" REAL-UNDER PATH=
   s" missing/../data/leaf" P AR @ CONFIG-TEST:REFUSE
   s" data/leaf" REAL-UNDER PATH= ;

: FOLLOW-FIRST ( -- ) s" first" P AR @ CONFIG-TEST:FOLLOW drop ;

: SYMLINK-LOOP ( -- )
   s" second" UNDER s" first" UNDER SYMLINK
   s" first" UNDER s" second" UNDER SYMLINK
   ['] FOLLOW-FIRST CONFIG:E-INSPECT-PATH
   s" could not inspect `" s" first" UNDER CAT
   s" ` while validating configuration paths" CAT REFUSED
   CAUSE @ FS:ELOOP T= ;

: REFUSE-LEAF ( -- ) s" link/leaf" P AR @ CONFIG-TEST:REFUSE drop ;

: REFUSES-DANGLING ( -- )
   s" data" UNDER s" link" UNDER SYMLINK
   ['] REFUSE-LEAF CONFIG:E-INSPECT-PATH
   s" could not inspect `" s" link" UNDER CAT
   s" ` while validating configuration paths" CAT REFUSED ;

: FROM-ROOT ( -- ) XDG @ ROOT @ s" test-app-key" AR @ CONFIG:FROM-VALUES drop ;

: ROOT-HOLDS-CONFIG ( -- )
   s" Dropbox" UNDER ROOT !
   ROOT @ MKDIR
   s" Dropbox" s" state" XDG-AT
   ['] FROM-ROOT CONFIG:E-INSIDE-SYNC-ROOT
   s" configuration directory" s" Dropbox/omabox" UNDER
   s" Dropbox" REAL-UNDER INSIDE-TEXT
   s" Set XDG_CONFIG_HOME to a local directory outside the sync root."
   REFUSED-WITH ;

: LOCK-INSIDE ( -- )
   FIXTURE
   s" Dropbox/stolen.lock" UNDER s" " FS:WRITE-ALL
   STATE-APP MKDIRS
   s" Dropbox/stolen.lock" UNDER STATE-APP s" /daemon.lock" CAT SYMLINK
   STANDARD
   ['] LOAD-DROP CONFIG:E-INSIDE-SYNC-ROOT
   s" daemon lock" s" Dropbox/stolen.lock" REAL-UNDER
   s" Dropbox" REAL-UNDER INSIDE-TEXT REFUSED ;

: UNKNOWN-FIELDS ( -- )
   FIXTURE
   ROOT-LINE s\" refresh_token = \"credential-sentinel-must-never-render\"\n" CAT
   WRITE-CONFIG
   ['] LOAD-DROP CONFIG:E-PARSE PARSE-TEXT REFUSED
   ERR$ s" credential-sentinel-must-never-render" STR:CONTAINS? TFALSE ;

: EMPTY-KEY ( -- )
   FIXTURE
   s" local-path-sentinel" UNDER ROOT !
   ROOT @ MKDIR
   ROOT-LINE s\" dropbox_app_key = \"  \"\n" CAT WRITE-CONFIG
   ['] LOAD-DROP CONFIG:E-EMPTY-APP-KEY
   s" Dropbox application key is empty" REFUSED
   ERR$ s" local-path-sentinel" STR:CONTAINS? TFALSE ;

: SOME ( str -- option<str> ) OPTION:SOME ;

: NO-HOME ( -- )
   CONFIG-TEST:ABSENT CONFIG-TEST:ABSENT CONFIG-TEST:ABSENT
   AR @ CONFIG-TEST:RESOLVE drop ;

: HOME-MISSING ( -- )
   ['] NO-HOME CONFIG:E-HOME-UNAVAILABLE s" HOME is not set" REFUSED ;

: EMPTY-VALUES ( -- )
   DIR @ SOME s" " SOME s" " SOME AR @ CONFIG-TEST:RESOLVE {: x :}
   x CONFIG:CONFIG-HOME s" .config" UNDER PATH=
   x CONFIG-TEST:STATE-HOME s" .local/state" UNDER PATH= ;

: RELATIVE-VALUES ( -- )
   DIR @ SOME s" relative-config" SOME s" relative-state" SOME
   AR @ CONFIG-TEST:RESOLVE {: x :}
   x CONFIG:CONFIG-HOME s" .config" UNDER PATH=
   x CONFIG-TEST:STATE-HOME s" .local/state" UNDER PATH= ;

: ABSOLUTE-VALUES ( -- )
   CONFIG-TEST:ABSENT s" /configured/config" SOME
   s" /configured/state" SOME AR @ CONFIG-TEST:RESOLVE {: x :}
   x CONFIG:CONFIG-HOME s" /configured/config" PATH=
   x CONFIG-TEST:STATE-HOME s" /configured/state" PATH= ;


\ ---- prepare and the daemon lock

\ 0700, each.
: RUNTIME-MODES ( ^CONFIG:paths -- )
   {: p :}
   p CONFIG:STATE-DIRECTORY MODE $1C0 T=
   p CONFIG:UPLOAD-STAGING-DIRECTORY MODE $1C0 T=
   p CONFIG:RECOVERY-DIRECTORY MODE $1C0 T= ;

: PREPARE-CREATES ( -- )
   FIXTURE STANDARD
   LOAD {: c :}
   c CONFIG:PREPARE
   c CONFIG:PATHS RUNTIME-MODES ;

\ The directory made, then set 0777.
: BROAD ( CONFIG:abs-path -- )
   CONFIG:ABS-PATH>STR str> {: a:^ u:n :}
   a u >str FS:MAKE-DIRS
   a u >str $1FF FS:CHMOD-MODE ;

: PREPARE-REPAIRS ( -- )
   FIXTURE STANDARD
   LOAD {: c :}
   c CONFIG:PATHS {: p :}
   p CONFIG:STATE-DIRECTORY BROAD
   p CONFIG:UPLOAD-STAGING-DIRECTORY BROAD
   p CONFIG:RECOVERY-DIRECTORY BROAD
   c CONFIG:PREPARE
   p RUNTIME-MODES ;

: PREPARE-ROOT ( -- )
   SET @ ROOT @ CONFIG:>ABS-PATH CONFIG:PREPARE-PATHS ;

\ ROOT is DIR/root, a link to the missing DIR/data, which holds the state.
: DANGLING-ROOT-TARGET ( -- )
   s" data" UNDER s" root" UNDER SYMLINK
   s" root" UNDER ROOT !
   s" config" s" data/state" XDG-AT
   XDG @ AR @ CONFIG:RESOLVE-PRIVATE SET !
   ['] PREPARE-ROOT CONFIG:E-INSIDE-SYNC-ROOT
   s" state directory" s" data/state/omabox" REAL-UNDER ROOT @
   INSIDE-TEXT REFUSED
   s" data" UNDER EXISTS? TFALSE ;

\ A config over the fixture, prepared; its lock file is
\ REAL/state/omabox/daemon.lock.
: LOCKABLE ( -- ^CONFIG:config )
   FIXTURE STANDARD
   LOAD {: c :}
   c CONFIG:PREPARE
   c ;

: LOCK-PATH ( -- str )
   HELD @ CONFIG:PATHS CONFIG:LOCK-FILE CONFIG:ABS-PATH>STR ;
: HELD-LOCK ( -- CONFIG:lock ) HELD @ CONFIG:PATHS CONFIG:LOCK ;
: LOCK-DROP ( -- ) HELD-LOCK CONFIG:UNLOCK ;

: OPEN-TEXT ( -- str )
   s" could not open daemon lock file `" LOCK-PATH CAT s" `" CAT ;

\ The exit code of `flock -n LOCK-PATH true`: 1 while the lock is held.
: FLOCK-RC ( -- n )
   s" /usr/bin/flock" PROCESS:NEW s" -n" PROCESS:ARG
   LOCK-PATH PROCESS:ARG s" true" PROCESS:ARG
   PROCESS:SPAWN PROCESS:WAIT PROCESS:STATUS>RC RC>N ;

: LOCK-OWNER-ONLY ( -- )
   LOCKABLE HELD !
   HELD-LOCK {: l :}
   LOCK-PATH FS:TRY-STAT TTRUE
   FS:STAT-MODE@ $1FF and $180 T=
   l CONFIG:UNLOCK ;

\ The Rust test makes existing.lock by locking it; a plain file stands for
\ it, as the lock file is one.
: LOCK-SYMLINKED ( -- )
   LOCKABLE HELD !
   s" planted.lock" UNDER LOCK-PATH SYMLINK
   ['] LOCK-DROP CONFIG:E-LOCK-OPEN OPEN-TEXT REFUSED
   CAUSE @ 0 T=
   s" planted.lock" UNDER EXISTS? TFALSE
   LOCK-PATH FS:REMOVE-FILE
   s" existing.lock" UNDER s" " FS:WRITE-ALL
   s" existing.lock" UNDER LOCK-PATH SYMLINK
   ['] LOCK-DROP CONFIG:E-LOCK-OPEN OPEN-TEXT REFUSED
   CAUSE @ 0 T= ;

\ A lock's path is its config's LOCK-FILE, so the Rust test's path check
\ is the file's presence. flock(1) contends as the Rust daemon would.
: LOCK-CONTENTION ( -- )
   LOCKABLE HELD !
   HELD-LOCK {: first :}
   ['] LOCK-DROP CONFIG:E-ALREADY-RUNNING
   s" another Omabox daemon is already running" REFUSED
   CAUSE @ 0 T=
   FLOCK-RC 1 T=
   first CONFIG:UNLOCK
   FLOCK-RC 0 T=
   HELD-LOCK {: second :}
   LOCK-PATH EXISTS? TTRUE
   second CONFIG:UNLOCK ;

\ The copy shares the lock's open file description, as a forked child's
\ copy of the descriptor does.
: LOCK-COPY ( -- )
   LOCKABLE HELD !
   HELD-LOCK CONFIG-TEST:LOCK-FD {: first copy:n :}
   copy FD:F-DUPFD-CLOEXEC 0 fcntl {: twin:n :}
   twin 0 >= TTRUE
   first CONFIG:UNLOCK
   HELD-LOCK {: second :}
   FLOCK-RC 1 T=
   twin close
   second CONFIG:UNLOCK ;


\ ---- the failures of prepare and the lock

\ Both targets' fcntl.h.
1 constant F-GETFD

: PREPARE-HELD ( -- ) HELD @ CONFIG:PREPARE ;

: STATE-PATH ( -- str )
   HELD @ CONFIG:PATHS CONFIG:STATE-DIRECTORY CONFIG:ABS-PATH>STR ;

\ The state home made 0555, so its omabox directory cannot be made.
: PREPARE-DENIED ( -- )
   FIXTURE STANDARD
   s" state" UNDER {: home :}
   home MKDIR
   home $16D FS:CHMOD-MODE
   LOAD HELD !
   ['] PREPARE-HELD CONFIG:E-CREATE-DIRECTORY
   s" could not create Omabox state directory at `" STATE-PATH CAT
   s" `" CAT REFUSED
   CAUSE @ FS:EACCES T=
   home $1ED FS:CHMOD-MODE ;

\ LOCK before PREPARE, which makes the state directory.
: LOCK-NO-STATE ( -- )
   FIXTURE STANDARD
   LOAD HELD !
   ['] LOCK-DROP CONFIG:E-LOCK-OPEN OPEN-TEXT REFUSED
   CAUSE @ FS:ENOENT T= ;

\ The lock's descriptor closed under it, then the lock dropped.
: UNLOCK-CLOSED ( -- )
   HELD-LOCK CONFIG-TEST:LOCK-FD close CONFIG:UNLOCK ;

: UNLOCK-WARNS ( -- )
   LOCKABLE HELD !
   ['] UNLOCK-CLOSED LOGGED 0 T=
   s" could not unlock the daemon lock file `" LOCK-PATH CAT
   s" `; closing it instead: " CAT FS:EBADF FS:ERRNO$ CAT {: t :}
   t LINE? t ASSERT-LOG ;

: LOCK-CLOEXEC ( -- )
   LOCKABLE HELD !
   HELD-LOCK CONFIG-TEST:LOCK-FD {: l fd:n :}
   fd F-GETFD 0 fcntl FD:FD-CLOEXEC and FD:FD-CLOEXEC T=
   l CONFIG:UNLOCK ;

: SECURE-DENIED ( -- )
   FS:EPERM FS:CAUSE!
   s" state" P CONFIG-TEST:SECURE-FAILED ;

: SECURE-FAILS ( -- )
   ['] SECURE-DENIED CONFIG:E-SECURE-DIRECTORY
   s" could not secure Omabox state directory at `" s" state" UNDER CAT
   s" `" CAT REFUSED
   CAUSE @ FS:EPERM T= ;

: ACQUIRE-DENIED ( -- )
   FS:EINVAL FS:CAUSE!
   s" daemon.lock" P CONFIG-TEST:ACQUIRE-FAILED ;

: ACQUIRE-FAILS ( -- )
   ['] ACQUIRE-DENIED CONFIG:E-LOCK-ACQUIRE
   s" could not acquire daemon lock on `" s" daemon.lock" UNDER CAT
   s" `" CAT REFUSED
   CAUSE @ FS:EINVAL T= ;

: OPEN-FULL ( -- )
   FS:ENOSPC FS:CAUSE!
   s" daemon.lock" P CONFIG-TEST:OPEN-FAILED ;

\ E-DISK-FULL's help is the failing word's, so only the code is checked.
: OPEN-DISK-FULL ( -- ) ['] OPEN-FULL LOGGED CONFIG:E-DISK-FULL T= ;

: SECURE-FULL ( -- )
   FS:ENOSPC FS:CAUSE!
   s" state" P CONFIG-TEST:SECURE-FAILED ;

: SECURE-DISK-FULL ( -- ) ['] SECURE-FULL LOGGED CONFIG:E-DISK-FULL T= ;


\ ---- config.toml

\ The file is the root's line, then `dropbox_app_key = ` the value's TOML
\ text; the key decodes to the bytes.
: DECODES ( str str -- )
   {: v w :}
   FIXTURE
   ROOT-LINE s" dropbox_app_key = " CAT v CAT s\" \n" CAT WRITE-CONFIG
   DOCUMENT CONFIG:DOCUMENT-KEY w T$= ;

\ The file is before, the root, after; it loads with the root and key k.
: ACCEPTS ( str str -- )
   {: b a :}
   FIXTURE
   b ROOT @ CAT a CAT WRITE-CONFIG
   DOCUMENT {: d :}
   d CONFIG:DOCUMENT-ROOT ROOT @ PATH=
   d CONFIG:DOCUMENT-KEY s" k" T$= ;

\ The file is before, the root, after; its load is refused with the code.
: REFUSES ( str str n -- )
   {: b a code:n :}
   FIXTURE
   b ROOT @ CAT a CAT WRITE-CONFIG
   ['] DOCUMENT-DROP code
   code CONFIG:E-READ = if READ-TEXT else PARSE-TEXT then REFUSED ;

: BASIC ( -- ) s\" \"test-app-key\"" s" test-app-key" DECODES ;
: LITERAL ( -- ) s" 'C:\no\escape'" s" C:\no\escape" DECODES ;
: ML-BASIC ( -- ) s\" \"\"\"\nfirst\nsecond\"\"\"" s\" first\nsecond" DECODES ;
: ML-BACKSLASH ( -- )
   s\" \"\"\"one \\\n    two \\  \n\n  three\"\"\"" s" one two three" DECODES ;
: ML-QUOTES ( -- ) s\" \"\"\"\"quoted\"\"\"\"\"" s\" \"quoted\"\"" DECODES ;
: ML-LITERAL ( -- ) s\" '''\nC:\\path\n'''" s\" C:\\path\n" DECODES ;
: ML-LITERAL-QUOTE ( -- ) s\" '''it's'''''" s" it's''" DECODES ;
: ML-CRLF ( -- ) s\" \"\"\"\r\na\r\nb\"\"\"" s\" a\r\nb" DECODES ;
: ESCAPES ( -- )
   s\" \"\\b\\t\\n\\f\\r\\\"\\\\\\e\"" s\" \x08\x09\x0A\x0C\x0D\x22\x5C\x1B"
   DECODES ;
: HEX-ESCAPES ( -- )
   s\" \"\\x41\\u00E9\\U0001F600\"" s\" A\xC3\xA9\xF0\x9F\x98\x80" DECODES ;
: TAB-IN-BASIC ( -- ) s\" \"a\tb\"" s\" a\tb" DECODES ;

: COMMENTS ( -- )
   s\" # leading\n\n   \nsync_root = \"" s\" \" # the root\ndropbox_app_key = \"k\"# tight\n# last"
   ACCEPTS ;
: CRLF ( -- ) s\" sync_root = \"" s\" \"\r\ndropbox_app_key = \"k\"\r\n" ACCEPTS ;
: WHITESPACE ( -- ) s\" \t sync_root\t=  \"" s\" \"\t\n  dropbox_app_key=\"k\"" ACCEPTS ;
: QUOTED-KEYS ( -- ) s\" 'sync_root' = \"" s\" \"\n\"dropbox_app_key\" = \"k\"\n" ACCEPTS ;
: ESCAPED-KEY ( -- )
   s\" sync_root = \"" s\" \"\n\"dropbox\\u005Fapp_key\" = \"k\"\n" ACCEPTS ;
: BOM ( -- ) s\" \xEF\xBB\xBFsync_root = \"" s\" \"\ndropbox_app_key = \"k\"\n" ACCEPTS ;

: K ( -- str ) s\" \"\ndropbox_app_key = \"k\"\n" ;

: ANOTHER-KEY ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"k\"\nextra = \"x\"\n" CONFIG:E-PARSE REFUSES ;
: TABLE ( -- ) s\" [omabox]\nsync_root = \"" K CONFIG:E-PARSE REFUSES ;
: DOTTED-KEY ( -- ) s\" sync_root.x = \"" K CONFIG:E-PARSE REFUSES ;
: INTEGER ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = 42\n" CONFIG:E-PARSE REFUSES ;
: ARRAY ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = [\"k\"]\n" CONFIG:E-PARSE REFUSES ;
: DUPLICATE ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"k\"\ndropbox_app_key = \"k\"\n" CONFIG:E-PARSE REFUSES ;
: MISSING-KEY ( -- ) s\" sync_root = \"" s\" \"\n" CONFIG:E-PARSE REFUSES ;
: BAD-UTF8 ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"\xFF\"\n" CONFIG:E-READ REFUSES ;
: BAD-ESCAPE ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"\\q\"\n" CONFIG:E-PARSE REFUSES ;
: SURROGATE ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"\\uD800\"\n" CONFIG:E-PARSE REFUSES ;
: CONTROL ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"a\x01\"\n" CONFIG:E-PARSE REFUSES ;
: NEWLINE-IN-BASIC ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"a\nb\"\n" CONFIG:E-PARSE REFUSES ;
: LONE-CR ( -- ) s\" sync_root = \"" s\" \"\rdropbox_app_key = \"k\"\n" CONFIG:E-PARSE REFUSES ;
: SIX-QUOTES ( -- ) s\" sync_root = \"" s\" \"\ndropbox_app_key = \"\"\"a\"\"\"\"\"\"\n" CONFIG:E-PARSE REFUSES ;
: TWO-ON-A-LINE ( -- ) s\" sync_root = \"" s\" \" dropbox_app_key = \"k\"\n" CONFIG:E-PARSE REFUSES ;

: NO-FILE ( -- )
   FIXTURE
   ['] DOCUMENT-DROP CONFIG:E-MISSING READ-TEXT REFUSED
   CAUSE @ FS:ENOENT T= ;

\ The lowest free descriptor.
: NEXT-FD ( -- n )
   s" /dev/null" FS:>PATHZ 0 0 open {: fd:n :}
   fd close fd ;

: CONFIG-DIRECTORY-FILE ( -- )
   FIXTURE
   CONFIG-FILE MKDIR
   NEXT-FD {: free:n :}
   ['] DOCUMENT-DROP CONFIG:E-READ READ-TEXT REFUSED
   CAUSE @ FS:EISDIR T=
   NEXT-FD free T= ;

: RELATIVE-ROOT ( -- )
   FIXTURE
   s\" sync_root = \"Dropbox\"\ndropbox_app_key = \"k\"\n" WRITE-CONFIG
   ['] DOCUMENT-DROP CONFIG:E-PATH-NOT-ABSOLUTE
   s" sync_root must be an absolute path, but was `Dropbox`" REFUSED ;

: NOT-DIRECTORY ( -- )
   FIXTURE
   ROOT @ FS:REMOVE-TREE
   ROOT @ s" " FS:WRITE-ALL
   STANDARD
   ['] LOAD-DROP CONFIG:E-SYNC-ROOT-NOT-DIRECTORY
   s" sync root `" ROOT @ CAT s" ` is not a directory" CAT
   REFUSED ;


\ ---- writing config.toml

: REPLACEMENT ( -- str ) s" Replacement" UNDER ;

\ A config from XDG, the root and the key.
: FROM ( str str -- ^CONFIG:config )
   {: root k :}
   XDG @ root k AR @ CONFIG:FROM-VALUES ;

: NO-LEFTOVERS ( ^VEC:vector<STALE:leftover> -- ) VEC:COUNT 0 T= ;

variable ENTRIES
: COUNT-ENTRY ( str -- ) drop 1 ENTRIES +! ;

: ENTRY-COUNT ( str -- n )
   0 ENTRIES ! [: COUNT-ENTRY ;] FS-LIST:EACH ENTRIES @ ;

4096 constant TEXT-CAP
TEXT-CAP BUFFER: TEXT

\ The bytes of a file, laid in AR.
: CONTENTS ( str -- str )
   TEXT TEXT-CAP FS:READ-ALL {: u:n :}
   TEXT u >str KEEP ;

: WRITE-REPLACES ( -- )
   FIXTURE
   REPLACEMENT MKDIR
   STANDARD
   CONFIG-FILE $1A4 FS:CHMOD-MODE
   REPLACEMENT s" replacement-app-key" FROM {: r :}
   r AR @ CONFIG:WRITE NO-LEFTOVERS
   CONFIG-FILE CONFIG:>ABS-PATH MODE $180 T=
   LOAD {: c :}
   c CONFIG:SYNC-ROOT r CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR PATH=
   c CONFIG:APP-KEY r CONFIG:APP-KEY T$=
   c CONFIG:PATHS r CONFIG:PATHS SAME-PATHS
   CONFIG-DIR ENTRY-COUNT 1 T= ;

: NEW-AGAIN ( -- ) HELD @ AR @ CONFIG:WRITE-NEW drop ;

\ Also checks that the refused write left no temporary.
: WRITE-NEW-KEEPS ( -- )
   FIXTURE
   REPLACEMENT MKDIR
   ROOT @ s" existing-app-key" FROM AR @ CONFIG:WRITE-NEW NO-LEFTOVERS
   CONFIG-FILE CONTENTS {: original :}
   REPLACEMENT s" replacement-app-key" FROM HELD !
   ['] NEW-AGAIN CONFIG:E-ALREADY-EXISTS
   s" Omabox configuration already exists at `" CONFIG-FILE CAT
   s" `" CAT REFUSED
   CONFIG-FILE CONTENTS original T$=
   CONFIG-DIR ENTRY-COUNT 1 T= ;

\ The offset past the line that starts at or after at.
: PAST-LINE ( n -- n )
   {: at:n :}
   ERR-U @ at ?do ERR @ i + c@ 10 = if i 1+ unloop exit then loop
   ERR-U @ ;

\ ERR$'s line k, its newline included.
: LINE-AT ( n -- str )
   {: k:n :}
   0 k 0 ?do PAST-LINE loop {: s:n :}
   s PAST-LINE {: e:n :}
   ERR @ s + e s - >str ;

: LINE-IS ( n str -- )
   {: k:n t :}
   k LINE-AT t ENDS? t ASSERT-LOG ;

: CLEANUP-FAILS ( -- )
   s" /config.tmp" CONFIG:>ABS-PATH CONFIG-TEST:CLEANUP-FAILS ;

\ Both failures are writes, so both helps are the same text.
: CLEANUP-RENDERS ( -- )
   ['] CLEANUP-FAILS LOGGED CONFIG:E-CLEANUP-AFTER-WRITE T=
   CAUSE @ FS:EPERM T=
   ERR$ LINES 4 T=
   0 s" could not write a temporary Omabox configuration at `/config.tmp`"
   LINE-IS
   s" help: " CONFIG:E-WRITE HELP$ CAT {: h :}
   1 h LINE-IS
   s" the configuration write failed and cleanup also failed: "
   s" could not remove the temporary Omabox configuration at" CAT
   s"  `/config.tmp`; the incomplete owner-only temporary file is" CAT
   s"  ignored" CAT {: c :}
   2 c LINE-IS
   3 h LINE-IS ;

\ The decimal at the start of a u.
: LEADING ( str -- n )
   str> {: a:^ u:n :}
   0 u 0 ?do
      a i + c@ {: b:n :}
      b [char] 0 < b [char] 9 > or if unloop exit then
      10 * b [char] 0 - +
   loop ;

: PID-MAX ( -- n )
   s" /proc/sys/kernel/pid_max" CONTENTS LEADING ;

: N$ ( n -- str ) FMT:INT$ KEEP ;

\ CONFIG-DIR/.config.toml.<t>
: TEMPORARY ( str -- str )
   {: t :}
   CONFIG-DIR s" /.config.toml." CAT t CAT ;

: LSTAT? ( str -- bool ) FS:TRY-LSTAT ;

\ The config half of install.rs's
\ upgrade_and_config_write_sweep_only_dead_temporaries: no process has a
\ PID above pid_max.
: SWEEPS-DEAD ( -- )
   FIXTURE
   PID-MAX 1 + N$ {: dead :}
   s" outside-file" UNDER {: outside :}
   outside s" outside" FS:WRITE-ALL
   dead s" .0.tmp" CAT TEMPORARY {: file :}
   dead s" .1.tmp" CAT TEMPORARY {: link :}
   getpid N$ s" .999999999.tmp" CAT TEMPORARY {: live :}
   dead s" .0" CAT TEMPORARY {: miss :}
   file s" stale" FS:WRITE-ALL
   live s" stale" FS:WRITE-ALL
   miss s" stale" FS:WRITE-ALL
   outside link SYMLINK
   ROOT @ s" test-app-key" FROM AR @ CONFIG:WRITE NO-LEFTOVERS
   file LSTAT? TFALSE
   link LSTAT? TFALSE
   live LSTAT? TTRUE
   miss LSTAT? TTRUE
   outside CONTENTS s" outside" T$= ;

\ `"`, `\` and `'` rule out every form toml_writer prefers to a
\ multi-line literal string.
: AWKWARD ( -- str ) s\" a\"b\\c'd\xC3\xA9" ;

: WRITES-TOML ( -- )
   FIXTURE
   AWKWARD UNDER {: root :}
   root MKDIR
   root s" test-app-key" FROM AR @ CONFIG:WRITE NO-LEFTOVERS
   s" sync_root = '''" REAL @ CAT s" /" CAT AWKWARD CAT
   s\" '''\ndropbox_app_key = \"test-app-key\"\n" CAT {: want :}
   CONFIG-FILE CONTENTS want T$=
   LOAD {: c :}
   c CONFIG:SYNC-ROOT AWKWARD REAL-UNDER PATH=
   c CONFIG:APP-KEY s" test-app-key" T$= ;

public

: RUN ( -- )
   T-RESET
   s" config_resolves_xdg_paths_and_prepares_state" ['] RESOLVES-XDG-PATHS RUN-CASE
   s" document_loads_when_the_recorded_root_is_unavailable" ['] ROOT-UNAVAILABLE RUN-CASE
   s" prepare_creates_private_runtime_directories" ['] PREPARE-CREATES RUN-CASE
   s" prepare_repairs_broad_runtime_directory_permissions" ['] PREPARE-REPAIRS RUN-CASE
   s" config_rejects_state_inside_sync_root" ['] STATE-INSIDE RUN-CASE
   s" config_rejects_symlinked_state_inside_sync_root" ['] SYMLINKED-STATE RUN-CASE
   s" config_rejects_dangling_state_symlink_into_sync_root_without_creating_target"
   ['] DANGLING-STATE RUN-CASE
   s" relinked_runtime_leaves_are_projected_individually" ['] RELINKED-LEAVES RUN-CASE
   s" projection_follows_a_dangling_absolute_symlink" ['] FOLLOWS-ABSOLUTE RUN-CASE
   s" projection_follows_a_dangling_relative_symlink" ['] FOLLOWS-RELATIVE RUN-CASE
   s" projection_leaves_a_missing_component_on_parent" ['] MISSING-ON-PARENT RUN-CASE
   s" projection_refuses_a_symlink_loop" ['] SYMLINK-LOOP RUN-CASE
   s" refusing_projection_fails_on_a_dangling_symlink" ['] REFUSES-DANGLING RUN-CASE
   s" prepare_refuses_state_below_a_dangling_root_target"
   ['] DANGLING-ROOT-TARGET RUN-CASE
   s" config_rejects_sync_root_containing_the_config_directory"
   ['] ROOT-HOLDS-CONFIG RUN-CASE
   s" config_rejects_a_lock_symlinked_into_the_sync_root" ['] LOCK-INSIDE RUN-CASE
   s" config_errors_preserve_sources_and_reject_unknown_fields" ['] UNKNOWN-FIELDS RUN-CASE
   s" config_rejects_empty_app_key_without_rendering_other_values" ['] EMPTY-KEY RUN-CASE
   s" xdg_empty_values_use_home_defaults" ['] EMPTY-VALUES RUN-CASE
   s" xdg_relative_values_use_home_defaults" ['] RELATIVE-VALUES RUN-CASE
   s" xdg_absolute_values_do_not_require_home" ['] ABSOLUTE-VALUES RUN-CASE
   s" no HOME" ['] HOME-MISSING RUN-CASE
   s" daemon_lock_file_is_created_for_its_owner_only" ['] LOCK-OWNER-ONLY RUN-CASE
   s" daemon_lock_refuses_a_symlinked_lock_file" ['] LOCK-SYMLINKED RUN-CASE
   s" lock_contention_is_clean_and_release_is_automatic" ['] LOCK-CONTENTION RUN-CASE
   s" dropping_the_lock_releases_it_while_a_descriptor_copy_is_open"
   ['] LOCK-COPY RUN-CASE
   s" prepare under a read-only state home" ['] PREPARE-DENIED RUN-CASE
   s" a lock with no state directory" ['] LOCK-NO-STATE RUN-CASE
   s" an unlock of a closed descriptor" ['] UNLOCK-WARNS RUN-CASE
   s" a close-on-exec lock descriptor" ['] LOCK-CLOEXEC RUN-CASE
   s" a directory that cannot be secured" ['] SECURE-FAILS RUN-CASE
   s" a lock that cannot be acquired" ['] ACQUIRE-FAILS RUN-CASE
   s" a lock file on a full disk" ['] OPEN-DISK-FULL RUN-CASE
   s" a directory secured on a full disk" ['] SECURE-DISK-FULL RUN-CASE
   s" a basic string" ['] BASIC RUN-CASE
   s" a literal string" ['] LITERAL RUN-CASE
   s" a multi-line basic string" ['] ML-BASIC RUN-CASE
   s" line-ending backslashes" ['] ML-BACKSLASH RUN-CASE
   s" quotes before a multi-line basic close" ['] ML-QUOTES RUN-CASE
   s" a multi-line literal string" ['] ML-LITERAL RUN-CASE
   s" quotes before a multi-line literal close" ['] ML-LITERAL-QUOTE RUN-CASE
   s" CRLF inside a multi-line string" ['] ML-CRLF RUN-CASE
   s" the one-letter escapes" ['] ESCAPES RUN-CASE
   s" the hex escapes" ['] HEX-ESCAPES RUN-CASE
   s" a tab in a basic string" ['] TAB-IN-BASIC RUN-CASE
   s" comments and blank lines" ['] COMMENTS RUN-CASE
   s" CRLF line ends" ['] CRLF RUN-CASE
   s" whitespace" ['] WHITESPACE RUN-CASE
   s" quoted keys" ['] QUOTED-KEYS RUN-CASE
   s" an escaped key" ['] ESCAPED-KEY RUN-CASE
   s" a BOM" ['] BOM RUN-CASE
   s" another key" ['] ANOTHER-KEY RUN-CASE
   s" a table" ['] TABLE RUN-CASE
   s" a dotted key" ['] DOTTED-KEY RUN-CASE
   s" an integer value" ['] INTEGER RUN-CASE
   s" an array value" ['] ARRAY RUN-CASE
   s" a duplicate key" ['] DUPLICATE RUN-CASE
   s" a missing key" ['] MISSING-KEY RUN-CASE
   s" bad UTF-8" ['] BAD-UTF8 RUN-CASE
   s" a bad escape" ['] BAD-ESCAPE RUN-CASE
   s" a surrogate escape" ['] SURROGATE RUN-CASE
   s" a control character" ['] CONTROL RUN-CASE
   s" a newline in a basic string" ['] NEWLINE-IN-BASIC RUN-CASE
   s" a lone CR" ['] LONE-CR RUN-CASE
   s" six closing quotes" ['] SIX-QUOTES RUN-CASE
   s" two keys on a line" ['] TWO-ON-A-LINE RUN-CASE
   s" no config.toml" ['] NO-FILE RUN-CASE
   s" config.toml a directory" ['] CONFIG-DIRECTORY-FILE RUN-CASE
   s" a relative root" ['] RELATIVE-ROOT RUN-CASE
   s" a root that is a file" ['] NOT-DIRECTORY RUN-CASE
   s" config_write_atomically_replaces_with_owner_only_file"
   ['] WRITE-REPLACES RUN-CASE
   s" initial_config_write_never_replaces_an_existing_file"
   ['] WRITE-NEW-KEEPS RUN-CASE
   s" cleanup_after_write_renders_both_chains_and_both_helps"
   ['] CLEANUP-RENDERS RUN-CASE
   s" upgrade_and_config_write_sweep_only_dead_temporaries"
   ['] SWEEPS-DEAD RUN-CASE
   s" a sync root toml_writer writes as a multi-line literal"
   ['] WRITES-TOML RUN-CASE
   s" config-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

CONFIG-TEST:RUN
