\ journal-test.f - JOURNAL's open, schema 8, bindings, baselines and plans
\ on journals under TMPDIR: a new journal's sqlite_master and user_version
\ against src/oracle/schema.tsv as a set; versions 1, 7 and 9 refused
\ unchanged; src/oracle/journal.sqlite3, copied and opened, giving
\ journal.tsv's Dropbox and local root bindings, baselines, baseline
\ paths, pending and blocked plans and pending upload content; and
\ twenty-four tests of the Rust version (rust src/journal.rs)
\ under their names, which build each decision the Rust ones ask the
\ planner for as src/oracle/plan.tsv holds it. Habu opens no schema-6
\ file, so the version-six tests start from a schema-8 journal holding the
\ row migration 7 leaves for a schema-6 root, birth and subvolume NULL,
\ and one baseline row; their inventory and conflict halves wait for the
\ words that write those. Each case removes its directory; a refusal's
\ log line is captured in it, checked and removed.
\ Run from the repository root: hb --load src/journal-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fs-statx.f
require src/lib/sqlite.f
require src/lib/vector.f
require src/model.f
require src/journal.f

\ JOURNAL reopened: a case reads the journal's connection, its rows and
\ the bindings' fields.
package JOURNAL
private

8192 constant CAP
CAP BUFFER: BODY       \ an oracle file, after a newline
CAP BUFFER: LINE       \ a line looked for in BODY
CAP BUFFER: WANT       \ a binding as the Rust version prints it
CAP BUFFER: ERR        \ a captured log
variable BODY-U
$1A4 constant MODE-SHARED

TYPED-VARIABLE ACTION [ -- ]
TYPED-VARIABLE SUBJECT str


\ ---- a case's directory ------------------------------------------

: SCRATCH ( ^ARENA:arena -- str )
   {: ar :}
   s" journal-test" FS:MKTEMP-DIR ar COPIED ;


\ dir/name.
: INSIDE ( str ^u8 n ^ARENA:arena -- str )
   {: d:str a:^ u ar :}
   d str> {: p:^ pu :}
   ar pu u + 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst pu BYTE-COPY
   47 dst pu + c!
   a dst pu + 1+ u BYTE-COPY
   dst pu u + 1+ >str ;


\ A case's directory and the journal path in it.
: JOURNAL-AT ( ^ARENA:arena -- str str )
   {: ar :}
   ar SCRATCH {: d:str :}
   d d s" journal.sqlite3" ar INSIDE ;


: GONE ( str -- ) str> FS:REMOVE-TREE ;

: MODE-OF ( str -- n ) str> FS:STAT-MODE MODE-BITS and ;


\ The action throws want with fd 2 sent to dir/stderr.txt, which then
\ holds one line with the text and is removed.
: LOGGED ( [ -- ] n str ^u8 n ^ARENA:arena -- )
   {: want dir:str t:^ tu ar :}
   ACTION !
   dir s" stderr.txt" ar INSIDE {: f:str :}
   f str> STDERR:CAPTURE
   [: ACTION @ want TTHROWSQ ;] [: STDERR:;CAPTURE ;] finally
   f str> ERR CAP FS:READ-ALL {: u :}
   f str> FS:REMOVE-FILE
   ERR u 10 COUNT-CHAR 1 T=
   ERR u t tu CONTAINS? TTRUE ;


\ ---- the oracle files --------------------------------------------

\ BODY holds a newline, then the file at path.
: ORACLE ( ^u8 n -- )
   {: a:^ u :}
   10 BODY c!
   a u BODY 1+ CAP 1- FS:READ-ALL 1+ BODY-U ! ;


\ BODY holds the text as a whole line.
: HELD? ( ^u8 n -- bool )
   {: a:^ u :}
   10 LINE c!
   a LINE 1+ u BYTE-COPY
   10 LINE u + 1+ c!
   BODY BODY-U @ LINE u 2 + CONTAINS? ;


: PUT ( ^u8 n n -- n )
   {: a:^ u at :}
   a WANT at + u BYTE-COPY
   at u + ;

: PUT-STR ( str n -- n ) {: s:str at :} s str> at PUT ;

: PUT-N ( n n -- n ) {: v at :} v FMT:INT$ at PUT ;

: PUT-QUOTED ( str n -- n )
   {: s:str at :}
   s\" \"" at PUT  s swap PUT-STR  s\" \"" rot PUT ;


\ ---- the bindings as the Rust version prints them ----------------

: DROPBOX-DEBUG ( dropbox-binding -- ^u8 n )
   JOURNAL-DROPBOX--BINDING:UNMAKE {: acct:str ns:str root:str :}
   s\" dropbox_binding\tSome(DropboxBinding { account_id: " 0 PUT
   acct swap PUT-QUOTED
   s" , root_namespace_id: " rot PUT
   ns swap PUT-QUOTED
   s" , remote_root: " rot PUT
   root swap PUT-QUOTED
   s"  })" rot PUT {: u :}
   WANT u ;

: BIRTH-DEBUG ( option<birth-time> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF
         JOURNAL-BIRTH--TIME:UNMAKE {: s ns :}
         s" Some(BirthTime { seconds: " at PUT  s swap PUT-N
         s" , nanoseconds: " rot PUT  ns swap PUT-N
         s"  })" rot PUT
      ENDOF
   ;MATCH ;

: SUBVOLUME-DEBUG ( option<n> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF {: v :} s" Some(" at PUT  v swap PUT-N  s" )" rot PUT ENDOF
   ;MATCH ;

: ROOT-DEBUG ( local-root-record -- ^u8 n )
   JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b g :}
   b JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str inode birth sub :}
   s\" local_root_binding\tSome(LocalRootRecord { binding: LocalRootBinding { canonical_path: "
   0 PUT
   p swap PUT-QUOTED
   s" , inode: " rot PUT  inode swap PUT-N
   s" , birth: " rot PUT  birth swap BIRTH-DEBUG
   s" , subvolume: " rot PUT  sub swap SUBVOLUME-DEBUG
   s"  }, generation: " rot PUT  g swap PUT-N
   s"  })" rot PUT {: u :}
   WANT u ;

: DROPBOX-HELD? ( option<dropbox-binding> -- bool )
   MATCH option
      none OF false ENDOF
      some OF DROPBOX-DEBUG HELD? ENDOF
   ;MATCH ;

: ROOT-HELD? ( option<local-root-record> -- bool )
   MATCH option
      none OF false ENDOF
      some OF ROOT-DEBUG HELD? ENDOF
   ;MATCH ;


\ ---- bindings and outcomes ---------------------------------------

: DROPBOX ( ^u8 n ^u8 n ^u8 n -- dropbox-binding )
   {: a:^ au b:^ bu c:^ cu :}
   a au >str b bu >str c cu >str JOURNAL-DROPBOX--BINDING:MAKE ;

: BIRTH-5 ( -- birth-time ) 1700000000 5 JOURNAL-BIRTH--TIME:MAKE ;

\ The Rust tests' local_root(path, inode).
: LOCAL-ROOT ( ^u8 n n -- local-root-binding )
   {: a:^ u inode :}
   a u >str inode BIRTH-5 OPTION:SOME 256 OPTION:SOME
   JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

\ The root a schema-6 journal recorded: no birth time, no subvolume.
: LEGACY-ROOT ( -- local-root-record )
   s" /sync/root" >str 2 NO-BIRTH NO-SUBVOLUME
   JOURNAL-LOCAL--ROOT--BINDING:MAKE
   3 JOURNAL-LOCAL--ROOT--RECORD:MAKE ;

: RECORD= ( local-root-record local-root-record -- bool )
   {: a b :}
   a >BINDING b >BINDING ROOT=
   a >GENERATION b >GENERATION = and ;

: RECORD-HELD? ( option<local-root-record> local-root-record -- bool )
   {: want :}
   MATCH option
      none OF false ENDOF
      some OF want RECORD= ENDOF
   ;MATCH ;

: DROPBOX-HELD-AS? ( option<dropbox-binding> dropbox-binding -- bool )
   {: want :}
   MATCH option
      none OF false ENDOF
      some OF want BINDING= ENDOF
   ;MATCH ;

: CURRENT? ( local-root-activation local-root-record -- bool )
   {: want :}
   MATCH local-root-activation
      activated OF drop false ENDOF
      current OF want RECORD= ENDOF
      unavailable OF 2drop false ENDOF
   ;MATCH ;

: UNAVAILABLE?
   ( local-root-activation local-root-binding local-root-binding -- bool )
   {: recorded actual :}
   MATCH local-root-activation
      activated OF drop false ENDOF
      current OF drop false ENDOF
      unavailable OF
         {: r a :} r recorded ROOT= a actual ROOT= and
      ENDOF
   ;MATCH ;

: BOUND? ( dropbox-binding-write -- bool )
   MATCH dropbox-binding-write
      bound OF true ENDOF
      already-bound OF false ENDOF
      mismatch OF drop false ENDOF
   ;MATCH ;

: ALREADY-BOUND? ( dropbox-binding-write -- bool )
   MATCH dropbox-binding-write
      bound OF false ENDOF
      already-bound OF true ENDOF
      mismatch OF drop false ENDOF
   ;MATCH ;

: MISMATCH? ( dropbox-binding-write dropbox-binding -- bool )
   {: want :}
   MATCH dropbox-binding-write
      bound OF false ENDOF
      already-bound OF false ENDOF
      mismatch OF want BINDING= ENDOF
   ;MATCH ;

: SUBVOLUME-OF ( local-root-binding -- option<n> )
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str i b s :} s ;


\ ---- the journal's rows ------------------------------------------

: BASELINE-ROWS ( journal -- n )
   >CONNECTION s" SELECT count(*) FROM baselines" QUERY-INT ;

: CHANGED ( journal -- n )
   >CONNECTION s" SELECT total_changes()" QUERY-INT ;

\ A schema-8 journal holding a schema-6 root's row, as migration 7
\ copies it, and one baseline, whose JSON only stands in.
: LEGACY ( str -- )
   {: p:str :}
   p OPEN CLOSE
   p str> SQLITE:OPEN {: c :}
   c s" INSERT INTO local_root_binding(
         singleton, canonical_path, inode, generation
      ) VALUES (1, CAST('/sync/root' AS BLOB), X'0000000000000002', 3);
      INSERT INTO baselines(path, baseline_json, canonical_path)
      VALUES (CAST('kept.txt' AS BLOB), '{}', CAST('kept.txt' AS BLOB));"
   SQLITE:EXEC
   c SQLITE:CLOSE ;

: SCHEMA-SQL ( -- ^u8 n )
   s" SELECT type || char(9) || name || char(9) || tbl_name || char(9)
         || coalesce(replace(replace(replace(sql, '\', '\\'),
            char(10), '\n'), char(9), '\t'), '')
      FROM sqlite_master" ;

\ Counts the rows, each a line of BODY.
: SCHEMA-ROWS ( n SQLITE:statement -- n SQLITE:statement )
   begin SQLITE:STEP while
      0 SQLITE:COL-TEXT HELD? TTRUE
      swap 1+ swap
   repeat ;

\ Every table's and index's name and SQL, lower case, in BODY.
: SCHEMA-TEXT ( SQLITE:statement -- n SQLITE:statement )
   SQLITE:STEP drop
   0 SQLITE:COL-TEXT {: a:^ u :}
   a BODY u BYTE-COPY
   u swap ;

: VERSIONED ( str n -- )
   {: p:str v :}
   p str> SQLITE:OPEN {: c :}
   s" PRAGMA user_version = " 0 PUT v swap PUT-N {: u :}
   c WANT u SQLITE:EXEC
   c SQLITE:CLOSE ;

: VERSION-AT ( str -- n )
   str> SQLITE:OPEN {: c :}
   c VERSION
   c SQLITE:CLOSE ;

\ A journal at version v is refused and keeps it.
: REFUSED ( n ^ARENA:arena -- )
   {: v ar :}
   ar JOURNAL-AT {: d:str p:str :}
   p v VERSIONED
   p SUBJECT !
   [: SUBJECT @ OPEN CLOSE ;] E-UNSUPPORTED-VERSION d
   s" has unsupported schema version" ar LOGGED
   p VERSION-AT v T=
   d GONE ;


\ ---- the brief's cases -------------------------------------------

: NEW-JOURNAL-HAS-THE-ORACLE-SCHEMA ( ^ARENA:arena -- )
   {: ar :}
   s" a new journal's schema is schema.tsv's" T-LABEL
   s" src/oracle/schema.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   0 j >CONNECTION SCHEMA-SQL [: SCHEMA-ROWS ;] SQLITE:WITH-STATEMENT
   26 T=
   j >CONNECTION VERSION 8 T=
   s\" user_version\t8" HELD? TTRUE
   BODY BODY-U @ 10 COUNT-CHAR 28 T=
   j CLOSE
   d GONE ;

: OTHER-VERSIONS-ARE-REFUSED-UNCHANGED ( ^ARENA:arena -- )
   {: ar :}
   s" versions 1, 7 and 9 are refused unchanged" T-LABEL
   1 ar REFUSED
   7 ar REFUSED
   9 ar REFUSED ;

: ORACLE-JOURNAL-HOLDS-ITS-BINDINGS ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's bindings are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p str> FS:COPY-FILE-STREAM
   p OPEN {: j :}
   j ar DROPBOX-BINDING DROPBOX-HELD? TTRUE
   j ar LOCAL-ROOT-BINDING ROOT-HELD? TTRUE
   j CLOSE
   d GONE ;


\ ---- the Rust version's tests ------------------------------------

: WRITABLE-JOURNAL-CREATES-OWNER-ONLY-DATABASE ( ^ARENA:arena -- )
   {: ar :}
   s" writable_journal_creates_owner_only_database" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   p MODE-OF MODE-OWNER T=
   j CLOSE
   d GONE ;

: READ-ONLY-JOURNAL-PRESERVES-EXISTING-PERMISSIONS ( ^ARENA:arena -- )
   {: ar :}
   s" read_only_journal_preserves_existing_permissions" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN CLOSE
   p str> MODE-SHARED FS:CHMOD-MODE
   p OPEN-READ {: j :}
   p MODE-OF MODE-SHARED T=
   j CLOSE
   d GONE ;

\ The identity statx gives for the directory, read here on its own.
: STATX-ROOT ( str -- local-root-binding )
   {: d:str :}
   d str> FS:TRY-STAT TTRUE
   FS:STAT-INO@ {: inode :}
   d str> FS:OPEN-DIR {: dir:fd :}
   dir FS-STATX:BIRTH {: s ns born:bool :}
   dir FS-STATX:SUBVOLUME {: sub has:bool :}
   dir FS:CLOSE-DIR
   born TTRUE
   d inode s ns JOURNAL-BIRTH--TIME:MAKE OPTION:SOME
   has if sub OPTION:SOME else NO-SUBVOLUME then
   JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

: LOCAL-ROOT-INSPECTION-USES-DIRECTORY-FILESYSTEM-IDENTITY
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_root_inspection_uses_directory_filesystem_identity" T-LABEL
   ar SCRATCH {: d:str :}
   d INSPECT d STATX-ROOT ROOT= TTRUE
   d s" not-a-root" ar INSIDE {: f:str :}
   f str> s" file" FS:WRITE-ALL
   f SUBJECT !
   [: SUBJECT @ INSPECT drop ;] E-FILE d
   s" journal operation `inspect local root` failed for" ar LOGGED
   d GONE ;

: UNBORN-SYNC ( -- )
   s" /sync" >str 2 BIRTH-5 false 256 true FROM-STATX-FIELDS drop ;

: ROOT-IDENTITY-REQUIRES-A-RECORDED-BIRTH-TIME ( ^ARENA:arena -- )
   {: ar :}
   s" root_identity_requires_a_recorded_birth_time" T-LABEL
   ar SCRATCH {: d:str :}
   [: UNBORN-SYNC ;] E-NO-BIRTH-TIME d s" sync root `/sync` is on" ar
   LOGGED
   s" /sync" >str 2 BIRTH-5 true 256 false FROM-STATX-FIELDS
   SUBVOLUME-OF NO-SUBVOLUME? TTRUE
   d GONE ;

: RECORDED ( ^u8 n option<birth-time> -- local-root-record )
   {: a:^ u birth :}
   a u >str 2 birth NO-SUBVOLUME JOURNAL-LOCAL--ROOT--BINDING:MAKE
   1 JOURNAL-LOCAL--ROOT--RECORD:MAKE ;

\ The Rust test's last case, a File error, has no counterpart: the
\ caller asks STOOD-IN-BY? only of an E-NO-BIRTH-TIME refusal.
: STAND-IN-NEEDS-THE-ROOT-PATH-AND-A-BIRTH-TIME-OR-ANOTHER-INODE ( -- )
   s" stand_in_needs_the_root_path_and_a_birth_time_or_another_inode"
   T-LABEL
   s" /sync/root" BIRTH-5 OPTION:SOME RECORDED {: born :}
   born s" /sync/root" >str 2 STOOD-IN-BY? TTRUE
   born s" /sync/root" >str 9 STOOD-IN-BY? TTRUE
   s" /sync/root" NO-BIRTH RECORDED {: legacy :}
   legacy s" /sync/root" >str 9 STOOD-IN-BY? TTRUE
   legacy s" /sync/root" >str 2 STOOD-IN-BY? TFALSE
   s" /sync/other" BIRTH-5 OPTION:SOME RECORDED {: elsewhere :}
   elsewhere s" /sync/root" >str 9 STOOD-IN-BY? TFALSE ;

\ The Rust test also publishes a local scan and records a conflict, which
\ the activation keeps; here the baseline row stands for that state.
: VERSION-SIX-ROOT-BINDING-UPGRADES-IN-PLACE-WHEN-PATH-AND-INODE-MATCH
   ( ^ARENA:arena -- )
   {: ar :}
   s" version_six_root_binding_upgrades_in_place_when_path_and_inode_match"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p LEGACY
   p OPEN-READ {: r :}
   r ar LOCAL-ROOT-BINDING LEGACY-ROOT RECORD-HELD? TTRUE
   r CLOSE
   p OPEN {: j :}
   j >CONNECTION VERSION 8 T=
   j ar LOCAL-ROOT-BINDING LEGACY-ROOT RECORD-HELD? TTRUE
   s" /sync/root" 2 LOCAL-ROOT {: inspected :}
   inspected 3 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: upgraded :}
   j CHANGED {: before :}
   j inspected ar ACTIVATE-LOCAL-ROOT upgraded CURRENT? TTRUE
   j CHANGED before - 1 T=
   j BASELINE-ROWS 1 T=
   j ar LOCAL-ROOT-BINDING upgraded RECORD-HELD? TTRUE
   j inspected ar ACTIVATE-LOCAL-ROOT upgraded CURRENT? TTRUE
   j CLOSE
   d GONE ;

: VERSION-SIX-ROOT-BINDING-WITH-ANOTHER-INODE-IS-UNAVAILABLE-WITHOUT-CHANGES
   ( ^ARENA:arena -- )
   {: ar :}
   s" version_six_root_binding_with_another_inode_is_unavailable_without_changes"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p LEGACY
   p OPEN {: j :}
   j CHANGED {: before :}
   s" /sync/root" 9 LOCAL-ROOT {: actual :}
   j actual ar ACTIVATE-LOCAL-ROOT LEGACY-ROOT >BINDING actual UNAVAILABLE?
   TTRUE
   j ar LOCAL-ROOT-BINDING LEGACY-ROOT RECORD-HELD? TTRUE
   j BASELINE-ROWS 1 T=
   j CHANGED before T=
   j CLOSE
   d GONE ;

: ADOPTING-A-MATCHING-VERSION-SIX-ROOT-KEEPS-ITS-GENERATION
   ( ^ARENA:arena -- )
   {: ar :}
   s" adopting_a_matching_version_six_root_keeps_its_generation" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p LEGACY
   p OPEN {: j :}
   s" /sync/root" 2 LOCAL-ROOT {: inspected :}
   inspected 3 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: upgraded :}
   j inspected ar ADOPT-LOCAL-ROOT upgraded CURRENT? TTRUE
   j ar LOCAL-ROOT-BINDING upgraded RECORD-HELD? TTRUE
   j BASELINE-ROWS 1 T=
   j CLOSE
   d GONE ;

: JOURNAL-DROPBOX-BINDING-SURVIVES-REOPEN ( ^ARENA:arena -- )
   {: ar :}
   s" journal_dropbox_binding_survives_reopen" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" dbid:account" s" namespace-1" s" /omabox" DROPBOX {: b :}
   p OPEN {: j :}
   j b ar BIND-DROPBOX-ROOT BOUND? TTRUE
   j CLOSE
   p OPEN {: k :}
   k ar DROPBOX-BINDING b DROPBOX-HELD-AS? TTRUE
   k b ar BIND-DROPBOX-ROOT ALREADY-BOUND? TTRUE
   k CLOSE
   d GONE ;

: JOURNAL-DROPBOX-BINDING-MISMATCH-NEVER-REPLACES-EXISTING
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_dropbox_binding_mismatch_never_replaces_existing" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" dbid:account" s" namespace-1" s" /omabox" DROPBOX {: existing :}
   p OPEN {: j :}
   j existing ar BIND-DROPBOX-ROOT BOUND? TTRUE
   j s" dbid:other" s" namespace-1" s" /omabox" DROPBOX ar BIND-DROPBOX-ROOT
   existing MISMATCH? TTRUE
   j s" dbid:account" s" namespace-2" s" /omabox" DROPBOX ar
   BIND-DROPBOX-ROOT existing MISMATCH? TTRUE
   j s" dbid:account" s" namespace-1" s" /other" DROPBOX ar BIND-DROPBOX-ROOT
   existing MISMATCH? TTRUE
   j CLOSE
   p OPEN {: k :}
   k existing ar BIND-DROPBOX-ROOT ALREADY-BOUND? TTRUE
   k CLOSE
   d GONE ;

: JOURNAL-REJECTS-NEWER-SCHEMA-WITHOUT-CHANGING-ITS-VERSION
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_rejects_newer_schema_without_changing_its_version" T-LABEL
   9 ar REFUSED ;

: JOURNAL-SCHEMA-AND-PAYLOAD-COLUMNS-ARE-NOT-SECRET-BEARING
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_schema_and_payload_columns_are_not_secret_bearing" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j >CONNECTION
   s" SELECT lower(group_concat(name || ' ' || sql, char(10)))
      FROM sqlite_master
      WHERE type IN ('table', 'index') AND sql IS NOT NULL"
   [: SCHEMA-TEXT ;] SQLITE:WITH-STATEMENT {: u :}
   BODY u s" oauth" CONTAINS? TFALSE
   BODY u s" credential" CONTAINS? TFALSE
   BODY u s" access_token" CONTAINS? TFALSE
   BODY u s" refresh_token" CONTAINS? TFALSE
   BODY u s" secret" CONTAINS? TFALSE
   BODY u s" local_root_binding" CONTAINS? TTRUE
   j CLOSE
   d GONE ;


\ ---- baselines and plans -----------------------------------------

TYPED-VARIABLE HELD-JOURNAL journal
TYPED-VARIABLE HELD-ARENA ^ARENA:arena
TYPED-VARIABLE NOOPS ^VEC:vector<path-baseline>
TYPED-VARIABLE PLANS ^VEC:vector<path-plan>

: AT-PATH ( ^u8 n -- MODEL:path ) >str MODEL:>PATH ;

: CANONICAL ( ^u8 n ^ARENA:arena -- MODEL:key )
   {: a:^ u ar :}
   a u AT-PATH ar MODEL:FOLD ;

: CONTENT ( ^u8 n -- DROPBOX:hash ) >str DROPBOX:>HASH ;

: REMOTE-FILE ( ^u8 n ^u8 n -- MODEL:remote )
   {: c:^ cu r:^ ru :}
   c cu CONTENT r ru >str DROPBOX:>REV MODEL-REMOTE:MAKE ;

: PATH= ( MODEL:path MODEL:path -- bool )
   PATH-BYTES {: b:^ bu :}
   PATH-BYTES b bu STR= ;

\ The planner's decisions for the Rust tests' plan() calls, built here
\ as src/oracle/plan.tsv holds them. An upload: a new local file, no
\ remote one, no baseline.
: UPLOAD-DECISION ( ^u8 n -- MODEL:decision )
   CONTENT MODEL-OPERATION:create-remote MODEL-DECISION:operate ;

\ Both sides present with the remote file's content, whatever the
\ baseline: the remote file becomes the baseline.
: MATCH-DECISION ( MODEL:remote -- MODEL:decision )
   MODEL-BASELINE:present MODEL-DECISION:noop ;

\ Both sides confirmed absent.
: ABSENT-DECISION ( -- MODEL:decision )
   MODEL-BASELINE:absent MODEL-DECISION:noop ;

\ A directory on both sides and in the baseline.
: DIRECTORY-DECISION ( -- MODEL:decision )
   MODEL-BASELINE:directory MODEL-DECISION:noop ;

: TEST-PATH ( -- str ) s" test" >str ;

: ONE-PLAN ( MODEL:operation ^ARENA:arena -- operation-plan )
   {: o ar :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   o ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

: NOT-OPERATIONS ( -- )
   s" extract test operation plan" >str TEST-PATH
   s" test expected planner operations" >str INVALID ;

\ The Rust tests' operations(decision).
: OPERATIONS ( MODEL:decision ^ARENA:arena -- operation-plan )
   {: ar :}
   MATCH MODEL:decision
      operate OF ar ONE-PLAN ENDOF
      noop OF drop NOT-OPERATIONS ENDOF
      blocked OF drop NOT-OPERATIONS ENDOF
      conflicted OF drop NOT-OPERATIONS ENDOF
      collided OF drop NOT-OPERATIONS ENDOF
   ;MATCH ;

: NOT-NOOP ( -- )
   s" extract test no-op" >str TEST-PATH
   s" test expected a planner no-op" >str INVALID ;

\ The Rust tests' noop(decision): the baseline it records.
: NOOP ( MODEL:decision -- MODEL:baseline )
   MATCH MODEL:decision
      noop OF ENDOF
      operate OF drop NOT-NOOP ENDOF
      blocked OF drop NOT-NOOP ENDOF
      conflicted OF drop NOT-NOOP ENDOF
      collided OF drop NOT-NOOP ENDOF
   ;MATCH ;

\ The Rust tests' recorded_plan(write).
: RECORDED-PLAN ( plan-write -- plan-record )
   MATCH plan-write
      recorded OF ENDOF
      already-live OF
         drop s" extract recorded test plan" >str TEST-PATH
         s" test expected a newly recorded plan" >str INVALID
      ENDOF
   ;MATCH ;

: NOOP-RECORDED? ( noop-write -- bool )
   MATCH noop-write
      recorded OF true ENDOF
      live-plan OF drop false ENDOF
   ;MATCH ;

: OWNED-BY? ( noop-write plan-id -- bool )
   {: id :}
   MATCH noop-write
      recorded OF false ENDOF
      live-plan OF id ID= ENDOF
   ;MATCH ;

: NO-BASELINE? ( option<MODEL:baseline> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: BASELINE-HELD? ( option<MODEL:baseline> MODEL:baseline -- bool )
   {: want :}
   MATCH option
      none OF false ENDOF
      some OF want MODEL:BASELINE= ENDOF
   ;MATCH ;

: STATUS-N ( record-status -- n )
   MATCH record-status
      pending OF 0 ENDOF
      completed OF 1 ENDOF
   ;MATCH ;

: PENDING? ( plan-status -- bool )
   MATCH plan-status
      pending OF true ENDOF
      blocked OF 2drop false ENDOF
      completed OF false ENDOF
   ;MATCH ;

: PLANNED= ( planned-operation planned-operation -- bool )
   JOURNAL-PLANNED--OPERATION:UNMAKE {: i o x s :}
   JOURNAL-PLANNED--OPERATION:UNMAKE {: j p y t :}
   i OPERATION-ID>N j OPERATION-ID>N = o p = and
   x y MODEL:OPERATION= and s STATUS-N t STATUS-N = and ;

: OPERATIONS= ( ^VEC:vector<planned-operation>
     ^VEC:vector<planned-operation> -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ PLANNED= 0= if unloop false exit then
   loop
   true ;

\ Two plans equal and both pending, as every plan these tests compare is.
: PENDING-PLAN= ( plan-record plan-record -- bool )
   JOURNAL-PLAN--RECORD:UNMAKE {: i p o s :}
   JOURNAL-PLAN--RECORD:UNMAKE {: j q r t :}
   i j ID= p q PATH= and o r OPERATIONS= and
   s PENDING? and t PENDING? and ;

: FIRST-OPERATION ( plan-record -- MODEL:operation )
   >OPERATIONS 0 VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE
   {: i o x s :} x ;

: PATHS= ( ^VEC:vector<MODEL:path> ^VEC:vector<MODEL:path> -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ PATH= 0= if unloop false exit then
   loop
   true ;

\ The paths' vector holds the two paths, in order.
: TWO-PATHS? ( ^VEC:vector<MODEL:path> ^u8 n ^u8 n -- bool )
   {: v a:^ au b:^ bu :}
   v VEC:COUNT 2 <> if false exit then
   v 0 VEC:AT @ a au AT-PATH PATH=
   v 1 VEC:AT @ b bu AT-PATH PATH= and ;

: ROWS-AT ( journal MODEL:path -- n )
   {: j path :}
   j >CONNECTION s" SELECT COUNT(*) FROM baselines WHERE path = ?1"
   [: path PATH-BYTES 1 SQLITE:BIND-BLOB INT-ROW ;]
   SQLITE:WITH-STATEMENT ;

: AGREE ( journal ^u8 n ^u8 n ^u8 n ^ARENA:arena -- )
   {: j p:^ pu c:^ cu r:^ ru ar :}
   j p pu AT-PATH c cu r ru REMOTE-FILE MATCH-DECISION NOOP ar
   RECORD-NOOP drop ;

: DIRECTORY ( journal ^u8 n ^ARENA:arena -- )
   {: j p:^ pu ar :}
   j p pu AT-PATH DIRECTORY-DECISION NOOP ar RECORD-NOOP drop ;

: RECONCILE ( -- )
   HELD-JOURNAL @ NOOPS @ PLANS @ HELD-ARENA @ RECORD-RECONCILIATION
   drop ;

: EXISTS? ( MODEL:path -- bool ) drop true ;

: PROBE-FAILS ( MODEL:path -- bool ) drop E-INVALID-STATE throw ;

: NOT-GONE? ( MODEL:path -- bool ) s" Foo/gone.txt" AT-PATH PATH= 0= ;

: RECORD-IS? ( MODEL:baseline-record ^u8 n ^u8 n ^ARENA:arena -- bool )
   {: r k:^ ku p:^ pu ar :}
   r MODEL-BASELINE--RECORD:UNMAKE {: key path b :}
   key k ku ar CANONICAL MODEL:KEY= path p pu AT-PATH PATH= and ;


\ ---- the oracle's baselines as the Rust version prints them ------

: HASH-DEBUG ( DROPBOX:hash n -- n )
   {: h at :}
   s" ContentIdentity(" at PUT
   h DROPBOX:HASH>STR swap PUT-QUOTED
   s" )" rot PUT ;

: REV-DEBUG ( DROPBOX:rev n -- n )
   {: r at :}
   s" DropboxRevision(" at PUT
   r DROPBOX:REV>STR swap PUT-QUOTED
   s" )" rot PUT ;

: SHUT ( n -- n ) s"  }" rot PUT ;

: REMOTE-DEBUG ( MODEL:remote n -- n )
   {: r at :}
   r MODEL-REMOTE:UNMAKE {: c rev :}
   s" RemoteFile { content: " at PUT
   c swap HASH-DEBUG
   s" , revision: " rot PUT
   rev swap REV-DEBUG SHUT ;

: VALUE-DEBUG ( MODEL:baseline n -- n )
   {: at :}
   MATCH MODEL:baseline
      absent OF s" Absent" at PUT ENDOF
      present OF
         {: r :} s" Present(" at PUT {: at2 :}
         r at2 REMOTE-DEBUG s" )" rot PUT
      ENDOF
      directory OF s" Directory" at PUT ENDOF
   ;MATCH ;

: BASELINE-DEBUG ( option<MODEL:baseline> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF
         {: b :} s" Some(" at PUT {: at2 :}
         b at2 VALUE-DEBUG s" )" rot PUT
      ENDOF
   ;MATCH ;

\ The line baseline(path) answers.
: BASELINE-LINE ( journal ^u8 n ^ARENA:arena -- ^u8 n )
   {: j a:^ u ar :}
   s" baseline(" 0 PUT  a u rot PUT  s\" )\t" rot PUT {: at :}
   j a u AT-PATH ar BASELINE at BASELINE-DEBUG {: v :}
   WANT v ;

: PATHS-LINE ( ^VEC:vector<MODEL:path> -- ^u8 n )
   {: paths :}
   s\" baseline_paths\t[" 0 PUT
   paths VEC:COUNT 0 ?do
      i 0<> if s" , " rot PUT then
      paths i VEC:AT @ MODEL:PATH>STR swap PUT-QUOTED
   loop
   s" ]" rot PUT {: u :}
   WANT u ;

: ORACLE-JOURNAL-HOLDS-ITS-BASELINES ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's baselines are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p str> FS:COPY-FILE-STREAM
   p OPEN-READ {: j :}
   j s" Docs" ar BASELINE-LINE HELD? TTRUE
   j s" Docs/A.txt" ar BASELINE-LINE HELD? TTRUE
   j s" Old/Gone.txt" ar BASELINE-LINE HELD? TTRUE
   j ar BASELINE-PATHS PATHS-LINE HELD? TTRUE
   j CLOSE
   d GONE ;


\ ---- the Rust version's baseline and plan tests ------------------

: JOURNAL-REOPEN-EXPOSES-INTENT-WITHOUT-ADVANCING-BASELINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_reopen_exposes_intent_without_advancing_baseline" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" notes/report.txt" AT-PATH {: path :}
   s" new" CONTENT MODEL-OPERATION:create-remote {: operation :}
   s" new" UPLOAD-DECISION ar OPERATIONS {: plan :}
   p OPEN {: j :}
   j path plan ar RECORD-PLAN RECORDED-PLAN {: recorded :}
   j CLOSE
   p OPEN {: k :}
   k path ar BASELINE NO-BASELINE? TTRUE
   recorded FIRST-OPERATION operation MODEL:OPERATION= TTRUE
   k ar PENDING-PLANS {: pending :}
   pending VEC:COUNT 1 T=
   pending 0 VEC:AT @ recorded PENDING-PLAN= TTRUE
   k CLOSE
   d GONE ;

\ The rejected plan's SQLite failure is logged once, with the trigger's
\ text.
: RECONCILIATION-DECISIONS-COMMIT-ATOMICALLY ( ^ARENA:arena -- )
   {: ar :}
   s" reconciliation_decisions_commit_atomically" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j >CONNECTION
   s" CREATE TRIGGER reject_test_plan BEFORE INSERT ON plans
      WHEN hex(NEW.path) = hex('reject.txt')
      BEGIN SELECT RAISE(ABORT, 'test rejection'); END;" SQLITE:EXEC
   s" same" s" rev-same" REMOTE-FILE MATCH-DECISION NOOP {: agreed :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   ar [type] path-baseline NEW-VECTOR {: noops :}
   s" same.txt" AT-PATH agreed JOURNAL-PATH--BASELINE:MAKE
   noops VEC:PUSH !
   ar [type] path-plan NEW-VECTOR {: plans :}
   s" safe.txt" AT-PATH upload JOURNAL-PATH--PLAN:MAKE plans VEC:PUSH !
   s" reject.txt" AT-PATH upload JOURNAL-PATH--PLAN:MAKE plans VEC:PUSH !
   j HELD-JOURNAL !  ar HELD-ARENA !  noops NOOPS !  plans PLANS !
   [: RECONCILE ;] SQLITE:E-SQL d s" test rejection" ar LOGGED
   j s" same.txt" AT-PATH ar BASELINE NO-BASELINE? TTRUE
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j CLOSE
   d GONE ;

: JOURNAL-NOOP-REFRESHES-REVISION-BUT-CANNOT-CROSS-A-PENDING-PLAN
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_noop_refreshes_revision_but_cannot_cross_a_pending_plan"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" matching.txt" AT-PATH {: path :}
   s" same" s" rev-current" REMOTE-FILE {: observed :}
   observed MATCH-DECISION NOOP {: noop :}
   j path noop ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j path ar BASELINE observed MODEL-BASELINE:present BASELINE-HELD?
   TTRUE
   j CHANGED {: unchanged :}
   j path noop ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j CHANGED unchanged T=
   s" new" UPLOAD-DECISION ar OPERATIONS {: upload :}
   j path upload ar RECORD-PLAN RECORDED-PLAN {: pending :}
   ABSENT-DECISION NOOP {: absent :}
   j path absent ar RECORD-NOOP pending >ID OWNED-BY? TTRUE
   j path ar BASELINE
   s" same" s" rev-current" REMOTE-FILE MODEL-BASELINE:present
   BASELINE-HELD? TTRUE
   j CLOSE
   d GONE ;

: ABSENT-BASELINE-REMOVES-ITS-ROW ( ^ARENA:arena -- )
   {: ar :}
   s" absent_baseline_removes_its_row" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" removed.txt" AT-PATH {: path :}
   j s" removed.txt" s" old" s" rev-old" ar AGREE
   ar [type] MODEL:path NEW-VECTOR {: want :}
   path want VEC:PUSH !
   j ar BASELINE-PATHS want PATHS= TTRUE
   j path ABSENT-DECISION NOOP ar RECORD-NOOP drop
   j path ar BASELINE NO-BASELINE? TTRUE
   j ar BASELINE-PATHS VEC:COUNT 0 T=
   j path ROWS-AT 0 T=
   j CLOSE
   d GONE ;

: CASE-COLLISION-INVALIDATION-COVERS-A-CHILD-NAMED-WITH-A-HIGH-BYTE
   ( ^ARENA:arena -- )
   {: ar :}
   s" case_collision_invalidation_covers_a_child_named_with_a_high_byte"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" p" ar DIRECTORY
   j s\" p/\xFFchild" s" old" s" rev-old" ar AGREE
   j ar BASELINES VEC:COUNT 2 T=
   j s" p" AT-PATH [: EXISTS? ;] ar INVALIDATE-CASE-COLLISION-BASELINES
   j ar BASELINES VEC:COUNT 0 T=
   j CLOSE
   d GONE ;

: CASE-COLLISION-INVALIDATION-JUDGES-EACH-RECORDED-SPELLING
   ( ^ARENA:arena -- )
   {: ar :}
   s" case_collision_invalidation_judges_each_recorded_spelling" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" Foo" ar DIRECTORY
   j s" Foo/kept.txt" s" old" s" rev-old" ar AGREE
   j s" Foo/gone.txt" s" old" s" rev-old" ar AGREE
   j s" foo/renamed.txt" s" old" s" rev-old" ar AGREE
   j ar BASELINE-PATHS {: all :}
   [: j s" foo" AT-PATH [: PROBE-FAILS ;] ar
      INVALIDATE-CASE-COLLISION-BASELINES ;] E-INVALID-STATE TTHROWSQ
   j ar BASELINE-PATHS all PATHS= TTRUE
   j s" foo" AT-PATH [: NOT-GONE? ;] ar
   INVALIDATE-CASE-COLLISION-BASELINES
   j ar BASELINE-PATHS s" Foo" s" Foo/kept.txt" TWO-PATHS? TTRUE
   j CLOSE
   d GONE ;

: BASELINE-SNAPSHOT-IS-CANONICAL-SORTED ( ^ARENA:arena -- )
   {: ar :}
   s" baseline_snapshot_is_canonical_sorted" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" Zulu.TXT" s" zulu" s" rev-zulu" ar AGREE
   j s" alpha.txt" s" alpha" s" rev-alpha" ar AGREE
   j ar BASELINES {: records :}
   records VEC:COUNT 2 T=
   records 0 VEC:AT @ s" alpha.txt" s" alpha.txt" ar RECORD-IS? TTRUE
   records 1 VEC:AT @ s" zulu.txt" s" Zulu.TXT" ar RECORD-IS? TTRUE
   records 1 VEC:AT @ MODEL-BASELINE--RECORD:UNMAKE {: k path b :}
   b s" zulu" s" rev-zulu" REMOTE-FILE MODEL-BASELINE:present
   MODEL:BASELINE= TTRUE
   j CLOSE
   d GONE ;


\ ---- the oracle's plans as the Rust version prints them ----------

: LOCAL-DEBUG ( MODEL:local n -- n )
   {: l at :}
   s" LocalFile { content: " at PUT
   l MODEL-LOCAL:UNMAKE swap HASH-DEBUG SHUT ;

: REPLACE-LOCAL-DEBUG ( MODEL:remote DROPBOX:hash n -- n )
   {: r h at :}
   s" ReplaceLocal { source: " at PUT
   r swap REMOTE-DEBUG
   s" , expected_content: " rot PUT
   h swap HASH-DEBUG SHUT ;

: REPLACE-REMOTE-DEBUG ( DROPBOX:hash DROPBOX:rev n -- n )
   {: h r at :}
   s" ReplaceRemote { content: " at PUT
   h swap HASH-DEBUG
   s" , expected_revision: " rot PUT
   r swap REV-DEBUG SHUT ;

: OPERATION-DEBUG ( MODEL:operation n -- n )
   {: at :}
   MATCH MODEL:operation
      create-local-directory OF s" CreateLocalDirectory" at PUT ENDOF
      create-remote-directory OF s" CreateRemoteDirectory" at PUT ENDOF
      delete-local-directory OF s" DeleteLocalDirectory" at PUT ENDOF
      delete-remote-directory OF s" DeleteRemoteDirectory" at PUT ENDOF
      create-remote OF
         s" CreateRemote { content: " at PUT HASH-DEBUG SHUT
      ENDOF
      install-local OF
         s" InstallLocal { source: " at PUT REMOTE-DEBUG SHUT
      ENDOF
      preserve-local OF
         s" PreserveLocal { file: " at PUT LOCAL-DEBUG SHUT
      ENDOF
      replace-local OF at REPLACE-LOCAL-DEBUG ENDOF
      delete-local OF
         s" DeleteLocal { expected_content: " at PUT HASH-DEBUG SHUT
      ENDOF
      preserve-remote OF
         s" PreserveRemote { file: " at PUT REMOTE-DEBUG SHUT
      ENDOF
      replace-remote OF at REPLACE-REMOTE-DEBUG ENDOF
      delete-remote OF
         s" DeleteRemote { expected_revision: " at PUT REV-DEBUG SHUT
      ENDOF
   ;MATCH ;

: BLOCKAGE-DEBUG ( MODEL:blockage n -- n )
   {: at :}
   MATCH MODEL:blockage
      unsupported-file-size OF s" UnsupportedFileSize" at PUT ENDOF
      remote-rejected OF
         s" RemoteRejected { tag: " at PUT PUT-QUOTED SHUT
      ENDOF
      download-unavailable OF
         s" DownloadUnavailable { status: " at PUT PUT-N SHUT
      ENDOF
      download-verification-failed OF
         s" DownloadVerificationFailed" at PUT
      ENDOF
      stage-occupied OF s" StageOccupied" at PUT ENDOF
      local-object-in-way OF s" LocalObjectInWay" at PUT ENDOF
      remote-object OF s" RemoteObject" at PUT ENDOF
      conflict-copy-occupied OF s" ConflictCopyOccupied" at PUT ENDOF
   ;MATCH ;

: BLOCKED-DEBUG ( MODEL:blockage n n -- n )
   {: reason retry at :}
   s" Blocked { reason: " at PUT
   reason swap BLOCKAGE-DEBUG
   s" , retry_at: " rot PUT
   retry swap PUT-N SHUT ;

: STATUS-DEBUG ( plan-status n -- n )
   {: at :}
   MATCH plan-status
      pending OF s" Pending" at PUT ENDOF
      blocked OF at BLOCKED-DEBUG ENDOF
      completed OF s" Completed" at PUT ENDOF
   ;MATCH ;

: RECORD-STATUS-DEBUG ( record-status n -- n )
   {: at :}
   MATCH record-status
      pending OF s" Pending" at PUT ENDOF
      completed OF s" Completed" at PUT ENDOF
   ;MATCH ;

: PLANNED-DEBUG ( planned-operation n -- n )
   {: at :}
   JOURNAL-PLANNED--OPERATION:UNMAKE {: id ordinal o st :}
   s" PlannedOperation { id: OperationId(" at PUT
   id OPERATION-ID>N swap PUT-N
   s" ), ordinal: " rot PUT  ordinal swap PUT-N
   s" , operation: " rot PUT  o swap OPERATION-DEBUG
   s" , status: " rot PUT  st swap RECORD-STATUS-DEBUG SHUT ;

: PLANNED-LIST ( ^VEC:vector<planned-operation> n -- n )
   {: ops at :}
   s" [" at PUT
   ops VEC:COUNT 0 ?do
      i 0<> if s" , " rot PUT then
      ops i VEC:AT @ swap PLANNED-DEBUG
   loop
   s" ]" rot PUT ;

: PLAN-DEBUG ( plan-record n -- n )
   {: at :}
   JOURNAL-PLAN--RECORD:UNMAKE {: id path ops st :}
   s" PlanRecord { id: PlanId(" at PUT
   id PLAN-ID>N swap PUT-N
   s" ), path: " rot PUT  path MODEL:PATH>STR swap PUT-QUOTED
   s" , operations: " rot PUT  ops swap PLANNED-LIST
   s" , status: " rot PUT  st swap STATUS-DEBUG SHUT ;

\ name, a tab, then the plans as a list.
: PLANS-LINE ( ^u8 n ^VEC:vector<plan-record> -- ^u8 n )
   {: a:^ u plans :}
   a u 0 PUT  s\" \t[" rot PUT
   plans VEC:COUNT 0 ?do
      i 0<> if s" , " rot PUT then
      plans i VEC:AT @ swap PLAN-DEBUG
   loop
   s" ]" rot PUT {: v :}
   WANT v ;

: CONTENT-LINE ( ^VEC:vector<DROPBOX:hash> -- ^u8 n )
   {: hashes :}
   s\" pending_upload_content\t[" 0 PUT
   hashes VEC:COUNT 0 ?do
      i 0<> if s" , " rot PUT then
      hashes i VEC:AT @ swap HASH-DEBUG
   loop
   s" ]" rot PUT {: u :}
   WANT u ;

\ Two statuses alike as the Rust version prints them, which names each
\ field: the first is printed at WANT, the second after it.
: STATUS= ( plan-status plan-status -- bool )
   {: a b :}
   a 0 STATUS-DEBUG {: u :}
   b u STATUS-DEBUG {: v :}
   WANT u WANT u + v u - STR= ;

: ORACLE-JOURNAL-HOLDS-ITS-PLANS ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's plans are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p str> FS:COPY-FILE-STREAM
   p OPEN-READ {: j :}
   s" pending_plans" j ar PENDING-PLANS PLANS-LINE HELD? TTRUE
   s" blocked_plans" j ar BLOCKED-PLANS PLANS-LINE HELD? TTRUE
   j ar PENDING-UPLOAD-CONTENT CONTENT-LINE HELD? TTRUE
   j CLOSE
   d GONE ;


\ ---- the Rust version's blocked plan tests ------------------------

TYPED-VARIABLE HELD-OPS ^VEC:vector<MODEL:operation>
variable CRAFT

: STATUS-OF ( plan-record -- plan-status )
   JOURNAL-PLAN--RECORD:UNMAKE {: i p o s :} s ;

: BLOCKED-AS ( MODEL:blockage n -- plan-status )
   construct plan-status blocked ;

: PENDING-STATUS ( -- plan-status ) construct plan-status pending ;

\ Two plans alike but for their status.
: SAME-PLAN? ( plan-record plan-record -- bool )
   JOURNAL-PLAN--RECORD:UNMAKE {: i p o s :}
   JOURNAL-PLAN--RECORD:UNMAKE {: j q r t :}
   i j ID= p q PATH= and o r OPERATIONS= and ;

: BLOCK-N ( plan-block -- n )
   MATCH plan-block
      not-found OF 0 ENDOF
      already-completed OF 1 ENDOF
      blocked OF 2 ENDOF
   ;MATCH ;

: UNBLOCK-N ( plan-unblock -- n )
   MATCH plan-unblock
      not-found OF 0 ENDOF
      not-blocked OF 1 ENDOF
      unblocked OF 2 ENDOF
   ;MATCH ;

\ The Rust tests' let PlanWrite::AlreadyLive(live) = write.
: ALREADY-LIVE-PLAN ( plan-write -- plan-record )
   MATCH plan-write
      already-live OF ENDOF
      recorded OF
         drop s" extract live test plan" >str TEST-PATH
         s" a blocked path accepted a second live plan" >str INVALID
      ENDOF
   ;MATCH ;

: LIVE-PLAN-ROWS ( journal -- n )
   >CONNECTION
   s" SELECT COUNT(*) FROM plans WHERE status IN ('pending', 'blocked')"
   QUERY-INT ;

: PLAN-ROWS ( journal -- n )
   >CONNECTION s" SELECT COUNT(*) FROM plans" QUERY-INT ;

: ONLY ( ^VEC:vector<plan-record> -- plan-record )
   {: plans :}
   plans VEC:COUNT 1 T=
   plans 0 VEC:AT @ ;

: BLOCKING-A-PLAN-HIDES-IT-FROM-PENDING-WORK-ACROSS-REOPEN
   ( ^ARENA:arena -- )
   {: ar :}
   s" blocking_a_plan_hides_it_from_pending_work_across_reopen" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" blocked.txt" AT-PATH {: path :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   s" insufficient_space" >str MODEL-BLOCKAGE:remote-rejected {: why :}
   p OPEN {: j :}
   j path upload ar RECORD-PLAN RECORDED-PLAN {: recorded :}
   recorded >ID {: id :}
   recorded STATUS-OF PENDING-STATUS STATUS= TTRUE
   j id why 1700000000 ar BLOCK-PLAN BLOCK-N 2 T=
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j ar BLOCKED-PLANS ONLY {: blocked :}
   blocked recorded SAME-PLAN? TTRUE
   blocked STATUS-OF why 1700000000 BLOCKED-AS STATUS= TTRUE
   j CLOSE
   p OPEN {: k :}
   k ar PENDING-PLANS VEC:COUNT 0 T=
   k ar BLOCKED-PLANS VEC:COUNT 1 T=
   MODEL-BLOCKAGE:stage-occupied {: stage :}
   k id stage 1700003600 ar BLOCK-PLAN BLOCK-N 2 T=
   k ar BLOCKED-PLANS ONLY STATUS-OF stage 1700003600 BLOCKED-AS
   STATUS= TTRUE
   k id ar UNBLOCK-PLAN UNBLOCK-N 2 T=
   k ar BLOCKED-PLANS VEC:COUNT 0 T=
   k ar PENDING-PLANS ONLY {: live :}
   live >ID id ID= TTRUE
   live STATUS-OF PENDING-STATUS STATUS= TTRUE
   k id ar UNBLOCK-PLAN UNBLOCK-N 1 T=
   k CLOSE
   d GONE ;

: A-BLOCKED-PATH-KEEPS-ITS-PLAN-INSTEAD-OF-GAINING-A-SECOND-ONE
   ( ^ARENA:arena -- )
   {: ar :}
   s" a_blocked_path_keeps_its_plan_instead_of_gaining_a_second_one"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   MODEL-BLOCKAGE:local-object-in-way {: why :}
   p OPEN {: j :}
   j s" Contested.TXT" AT-PATH upload ar RECORD-PLAN RECORDED-PLAN
   >ID {: id :}
   j id why 1700000000 ar BLOCK-PLAN BLOCK-N 2 T=
   j s" contested.txt" AT-PATH upload ar RECORD-PLAN ALREADY-LIVE-PLAN
   {: live :}
   live >ID id ID= TTRUE
   live STATUS-OF why 1700000000 BLOCKED-AS STATUS= TTRUE
   j LIVE-PLAN-ROWS 1 T=
   j CLOSE
   d GONE ;

: ORDINAL-OF ( planned-operation -- u32 )
   JOURNAL-PLANNED--OPERATION:UNMAKE {: i o x s :} o ;

\ The plan's ordinals ascend.
: ORDINALS-ASCEND? ( plan-record -- bool )
   >OPERATIONS {: ops :}
   ops VEC:COUNT 1 ?do
      ops i 1- VEC:AT @ ORDINAL-OF ops i VEC:AT @ ORDINAL-OF >= if
         unloop false exit
      then
   loop
   true ;

\ The plans' ids ascend and each one's ordinals do.
: IN-ORDER? ( ^VEC:vector<plan-record> -- bool )
   {: plans :}
   plans VEC:COUNT 0 ?do
      plans i VEC:AT @ ORDINALS-ASCEND? 0= if unloop false exit then
      i 0<> if
         plans i 1- VEC:AT @ >ID PLAN-ID>N
         plans i VEC:AT @ >ID PLAN-ID>N >= if unloop false exit then
      then
   loop
   true ;

: RECORD-UPLOAD ( journal ^u8 n operation-plan ^ARENA:arena -- )
   {: j a:^ u plan ar :}
   j a u AT-PATH plan ar RECORD-PLAN RECORDED-PLAN drop ;

\ The Rust test also counts the statements pending_plans runs, by
\ rusqlite's trace. SQLITE has no trace hook; PENDING-PLANS reads in
\ READ-PLANS-WITH-STATUS's one WITH-STATEMENT.
: PENDING-PLANS-READS-EVERY-PLAN-AND-OPERATION-IN-ONE-QUERY
   ( ^ARENA:arena -- )
   {: ar :}
   s" pending_plans_reads_every_plan_and_operation_in_one_query" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   s" displaced" CONTENT {: displaced :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   displaced MODEL-LOCAL:MAKE MODEL-OPERATION:preserve-local
   ops VEC:PUSH !
   displaced MODEL-OPERATION:delete-local ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE {: ordered :}
   p OPEN {: j :}
   j s" a.txt" upload ar RECORD-UPLOAD
   j s" b.txt" upload ar RECORD-UPLOAD
   j s" c.txt" upload ar RECORD-UPLOAD
   j s" d.txt" AT-PATH ordered ar RECORD-PLAN RECORDED-PLAN
   >OPERATIONS VEC:COUNT 1 > TTRUE
   j ar PENDING-PLANS {: plans :}
   plans VEC:COUNT 4 T=
   plans IN-ORDER? TTRUE
   j CLOSE
   d GONE ;

: RECORD-EMPTY ( -- )
   HELD-JOURNAL @ s" empty.txt" AT-PATH
   HELD-OPS @ JOURNAL-OPERATION--PLAN:MAKE HELD-ARENA @ RECORD-PLAN
   drop ;

: A-PLAN-WITHOUT-OPERATIONS-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" a_plan_without_operations_is_refused" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j HELD-JOURNAL !  ar HELD-ARENA !
   ar [type] MODEL:operation NEW-VECTOR HELD-OPS !
   [: RECORD-EMPTY ;] E-INVALID-STATE d
   s" journal operation `record plan` found invalid state" ar LOGGED
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j PLAN-ROWS 0 T=
   j CLOSE
   d GONE ;

\ The Rust test's crafted columns, case k: status, blocked_json and
\ retry_at.
: CRAFTED-STATUS ( n -- ^u8 n )
   {: k :}
   k 0= if s" pending" exit then
   k 1 = if s" completed" exit then
   k 4 < if s" blocked" exit then
   k 6 < if s" retired" exit then
   s" blocked" ;

: CRAFTED-JSON ( n -- option<str> )
   {: k :}
   k 0= k 3 = or k 5 = or k 6 = or if SUBJECT @ OPTION:SOME exit then
   NO-TEXT ;

: CRAFTED-RETRY ( n -- option<n> )
   {: k :}
   k 6 = if -1 OPTION:SOME exit then
   k 1 = k 2 = or k 5 = or if 1 OPTION:SOME exit then
   NO-INT ;

: CRAFTED-DETAIL ( n -- ^u8 n )
   {: k :}
   k 4 < if s" plan status disagrees with its block columns" exit then
   k 6 < if s" plan has an unrecognized status" exit then
   s" blocked plan has a negative retry time" ;

: CRAFTED-PATH ( -- MODEL:path ) s" crafted.txt" AT-PATH ;

: DECODE-COLUMNS ( ^u8 n option<str> option<n> -- plan-status )
   s" read plan status" >str CRAFTED-PATH HELD-ARENA @
   DECODE-PLAN-STATUS ;

: DECODE-CRAFTED ( -- )
   CRAFT @ {: k :}
   k CRAFTED-STATUS k CRAFTED-JSON k CRAFTED-RETRY DECODE-COLUMNS drop ;

: PLAN-STATUS-DECODING-NAMES-THE-STATE-IT-REJECTS ( ^ARENA:arena -- )
   {: ar :}
   s" plan_status_decoding_names_the_state_it_rejects" T-LABEL
   ar SCRATCH {: d:str :}
   ar HELD-ARENA !
   MODEL-BLOCKAGE:stage-occupied ar ENCODE-BLOCKAGE SUBJECT !
   s" pending" NO-TEXT NO-INT DECODE-COLUMNS PENDING-STATUS STATUS=
   TTRUE
   s" completed" NO-TEXT NO-INT DECODE-COLUMNS
   construct plan-status completed STATUS= TTRUE
   7 0 ?do
      i CRAFT !
      [: DECODE-CRAFTED ;] E-INVALID-STATE d i CRAFTED-DETAIL ar LOGGED
   loop
   d GONE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar NEW-JOURNAL-HAS-THE-ORACLE-SCHEMA
   ar OTHER-VERSIONS-ARE-REFUSED-UNCHANGED
   ar ORACLE-JOURNAL-HOLDS-ITS-BINDINGS
   ar WRITABLE-JOURNAL-CREATES-OWNER-ONLY-DATABASE
   ar READ-ONLY-JOURNAL-PRESERVES-EXISTING-PERMISSIONS
   ar LOCAL-ROOT-INSPECTION-USES-DIRECTORY-FILESYSTEM-IDENTITY
   ar ROOT-IDENTITY-REQUIRES-A-RECORDED-BIRTH-TIME
   STAND-IN-NEEDS-THE-ROOT-PATH-AND-A-BIRTH-TIME-OR-ANOTHER-INODE
   ar VERSION-SIX-ROOT-BINDING-UPGRADES-IN-PLACE-WHEN-PATH-AND-INODE-MATCH
   ar VERSION-SIX-ROOT-BINDING-WITH-ANOTHER-INODE-IS-UNAVAILABLE-WITHOUT-CHANGES
   ar ADOPTING-A-MATCHING-VERSION-SIX-ROOT-KEEPS-ITS-GENERATION
   ar JOURNAL-DROPBOX-BINDING-SURVIVES-REOPEN
   ar JOURNAL-DROPBOX-BINDING-MISMATCH-NEVER-REPLACES-EXISTING
   ar JOURNAL-REJECTS-NEWER-SCHEMA-WITHOUT-CHANGING-ITS-VERSION
   ar JOURNAL-SCHEMA-AND-PAYLOAD-COLUMNS-ARE-NOT-SECRET-BEARING
   ar ORACLE-JOURNAL-HOLDS-ITS-BASELINES
   ar JOURNAL-REOPEN-EXPOSES-INTENT-WITHOUT-ADVANCING-BASELINE
   ar RECONCILIATION-DECISIONS-COMMIT-ATOMICALLY
   ar JOURNAL-NOOP-REFRESHES-REVISION-BUT-CANNOT-CROSS-A-PENDING-PLAN
   ar ABSENT-BASELINE-REMOVES-ITS-ROW
   ar CASE-COLLISION-INVALIDATION-COVERS-A-CHILD-NAMED-WITH-A-HIGH-BYTE
   ar CASE-COLLISION-INVALIDATION-JUDGES-EACH-RECORDED-SPELLING
   ar BASELINE-SNAPSHOT-IS-CANONICAL-SORTED
   ar ORACLE-JOURNAL-HOLDS-ITS-PLANS
   ar BLOCKING-A-PLAN-HIDES-IT-FROM-PENDING-WORK-ACROSS-REOPEN
   ar A-BLOCKED-PATH-KEEPS-ITS-PLAN-INSTEAD-OF-GAINING-A-SECOND-ONE
   ar PENDING-PLANS-READS-EVERY-PLAN-AND-OPERATION-IN-ONE-QUERY
   ar A-PLAN-WITHOUT-OPERATIONS-IS-REFUSED
   ar PLAN-STATUS-DECODING-NAMES-THE-STATE-IT-REJECTS ;


: TESTS ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" journal-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

TESTS

;package
