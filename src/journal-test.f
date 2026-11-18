\ journal-test.f - JOURNAL's open, schema 8, bindings, inventories,
\ baselines, plans, completions, conflicts and recoveries on journals
\ under TMPDIR: a new journal's sqlite_master and user_version against
\ src/oracle/schema.tsv as a set; versions 1, 7 and 9 refused unchanged;
\ src/oracle/journal.sqlite3, copied and opened, giving journal.tsv's
\ Dropbox and local root bindings, local and remote inventories, remote
\ cursor, baselines, baseline paths, pending and blocked plans, pending
\ upload content, conflicts and pending and completed recoveries, each in
\ the line's own form; a file of other bytes refused as corrupt by both
\ opens, unchanged; a failed open's E-FILE leaving EACCES in FS:ERRNO;
\ and fifty-one tests of the Rust version's src/journal.rs and two of
\ its src/daemon.rs under their names, which
\ build each decision the Rust ones ask the planner for as
\ src/oracle/plan.tsv holds it. Habu opens no
\ schema-6 file, so the version-six tests start from a schema-8 journal
\ holding the row migration 7 leaves for a schema-6 root, birth and
\ subvolume NULL, and the baseline the Rust tests' version_six_with_root
\ writes. A copy of the oracle journal with a value MODEL cannot read
\ in one row of each stored family is refused by the word that reads
\ it, as E-JSON naming the row's path. Each case removes its directory;
\ a refusal's log line is captured in it, checked and removed.
\ Run from the repository root: hb --load src/journal-test.f </dev/null
require src/lib/error.f
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
require src/test-journal.f

\ JOURNAL reopened: a case reads the journal's connection, its rows, the
\ bindings' and records' fields, and the inventories' private words.
package JOURNAL
private

8192 constant CAP
CAP BUFFER: BODY       \ an oracle file, after a newline
CAP BUFFER: LINE       \ a line looked for in BODY
CAP BUFFER: WANT       \ a binding as the Rust version prints it
variable BODY-U
$1A4 constant MODE-SHARED
$140 constant MODE-SEALED          \ 0500
$1C0 constant MODE-DIR-OWNER       \ 0700

TYPED-VARIABLE ACTION [ -- ]
TYPED-VARIABLE SUBJECT str
TYPED-VARIABLE SUBJECT-ARENA ^ARENA:arena


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

: MODE-OF ( str -- n ) FS:STAT-MODE MODE-BITS and ;


\ The action throws want with fd 2 sent to dir/stderr.txt, which then
\ holds one line with the text and is removed.
: LOGGED ( [ -- ] n str ^u8 n ^ARENA:arena -- )
   {: want dir:str t:^ tu ar :}
   ACTION !
   dir s" stderr.txt" ar INSIDE {: f:str :}
   ACTION @ f ar STDERR:CAPTURING str> {: code:n e:^ u:n :}
   code want T=
   e u >str 10 COUNT-CHAR 1 T=
   e u t tu CONTAINS? TTRUE ;

\ The action runs with fd 2 sent to dir/stderr.txt, which then is empty
\ and is removed.
: SILENT ( [ -- ] str ^ARENA:arena -- )
   {: dir:str ar :}
   ACTION !
   dir s" stderr.txt" ar INSIDE {: f:str :}
   ACTION @ f ar STDERR:CAPTURING str> nip {: code:n u:n :}
   code 0<> if code throw then
   u 0 T= ;


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
   REMOTE-FILE MODEL-OBSERVATION:PRESENT ;

: ABSENT-REMOTE ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:ABSENT ;

: INACCESSIBLE ( -- MODEL:observation<MODEL:remote> )
   MODEL-UNKNOWN--REASON:INACCESSIBLE MODEL-OBSERVATION:UNKNOWN ;

: PRESENT-LOCAL ( ^u8 n -- MODEL:observation<MODEL:local> )
   CONTENT MODEL-LOCAL:MAKE MODEL-OBSERVATION:PRESENT ;

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
: ANY-HOLDS?
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
   s" a/" >str 1 SQLITE:BIND-BLOB
   s\" a/\xFF" >str 2 SQLITE:BIND-BLOB
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
   c INSERT-LOCAL >str [: v w LOCAL-INSERTS ;] SQLITE:WITH-STATEMENT ;

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
   0 j >CONNECTION SCHEMA-SQL >str [: SCHEMA-ROWS ;] SQLITE:WITH-STATEMENT
   26 T=
   j >CONNECTION VERSION 8 T=
   s\" user_version\t8" HELD? TTRUE
   BODY BODY-U @ >str 10 COUNT-CHAR 28 T=
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
   p MODE-SHARED FS:CHMOD-MODE
   p OPEN-READ {: j :}
   p MODE-OF MODE-SHARED T=
   j CLOSE
   d GONE ;

: WRITABLE-JOURNAL-RESTRICTS-EXISTING-DATABASE ( ^ARENA:arena -- )
   {: ar :}
   s" writable_journal_restricts_existing_database" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN CLOSE
   p MODE-SHARED FS:CHMOD-MODE
   p OPEN {: j :}
   p MODE-OF MODE-OWNER T=
   j CLOSE
   d GONE ;

: BUSY-MS-OF ( journal -- n )
   >CONNECTION s" PRAGMA busy_timeout" QUERY-INT ;

: EVERY-CONNECTION-WAITS-OUT-A-CONCURRENT-COMMIT ( ^ARENA:arena -- )
   {: ar :}
   s" every_connection_waits_out_a_concurrent_commit" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   p OPEN-READ {: k :}
   j BUSY-MS-OF BUSY-MS T=
   k BUSY-MS-OF BUSY-MS T=
   k CLOSE
   j CLOSE
   d GONE ;

\ The journal mode's name, exactly as SQLite reports it.
: DELETE-ROW? ( SQLITE:statement -- bool SQLITE:statement )
   SQLITE:STEP drop 0 SQLITE:COL-TEXT s" delete" STR= swap ;

: WRITABLE-JOURNAL-USES-FULL-SYNCHRONOUS-ROLLBACK-MODE
   ( ^ARENA:arena -- )
   {: ar :}
   s" writable_journal_uses_full_synchronous_rollback_mode" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j >CONNECTION {: c :}
   c s" PRAGMA journal_mode" >str [: DELETE-ROW? ;] SQLITE:WITH-STATEMENT
   TTRUE
   c s" PRAGMA synchronous" QUERY-INT 2 T=
   j BUSY-MS-OF 5000 T=
   c s" PRAGMA foreign_keys" QUERY-INT 1 T=
   j CLOSE
   d GONE ;

: CREATE-FAILED ( -- ^u8 n )
   s" journal operation `create journal database` failed for" ;

\ Opening path throws E-FILE with a log line in dir holding the text.
: OPEN-REFUSED ( str str ^u8 n ^ARENA:arena -- )
   {: path:str dir:str t:^ tu ar :}
   path SUBJECT !
   [: SUBJECT @ OPEN CLOSE ;] E-FILE dir t tu ar LOGGED ;

\ A file failure on ENOSPC throws E-DISK-FULL, logged as E-FILE is.
: A-FULL-DISK-IS-ITS-OWN-CODE ( ^ARENA:arena -- )
   {: ar :}
   s" a full disk is its own code" T-LABEL
   ar SCRATCH {: d:str :}
   d SUBJECT !
   [: s" create journal database" >str SUBJECT @ E-FS-OPEN FS:ENOSPC
      FILE-FAILED ;] E-DISK-FULL d CREATE-FAILED ar LOGGED
   d GONE ;

: JOURNAL-CREATION-REPORTS-ITS-OWN-FILESYSTEM-FAILURE
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_creation_reports_its_own_filesystem_failure" T-LABEL
   ar SCRATCH {: d:str :}
   d s" sealed" ar INSIDE {: sealed:str :}
   sealed str> FS:MAKE-DIR
   sealed MODE-SEALED FS:CHMOD-MODE
   sealed s" journal.sqlite3" ar INSIDE {: path:str :}
   path d CREATE-FAILED ar OPEN-REFUSED
   sealed MODE-DIR-OWNER FS:CHMOD-MODE
   d GONE ;

variable SEEN          \ FS:ERRNO as OPEN's throw left it

: OPEN-NOTING ( -- )
   [: SUBJECT @ OPEN CLOSE ;] catch FS:ERRNO SEEN ! throw ;

: A-FAILED-OPEN-KEEPS-THE-HOST-ERRNO ( ^ARENA:arena -- )
   {: ar :}
   s" a failed open keeps the host errno" T-LABEL
   ar SCRATCH {: d:str :}
   d s" sealed" ar INSIDE {: sealed:str :}
   sealed str> FS:MAKE-DIR
   sealed MODE-SEALED FS:CHMOD-MODE
   sealed s" journal.sqlite3" ar INSIDE SUBJECT !
   [: OPEN-NOTING ;] E-FILE d CREATE-FAILED ar LOGGED
   SEEN @ FS:EACCES T=
   sealed MODE-DIR-OWNER FS:CHMOD-MODE
   d GONE ;

: JOURNAL-REFUSES-A-SYMLINKED-DATABASE ( ^ARENA:arena -- )
   {: ar :}
   s" journal_refuses_a_symlinked_database" T-LABEL
   ar SCRATCH {: d:str :}
   d s" planted.sqlite3" ar INSIDE {: planted:str :}
   d s" dangling.sqlite3" ar INSIDE {: dangling:str :}
   planted dangling FS:MAKE-SYMLINK
   dangling d CREATE-FAILED ar OPEN-REFUSED
   planted FS:EXISTS? TFALSE
   d s" existing.sqlite3" ar INSIDE {: existing:str :}
   existing OPEN CLOSE
   d s" linked.sqlite3" ar INSIDE {: linked:str :}
   existing linked FS:MAKE-SYMLINK
   linked d s" `: existing path is not a regular file" ar
   OPEN-REFUSED
   d GONE ;

: GARBAGE ( -- ^u8 n )
   s" these bytes are text, not a SQLite database's" ;

: GARBAGE-KEPT? ( str -- bool )
   str> BODY CAP FS:READ-ALL {: u :}
   BODY u GARBAGE STR= ;

: GARBAGE-FILE-IS-CORRUPT ( ^ARENA:arena -- )
   {: ar :}
   s" a file of other bytes is corrupt to both opens" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p str> GARBAGE FS:WRITE-ALL
   p SUBJECT !
   [: SUBJECT @ OPEN CLOSE ;] SQLITE:E-CORRUPT d
   s" file is not a database" ar LOGGED
   p GARBAGE-KEPT? TTRUE
   [: SUBJECT @ OPEN-READ CLOSE ;] SQLITE:E-CORRUPT d
   s" file is not a database" ar LOGGED
   p GARBAGE-KEPT? TTRUE
   d GONE ;

\ The identity statx gives for the directory, read here on its own.
: STATX-ROOT ( str -- local-root-binding )
   {: d:str :}
   d FS:TRY-STAT TTRUE
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
   [: SUBJECT @ INSPECT drop ;] E-ROOT d
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
   SUBVOLUME-OF NO-INT? TTRUE
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

\ A directory whose filesystem reports no birth time.
: SYS-KERNEL ( -- str ) s" /sys/kernel" >str ;

: SYS-INODE ( -- n ) SYS-KERNEL FS:TRY-STAT TTRUE FS:STAT-INO@ ;

: SYS-REFUSAL ( -- ^u8 n ) s" sync root `/sys/kernel` is on" ;

: SYS-ROOT ( n option<birth-time> -- local-root-binding )
   {: inode birth :}
   SYS-KERNEL inode birth NO-SUBVOLUME
   JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

: INSPECT-SYS ( -- option<local-root-binding> )
   SYS-KERNEL THE-JOURNAL @ SUBJECT-ARENA @ INSPECT-ROOT ;

: NO-ROOT? ( option<local-root-binding> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: STANDS-IN ( -- ) INSPECT-SYS NO-ROOT? TTRUE ;

: REFUSES ( -- ) INSPECT-SYS drop ;

\ The root /sys/kernel stands in for, recorded at inode n.
: SYS-RECORDED ( journal n option<birth-time> -- )
   {: j inode birth :}
   inode birth SYS-ROOT 1 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: r :}
   j >CONNECTION r WRITE-LOCAL-ROOT ;

\ The Rust test's dispositions and public statuses are DAEMON's, left
\ out.
: ROOT-INSPECTION-FAILURE-IS-UNAVAILABLE-ONLY-FOR-A-STAND-IN
   ( ^ARENA:arena -- )
   {: ar :}
   s" root_inspection_failure_is_unavailable_only_for_a_stand_in"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j THE-JOURNAL !  ar SUBJECT-ARENA !
   SYS-INODE {: inode :}
   [: REFUSES ;] E-NO-BIRTH-TIME d SYS-REFUSAL ar LOGGED
   j inode BIRTH-5 OPTION:SOME SYS-RECORDED
   [: STANDS-IN ;] d ar SILENT
   j inode NO-BIRTH SYS-RECORDED
   [: REFUSES ;] E-NO-BIRTH-TIME d SYS-REFUSAL ar LOGGED
   j CLOSE
   d GONE ;

\ The Rust test's configuration and daemon error are DAEMON's, left
\ out: INSPECT-ROOT's none is the root unavailable.
: STAND-IN-WITHOUT-BIRTH-TIME-LEAVES-THE-ROOT-UNAVAILABLE
   ( ^ARENA:arena -- )
   {: ar :}
   s" stand_in_without_birth_time_leaves_the_root_unavailable" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   SYS-KERNEL SUBJECT !
   [: SUBJECT @ INSPECT drop ;] E-NO-BIRTH-TIME d SYS-REFUSAL ar LOGGED
   p OPEN {: j :}
   j THE-JOURNAL !  ar SUBJECT-ARENA !
   j 1 BIRTH-5 OPTION:SOME SYS-ROOT ar ACTIVATE-LOCAL-ROOT drop
   [: STANDS-IN ;] d ar SILENT
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
   >str [: SCHEMA-TEXT ;] SQLITE:WITH-STATEMENT {: u :}
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
   j TOTAL-CHANGES {: before-empty :}
   j s" cursor-empty" CURSOR ar DELTA APPLY-REMOTE-INVENTORY-DELTA
   j TOTAL-CHANGES before-empty - 1 T=
   5000 ar NEW-FILE BULK-RECORD {: changed :}
   5000 ar BULK-PATH ar MODEL:FOLD {: key:MODEL:key :}
   ar DELTA {: changes :}
   ar BULK-DIRECTORY UPSERT changes CHANGE+
   key DELETE-SUBTREE changes CHANGE+
   changed UPSERT changes CHANGE+
   j TOTAL-CHANGES {: before-change :}
   j s" cursor-new" CURSOR changes APPLY-REMOTE-INVENTORY-DELTA
   j TOTAL-CHANGES before-change - 3 T=
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s" cursor-new" CURSOR-IS? TTRUE
   v VEC:COUNT 10000 T=
   v key NEW-FILE ANY-HOLDS? TTRUE
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
   j >CONNECTION SUBTREE-PLAN-SQL >str [: SUBTREE-PLAN ;]
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
   j TOTAL-CHANGES {: unchanged :}
   j b old ar ONE-LOCAL old-hash ar ONE-HASH PUBLISH-LOCAL-SCAN TTRUE
   j TOTAL-CHANGES unchanged T=
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
   j TOTAL-CHANGES {: stale :}
   j s" /stale" 4 LOCAL-ROOT replacement
   s" new.txt" 20 ar LOCAL-HASH ar ONE-HASH PUBLISH-LOCAL-SCAN TFALSE
   j TOTAL-CHANGES stale T=
   j old old-hash ar SCAN-HELD
   j CLOSE
   d GONE ;


\ ---- baselines and plans -----------------------------------------

TYPED-VARIABLE HELD-JOURNAL journal
TYPED-VARIABLE HELD-ARENA ^ARENA:arena
TYPED-VARIABLE NOOPS ^VEC:vector<path-baseline>
TYPED-VARIABLE PLANS ^VEC:vector<path-plan>
TYPED-VARIABLE FINALS ^VEC:vector<operation-baseline>

: PATH= ( MODEL:path MODEL:path -- bool )
   PATH-BYTES {: b:^ bu :}
   PATH-BYTES b bu STR= ;

\ The planner's decisions for the Rust tests' plan() calls, built here
\ as src/oracle/plan.tsv holds them. An upload: a new local file, no
\ remote one, no baseline.
: UPLOAD-DECISION ( ^u8 n -- MODEL:decision )
   CONTENT MODEL-OPERATION:CREATE-REMOTE MODEL-DECISION:OPERATE ;

\ Both sides present with the remote file's content, whatever the
\ baseline: the remote file becomes the baseline.
: MATCH-DECISION ( MODEL:remote -- MODEL:decision )
   MODEL-BASELINE:PRESENT MODEL-DECISION:NOOP ;

\ A download: no baseline, the local side confirmed absent, the remote
\ file present.
: DOWNLOAD-DECISION ( MODEL:remote -- MODEL:decision )
   MODEL-OPERATION:INSTALL-LOCAL MODEL-DECISION:OPERATE ;

\ Both sides confirmed absent.
: ABSENT-DECISION ( -- MODEL:decision )
   MODEL-BASELINE:ABSENT MODEL-DECISION:NOOP ;

\ A directory on both sides and in the baseline.
: DIRECTORY-DECISION ( -- MODEL:decision )
   MODEL-BASELINE:DIRECTORY MODEL-DECISION:NOOP ;

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
   v 0 VEC:AT @ a au DISPLAY PATH=
   v 1 VEC:AT @ b bu DISPLAY PATH= and ;

: ROWS-AT ( journal MODEL:path -- n )
   {: j path :}
   j >CONNECTION s" SELECT COUNT(*) FROM baselines WHERE path = ?1"
   >str [: path PATH-BYTES >str 1 SQLITE:BIND-BLOB INT-ROW ;]
   SQLITE:WITH-STATEMENT ;

: AGREE ( journal ^u8 n ^u8 n ^u8 n ^ARENA:arena -- )
   {: j p:^ pu c:^ cu r:^ ru ar :}
   j p pu DISPLAY c cu r ru REMOTE-FILE MATCH-DECISION NOOP ar
   RECORD-NOOP drop ;

: DIRECTORY ( journal ^u8 n ^ARENA:arena -- )
   {: j p:^ pu ar :}
   j p pu DISPLAY DIRECTORY-DECISION NOOP ar RECORD-NOOP drop ;

: RECONCILE ( -- )
   HELD-JOURNAL @ NOOPS @ PLANS @ HELD-ARENA @ RECORD-RECONCILIATION
   drop ;

: EXISTS? ( MODEL:path -- bool ) drop true ;

: PROBE-FAILS ( MODEL:path -- bool ) drop E-INVALID-STATE throw ;

: NOT-GONE? ( MODEL:path -- bool ) s" Foo/gone.txt" DISPLAY PATH= 0= ;

: RECORD-IS? ( MODEL:baseline-record ^u8 n ^u8 n ^ARENA:arena -- bool )
   {: r k:^ ku p:^ pu ar :}
   r MODEL-BASELINE--RECORD:UNMAKE {: key path b :}
   key k ku ar CANONICAL MODEL:KEY= path p pu DISPLAY PATH= and ;


\ The id of the plan's first operation.
: FIRST-ID ( plan-record -- operation-id )
   >OPERATIONS 0 VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE
   {: i o x s :} i ;

: COMPLETE-FINALS ( -- )
   HELD-JOURNAL @ FINALS @ HELD-ARENA @ COMPLETE-FINAL-OPERATIONS drop ;

: SUPERSEDED? ( plan-supersede -- bool )
   MATCH plan-supersede
      not-found OF false ENDOF
      already-completed OF false ENDOF
      superseded OF true ENDOF
   ;MATCH ;

\ The Rust tests' DivergentEdits conflict.
: DIVERGENT ( -- MODEL:conflict )
   s" local" CONTENT MODEL-LOCAL:MAKE
   s" remote" s" rev-remote" REMOTE-FILE MODEL-CONFLICT:DIVERGENT ;

: CONFLICT-RECORD= ( conflict-record conflict-record -- bool )
   JOURNAL-CONFLICT--RECORD:UNMAKE {: i p x :}
   JOURNAL-CONFLICT--RECORD:UNMAKE {: j q y :}
   i j = p q PATH= and x y MODEL:CONFLICT= and ;


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
   j a u DISPLAY ar BASELINE at BASELINE-DEBUG {: v :}
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


\ ---- the oracle's conflicts as the Rust version prints them ------

: LOCAL-DEBUG ( MODEL:local n -- n )
   {: l at :}
   s" LocalFile { content: " at PUT
   l MODEL-LOCAL:UNMAKE swap HASH-DEBUG SHUT ;

\ A conflict that holds both sides: its name, then local and remote.
: BOTH-DEBUG ( ^u8 n MODEL:local MODEL:remote n -- n )
   {: a:^ u l r at :}
   a u at PUT
   s"  { local: " rot PUT  l swap LOCAL-DEBUG
   s" , remote: " rot PUT  r swap REMOTE-DEBUG
   s"  }" rot PUT ;

: CONFLICT-DEBUG ( MODEL:conflict n -- n )
   {: at :}
   MATCH MODEL:conflict
      initial OF
         {: l r :} s" InitialCollision" l r at BOTH-DEBUG
      ENDOF
      divergent OF {: l r :} s" DivergentEdits" l r at BOTH-DEBUG ENDOF
      local-deleted OF
         {: r :} s" LocalDeletionRemoteEdit { remote: " at PUT
         r swap REMOTE-DEBUG s"  }" rot PUT
      ENDOF
      remote-deleted OF
         {: l :} s" RemoteDeletionLocalEdit { local: " at PUT
         l swap LOCAL-DEBUG s"  }" rot PUT
      ENDOF
   ;MATCH ;

: RECORD-DEBUG ( conflict-record n -- n )
   {: r at :}
   r JOURNAL-CONFLICT--RECORD:UNMAKE {: id path x :}
   s" ConflictRecord { id: " at PUT  id swap PUT-N
   s" , path: " rot PUT  path MODEL:PATH>STR swap PUT-QUOTED
   s" , conflict: " rot PUT  x swap CONFLICT-DEBUG
   s"  }" rot PUT ;

: CONFLICTS-LINE ( ^VEC:vector<conflict-record> -- ^u8 n )
   {: found :}
   s\" conflicts\t[" 0 PUT
   found VEC:COUNT 0 ?do
      i 0<> if s" , " rot PUT then
      found i VEC:AT @ swap RECORD-DEBUG
   loop
   s" ]" rot PUT {: u :}
   WANT u ;

: ORACLE-JOURNAL-HOLDS-ITS-CONFLICTS ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's conflicts are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p str> FS:COPY-FILE-STREAM
   p OPEN-READ {: j :}
   j ar CONFLICTS CONFLICTS-LINE HELD? TTRUE
   j CLOSE
   d GONE ;


\ ---- the Rust version's baseline and plan tests ------------------

: JOURNAL-REOPEN-EXPOSES-INTENT-WITHOUT-ADVANCING-BASELINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_reopen_exposes_intent_without_advancing_baseline" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" notes/report.txt" DISPLAY {: path :}
   s" new" CONTENT MODEL-OPERATION:CREATE-REMOTE {: operation :}
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
   s" same.txt" DISPLAY agreed JOURNAL-PATH--BASELINE:MAKE
   noops VEC:PUSH !
   ar [type] path-plan NEW-VECTOR {: plans :}
   s" safe.txt" DISPLAY upload JOURNAL-PATH--PLAN:MAKE plans VEC:PUSH !
   s" reject.txt" DISPLAY upload JOURNAL-PATH--PLAN:MAKE plans VEC:PUSH !
   j HELD-JOURNAL !  ar HELD-ARENA !  noops NOOPS !  plans PLANS !
   [: RECONCILE ;] SQLITE:E-SQL d s" test rejection" ar LOGGED
   j s" same.txt" DISPLAY ar BASELINE NO-BASELINE? TTRUE
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j CLOSE
   d GONE ;

: WRITABLE-JOURNAL-NEVER-TRUNCATES-AN-EXISTING-DATABASE
   ( ^ARENA:arena -- )
   {: ar :}
   s" writable_journal_never_truncates_an_existing_database" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" kept.txt" DISPLAY {: path :}
   s" kept" s" rev-kept" REMOTE-FILE {: file :}
   p OPEN {: j :}
   j path file MATCH-DECISION NOOP ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j CLOSE
   p OPEN {: k :}
   k path ar BASELINE file MODEL-BASELINE:PRESENT BASELINE-HELD? TTRUE
   p MODE-OF MODE-OWNER T=
   k CLOSE
   d GONE ;

: JOURNAL-NOOP-REFRESHES-REVISION-BUT-CANNOT-CROSS-A-PENDING-PLAN
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_noop_refreshes_revision_but_cannot_cross_a_pending_plan"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" matching.txt" DISPLAY {: path :}
   s" same" s" rev-current" REMOTE-FILE {: observed :}
   observed MATCH-DECISION NOOP {: noop :}
   j path noop ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j path ar BASELINE observed MODEL-BASELINE:PRESENT BASELINE-HELD?
   TTRUE
   j TOTAL-CHANGES {: unchanged :}
   j path noop ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j TOTAL-CHANGES unchanged T=
   s" new" UPLOAD-DECISION ar OPERATIONS {: upload :}
   j path upload ar RECORD-PLAN RECORDED-PLAN {: pending :}
   ABSENT-DECISION NOOP {: absent :}
   j path absent ar RECORD-NOOP pending >ID OWNED-BY? TTRUE
   j path ar BASELINE
   s" same" s" rev-current" REMOTE-FILE MODEL-BASELINE:PRESENT
   BASELINE-HELD? TTRUE
   j CLOSE
   d GONE ;

: ABSENT-BASELINE-REMOVES-ITS-ROW ( ^ARENA:arena -- )
   {: ar :}
   s" absent_baseline_removes_its_row" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" removed.txt" DISPLAY {: path :}
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
   j s" p" DISPLAY [: EXISTS? ;] ar INVALIDATE-CASE-COLLISION-BASELINES
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
   [: j s" foo" DISPLAY [: PROBE-FAILS ;] ar
      INVALIDATE-CASE-COLLISION-BASELINES ;] E-INVALID-STATE TTHROWSQ
   j ar BASELINE-PATHS all PATHS= TTRUE
   j s" foo" DISPLAY [: NOT-GONE? ;] ar
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
   b s" zulu" s" rev-zulu" REMOTE-FILE MODEL-BASELINE:PRESENT
   MODEL:BASELINE= TTRUE
   j CLOSE
   d GONE ;


\ ---- the oracle's plans as the Rust version prints them ----------

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
   s" blocked.txt" DISPLAY {: path :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   s" insufficient_space" >str MODEL-BLOCKAGE:REMOTE-REJECTED {: why :}
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
   MODEL-BLOCKAGE:STAGE-OCCUPIED {: stage :}
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
   MODEL-BLOCKAGE:LOCAL-OBJECT-IN-WAY {: why :}
   p OPEN {: j :}
   j s" Contested.TXT" DISPLAY upload ar RECORD-PLAN RECORDED-PLAN
   >ID {: id :}
   j id why 1700000000 ar BLOCK-PLAN BLOCK-N 2 T=
   j s" contested.txt" DISPLAY upload ar RECORD-PLAN ALREADY-LIVE-PLAN
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
   j a u DISPLAY plan ar RECORD-PLAN RECORDED-PLAN drop ;

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
   displaced MODEL-LOCAL:MAKE MODEL-OPERATION:PRESERVE-LOCAL
   ops VEC:PUSH !
   displaced MODEL-OPERATION:DELETE-LOCAL ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE {: ordered :}
   p OPEN {: j :}
   j s" a.txt" upload ar RECORD-UPLOAD
   j s" b.txt" upload ar RECORD-UPLOAD
   j s" c.txt" upload ar RECORD-UPLOAD
   j s" d.txt" DISPLAY ordered ar RECORD-PLAN RECORDED-PLAN
   >OPERATIONS VEC:COUNT 1 > TTRUE
   j ar PENDING-PLANS {: plans :}
   plans VEC:COUNT 4 T=
   plans IN-ORDER? TTRUE
   j CLOSE
   d GONE ;

: RECORD-EMPTY ( -- )
   HELD-JOURNAL @ s" empty.txt" DISPLAY
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

: CRAFTED-PATH ( -- MODEL:path ) s" crafted.txt" DISPLAY ;

: DECODE-COLUMNS ( ^u8 n option<str> option<n> -- plan-status )
   s" read plan status" >str CRAFTED-PATH HELD-ARENA @
   DECODE-PLAN-STATUS ;

: DECODE-CRAFTED ( -- )
   CRAFT @ {: k :}
   k CRAFTED-STATUS k CRAFTED-JSON k CRAFTED-RETRY DECODE-COLUMNS drop ;

\ The stage-occupied blockage's stored JSON, copied into the arena.
: BLOCKAGE-JSON ( ^ARENA:arena ^JSON:writer -- str )
   {: ar w :}
   MODEL-BLOCKAGE:STAGE-OCCUPIED w ENCODE-BLOCKAGE ar COPIED ;

: PLAN-STATUS-DECODING-NAMES-THE-STATE-IT-REJECTS ( ^ARENA:arena -- )
   {: ar :}
   s" plan_status_decoding_names_the_state_it_rejects" T-LABEL
   ar SCRATCH {: d:str :}
   ar HELD-ARENA !
   ar [: BLOCKAGE-JSON ;] ENCODING SUBJECT !
   s" pending" NO-TEXT NO-INT DECODE-COLUMNS PENDING-STATUS STATUS=
   TTRUE
   s" completed" NO-TEXT NO-INT DECODE-COLUMNS
   construct plan-status completed STATUS= TTRUE
   7 0 ?do
      i CRAFT !
      [: DECODE-CRAFTED ;] E-INVALID-STATE d i CRAFTED-DETAIL ar LOGGED
   loop
   d GONE ;


\ ---- the Rust version's completion and conflict tests -----------

\ The second plan's rejected completion is logged once, with the
\ trigger's text, and takes the first one's back.
: FINAL-EFFECT-COMPLETIONS-COMMIT-ATOMICALLY ( ^ARENA:arena -- )
   {: ar :}
   s" final_effect_completions_commit_atomically" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" downloaded" s" rev-downloaded" REMOTE-FILE {: downloaded :}
   downloaded DOWNLOAD-DECISION ar OPERATIONS {: plan :}
   s" first.txt" DISPLAY {: one :}
   s" second.txt" DISPLAY {: two :}
   j one plan ar RECORD-PLAN RECORDED-PLAN {: first :}
   j two plan ar RECORD-PLAN RECORDED-PLAN {: second :}
   j >CONNECTION
   s" CREATE TRIGGER reject_test_completion BEFORE UPDATE OF status ON plans
      WHEN hex(OLD.path) = hex('second.txt') AND NEW.status = 'completed'
      BEGIN SELECT RAISE(ABORT, 'test rejection'); END;" SQLITE:EXEC
   downloaded MODEL-BASELINE:PRESENT {: b :}
   ar [type] operation-baseline NEW-VECTOR {: finals :}
   first FIRST-ID b JOURNAL-OPERATION--BASELINE:MAKE finals VEC:PUSH !
   second FIRST-ID b JOURNAL-OPERATION--BASELINE:MAKE finals VEC:PUSH !
   j HELD-JOURNAL !  ar HELD-ARENA !  finals FINALS !
   [: COMPLETE-FINALS ;] SQLITE:E-SQL d s" test rejection" ar LOGGED
   j one ar BASELINE NO-BASELINE? TTRUE
   j two ar BASELINE NO-BASELINE? TTRUE
   j ar PENDING-PLANS VEC:COUNT 2 T=
   j CLOSE
   d GONE ;

: SUPERSEDING-A-RACED-DIRECTORY-PLAN-NEVER-ADVANCES-ITS-BASELINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" superseding_a_raced_directory_plan_never_advances_its_baseline"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" parent" DISPLAY {: path :}
   MODEL-BASELINE:DIRECTORY {: dir :}
   p OPEN {: j :}
   j path DIRECTORY-DECISION NOOP ar RECORD-NOOP NOOP-RECORDED? TTRUE
   MODEL-OPERATION:DELETE-LOCAL-DIRECTORY ar ONE-PLAN {: plan :}
   j path plan ar RECORD-PLAN RECORDED-PLAN {: pending :}
   j pending >ID ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j path ar BASELINE dir BASELINE-HELD? TTRUE
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j ar CONFLICTS VEC:COUNT 0 T=
   j CLOSE
   p OPEN {: k :}
   k path ar BASELINE dir BASELINE-HELD? TTRUE
   k ar PENDING-PLANS VEC:COUNT 0 T=
   k CLOSE
   d GONE ;

: JOURNAL-CONFLICT-PRESERVES-EVERY-TYPED-SIDE-ACROSS-REOPEN
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_conflict_preserves_every_typed_side_across_reopen" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" conflict.txt" DISPLAY DIVERGENT ar RECORD-CONFLICT {: expected :}
   j CLOSE
   p OPEN {: k :}
   k ar CONFLICTS {: found :}
   found VEC:COUNT 1 T=
   found 0 VEC:AT @ expected CONFLICT-RECORD= TTRUE
   k CLOSE
   d GONE ;

: JOURNAL-RETIRES-CONFLICT-DESCRIPTION-WHEN-THE-PATH-CONVERGES
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_retires_conflict_description_when_the_path_converges"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" resolved.txt" DISPLAY {: path :}
   j path DIVERGENT ar RECORD-CONFLICT drop
   j ar CONFLICTS VEC:COUNT 1 T=
   j path ABSENT-DECISION NOOP ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j ar CONFLICTS VEC:COUNT 0 T=
   j CLOSE
   d GONE ;


\ ---- the Rust version's version-six tests -------------------------

: KEPT-PATH ( -- MODEL:path ) s" kept.txt" DISPLAY ;

: KEPT ( -- MODEL:baseline )
   s" kept" s" rev-kept" REMOTE-FILE MODEL-BASELINE:PRESENT ;

\ A schema-8 journal holding a schema-6 root's row, as migration 7
\ copies it, and the baseline version_six_with_root writes.
: LEGACY ( str ^ARENA:arena -- )
   {: p:str ar :}
   p OPEN CLOSE
   p str> SQLITE:OPEN {: c :}
   c s" INSERT INTO local_root_binding(
         singleton, canonical_path, inode, generation
      ) VALUES (1, CAST('/sync/root' AS BLOB), X'0000000000000002', 3)"
   SQLITE:EXEC
   c KEPT-PATH KEPT ar [: WRITE-BASELINE ;] ENCODING
   c SQLITE:CLOSE ;

: OBSERVED ( -- MODEL:local-record )
   s" observed.txt" s" observed" PRESENT-LOCAL LOCAL-RECORD ;

: CONFLICTED ( -- MODEL:conflict )
   s" local-conflict" CONTENT MODEL-LOCAL:MAKE
   s" remote-conflict" s" rev-conflict" REMOTE-FILE
   MODEL-CONFLICT:DIVERGENT ;

: ONLY-CONFLICT ( ^VEC:vector<conflict-record> -- conflict-record )
   {: found :}
   found VEC:COUNT 1 T=
   found 0 VEC:AT @ ;

\ The local scan and conflict recorded before the upgrade stay.
: SIX-KEPT
   ( journal MODEL:hash-record conflict-record ^ARENA:arena -- )
   {: j hash conflict ar :}
   j KEPT-PATH ar BASELINE KEPT BASELINE-HELD? TTRUE
   j OBSERVED hash ar SCAN-HELD
   j ar CONFLICTS ONLY-CONFLICT conflict CONFLICT-RECORD= TTRUE ;

: VERSION-SIX-ROOT-BINDING-UPGRADES-IN-PLACE-WHEN-PATH-AND-INODE-MATCH
   ( ^ARENA:arena -- )
   {: ar :}
   s" version_six_root_binding_upgrades_in_place_when_path_and_inode_match"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar LEGACY
   p OPEN-READ {: r :}
   r ar LOCAL-ROOT-BINDING LEGACY-ROOT RECORD-HELD? TTRUE
   r CLOSE
   p OPEN {: j :}
   j >CONNECTION VERSION 8 T=
   j ar LOCAL-ROOT-BINDING LEGACY-ROOT RECORD-HELD? TTRUE
   s" observed.txt" 10 ar LOCAL-HASH {: hash :}
   j LEGACY-ROOT >BINDING OBSERVED ar ONE-LOCAL hash ar ONE-HASH
   PUBLISH-LOCAL-SCAN TTRUE
   j s" conflict.txt" DISPLAY CONFLICTED ar RECORD-CONFLICT {: conflict :}
   s" /sync/root" 2 LOCAL-ROOT {: inspected :}
   inspected 3 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: upgraded :}
   j TOTAL-CHANGES {: before :}
   j inspected ar ACTIVATE-LOCAL-ROOT upgraded CURRENT? TTRUE
   j TOTAL-CHANGES before - 1 T=
   j hash conflict ar SIX-KEPT
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
   p ar LEGACY
   p OPEN {: j :}
   j ar BASELINE-PATHS {: paths :}
   j TOTAL-CHANGES {: before :}
   s" /sync/root" 9 LOCAL-ROOT {: actual :}
   j actual ar ACTIVATE-LOCAL-ROOT LEGACY-ROOT >BINDING actual UNAVAILABLE?
   TTRUE
   j ar LOCAL-ROOT-BINDING LEGACY-ROOT RECORD-HELD? TTRUE
   j ar BASELINE-PATHS paths PATHS= TTRUE
   j KEPT-PATH ar BASELINE KEPT BASELINE-HELD? TTRUE
   j TOTAL-CHANGES before T=
   j CLOSE
   d GONE ;

: ADOPTING-A-MATCHING-VERSION-SIX-ROOT-KEEPS-ITS-GENERATION
   ( ^ARENA:arena -- )
   {: ar :}
   s" adopting_a_matching_version_six_root_keeps_its_generation" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar LEGACY
   p OPEN {: j :}
   s" /sync/root" 2 LOCAL-ROOT {: inspected :}
   inspected 3 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: upgraded :}
   j inspected ar ADOPT-LOCAL-ROOT upgraded CURRENT? TTRUE
   j ar LOCAL-ROOT-BINDING upgraded RECORD-HELD? TTRUE
   j KEPT-PATH ar BASELINE KEPT BASELINE-HELD? TTRUE
   j CLOSE
   d GONE ;


\ ---- recoveries as the Rust version prints them -------------------

: RETAINED-DEBUG ( option<n> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF {: v :} s" Some(" at PUT v swap PUT-N s" )" rot PUT ENDOF
   ;MATCH ;

: RECOVERY-DEBUG ( recovery-record n -- n )
   {: r at :}
   r JOURNAL-RECOVERY--RECORD:UNMAKE {: id op from to c s kept :}
   s" RecoveryRecord { id: RecoveryId(" at PUT
   id RECOVERY-ID>N swap PUT-N
   s" ), operation_id: OperationId(" rot PUT
   op OPERATION-ID>N swap PUT-N
   s" ), original_path: " rot PUT  from MODEL:PATH>STR swap PUT-QUOTED
   s" , recovery_path: " rot PUT  to MODEL:PATH>STR swap PUT-QUOTED
   s" , content: " rot PUT  c swap HASH-DEBUG
   s" , status: " rot PUT  s swap RECORD-STATUS-DEBUG
   s" , retained_at: " rot PUT  kept swap RETAINED-DEBUG SHUT ;

\ name, a tab, then the records as a list.
: RECOVERIES-LINE ( ^u8 n ^VEC:vector<recovery-record> -- ^u8 n )
   {: a:^ u found :}
   a u 0 PUT  s\" \t[" rot PUT
   found VEC:COUNT 0 ?do
      i 0<> if s" , " rot PUT then
      found i VEC:AT @ swap RECOVERY-DEBUG
   loop
   s" ]" rot PUT {: v :}
   WANT v ;

\ Two records alike as the Rust version prints them, every field named.
: RECOVERY= ( recovery-record recovery-record -- bool )
   {: a b :}
   a 0 RECOVERY-DEBUG {: u :}
   b u RECOVERY-DEBUG {: v :}
   WANT u WANT u + v u - STR= ;

\ retained_at in completed_recoveries is the clock journal.sqlite3 was
\ written at, which the file holds.
: ORACLE-JOURNAL-HOLDS-ITS-RECOVERIES ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's recoveries are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p str> FS:COPY-FILE-STREAM
   p OPEN-READ {: j :}
   s" pending_recoveries" j ar PENDING-RECOVERIES RECOVERIES-LINE HELD?
   TTRUE
   s" completed_recoveries" j ar COMPLETED-RECOVERIES RECOVERIES-LINE
   HELD? TTRUE
   j CLOSE
   d GONE ;


\ ---- the Rust version's recovery tests ----------------------------

\ The Rust tests' recorded_recovery(write).
: NO-RECOVERY-RECORDED ( -- )
   s" extract recorded test recovery" >str TEST-PATH
   s" test expected a newly recorded recovery" >str INVALID ;

: RECORDED-RECOVERY ( recovery-write -- recovery-record )
   MATCH recovery-write
      recorded OF ENDOF
      already-recorded OF drop NO-RECOVERY-RECORDED ENDOF
      operation-not-found OF NO-RECOVERY-RECORDED ENDOF
      operation-completed OF NO-RECOVERY-RECORDED ENDOF
      operation-not-destructive OF NO-RECOVERY-RECORDED ENDOF
   ;MATCH ;

: COMPLETION-N ( operation-completion -- n )
   MATCH operation-completion
      not-found OF 0 ENDOF
      already-completed OF 1 ENDOF
      waiting-for-earlier-operation OF drop 2 ENDOF
      baseline-required OF 3 ENDOF
      unexpected-baseline OF 4 ENDOF
      baseline-mismatch OF 5 ENDOF
      operation-completed OF 6 ENDOF
      plan-completed OF 7 ENDOF
   ;MATCH ;

: WAITING-FOR? ( operation-completion operation-id -- bool )
   {: id :}
   MATCH operation-completion
      not-found OF false ENDOF
      already-completed OF false ENDOF
      waiting-for-earlier-operation OF
         OPERATION-ID>N id OPERATION-ID>N =
      ENDOF
      baseline-required OF false ENDOF
      unexpected-baseline OF false ENDOF
      baseline-mismatch OF false ENDOF
      operation-completed OF false ENDOF
      plan-completed OF false ENDOF
   ;MATCH ;

: RECOVERY-COMPLETION-N ( recovery-completion -- n )
   MATCH recovery-completion
      not-found OF 0 ENDOF
      already-completed OF 1 ENDOF
      completed OF 2 ENDOF
   ;MATCH ;

: FORGET-N ( recovery-forget -- n )
   MATCH recovery-forget
      not-found OF 0 ENDOF
      pending OF 1 ENDOF
      forgotten OF 2 ENDOF
   ;MATCH ;

: CONFLICT-COMPLETION-N ( plan-conflict-completion -- n )
   MATCH plan-conflict-completion
      not-found OF 0 ENDOF
      already-completed OF 1 ENDOF
      recorded OF 2 ENDOF
   ;MATCH ;

: ID-OF ( recovery-record -- recovery-id )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: i o a b c s r :} i ;

: OPERATION-OF ( recovery-record -- operation-id )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: i o a b c s r :} o ;

: CONTENT-OF ( recovery-record -- DROPBOX:hash )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: i o a b c s r :} c ;

: RETAINED-OF ( recovery-record -- option<n> )
   JOURNAL-RECOVERY--RECORD:UNMAKE {: i o a b c s r :} r ;

\ The record completed, its retention started at the time.
: COMPLETED-AT ( recovery-record n -- recovery-record )
   {: rec at :}
   rec JOURNAL-RECOVERY--RECORD:UNMAKE {: i o a b c s r :}
   i o a b c construct record-status completed at OPTION:SOME
   JOURNAL-RECOVERY--RECORD:MAKE ;

: RETAINED? ( option<n> -- bool )
   MATCH option
      none OF false ENDOF
      some OF drop true ENDOF
   ;MATCH ;

\ When the record's retention started; none is invalid state on path.
: RETENTION ( recovery-record MODEL:path -- n )
   {: path :}
   RETAINED-OF MATCH option
      none OF
         s" read retained test recovery" >str path
         s" completed destructive operation did not start retention"
         PATH-INVALID
      ENDOF
      some OF ENDOF
   ;MATCH ;

: ONE-RECOVERY ( ^VEC:vector<recovery-record> -- recovery-record )
   {: found :}
   found VEC:COUNT 1 T=
   found 0 VEC:AT @ ;

: NTH-ID ( plan-record n -- operation-id )
   {: r k :}
   r >OPERATIONS k VEC:AT @ JOURNAL-PLANNED--OPERATION:UNMAKE
   {: i o x s :} i ;

: PLAN-GONE? ( option<plan-record> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

\ The upload content at k is the content of the text.
: UPLOAD-AT? ( ^VEC:vector<DROPBOX:hash> n ^u8 n -- bool )
   {: v k c:^ cu :}
   v k VEC:AT @ c cu CONTENT HASH= ;

\ The file preserved, then replaced with the content of the text where
\ its revision still stands.
: PRESERVED-REPLACE
   ( MODEL:remote ^u8 n ^ARENA:arena -- operation-plan )
   {: file c:^ cu ar :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   file MODEL-OPERATION:PRESERVE-REMOTE ops VEC:PUSH !
   file MODEL-REMOTE:UNMAKE {: old rev :}
   c cu CONTENT rev MODEL-OPERATION:REPLACE-REMOTE ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

: JOURNAL-FINAL-OPERATION-RECORDS-ONLY-ITS-ACTUAL-RESULT
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_final_operation_records_only_its_actual_result" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" created.txt" DISPLAY {: path :}
   s" created" UPLOAD-DECISION ar OPERATIONS {: plan :}
   s" created" CONTENT MODEL-LOCAL:MAKE MODEL-CONFLICT:REMOTE-DELETED
   {: stale :}
   p OPEN {: j :}
   j path stale ar RECORD-CONFLICT drop
   j path plan ar RECORD-PLAN RECORDED-PLAN FIRST-ID {: id :}
   j id NO-BASELINE ar COMPLETE-OPERATION COMPLETION-N 3 T=
   j path ar BASELINE NO-BASELINE? TTRUE
   s" wrong" s" rev-server" REMOTE-FILE MODEL-BASELINE:PRESENT {: wrong :}
   j id wrong OPTION:SOME ar COMPLETE-OPERATION COMPLETION-N 5 T=
   j path ar BASELINE NO-BASELINE? TTRUE
   s" created" s" rev-server" REMOTE-FILE MODEL-BASELINE:PRESENT
   {: actual :}
   j id actual OPTION:SOME ar COMPLETE-OPERATION COMPLETION-N 7 T=
   j path ar BASELINE actual BASELINE-HELD? TTRUE
   j ar CONFLICTS VEC:COUNT 0 T=
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j id NO-BASELINE ar COMPLETE-OPERATION COMPLETION-N 1 T=
   j PRUNE-COMPLETED-WORK 1 T=
   j id NO-BASELINE ar COMPLETE-OPERATION COMPLETION-N 0 T=
   j CLOSE
   d GONE ;

\ The planner replaces the remote file with an edit made where the
\ baseline and the remote file agree, as src/oracle/plan.tsv holds.
: PENDING-UPLOAD-CONTENT-LISTS-ONLY-UNFINISHED-REMOTE-PAYLOADS
   ( ^ARENA:arena -- )
   {: ar :}
   s" pending_upload_content_lists_only_unfinished_remote_payloads"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" create.txt" DISPLAY {: create-path :}
   j create-path s" create" UPLOAD-DECISION ar OPERATIONS ar RECORD-PLAN
   RECORDED-PLAN {: create :}
   s" replace" CONTENT s" rev-old" >str DROPBOX:>REV
   MODEL-OPERATION:REPLACE-REMOTE ar ONE-PLAN {: replace :}
   j s" replace.txt" replace ar RECORD-UPLOAD
   s" download" s" rev-download" REMOTE-FILE DOWNLOAD-DECISION
   ar OPERATIONS {: download :}
   j s" download.txt" DISPLAY download ar RECORD-PLAN drop
   j ar PENDING-UPLOAD-CONTENT {: two :}
   two VEC:COUNT 2 T=
   two 0 s" create" UPLOAD-AT? TTRUE
   two 1 s" replace" UPLOAD-AT? TTRUE
   s" create" s" rev-created" REMOTE-FILE MODEL-BASELINE:PRESENT
   {: created :}
   j create FIRST-ID created OPTION:SOME ar COMPLETE-OPERATION
   COMPLETION-N 7 T=
   j ar PENDING-UPLOAD-CONTENT {: one :}
   one VEC:COUNT 1 T=
   one 0 s" replace" UPLOAD-AT? TTRUE
   j CLOSE
   d GONE ;

\ The intent recorded between the preservation and the replacement.
: INTENDED
   ( journal plan-record MODEL:baseline ^ARENA:arena -- recovery-record )
   {: j plan target ar :}
   plan 0 NTH-ID {: first :}
   plan 1 NTH-ID {: second :}
   j second target OPTION:SOME ar COMPLETE-OPERATION first WAITING-FOR?
   TTRUE
   j first target OPTION:SOME ar COMPLETE-OPERATION COMPLETION-N 4 T=
   j first NO-BASELINE ar COMPLETE-OPERATION COMPLETION-N 6 T=
   j second s" recovery/replace.txt" DISPLAY ar RECORD-RECOVERY-INTENT
   RECORDED-RECOVERY ;

\ The replacement completes and starts the copy's retention.
: RETAINED
   ( journal plan-record MODEL:path MODEL:baseline recovery-record
     ^ARENA:arena -- recovery-record )
   {: k plan path target recovery ar :}
   plan 1 NTH-ID {: second :}
   k ar PENDING-RECOVERIES ONE-RECOVERY recovery RECOVERY= TTRUE
   k recovery ID-OF FORGET-COMPLETED-RECOVERY FORGET-N 1 T=
   k second target OPTION:SOME ar COMPLETE-OPERATION COMPLETION-N 7 T=
   k second target OPTION:SOME ar COMPLETE-OPERATION COMPLETION-N 1 T=
   k path ar BASELINE target BASELINE-HELD? TTRUE
   k ar COMPLETED-RECOVERIES ONE-RECOVERY {: eligible :}
   eligible path RETENTION {: at :}
   at 0 > TTRUE
   recovery at COMPLETED-AT {: completed :}
   eligible completed RECOVERY= TTRUE
   completed ;

: JOURNAL-DESTRUCTIVE-COMPLETION-RETIRES-LEGACY-RECOVERY-ACROSS-REOPEN
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_destructive_completion_retires_legacy_recovery_across_reopen"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" replace.txt" DISPLAY {: path :}
   s" new" s" rev-server" REMOTE-FILE MODEL-BASELINE:PRESENT {: target :}
   s" old" s" rev-current" REMOTE-FILE s" new" ar PRESERVED-REPLACE
   {: plan :}
   p OPEN {: j :}
   j path plan ar RECORD-PLAN RECORDED-PLAN {: recorded :}
   j recorded target ar INTENDED {: recovery :}
   j CLOSE
   p OPEN {: k :}
   recovery CONTENT-OF s" old" CONTENT HASH= TTRUE
   k path ar BASELINE NO-BASELINE? TTRUE
   k recorded path target recovery ar RETAINED {: completed :}
   k PRUNE-COMPLETED-WORK 1 T=
   k >CONNECTION recorded >ID ar READ-PLAN PLAN-GONE? TTRUE
   s" fresh" UPLOAD-DECISION ar OPERATIONS {: fresh :}
   k s" fresh.txt" DISPLAY fresh ar RECORD-PLAN RECORDED-PLAN FIRST-ID
   OPERATION-ID>N recovery OPERATION-OF OPERATION-ID>N > TTRUE
   k ar COMPLETED-RECOVERIES ONE-RECOVERY completed RECOVERY= TTRUE
   k recovery ID-OF FORGET-COMPLETED-RECOVERY FORGET-N 2 T=
   k ar COMPLETED-RECOVERIES VEC:COUNT 0 T=
   k recovery ID-OF FORGET-COMPLETED-RECOVERY FORGET-N 0 T=
   k CLOSE
   d GONE ;

: BLOCKING-REPORTS-MISSING-AND-FINISHED-PLANS-WITHOUT-CHANGING-THEM
   ( ^ARENA:arena -- )
   {: ar :}
   s" blocking_reports_missing_and_finished_plans_without_changing_them"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   409 MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE {: why :}
   p OPEN {: j :}
   j s" finished.txt" DISPLAY upload ar RECORD-PLAN RECORDED-PLAN >ID
   {: id :}
   j id ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j id why 1700000000 ar BLOCK-PLAN BLOCK-N 1 T=
   j ar BLOCKED-PLANS VEC:COUNT 0 T=
   j id ar UNBLOCK-PLAN UNBLOCK-N 1 T=
   9999 >PLAN-ID {: missing :}
   j missing why 1700000000 ar BLOCK-PLAN BLOCK-N 0 T=
   j missing ar UNBLOCK-PLAN UNBLOCK-N 0 T=
   j CLOSE
   d GONE ;

: BLOCKED-PLAN-UPLOAD-PAYLOADS-STAY-REFERENCED ( ^ARENA:arena -- )
   {: ar :}
   s" blocked_plan_upload_payloads_stay_referenced" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   p OPEN {: j :}
   j s" upload.txt" DISPLAY upload ar RECORD-PLAN RECORDED-PLAN >ID
   {: id :}
   j ar PENDING-UPLOAD-CONTENT {: before :}
   before VEC:COUNT 1 T=
   before 0 s" upload" UPLOAD-AT? TTRUE
   j id MODEL-BLOCKAGE:REMOTE-OBJECT 1700000000 ar BLOCK-PLAN BLOCK-N
   2 T=
   j ar PENDING-UPLOAD-CONTENT {: blocked :}
   blocked VEC:COUNT 1 T=
   blocked 0 s" upload" UPLOAD-AT? TTRUE
   j id ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j ar PENDING-UPLOAD-CONTENT VEC:COUNT 0 T=
   j CLOSE
   d GONE ;

\ The recovery copy, completed before its plan finishes, starts no
\ retention until then.
: COPY-UNRETAINED ( journal recovery-record MODEL:path ^ARENA:arena -- )
   {: j recovery path ar :}
   j recovery ID-OF COMPLETE-RECOVERY RECOVERY-COMPLETION-N 2 T=
   j >CONNECTION recovery ID-OF ar READ-RECOVERY MATCH option
      none OF
         s" read conflicted recovery test" >str path
         s" test recovery disappeared before conflict completion"
         PATH-INVALID
      ENDOF
      some OF RETAINED-OF RETAINED? TFALSE ENDOF
   ;MATCH ;

\ The conflict retires the plan of a preservation and a replacement
\ whose recovery copy is complete, once.
: CONFLICTED-ONCE
   ( journal MODEL:path MODEL:remote ^ARENA:arena -- plan-id )
   {: j path file ar :}
   file s" local" ar PRESERVED-REPLACE {: ops :}
   j path ops ar RECORD-PLAN RECORDED-PLAN {: plan :}
   plan >OPERATIONS VEC:COUNT 2 T=
   j plan 0 NTH-ID NO-BASELINE ar COMPLETE-OPERATION COMPLETION-N 6 T=
   j plan 1 NTH-ID s" recovery/conflict.txt" DISPLAY ar
   RECORD-RECOVERY-INTENT RECORDED-RECOVERY {: recovery :}
   j recovery path ar COPY-UNRETAINED
   j plan >ID DIVERGENT ar FINISH-PLAN-WITH-CONFLICT
   CONFLICT-COMPLETION-N 2 T=
   j ar COMPLETED-RECOVERIES ONE-RECOVERY RETAINED-OF RETAINED? TTRUE
   j plan >ID DIVERGENT ar FINISH-PLAN-WITH-CONFLICT
   CONFLICT-COMPLETION-N 1 T=
   plan >ID ;

: JOURNAL-PLAN-CONFLICT-COMPLETES-ONCE-WITHOUT-ADVANCING-BASELINE
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_plan_conflict_completes_once_without_advancing_baseline"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" conflict.txt" DISPLAY {: path :}
   s" old" s" rev-old" REMOTE-FILE {: file :}
   p OPEN {: j :}
   j path file MATCH-DECISION NOOP ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j path file ar CONFLICTED-ONCE {: id :}
   j CLOSE
   p OPEN {: k :}
   k path ar BASELINE file MODEL-BASELINE:PRESENT BASELINE-HELD? TTRUE
   k ar PENDING-PLANS VEC:COUNT 0 T=
   k >CONNECTION id ar READ-PLAN PLAN-GONE? TTRUE
   k ar CONFLICTS ONLY-CONFLICT {: found :}
   found JOURNAL-CONFLICT--RECORD:UNMAKE {: n at x :}
   at path PATH= TTRUE
   x DIVERGENT MODEL:CONFLICT= TTRUE
   k id DIVERGENT ar FINISH-PLAN-WITH-CONFLICT CONFLICT-COMPLETION-N 0 T=
   k ar CONFLICTS ONLY-CONFLICT found CONFLICT-RECORD= TTRUE
   k INT-MAX >PLAN-ID DIVERGENT ar FINISH-PLAN-WITH-CONFLICT
   CONFLICT-COMPLETION-N 0 T=
   k CLOSE
   d GONE ;


\ ---- the Rust version's root activation tests ---------------------

: ACTIVATED? ( local-root-activation local-root-record -- bool )
   {: want :}
   MATCH local-root-activation
      activated OF want RECORD= ENDOF
      current OF drop false ENDOF
      unavailable OF 2drop false ENDOF
   ;MATCH ;

: PLAN= ( plan-record plan-record -- bool )
   {: a b :}
   a b SAME-PLAN? a STATUS-OF b STATUS-OF STATUS= and ;

: PLANS= ( ^VEC:vector<plan-record> ^VEC:vector<plan-record> -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ PLAN= 0= if unloop false exit then
   loop
   true ;

: RECOVERIES=
   ( ^VEC:vector<recovery-record> ^VEC:vector<recovery-record> -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ RECOVERY= 0= if unloop false exit then
   loop
   true ;

: CONFLICTS=
   ( ^VEC:vector<conflict-record> ^VEC:vector<conflict-record> -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ CONFLICT-RECORD= 0=
      if unloop false exit then
   loop
   true ;

\ /sync/root at inode 2, with the birth time and subvolume statx gave.
: SYNC-ROOT ( birth-time n bool -- local-root-binding )
   {: birth sub has:bool :}
   s" /sync/root" >str 2 birth true sub has FROM-STATX-FIELDS ;

\ Activating actual over recorded is unavailable and writes nothing.
: UNAVAILABLE-UNCHANGED
   ( journal local-root-binding local-root-binding ^ARENA:arena -- )
   {: j recorded actual ar :}
   j TOTAL-CHANGES {: before :}
   j actual ar ACTIVATE-LOCAL-ROOT recorded actual UNAVAILABLE? TTRUE
   j TOTAL-CHANGES before T= ;

: SAME-PATH-AND-INODE-WITH-ANOTHER-BIRTH-OR-SUBVOLUME-IS-UNAVAILABLE-WITHOUT-CHANGES
   ( ^ARENA:arena -- )
   {: ar :}
   s" same_path_and_inode_with_another_birth_or_subvolume_is_unavailable_without_changes"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" /sync/root" 2 LOCAL-ROOT {: recorded :}
   j recorded ar ACTIVATE-LOCAL-ROOT ACTIVATED
   1700000001 5 JOURNAL-BIRTH--TIME:MAKE 256 true SYNC-ROOT {: reborn :}
   BIRTH-5 257 true SYNC-ROOT {: resubvolumed :}
   BIRTH-5 0 false SYNC-ROOT {: unsubvolumed :}
   j recorded reborn ar UNAVAILABLE-UNCHANGED
   j recorded resubvolumed ar UNAVAILABLE-UNCHANGED
   j recorded unsubvolumed ar UNAVAILABLE-UNCHANGED
   j CLOSE
   d GONE ;

\ The content preserved as a local file, then deleted where it stands.
: PRESERVED-DELETE ( ^u8 n ^ARENA:arena -- operation-plan )
   {: c:^ cu ar :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   c cu CONTENT MODEL-LOCAL:MAKE MODEL-OPERATION:PRESERVE-LOCAL
   ops VEC:PUSH !
   c cu CONTENT MODEL-OPERATION:DELETE-LOCAL ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

\ A pending destructive plan of the content, whose deletion has a
\ recovery intent copying to copy, and a blocked upload.
: PRIOR-WORK ( journal ^u8 n MODEL:path ^ARENA:arena -- )
   {: j c:^ cu copy ar :}
   j s" pending.txt" DISPLAY c cu ar PRESERVED-DELETE ar RECORD-PLAN
   RECORDED-PLAN {: pending :}
   j pending 1 NTH-ID copy ar RECORD-RECOVERY-INTENT RECORDED-RECOVERY
   drop
   s" blocked" UPLOAD-DECISION ar OPERATIONS {: upload :}
   j s" blocked.txt" DISPLAY upload ar RECORD-PLAN RECORDED-PLAN >ID
   {: id :}
   j id MODEL-BLOCKAGE:STAGE-OCCUPIED 1700000000 ar BLOCK-PLAN BLOCK-N
   2 T= ;

\ dir/recovery-payload and dir/staged-payload, written.
: PAYLOADS ( str ^ARENA:arena -- str str )
   {: d:str ar :}
   d s" recovery-payload" ar INSIDE {: r:str :}
   d s" staged-payload" ar INSIDE {: s:str :}
   r str> s" recovery" FS:WRITE-ALL
   s str> s" staged" FS:WRITE-ALL
   r s ;

: FILE-HOLDS? ( str ^u8 n ^ARENA:arena -- bool )
   {: f:str t:^ tu ar :}
   ar 16 ARENA:ALLOC drop {: buf:^ :}
   f str> buf 16 FS:READ-ALL {: u :}
   buf u t tu STR= ;

\ Retiring a root's work leaves the payload files as they were written.
: PAYLOADS-KEPT ( str str ^ARENA:arena -- )
   {: r:str s:str ar :}
   r s" recovery" ar FILE-HOLDS? TTRUE
   s s" staged" ar FILE-HOLDS? TTRUE ;

\ The journal holds none of a prior root's state.
: ROOT-WORK-RETIRED ( journal ^ARENA:arena -- )
   {: j ar :}
   j ar BASELINE-PATHS VEC:COUNT 0 T=
   j ar LOCAL-INVENTORY VEC:COUNT 0 T=
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j ar BLOCKED-PLANS VEC:COUNT 0 T=
   j ar PENDING-RECOVERIES VEC:COUNT 0 T=
   j ar CONFLICTS VEC:COUNT 0 T= ;

\ The journal's state reads the same after the action as before it.
: KEPT-ACROSS ( journal ^ARENA:arena [ -- ] -- )
   {: j ar act :}
   j ar BASELINE-PATHS {: paths :}
   j ar LOCAL-INVENTORY {: locals :}
   j ar PENDING-PLANS {: pending :}
   j ar BLOCKED-PLANS {: blocked :}
   j ar PENDING-RECOVERIES {: recoveries :}
   j ar CONFLICTS {: conflicts :}
   act execute
   j ar BASELINE-PATHS paths PATHS= TTRUE
   j ar LOCAL-INVENTORY locals LOCAL-RECORDS= TTRUE
   j ar PENDING-PLANS pending PLANS= TTRUE
   j ar BLOCKED-PLANS blocked PLANS= TTRUE
   j ar PENDING-RECOVERIES recoveries RECOVERIES= TTRUE
   j ar CONFLICTS conflicts CONFLICTS= TTRUE ;

\ A new directory at root, the old one moved aside, inspected.
: REPLACED ( str str -- local-root-binding )
   {: root:str moved:str :}
   root moved FS:RENAME-FILE
   root str> FS:MAKE-DIR
   root INSPECT ;

\ The root's state: an agreed baseline, a local inventory, prior work
\ recovering to the payload and a conflict.
: ROOT-STATE ( journal str ^ARENA:arena -- )
   {: j payload:str ar :}
   j s" agreed.txt" s" agreed" s" rev-agreed" ar AGREE
   j s" local.txt" s" local" PRESENT-LOCAL LOCAL-RECORD ar ONE-LOCAL
   PUBLISH-LOCAL-INVENTORY
   j s" old" payload MODEL:>PATH ar PRIOR-WORK
   j s" conflict.txt" DISPLAY CONFLICTED ar RECORD-CONFLICT drop ;

: REPLACED-SAME-PATH-IS-UNAVAILABLE-WITHOUT-CHANGING-JOURNAL-STATE
   ( ^ARENA:arena -- )
   {: ar :}
   s" replaced_same_path_is_unavailable_without_changing_journal_state"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   d s" root" ar INSIDE {: root:str :}
   root str> FS:MAKE-DIR
   root INSPECT {: recorded :}
   recorded 1 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: was :}
   p OPEN {: j :}
   j recorded ar ACTIVATE-LOCAL-ROOT ACTIVATED
   d ar PAYLOADS {: rp:str sp:str :}
   j rp ar ROOT-STATE
   root d s" moved-root" ar INSIDE REPLACED {: actual :}
   recorded actual ROOT= TFALSE
   recorded ROOT-PATH actual ROOT-PATH SAME? TTRUE
   j ar [: j recorded actual ar UNAVAILABLE-UNCHANGED ;] KEPT-ACROSS
   j ar LOCAL-ROOT-BINDING was RECORD-HELD? TTRUE
   actual 2 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: adopted :}
   j actual ar ADOPT-LOCAL-ROOT adopted ACTIVATED? TTRUE
   j ar ROOT-WORK-RETIRED
   rp sp ar PAYLOADS-KEPT
   j CLOSE
   d GONE ;

\ The remote inventory still holds the cursor and the record.
: REMOTE-KEPT ( remote-inventory MODEL:remote-record ^ARENA:arena -- )
   {: inv r ar :}
   inv JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s" cursor-kept" CURSOR-IS? TTRUE
   v r ar ONE-REMOTE REMOTES= TTRUE ;

: SAME-REV-1 ( -- MODEL:remote ) s" same" s" rev-1" REMOTE-FILE ;

\ The first root's state at tracked.txt, agreed as the remote record
\ answered holds it, and a conflict.
: TRACKED ( journal ^ARENA:arena -- MODEL:remote-record )
   {: j ar :}
   s" tracked.txt" DISPLAY {: path :}
   SAME-REV-1 {: agreed :}
   j path agreed MATCH-DECISION NOOP ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j s" tracked.txt" s" same" PRESENT-LOCAL LOCAL-RECORD ar ONE-LOCAL
   PUBLISH-LOCAL-INVENTORY
   s" tracked.txt" s" tracked.txt" agreed MODEL-OBSERVATION:PRESENT ar
   REMOTE-RECORD {: remote :}
   j s" cursor-kept" CURSOR remote ar ONE-REMOTE PUBLISH-REMOTE-INVENTORY
   j s" old-root-conflict.txt" DISPLAY DIVERGENT ar RECORD-CONFLICT drop
   remote ;

: LOCAL-ROOT-GENERATION-RESETS-ONLY-ROOT-LOCAL-STATE ( ^ARENA:arena -- )
   {: ar :}
   s" local_root_generation_resets_only_root_local_state" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" /sync/first" 2 LOCAL-ROOT {: first :}
   first 1 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: first-record :}
   j first ar ACTIVATE-LOCAL-ROOT first-record ACTIVATED? TTRUE
   j ar TRACKED {: remote :}
   s" tracked.txt" DISPLAY {: path :}
   j first ar ACTIVATE-LOCAL-ROOT first-record CURRENT? TTRUE
   j path ar BASELINE SAME-REV-1 MODEL-BASELINE:PRESENT BASELINE-HELD?
   TTRUE
   s" /sync/second" 4 LOCAL-ROOT {: second :}
   second 2 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: second-record :}
   j second ar ACTIVATE-LOCAL-ROOT second-record ACTIVATED? TTRUE
   j ar LOCAL-ROOT-BINDING second-record RECORD-HELD? TTRUE
   j path ar BASELINE NO-BASELINE? TTRUE
   j ar ROOT-WORK-RETIRED
   j ar REMOTE-INVENTORY remote ar REMOTE-KEPT
   j CLOSE
   d GONE ;

\ A journal bound to no root, holding a pending plan, retires it when
\ the root activates as the first generation.
: UNBOUND-RETIRED ( str local-root-binding ^ARENA:arena -- )
   {: d:str b ar :}
   d s" unbound.sqlite3" ar INSIDE OPEN {: u :}
   u s" pending.txt" DISPLAY s" pending" ar PRESERVED-DELETE ar
   RECORD-PLAN RECORDED-PLAN drop
   b 1 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: first :}
   u b ar ACTIVATE-LOCAL-ROOT first ACTIVATED? TTRUE
   u ar PENDING-PLANS VEC:COUNT 0 T=
   u LIVE-PLAN-ROWS 0 T=
   u CLOSE ;

: LOCAL-ROOT-ACTIVATION-RETIRES-WORK-FROM-A-PRIOR-OR-UNBOUND-ROOT
   ( ^ARENA:arena -- )
   {: ar :}
   s" local_root_activation_retires_work_from_a_prior_or_unbound_root"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   d ar PAYLOADS {: rp:str sp:str :}
   p OPEN {: j :}
   s" /sync/current" 2 LOCAL-ROOT {: current :}
   current 1 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: was :}
   j current ar ACTIVATE-LOCAL-ROOT was ACTIVATED? TTRUE
   j s" pending" rp MODEL:>PATH ar PRIOR-WORK
   s" /sync/replacement" 4 LOCAL-ROOT {: replacement :}
   replacement 2 JOURNAL-LOCAL--ROOT--RECORD:MAKE {: record :}
   j replacement ar ACTIVATE-LOCAL-ROOT record ACTIVATED? TTRUE
   j ar LOCAL-ROOT-BINDING record RECORD-HELD? TTRUE
   j ar ROOT-WORK-RETIRED
   j LIVE-PLAN-ROWS 0 T=
   rp sp ar PAYLOADS-KEPT
   j CLOSE
   d replacement ar UNBOUND-RETIRED
   d GONE ;

\ JOURNAL's half: the new root finds no baseline. Planning the absent
\ baseline, the empty root and the remote file into an install is
\ PLANNER's half, which this file does not load.
: NEW-EMPTY-ROOT-DOWNLOADS-REMOTE-CONTENT-INSTEAD-OF-DELETING-IT
   ( ^ARENA:arena -- )
   {: ar :}
   s" new_empty_root_downloads_remote_content_instead_of_deleting_it"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" /sync/old" 2 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   s" remote-only.txt" DISPLAY {: path :}
   s" remote" s" rev-remote" REMOTE-FILE {: remote :}
   j path remote MATCH-DECISION NOOP ar RECORD-NOOP NOOP-RECORDED? TTRUE
   j s" /sync/new-empty" 4 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j path ar BASELINE NO-BASELINE? TTRUE
   j CLOSE
   d GONE ;


\ ---- stored values MODEL cannot read -----------------------------

\ The oracle journal, copied into a case's directory and opened, with
\ the SQL run on it; the journal and arena are held for a reader.
: PLANTED ( ^u8 n ^ARENA:arena -- str )
   {: sql:^ su ar :}
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p str> FS:COPY-FILE-STREAM
   p OPEN {: j :}
   j >CONNECTION sql su SQLITE:EXEC
   j HELD-JOURNAL !  ar HELD-ARENA !
   d ;

: PLANTED-GONE ( str -- ) HELD-JOURNAL @ CLOSE GONE ;

\ `op` could not process the record for `path`, as MODEL:E-STORED.
: STORED-LINE ( ^u8 n ^u8 n -- ^u8 n )
   {: op:^ ou path:^ pu :}
   s" `" 0 PUT  op ou rot PUT
   s" ` could not process the record for `" rot PUT
   path pu rot PUT  s" `: " rot PUT
   MODEL:E-STORED swap PUT-N  s"  " rot PUT
   MODEL:E-STORED ERROR:NAME$ rot PUT {: u :}
   WANT u ;

\ The reader throws E-JSON after one line naming op, path and cause.
: UNREADABLE ( [ -- ] str ^u8 n ^u8 n ^ARENA:arena -- )
   {: reader d:str op:^ ou path:^ pu ar :}
   op ou path pu STORED-LINE {: a:^ u :}
   reader E-JSON d a u ar LOGGED ;

: HELD-BASELINES ( -- ) HELD-JOURNAL @ HELD-ARENA @ BASELINES drop ;

: HELD-PENDING-PLANS ( -- )
   HELD-JOURNAL @ HELD-ARENA @ PENDING-PLANS drop ;

: HELD-BLOCKED-PLANS ( -- )
   HELD-JOURNAL @ HELD-ARENA @ BLOCKED-PLANS drop ;

: HELD-LOCAL-INVENTORY ( -- )
   HELD-JOURNAL @ HELD-ARENA @ LOCAL-INVENTORY drop ;

: HELD-REMOTE-INVENTORY ( -- )
   HELD-JOURNAL @ HELD-ARENA @ REMOTE-INVENTORY drop ;

: HELD-CONFLICTS ( -- ) HELD-JOURNAL @ HELD-ARENA @ CONFLICTS drop ;

: HELD-HASH-CACHE ( -- )
   HELD-JOURNAL @ HELD-ARENA @ LOCAL-HASH-CACHE drop ;

: HELD-PENDING-RECOVERIES ( -- )
   HELD-JOURNAL @ HELD-ARENA @ PENDING-RECOVERIES drop ;

: AN-UNKNOWN-BASELINE-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored baseline is refused" T-LABEL
   s\" UPDATE baselines SET baseline_json = '{\"Future\":1}'
      WHERE hex(path) = hex('Docs')" ar PLANTED {: d:str :}
   [: HELD-BASELINES ;] d s" deserialize baseline" s" Docs" ar
   UNREADABLE
   d PLANTED-GONE ;

\ Plan 2's only operation, which PENDING-PLANS reads.
: AN-UNKNOWN-OPERATION-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored operation is refused" T-LABEL
   s\" UPDATE operations SET operation_json = '{\"Future\":1}'
      WHERE id = 2" ar PLANTED {: d:str :}
   [: HELD-PENDING-PLANS ;] d s" deserialize operation"
   s" Docs/New.txt" ar UNREADABLE
   d PLANTED-GONE ;

: AN-UNKNOWN-OBSERVATION-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored observation is refused" T-LABEL
   s\" UPDATE local_observations
      SET observation_json = '{\"Future\":1}'
      WHERE hex(path) = hex('Docs');
      UPDATE remote_observations
      SET observation_json = '{\"Future\":1}'
      WHERE hex(path) = hex('Docs')" ar PLANTED {: d:str :}
   [: HELD-LOCAL-INVENTORY ;] d s" deserialize local observation"
   s" Docs" ar UNREADABLE
   [: HELD-REMOTE-INVENTORY ;] d s" deserialize remote observation"
   s" Docs" ar UNREADABLE
   d PLANTED-GONE ;

\ Plan 3, the oracle's blocked one.
: AN-UNKNOWN-BLOCKAGE-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored blockage is refused" T-LABEL
   s\" UPDATE plans SET blocked_json = '{\"Future\":1}' WHERE id = 3"
   ar PLANTED {: d:str :}
   [: HELD-BLOCKED-PLANS ;] d s" deserialize block reason"
   s" Docs/Big.bin" ar UNREADABLE
   d PLANTED-GONE ;

: AN-UNKNOWN-CONFLICT-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored conflict is refused" T-LABEL
   s\" UPDATE conflicts SET conflict_json = '{\"Future\":1}'
      WHERE id = 1" ar PLANTED {: d:str :}
   [: HELD-CONFLICTS ;] d s" deserialize conflict" s" Docs/Both.txt"
   ar UNREADABLE
   d PLANTED-GONE ;

\ A hash value is an object with a fingerprint and content, not a sum.
: AN-UNREADABLE-HASH-VALUE-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unreadable stored hash value is refused" T-LABEL
   s\" UPDATE local_hash_cache SET hash_json = '{\"Future\":1}'
      WHERE hex(path) = hex('Docs/A.txt')" ar PLANTED {: d:str :}
   [: HELD-HASH-CACHE ;] d s" deserialize local hash cache"
   s" Docs/A.txt" ar UNREADABLE
   d PLANTED-GONE ;

\ Recovery 1, the pending one, whose content is a JSON string; the line
\ names its original path.
: AN-UNREADABLE-RECOVERY-CONTENT-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unreadable stored recovery content is refused" T-LABEL
   s\" UPDATE recovery_records SET content_json = '{\"Future\":1}'
      WHERE id = 1" ar PLANTED {: d:str :}
   [: HELD-PENDING-RECOVERIES ;] d s" deserialize recovery content"
   s" Trash/Old1.txt" ar UNREADABLE
   d PLANTED-GONE ;


: CASES ( ^ARENA:arena -- )
   {: ar :}
   ar NEW-JOURNAL-HAS-THE-ORACLE-SCHEMA
   ar OTHER-VERSIONS-ARE-REFUSED-UNCHANGED
   ar ORACLE-JOURNAL-HOLDS-ITS-BINDINGS
   ar WRITABLE-JOURNAL-CREATES-OWNER-ONLY-DATABASE
   ar READ-ONLY-JOURNAL-PRESERVES-EXISTING-PERMISSIONS
   ar WRITABLE-JOURNAL-RESTRICTS-EXISTING-DATABASE
   ar EVERY-CONNECTION-WAITS-OUT-A-CONCURRENT-COMMIT
   ar WRITABLE-JOURNAL-USES-FULL-SYNCHRONOUS-ROLLBACK-MODE
   ar JOURNAL-CREATION-REPORTS-ITS-OWN-FILESYSTEM-FAILURE
   ar A-FULL-DISK-IS-ITS-OWN-CODE
   ar A-FAILED-OPEN-KEEPS-THE-HOST-ERRNO
   ar WRITABLE-JOURNAL-NEVER-TRUNCATES-AN-EXISTING-DATABASE
   ar JOURNAL-REFUSES-A-SYMLINKED-DATABASE
   ar GARBAGE-FILE-IS-CORRUPT
   ar LOCAL-ROOT-INSPECTION-USES-DIRECTORY-FILESYSTEM-IDENTITY
   ar ROOT-IDENTITY-REQUIRES-A-RECORDED-BIRTH-TIME
   STAND-IN-NEEDS-THE-ROOT-PATH-AND-A-BIRTH-TIME-OR-ANOTHER-INODE
   ar ROOT-INSPECTION-FAILURE-IS-UNAVAILABLE-ONLY-FOR-A-STAND-IN
   ar STAND-IN-WITHOUT-BIRTH-TIME-LEAVES-THE-ROOT-UNAVAILABLE
   ar VERSION-SIX-ROOT-BINDING-UPGRADES-IN-PLACE-WHEN-PATH-AND-INODE-MATCH
   ar VERSION-SIX-ROOT-BINDING-WITH-ANOTHER-INODE-IS-UNAVAILABLE-WITHOUT-CHANGES
   ar ADOPTING-A-MATCHING-VERSION-SIX-ROOT-KEEPS-ITS-GENERATION
   ar SAME-PATH-AND-INODE-WITH-ANOTHER-BIRTH-OR-SUBVOLUME-IS-UNAVAILABLE-WITHOUT-CHANGES
   ar REPLACED-SAME-PATH-IS-UNAVAILABLE-WITHOUT-CHANGING-JOURNAL-STATE
   ar LOCAL-ROOT-GENERATION-RESETS-ONLY-ROOT-LOCAL-STATE
   ar LOCAL-ROOT-ACTIVATION-RETIRES-WORK-FROM-A-PRIOR-OR-UNBOUND-ROOT
   ar NEW-EMPTY-ROOT-DOWNLOADS-REMOTE-CONTENT-INSTEAD-OF-DELETING-IT
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
   ar JOURNAL-LOCAL-SCAN-REPLACES-INVENTORY-AND-HASHES-ATOMICALLY
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
   ar PLAN-STATUS-DECODING-NAMES-THE-STATE-IT-REJECTS
   ar ORACLE-JOURNAL-HOLDS-ITS-CONFLICTS
   ar FINAL-EFFECT-COMPLETIONS-COMMIT-ATOMICALLY
   ar SUPERSEDING-A-RACED-DIRECTORY-PLAN-NEVER-ADVANCES-ITS-BASELINE
   ar JOURNAL-CONFLICT-PRESERVES-EVERY-TYPED-SIDE-ACROSS-REOPEN
   ar JOURNAL-RETIRES-CONFLICT-DESCRIPTION-WHEN-THE-PATH-CONVERGES
   ar ORACLE-JOURNAL-HOLDS-ITS-RECOVERIES
   ar JOURNAL-FINAL-OPERATION-RECORDS-ONLY-ITS-ACTUAL-RESULT
   ar PENDING-UPLOAD-CONTENT-LISTS-ONLY-UNFINISHED-REMOTE-PAYLOADS
   ar JOURNAL-DESTRUCTIVE-COMPLETION-RETIRES-LEGACY-RECOVERY-ACROSS-REOPEN
   ar BLOCKING-REPORTS-MISSING-AND-FINISHED-PLANS-WITHOUT-CHANGING-THEM
   ar BLOCKED-PLAN-UPLOAD-PAYLOADS-STAY-REFERENCED
   ar JOURNAL-PLAN-CONFLICT-COMPLETES-ONCE-WITHOUT-ADVANCING-BASELINE
   ar AN-UNKNOWN-BASELINE-IS-REFUSED
   ar AN-UNKNOWN-OPERATION-IS-REFUSED
   ar AN-UNKNOWN-OBSERVATION-IS-REFUSED
   ar AN-UNKNOWN-BLOCKAGE-IS-REFUSED
   ar AN-UNKNOWN-CONFLICT-IS-REFUSED
   ar AN-UNREADABLE-HASH-VALUE-IS-REFUSED
   ar AN-UNREADABLE-RECOVERY-CONTENT-IS-REFUSED ;


: TESTS ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" journal-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

TESTS

;package
