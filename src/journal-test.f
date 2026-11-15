\ journal-test.f - JOURNAL's open, schema 8, bindings and inventories on
\ journals under TMPDIR: a new journal's sqlite_master and user_version
\ against src/oracle/schema.tsv as a set; versions 1, 7 and 9 refused
\ unchanged; src/oracle/journal.sqlite3, copied and opened, giving
\ journal.tsv's Dropbox and local root bindings, local and remote
\ inventories and remote cursor, each in the line's own form; and eighteen
\ tests of the Rust version (rust src/journal.rs) under their names. Habu
\ opens no schema-6 file, so the version-six tests start from a schema-8
\ journal holding the row migration 7 leaves for a schema-6 root, birth
\ and subvolume NULL, and one baseline row, which stands for the local
\ scan and conflict the Rust tests also keep. Each case removes its
\ directory; a refusal's log line is captured in it, checked and removed.
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
require src/lib/json.f
require src/lib/vector.f
require src/dropbox.f
require src/model.f
require src/journal.f

\ JOURNAL reopened: a case reads the journal's connection, its rows, the
\ bindings' and records' fields, and the inventories' private words.
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


\ ---- inventories' values -----------------------------------------

TYPED-VARIABLE THE-JOURNAL journal
TYPED-VARIABLE THE-BINDING local-root-binding
TYPED-VARIABLE THE-REMOTES ^VEC:vector<MODEL:remote-record>
TYPED-VARIABLE THE-LOCALS ^VEC:vector<MODEL:local-record>
TYPED-VARIABLE THE-HASHES ^VEC:vector<MODEL:hash-record>
variable INDEXED       \ query plan rows that use the key's index
variable SCANNED       \ query plan rows that scan the table

: CONTENT ( ^u8 n -- DROPBOX:hash ) >str DROPBOX:>HASH ;

: CURSOR ( ^u8 n -- DROPBOX:cursor ) >str DROPBOX:>CURSOR ;

: DISPLAY ( ^u8 n -- MODEL:path ) >str MODEL:>PATH ;

: CANONICAL ( ^u8 n ^ARENA:arena -- MODEL:key )
   {: a:^ u ar :}
   a u DISPLAY ar MODEL:FOLD ;

: REMOTE-FILE ( ^u8 n ^u8 n -- MODEL:remote )
   {: c:^ cu r:^ ru :}
   c cu CONTENT r ru >str DROPBOX:>REV MODEL-REMOTE:MAKE ;

: PRESENT-REMOTE ( ^u8 n ^u8 n -- MODEL:observation<MODEL:remote> )
   REMOTE-FILE MODEL-OBSERVATION:present ;

: ABSENT-REMOTE ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:absent ;

: INACCESSIBLE ( -- MODEL:observation<MODEL:remote> )
   MODEL-UNKNOWN--REASON:inaccessible MODEL-OBSERVATION:unknown ;

: PRESENT-LOCAL ( ^u8 n -- MODEL:observation<MODEL:local> )
   CONTENT MODEL-LOCAL:MAKE MODEL-OBSERVATION:present ;

\ The Rust tests' record(key, path, observation).
: REMOTE-RECORD
   ( ^u8 n ^u8 n MODEL:observation<MODEL:remote> ^ARENA:arena
     -- MODEL:remote-record )
   {: k:^ ku p:^ pu o ar :}
   k ku ar CANONICAL p pu DISPLAY o MODEL-REMOTE--RECORD:MAKE ;

: LOCAL-RECORD
   ( ^u8 n MODEL:observation<MODEL:local> -- MODEL:local-record )
   {: p:^ pu o :}
   p pu DISPLAY o MODEL-LOCAL--RECORD:MAKE ;

\ Sixty-four "a"s, a Dropbox content hash.
: A-HASH ( ^ARENA:arena -- DROPBOX:hash )
   64 ARENA:ALLOC drop {: d:^ :}
   64 0 ?do 97 d i + c! loop
   d 64 >str DROPBOX:>HASH ;

\ The Rust tests' local_hash(path, marker).
: LOCAL-HASH ( ^u8 n n ^ARENA:arena -- MODEL:hash-record )
   {: p:^ pu m ar :}
   m 1000000000 mod {: ns :}
   p pu DISPLAY
   m 1 + m 2 + 1 ns 2 ns MODEL-FINGERPRINT:MAKE
   ar A-HASH MODEL-HASH--RECORD:MAKE ;

: REMOTES ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW ;

: LOCALS ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   ARENA:ALLOCATOR 0 [type] MODEL:local-record VEC:NEW ;

: HASHES ( ^ARENA:arena -- ^VEC:vector<MODEL:hash-record> )
   ARENA:ALLOCATOR 0 [type] MODEL:hash-record VEC:NEW ;

: DELTA ( ^ARENA:arena -- ^VEC:vector<remote-inventory-change> )
   ARENA:ALLOCATOR 0 [type] remote-inventory-change VEC:NEW ;

: REMOTE+ ( MODEL:remote-record ^VEC:vector<MODEL:remote-record> -- )
   VEC:PUSH ! ;

: LOCAL+ ( MODEL:local-record ^VEC:vector<MODEL:local-record> -- )
   VEC:PUSH ! ;

: HASH+ ( MODEL:hash-record ^VEC:vector<MODEL:hash-record> -- )
   VEC:PUSH ! ;

: CHANGE+
   ( remote-inventory-change ^VEC:vector<remote-inventory-change> -- )
   VEC:PUSH ! ;

: UPSERT ( MODEL:remote-record -- remote-inventory-change )
   construct remote-inventory-change upsert ;

: ENSURE ( MODEL:remote-record -- remote-inventory-change )
   construct remote-inventory-change ensure-directory ;

: DELETE-SUBTREE ( MODEL:key -- remote-inventory-change )
   construct remote-inventory-change delete-subtree ;

: ONE-REMOTE
   ( MODEL:remote-record ^ARENA:arena
     -- ^VEC:vector<MODEL:remote-record> )
   {: r ar :}
   ar REMOTES {: v :} r v REMOTE+ v ;

: ONE-LOCAL
   ( MODEL:local-record ^ARENA:arena
     -- ^VEC:vector<MODEL:local-record> )
   {: r ar :}
   ar LOCALS {: v :} r v LOCAL+ v ;

: ONE-HASH
   ( MODEL:hash-record ^ARENA:arena -- ^VEC:vector<MODEL:hash-record> )
   {: r ar :}
   ar HASHES {: v :} r v HASH+ v ;

: ONE-CHANGE
   ( remote-inventory-change ^ARENA:arena
     -- ^VEC:vector<remote-inventory-change> )
   {: c ar :}
   ar DELTA {: v :} c v CHANGE+ v ;


\ ---- inventories' answers ----------------------------------------

: CURSOR-IS? ( option<DROPBOX:cursor> ^u8 n -- bool )
   {: a:^ u :}
   MATCH option
      none OF false ENDOF
      some OF DROPBOX:CURSOR>STR str> a u STR= ENDOF
   ;MATCH ;

: REMOTES=
   ( ^VEC:vector<MODEL:remote-record> ^VEC:vector<MODEL:remote-record>
     -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   true a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ MODEL:REMOTE-RECORD= and
   loop ;

: KEY-AT ( ^VEC:vector<MODEL:remote-record> n -- ^u8 n )
   VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p o :}
   k KEY-BYTES ;

: HELD-AS?
   ( MODEL:remote-record MODEL:key MODEL:observation<MODEL:remote>
     -- bool )
   {: k:MODEL:key o :}
   MODEL-REMOTE--RECORD:UNMAKE {: k2:MODEL:key p o2 :}
   k k2 MODEL:KEY= o o2 MODEL:REMOTE-OBSERVATION= and ;

\ Some record holds the key with the observation.
: HOLDS?
   ( ^VEC:vector<MODEL:remote-record> MODEL:key
     MODEL:observation<MODEL:remote> -- bool )
   {: v k:MODEL:key o :}
   false v VEC:COUNT 0 ?do v i VEC:AT @ k o HELD-AS? or loop ;

\ The inventory holds one record, with the observation.
: HOLDS-ONLY?
   ( remote-inventory MODEL:observation<MODEL:remote> -- bool )
   {: o :}
   JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   v VEC:COUNT 1 <> if false exit then
   v 0 VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k p o2 :}
   o o2 MODEL:REMOTE-OBSERVATION= ;

: DIRECTORY-IS?
   ( ^VEC:vector<remote-directory> n ^u8 n ^u8 n -- bool )
   {: v i k:^ ku p:^ pu :}
   v i VEC:AT @ JOURNAL-REMOTE--DIRECTORY:UNMAKE {: key path :}
   key KEY-BYTES k ku STR= path PATH-BYTES p pu STR= and ;

: SUBTREE-PLAN-ROW ( SQLITE:statement -- SQLITE:statement )
   3 SQLITE:COL-TEXT {: a:^ u :}
   a u s" remote_observations_by_canonical_path" CONTAINS? if
      1 INDEXED +!
   then
   a u s" SCAN remote_observations" CONTAINS? if 1 SCANNED +! then ;

\ The plan of deleting what lies beneath "a".
: SUBTREE-PLAN ( SQLITE:statement -- SQLITE:statement )
   s" a/" 1 SQLITE:BIND-BLOB
   s\" a/\xFF" 2 SQLITE:BIND-BLOB
   begin SQLITE:STEP while SUBTREE-PLAN-ROW repeat ;


\ ---- the Rust version's lines ------------------------------------

\ The text of a JSON string without its quotes.
: NAME-PUT ( n ^u8 n -- n )
   {: at a:^ u :}
   a 1+ u 2 - at PUT ;

: LOCAL-FILE-PUT ( n MODEL:local -- n )
   {: at l :}
   l MODEL-LOCAL:UNMAKE DROPBOX:HASH>STR {: h:str :}
   s" LocalFile { content: ContentIdentity(" at PUT
   h swap PUT-QUOTED s" ) }" rot PUT ;

: REMOTE-FILE-PUT ( n MODEL:remote -- n )
   {: at r :}
   r MODEL-REMOTE:UNMAKE {: h:DROPBOX:hash v:DROPBOX:rev :}
   s" RemoteFile { content: ContentIdentity(" at PUT
   h DROPBOX:HASH>STR swap PUT-QUOTED
   s" ), revision: DropboxRevision(" rot PUT
   v DROPBOX:REV>STR swap PUT-QUOTED s" ) }" rot PUT ;

\ Rust names a reason as serde does, the name MODEL's writer quotes.
: UNKNOWN-PUT ( n MODEL:unknown-reason ^JSON:writer -- n )
   {: at r w :}
   s" Unknown(" at PUT
   w [: r swap MODEL:UNKNOWN-REASON>JSON ;] ENCODE NAME-PUT
   s" )" rot PUT ;

: LOCAL-OBSERVATION-PUT
   ( n MODEL:observation<MODEL:local> ^JSON:writer -- n )
   {: at o w :}
   o MATCH MODEL:observation
      present OF
         s" Present(" at PUT swap LOCAL-FILE-PUT s" )" rot PUT
      ENDOF
      unknown OF {: r :} at r w UNKNOWN-PUT ENDOF
      directory OF
         at w [: o swap MODEL:LOCAL-OBSERVATION>JSON ;] ENCODE NAME-PUT
      ENDOF
      absent OF
         at w [: o swap MODEL:LOCAL-OBSERVATION>JSON ;] ENCODE NAME-PUT
      ENDOF
   ;MATCH ;

: REMOTE-OBSERVATION-PUT
   ( n MODEL:observation<MODEL:remote> ^JSON:writer -- n )
   {: at o w :}
   o MATCH MODEL:observation
      present OF
         s" Present(" at PUT swap REMOTE-FILE-PUT s" )" rot PUT
      ENDOF
      unknown OF {: r :} at r w UNKNOWN-PUT ENDOF
      directory OF
         at w [: o swap MODEL:REMOTE-OBSERVATION>JSON ;] ENCODE NAME-PUT
      ENDOF
      absent OF
         at w [: o swap MODEL:REMOTE-OBSERVATION>JSON ;] ENCODE NAME-PUT
      ENDOF
   ;MATCH ;

: LOCAL-RECORD-PUT ( n MODEL:local-record ^JSON:writer -- n )
   {: at r w :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   s" LocalObservationRecord { path: " at PUT
   p MODEL:PATH>STR swap PUT-QUOTED
   s" , observation: " rot PUT o w LOCAL-OBSERVATION-PUT
   s"  }" rot PUT ;

: REMOTE-RECORD-PUT ( n MODEL:remote-record ^JSON:writer -- n )
   {: at r w :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   s" RemoteObservationRecord { canonical_path: CanonicalPath(" at PUT
   k MODEL:KEY>STR swap PUT-QUOTED
   s" ), path: " rot PUT p MODEL:PATH>STR swap PUT-QUOTED
   s" , observation: " rot PUT o w REMOTE-OBSERVATION-PUT
   s"  }" rot PUT ;

: SEPARATED ( n n -- n )
   {: at i :}
   i 0 > if s" , " at PUT exit then
   at ;

: LOCALS-PUT ( n ^VEC:vector<MODEL:local-record> ^JSON:writer -- n )
   {: at v w :}
   s" [" at PUT
   v VEC:COUNT 0 ?do i SEPARATED v i VEC:AT @ w LOCAL-RECORD-PUT loop
   s" ]" rot PUT ;

: REMOTES-PUT ( n ^VEC:vector<MODEL:remote-record> ^JSON:writer -- n )
   {: at v w :}
   s" [" at PUT
   v VEC:COUNT 0 ?do i SEPARATED v i VEC:AT @ w REMOTE-RECORD-PUT loop
   s" ]" rot PUT ;

: CURSOR-PUT ( option<DROPBOX:cursor> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF
         DROPBOX:CURSOR>STR {: c:str :}
         s" Some(" at PUT c swap PUT-QUOTED s" )" rot PUT
      ENDOF
   ;MATCH ;

: LOCAL-INVENTORY-DEBUG
   ( ^VEC:vector<MODEL:local-record> ^JSON:writer -- ^u8 n )
   {: v w :}
   s\" local_inventory\t" 0 PUT v w LOCALS-PUT {: u :}
   WANT u ;

: REMOTE-CURSOR-DEBUG ( option<DROPBOX:cursor> -- ^u8 n )
   s\" remote_cursor\t" 0 PUT CURSOR-PUT {: u :}
   WANT u ;

: REMOTE-INVENTORY-DEBUG ( remote-inventory ^JSON:writer -- ^u8 n )
   {: inv w :}
   inv JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s\" remote_inventory\tRemoteInventory { cursor: " 0 PUT
   CURSOR-PUT
   s" , observations: " rot PUT v w REMOTES-PUT
   s"  }" rot PUT {: u :}
   WANT u ;

: INVENTORY-LINES ( journal ^ARENA:arena ^JSON:writer -- )
   {: j ar w :}
   j ar LOCAL-INVENTORY w LOCAL-INVENTORY-DEBUG HELD? TTRUE
   j ar REMOTE-CURSOR REMOTE-CURSOR-DEBUG HELD? TTRUE
   j ar REMOTE-INVENTORY w REMOTE-INVENTORY-DEBUG HELD? TTRUE ;


\ ---- test-only words of the Rust version -------------------------

: LOCAL-INVENTORY-WRITTEN
   ( SQLITE:connection ^VEC:vector<MODEL:local-record> ^JSON:writer -- )
   {: c v w :}
   c s" DELETE FROM local_observations" SQLITE:EXEC
   c INSERT-LOCAL [: v w LOCAL-INSERTS ;] SQLITE:WITH-STATEMENT ;

\ Replaces the local inventory, and nothing else, in one transaction.
: PUBLISH-LOCAL-INVENTORY
   ( journal ^VEC:vector<MODEL:local-record> -- )
   {: j v :}
   j >CONNECTION {: c :}
   c [: c v [: LOCAL-INVENTORY-WRITTEN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;


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


\ ---- inventories -------------------------------------------------

: ORACLE-JOURNAL-HOLDS-ITS-INVENTORIES ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's inventories are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p str> FS:COPY-FILE-STREAM
   p OPEN {: j :}
   j ar [: INVENTORY-LINES ;] ENCODING
   j CLOSE
   d GONE ;

: PUBLISH-DUPLICATES ( -- )
   THE-JOURNAL @ s" cursor-new" CURSOR THE-REMOTES @
   PUBLISH-REMOTE-INVENTORY ;

: JOURNAL-REMOTE-INVENTORY-AND-CURSOR-PUBLISH-ATOMICALLY
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_remote_inventory_and_cursor_publish_atomically" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" old.txt" s" old.txt" s" old" s" rev-old" PRESENT-REMOTE ar
   REMOTE-RECORD ar ONE-REMOTE {: old :}
   j s" cursor-old" CURSOR old PUBLISH-REMOTE-INVENTORY
   ar REMOTES {: dups :}
   s" duplicate.txt" s" duplicate.txt" ABSENT-REMOTE ar REMOTE-RECORD
   dups REMOTE+
   s" duplicate.txt" s" duplicate.txt" s" new" s" rev-new" PRESENT-REMOTE
   ar REMOTE-RECORD dups REMOTE+
   j THE-JOURNAL !  dups THE-REMOTES !
   [: PUBLISH-DUPLICATES ;] SQLITE:E-SQL d s" UNIQUE constraint failed"
   ar LOGGED
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s" cursor-old" CURSOR-IS? TTRUE
   v old REMOTES= TTRUE
   j CLOSE
   d GONE ;

\ bulk/NNNNN.txt, n in five digits.
: BULK-PATH ( n ^ARENA:arena -- MODEL:path )
   {: n ar :}
   ar 14 ARENA:ALLOC drop {: dst:^ :}
   s" bulk/" drop dst 5 BYTE-COPY
   s" .txt" drop dst 10 + 4 BYTE-COPY
   n 5 0 ?do dup 10 mod 48 + dst 9 i - + c! 10 / loop drop
   dst 14 >str MODEL:>PATH ;

: OLD-FILE ( -- MODEL:observation<MODEL:remote> )
   s" old" s" rev-old" PRESENT-REMOTE ;

: NEW-FILE ( -- MODEL:observation<MODEL:remote> )
   s" new" s" rev-new" PRESENT-REMOTE ;

: BULK-RECORD
   ( n ^ARENA:arena MODEL:observation<MODEL:remote>
     -- MODEL:remote-record )
   {: n ar o :}
   n ar BULK-PATH {: p:MODEL:path :}
   p ar MODEL:FOLD p o MODEL-REMOTE--RECORD:MAKE ;

: BULK-DIRECTORY ( ^ARENA:arena -- MODEL:remote-record )
   {: ar :}
   s" bulk" s" Bulk" REMOTE-DIRECTORY ar REMOTE-RECORD ;

\ "Bulk" and 9,999 files beneath it.
: BULK ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: ar :}
   ar REMOTES {: v :}
   ar BULK-DIRECTORY v REMOTE+
   10000 1 ?do i ar OLD-FILE BULK-RECORD v REMOTE+ loop
   v ;

: REMOTE-DELTA-MUTATES-ONLY-CHANGED-ROWS-AND-CURSOR ( ^ARENA:arena -- )
   {: ar :}
   s" remote_delta_mutates_only_changed_rows_and_cursor" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" cursor-old" CURSOR ar BULK PUBLISH-REMOTE-INVENTORY
   j CHANGED {: before-empty :}
   j s" cursor-empty" CURSOR ar DELTA APPLY-REMOTE-INVENTORY-DELTA
   j CHANGED before-empty - 1 T=
   5000 ar NEW-FILE BULK-RECORD {: changed :}
   5000 ar BULK-PATH ar MODEL:FOLD {: key:MODEL:key :}
   ar DELTA {: changes :}
   ar BULK-DIRECTORY UPSERT changes CHANGE+
   key DELETE-SUBTREE changes CHANGE+
   changed UPSERT changes CHANGE+
   j CHANGED {: before-change :}
   j s" cursor-new" CURSOR changes APPLY-REMOTE-INVENTORY-DELTA
   j CHANGED before-change - 3 T=
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s" cursor-new" CURSOR-IS? TTRUE
   v VEC:COUNT 10000 T=
   v key NEW-FILE HOLDS? TTRUE
   j CLOSE
   d GONE ;

: SUBTREE-SAMPLE ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: ar :}
   ar REMOTES {: v :}
   s" a" s" a" REMOTE-DIRECTORY ar REMOTE-RECORD v REMOTE+
   s" a/child.txt" s" a/child.txt" s" a-child" s" rev-a" PRESENT-REMOTE
   ar REMOTE-RECORD v REMOTE+
   s" ab" s" ab" REMOTE-DIRECTORY ar REMOTE-RECORD v REMOTE+
   s" ab/child.txt" s" ab/child.txt" s" ab-child" s" rev-ab"
   PRESENT-REMOTE ar REMOTE-RECORD v REMOTE+
   s" a-file.txt" s" a-file.txt" s" a-file" s" rev-a-file"
   PRESENT-REMOTE ar REMOTE-RECORD v REMOTE+
   v ;

: SUBTREE-PLAN-SQL ( -- ^u8 n )
   s" EXPLAIN QUERY PLAN " 0 PUT
   DELETE-REMOTE-DESCENDANTS rot PUT {: u :}
   WANT u ;

: REMOTE-DELTA-DELETES-ONLY-THE-NAMED-SUBTREE ( ^ARENA:arena -- )
   {: ar :}
   s" remote_delta_deletes_only_the_named_subtree" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" cursor-old" CURSOR ar SUBTREE-SAMPLE PUBLISH-REMOTE-INVENTORY
   0 INDEXED !  0 SCANNED !
   j >CONNECTION SUBTREE-PLAN-SQL [: SUBTREE-PLAN ;]
   SQLITE:WITH-STATEMENT
   INDEXED @ 0 > TTRUE
   SCANNED @ 0 T=
   j s" cursor-new" CURSOR
   s" a" ar CANONICAL DELETE-SUBTREE ar ONE-CHANGE
   APPLY-REMOTE-INVENTORY-DELTA
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s" cursor-new" CURSOR-IS? TTRUE
   v VEC:COUNT 3 T=
   v 0 KEY-AT s" a-file.txt" T$=
   v 1 KEY-AT s" ab" T$=
   v 2 KEY-AT s" ab/child.txt" T$=
   j CLOSE
   d GONE ;

: SHARED ( MODEL:observation<MODEL:remote> ^ARENA:arena
   -- MODEL:remote-record )
   {: o ar :}
   s" shared" s" Shared" o ar REMOTE-RECORD ;

: REMOTE-DELTA-ENSURED-DIRECTORY-KEEPS-AN-UNKNOWN-FOLDER
   ( ^ARENA:arena -- )
   {: ar :}
   s" remote_delta_ensured_directory_keeps_an_unknown_folder" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" cursor-old" CURSOR INACCESSIBLE ar SHARED ar ONE-REMOTE
   PUBLISH-REMOTE-INVENTORY
   j s" cursor-ensure" CURSOR REMOTE-DIRECTORY ar SHARED ENSURE
   ar ONE-CHANGE APPLY-REMOTE-INVENTORY-DELTA
   j ar REMOTE-INVENTORY INACCESSIBLE HOLDS-ONLY? TTRUE
   j s" cursor-upsert" CURSOR REMOTE-DIRECTORY ar SHARED UPSERT
   ar ONE-CHANGE APPLY-REMOTE-INVENTORY-DELTA
   j ar REMOTE-INVENTORY REMOTE-DIRECTORY HOLDS-ONLY? TTRUE
   j CLOSE
   d GONE ;

: RESTRICTED-SAMPLE ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: ar :}
   ar REMOTES {: v :}
   s" docs" s" Docs" REMOTE-DIRECTORY ar REMOTE-RECORD v REMOTE+
   s" docs/a.txt" s" Docs/A.txt" s" a" s" rev-a" PRESENT-REMOTE
   ar REMOTE-RECORD v REMOTE+
   s" shared" s" Shared" INACCESSIBLE ar REMOTE-RECORD v REMOTE+
   v ;

: REMOTE-DIRECTORY-PATHS-INCLUDE-RESTRICTED-FOLDERS ( ^ARENA:arena -- )
   {: ar :}
   s" remote_directory_paths_include_restricted_folders" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" cursor" CURSOR ar RESTRICTED-SAMPLE PUBLISH-REMOTE-INVENTORY
   j ar REMOTE-DIRECTORY-PATHS {: v :}
   v VEC:COUNT 2 T=
   v 0 s" docs" s" Docs" DIRECTORY-IS? TTRUE
   v 1 s" shared" s" Shared" DIRECTORY-IS? TTRUE
   j CLOSE
   d GONE ;

: PUBLISH-HELD-SCAN ( -- )
   THE-JOURNAL @ THE-BINDING @ THE-LOCALS @ THE-HASHES @
   PUBLISH-LOCAL-SCAN drop ;

\ The local inventory and hash cache are the one record and hash given.
: SCAN-HELD
   ( journal MODEL:local-record MODEL:hash-record ^ARENA:arena -- )
   {: j r h ar :}
   j ar LOCAL-INVENTORY r ar ONE-LOCAL LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE h ar ONE-HASH HASH-RECORDS= TTRUE ;

: ACTIVATED ( local-root-activation -- ) drop ;

: JOURNAL-LOCAL-SCAN-REPLACES-INVENTORY-AND-HASHES-ATOMICALLY
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_local_scan_replaces_inventory_and_hashes_atomically"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" /sync" 2 LOCAL-ROOT {: b :}
   j b ar ACTIVATE-LOCAL-ROOT ACTIVATED
   s" old.txt" s" old" PRESENT-LOCAL LOCAL-RECORD {: old :}
   s" old.txt" 10 ar LOCAL-HASH {: old-hash :}
   j b old ar ONE-LOCAL old-hash ar ONE-HASH PUBLISH-LOCAL-SCAN TTRUE
   j CHANGED {: unchanged :}
   j b old ar ONE-LOCAL old-hash ar ONE-HASH PUBLISH-LOCAL-SCAN TTRUE
   j CHANGED unchanged T=
   s" new.txt" s" new" PRESENT-LOCAL LOCAL-RECORD ar ONE-LOCAL
   {: replacement :}
   ar HASHES {: dups :}
   s" new.txt" 20 ar LOCAL-HASH dups HASH+
   s" new.txt" 30 ar LOCAL-HASH dups HASH+
   j THE-JOURNAL !  b THE-BINDING !
   replacement THE-LOCALS !  dups THE-HASHES !
   [: PUBLISH-HELD-SCAN ;] SQLITE:E-SQL d s" UNIQUE constraint failed"
   ar LOGGED
   j old old-hash ar SCAN-HELD
   j CHANGED {: stale :}
   j s" /stale" 4 LOCAL-ROOT replacement
   s" new.txt" 20 ar LOCAL-HASH ar ONE-HASH PUBLISH-LOCAL-SCAN TFALSE
   j CHANGED stale T=
   j old old-hash ar SCAN-HELD
   j CLOSE
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
   ar ORACLE-JOURNAL-HOLDS-ITS-INVENTORIES
   ar JOURNAL-REMOTE-INVENTORY-AND-CURSOR-PUBLISH-ATOMICALLY
   ar REMOTE-DELTA-MUTATES-ONLY-CHANGED-ROWS-AND-CURSOR
   ar REMOTE-DELTA-DELETES-ONLY-THE-NAMED-SUBTREE
   ar REMOTE-DELTA-ENSURED-DIRECTORY-KEEPS-AN-UNKNOWN-FOLDER
   ar REMOTE-DIRECTORY-PATHS-INCLUDE-RESTRICTED-FOLDERS
   ar JOURNAL-LOCAL-SCAN-REPLACES-INVENTORY-AND-HASHES-ATOMICALLY ;


: TESTS ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" journal-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

TESTS

;package
