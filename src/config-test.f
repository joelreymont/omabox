\ config-test.f - CONFIG against the Rust version's config.rs tests of what
\ it ports, under their names: the XDG paths, the private paths and their
\ symlink projection, the sync root's checks, the refusals of a config
\ that names a protected path inside it, the prepared directories and the
\ daemon lock, contended in this process and by util-linux's flock(1)
\ through /usr/bin/flock. Then config.toml as the toml crate
\ reads it: each string form, each escape, comments, whitespace, CRLF, a
\ BOM and quoted keys, and each refusal with the code the Rust error maps
\ to. Every case runs in a directory of its own under TMPDIR, sets its own
\ XDG and HOME values and removes the directory after. CONFIG's log lines
\ go to stderr, but those a case checks, which are captured in the case's
\ directory, checked and removed. White-box: CONFIG is reopened for the
\ private words a Rust test calls.
\ Run from the repository root: hb --load src/config-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/memory.f
require src/lib/adt/option.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/lib/process.f
require src/config.f

package CONFIG-TEST
;package


\ CONFIG reopened for project_physical_path, resolve_xdg_directories,
\ the XDG fields, fs::canonicalize, Paths::prepare and a lock's descriptor.
\ Each name lands in CONFIG-TEST, so CONFIG gains none.
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

: CONFIG-TEST:CONFIG-HOME ( ^xdg -- abs-path ) XDG-CONFIG-HOME @ ;
: CONFIG-TEST:STATE-HOME ( ^xdg -- abs-path ) XDG-STATE-HOME @ ;

\ application_state_directory.
: CONFIG-TEST:STATE-APP ( ^xdg ^ARENA:arena -- abs-path ) XDG-STATE-DIRECTORY ;

: CANON-FAILED ( -- ) E-INSPECT-PATH throw ;

: CONFIG-TEST:CANON ( str ^ARENA:arena -- abs-path )
   CANONICAL MATCH option
      some OF ENDOF
      none OF CANON-FAILED ENDOF
   ;MATCH ;

: CONFIG-TEST:PREPARE-PATHS ( ^paths abs-path ^ARENA:arena -- )
   PREPARE-PATHS ;

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
create ERR 1024 allot
variable ERR-U
\ FS:ERRNO as the logged action left it.
variable CAUSE


\ ---- strings and paths, laid in the case's arena

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

\ DIR/name and REAL/name.
: UNDER ( ^u8 n -- str )
   {: n:^ u:n :}
   DIR @ s" /" S+ n u S+ ;

: REAL-UNDER ( ^u8 n -- str )
   {: n:^ u:n :}
   REAL @ s" /" S+ n u S+ ;

: P ( ^u8 n -- CONFIG:abs-path ) UNDER CONFIG:>ABS-PATH ;

: MKDIR ( str -- ) str> FS:MAKE-DIR ;
: MKDIRS ( str -- ) str> FS:MAKE-DIRS ;
: SYMLINK ( str str -- ) {: target link :} target str> link str> FS:MAKE-SYMLINK ;
: EXISTS? ( str -- bool ) str> FS:TRY-STAT ;
: DIRECTORY? ( CONFIG:abs-path -- bool ) CONFIG:ABS-PATH>STR str> FS:DIR? ;

\ The permission bits of the entry a path names, links followed.
: MODE ( CONFIG:abs-path -- n )
   CONFIG:ABS-PATH>STR str> FS:TRY-STAT TTRUE
   FS:STAT-MODE@ $1FF and ;

: PATH= ( CONFIG:abs-path str -- )
   {: p s :}
   p CONFIG:ABS-PATH>STR str> s str> T$= ;

: CONTAINS? ( ^u8 n ^u8 n -- bool )
   {: a:^ u:n t:^ tu:n :}
   tu u > if false exit then
   u tu - 1+ 0 ?do
      a i + tu t tu T-STR= if true unloop exit then
   loop false ;


\ ---- the case's frame

: CLEANUP ( -- )
   DIR @ str> FS:REMOVE-TREE
   AR @ ARENA:RELEASE ;

\ Runs the body with AR, DIR and REAL fresh; the directory goes after.
: RUN-CASE ( ^u8 n [ -- ] -- )
   BODY ! T-LABEL
   ARENA:NEW AR !
   s" TMPDIR" GETENV s" config-test-" FS:MKTEMP-DIR-IN KEEP DIR !
   DIR @ AR @ CONFIG-TEST:CANON CONFIG:ABS-PATH>STR REAL !
   [: BODY @ execute ;] [: CLEANUP ;] finally ;


\ ---- the log a refusal writes

: ERR$ ( -- ^u8 n ) ERR ERR-U @ ;
: ERR-PATH ( -- str ) s" stderr.txt" UNDER ;

\ The code the action throws, 0 for none, with fd 2 sent to the case's
\ stderr.txt, which ERR$ then holds and which is removed.
: LOGGED ( [ -- ] -- n )
   ACTION !
   ERR-PATH str> STDERR:CAPTURE
   [: ACTION @ catch FS:ERRNO CAUSE ! ;] [: STDERR:;CAPTURE ;] finally
   ERR-PATH str> ERR 1024 FS:READ-ALL ERR-U !
   ERR-PATH str> FS:REMOVE-FILE ;

: LINES ( ^u8 n -- n )
   {: a:^ u:n :}
   0 u 0 ?do a i + c@ 10 = if 1+ then loop ;

\ ERR$ is one line that ends in CONFIG's tag and the text.
: LINE? ( str -- bool )
   {: t :}
   s" config: " >str t CAT s\" \n" S+ str> {: w:^ wu:n :}
   ERR$ LINES 1 <> if false exit then
   ERR-U @ wu < if false exit then
   ERR ERR-U @ wu - + wu w wu T-STR= ;

\ The action throws the code and logs the line.
: REFUSED ( [ -- ] n str -- )
   {: xt want:n t :}
   xt LOGGED want T=
   t LINE? dup T-ASSERT 0= if
      s" want: " type t str> type cr s" got: " type ERR$ type
   then ;


\ ---- the Rust fixture

\ DIR/Dropbox made, XDG over DIR/config and DIR/state, DIR/config/omabox made.
: FIXTURE ( -- )
   s" Dropbox" UNDER ROOT !
   ROOT @ MKDIR
   s" config" P s" state" P AR @ CONFIG:XDG-NEW XDG !
   s" config/omabox" UNDER MKDIRS ;

: XDG-AT ( ^u8 n ^u8 n -- )
   {: c:^ cu:n s:^ su:n :}
   c cu P s su P AR @ CONFIG:XDG-NEW XDG ! ;

: XDG-LINKED ( ^u8 n str -- )
   {: c:^ cu:n s :}
   c cu P s CONFIG:>ABS-PATH AR @ CONFIG:XDG-NEW XDG ! ;

: CONFIG-FILE ( -- str ) XDG @ AR @ CONFIG:XDG-CONFIG-FILE CONFIG:ABS-PATH>STR ;
: CONFIG-DIR ( -- str ) XDG @ AR @ CONFIG:RESOLVE-PRIVATE CONFIG:CONFIG-DIRECTORY CONFIG:ABS-PATH>STR ;
: STATE-APP ( -- str ) XDG @ AR @ CONFIG-TEST:STATE-APP CONFIG:ABS-PATH>STR ;

: WRITE-CONFIG ( str -- ) {: t :} CONFIG-FILE str> t str> FS:WRITE-ALL ;

: ROOT-LINE ( -- str ) s\" sync_root = \"" >str ROOT @ CAT s\" \"\n" S+ ;

\ write_config: the root and test-app-key.
: STANDARD ( -- )
   ROOT-LINE s\" dropbox_app_key = \"test-app-key\"\n" S+ WRITE-CONFIG ;

: LOAD ( -- ^CONFIG:config ) XDG @ AR @ CONFIG:LOAD-FROM ;
: LOAD-DROP ( -- ) LOAD drop ;
: DOCUMENT ( -- ^CONFIG:document ) XDG @ AR @ CONFIG:DOCUMENT-LOAD-FROM ;
: DOCUMENT-DROP ( -- ) DOCUMENT drop ;

: PARSE-TEXT ( -- str )
   s" could not parse Omabox configuration at `" >str CONFIG-FILE CAT s" `" S+ ;

: READ-TEXT ( -- str )
   s" could not read Omabox configuration at `" >str CONFIG-FILE CAT s" `" S+ ;

\ "<role> `<path>` must not be inside sync root `<root>`".
: INSIDE-TEXT ( ^u8 n str str -- str )
   {: r:^ ru:n p root :}
   r ru >str s"  `" S+ p CAT s" ` must not be inside sync root `" S+
   root CAT s" `" S+ ;

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
   c CONFIG:APP-KEY str> s" test-app-key" T$=
   p CONFIG:JOURNAL-FILE s" state" UNDER AR @ CONFIG-TEST:CANON
   CONFIG:ABS-PATH>STR s" /omabox/journal.sqlite3" S+ PATH=
   p CONFIG:UPLOAD-STAGING-DIRECTORY DIRECTORY? TTRUE
   p CONFIG:RECOVERY-DIRECTORY DIRECTORY? TTRUE
   p CONFIG:JOURNAL-FILE CONFIG:ABS-PATH>STR EXISTS? TFALSE ;

: ROOT-UNAVAILABLE ( -- )
   FIXTURE STANDARD
   LOAD {: available :}
   ROOT @ str> FS:REMOVE-TREE
   ['] LOAD-DROP CONFIG:E-RESOLVE-SYNC-ROOT
   s" could not resolve sync root `" >str ROOT @ CAT s" `" S+ REFUSED
   CAUSE @ FS:ENOENT T=
   DOCUMENT {: d :}
   d CONFIG:DOCUMENT-ROOT ROOT @ PATH=
   d CONFIG:DOCUMENT-KEY str> s" test-app-key" T$=
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
   s" could not inspect `" >str s" dangling-state-link" UNDER CAT
   s" ` while validating configuration paths" S+ REFUSED
   s" Dropbox/not-yet-existing-state" UNDER EXISTS? TFALSE ;

\ Its loading half: the Rust test then prepares, which leaves the path.
: RELINKED-LEAVES ( -- )
   FIXTURE
   s" elsewhere" UNDER MKDIR
   STATE-APP MKDIRS
   s" elsewhere" UNDER STATE-APP s" /upload-staging" S+ SYMLINK
   STANDARD
   LOAD CONFIG:PATHS CONFIG:UPLOAD-STAGING-DIRECTORY
   s" elsewhere" REAL-UNDER PATH= ;

: FOLLOWS-ABSOLUTE ( -- )
   s" data/sub" UNDER s" link" UNDER SYMLINK
   s" link/leaf" P AR @ CONFIG-TEST:FOLLOW s" data/sub/leaf" REAL-UNDER PATH= ;

: FOLLOWS-RELATIVE ( -- )
   s" links" UNDER MKDIR
   s" ../data/sub" >str s" links/link" UNDER SYMLINK
   s" links/link/leaf" P AR @ CONFIG-TEST:FOLLOW
   s" data/sub/leaf" REAL-UNDER PATH= ;

: MISSING-ON-PARENT ( -- )
   s" links" UNDER MKDIR
   s" ../missing/../data" >str s" links/link" UNDER SYMLINK
   s" links/link/leaf" P AR @ CONFIG-TEST:FOLLOW s" data/leaf" REAL-UNDER PATH=
   s" missing/../data/leaf" P AR @ CONFIG-TEST:REFUSE
   s" data/leaf" REAL-UNDER PATH= ;

: FOLLOW-FIRST ( -- ) s" first" P AR @ CONFIG-TEST:FOLLOW drop ;

: SYMLINK-LOOP ( -- )
   s" second" UNDER s" first" UNDER SYMLINK
   s" first" UNDER s" second" UNDER SYMLINK
   ['] FOLLOW-FIRST CONFIG:E-INSPECT-PATH
   s" could not inspect `" >str s" first" UNDER CAT
   s" ` while validating configuration paths" S+ REFUSED
   CAUSE @ FS:ELOOP T= ;

: REFUSE-LEAF ( -- ) s" link/leaf" P AR @ CONFIG-TEST:REFUSE drop ;

: REFUSES-DANGLING ( -- )
   s" data" UNDER s" link" UNDER SYMLINK
   ['] REFUSE-LEAF CONFIG:E-INSPECT-PATH
   s" could not inspect `" >str s" link" UNDER CAT
   s" ` while validating configuration paths" S+ REFUSED ;

: FROM-ROOT ( -- ) XDG @ ROOT @ CONFIG:>ABS-PATH s" test-app-key" >str AR @ CONFIG:FROM-VALUES drop ;

\ The Rust test also checks the miette help, "Set XDG_CONFIG_HOME to a
\ local directory outside the sync root."; CONFIG ports no help, so the
\ line's role stands for it.
: ROOT-HOLDS-CONFIG ( -- )
   s" Dropbox" UNDER ROOT !
   ROOT @ MKDIR
   s" Dropbox" s" state" XDG-AT
   ['] FROM-ROOT CONFIG:E-INSIDE-SYNC-ROOT
   s" configuration directory" s" Dropbox/omabox" UNDER
   s" Dropbox" REAL-UNDER INSIDE-TEXT REFUSED ;

\ As ROOT-HOLDS-CONFIG, the help (XDG_STATE_HOME) is not ported.
: LOCK-INSIDE ( -- )
   FIXTURE
   s" Dropbox/stolen.lock" UNDER str> s" " FS:WRITE-ALL
   STATE-APP MKDIRS
   s" Dropbox/stolen.lock" UNDER STATE-APP s" /daemon.lock" S+ SYMLINK
   STANDARD
   ['] LOAD-DROP CONFIG:E-INSIDE-SYNC-ROOT
   s" daemon lock" s" Dropbox/stolen.lock" REAL-UNDER
   s" Dropbox" REAL-UNDER INSIDE-TEXT REFUSED ;

: UNKNOWN-FIELDS ( -- )
   FIXTURE
   ROOT-LINE s\" refresh_token = \"credential-sentinel-must-never-render\"\n" S+
   WRITE-CONFIG
   ['] LOAD-DROP CONFIG:E-PARSE PARSE-TEXT REFUSED
   ERR$ s" credential-sentinel-must-never-render" CONTAINS? TFALSE ;

: EMPTY-KEY ( -- )
   FIXTURE
   s" local-path-sentinel" UNDER ROOT !
   ROOT @ MKDIR
   ROOT-LINE s\" dropbox_app_key = \"  \"\n" S+ WRITE-CONFIG
   ['] LOAD-DROP CONFIG:E-EMPTY-APP-KEY
   s" Dropbox application key is empty" >str REFUSED
   ERR$ s" local-path-sentinel" CONTAINS? TFALSE ;

: SOME ( str -- option<str> ) OPTION:SOME ;

: EMPTY-VALUES ( -- )
   DIR @ SOME s" " >str SOME s" " >str SOME AR @ CONFIG-TEST:RESOLVE {: x :}
   x CONFIG-TEST:CONFIG-HOME s" .config" UNDER PATH=
   x CONFIG-TEST:STATE-HOME s" .local/state" UNDER PATH= ;

: RELATIVE-VALUES ( -- )
   DIR @ SOME s" relative-config" >str SOME s" relative-state" >str SOME
   AR @ CONFIG-TEST:RESOLVE {: x :}
   x CONFIG-TEST:CONFIG-HOME s" .config" UNDER PATH=
   x CONFIG-TEST:STATE-HOME s" .local/state" UNDER PATH= ;

: ABSOLUTE-VALUES ( -- )
   CONFIG-TEST:ABSENT s" /configured/config" >str SOME
   s" /configured/state" >str SOME AR @ CONFIG-TEST:RESOLVE {: x :}
   x CONFIG-TEST:CONFIG-HOME s" /configured/config" >str PATH=
   x CONFIG-TEST:STATE-HOME s" /configured/state" >str PATH= ;


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
   a u FS:MAKE-DIRS
   a u $1FF FS:CHMOD-MODE ;

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
   SET @ ROOT @ CONFIG:>ABS-PATH AR @ CONFIG-TEST:PREPARE-PATHS ;

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
: LOCK-DROP ( -- ) HELD @ CONFIG:LOCK CONFIG:UNLOCK ;

: OPEN-TEXT ( -- str )
   s" could not open daemon lock file `" >str LOCK-PATH CAT s" `" S+ ;

\ The exit code of `flock -n LOCK-PATH true`: 1 while the lock is held.
: FLOCK-RC ( -- n )
   s" /usr/bin/flock" PROCESS:NEW s" -n" PROCESS:ARG
   LOCK-PATH str> PROCESS:ARG s" true" PROCESS:ARG
   PROCESS:SPAWN PROCESS:WAIT PROCESS:STATUS>RC RC>N ;

: LOCK-OWNER-ONLY ( -- )
   LOCKABLE HELD !
   HELD @ CONFIG:LOCK {: l :}
   LOCK-PATH str> FS:TRY-STAT TTRUE
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
   LOCK-PATH str> FS:REMOVE-FILE
   s" existing.lock" UNDER str> s" " FS:WRITE-ALL
   s" existing.lock" UNDER LOCK-PATH SYMLINK
   ['] LOCK-DROP CONFIG:E-LOCK-OPEN OPEN-TEXT REFUSED
   CAUSE @ 0 T= ;

\ A lock's path is its config's LOCK-FILE, so the Rust test's path check
\ is the file's presence. flock(1) contends as the Rust daemon would.
: LOCK-CONTENTION ( -- )
   LOCKABLE HELD !
   HELD @ CONFIG:LOCK {: first :}
   ['] LOCK-DROP CONFIG:E-ALREADY-RUNNING
   s" another Omabox daemon is already running" >str REFUSED
   CAUSE @ 0 T=
   FLOCK-RC 1 T=
   first CONFIG:UNLOCK
   FLOCK-RC 0 T=
   HELD @ CONFIG:LOCK {: second :}
   LOCK-PATH EXISTS? TTRUE
   second CONFIG:UNLOCK ;

\ The copy shares the lock's open file description, as a forked child's
\ copy of the descriptor does.
: LOCK-COPY ( -- )
   LOCKABLE HELD !
   HELD @ CONFIG:LOCK CONFIG-TEST:LOCK-FD {: first copy:n :}
   copy FD:F-DUPFD-CLOEXEC 0 fcntl {: twin:n :}
   twin 0 >= TTRUE
   first CONFIG:UNLOCK
   HELD @ CONFIG:LOCK {: second :}
   FLOCK-RC 1 T=
   twin close
   second CONFIG:UNLOCK ;


\ ---- config.toml

\ The file is the root's line, then `dropbox_app_key = ` the value's TOML
\ text; the key decodes to the bytes.
: DECODES ( ^u8 n ^u8 n -- )
   {: v:^ vu:n w:^ wu:n :}
   FIXTURE
   ROOT-LINE s" dropbox_app_key = " S+ v vu S+ s\" \n" S+ WRITE-CONFIG
   DOCUMENT CONFIG:DOCUMENT-KEY str> w wu T$= ;

\ The file is before, the root, after; it loads with the root and key k.
: ACCEPTS ( ^u8 n ^u8 n -- )
   {: b:^ bu:n a:^ au:n :}
   FIXTURE
   b bu >str ROOT @ CAT a au S+ WRITE-CONFIG
   DOCUMENT {: d :}
   d CONFIG:DOCUMENT-ROOT ROOT @ PATH=
   d CONFIG:DOCUMENT-KEY str> s" k" T$= ;

\ The file is before, the root, after; its load is refused with the code.
: REFUSES ( ^u8 n ^u8 n n -- )
   {: b:^ bu:n a:^ au:n code:n :}
   FIXTURE
   b bu >str ROOT @ CAT a au S+ WRITE-CONFIG
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

: K ( -- ^u8 n ) s\" \"\ndropbox_app_key = \"k\"\n" ;

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
   ['] DOCUMENT-DROP CONFIG:E-READ READ-TEXT REFUSED
   CAUSE @ FS:ENOENT T= ;

: RELATIVE-ROOT ( -- )
   FIXTURE
   s\" sync_root = \"Dropbox\"\ndropbox_app_key = \"k\"\n" >str WRITE-CONFIG
   ['] DOCUMENT-DROP CONFIG:E-PATH-NOT-ABSOLUTE
   s" sync_root must be an absolute path, but was `Dropbox`" >str REFUSED ;

: NOT-DIRECTORY ( -- )
   FIXTURE
   ROOT @ str> FS:REMOVE-TREE
   ROOT @ str> s" " FS:WRITE-ALL
   STANDARD
   ['] LOAD-DROP CONFIG:E-SYNC-ROOT-NOT-DIRECTORY
   s" sync root `" >str s" Dropbox" REAL-UNDER CAT s" ` is not a directory" S+
   REFUSED ;

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
   s" daemon_lock_file_is_created_for_its_owner_only" ['] LOCK-OWNER-ONLY RUN-CASE
   s" daemon_lock_refuses_a_symlinked_lock_file" ['] LOCK-SYMLINKED RUN-CASE
   s" lock_contention_is_clean_and_release_is_automatic" ['] LOCK-CONTENTION RUN-CASE
   s" dropping_the_lock_releases_it_while_a_descriptor_copy_is_open"
   ['] LOCK-COPY RUN-CASE
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
   s" a relative root" ['] RELATIVE-ROOT RUN-CASE
   s" a root that is a file" ['] NOT-DIRECTORY RUN-CASE
   s" config-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

CONFIG-TEST:RUN
