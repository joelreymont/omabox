\ journal-test.f - JOURNAL's open, schema 14, bindings, inventories,
\ baselines, plans, completions, conflicts, recoveries and upload
\ sessions on journals under TMPDIR: a new journal's sqlite_master
\ against src/oracle/schema.tsv as a set, but for the baselines,
\ remote_observations, local_observations and local_hash_cache tables,
\ which are migrations/0010.sql's, the upload_sessions table,
\ migrations/0011.sql's, conflict_blocks, 0012.sql's,
\ remote_mismatches and remote_shadows, 0013.sql's, and copy_stages,
\ 0014.sql's, and its user_version 14; versions 1, 7 and 15 refused
\ unchanged; a schema-10, a schema-11, a schema-12 and a schema-13
\ journal migrated to 14; src/oracle/journal.sqlite3, a schema-8
\ journal, migrated to 14 with
\ its local observations keyed by their
\ folded paths and its baselines, remote and local observations and
\ hash cache in typed columns, and, without its
\ remote_directories index, left at schema 8 with every row when the
\ migration fails; a local scan published as its difference, every
\ unchanged row keeping its rowid and the hashes of another generation
\ dropped, emptied by WITH-SCAN, and writing nothing for a root that is
\ not active; a scan's jobs visited once in path order, then gone; what
\ a visit observes and hashes published in place of the cached hash;
\ the walk merged with the stored rows staging only what differs, a
\ file changed or gone, a directory become a file, a new directory,
\ and beneath directories that changed while listed observations gone
\ but cached hashes kept; the cached hashes SCAN-FILE reuses and those
\ it hashes again; no transaction left open by a throw out of
\ WITH-SCAN, a visit holding no lock of the scan before it, and a scan
\ that fills its temporary database leaving the next scan whole; a
\ folder skipped at its subtree's turn keeping its stored rows, and the
\ rows the walk passed over before it staged gone; a range,
\ one or two in a scan, merging only beneath its folder;
\ watched folders clean once a published scan listed them, stirred
\ again when a scan ends unpublished or refused, answered stirred in
\ path byte order, replaced, forgotten and reset;
\ src/oracle/journal.sqlite3, copied and opened, giving journal.tsv's
\ Dropbox and local root bindings, local and remote inventories, remote
\ cursor, baselines, baseline paths, pending and blocked plans, pending
\ upload content, conflicts and pending and completed recoveries, each in
\ the line's own form; a file of other bytes refused as corrupt by both
\ opens, unchanged; a failed open's E-FILE leaving EACCES in FS:ERRNO;
\ the keys EACH-LOCAL-COLLISION visits, in MODEL:KEY-CMP's order, and
\ LOCAL-COUNT and LOCAL-AT over published scans; REMOTE-AT at held and
\ unheld keys; a key a delta's or a listing's hold shows unsupported,
\ spelled as the hold's path, its record, a directory
\ REMOTE-LISTED-AT finds, back at the unhold, the hold gone with an
\ unhold or a subtree deletion above its lower, and a hold on a key its
\ lower or its path does not fold to refused; LIVE-PLAN-AT at a
\ pending, a blocked, a completed and an
\ unheld key; a completed download plan kept by every prune, the one at
\ open included, until it is forgotten or a new root's activation
\ deletes it, and a completed upload plan not;
\ the keys EACH-UNSETTLED-PATH visits, in byte order, none
\ settled, and
\ KNOWN-PATH-AT at a held key and at keys nothing holds, and its subtree
\ as Rust's reconcile.rs remote_subtree_holds_only_true_descendants has it;
\ UNKNOWN-LOCALS and UNKNOWN-REMOTES answering only the unknown records of
\ inventories holding each observation they store, an excluded path
\ among them, by
\ path and by canonical path;
\ and fifty-one tests of the Rust version's src/journal.rs and two of
\ its src/daemon.rs under their names, which
\ build each decision the Rust ones ask the planner for as
\ src/oracle/plan.tsv holds it. Habu opens no
\ schema-6 file, so the version-six tests start from a schema-14 journal
\ holding the row migration 7 leaves for a schema-6 root, birth and
\ subvolume NULL, and the baseline the Rust tests' version_six_with_root
\ writes. A copy of the oracle journal with a value MODEL cannot read
\ in one row of each stored JSON family is refused by the word that
\ reads it, as E-JSON naming the row's path; at schema 9, a baseline or
\ remote observation refuses the migration so, leaving the file at 9
\ with every row. The oracle at schema 9 migrates a baseline, a remote
\ and a local observation of each kind, the absent ones gone and a
\ local one MODEL cannot read kept as unknown, and its hash cache, the
\ rows that do not convert gone; the migration
\ converts each of a list of texts exactly when MODEL's JSON reader
\ reads it, to the value it reads, a local text it refuses to unknown.
\ An upload session checkpointed, replaced, read across a reopen and
\ retired; a checkpoint of content that is not a Dropbox hash refused;
\ the session forgotten by its operation's completion, its plan's
\ conflict or supersession and a new root's activation, removed by the
\ prune that removes its operation, and kept by a completion that waits
\ and by blocking and unblocking its plan.
\ Each case removes its directory;
\ a refusal's log line is captured in it, checked and removed.
\ Run from the repository root: hb --load src/journal-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test/assert.f
require src/lib/test/stderr.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fs-statx.f
require src/lib/sqlite.f
require src/lib/vector.f
require src/lib/heap.f
require src/dropbox.f
require src/model.f
require src/journal.f
require src/test-journal.f

\ JOURNAL reopened: a case reads the journal's connection, its rows, the
\ bindings' and records' fields, and the inventories' private words.
package JOURNAL
private

TYPED-VARIABLE BODY-V ^VEC:vector<u8>  \ an oracle file
TYPED-VARIABLE LINE-V ^VEC:vector<u8>  \ a line looked for in it
TYPED-VARIABLE WANT-V ^VEC:vector<u8>  \ a binding as Rust prints it
: BODY ( -- ^VEC:vector<u8> ) BODY-V @ ;
: LINE ( -- ^VEC:vector<u8> ) LINE-V @ ;
: WANT ( -- ^VEC:vector<u8> ) WANT-V @ ;
: BYTES$ ( ^VEC:vector<u8> -- str ) VEC:SPAN SPAN:$ ;
$1A4 constant MODE-SHARED
$140 constant MODE-SEALED          \ 0500
$1C0 constant MODE-DIR-OWNER       \ 0700

TYPED-VARIABLE ACTION [ -- ]
TYPED-VARIABLE SUBJECT str
TYPED-VARIABLE SUBJECT-ARENA ^ARENA:arena


\ ---- a case's directory ------------------------------------------

: SCRATCH ( ^ARENA:arena -- str )
   {: ar :}
   s" journal-test" FS:MKTEMP-DIR ar ARENA:COPY ;


\ dir/name.
: INSIDE ( str str ^ARENA:arena -- str )
   {: d:str n:str ar :}
   d str> {: p:^ pu :}
   n str> {: a:^ u :}
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


: GONE ( str -- ) FS:REMOVE-TREE ;

: MODE-OF ( str -- n ) FS:STAT-MODE MODE-BITS and ;


\ The action throws want with fd 2 sent to dir/stderr.txt, which then
\ holds one line with the text and is removed.
: LOGGED ( [ -- ] n str str ^ARENA:arena -- )
   {: want dir:str t:str ar :}
   ACTION !
   dir s" stderr.txt" ar INSIDE {: f:str :}
   ACTION @ f ar STDERR:CAPTURING {: code:n e:str :}
   code want T=
   e 10 STR:COUNT-CHAR 1 T=
   e t STR:CONTAINS? TTRUE ;

\ The action runs with fd 2 sent to dir/stderr.txt, which then is empty
\ and is removed.
: SILENT ( [ -- ] str ^ARENA:arena -- )
   {: dir:str ar :}
   ACTION !
   dir s" stderr.txt" ar INSIDE {: f:str :}
   ACTION @ f ar STDERR:CAPTURING {: code:n e:str :}
   code 0<> if code throw then
   e STR:len 0 T= ;


\ ---- the oracle files --------------------------------------------

\ BODY holds the file at path, after a newline when lead is true.
: READ-BODY ( str bool -- )
   {: p:str lead:bool :}
   BODY 0 VEC:RESIZE
   lead if 10 BODY VEC:PUSH c! then
   p FS:FILE-SIZE {: u :}
   BODY u VEC:EXTEND SPAN:$ str> drop {: a:^ :}
   p a u FS:READ-ALL {: got :}
   BODY BODY VEC:COUNT u - got + VEC:RESIZE ;

\ BODY holds a newline, then the file at path.
: ORACLE ( str -- ) true READ-BODY ;


\ BODY holds the text as a whole line.
: HELD? ( str -- bool )
   {: t:str :}
   LINE 0 VEC:RESIZE
   10 LINE VEC:PUSH c!  t LINE VEC:APPEND  10 LINE VEC:PUSH c!
   BODY BYTES$ LINE BYTES$ STR:CONTAINS? ;


\ The oracle journal copied to path and brought to schema 9 in one
\ transaction.
: NINE-ORACLE ( str -- )
   {: p:str :}
   s" src/oracle/journal.sqlite3" p FS:COPY-FILE-STREAM
   p SQLITE:OPEN {: c :}
   c [: c MIGRATE-LOCAL-OBSERVATIONS ;] SQLITE:WITH-TRANSACTION
   c SQLITE:CLOSE ;

\ The oracle journal copied to path and brought to schema 10 in one
\ transaction.
: TEN-ORACLE ( str -- )
   {: p:str :}
   p NINE-ORACLE
   p SQLITE:OPEN {: c :}
   c [: c MIGRATE-TYPED-COLUMNS ;] SQLITE:WITH-TRANSACTION
   c SQLITE:CLOSE ;

\ The oracle journal copied to path and brought to schema 11 in one
\ transaction.
: ELEVEN-ORACLE ( str -- )
   {: p:str :}
   p TEN-ORACLE
   p SQLITE:OPEN {: c :}
   c [: c V11 RUN ;] SQLITE:WITH-TRANSACTION
   c SQLITE:CLOSE ;

\ The oracle journal copied to path and brought to schema 12 in one
\ transaction.
: TWELVE-ORACLE ( str -- )
   {: p:str :}
   p ELEVEN-ORACLE
   p SQLITE:OPEN {: c :}
   c [: c V12 RUN ;] SQLITE:WITH-TRANSACTION
   c SQLITE:CLOSE ;

\ The oracle journal copied to path and brought to schema 13 in one
\ transaction.
: THIRTEEN-ORACLE ( str -- )
   {: p:str :}
   p TWELVE-ORACLE
   p SQLITE:OPEN {: c :}
   c [: c V13 RUN ;] SQLITE:WITH-TRANSACTION
   c SQLITE:CLOSE ;

\ The oracle journal copied to path and migrated to schema 14, its
\ completed work kept.
: MIGRATED-ORACLE ( str -- )
   {: p:str :}
   p TEN-ORACLE
   p SQLITE:OPEN {: c :}
   c [: c 10 MIGRATE ;] SQLITE:WITH-TRANSACTION
   c SQLITE:CLOSE ;


\ Writes the text at WANT's byte at, cutting what follows; answers
\ the byte after it.
: PUT ( str n -- n )
   {: s:str at :}
   WANT at VEC:RESIZE
   s WANT VEC:APPEND
   WANT VEC:COUNT ;

\ WANT's bytes from i up to j.
: WANT-PART ( n n -- str )
   {: i j :} WANT BYTES$ str> drop i + j i - >str ;

: PUT-N ( n n -- n ) {: v at :} v FMT:INT$ at PUT ;

: PUT-QUOTED ( str n -- n )
   {: s:str at :}
   s\" \"" at PUT  s swap PUT  s\" \"" swap PUT ;


\ ---- the bindings as the Rust version prints them ----------------

: DROPBOX-DEBUG ( dropbox-binding -- str )
   JOURNAL-DROPBOX--BINDING:UNMAKE {: acct:str ns:str root:str :}
   s\" dropbox_binding\tSome(DropboxBinding { account_id: " 0 PUT
   acct swap PUT-QUOTED
   s" , root_namespace_id: " swap PUT
   ns swap PUT-QUOTED
   s" , remote_root: " swap PUT
   root swap PUT-QUOTED
   s"  })" swap PUT {: u :}
   0 u WANT-PART ;

: BIRTH-DEBUG ( option<birth-time> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF
         JOURNAL-BIRTH--TIME:UNMAKE {: s ns :}
         s" Some(BirthTime { seconds: " at PUT  s swap PUT-N
         s" , nanoseconds: " swap PUT  ns swap PUT-N
         s"  })" swap PUT
      ENDOF
   ;MATCH ;

: SUBVOLUME-DEBUG ( option<n> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF {: v :} s" Some(" at PUT  v swap PUT-N  s" )" swap PUT ENDOF
   ;MATCH ;

: ROOT-DEBUG ( local-root-record -- str )
   JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b g :}
   b JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str inode birth sub :}
   s\" local_root_binding\tSome(LocalRootRecord { binding: LocalRootBinding { canonical_path: "
   0 PUT
   p swap PUT-QUOTED
   s" , inode: " swap PUT  inode swap PUT-N
   s" , birth: " swap PUT  birth swap BIRTH-DEBUG
   s" , subvolume: " swap PUT  sub swap SUBVOLUME-DEBUG
   s"  }, generation: " swap PUT  g swap PUT-N
   s"  })" swap PUT {: u :}
   0 u WANT-PART ;

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

: DROPBOX ( str str str -- dropbox-binding )
   JOURNAL-DROPBOX--BINDING:MAKE ;

: BIRTH-5 ( -- birth-time ) 1700000000 5 JOURNAL-BIRTH--TIME:MAKE ;

\ The Rust tests' local_root(path, inode).
: LOCAL-ROOT ( str n -- local-root-binding )
   {: p:str inode :}
   p inode BIRTH-5 OPTION:SOME 256 OPTION:SOME
   JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

\ The root a schema-6 journal recorded: no birth time, no subvolume.
: LEGACY-ROOT ( -- local-root-record )
   s" /sync/root" 2 NO-BIRTH NO-SUBVOLUME
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

\ Every row but those of the tables 0010.sql to 0014.sql define and of
\ the indexes on 0012.sql's and 0013.sql's tables, as schema.tsv writes
\ one.
: SCHEMA-SQL ( -- str )
   s" SELECT type || char(9) || name || char(9) || tbl_name || char(9)
         || coalesce(replace(replace(replace(sql, '\', '\\'),
            char(10), '\n'), char(9), '\t'), '')
      FROM sqlite_master
      WHERE NOT (type = 'table' AND name IN
         ('baselines', 'remote_observations', 'local_observations',
            'local_hash_cache', 'upload_sessions'))
         AND tbl_name NOT IN
            ('conflict_blocks', 'remote_mismatches', 'remote_shadows',
               'copy_stages')" ;

\ Counts the rows, each a line of BODY.
: SCHEMA-ROWS ( n SQLITE:statement -- n SQLITE:statement )
   begin SQLITE:STEP while
      0 SQLITE:COL-TEXT HELD? TTRUE
      swap 1+ swap
   repeat ;

\ Every table's and index's name and SQL, lower case, in BODY.
: SCHEMA-TEXT ( SQLITE:statement -- SQLITE:statement )
   SQLITE:STEP drop
   BODY 0 VEC:RESIZE
   0 SQLITE:COL-TEXT BODY VEC:APPEND ;

\ Whether BODY holds the first row's text.
: BODY-HOLDS ( SQLITE:statement -- bool SQLITE:statement )
   SQLITE:STEP drop 0 SQLITE:COL-TEXT {: t:str :}
   BODY BYTES$ t STR:CONTAINS? swap ;

\ The journal's schema is schema.tsv's but for the tables 0010.sql to
\ 0014.sql define, which are theirs, and its version is 14.
: SCHEMA-14 ( journal -- )
   >CONNECTION {: c :}
   s" src/oracle/schema.tsv" ORACLE
   0 c SCHEMA-SQL [: SCHEMA-ROWS ;] SQLITE:WITH-STATEMENT 22 T=
   c VERSION 14 T=
   s" migrations/0011.sql" ORACLE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'upload_sessions'" [: BODY-HOLDS ;]
   SQLITE:WITH-STATEMENT TTRUE
   s" migrations/0010.sql" ORACLE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'baselines'" [: BODY-HOLDS ;]
   SQLITE:WITH-STATEMENT TTRUE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'remote_observations'"
   [: BODY-HOLDS ;] SQLITE:WITH-STATEMENT TTRUE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'local_observations'"
   [: BODY-HOLDS ;] SQLITE:WITH-STATEMENT TTRUE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'local_hash_cache'"
   [: BODY-HOLDS ;] SQLITE:WITH-STATEMENT TTRUE
   s" migrations/0012.sql" ORACLE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'conflict_blocks'" [: BODY-HOLDS ;]
   SQLITE:WITH-STATEMENT TTRUE
   s" migrations/0013.sql" ORACLE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'remote_mismatches'" [: BODY-HOLDS ;]
   SQLITE:WITH-STATEMENT TTRUE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'index' AND name = 'remote_mismatches_by_canonical_path'"
   [: BODY-HOLDS ;] SQLITE:WITH-STATEMENT TTRUE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'remote_shadows'" [: BODY-HOLDS ;]
   SQLITE:WITH-STATEMENT TTRUE
   s" migrations/0014.sql" ORACLE
   c s" SELECT sql FROM sqlite_master
      WHERE type = 'table' AND name = 'copy_stages'" [: BODY-HOLDS ;]
   SQLITE:WITH-STATEMENT TTRUE ;

: VERSIONED ( str n -- )
   {: p:str v :}
   p SQLITE:OPEN {: c :}
   s" PRAGMA user_version = " 0 PUT v swap PUT-N {: u :}
   c 0 u WANT-PART SQLITE:EXEC
   c SQLITE:CLOSE ;

: VERSION-AT ( str -- n )
   SQLITE:OPEN {: c :}
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

: CONTENT ( str -- DROPBOX:hash ) DROPBOX:>HASH ;

: CURSOR ( str -- DROPBOX:cursor ) DROPBOX:>CURSOR ;

: DISPLAY ( str -- MODEL:path ) MODEL:>PATH ;

: CANONICAL ( str ^ARENA:arena -- MODEL:key )
   {: s:str ar :}
   s DISPLAY ar MODEL:FOLD ;

: REMOTE-FILE ( str str -- MODEL:remote )
   {: c:str r:str :}
   c CONTENT r DROPBOX:>REV MODEL-REMOTE:MAKE ;

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

\ The oracle journal's file at Docs/A.txt.
: ORACLE-REMOTE ( -- MODEL:remote )
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
   s" 5f0a1b2c3d4e" REMOTE-FILE ;

\ The oracle journal's baseline at Docs/A.txt.
: ORACLE-FILE ( -- MODEL:baseline ) ORACLE-REMOTE MODEL-BASELINE:PRESENT ;

: PRESENT-REMOTE ( str str -- MODEL:observation<MODEL:remote> )
   REMOTE-FILE MODEL-OBSERVATION:PRESENT ;

: ABSENT-REMOTE ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:ABSENT ;

: INACCESSIBLE ( -- MODEL:observation<MODEL:remote> )
   MODEL-UNKNOWN--REASON:INACCESSIBLE MODEL-OBSERVATION:UNKNOWN ;

: PRESENT-LOCAL ( str -- MODEL:observation<MODEL:local> )
   CONTENT MODEL-LOCAL:MAKE MODEL-OBSERVATION:PRESENT ;

: LOCAL-DIRECTORY ( -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:DIRECTORY ;

\ The Rust tests' record(key, path, observation).
: REMOTE-RECORD
   ( str str MODEL:observation<MODEL:remote> ^ARENA:arena
     -- MODEL:remote-record )
   {: k:str p:str o ar :}
   k ar CANONICAL p DISPLAY o MODEL-REMOTE--RECORD:MAKE ;

: LOCAL-RECORD
   ( str MODEL:observation<MODEL:local> -- MODEL:local-record )
   {: p:str o :}
   p DISPLAY o MODEL-LOCAL--RECORD:MAKE ;

\ Sixty-four of the letter c, a Dropbox content hash.
: LETTER-HASH ( n ^ARENA:arena -- DROPBOX:hash )
   {: c ar :}
   ar 64 ARENA:ALLOC drop {: d:^ :}
   64 0 ?do c d i + c! loop
   d 64 >str DROPBOX:>HASH ;

\ Sixty-four "a"s, a Dropbox content hash.
: A-HASH ( ^ARENA:arena -- DROPBOX:hash ) 97 swap LETTER-HASH ;

\ The Rust tests' local_hash(path, marker).
: LOCAL-HASH ( str n ^ARENA:arena -- MODEL:hash-record )
   {: p:str m ar :}
   m 1000000000 mod {: ns :}
   p DISPLAY
   m 1 + m 2 + 1 ns 2 ns MODEL-FINGERPRINT:MAKE
   ar A-HASH MODEL-HASH--RECORD:MAKE ;

\ A hash record at the path whose hash, "new", is not Dropbox's.
: FOREIGN-HASH ( str -- MODEL:hash-record )
   DISPLAY 1 2 1 0 2 0 MODEL-FINGERPRINT:MAKE s" new" CONTENT
   MODEL-HASH--RECORD:MAKE ;

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

: CURSOR-IS? ( option<DROPBOX:cursor> str -- bool )
   {: s:str :}
   MATCH option
      none OF false ENDOF
      some OF DROPBOX:CURSOR>STR s STR:= ENDOF
   ;MATCH ;

: REMOTES=
   ( ^VEC:vector<MODEL:remote-record> ^VEC:vector<MODEL:remote-record>
     -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   true a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ MODEL:REMOTE-RECORD= and
   loop ;

: KEY-AT ( ^VEC:vector<MODEL:remote-record> n -- str )
   VEC:AT @ MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p o :}
   k MODEL:KEY>STR ;

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


: SUBTREE-PLAN-ROW ( SQLITE:statement -- SQLITE:statement )
   3 SQLITE:COL-TEXT {: a:str :}
   a s" remote_observations_by_canonical_path" STR:CONTAINS? if
      1 INDEXED +!
   then
   a s" SCAN remote_observations" STR:CONTAINS? if 1 SCANNED +! then ;

\ The plan of deleting what lies beneath "a".
: SUBTREE-PLAN ( SQLITE:statement -- SQLITE:statement )
   s" a/" 1 SQLITE:BIND-BLOB
   s\" a/\xFF" 2 SQLITE:BIND-BLOB
   begin SQLITE:STEP while SUBTREE-PLAN-ROW repeat ;


\ ---- the Rust version's lines ------------------------------------

: LOCAL-FILE-PUT ( n MODEL:local -- n )
   {: at l :}
   l MODEL-LOCAL:UNMAKE DROPBOX:HASH>STR {: h:str :}
   s" LocalFile { content: ContentIdentity(" at PUT
   h swap PUT-QUOTED s" ) }" swap PUT ;

: REMOTE-FILE-PUT ( n MODEL:remote -- n )
   {: at r :}
   r MODEL-REMOTE:UNMAKE {: h:DROPBOX:hash v:DROPBOX:rev :}
   s" RemoteFile { content: ContentIdentity(" at PUT
   h DROPBOX:HASH>STR swap PUT-QUOTED
   s" ), revision: DropboxRevision(" swap PUT
   v DROPBOX:REV>STR swap PUT-QUOTED s" ) }" swap PUT ;

\ Rust names a reason as serde does.
: UNKNOWN-PUT ( n MODEL:unknown-reason -- n )
   {: at r :}
   s" Unknown(" at PUT
   r MATCH MODEL:unknown-reason
      incomplete OF s" Incomplete" ENDOF
      inaccessible OF s" Inaccessible" ENDOF
      unavailable OF s" Unavailable" ENDOF
      stale OF s" Stale" ENDOF
      cursor-reset OF s" CursorReset" ENDOF
      unsupported OF s" Unsupported" ENDOF
   ;MATCH swap PUT
   s" )" swap PUT ;

: LOCAL-OBSERVATION-PUT ( n MODEL:observation<MODEL:local> -- n )
   {: at o :}
   o MATCH MODEL:observation
      present OF
         s" Present(" at PUT swap LOCAL-FILE-PUT s" )" swap PUT
      ENDOF
      unknown OF {: r :} at r UNKNOWN-PUT ENDOF
      directory OF s" Directory" at PUT ENDOF
      absent OF s" ConfirmedAbsent" at PUT ENDOF
   ;MATCH ;

: REMOTE-OBSERVATION-PUT ( n MODEL:observation<MODEL:remote> -- n )
   {: at o :}
   o MATCH MODEL:observation
      present OF
         s" Present(" at PUT swap REMOTE-FILE-PUT s" )" swap PUT
      ENDOF
      unknown OF {: r :} at r UNKNOWN-PUT ENDOF
      directory OF s" Directory" at PUT ENDOF
      absent OF s" ConfirmedAbsent" at PUT ENDOF
   ;MATCH ;

: LOCAL-RECORD-PUT ( n MODEL:local-record -- n )
   {: at r :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   s" LocalObservationRecord { path: " at PUT
   p MODEL:PATH>STR swap PUT-QUOTED
   s" , observation: " swap PUT o LOCAL-OBSERVATION-PUT
   s"  }" swap PUT ;

: REMOTE-RECORD-PUT ( n MODEL:remote-record -- n )
   {: at r :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   s" RemoteObservationRecord { canonical_path: CanonicalPath(" at PUT
   k MODEL:KEY>STR swap PUT-QUOTED
   s" ), path: " swap PUT p MODEL:PATH>STR swap PUT-QUOTED
   s" , observation: " swap PUT o REMOTE-OBSERVATION-PUT
   s"  }" swap PUT ;

: SEPARATED ( n n -- n )
   {: at i :}
   i 0 > if s" , " at PUT exit then
   at ;

: LOCALS-PUT ( n ^VEC:vector<MODEL:local-record> -- n )
   {: at v :}
   s" [" at PUT
   v VEC:COUNT 0 ?do i SEPARATED v i VEC:AT @ LOCAL-RECORD-PUT loop
   s" ]" swap PUT ;

: REMOTES-PUT ( n ^VEC:vector<MODEL:remote-record> -- n )
   {: at v :}
   s" [" at PUT
   v VEC:COUNT 0 ?do i SEPARATED v i VEC:AT @ REMOTE-RECORD-PUT loop
   s" ]" swap PUT ;

: CURSOR-PUT ( option<DROPBOX:cursor> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF
         DROPBOX:CURSOR>STR {: c:str :}
         s" Some(" at PUT c swap PUT-QUOTED s" )" swap PUT
      ENDOF
   ;MATCH ;

: LOCAL-INVENTORY-DEBUG ( ^VEC:vector<MODEL:local-record> -- str )
   {: v :}
   s\" local_inventory\t" 0 PUT v LOCALS-PUT {: u :}
   0 u WANT-PART ;

: REMOTE-CURSOR-DEBUG ( option<DROPBOX:cursor> -- str )
   s\" remote_cursor\t" 0 PUT CURSOR-PUT {: u :}
   0 u WANT-PART ;

: REMOTE-INVENTORY-DEBUG ( remote-inventory -- str )
   {: inv :}
   inv JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s\" remote_inventory\tRemoteInventory { cursor: " 0 PUT
   CURSOR-PUT
   s" , observations: " swap PUT v REMOTES-PUT
   s"  }" swap PUT {: u :}
   0 u WANT-PART ;

: INVENTORY-LINES ( journal ^ARENA:arena -- )
   {: j ar :}
   j ar LOCAL-INVENTORY LOCAL-INVENTORY-DEBUG HELD? TTRUE
   j ar REMOTE-CURSOR REMOTE-CURSOR-DEBUG HELD? TTRUE
   j ar REMOTE-INVENTORY REMOTE-INVENTORY-DEBUG HELD? TTRUE ;


\ ---- test-only words of the Rust version -------------------------

: LOCALS-INSERTED
   ( SQLITE:statement ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- SQLITE:statement )
   {: v ar :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ ar LOCAL-INSERTED ar ARENA:RESET
   loop ;

: LOCAL-INSERTS
   ( SQLITE:statement ^VEC:vector<MODEL:local-record>
     -- SQLITE:statement )
   [: LOCALS-INSERTED ;] ARENA:WITH ;

\ The bindings are LOCAL-INSERTED's.
: LOCAL-INSERT ( -- str )
   s" INSERT INTO local_observations(path, kind, canonical_path, content)
      VALUES (?1, ?2, ?3, ?4)" ;

: LOCAL-INVENTORY-WRITTEN
   ( SQLITE:connection ^VEC:vector<MODEL:local-record> -- )
   {: c v :}
   c s" DELETE FROM local_observations" SQLITE:EXEC
   c LOCAL-INSERT [: v LOCAL-INSERTS ;] SQLITE:WITH-STATEMENT ;

\ Replaces the local inventory, and nothing else, in one transaction.
: PUBLISH-LOCAL-INVENTORY
   ( journal ^VEC:vector<MODEL:local-record> -- )
   {: j v :}
   j >CONNECTION {: c :}
   c [: c v LOCAL-INVENTORY-WRITTEN ;] SQLITE:WITH-TRANSACTION ;


\ ---- the brief's cases -------------------------------------------

: NEW-JOURNAL-HAS-THE-ORACLE-SCHEMA ( ^ARENA:arena -- )
   {: ar :}
   s" a new journal's schema is schema.tsv's and 0010.sql's to 0014.sql's"
   T-LABEL
   s" src/oracle/schema.tsv" ORACLE
   BODY BYTES$ 10 STR:COUNT-CHAR 28 T=
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j SCHEMA-14
   j CLOSE
   d GONE ;

: OTHER-VERSIONS-ARE-REFUSED-UNCHANGED ( ^ARENA:arena -- )
   {: ar :}
   s" versions 1, 7 and 15 are refused unchanged" T-LABEL
   1 ar REFUSED
   7 ar REFUSED
   15 ar REFUSED ;

: SCHEMA-11-JOURNAL-IS-MIGRATED ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-11 journal migrates to schema 14" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ELEVEN-ORACLE
   p VERSION-AT 11 T=
   p OPEN {: j :}
   j SCHEMA-14
   j CLOSE
   d GONE ;

: SCHEMA-12-JOURNAL-IS-MIGRATED ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-12 journal migrates to schema 14" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p TWELVE-ORACLE
   p VERSION-AT 12 T=
   p OPEN {: j :}
   j SCHEMA-14
   j CLOSE
   d GONE ;

: SCHEMA-13-JOURNAL-IS-MIGRATED ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-13 journal migrates to schema 14" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p THIRTEEN-ORACLE
   p VERSION-AT 13 T=
   p OPEN {: j :}
   j SCHEMA-14
   j CLOSE
   d GONE ;

: ORACLE-JOURNAL-HOLDS-ITS-BINDINGS ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's bindings are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p FS:COPY-FILE-STREAM
   p OPEN {: j :}
   j ar DROPBOX-BINDING DROPBOX-HELD? TTRUE
   j ar LOCAL-ROOT-BINDING ROOT-HELD? TTRUE
   j CLOSE
   d GONE ;

\ The row's canonical path is the key MODEL:FOLD gives its path.
: FOLDED? ( SQLITE:statement ^ARENA:arena -- SQLITE:statement bool )
   {: ar :}
   0 SQLITE:COL-BLOB ar BYTES-PATH ar MODEL:FOLD {: k :}
   1 SQLITE:COL-BLOB k MODEL:KEY>STR SAME? ;

\ Counts the rows, each one FOLDED? holds for.
: FOLDED-ROWS ( n SQLITE:statement ^ARENA:arena -- n SQLITE:statement )
   {: ar :}
   begin SQLITE:STEP while
      ar FOLDED? TTRUE
      swap 1+ swap
   repeat ;

\ The records hold the oracle journal's three remote observations.
: ORACLE-REMOTES?
   ( ^VEC:vector<MODEL:remote-record> ^ARENA:arena -- bool )
   {: v ar :}
   v s" docs" ar CANONICAL REMOTE-DIRECTORY ANY-HOLDS?
   v s" docs/a.txt" ar CANONICAL
   ORACLE-REMOTE MODEL-OBSERVATION:PRESENT ANY-HOLDS? and
   v s" restricted" ar CANONICAL INACCESSIBLE ANY-HOLDS? and ;

\ The oracle journal's file at Docs/A.txt, as a local observation.
: ORACLE-LOCAL ( -- MODEL:observation<MODEL:local> )
   ORACLE-REMOTE MODEL-REMOTE:UNMAKE drop MODEL-LOCAL:MAKE
   MODEL-OBSERVATION:PRESENT ;

: LOCKED-LOCAL ( -- MODEL:observation<MODEL:local> )
   MODEL-UNKNOWN--REASON:INACCESSIBLE MODEL-OBSERVATION:UNKNOWN ;

\ The oracle journal's hash of Docs/A.txt.
: ORACLE-HASH ( -- MODEL:hash-record )
   s" Docs/A.txt" DISPLAY
   4243 0 1700000100 500 1700000200 600 MODEL-FINGERPRINT:MAKE
   ORACLE-REMOTE MODEL-REMOTE:UNMAKE drop MODEL-HASH--RECORD:MAKE ;

\ The oracle journal's three local records, by path.
: ORACLE-LOCALS ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   LOCALS {: v :}
   s" Docs" LOCAL-DIRECTORY LOCAL-RECORD v LOCAL+
   s" Docs/A.txt" ORACLE-LOCAL LOCAL-RECORD v LOCAL+
   s" Docs/Locked" LOCKED-LOCAL LOCAL-RECORD v LOCAL+
   v ;

: ORACLE-JOURNAL-IS-MIGRATED ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal migrates to schema 14" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p FS:COPY-FILE-STREAM
   p OPEN {: j :}
   j SCHEMA-14
   j s" Docs" DISPLAY ar BASELINE MODEL-BASELINE:DIRECTORY
   BASELINE-HELD? TTRUE
   j s" Docs/A.txt" DISPLAY ar BASELINE ORACLE-FILE BASELINE-HELD? TTRUE
   0 j >CONNECTION
   s" SELECT path, canonical_path FROM local_observations"
   [: ar FOLDED-ROWS ;] SQLITE:WITH-STATEMENT 3 T=
   j ar LOCAL-INVENTORY ar ORACLE-LOCALS LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE ORACLE-HASH ar ONE-HASH HASH-RECORDS= TTRUE
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   v VEC:COUNT 3 T=
   v ar ORACLE-REMOTES? TTRUE
   j CLOSE
   d GONE ;

\ The oracle journal without its remote_directories index fails
\ migration 9's DROP INDEX, inside the one transaction.
: FAILED-MIGRATION-LEAVES-SCHEMA-8 ( ^ARENA:arena -- )
   {: ar :}
   s" a failed migration leaves schema 8 and every row" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p FS:COPY-FILE-STREAM
   p SQLITE:OPEN {: c :}
   c s" DROP INDEX remote_directories" SQLITE:EXEC
   c SQLITE:CLOSE
   p SUBJECT !
   [: SUBJECT @ OPEN CLOSE ;] SQLITE:E-SQL d
   s" no such index: remote_directories" ar LOGGED
   p VERSION-AT 8 T=
   p SQLITE:OPEN {: k :}
   k s" SELECT COUNT(*) FROM local_observations" QUERY-INT 3 T=
   k SQLITE:CLOSE
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
   SQLITE:STEP drop 0 SQLITE:COL-TEXT s" delete" STR:= swap ;

: MEMORY-ROW? ( SQLITE:statement -- bool SQLITE:statement )
   SQLITE:STEP drop 0 SQLITE:COL-TEXT s" memory" STR:= swap ;

: WRITABLE-JOURNAL-USES-FULL-SYNCHRONOUS-ROLLBACK-MODE
   ( ^ARENA:arena -- )
   {: ar :}
   s" writable_journal_uses_full_synchronous_rollback_mode" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j >CONNECTION {: c :}
   c s" PRAGMA journal_mode" [: DELETE-ROW? ;] SQLITE:WITH-STATEMENT
   TTRUE
   c s" PRAGMA temp.journal_mode" [: MEMORY-ROW? ;] SQLITE:WITH-STATEMENT
   TTRUE
   c s" PRAGMA temp.secure_delete" QUERY-INT 0 T=
   c s" PRAGMA synchronous" QUERY-INT 2 T=
   j BUSY-MS-OF 5000 T=
   c s" PRAGMA foreign_keys" QUERY-INT 1 T=
   j CLOSE
   d GONE ;

: CREATE-FAILED ( -- str )
   s" journal operation `create journal database` failed for" ;

\ Opening path throws E-FILE with a log line in dir holding the text.
: OPEN-REFUSED ( str str str ^ARENA:arena -- )
   {: path:str dir:str t:str ar :}
   path SUBJECT !
   [: SUBJECT @ OPEN CLOSE ;] E-FILE dir t ar LOGGED ;

\ A file failure on ENOSPC throws E-DISK-FULL, logged as E-FILE is.
: A-FULL-DISK-IS-ITS-OWN-CODE ( ^ARENA:arena -- )
   {: ar :}
   s" a full disk is its own code" T-LABEL
   ar SCRATCH {: d:str :}
   d SUBJECT !
   [: s" create journal database" SUBJECT @ E-FS-OPEN FS:ENOSPC
      FILE-FAILED ;] E-DISK-FULL d CREATE-FAILED ar LOGGED
   d GONE ;

: JOURNAL-CREATION-REPORTS-ITS-OWN-FILESYSTEM-FAILURE
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_creation_reports_its_own_filesystem_failure" T-LABEL
   ar SCRATCH {: d:str :}
   d s" sealed" ar INSIDE {: sealed:str :}
   sealed FS:MAKE-DIR
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
   sealed FS:MAKE-DIR
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

: GARBAGE ( -- str )
   s" these bytes are text, not a SQLite database's" ;

: GARBAGE-KEPT? ( str -- bool )
   false READ-BODY BODY BYTES$ GARBAGE STR:= ;

: GARBAGE-FILE-IS-CORRUPT ( ^ARENA:arena -- )
   {: ar :}
   s" a file of other bytes is corrupt to both opens" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p GARBAGE FS:WRITE-ALL
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
   d FS:OPEN-DIR {: dir:fd :}
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
   f s" file" FS:WRITE-ALL
   f SUBJECT !
   [: SUBJECT @ INSPECT drop ;] E-ROOT d
   s" journal operation `inspect local root` failed for" ar LOGGED
   d GONE ;

: UNBORN-SYNC ( -- )
   s" /sync" 2 BIRTH-5 false 256 true FROM-STATX-FIELDS drop ;

: ROOT-IDENTITY-REQUIRES-A-RECORDED-BIRTH-TIME ( ^ARENA:arena -- )
   {: ar :}
   s" root_identity_requires_a_recorded_birth_time" T-LABEL
   ar SCRATCH {: d:str :}
   [: UNBORN-SYNC ;] E-NO-BIRTH-TIME d s" sync root `/sync` is on" ar
   LOGGED
   s" /sync" 2 BIRTH-5 true 256 false FROM-STATX-FIELDS
   SUBVOLUME-OF NO-INT? TTRUE
   d GONE ;

: RECORDED ( str option<birth-time> -- local-root-record )
   {: a:str birth :}
   a 2 birth NO-SUBVOLUME JOURNAL-LOCAL--ROOT--BINDING:MAKE
   1 JOURNAL-LOCAL--ROOT--RECORD:MAKE ;

\ The Rust test's last case, a File error, has no counterpart: the
\ caller asks STOOD-IN-BY? only of an E-NO-BIRTH-TIME refusal.
: STAND-IN-NEEDS-THE-ROOT-PATH-AND-A-BIRTH-TIME-OR-ANOTHER-INODE ( -- )
   s" stand_in_needs_the_root_path_and_a_birth_time_or_another_inode"
   T-LABEL
   s" /sync/root" BIRTH-5 OPTION:SOME RECORDED {: born :}
   born s" /sync/root" 2 STOOD-IN-BY? TTRUE
   born s" /sync/root" 9 STOOD-IN-BY? TTRUE
   s" /sync/root" NO-BIRTH RECORDED {: legacy :}
   legacy s" /sync/root" 9 STOOD-IN-BY? TTRUE
   legacy s" /sync/root" 2 STOOD-IN-BY? TFALSE
   s" /sync/other" BIRTH-5 OPTION:SOME RECORDED {: elsewhere :}
   elsewhere s" /sync/root" 9 STOOD-IN-BY? TFALSE ;

\ A directory whose filesystem reports no birth time.
: SYS-KERNEL ( -- str ) s" /sys/kernel" ;

: SYS-INODE ( -- n ) SYS-KERNEL FS:TRY-STAT TTRUE FS:STAT-INO@ ;

: SYS-REFUSAL ( -- str ) s" sync root `/sys/kernel` is on" ;

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
   15 ar REFUSED ;

: JOURNAL-SCHEMA-AND-PAYLOAD-COLUMNS-ARE-NOT-SECRET-BEARING
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_schema_and_payload_columns_are_not_secret_bearing" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j >CONNECTION
   s" SELECT lower(group_concat(name || ' ' || sql, char(10)))
      FROM sqlite_master
      WHERE type IN ('table', 'index') AND sql IS NOT NULL" [: SCHEMA-TEXT ;] SQLITE:WITH-STATEMENT
   BODY BYTES$ {: b:str :}
   b s" oauth" STR:CONTAINS? TFALSE
   b s" credential" STR:CONTAINS? TFALSE
   b s" access_token" STR:CONTAINS? TFALSE
   b s" refresh_token" STR:CONTAINS? TFALSE
   b s" secret" STR:CONTAINS? TFALSE
   b s" local_root_binding" STR:CONTAINS? TTRUE
   j CLOSE
   d GONE ;


\ ---- inventories -------------------------------------------------

: ORACLE-JOURNAL-HOLDS-ITS-INVENTORIES ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's inventories are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p FS:COPY-FILE-STREAM
   p OPEN {: j :}
   j ar INVENTORY-LINES
   j CLOSE
   d GONE ;

: PUBLISH-DUPLICATES ( -- )
   THE-JOURNAL @ s" cursor-new" CURSOR THE-REMOTES @
   SUBJECT-ARENA @ DELTA PUBLISH-REMOTE-INVENTORY ;

: JOURNAL-REMOTE-INVENTORY-AND-CURSOR-PUBLISH-ATOMICALLY
   ( ^ARENA:arena -- )
   {: ar :}
   s" journal_remote_inventory_and_cursor_publish_atomically" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" old.txt" s" old.txt" s" old" s" rev-old" PRESENT-REMOTE ar
   REMOTE-RECORD ar ONE-REMOTE {: old :}
   j s" cursor-old" CURSOR old ar DELTA PUBLISH-REMOTE-INVENTORY
   ar REMOTES {: dups :}
   s" duplicate.txt" s" duplicate.txt" REMOTE-DIRECTORY ar
   REMOTE-RECORD dups REMOTE+
   s" duplicate.txt" s" duplicate.txt" s" new" s" rev-new" PRESENT-REMOTE
   ar REMOTE-RECORD dups REMOTE+
   j THE-JOURNAL !  dups THE-REMOTES !  ar SUBJECT-ARENA !
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
   s" bulk/" STR:data dst 5 BYTE-COPY
   s" .txt" STR:data dst 10 + 4 BYTE-COPY
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
   j s" cursor-old" CURSOR ar BULK ar DELTA
   PUBLISH-REMOTE-INVENTORY
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

: SUBTREE-PLAN-SQL ( -- str )
   s" EXPLAIN QUERY PLAN " 0 PUT
   DELETE-REMOTE-DESCENDANTS swap PUT {: u :}
   0 u WANT-PART ;

: REMOTE-DELTA-DELETES-ONLY-THE-NAMED-SUBTREE ( ^ARENA:arena -- )
   {: ar :}
   s" remote_delta_deletes_only_the_named_subtree" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" cursor-old" CURSOR ar SUBTREE-SAMPLE ar DELTA
   PUBLISH-REMOTE-INVENTORY
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
   ar DELTA PUBLISH-REMOTE-INVENTORY
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

\ Whether the answer is the record.
: REMOTE-IS? ( option<MODEL:remote-record> MODEL:remote-record -- bool )
   {: want :}
   MATCH option
      none OF false ENDOF
      some OF want MODEL:REMOTE-RECORD= ENDOF
   ;MATCH ;

: NO-REMOTE? ( option<MODEL:remote-record> -- bool )
   MATCH option none OF true ENDOF some OF drop false ENDOF ;MATCH ;

\ REMOTE-AT answers the record at a key, an unknown one included, and
\ none where no row holds it.
: REMOTE-AT-ANSWERS-THE-RECORD-AT-A-KEY ( ^ARENA:arena -- )
   {: ar :}
   s" remote at answers the record at a key" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   ar RESTRICTED-SAMPLE {: v :}
   j s" cursor" CURSOR v ar DELTA PUBLISH-REMOTE-INVENTORY
   j s" docs/a.txt" ar CANONICAL ar REMOTE-AT v 1 VEC:AT @ REMOTE-IS?
   TTRUE
   j s" shared" ar CANONICAL ar REMOTE-AT v 2 VEC:AT @ REMOTE-IS? TTRUE
   j s" absent" ar CANONICAL ar REMOTE-AT NO-REMOTE? TTRUE
   j CLOSE
   d GONE ;

\ "Ꭰ", U+13A0, folds to "ꭰ", U+AB70, which Dropbox keeps as its own
\ fold: an entry at lower "Ꭰ.txt" holds the key "ꭰ.txt".
: SHARED-LOWER ( -- str ) s" Ꭰ.txt" ;
: SHARED-OWN ( -- str ) s" ꭰ.txt" ;
\ A spelling of SHARED-OWN's key other than its bytes.
: SHARED-SPELLED ( -- str ) s" ꭰ.TXT" ;

: HOLD ( MODEL:path MODEL:key MODEL:path -- remote-inventory-change )
   construct remote-inventory-change hold ;

: UNHOLD ( MODEL:path MODEL:key -- remote-inventory-change )
   construct remote-inventory-change unhold ;

\ The hold of the entry at lower l, on l's fold, spelled as its bytes.
: HOLD-AT ( str ^ARENA:arena -- remote-inventory-change )
   {: l:str ar :}
   l ar CANONICAL {: k :}
   l DISPLAY k k MODEL:KEY>STR DISPLAY HOLD ;

: UNHOLD-AT ( str ^ARENA:arena -- remote-inventory-change )
   {: l:str ar :}
   l DISPLAY l ar CANONICAL UNHOLD ;

: UNSUPPORTED-REMOTE ( -- MODEL:observation<MODEL:remote> )
   MODEL-UNKNOWN--REASON:UNSUPPORTED MODEL-OBSERVATION:UNKNOWN ;

\ The unsupported record HOLD-AT's hold shows at the key k, its path
\ k's bytes.
: HELD-RECORD ( str ^ARENA:arena -- MODEL:remote-record )
   {: k:str ar :}
   k ar CANONICAL {: key:MODEL:key :}
   key key MODEL:KEY>STR DISPLAY UNSUPPORTED-REMOTE
   MODEL-REMOTE--RECORD:MAKE ;

: OWN-FILE ( ^ARENA:arena -- MODEL:remote-record )
   {: ar :}
   SHARED-OWN SHARED-OWN OLD-FILE ar REMOTE-RECORD ;

\ Applies the one change, with the cursor s.
: CHANGED ( journal str remote-inventory-change ^ARENA:arena -- )
   {: j s:str c ar :}
   j s CURSOR c ar ONE-CHANGE APPLY-REMOTE-INVENTORY-DELTA ;

: REMOTE-AT-KEY
   ( journal str ^ARENA:arena -- option<MODEL:remote-record> )
   {: j k:str ar :}
   j k ar CANONICAL ar REMOTE-AT ;

: PUBLISHED-ALONE ( journal MODEL:remote-record ^ARENA:arena -- )
   {: j r ar :}
   j s" cursor" CURSOR r ar ONE-REMOTE ar DELTA
   PUBLISH-REMOTE-INVENTORY ;

: A-HOLD-HIDES-THE-RECORD-UNTIL-ITS-UNHOLD ( ^ARENA:arena -- )
   {: ar :}
   s" a hold hides the key's record until its unhold" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   ar OWN-FILE {: f :}
   j f ar PUBLISHED-ALONE
   SHARED-OWN ar CANONICAL {: k :}
   SHARED-SPELLED DISPLAY {: sp :}
   j s" cursor-hold" SHARED-LOWER DISPLAY k sp HOLD ar CHANGED
   j SHARED-OWN ar REMOTE-AT-KEY k sp UNSUPPORTED-REMOTE
   MODEL-REMOTE--RECORD:MAKE REMOTE-IS? TTRUE
   j s" cursor-unhold" SHARED-LOWER ar UNHOLD-AT ar CHANGED
   j SHARED-OWN ar REMOTE-AT-KEY f REMOTE-IS? TTRUE
   j CLOSE
   d GONE ;

: A-HELD-KEY-OUTLIVES-ITS-OWN-DELETION ( ^ARENA:arena -- )
   {: ar :}
   s" a held key stays unsupported past its own entry's deletion"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j ar OWN-FILE ar PUBLISHED-ALONE
   j s" cursor-hold" SHARED-LOWER ar HOLD-AT ar CHANGED
   j s" cursor-delete" SHARED-OWN ar CANONICAL DELETE-SUBTREE ar CHANGED
   j SHARED-OWN ar REMOTE-AT-KEY SHARED-OWN ar HELD-RECORD REMOTE-IS?
   TTRUE
   j s" cursor-unhold" SHARED-LOWER ar UNHOLD-AT ar CHANGED
   j SHARED-OWN ar REMOTE-AT-KEY NO-REMOTE? TTRUE
   j CLOSE
   d GONE ;

\ "Ꭰ/x.txt" holds "ꭰ/x.txt"; the unhold of "Ꭰ" releases it.
: AN-UNHOLD-RELEASES-THE-HOLDS-BENEATH-IT ( ^ARENA:arena -- )
   {: ar :}
   s" an unhold releases the holds beneath its lower" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" cursor" CURSOR ar REMOTES ar DELTA PUBLISH-REMOTE-INVENTORY
   j s" cursor-hold" s" Ꭰ/x.txt" ar HOLD-AT ar CHANGED
   j s" ꭰ/x.txt" ar REMOTE-AT-KEY s" ꭰ/x.txt" ar HELD-RECORD
   REMOTE-IS? TTRUE
   j s" cursor-unhold" s" Ꭰ" ar UNHOLD-AT ar CHANGED
   j s" ꭰ/x.txt" ar REMOTE-AT-KEY NO-REMOTE? TTRUE
   j CLOSE
   d GONE ;

\ "d/Ꭰ.txt" holds "d/ꭰ.txt"; the deletion of "d" releases it.
: A-SUBTREE-DELETION-RELEASES-THE-HOLDS-BENEATH-IT ( ^ARENA:arena -- )
   {: ar :}
   s" a subtree deletion releases the holds beneath its key" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" d" s" d" REMOTE-DIRECTORY ar REMOTE-RECORD ar PUBLISHED-ALONE
   j s" cursor-hold" s" d/Ꭰ.txt" ar HOLD-AT ar CHANGED
   j s" d/ꭰ.txt" ar REMOTE-AT-KEY s" d/ꭰ.txt" ar HELD-RECORD
   REMOTE-IS? TTRUE
   j s" cursor-delete" s" d" ar CANONICAL DELETE-SUBTREE ar CHANGED
   j s" d/ꭰ.txt" ar REMOTE-AT-KEY NO-REMOTE? TTRUE
   j CLOSE
   d GONE ;

: A-LISTING-HOLDS-A-DIRECTORY-KEY ( ^ARENA:arena -- )
   {: ar :}
   s" a listing's hold hides a directory REMOTE-LISTED-AT still finds"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" ꭰ" s" ꭰ" REMOTE-DIRECTORY ar REMOTE-RECORD {: dir :}
   j s" cursor" CURSOR dir ar ONE-REMOTE
   s" Ꭰ" ar HOLD-AT ar ONE-CHANGE PUBLISH-REMOTE-INVENTORY
   j s" ꭰ" ar REMOTE-AT-KEY s" ꭰ" ar HELD-RECORD REMOTE-IS? TTRUE
   j s" ꭰ" ar CANONICAL ar REMOTE-LISTED-AT dir REMOTE-IS? TTRUE
   j s" cursor-unhold" s" Ꭰ" ar UNHOLD-AT ar CHANGED
   j s" ꭰ" ar REMOTE-AT-KEY dir REMOTE-IS? TTRUE
   j CLOSE
   d GONE ;

\ The hold of "other.txt" on the key "ꭰ.txt", which it does not fold to.
: STRAY-HOLD ( ^ARENA:arena -- ^VEC:vector<remote-inventory-change> )
   {: ar :}
   SHARED-OWN ar CANONICAL {: k :}
   s" other.txt" DISPLAY k k MODEL:KEY>STR DISPLAY HOLD ar ONE-CHANGE ;

: PUBLISH-STRAY-HOLD ( -- )
   THE-JOURNAL @ s" cursor-new" CURSOR THE-REMOTES @
   SUBJECT-ARENA @ STRAY-HOLD PUBLISH-REMOTE-INVENTORY ;

: A-HOLD-ON-ANOTHER-FOLD-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" a hold on a key its lower does not fold to is refused" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   ar OWN-FILE {: f :}
   j f ar PUBLISHED-ALONE
   j THE-JOURNAL !  ar REMOTES THE-REMOTES !  ar SUBJECT-ARENA !
   [: PUBLISH-STRAY-HOLD ;] E-INVALID-STATE d
   s" canonical path does not match display path" ar LOGGED
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s" cursor" CURSOR-IS? TTRUE
   v f ar ONE-REMOTE REMOTES= TTRUE
   j >CONNECTION s" SELECT count(*) FROM remote_mismatches" QUERY-INT
   0 T=
   j CLOSE
   d GONE ;

\ The hold of SHARED-LOWER on its key, its record spelled "other.txt".
: MISSPELLED-HOLD
   ( ^ARENA:arena -- ^VEC:vector<remote-inventory-change> )
   {: ar :}
   SHARED-LOWER DISPLAY SHARED-OWN ar CANONICAL s" other.txt" DISPLAY HOLD
   ar ONE-CHANGE ;

: PUBLISH-MISSPELLED-HOLD ( -- )
   THE-JOURNAL @ s" cursor-new" CURSOR THE-REMOTES @
   SUBJECT-ARENA @ MISSPELLED-HOLD PUBLISH-REMOTE-INVENTORY ;

: A-HOLD-SPELLED-AS-ANOTHER-KEY-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" a hold whose path does not fold to its key is refused" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   ar OWN-FILE {: f :}
   j f ar PUBLISHED-ALONE
   j THE-JOURNAL !  ar REMOTES THE-REMOTES !  ar SUBJECT-ARENA !
   [: PUBLISH-MISSPELLED-HOLD ;] E-INVALID-STATE d
   s" `other.txt`: canonical path does not match display path" ar LOGGED
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   cur s" cursor" CURSOR-IS? TTRUE
   v f ar ONE-REMOTE REMOTES= TTRUE
   j >CONNECTION s" SELECT count(*) FROM remote_mismatches" QUERY-INT
   0 T=
   j CLOSE
   d GONE ;

: UNKNOWN-LOCAL
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:UNKNOWN ;

: ABSENT-LOCAL ( -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:ABSENT ;

: STALE-REMOTE ( -- MODEL:observation<MODEL:remote> )
   MODEL-UNKNOWN--REASON:STALE MODEL-OBSERVATION:UNKNOWN ;

\ A local inventory of each observation a row holds, out of path order;
\ its unknown paths, Thumbs.db an excluded name, sort otherwise once
\ folded.
: MIXED-LOCALS ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: ar :}
   ar LOCALS {: v :}
   s" z-unknown.txt" MODEL-UNKNOWN--REASON:UNAVAILABLE UNKNOWN-LOCAL
   LOCAL-RECORD v LOCAL+
   s" a.txt" s" a" PRESENT-LOCAL LOCAL-RECORD v LOCAL+
   s" dir" LOCAL-DIRECTORY LOCAL-RECORD v LOCAL+
   s" Thumbs.db" MODEL-UNKNOWN--REASON:INACCESSIBLE UNKNOWN-LOCAL
   LOCAL-RECORD v LOCAL+
   s" m-unknown" MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-LOCAL
   LOCAL-RECORD v LOCAL+
   v ;

\ MIXED-LOCALS' unknown records, by path.
: UNKNOWN-SAMPLE-LOCALS
   ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: ar :}
   ar LOCALS {: v :}
   s" Thumbs.db" MODEL-UNKNOWN--REASON:INACCESSIBLE UNKNOWN-LOCAL
   LOCAL-RECORD v LOCAL+
   s" m-unknown" MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-LOCAL
   LOCAL-RECORD v LOCAL+
   s" z-unknown.txt" MODEL-UNKNOWN--REASON:UNAVAILABLE UNKNOWN-LOCAL
   LOCAL-RECORD v LOCAL+
   v ;

\ A remote inventory of each observation a row holds, out of canonical
\ path order; its unknown spellings, Thumbs.db an excluded name, sort
\ otherwise.
: MIXED-REMOTES ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: ar :}
   ar REMOTES {: v :}
   s" z-shared" s" Z-Shared" INACCESSIBLE ar REMOTE-RECORD v REMOTE+
   s" a.txt" s" A.txt" s" a" s" rev-a" PRESENT-REMOTE
   ar REMOTE-RECORD v REMOTE+
   s" docs" s" Docs" REMOTE-DIRECTORY ar REMOTE-RECORD v REMOTE+
   s" thumbs.db" s" Thumbs.db" STALE-REMOTE ar REMOTE-RECORD v REMOTE+
   s" m-stale" s" m-stale" STALE-REMOTE ar REMOTE-RECORD v REMOTE+
   v ;

\ MIXED-REMOTES' unknown records, by canonical path.
: UNKNOWN-SAMPLE-REMOTES
   ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: ar :}
   ar REMOTES {: v :}
   s" m-stale" s" m-stale" STALE-REMOTE ar REMOTE-RECORD v REMOTE+
   s" thumbs.db" s" Thumbs.db" STALE-REMOTE ar REMOTE-RECORD v REMOTE+
   s" z-shared" s" Z-Shared" INACCESSIBLE ar REMOTE-RECORD v REMOTE+
   v ;

: UNKNOWN-OBSERVATIONS-ARE-READ-ALONE ( ^ARENA:arena -- )
   {: ar :}
   s" unknown observations are read alone, in path order" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j ar MIXED-LOCALS PUBLISH-LOCAL-INVENTORY
   j s" cursor" CURSOR ar MIXED-REMOTES ar DELTA
   PUBLISH-REMOTE-INVENTORY
   j ar UNKNOWN-LOCALS ar UNKNOWN-SAMPLE-LOCALS LOCAL-RECORDS= TTRUE
   j ar UNKNOWN-REMOTES ar UNKNOWN-SAMPLE-REMOTES REMOTES= TTRUE
   j CLOSE
   d GONE ;

\ Notes each published row's rowid, path and value in temporary tables.
: ROWS-NOTED ( journal -- )
   >CONNECTION
   s" DROP TABLE IF EXISTS temp.noted_observations;
      DROP TABLE IF EXISTS temp.noted_hashes;
      CREATE TEMP TABLE noted_observations AS
         SELECT rowid AS id, path, kind, content
         FROM local_observations;
      CREATE TEMP TABLE noted_hashes AS
         SELECT rowid AS id, * FROM local_hash_cache;" SQLITE:EXEC ;

\ The observation rows noted that remain with their rowid, the rows
\ added since, and the rows noted that are gone.
: OBSERVATIONS-MOVED ( journal -- n n n )
   >CONNECTION {: c :}
   c s" SELECT COUNT(*) FROM (
         SELECT rowid, path, kind, content FROM local_observations
         INTERSECT SELECT * FROM noted_observations)" QUERY-INT
   c s" SELECT COUNT(*) FROM (
         SELECT rowid, path, kind, content FROM local_observations
         EXCEPT SELECT * FROM noted_observations)" QUERY-INT
   c s" SELECT COUNT(*) FROM (
         SELECT * FROM noted_observations
         EXCEPT SELECT rowid, path, kind, content
         FROM local_observations)"
   QUERY-INT ;

\ OBSERVATIONS-MOVED's counts for the hash cache.
: HASHES-MOVED ( journal -- n n n )
   >CONNECTION {: c :}
   c s" SELECT COUNT(*) FROM (
         SELECT rowid, * FROM local_hash_cache
         INTERSECT SELECT * FROM noted_hashes)" QUERY-INT
   c s" SELECT COUNT(*) FROM (
         SELECT rowid, * FROM local_hash_cache
         EXCEPT SELECT * FROM noted_hashes)" QUERY-INT
   c s" SELECT COUNT(*) FROM (
         SELECT * FROM noted_hashes EXCEPT
         SELECT rowid, * FROM local_hash_cache)"
   QUERY-INT ;

\ The counts OBSERVATIONS-MOVED and HASHES-MOVED answer are the ones given.
: MOVED= ( n n n n n n -- )
   {: k a g wk wa wg :}
   k wk T=  a wa T=  g wg T= ;

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
   j ROWS-NOTED
   j b old ar ONE-LOCAL old-hash ar ONE-HASH PUBLISH-LOCAL-SCAN TTRUE
   j OBSERVATIONS-MOVED 1 0 0 MOVED=  j HASHES-MOVED 1 0 0 MOVED=
   s" new.txt" s" new" PRESENT-LOCAL LOCAL-RECORD ar ONE-LOCAL
   {: replacement :}
   j THE-JOURNAL !  b THE-BINDING !
   replacement THE-LOCALS !  s" new.txt" FOREIGN-HASH ar ONE-HASH THE-HASHES !
   [: PUBLISH-HELD-SCAN ;] E-INVALID-STATE d
   s" is not a Dropbox content hash" ar LOGGED
   j old old-hash ar SCAN-HELD
   j s" /stale" 4 LOCAL-ROOT replacement
   s" new.txt" 20 ar LOCAL-HASH ar ONE-HASH PUBLISH-LOCAL-SCAN TFALSE
   j OBSERVATIONS-MOVED 1 0 0 MOVED=  j HASHES-MOVED 1 0 0 MOVED=
   j CLOSE
   d GONE ;


\ Adds the path's observation, with the content, and its hash, with
\ the marker, to the scan.
: SCAN+
   ( str str n ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> ^ARENA:arena -- )
   {: p:str c:str m obs hashes ar :}
   p c PRESENT-LOCAL LOCAL-RECORD obs LOCAL+
   p m ar LOCAL-HASH hashes HASH+ ;

\ The journal at the path, opened with /sync its active root.
: ACTIVE-JOURNAL ( str ^ARENA:arena -- journal local-root-binding )
   {: p:str ar :}
   p OPEN {: j :}
   s" /sync" 2 LOCAL-ROOT {: b :}
   j b ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j b ;

: A-SCAN-PUBLISHES-ONLY-ITS-DIFFERENCE ( ^ARENA:arena -- )
   {: ar :}
   s" a scan publishes only its difference" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a.txt" s" a" 1 obs hashes ar SCAN+
   s" b.txt" s" b" 2 obs hashes ar SCAN+
   s" c.txt" s" c" 3 obs hashes ar SCAN+
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE
   j ROWS-NOTED
   j CHANGE-COUNTER {: before :}
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE
   j CHANGE-COUNTER before T=
   j OBSERVATIONS-MOVED 3 0 0 MOVED=  j HASHES-MOVED 3 0 0 MOVED=
   ar LOCALS {: next :}  ar HASHES {: next-hashes :}
   s" a.txt" s" a" 1 next next-hashes ar SCAN+
   s" b.txt" s" b2" 4 next next-hashes ar SCAN+
   s" d.txt" s" d" 5 next next-hashes ar SCAN+
   j b next next-hashes PUBLISH-LOCAL-SCAN TTRUE
   j OBSERVATIONS-MOVED 1 2 2 MOVED=  j HASHES-MOVED 1 2 2 MOVED=
   j ar LOCAL-INVENTORY next LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE next-hashes HASH-RECORDS= TTRUE
   j CLOSE
   d GONE ;

: A-SCAN-DROPS-HASHES-OF-ANOTHER-GENERATION ( ^ARENA:arena -- )
   {: ar :}
   s" a scan drops the hashes of another generation" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a.txt" s" a" 1 obs hashes ar SCAN+
   s" b.txt" s" b" 2 obs hashes ar SCAN+
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE
   j >CONNECTION
   s" INSERT INTO local_hash_cache
      SELECT root_generation + 1, path, inode, size, modified_seconds,
         modified_nanoseconds, changed_seconds, changed_nanoseconds,
         content_hash
      FROM local_hash_cache"
   SQLITE:EXEC
   j ROWS-NOTED
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE
   j OBSERVATIONS-MOVED 2 0 0 MOVED=  j HASHES-MOVED 2 0 2 MOVED=
   j >CONNECTION
   s" SELECT COUNT(*) FROM local_hash_cache WHERE root_generation != 1"
   QUERY-INT 0 T=
   j CLOSE
   d GONE ;

variable ROWS-SEEN       \ rows an EACH-SCAN-JOB body was given

\ The fingerprint of the marker, a negative field among it.
: MARKED-FINGERPRINT ( n -- MODEL:fingerprint )
   {: m :}
   m m 1 + -1 999999999 m 2 + m 3 + MODEL-FINGERPRINT:MAKE ;

\ The n-th path in byte order of "a", "a-b" and "a/x", the walk's order
\ of them, and its marker.
: ORDERED-PATH ( n -- str )
   dup 0= if drop s" a" exit then
   1 = if s" a-b" exit then
   s" a/x" ;

: ORDERED-MARK ( n -- n )
   dup 0= if drop 3 exit then
   1 = if 1 exit then
   2 ;

\ The path is the n-th one of the order, counted in ROWS-SEEN.
: SEEN-AT ( str [ n -- str ] -- n )
   {: p:str order :}
   ROWS-SEEN @ {: k :}
   p k order execute STR:= TTRUE
   1 ROWS-SEEN +!
   k ;

: JOB-SEEN ( scan str MODEL:fingerprint -- scan )
   {: p:str f :}
   p [: ORDERED-PATH ;] SEEN-AT {: k :}
   k ORDERED-MARK MARKED-FINGERPRINT f MODEL:FINGERPRINT= TTRUE ;

: JOB-COUNTED ( scan str MODEL:fingerprint -- scan )
   {: p:str f :} 1 ROWS-SEEN +! ;

\ After LOCAL-HASH's times, and in the reuse table seconds 100.
: REUSE-CUTOFF ( -- option<MODEL:cutoff> )
   100 500 MODEL-CUTOFF:MAKE OPTION:SOME ;

: NO-CUTOFF ( -- option<MODEL:cutoff> ) OPTION:NONE ;

\ The scan holds no job to visit.
: NOTHING-LEFT ( scan -- scan )
   0 ROWS-SEEN !
   [: JOB-COUNTED ;] EACH-SCAN-JOB
   ROWS-SEEN @ 0 T= ;

\ Puts old.txt in each of the scan's tables, publishing nothing.
: OLD-SCANNED ( scan ^ARENA:arena -- scan )
   {: ar :}
   s" old.txt" 10 MARKED-FINGERPRINT NO-CUTOFF SCAN-FILE
   s" old.txt" s" old" PRESENT-LOCAL LOCAL-RECORD SCAN-OBSERVE
   s" old.txt" 10 ar LOCAL-HASH SCAN-HASH ;

\ Observes and hashes new.txt, then publishes the scan.
: NEW-PUBLISHED
   ( scan local-root-binding MODEL:local-record MODEL:hash-record
     -- scan )
   {: b new new-hash :}
   NOTHING-LEFT
   new SCAN-OBSERVE  new-hash SCAN-HASH
   b PUBLISH-SCAN TTRUE ;

: WITH-SCAN-EMPTIES-THE-PREVIOUS-SCAN ( ^ARENA:arena -- )
   {: ar :}
   s" WITH-SCAN empties the previous scan" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   s" old.txt" 10 ar LOCAL-HASH {: old-hash :}
   j b ar LOCALS old-hash ar ONE-HASH PUBLISH-LOCAL-SCAN TTRUE
   j [: ar OLD-SCANNED ;] WITH-SCAN
   s" new.txt" s" new" PRESENT-LOCAL LOCAL-RECORD {: new :}
   s" new.txt" 20 ar LOCAL-HASH {: new-hash :}
   j [: b new new-hash NEW-PUBLISHED ;] WITH-SCAN
   j new new-hash ar SCAN-HELD
   j CLOSE
   d GONE ;

\ Ends the walk, observes and hashes new.txt, then publishes the scan
\ for a root that is not active, which writes nothing.
: STALE-PUBLISHED ( scan journal ^ARENA:arena -- scan )
   {: j ar :}
   NOTHING-LEFT
   s" new.txt" s" new" PRESENT-LOCAL LOCAL-RECORD SCAN-OBSERVE
   s" new.txt" 20 ar LOCAL-HASH SCAN-HASH
   j TOTAL-CHANGES {: before :}
   s" /stale" 4 LOCAL-ROOT PUBLISH-SCAN TFALSE
   j TOTAL-CHANGES before T= ;

: A-SCAN-FOR-ANOTHER-ROOT-WRITES-NOTHING ( ^ARENA:arena -- )
   {: ar :}
   s" a scan for a root that is not active writes nothing" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   s" old.txt" s" old" PRESENT-LOCAL LOCAL-RECORD {: old :}
   s" old.txt" 10 ar LOCAL-HASH {: old-hash :}
   j b old ar ONE-LOCAL old-hash ar ONE-HASH PUBLISH-LOCAL-SCAN TTRUE
   j ROWS-NOTED
   j [: j ar STALE-PUBLISHED ;] WITH-SCAN
   j OBSERVATIONS-MOVED 1 0 0 MOVED=  j HASHES-MOVED 1 0 0 MOVED=
   j CLOSE
   d GONE ;

: DIRECTORY-LOCAL ( str -- MODEL:local-record )
   LOCAL-DIRECTORY LOCAL-RECORD ;

\ The journal at a new path, given to body, closed and removed after.
: ON-NEW-JOURNAL ( ^ARENA:arena [ journal -- ] -- )
   {: ar body :}
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j body execute
   j CLOSE
   d GONE ;

: JOBS-VISITED ( scan -- scan )
   s" a" 3 MARKED-FINGERPRINT NO-CUTOFF SCAN-FILE
   s" a-b" 1 MARKED-FINGERPRINT NO-CUTOFF SCAN-FILE
   s" a/x" 2 MARKED-FINGERPRINT NO-CUTOFF SCAN-FILE
   0 ROWS-SEEN !  [: JOB-SEEN ;] EACH-SCAN-JOB  ROWS-SEEN @ 3 T=
   0 ROWS-SEEN !  [: JOB-COUNTED ;] EACH-SCAN-JOB  ROWS-SEEN @ 0 T= ;

: EACH-SCAN-JOB-VISITS-EACH-ROW-ONCE-IN-PATH-ORDER ( ^ARENA:arena -- )
   s" EACH-SCAN-JOB visits each row once in path order" T-LABEL
   [: [: JOBS-VISITED ;] WITH-SCAN ;] ON-NEW-JOURNAL ;

: PRINT-OF ( MODEL:hash-record -- MODEL:fingerprint )
   MODEL-HASH--RECORD:UNMAKE {: p:MODEL:path f h :} f ;

\ The job's visit observes and hashes its file.
: HASHED-VISIT
   ( scan str MODEL:fingerprint MODEL:hash-record -- scan )
   {: p:str f h :}
   p s" a" PRESENT-LOCAL LOCAL-RECORD SCAN-OBSERVE
   h SCAN-HASH ;

\ The cache's hash at "a.txt" is another file's: the walk's file is a
\ job, its cached hash gone until the visit hashes it.
: HASHED-PUBLISHED ( scan local-root-binding ^ARENA:arena -- scan )
   {: b ar :}
   s" a.txt" 11 ar LOCAL-HASH {: h :}
   s" a.txt" h PRINT-OF REUSE-CUTOFF SCAN-FILE
   [: h HASHED-VISIT ;] EACH-SCAN-JOB
   b PUBLISH-SCAN TTRUE ;

\ The hash the visit computed replaces the cached one.
: A-VISIT-PUBLISHES-WHAT-IT-OBSERVES-AND-HASHES ( ^ARENA:arena -- )
   {: ar :}
   s" a visit publishes what it observes and hashes" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar LOCALS s" a.txt" 10 ar LOCAL-HASH ar ONE-HASH
   PUBLISH-LOCAL-SCAN TTRUE
   j [: b ar HASHED-PUBLISHED ;] WITH-SCAN
   j s" a.txt" s" a" PRESENT-LOCAL LOCAL-RECORD
   s" a.txt" 11 ar LOCAL-HASH ar SCAN-HELD
   j CLOSE
   d GONE ;

\ ---- the merge

\ The file the record's hash is the content of.
: CACHED-FILE ( MODEL:hash-record -- MODEL:local-record )
   MODEL-HASH--RECORD:UNMAKE {: p:MODEL:path f h :}
   p h MODEL-LOCAL:MAKE MODEL-OBSERVATION:PRESENT
   MODEL-LOCAL--RECORD:MAKE ;

\ The file at the path, with the marker's hash, and the hash.
: CACHED+
   ( str n ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> ^ARENA:arena -- )
   {: p:str m obs hashes ar :}
   p m ar LOCAL-HASH {: h :}
   h CACHED-FILE obs LOCAL+  h hashes HASH+ ;

\ The path with the marker's fingerprint and sixty-four "b"s for hash.
: B-RECORD ( str n ^ARENA:arena -- MODEL:hash-record )
   {: p:str m ar :}
   p DISPLAY p m ar LOCAL-HASH PRINT-OF 98 ar LETTER-HASH
   MODEL-HASH--RECORD:MAKE ;

: INCOMPLETE-LOCAL ( str -- MODEL:local-record )
   MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-LOCAL LOCAL-RECORD ;

\ The stored tree: the directory "d" over the file "d/x"; the files
\ "k", "r" and "t"; the directories "u" and "u-v" over the files "u/y"
\ and "u-v/z". Each file's hash is cached.
: MERGE-STORED ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" d" DIRECTORY-LOCAL obs LOCAL+
   s" d/x" 1 obs hashes ar CACHED+
   s" k" 2 obs hashes ar CACHED+
   s" r" 3 obs hashes ar CACHED+
   s" t" 4 obs hashes ar CACHED+
   s" u" DIRECTORY-LOCAL obs LOCAL+
   s" u-v" DIRECTORY-LOCAL obs LOCAL+
   s" u-v/z" 5 obs hashes ar CACHED+
   s" u/y" 6 obs hashes ar CACHED+
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE ;

\ The walk's file at the path, with the marker's fingerprint.
: WALKED-FILE ( scan str n ^ARENA:arena -- scan )
   {: p:str m ar :}
   p p m ar LOCAL-HASH PRINT-OF REUSE-CUTOFF SCAN-FILE ;

\ "d" is now a file, "k" is unchanged, "n" a new directory, "r" gone
\ and "t" touched; "u" and "u-v" changed while they were listed.
: MERGE-WALKED ( scan ^ARENA:arena -- scan )
   {: ar :}
   s" d" 7 ar WALKED-FILE
   s" k" 2 ar WALKED-FILE
   s" n" DIRECTORY-LOCAL SCAN-SEEN
   s" t" 8 ar WALKED-FILE
   s" u" INCOMPLETE-LOCAL SCAN-SEEN
   s" u-v" INCOMPLETE-LOCAL SCAN-SEEN ;

\ The job's file, its content sixty-four "b"s.
: MERGE-VISIT ( scan str MODEL:fingerprint ^ARENA:arena -- scan )
   {: p:str f ar :}
   p DISPLAY f 98 ar LETTER-HASH MODEL-HASH--RECORD:MAKE {: h :}
   h CACHED-FILE SCAN-OBSERVE  h SCAN-HASH ;

\ Jobs at "d" and "t"; gone "d/x", "r", "u/y" and "u-v/z", new "n",
\ unknown "u" and "u-v"; tombstones at "d/x", "r" and "t".
: MERGED ( scan local-root-binding ^ARENA:arena -- scan )
   {: b ar :}
   ar MERGE-WALKED
   WALK-ENDED SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 2 T= staged 7 T= hashes 3 T=
   [: ar MERGE-VISIT ;] EACH-SCAN-JOB
   b PUBLISH-SCAN TTRUE ;

\ The stored rows beneath "u" and "u-v" leave the inventory, and their
\ cached hashes stay.
: MERGE-PUBLISHED ( journal ^ARENA:arena -- )
   {: j ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" d" 7 ar B-RECORD {: dh :}  s" t" 8 ar B-RECORD {: th :}
   s" k" 2 ar LOCAL-HASH {: kh :}
   dh CACHED-FILE obs LOCAL+  kh CACHED-FILE obs LOCAL+
   s" n" DIRECTORY-LOCAL obs LOCAL+  th CACHED-FILE obs LOCAL+
   s" u" INCOMPLETE-LOCAL obs LOCAL+
   s" u-v" INCOMPLETE-LOCAL obs LOCAL+
   dh hashes HASH+  kh hashes HASH+  th hashes HASH+
   s" u-v/z" 5 ar LOCAL-HASH hashes HASH+
   s" u/y" 6 ar LOCAL-HASH hashes HASH+
   j ar LOCAL-INVENTORY obs LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE hashes HASH-RECORDS= TTRUE ;

: THE-SCAN-STAGES-ONLY-WHAT-DIFFERS ( ^ARENA:arena -- )
   {: ar :}
   s" the scan stages only what differs from the stored rows" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar MERGE-STORED
   j [: b ar MERGED ;] WITH-SCAN
   j ar MERGE-PUBLISHED
   j CLOSE
   d GONE ;

\ ---- the stored stream's bound

\ Files enough that their rows, two each, pass BATCH-BOUND more than
\ once.
600 constant MANY-FILES

\ The file left out of the second walk: "1400", read after the stream's
\ first reset.
400 constant LEFT-OUT

\ The n-th file's path: "1000" on, in byte order.
: MANY-PATH ( n ^ARENA:arena -- str )
   {: n ar :}
   n 1000 + FMT:INT$ ar ARENA:COPY ;

\ Each file with its hash cached.
: MANY-STORED ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   MANY-FILES 0 ?do i ar MANY-PATH i 1+ obs hashes ar CACHED+ loop
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE ;

\ The walk over each file unchanged but the skip-th, which it leaves
\ out; -1 leaves none out.
: MANY-WALKED ( scan n ^ARENA:arena -- scan )
   {: skip ar :}
   MANY-FILES 0 ?do
      i skip <> if i ar MANY-PATH i 1+ ar WALKED-FILE then
   loop
   WALK-ENDED ;

\ The unchanged walk stages nothing.
: NONE-STAGED ( scan ^ARENA:arena -- scan )
   {: ar :}
   -1 ar MANY-WALKED SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 0 T= hashes 0 T= ;

\ The walk without LEFT-OUT stages it, and only it, gone.
: ONE-GONE ( scan ^ARENA:arena -- scan )
   {: ar :}
   LEFT-OUT ar MANY-WALKED SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 1 T= hashes 1 T=
   SCAN-JOURNAL >CONNECTION {: c :}
   c s" SELECT COUNT(*) FROM temp.scan_observations
      WHERE CAST(path AS TEXT) = '1400' AND kind = 2" QUERY-INT 1 T=
   c s" SELECT COUNT(*) FROM temp.scan_hashes
      WHERE CAST(path AS TEXT) = '1400' AND content_hash IS NULL"
   QUERY-INT 1 T= ;

: A-STORED-STREAM-RESUMES-PAST-ITS-BOUND ( ^ARENA:arena -- )
   {: ar :}
   s" a stored stream resumes past its bound" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar MANY-STORED
   j [: ar NONE-STAGED ;] WITH-SCAN
   j [: ar ONE-GONE ;] WITH-SCAN
   j CLOSE
   d GONE ;

\ ---- skips and ranges

\ The stored tree: the directory "a" over the file "a/x", its hash
\ cached, and the file "a/y"; the files "a-b" and "b", hashes cached.
: SKIP-STORED ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a" DIRECTORY-LOCAL obs LOCAL+
   s" a-b" 1 obs hashes ar CACHED+
   s" a/x" 2 obs hashes ar CACHED+
   s" a/y" 3 ar LOCAL-HASH CACHED-FILE obs LOCAL+
   s" b" 4 obs hashes ar CACHED+
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE ;

\ The walk sees "a" and "a-b" unchanged, skips "a" at its subtree's
\ turn, then sees "b" become a directory: only "b" is staged, its hash
\ gone.
: SKIP-WALKED ( scan local-root-binding ^ARENA:arena -- scan )
   {: b ar :}
   s" a" DIRECTORY-LOCAL SCAN-SEEN
   s" a-b" 1 ar WALKED-FILE
   s" a" SCAN-SKIP
   s" b" DIRECTORY-LOCAL SCAN-SEEN
   WALK-ENDED SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 1 T= hashes 1 T=
   b PUBLISH-SCAN TTRUE ;

\ The rows beneath "a" and the hash at "a/x" stay.
: SKIP-PUBLISHED ( journal ^ARENA:arena -- )
   {: j ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a" DIRECTORY-LOCAL obs LOCAL+
   s" a-b" 1 obs hashes ar CACHED+
   s" a/x" 2 obs hashes ar CACHED+
   s" a/y" 3 ar LOCAL-HASH CACHED-FILE obs LOCAL+
   s" b" DIRECTORY-LOCAL obs LOCAL+
   j ar LOCAL-INVENTORY obs LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE hashes HASH-RECORDS= TTRUE ;

: A-SKIPPED-FOLDER-KEEPS-ITS-STORED-ROWS ( ^ARENA:arena -- )
   {: ar :}
   s" a skipped folder keeps its stored rows" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar SKIP-STORED
   j [: b ar SKIP-WALKED ;] WITH-SCAN
   j ar SKIP-PUBLISHED
   j CLOSE
   d GONE ;

\ The stored tree: the directory "a" over the file "a/x"; the files
\ "a-b" and "b". Each file's hash is cached.
: PASSED-STORED ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a" DIRECTORY-LOCAL obs LOCAL+
   s" a-b" 1 obs hashes ar CACHED+
   s" a/x" 2 obs hashes ar CACHED+
   s" b" 3 obs hashes ar CACHED+
   j b obs hashes PUBLISH-LOCAL-SCAN TTRUE ;

\ The walk sees "a", never "a-b", skips "a" at its subtree's turn, then
\ sees "b" unchanged: only "a-b" is staged gone, with its hash.
: PASSED-WALKED ( scan local-root-binding ^ARENA:arena -- scan )
   {: b ar :}
   s" a" DIRECTORY-LOCAL SCAN-SEEN
   s" a" SCAN-SKIP
   s" b" 3 ar WALKED-FILE
   WALK-ENDED SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 1 T= hashes 1 T=
   b PUBLISH-SCAN TTRUE ;

\ "a-b" and its hash are gone; "a/x" and its hash stay.
: PASSED-PUBLISHED ( journal ^ARENA:arena -- )
   {: j ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a" DIRECTORY-LOCAL obs LOCAL+
   s" a/x" 2 obs hashes ar CACHED+
   s" b" 3 obs hashes ar CACHED+
   j ar LOCAL-INVENTORY obs LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE hashes HASH-RECORDS= TTRUE ;

: A-SKIP-STAGES-GONE-WHAT-THE-WALK-PASSED-OVER ( ^ARENA:arena -- )
   {: ar :}
   s" a skip stages gone what the walk passed over" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar PASSED-STORED
   j [: b ar PASSED-WALKED ;] WITH-SCAN
   j ar PASSED-PUBLISHED
   j CLOSE
   d GONE ;

\ p, "/" and q, laid in ar.
: JOINED ( str str ^ARENA:arena -- str )
   {: p:str q:str ar :}
   p str> {: pa:^ pu:n :}  q str> {: qa:^ qu:n :}
   ar pu qu + 1+ ARENA:ALLOC drop {: dst:^ :}
   pa dst pu BYTE-COPY
   [char] / dst pu + c!
   qa dst pu + 1+ qu BYTE-COPY
   dst pu qu + 1+ >str ;

\ The folder f as stored, markers from m: the directories f and "f/w",
\ the files "f/w/k", "f/x", "f/y" and "f/z", their hashes cached.
: TREE-STORED+
   ( str n ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> ^ARENA:arena -- )
   {: f:str m obs hashes ar :}
   f DIRECTORY-LOCAL obs LOCAL+
   f s" w" ar JOINED DIRECTORY-LOCAL obs LOCAL+
   f s" w/k" ar JOINED m 1+ obs hashes ar CACHED+
   f s" x" ar JOINED m 2 + obs hashes ar CACHED+
   f s" y" ar JOINED m 3 + obs hashes ar CACHED+
   f s" z" ar JOINED m 4 + obs hashes ar CACHED+ ;

\ The folder f once its range is walked: "f/x" hashed again by its
\ visit, "f/y" gone, the rest as stored.
: TREE-WALKED+
   ( str n ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> ^ARENA:arena -- )
   {: f:str m obs hashes ar :}
   f DIRECTORY-LOCAL obs LOCAL+
   f s" w" ar JOINED DIRECTORY-LOCAL obs LOCAL+
   f s" w/k" ar JOINED m 1+ obs hashes ar CACHED+
   f s" x" ar JOINED m 9 + ar B-RECORD {: h :}
   h CACHED-FILE obs LOCAL+  h hashes HASH+
   f s" z" ar JOINED m 4 + obs hashes ar CACHED+ ;

\ The stored tree's rows: the file "a", the folder "d" from marker 10,
\ the file "e" and the folder "h" from marker 20.
: STORED-RANGES
   ( ^ARENA:arena
     -- ^VEC:vector<MODEL:local-record> ^VEC:vector<MODEL:hash-record> )
   {: ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a" 1 obs hashes ar CACHED+
   s" d" 10 obs hashes ar TREE-STORED+
   s" e" 2 obs hashes ar CACHED+
   s" h" 20 obs hashes ar TREE-STORED+
   obs hashes ;

\ Publishes the stored tree.
: RANGES-STORED ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   j b ar STORED-RANGES PUBLISH-LOCAL-SCAN TTRUE ;

\ The range of the folder f, markers from m: the walk sees "f/w" and
\ skips it at its subtree's turn, sees "f/x" changed and "f/z" as
\ stored, and misses "f/y".
: RANGE-WALKED ( scan str n ^ARENA:arena -- scan )
   {: f:str m ar :}
   f SCAN-FROM
   f s" w" ar JOINED {: w:str :}
   w DIRECTORY-LOCAL SCAN-SEEN
   w SCAN-SKIP
   f s" x" ar JOINED m 9 + ar WALKED-FILE
   f s" z" ar JOINED m 4 + ar WALKED-FILE
   f SCAN-TO ;

\ After n ranges the walk's end stages nothing more: a job at each
\ "f/x", each "f/y" gone and the hashes at both; the visits hash each
\ "f/x", then the scan is published.
: RANGES-PUBLISHED ( scan local-root-binding n ^ARENA:arena -- scan )
   {: b n ar :}
   WALK-ENDED SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs n T= staged n T= hashes n 2 * T=
   [: ar MERGE-VISIT ;] EACH-SCAN-JOB
   b PUBLISH-SCAN TTRUE ;

: ONE-RANGE ( scan local-root-binding ^ARENA:arena -- scan )
   {: b ar :}
   s" d" 10 ar RANGE-WALKED
   b 1 ar RANGES-PUBLISHED ;

: TWO-RANGES ( scan local-root-binding ^ARENA:arena -- scan )
   {: b ar :}
   s" d" 10 ar RANGE-WALKED
   s" h" 20 ar RANGE-WALKED
   b 2 ar RANGES-PUBLISHED ;

\ The published rows: "d" walked, and "h" walked when both holds, else
\ as stored; "a" and "e" as stored.
: RANGES-HELD ( journal bool ^ARENA:arena -- )
   {: j both:bool ar :}
   ar LOCALS {: obs :}  ar HASHES {: hashes :}
   s" a" 1 obs hashes ar CACHED+
   s" d" 10 obs hashes ar TREE-WALKED+
   s" e" 2 obs hashes ar CACHED+
   both if s" h" 20 obs hashes ar TREE-WALKED+
   else s" h" 20 obs hashes ar TREE-STORED+ then
   j ar LOCAL-INVENTORY obs LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE hashes HASH-RECORDS= TTRUE ;

: A-RANGE-MERGES-ONLY-BENEATH-ITS-FOLDER ( ^ARENA:arena -- )
   {: ar :}
   s" a range merges only beneath its folder" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar RANGES-STORED
   j [: b ar ONE-RANGE ;] WITH-SCAN
   j false ar RANGES-HELD
   j CLOSE
   d GONE ;

: TWO-RANGES-IN-ONE-SCAN-MERGE-EACH-FOLDER ( ^ARENA:arena -- )
   {: ar :}
   s" two ranges in one scan merge each folder" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar RANGES-STORED
   j [: b ar TWO-RANGES ;] WITH-SCAN
   j true ar RANGES-HELD
   j CLOSE
   d GONE ;

\ ---- the reuse table

\ Inode 7 and size 8, modified then changed at the times given.
: TIMES-PRINT ( n n n n -- MODEL:fingerprint )
   {: ms mn cs cn :}
   7 8 ms mn cs cn MODEL-FINGERPRINT:MAKE ;

\ The cache's fingerprint at "f" in most rows of the reuse table.
: BASE-PRINT ( -- MODEL:fingerprint ) 50 5 60 6 TIMES-PRINT ;

\ BASE-PRINT with field k, 0 the inode to 5 the changed nanoseconds,
\ one more.
: SHIFTED ( n -- MODEL:fingerprint )
   {: k :}
   BASE-PRINT MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   k 0 = if i 1+ else i then  k 1 = if s 1+ else s then
   k 2 = if ms 1+ else ms then  k 3 = if mn 1+ else mn then
   k 4 = if cs 1+ else cs then  k 5 = if cn 1+ else cn then
   MODEL-FINGERPRINT:MAKE ;

\ Publishes the fingerprint as the cache's only record, at "f".
: CACHE-HOLDS ( MODEL:fingerprint ^ARENA:arena -- )
   {: f ar :}
   s" f" DISPLAY f ar A-HASH MODEL-HASH--RECORD:MAKE {: r :}
   THE-JOURNAL @ THE-BINDING @ ar LOCALS r ar ONE-HASH
   PUBLISH-LOCAL-SCAN TTRUE ;

: FLAG-COUNT ( bool -- n ) if 1 else 0 then ;

\ The file at "f" with the fingerprint, walked under o, is a job unless
\ reused holds.
: ROW-WALKED
   ( scan MODEL:fingerprint option<MODEL:cutoff> bool -- scan )
   {: f o:option<MODEL:cutoff> reused:bool :}
   s" f" f o SCAN-FILE
   0 ROWS-SEEN !  [: JOB-COUNTED ;] EACH-SCAN-JOB
   ROWS-SEEN @ reused 0= FLAG-COUNT T= ;

\ A scan walking "f" with the fingerprint under o.
: WALKS ( MODEL:fingerprint option<MODEL:cutoff> bool -- )
   {: f o:option<MODEL:cutoff> reused:bool :}
   THE-JOURNAL @ [: f o reused ROW-WALKED ;] WITH-SCAN ;

\ The cache and the walk share the fingerprint.
: SAME-ROW
   ( MODEL:fingerprint option<MODEL:cutoff> bool ^ARENA:arena -- )
   {: f o:option<MODEL:cutoff> reused:bool ar :}
   f ar CACHE-HOLDS f o reused WALKS ;

\ The walk's fingerprint differs from the cache's in field k.
: SHIFTED-ROW ( n ^ARENA:arena -- )
   {: k ar :}
   BASE-PRINT ar CACHE-HOLDS k SHIFTED REUSE-CUTOFF false WALKS ;

\ The cache's record at "f" is another generation's.
: GENERATION-ROW ( ^ARENA:arena -- )
   {: ar :}
   BASE-PRINT ar CACHE-HOLDS
   THE-JOURNAL @ >CONNECTION
   s" UPDATE local_hash_cache SET root_generation = root_generation + 1"
   SQLITE:EXEC
   BASE-PRINT REUSE-CUTOFF false WALKS ;

\ Each row: the fingerprint the cache and the walk share, the cutoff
\ and whether the hash is reused; then a field apart, another
\ generation.
: SCAN-FILE-REUSES-ONLY-REUSABLE-HASHES ( ^ARENA:arena -- )
   {: ar :}
   s" SCAN-FILE reuses only reusable hashes" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL THE-BINDING ! THE-JOURNAL !
   50 5 60 6 TIMES-PRINT REUSE-CUTOFF true ar SAME-ROW
   100 499 60 6 TIMES-PRINT REUSE-CUTOFF true ar SAME-ROW
   100 500 60 6 TIMES-PRINT REUSE-CUTOFF false ar SAME-ROW
   50 5 100 499 TIMES-PRINT REUSE-CUTOFF true ar SAME-ROW
   50 5 100 500 TIMES-PRINT REUSE-CUTOFF false ar SAME-ROW
   50 1000000000 60 6 TIMES-PRINT REUSE-CUTOFF false ar SAME-ROW
   50 -1 60 6 TIMES-PRINT REUSE-CUTOFF false ar SAME-ROW
   50 5 60 1000000000 TIMES-PRINT REUSE-CUTOFF false ar SAME-ROW
   50 5 60 -1 TIMES-PRINT REUSE-CUTOFF false ar SAME-ROW
   50 5 60 6 TIMES-PRINT NO-CUTOFF false ar SAME-ROW
   6 0 ?do i ar SHIFTED-ROW loop
   ar GENERATION-ROW
   THE-JOURNAL @ CLOSE
   d GONE ;

\ Another connection takes the journal at SUBJECT for writing, waiting
\ for no lock, and lets it go.
: EXCLUSIVE ( -- )
   SUBJECT @ SQLITE:OPEN {: c :}
   [: c s" BEGIN EXCLUSIVE; COMMIT" SQLITE:EXEC ;] [: c SQLITE:CLOSE ;]
   finally ;

\ THE-JOURNAL's connection opens and ends a transaction of its own,
\ which it cannot while one is open.
: NONE-OPEN ( -- )
   THE-JOURNAL @ >CONNECTION s" BEGIN IMMEDIATE; COMMIT" SQLITE:EXEC ;

\ Publishes hashes at "a" and "b", which the walk's stream reads.
: STORED-AB ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   ar HASHES {: v :}
   s" a" 2 ar LOCAL-HASH v HASH+  s" b" 3 ar LOCAL-HASH v HASH+
   j b ar LOCALS v PUBLISH-LOCAL-SCAN TTRUE ;

\ The walk at "a" leaves the stream standing on "b"; the body throws.
: THROWN-SCAN ( scan -- scan )
   s" a" 1 MARKED-FINGERPRINT REUSE-CUTOFF SCAN-FILE
   E-INVALID-STATE throw ;

: A-THROW-OUT-OF-WITH-SCAN-LEAVES-NO-TRANSACTION-OPEN ( ^ARENA:arena -- )
   {: ar :}
   s" a throw out of WITH-SCAN leaves no transaction open" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   p SUBJECT !  j THE-JOURNAL !
   j b ar STORED-AB
   [: j [: THROWN-SCAN ;] WITH-SCAN ;] E-INVALID-STATE TTHROWSQ
   [: NONE-OPEN ;] d ar SILENT
   [: EXCLUSIVE ;] d ar SILENT
   j CLOSE
   d GONE ;

\ The job's visit writes the scan, then another connection takes the
\ journal.
: UNLOCKED-VISIT
   ( scan str MODEL:fingerprint MODEL:hash-record str ^ARENA:arena
     -- scan )
   {: p:str f h d:str ar :}
   h SCAN-HASH
   [: EXCLUSIVE ;] d ar SILENT ;

\ The walk at "a" leaves the stream standing on "b" before the one
\ job's visit.
: VISITED-UNLOCKED ( scan str ^ARENA:arena -- scan )
   {: d:str ar :}
   s" a.txt" 10 ar LOCAL-HASH {: h :}
   s" a" 1 MARKED-FINGERPRINT REUSE-CUTOFF SCAN-FILE
   [: h d ar UNLOCKED-VISIT ;] EACH-SCAN-JOB ;

: A-VISIT-HOLDS-NO-LOCK-OF-THE-SCAN-BEFORE-IT ( ^ARENA:arena -- )
   {: ar :}
   s" a visit holds no lock of the scan before it" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   p SUBJECT !
   j b ar STORED-AB
   j [: d ar VISITED-UNLOCKED ;] WITH-SCAN
   j CLOSE
   d GONE ;

\ Sets the most pages the connection's temporary database holds; SQLite
\ raises n below the database's size to its size.
: TEMP-CAPPED ( SQLITE:connection n -- )
   {: c n :}
   s" PRAGMA temp.max_page_count = " 0 PUT  n swap PUT-N {: u :}
   c 0 u WANT-PART SQLITE:EXEC ;

\ Jobs at new paths, in byte order, fill the scan's temporary database,
\ capped at its size, until a write fails.
: FILLED-SCAN ( scan -- scan )
   SCAN-JOURNAL >CONNECTION 1 TEMP-CAPPED
   100000 0 ?do
      i 1000000 + FMT:INT$ 1 MARKED-FINGERPRINT NO-CUTOFF SCAN-FILE
   loop ;

: FULL-SCAN ( -- ) THE-JOURNAL @ [: FILLED-SCAN ;] WITH-SCAN ;

: A-FULL-SCAN-LEAVES-THE-NEXT-SCAN-WHOLE ( ^ARENA:arena -- )
   {: ar :}
   s" a full scan leaves the next scan whole" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j THE-JOURNAL !
   j >CONNECTION s" PRAGMA temp.max_page_count" QUERY-INT {: most :}
   [: FULL-SCAN ;] SQLITE:E-FULL d s" database or disk is full" ar LOGGED
   j >CONNECTION most TEMP-CAPPED
   s" a.txt" s" a" PRESENT-LOCAL LOCAL-RECORD {: r :}
   s" a.txt" 10 ar LOCAL-HASH {: h :}
   j b r ar ONE-LOCAL h ar ONE-HASH PUBLISH-LOCAL-SCAN TTRUE
   j ar LOCAL-INVENTORY r ar ONE-LOCAL LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE h ar ONE-HASH HASH-RECORDS= TTRUE
   j CLOSE
   d GONE ;


\ ---- watched folders ---------------------------------------------

: STIRRED-AT? ( option<stirred> n str -- bool )
   {: n p:str :}
   MATCH option
      none OF false ENDOF
      some OF
         JOURNAL-STIRRED:UNMAKE {: wd q:str :}
         wd n = q p STR:= and
      ENDOF
   ;MATCH ;

: NONE-STIRRED? ( option<stirred> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: WATCH-COUNT ( journal -- n )
   >CONNECTION s" SELECT COUNT(*) FROM temp.watches" QUERY-INT ;

: MARK-1 ( journal -- n )
   >CONNECTION s" SELECT mark FROM temp.watches WHERE wd = 1" QUERY-INT ;

\ Stores the folders a and b as directories, as their parent's listing
\ does.
: FOLDERS-STORED ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   ar LOCALS {: v :}
   s" a" DIRECTORY-LOCAL v LOCAL+  s" b" DIRECTORY-LOCAL v LOCAL+
   j b v ar HASHES PUBLISH-LOCAL-SCAN TTRUE ;

\ Lists wd 1's folder and publishes the scan, its stream stopped so the
\ stored rows stay.
: LISTED-PUBLISHED ( scan journal local-root-binding -- scan )
   {: j b :}
   SCAN-STOP  j 1 WATCH-LISTED  b PUBLISH-SCAN TTRUE ;

: A-PUBLISHED-LISTED-FOLDER-IS-CLEAN ( ^ARENA:arena -- )
   {: ar :}
   s" a recorded, listed and published folder is clean" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar FOLDERS-STORED
   j 1 s" a" WATCH-RECORD
   j 1 s" a" WATCH-CLEAN? TFALSE
   j [: j b LISTED-PUBLISHED ;] WITH-SCAN
   j 1 s" a" WATCH-CLEAN? TTRUE
   j 1 s" b" WATCH-CLEAN? TFALSE
   j 2 s" a" WATCH-CLEAN? TFALSE
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j CLOSE
   d GONE ;

\ Lists wd 1's folder, then the body throws.
: LISTED-THROWN ( scan journal -- scan )
   1 WATCH-LISTED  E-INVALID-STATE throw ;

: AN-UNPUBLISHED-SCAN-STIRS-WHAT-IT-LISTED ( ^ARENA:arena -- )
   {: ar :}
   s" a scan that ends unpublished stirs what it listed" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j 1 s" a" WATCH-RECORD
   j [: j b LISTED-PUBLISHED ;] WITH-SCAN
   j [: j 1 WATCH-LISTED ;] WITH-SCAN
   j ar NEXT-STIRRED 1 s" a" STIRRED-AT? TTRUE
   j [: j b LISTED-PUBLISHED ;] WITH-SCAN
   [: j [: j LISTED-THROWN ;] WITH-SCAN ;] E-INVALID-STATE TTHROWSQ
   j ar NEXT-STIRRED 1 s" a" STIRRED-AT? TTRUE
   j CLOSE
   d GONE ;

\ Lists wd 1's folder; publishing for a root that is not active leaves
\ it listed.
: LISTED-STALE ( scan journal ^ARENA:arena -- scan )
   {: j ar :}
   j 1 WATCH-LISTED
   s" /stale" 4 LOCAL-ROOT PUBLISH-SCAN TFALSE
   j MARK-1 2 T=
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE ;

: A-REFUSED-PUBLICATION-LEAVES-THE-MARKS ( ^ARENA:arena -- )
   {: ar :}
   s" a refused publication leaves the marks" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j 1 s" a" WATCH-RECORD
   j [: j ar LISTED-STALE ;] WITH-SCAN
   j MARK-1 1 T=
   j ar NEXT-STIRRED 1 s" a" STIRRED-AT? TTRUE
   j CLOSE
   d GONE ;

\ Lists every folder and publishes the scan, its stream stopped.
: ALL-PUBLISHED ( scan journal local-root-binding -- scan )
   {: j b :}
   SCAN-STOP  j 1 WATCH-LISTED  j 2 WATCH-LISTED  j 3 WATCH-LISTED
   b PUBLISH-SCAN TTRUE ;

\ Stirs a/x, then a-b, then lists them in the order NEXT-STIRRED
\ answers them, a-b stirred again once listed.
: STIRS-LISTED ( scan journal ^ARENA:arena -- scan )
   {: j ar :}
   j 1 WATCH-STIR TTRUE
   j ar NEXT-STIRRED 1 s" a/x" STIRRED-AT? TTRUE
   j 2 WATCH-STIR TTRUE
   j ar NEXT-STIRRED 2 s" a-b" STIRRED-AT? TTRUE
   j 2 WATCH-LISTED
   j ar NEXT-STIRRED 1 s" a/x" STIRRED-AT? TTRUE
   j 2 WATCH-STIR TTRUE
   j ar NEXT-STIRRED 2 s" a-b" STIRRED-AT? TTRUE
   j 2 WATCH-LISTED
   j 1 WATCH-LISTED
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE ;

: NEXT-STIRRED-ANSWERS-IN-PATH-ORDER ( ^ARENA:arena -- )
   {: ar :}
   s" NEXT-STIRRED answers stirred folders in path order" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j 1 s" a/x" WATCH-RECORD
   j 2 s" a-b" WATCH-RECORD
   j 3 s" a" WATCH-RECORD
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j 1 WATCH-STIR TTRUE  j 2 WATCH-STIR TTRUE  j 3 WATCH-STIR TTRUE
   j ar NEXT-STIRRED 3 s" a" STIRRED-AT? TTRUE
   j [: j b ALL-PUBLISHED ;] WITH-SCAN
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j [: j ar STIRS-LISTED ;] WITH-SCAN
   j ar NEXT-STIRRED 2 s" a-b" STIRRED-AT? TTRUE
   j CLOSE
   d GONE ;

: WATCH-RECORDS-ARE-REPLACED-AND-FORGOTTEN ( ^ARENA:arena -- )
   {: ar :}
   s" watch records are replaced, stirred and forgotten" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar FOLDERS-STORED
   j 1 s" a" WATCH-RECORD
   j 2 s" b" WATCH-RECORD
   j [: j b ALL-PUBLISHED ;] WITH-SCAN
   j 9 WATCH-STIR TFALSE
   j WATCH-COUNT 2 T=
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j 1 s" c" WATCH-RECORD
   j WATCH-COUNT 2 T=
   j 1 s" a" WATCH-CLEAN? TFALSE
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j 1 WATCH-STIR TTRUE
   j ar NEXT-STIRRED 1 s" c" STIRRED-AT? TTRUE
   j 1 WATCH-FORGET
   j WATCH-COUNT 1 T=
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j 2 s" b" WATCH-CLEAN? TTRUE
   j 3 s" " WATCH-RECORD
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j 3 WATCH-STIR TTRUE
   j ar NEXT-STIRRED 3 s" " STIRRED-AT? TTRUE
   j WATCHES-RESET
   j WATCH-COUNT 0 T=
   j 2 s" b" WATCH-CLEAN? TFALSE
   j CLOSE
   d GONE ;

\ Tries wd 1's folder, lists wd 2's and publishes the scan, its stream
\ stopped.
: TRIED-PUBLISHED ( scan journal local-root-binding -- scan )
   {: j b :}
   SCAN-STOP  j 1 WATCH-TRIED  j 2 WATCH-LISTED  b PUBLISH-SCAN TTRUE ;

\ Tries wd 2's folder, then the body throws.
: TRIED-THROWN ( scan journal -- scan )
   2 WATCH-TRIED  E-INVALID-STATE throw ;

: A-TRIED-FOLDER-IS-STIRRED-AFTER-ITS-SCAN ( ^ARENA:arena -- )
   {: ar :}
   s" a tried folder is stirred after its scan" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar FOLDERS-STORED
   j 1 s" a" WATCH-RECORD
   j 2 s" b" WATCH-RECORD
   j [: j b ALL-PUBLISHED ;] WITH-SCAN
   j [: j b TRIED-PUBLISHED ;] WITH-SCAN
   j ar NEXT-STIRRED 1 s" a" STIRRED-AT? TTRUE
   j 2 s" b" WATCH-CLEAN? TTRUE
   [: j [: j TRIED-THROWN ;] WITH-SCAN ;] E-INVALID-STATE TTHROWSQ
   j ar NEXT-STIRRED 1 s" a" STIRRED-AT? TTRUE
   j [: j b LISTED-PUBLISHED ;] WITH-SCAN
   j ar NEXT-STIRRED 2 s" b" STIRRED-AT? TTRUE
   j CLOSE
   d GONE ;

\ Walks the root's range seeing and skipping "h" alone, so "d" and the
\ rows beneath it are staged gone, then publishes the scan.
: H-ALONE-PUBLISHED ( scan local-root-binding -- scan )
   {: b :}
   SCAN-STOP  s" " SCAN-FROM
   s" h" DIRECTORY-LOCAL SCAN-SEEN  s" h" SCAN-SKIP
   s" d" SCAN-STAGED? TTRUE  s" h" SCAN-STAGED? TFALSE
   s" " SCAN-TO  b PUBLISH-SCAN TTRUE ;

: A-PUBLISHED-SCAN-FORGETS-THE-RECORDS-OF-FOLDERS-IT-DROPS
   ( ^ARENA:arena -- )
   {: ar :}
   s" a published scan forgets the records of folders it drops" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j 1 s" d" WATCH-RECORD
   j 2 s" h" WATCH-RECORD
   j [: j b ALL-PUBLISHED ;] WITH-SCAN
   j b ar RANGES-STORED
   j [: b H-ALONE-PUBLISHED ;] WITH-SCAN
   j 1 s" d" WATCH-CLEAN? TFALSE
   j 2 s" h" WATCH-CLEAN? TTRUE
   j ar NEXT-STIRRED NONE-STIRRED? TTRUE
   j CLOSE
   d GONE ;

\ Stops the stream and publishes the scan, which writes nothing.
: STOPPED-PUBLISHED ( scan journal local-root-binding -- scan )
   {: j b :}
   SCAN-STOP
   j TOTAL-CHANGES {: before :}
   b PUBLISH-SCAN TTRUE
   j TOTAL-CHANGES before T= ;

\ Stops the stream, then walks and publishes the range of "d".
: STOPPED-RANGE ( scan local-root-binding ^ARENA:arena -- scan )
   {: b ar :}
   SCAN-STOP  b ar ONE-RANGE ;

: A-STOPPED-SCAN-PUBLISHES-NOTHING ( ^ARENA:arena -- )
   {: ar :}
   s" a stopped scan publishes nothing" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p ar ACTIVE-JOURNAL {: j b :}
   j b ar RANGES-STORED
   j [: j b STOPPED-PUBLISHED ;] WITH-SCAN
   ar STORED-RANGES {: obs hashes :}
   j ar LOCAL-INVENTORY obs LOCAL-RECORDS= TTRUE
   j ar LOCAL-HASH-CACHE hashes HASH-RECORDS= TTRUE
   j [: b ar STOPPED-RANGE ;] WITH-SCAN
   j false ar RANGES-HELD
   j CLOSE
   d GONE ;

\ The piece of p from at joins v as a directory; the index after it,
\ or -1 past the last.
: SCAN-PIECE ( str n ^VEC:vector<MODEL:local-record> -- n )
   {: p:str at:n v :}
   p 32 at STR:SPLIT-NEXT 0= if 2drop -1 exit then
   {: q:str next:n :}
   q DIRECTORY-LOCAL v LOCAL+ next ;

\ The local inventory is directories at the paths p names, in its
\ order and apart by spaces, with no hashes.
: LOCAL-SCAN ( journal local-root-binding str ^ARENA:arena -- )
   {: j b p:str ar :}
   ar LOCALS {: v :}
   0 begin p swap v SCAN-PIECE dup 0< until drop
   j b v ar HASHES PUBLISH-LOCAL-SCAN TTRUE ;

\ Each record's path then a space, and "|" after the key's last.
: VISIT-PUT ( ^VEC:vector<MODEL:local-record> -- )
   {: v :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ MODEL-LOCAL--RECORD:UNMAKE drop MODEL:PATH>STR SB-APPEND
      s"  " SB-APPEND
   loop
   s" |" SB-APPEND ;

: VISIT-ON ( ^VEC:vector<MODEL:local-record> -- bool ) VISIT-PUT false ;
: VISIT-ONCE ( ^VEC:vector<MODEL:local-record> -- bool ) VISIT-PUT true ;

\ VISIT-PUT's text of the keys EACH-LOCAL-COLLISION visits with v.
: VISITS
   ( journal [ ^VEC:vector<MODEL:local-record> -- bool ] ^ARENA:arena
     -- str )
   {: j v ar :}
   SB-RESET j ar v EACH-LOCAL-COLLISION SB$ ar ARENA:COPY ;

: KEY-BEFORE? ( str str ^ARENA:arena -- bool )
   {: a:str b:str ar :}
   a ar CANONICAL b ar CANONICAL MODEL:KEY-CMP 0< ;

: COLLISIONS-VISITED ( journal local-root-binding ^ARENA:arena -- )
   {: j b ar :}
   j b s" b.txt a.txt" ar LOCAL-SCAN
   j [: VISIT-ON ;] ar VISITS s" " T$=
   s" z.txt" s\" \xC3\xA9.txt" ar KEY-BEFORE? TTRUE
   j b s\" \xC3\xA9.txt z.txt solo.txt \xC3\x89.txt Z.txt" ar LOCAL-SCAN
   j [: VISIT-ON ;] ar VISITS
   s\" Z.txt z.txt |\xC3\x89.txt \xC3\xA9.txt |" T$=
   s" note" s" notes" ar KEY-BEFORE? TTRUE
   j b s" notes Note solo Notes note" ar LOCAL-SCAN
   j [: VISIT-ON ;] ar VISITS s" Note note |Notes notes |" T$=
   j [: VISIT-ONCE ;] ar VISITS s" Note note |" T$= ;

\ Only keys several rows hold, in MODEL:KEY-CMP's order: 0x80 after 0x7A,
\ a prefix first; each key's records in path order; true stops the visit.
: EACH-LOCAL-COLLISION-VISITS-IN-KEY-ORDER ( ^ARENA:arena -- )
   {: ar :}
   s" each local collision visits in key order" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" /sync" 2 LOCAL-ROOT {: b :}
   j b ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j b ar COLLISIONS-VISITED
   j CLOSE
   d GONE ;

: LOCAL-AT$ ( journal str ^ARENA:arena -- str )
   {: j k:str ar :}
   j k ar CANONICAL ar LOCAL-AT MATCH option
      none OF s" (none)" ENDOF
      some OF MODEL-LOCAL--RECORD:UNMAKE drop MODEL:PATH>STR ENDOF
   ;MATCH ;

\ LOCAL-COUNT counts the local rows; LOCAL-AT answers a key's least
\ path, none where no row holds it.
: LOCAL-COUNT-AND-LOCAL-AT ( ^ARENA:arena -- )
   {: ar :}
   s" local count and local at" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   s" /sync" 2 LOCAL-ROOT {: b :}
   j b ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j LOCAL-COUNT 0 T=
   j s" a.txt" ar LOCAL-AT$ s" (none)" T$=
   j b s" b.txt a.txt A.txt" ar LOCAL-SCAN
   j LOCAL-COUNT 3 T=
   j s" a.txt" ar LOCAL-AT$ s" A.txt" T$=
   j s" b.txt" ar LOCAL-AT$ s" b.txt" T$=
   j s" c.txt" ar LOCAL-AT$ s" (none)" T$=
   j CLOSE
   d GONE ;

\ A row of each family at its own key, every value a directory, each
\ canonical path as MODEL:FOLD gives it.
: KNOWN-FIXTURE ( -- str )
   s\" INSERT INTO baselines(path, canonical_path, kind)
         VALUES (CAST('Base' AS BLOB), CAST('base' AS BLOB), 1);
      INSERT INTO local_observations(path, canonical_path, kind)
         SELECT CAST(column1 AS BLOB), CAST(column2 AS BLOB), 1
         FROM (VALUES ('local', 'local'), ('pair', 'pair'),
            ('Pair', 'pair'));
      INSERT INTO remote_observations(path, canonical_path, kind)
         SELECT CAST(column1 AS BLOB), CAST(column2 AS BLOB), 1
         FROM (VALUES ('A', 'a'), ('a/b', 'a/b'), ('a.txt', 'a.txt'),
            ('dir/file', 'dir/file'));
      INSERT INTO plans(id, path, canonical_path, status,
            blocked_json, retry_at)
         SELECT column1, CAST(column2 AS BLOB), CAST(column2 AS BLOB),
            column3, column4, column5
         FROM (VALUES (1, 'live', 'pending', NULL, NULL),
            (2, 'blocked', 'blocked', '{}', 0),
            (3, 'done', 'completed', NULL, NULL));" ;

: NONE-PUT ( -- ) s" - " SB-APPEND ;

\ The path then a space, "?" before it where the value is not the
\ fixture's directory.
: HELD-PUT ( MODEL:path bool -- )
   0= if s" ?" SB-APPEND then
   MODEL:PATH>STR SB-APPEND s"  " SB-APPEND ;

: KNOWN-BASELINE-PUT ( option<path-baseline> -- )
   MATCH option
      none OF NONE-PUT ENDOF
      some OF
         JOURNAL-PATH--BASELINE:UNMAKE
         MODEL-BASELINE:DIRECTORY MODEL:BASELINE= HELD-PUT
      ENDOF
   ;MATCH ;

: KNOWN-LOCAL-PUT ( option<MODEL:local-record> -- )
   MATCH option
      none OF NONE-PUT ENDOF
      some OF
         MODEL-LOCAL--RECORD:UNMAKE
         LOCAL-DIRECTORY MODEL:LOCAL-OBSERVATION= HELD-PUT
      ENDOF
   ;MATCH ;

\ The record's path, and whether it holds the key and a directory.
: REMOTE-HELD? ( MODEL:remote-record MODEL:key -- MODEL:path bool )
   {: k :}
   MODEL-REMOTE--RECORD:UNMAKE {: rk p o :}
   p rk k MODEL:KEY=
   o REMOTE-DIRECTORY MODEL:REMOTE-OBSERVATION= and ;

: KNOWN-REMOTE-PUT ( option<MODEL:remote-record> MODEL:key -- )
   {: k :}
   MATCH option
      none OF NONE-PUT ENDOF
      some OF k REMOTE-HELD? HELD-PUT ENDOF
   ;MATCH ;

: SUBTREE-PUT ( MODEL:subtree -- )
   MATCH MODEL:subtree
      empty OF s" empty " ENDOF
      occupied OF s" occupied " ENDOF
   ;MATCH SB-APPEND ;

: LIVE-PUT ( bool -- ) if s" live|" else s" -|" then SB-APPEND ;

\ The key, baseline, local, locals, remote, subtree and live fields,
\ apart by spaces, "-" for none, then "|".
: KNOWN-PUT ( known-path -- )
   JOURNAL-KNOWN--PATH:UNMAKE {: k b l n r t live:bool :}
   k MODEL:KEY>STR SB-APPEND s"  " SB-APPEND
   b KNOWN-BASELINE-PUT l KNOWN-LOCAL-PUT
   n FMT:INT$ SB-APPEND s"  " SB-APPEND
   r k KNOWN-REMOTE-PUT t SUBTREE-PUT live LIVE-PUT ;

\ KNOWN-PUT's text of the keys EACH-UNSETTLED-PATH visits in ar; the
\ fixture settles no key.
: KNOWN-VISITS ( journal ^ARENA:arena -- str )
   {: j ar :}
   SB-RESET j ar [: KNOWN-PUT ;] EACH-UNSETTLED-PATH 0 T= SB$ ;

: KNOWN-AT$ ( journal str ^ARENA:arena -- str )
   {: j k:str ar :}
   SB-RESET j k ar CANONICAL ar KNOWN-PATH-AT KNOWN-PUT
   SB$ ar ARENA:COPY ;

\ The fixture's keys in byte order: "a.txt" before "a/b" ('.' before
\ '/'), and not the completed plan.
: KNOWN-WANT ( ^ARENA:arena -- str )
   {: ar :}
   SB-RESET
   s" a - - 0 A occupied -|" SB-APPEND
   s" a.txt - - 0 a.txt empty -|" SB-APPEND
   s" a/b - - 0 a/b empty -|" SB-APPEND
   s" base Base - 0 - empty -|" SB-APPEND
   s" blocked - - 0 - empty live|" SB-APPEND
   s" dir/file - - 0 dir/file empty -|" SB-APPEND
   s" live - - 0 - empty live|" SB-APPEND
   s" local - local 1 - empty -|" SB-APPEND
   s" pair - Pair 2 - empty -|" SB-APPEND
   SB$ ar ARENA:COPY ;

\ Each held key once, in byte order, with its least local path; at one
\ key the same, and only the subtree where nothing holds the key.
: KNOWN-PATHS-ARE-READ-ROW-BY-ROW ( ^ARENA:arena -- )
   {: ar :}
   s" known paths are read row by row" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j >CONNECTION KNOWN-FIXTURE SQLITE:EXEC
   ar KNOWN-WANT {: w:str :}
   j [: KNOWN-VISITS ;] ARENA:WITH ar ARENA:COPY w T$=
   j s" Pair" ar KNOWN-AT$ s" pair - Pair 2 - empty -|" T$=
   j s" a" ar KNOWN-AT$ s" a - - 0 A occupied -|" T$=
   j s" gone" ar KNOWN-AT$ s" gone - - 0 - empty -|" T$=
   j s" dir" ar KNOWN-AT$ s" dir - - 0 - occupied -|" T$=
   j CLOSE
   d GONE ;

\ A remote directory at the path, keyed by its fold.
: REMOTE-DIRECTORY+
   ( ^VEC:vector<MODEL:remote-record> str ^ARENA:arena -- )
   {: v p:str ar :}
   p p REMOTE-DIRECTORY ar REMOTE-RECORD v REMOTE+ ;

\ report.txt sorts between report and its children; repo0 is the upper
\ bound of repo's subtree; deep/FF is the last child deep can hold.
: DESCENDANTS ( ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: ar :}
   ar REMOTES {: v :}
   v s" Report" ar REMOTE-DIRECTORY+
   v s" report.txt" ar REMOTE-DIRECTORY+
   v s" repo0" ar REMOTE-DIRECTORY+
   v s" Report/x" ar REMOTE-DIRECTORY+
   v s" reports/y" ar REMOTE-DIRECTORY+
   v s\" deep/\xFF" ar REMOTE-DIRECTORY+
   v ;

\ SUBTREE-PUT's text of the subtree KNOWN-PATH-AT answers at the path.
: SUBTREE-AT ( journal str ^ARENA:arena -- str )
   {: j p:str ar :}
   j p ar CANONICAL ar KNOWN-PATH-AT
   JOURNAL-KNOWN--PATH:UNMAKE {: k b l n r t live:bool :}
   SB-RESET t SUBTREE-PUT SB$ ;

: SUBTREE-HOLDS-ONLY-TRUE-DESCENDANTS ( ^ARENA:arena -- )
   {: ar :}
   s" remote_subtree_holds_only_true_descendants" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" cursor" CURSOR ar DESCENDANTS ar DELTA
   PUBLISH-REMOTE-INVENTORY
   j s" report" ar SUBTREE-AT s" occupied " T$=
   j s" reports" ar SUBTREE-AT s" occupied " T$=
   j s" deep" ar SUBTREE-AT s" occupied " T$=
   j s" report.txt" ar SUBTREE-AT s" empty " T$=
   j s" report/x" ar SUBTREE-AT s" empty " T$=
   j s" repo" ar SUBTREE-AT s" empty " T$=
   j s" other" ar SUBTREE-AT s" empty " T$=
   j CLOSE
   d GONE ;


\ ---- baselines and plans -----------------------------------------

TYPED-VARIABLE HELD-JOURNAL journal
TYPED-VARIABLE HELD-ARENA ^ARENA:arena
TYPED-VARIABLE NOOPS ^VEC:vector<path-baseline>
TYPED-VARIABLE PLANS ^VEC:vector<path-plan>
TYPED-VARIABLE FINALS ^VEC:vector<operation-baseline>

: PATH= ( MODEL:path MODEL:path -- bool )
   {: a b :} a MODEL:PATH>STR b MODEL:PATH>STR STR:= ;

\ The planner's decisions for the Rust tests' plan() calls, built here
\ as src/oracle/plan.tsv holds them. An upload: a new local file, no
\ remote one, no baseline.
: UPLOAD-DECISION ( str -- MODEL:decision )
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

: TEST-PATH ( -- str ) s" test" ;

: ONE-PLAN ( MODEL:operation ^ARENA:arena -- operation-plan )
   {: o ar :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   o ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

: NOT-OPERATIONS ( -- )
   s" extract test operation plan" TEST-PATH
   s" test expected planner operations" INVALID ;

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
   s" extract test no-op" TEST-PATH
   s" test expected a planner no-op" INVALID ;

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
         drop s" extract recorded test plan" TEST-PATH
         s" test expected a newly recorded plan" INVALID
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
: TWO-PATHS? ( ^VEC:vector<MODEL:path> str str -- bool )
   {: v a:str b:str :}
   v VEC:COUNT 2 <> if false exit then
   v 0 VEC:AT @ a DISPLAY PATH=
   v 1 VEC:AT @ b DISPLAY PATH= and ;

: ROWS-AT ( journal MODEL:path -- n )
   {: j path :}
   j >CONNECTION s" SELECT COUNT(*) FROM baselines WHERE path = ?1" [: path MODEL:PATH>STR 1 SQLITE:BIND-BLOB INT-ROW ;]
   SQLITE:WITH-STATEMENT ;

: AGREE ( journal str str str ^ARENA:arena -- )
   {: j p:str c:str r:str ar :}
   j p DISPLAY c r REMOTE-FILE MATCH-DECISION NOOP ar
   RECORD-NOOP drop ;

: DIRECTORY ( journal str ^ARENA:arena -- )
   {: j p:str ar :}
   j p DISPLAY DIRECTORY-DECISION NOOP ar RECORD-NOOP drop ;

: RECONCILE ( -- )
   HELD-JOURNAL @ NOOPS @ PLANS @ HELD-ARENA @ RECORD-RECONCILIATION
   drop ;

: EXISTS? ( MODEL:path -- bool ) drop true ;

: PROBE-FAILS ( MODEL:path -- bool ) drop E-INVALID-STATE throw ;

: NOT-GONE? ( MODEL:path -- bool ) s" Foo/gone.txt" DISPLAY PATH= 0= ;


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
   s" )" swap PUT ;

: REV-DEBUG ( DROPBOX:rev n -- n )
   {: r at :}
   s" DropboxRevision(" at PUT
   r DROPBOX:REV>STR swap PUT-QUOTED
   s" )" swap PUT ;

: SHUT ( n -- n ) s"  }" swap PUT ;

: REMOTE-DEBUG ( MODEL:remote n -- n )
   {: r at :}
   r MODEL-REMOTE:UNMAKE {: c rev :}
   s" RemoteFile { content: " at PUT
   c swap HASH-DEBUG
   s" , revision: " swap PUT
   rev swap REV-DEBUG SHUT ;

: VALUE-DEBUG ( MODEL:baseline n -- n )
   {: at :}
   MATCH MODEL:baseline
      absent OF s" Absent" at PUT ENDOF
      present OF
         {: r :} s" Present(" at PUT {: at2 :}
         r at2 REMOTE-DEBUG s" )" swap PUT
      ENDOF
      directory OF s" Directory" at PUT ENDOF
   ;MATCH ;

: BASELINE-DEBUG ( option<MODEL:baseline> n -- n )
   {: at :}
   MATCH option
      none OF s" None" at PUT ENDOF
      some OF
         {: b :} s" Some(" at PUT {: at2 :}
         b at2 VALUE-DEBUG s" )" swap PUT
      ENDOF
   ;MATCH ;

\ The line baseline(path) answers.
: BASELINE-LINE ( journal str ^ARENA:arena -- str )
   {: j a:str ar :}
   s" baseline(" 0 PUT  a swap PUT  s\" )\t" swap PUT {: at :}
   j a DISPLAY ar BASELINE at BASELINE-DEBUG {: v :}
   0 v WANT-PART ;

: PATHS-LINE ( ^VEC:vector<MODEL:path> -- str )
   {: paths :}
   s\" baseline_paths\t[" 0 PUT
   paths VEC:COUNT 0 ?do
      i 0<> if s" , " swap PUT then
      paths i VEC:AT @ MODEL:PATH>STR swap PUT-QUOTED
   loop
   s" ]" swap PUT {: u :}
   0 u WANT-PART ;

: ORACLE-JOURNAL-HOLDS-ITS-BASELINES ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's baselines are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   p MIGRATED-ORACLE
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
: BOTH-DEBUG ( str MODEL:local MODEL:remote n -- n )
   {: a:str l r at :}
   a at PUT
   s"  { local: " swap PUT  l swap LOCAL-DEBUG
   s" , remote: " swap PUT  r swap REMOTE-DEBUG
   s"  }" swap PUT ;

: CONFLICT-DEBUG ( MODEL:conflict n -- n )
   {: at :}
   MATCH MODEL:conflict
      initial OF
         {: l r :} s" InitialCollision" l r at BOTH-DEBUG
      ENDOF
      divergent OF {: l r :} s" DivergentEdits" l r at BOTH-DEBUG ENDOF
      local-deleted OF
         {: r :} s" LocalDeletionRemoteEdit { remote: " at PUT
         r swap REMOTE-DEBUG s"  }" swap PUT
      ENDOF
      remote-deleted OF
         {: l :} s" RemoteDeletionLocalEdit { local: " at PUT
         l swap LOCAL-DEBUG s"  }" swap PUT
      ENDOF
   ;MATCH ;

: RECORD-DEBUG ( conflict-record n -- n )
   {: r at :}
   r JOURNAL-CONFLICT--RECORD:UNMAKE {: id path x :}
   s" ConflictRecord { id: " at PUT  id swap PUT-N
   s" , path: " swap PUT  path MODEL:PATH>STR swap PUT-QUOTED
   s" , conflict: " swap PUT  x swap CONFLICT-DEBUG
   s"  }" swap PUT ;

: CONFLICTS-LINE ( ^VEC:vector<conflict-record> -- str )
   {: found :}
   s\" conflicts\t[" 0 PUT
   found VEC:COUNT 0 ?do
      i 0<> if s" , " swap PUT then
      found i VEC:AT @ swap RECORD-DEBUG
   loop
   s" ]" swap PUT {: u :}
   0 u WANT-PART ;

: ORACLE-JOURNAL-HOLDS-ITS-CONFLICTS ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's conflicts are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   p MIGRATED-ORACLE
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
   j ar BASELINE-PATHS VEC:COUNT 2 T=
   j s" p" DISPLAY [: EXISTS? ;] ar INVALIDATE-CASE-COLLISION-BASELINES
   j ar BASELINE-PATHS VEC:COUNT 0 T=
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



\ ---- the oracle's plans as the Rust version prints them ----------

: REPLACE-LOCAL-DEBUG ( MODEL:remote DROPBOX:hash n -- n )
   {: r h at :}
   s" ReplaceLocal { source: " at PUT
   r swap REMOTE-DEBUG
   s" , expected_content: " swap PUT
   h swap HASH-DEBUG SHUT ;

: REPLACE-REMOTE-DEBUG ( DROPBOX:hash DROPBOX:rev n -- n )
   {: h r at :}
   s" ReplaceRemote { content: " at PUT
   h swap HASH-DEBUG
   s" , expected_revision: " swap PUT
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
   s" , retry_at: " swap PUT
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
   s" ), ordinal: " swap PUT  ordinal swap PUT-N
   s" , operation: " swap PUT  o swap OPERATION-DEBUG
   s" , status: " swap PUT  st swap RECORD-STATUS-DEBUG SHUT ;

: PLANNED-LIST ( ^VEC:vector<planned-operation> n -- n )
   {: ops at :}
   s" [" at PUT
   ops VEC:COUNT 0 ?do
      i 0<> if s" , " swap PUT then
      ops i VEC:AT @ swap PLANNED-DEBUG
   loop
   s" ]" swap PUT ;

: PLAN-DEBUG ( plan-record n -- n )
   {: at :}
   JOURNAL-PLAN--RECORD:UNMAKE {: id path ops st :}
   s" PlanRecord { id: PlanId(" at PUT
   id PLAN-ID>N swap PUT-N
   s" ), path: " swap PUT  path MODEL:PATH>STR swap PUT-QUOTED
   s" , operations: " swap PUT  ops swap PLANNED-LIST
   s" , status: " swap PUT  st swap STATUS-DEBUG SHUT ;

\ name, a tab, then the plans as a list.
: PLANS-LINE ( str ^VEC:vector<plan-record> -- str )
   {: a:str plans :}
   a 0 PUT  s\" \t[" swap PUT
   plans VEC:COUNT 0 ?do
      i 0<> if s" , " swap PUT then
      plans i VEC:AT @ swap PLAN-DEBUG
   loop
   s" ]" swap PUT {: v :}
   0 v WANT-PART ;

: CONTENT-LINE ( ^VEC:vector<DROPBOX:hash> -- str )
   {: hashes :}
   s\" pending_upload_content\t[" 0 PUT
   hashes VEC:COUNT 0 ?do
      i 0<> if s" , " swap PUT then
      hashes i VEC:AT @ swap HASH-DEBUG
   loop
   s" ]" swap PUT {: u :}
   0 u WANT-PART ;

\ Two statuses alike as the Rust version prints them, which names each
\ field: the first is printed at WANT, the second after it.
: STATUS= ( plan-status plan-status -- bool )
   {: a b :}
   a 0 STATUS-DEBUG {: u :}
   b u STATUS-DEBUG {: v :}
   0 u WANT-PART u v WANT-PART STR:= ;

: ORACLE-JOURNAL-HOLDS-ITS-PLANS ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's plans are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   p MIGRATED-ORACLE
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
         drop s" extract live test plan" TEST-PATH
         s" a blocked path accepted a second live plan" INVALID
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
   s" insufficient_space" MODEL-BLOCKAGE:REMOTE-REJECTED {: why :}
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

: RECORD-UPLOAD ( journal str operation-plan ^ARENA:arena -- )
   {: j a:str plan ar :}
   j a DISPLAY plan ar RECORD-PLAN RECORDED-PLAN drop ;

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
: CRAFTED-STATUS ( n -- str )
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

: CRAFTED-DETAIL ( n -- str )
   {: k :}
   k 4 < if s" plan status disagrees with its block columns" exit then
   k 6 < if s" plan has an unrecognized status" exit then
   s" blocked plan has a negative retry time" ;

: CRAFTED-PATH ( -- MODEL:path ) s" crafted.txt" DISPLAY ;

: DECODE-COLUMNS ( str option<str> option<n> -- plan-status )
   s" read plan status" CRAFTED-PATH HELD-ARENA @
   DECODE-PLAN-STATUS ;

: DECODE-CRAFTED ( -- )
   CRAFT @ {: k :}
   k CRAFTED-STATUS k CRAFTED-JSON k CRAFTED-RETRY DECODE-COLUMNS drop ;

\ The stage-occupied blockage's stored JSON, copied into the arena.
: BLOCKAGE-JSON ( ^ARENA:arena ^JSON:writer -- str )
   {: ar w :}
   MODEL-BLOCKAGE:STAGE-OCCUPIED w ENCODE-BLOCKAGE ar ARENA:COPY ;

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

\ A schema-14 journal holding a schema-6 root's row, as migration 7
\ copies it, and the baseline version_six_with_root writes.
: LEGACY ( str ^ARENA:arena -- )
   {: p:str ar :}
   p OPEN CLOSE
   p SQLITE:OPEN {: c :}
   c s" INSERT INTO local_root_binding(
         singleton, canonical_path, inode, generation
      ) VALUES (1, CAST('/sync/root' AS BLOB), X'0000000000000002', 3)"
   SQLITE:EXEC
   c KEPT-PATH KEPT ar WRITE-BASELINE
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
   j >CONNECTION VERSION 14 T=
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
      some OF {: v :} s" Some(" at PUT v swap PUT-N s" )" swap PUT ENDOF
   ;MATCH ;

: RECOVERY-DEBUG ( recovery-record n -- n )
   {: r at :}
   r JOURNAL-RECOVERY--RECORD:UNMAKE {: id op from to c s kept :}
   s" RecoveryRecord { id: RecoveryId(" at PUT
   id RECOVERY-ID>N swap PUT-N
   s" ), operation_id: OperationId(" swap PUT
   op OPERATION-ID>N swap PUT-N
   s" ), original_path: " swap PUT  from MODEL:PATH>STR swap PUT-QUOTED
   s" , recovery_path: " swap PUT  to MODEL:PATH>STR swap PUT-QUOTED
   s" , content: " swap PUT  c swap HASH-DEBUG
   s" , status: " swap PUT  s swap RECORD-STATUS-DEBUG
   s" , retained_at: " swap PUT  kept swap RETAINED-DEBUG SHUT ;

\ name, a tab, then the records as a list.
: RECOVERIES-LINE ( str ^VEC:vector<recovery-record> -- str )
   {: a:str found :}
   a 0 PUT  s\" \t[" swap PUT
   found VEC:COUNT 0 ?do
      i 0<> if s" , " swap PUT then
      found i VEC:AT @ swap RECOVERY-DEBUG
   loop
   s" ]" swap PUT {: v :}
   0 v WANT-PART ;

\ Two records alike as the Rust version prints them, every field named.
: RECOVERY= ( recovery-record recovery-record -- bool )
   {: a b :}
   a 0 RECOVERY-DEBUG {: u :}
   b u RECOVERY-DEBUG {: v :}
   0 u WANT-PART u v WANT-PART STR:= ;

\ retained_at in completed_recoveries is the clock journal.sqlite3 was
\ written at, which the file holds.
: ORACLE-JOURNAL-HOLDS-ITS-RECOVERIES ( ^ARENA:arena -- )
   {: ar :}
   s" the oracle journal's recoveries are journal.tsv's" T-LABEL
   s" src/oracle/journal.tsv" ORACLE
   ar JOURNAL-AT {: d:str p:str :}
   p MIGRATED-ORACLE
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
   s" extract recorded test recovery" TEST-PATH
   s" test expected a newly recorded recovery" INVALID ;

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
         s" read retained test recovery" path
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
: UPLOAD-AT? ( ^VEC:vector<DROPBOX:hash> n str -- bool )
   {: v k c:str :}
   v k VEC:AT @ c CONTENT HASH= ;

\ The file preserved, then replaced with the content of the text where
\ its revision still stands.
: PRESERVED-REPLACE
   ( MODEL:remote str ^ARENA:arena -- operation-plan )
   {: file c:str ar :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   file MODEL-OPERATION:PRESERVE-REMOTE ops VEC:PUSH !
   file MODEL-REMOTE:UNMAKE {: old rev :}
   c CONTENT rev MODEL-OPERATION:REPLACE-REMOTE ops VEC:PUSH !
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
   s" replace" CONTENT s" rev-old" DROPBOX:>REV
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

\ A completed download plan outlives every prune, the one at open
\ included, until FORGET-COMPLETED-PLAN; a completed upload plan does
\ not, and a live plan is never forgotten.
: COMPLETED-DOWNLOAD-PLANS-WAIT-TO-BE-FORGOTTEN ( ^ARENA:arena -- )
   {: ar :}
   s" completed_download_plans_wait_to_be_forgotten" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: upload :}
   s" download" s" rev-download" REMOTE-FILE DOWNLOAD-DECISION
   ar OPERATIONS {: download :}
   p OPEN {: j :}
   j s" upload.txt" DISPLAY upload ar RECORD-PLAN RECORDED-PLAN >ID
   {: up :}
   j s" download.txt" DISPLAY download ar RECORD-PLAN RECORDED-PLAN >ID
   {: down :}
   j ar COMPLETED-DOWNLOAD-PLANS VEC:COUNT 0 T=
   j down FORGET-COMPLETED-PLAN
   j >CONNECTION down ar READ-PLAN PLAN-GONE? TFALSE
   j up ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j down ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j CLOSE
   p OPEN {: k :}
   k >CONNECTION up ar READ-PLAN PLAN-GONE? TTRUE
   k ar COMPLETED-DOWNLOAD-PLANS {: kept :}
   kept VEC:COUNT 1 T=
   kept 0 VEC:AT @ >ID down ID= TTRUE
   k PRUNE-COMPLETED-WORK 0 T=
   k ar COMPLETED-DOWNLOAD-PLANS VEC:COUNT 1 T=
   k down FORGET-COMPLETED-PLAN
   k >CONNECTION down ar READ-PLAN PLAN-GONE? TTRUE
   k ar COMPLETED-DOWNLOAD-PLANS VEC:COUNT 0 T=
   k CLOSE
   d GONE ;

: COPY-STAGE-ROWS ( journal -- n )
   >CONNECTION s" SELECT COUNT(*) FROM copy_stages" QUERY-INT ;

\ Whether the stage is the copy at target holding content for key k.
: COPY-STAGE-IS? ( copy-stage str DROPBOX:hash MODEL:key -- bool )
   {: s t:str h:DROPBOX:hash k :}
   s JOURNAL-COPY--STAGE:UNMAKE {: p:MODEL:path c:DROPBOX:hash key :}
   p MODEL:PATH>STR t STR:=
   c DROPBOX:HASH>STR h DROPBOX:HASH>STR STR:= and
   key k MODEL:KEY= and ;

\ A copy stage recorded twice is one row; forgetting it leaves the
\ stages of another content or another target.
: COPY-STAGES-ARE-RECORDED-ONCE-AND-FORGOTTEN-ALONE ( ^ARENA:arena -- )
   {: ar :}
   s" a copy stage is recorded once and forgotten alone" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   ar A-HASH {: a:DROPBOX:hash :}
   98 ar LETTER-HASH {: b:DROPBOX:hash :}
   s" conflicted.txt" ar CANONICAL {: k :}
   p OPEN {: j :}
   j s" copy.txt" DISPLAY a k RECORD-COPY-STAGE
   j s" copy.txt" DISPLAY a k RECORD-COPY-STAGE
   j COPY-STAGE-ROWS 1 T=
   j s" copy.txt" DISPLAY b k RECORD-COPY-STAGE
   j s" other.txt" DISPLAY a k RECORD-COPY-STAGE
   j COPY-STAGE-ROWS 3 T=
   j s" copy.txt" DISPLAY a FORGET-COPY-STAGE
   j ar UNHELD-COPY-STAGES {: v :}
   v VEC:COUNT 2 T=
   v 0 VEC:AT @ s" copy.txt" b k COPY-STAGE-IS? TTRUE
   v 1 VEC:AT @ s" other.txt" a k COPY-STAGE-IS? TTRUE
   j CLOSE
   d GONE ;

\ A pending plan, a blocked plan or a conflict block at a stage's key
\ holds it; once none remains it is answered. A stage of another key is
\ answered throughout.
: UNHELD-COPY-STAGES-LEAVE-OUT-HELD-KEYS ( ^ARENA:arena -- )
   {: ar :}
   s" unheld copy stages leave out a held key's" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" held" s" rev-held" REMOTE-FILE DOWNLOAD-DECISION
   ar OPERATIONS {: plan :}
   ar A-HASH {: a:DROPBOX:hash :}
   s" held.txt" ar CANONICAL {: k :}
   s" free.txt" ar CANONICAL {: f :}
   p OPEN {: j :}
   j s" held-copy.txt" DISPLAY a k RECORD-COPY-STAGE
   j s" free-copy.txt" DISPLAY a f RECORD-COPY-STAGE
   j s" held.txt" DISPLAY plan ar RECORD-PLAN RECORDED-PLAN >ID {: id :}
   j ar UNHELD-COPY-STAGES {: pending :}
   pending VEC:COUNT 1 T=
   pending 0 VEC:AT @ s" free-copy.txt" a f COPY-STAGE-IS? TTRUE
   j id MODEL-BLOCKAGE:STAGE-OCCUPIED 1700000000 ar BLOCK-PLAN
   BLOCK-N 2 T=
   j ar UNHELD-COPY-STAGES VEC:COUNT 1 T=
   j s" HELD.txt" DISPLAY MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED
   1700000000 ar BLOCK-NEW-CONFLICT
   j id ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j ar UNHELD-COPY-STAGES VEC:COUNT 1 T=
   j k UNBLOCK-CONFLICT
   j ar UNHELD-COPY-STAGES {: v :}
   v VEC:COUNT 2 T=
   v 0 VEC:AT @ s" free-copy.txt" a f COPY-STAGE-IS? TTRUE
   v 1 VEC:AT @ s" held-copy.txt" a k COPY-STAGE-IS? TTRUE
   j CLOSE
   d GONE ;

\ The recovery copy, completed before its plan finishes, starts no
\ retention until then.
: COPY-UNRETAINED ( journal recovery-record MODEL:path ^ARENA:arena -- )
   {: j recovery path ar :}
   j recovery ID-OF COMPLETE-RECOVERY RECOVERY-COMPLETION-N 2 T=
   j >CONNECTION recovery ID-OF ar READ-RECOVERY MATCH option
      none OF
         s" read conflicted recovery test" path
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

: LIVE-AT ( journal str ^ARENA:arena -- option<plan-record> )
   {: j k:str ar :}
   j k ar CANONICAL ar LIVE-PLAN-AT ;

\ Whether the answer is the plan.
: LIVE-IS? ( option<plan-record> plan-record -- bool )
   {: want :}
   MATCH option
      none OF false ENDOF
      some OF want PLAN= ENDOF
   ;MATCH ;

: NO-LIVE? ( option<plan-record> -- bool )
   MATCH option none OF true ENDOF some OF drop false ENDOF ;MATCH ;

\ LIVE-PLAN-AT answers a pending or a blocked plan as PENDING-PLANS and
\ BLOCKED-PLANS read it, and none for a completed plan or no plan.
: LIVE-PLAN-AT-ANSWERS-ONLY-A-LIVE-PLAN ( ^ARENA:arena -- )
   {: ar :}
   s" live plan at answers only a live plan" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" created" UPLOAD-DECISION ar OPERATIONS {: plan :}
   p OPEN {: j :}
   j s" created.txt" DISPLAY plan ar RECORD-PLAN RECORDED-PLAN
   {: created :}
   j s" held.txt" DISPLAY plan ar RECORD-PLAN RECORDED-PLAN >ID {: id :}
   j id MODEL-BLOCKAGE:STAGE-OCCUPIED 1700000000 ar BLOCK-PLAN
   BLOCK-N 2 T=
   j s" created.txt" ar LIVE-AT j ar PENDING-PLANS ONLY LIVE-IS? TTRUE
   j s" HELD.txt" ar LIVE-AT j ar BLOCKED-PLANS ONLY LIVE-IS? TTRUE
   j s" absent.txt" ar LIVE-AT NO-LIVE? TTRUE
   s" created" s" rev-server" REMOTE-FILE MODEL-BASELINE:PRESENT
   {: actual :}
   j created FIRST-ID actual OPTION:SOME ar COMPLETE-OPERATION
   COMPLETION-N 7 T=
   j s" created.txt" ar LIVE-AT NO-LIVE? TTRUE
   j CLOSE
   d GONE ;

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
   s" /sync/root" 2 birth true sub has FROM-STATX-FIELDS ;

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
: PRESERVED-DELETE ( str ^ARENA:arena -- operation-plan )
   {: c:str ar :}
   ar [type] MODEL:operation NEW-VECTOR {: ops :}
   c CONTENT MODEL-LOCAL:MAKE MODEL-OPERATION:PRESERVE-LOCAL
   ops VEC:PUSH !
   c CONTENT MODEL-OPERATION:DELETE-LOCAL ops VEC:PUSH !
   ops JOURNAL-OPERATION--PLAN:MAKE ;

\ A pending destructive plan of the content, whose deletion has a
\ recovery intent copying to copy, and a blocked upload.
: PRIOR-WORK ( journal str MODEL:path ^ARENA:arena -- )
   {: j c:str copy ar :}
   j s" pending.txt" DISPLAY c ar PRESERVED-DELETE ar RECORD-PLAN
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
   r s" recovery" FS:WRITE-ALL
   s s" staged" FS:WRITE-ALL
   r s ;

: FILE-HOLDS? ( str str ^ARENA:arena -- bool )
   {: f:str t:str ar :}
   ar 16 ARENA:ALLOC drop {: buf:^ :}
   f buf 16 FS:READ-ALL {: u :}
   buf u >str t STR:= ;

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
   j ar CONFLICTS VEC:COUNT 0 T=
   j ar CONFLICT-BLOCKS VEC:COUNT 0 T= ;

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
   root FS:MAKE-DIR
   root INSPECT ;

\ The root's state: an agreed baseline, a local inventory, prior work
\ recovering to the payload, a conflict and a conflict block.
: ROOT-STATE ( journal str ^ARENA:arena -- )
   {: j payload:str ar :}
   j s" agreed.txt" s" agreed" s" rev-agreed" ar AGREE
   j s" local.txt" s" local" PRESENT-LOCAL LOCAL-RECORD ar ONE-LOCAL
   PUBLISH-LOCAL-INVENTORY
   j s" old" payload MODEL:>PATH ar PRIOR-WORK
   j s" conflict.txt" DISPLAY CONFLICTED ar RECORD-CONFLICT drop
   j s" blocked.txt" DISPLAY MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED
   1700000000 ar BLOCK-NEW-CONFLICT ;

: REPLACED-SAME-PATH-IS-UNAVAILABLE-WITHOUT-CHANGING-JOURNAL-STATE
   ( ^ARENA:arena -- )
   {: ar :}
   s" replaced_same_path_is_unavailable_without_changing_journal_state"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   d s" root" ar INSIDE {: root:str :}
   root FS:MAKE-DIR
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
   j s" cursor-kept" CURSOR remote ar ONE-REMOTE ar DELTA
   PUBLISH-REMOTE-INVENTORY
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


\ ---- upload sessions ----------------------------------------------

\ A Dropbox content hash, as a session's record holds one.
: SESSION-CONTENT ( -- DROPBOX:hash )
   s" 9eb62f609dee341fdcc4521fd6d5a78d9e5c5bb36d844618d9e8d1b32f28ba95"
   CONTENT ;

1000 constant SESSION-LENGTH
TYPED-VARIABLE HELD-OPERATION operation-id

: SESSION-ROWS ( journal -- n )
   >CONNECTION s" SELECT COUNT(*) FROM upload_sessions" QUERY-INT ;

\ The session sid confirmed at of SESSION-LENGTH bytes of the operation's
\ upload.
: CHECKPOINTED ( journal operation-id str n -- )
   {: j id sid:str at :}
   j id sid at SESSION-LENGTH SESSION-CONTENT CHECKPOINT-UPLOAD ;

\ The record is sid's at offset at of SESSION-LENGTH bytes of
\ SESSION-CONTENT.
: SESSION-AT? ( option<upload-session> str n -- bool )
   {: sid:str at :}
   MATCH option
      none OF false ENDOF
      some OF
         JOURNAL-UPLOAD--SESSION:UNMAKE {: i:str o u h :}
         i sid SAME? o at = and u SESSION-LENGTH = and
         h SESSION-CONTENT HASH= and
      ENDOF
   ;MATCH ;

: SESSION-NONE? ( option<upload-session> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

\ A pending plan uploading to the path.
: UPLOADING ( journal str ^ARENA:arena -- plan-record )
   {: j a:str ar :}
   s" upload" UPLOAD-DECISION ar OPERATIONS {: ops :}
   j a DISPLAY ops ar RECORD-PLAN RECORDED-PLAN ;

\ A plan uploading to the path, its operation's session checkpointed.
: CHECKPOINTED-PLAN ( journal str ^ARENA:arena -- plan-record )
   {: j a:str ar :}
   j a ar UPLOADING {: plan :}
   j plan FIRST-ID s" session-a" 100 CHECKPOINTED
   j plan FIRST-ID ar UPLOAD-SESSION s" session-a" 100 SESSION-AT? TTRUE
   plan ;

: AN-UPLOAD-SESSION-IS-CHECKPOINTED-READ-AND-RETIRED ( ^ARENA:arena -- )
   {: ar :}
   s" an upload session is checkpointed, read and retired" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" big.bin" ar UPLOADING FIRST-ID {: id :}
   j id ar UPLOAD-SESSION SESSION-NONE? TTRUE
   j id s" session-a" 100 CHECKPOINTED
   j id ar UPLOAD-SESSION s" session-a" 100 SESSION-AT? TTRUE
   j id s" session-a" 600 CHECKPOINTED
   j id ar UPLOAD-SESSION s" session-a" 600 SESSION-AT? TTRUE
   j id s" session-b" 200 CHECKPOINTED
   j id ar UPLOAD-SESSION s" session-b" 200 SESSION-AT? TTRUE
   j SESSION-ROWS 1 T=
   j CLOSE
   p OPEN {: k :}
   k id ar UPLOAD-SESSION s" session-b" 200 SESSION-AT? TTRUE
   k id RETIRE-UPLOAD
   k id ar UPLOAD-SESSION SESSION-NONE? TTRUE
   k id RETIRE-UPLOAD
   k SESSION-ROWS 0 T=
   k CLOSE
   d GONE ;

\ A content identity that is not a Dropbox content hash is refused,
\ logged once, and the record stays as it was.
: A-CHECKPOINT-REFUSES-OTHER-CONTENT ( ^ARENA:arena -- )
   {: ar :}
   s" a checkpoint refuses content that is not a Dropbox hash" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" big.bin" ar CHECKPOINTED-PLAN FIRST-ID {: id :}
   j HELD-JOURNAL !  id HELD-OPERATION !
   [: HELD-JOURNAL @ HELD-OPERATION @ s" session-c" 300 SESSION-LENGTH
      s" big" CONTENT CHECKPOINT-UPLOAD ;]
   E-INVALID-STATE d s" upload content is not a Dropbox content hash" ar
   LOGGED
   j id ar UPLOAD-SESSION s" session-a" 100 SESSION-AT? TTRUE
   j CLOSE
   d GONE ;

\ Completing a non-final operation forgets its session and keeps the
\ later one's; the final one's goes with its plan. A completion that
\ waits for an earlier operation keeps it.
: COMPLETING-AN-OPERATION-FORGETS-ITS-UPLOAD-SESSION ( ^ARENA:arena -- )
   {: ar :}
   s" completing an operation forgets its upload session" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" replace.txt" DISPLAY {: path :}
   s" new" s" rev-server" REMOTE-FILE MODEL-BASELINE:PRESENT {: target :}
   s" old" s" rev-current" REMOTE-FILE s" new" ar PRESERVED-REPLACE
   {: ops :}
   p OPEN {: j :}
   j path ops ar RECORD-PLAN RECORDED-PLAN {: plan :}
   plan 0 NTH-ID {: first :}
   plan 1 NTH-ID {: second :}
   j first s" session-a" 100 CHECKPOINTED
   j second s" session-b" 200 CHECKPOINTED
   j second target OPTION:SOME ar COMPLETE-OPERATION first WAITING-FOR?
   TTRUE
   j second ar UPLOAD-SESSION s" session-b" 200 SESSION-AT? TTRUE
   j first NO-BASELINE ar COMPLETE-OPERATION COMPLETION-N 6 T=
   j first ar UPLOAD-SESSION SESSION-NONE? TTRUE
   j second ar UPLOAD-SESSION s" session-b" 200 SESSION-AT? TTRUE
   j second target OPTION:SOME ar COMPLETE-OPERATION COMPLETION-N 7 T=
   j SESSION-ROWS 0 T=
   j CLOSE
   d GONE ;

: A-CONFLICT-FORGETS-ITS-PLANS-UPLOAD-SESSION ( ^ARENA:arena -- )
   {: ar :}
   s" a conflict forgets its plan's upload session" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" big.bin" ar CHECKPOINTED-PLAN {: plan :}
   j plan >ID DIVERGENT ar FINISH-PLAN-WITH-CONFLICT
   CONFLICT-COMPLETION-N 2 T=
   j plan FIRST-ID ar UPLOAD-SESSION SESSION-NONE? TTRUE
   j SESSION-ROWS 0 T=
   j CLOSE
   d GONE ;

: SUPERSESSION-FORGETS-ITS-PLANS-UPLOAD-SESSION ( ^ARENA:arena -- )
   {: ar :}
   s" supersession forgets its plan's upload session" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" big.bin" ar CHECKPOINTED-PLAN {: plan :}
   j plan >ID ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j plan FIRST-ID ar UPLOAD-SESSION SESSION-NONE? TTRUE
   j SESSION-ROWS 0 T=
   j CLOSE
   d GONE ;

\ A new root's activation purges the prior root's live plans, their
\ sessions with them.
: ACTIVATION-PURGES-THE-PRIOR-ROOTS-UPLOAD-SESSIONS ( ^ARENA:arena -- )
   {: ar :}
   s" a new root's activation purges the prior root's upload sessions"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" /sync/first" 2 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j s" big.bin" ar CHECKPOINTED-PLAN {: plan :}
   j s" /sync/second" 4 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j ar PENDING-PLANS VEC:COUNT 0 T=
   j plan FIRST-ID ar UPLOAD-SESSION SESSION-NONE? TTRUE
   j SESSION-ROWS 0 T=
   j CLOSE
   d GONE ;

\ A new root's activation deletes the prior root's completed download
\ plan, which no prune would.
: ACTIVATION-PURGES-THE-PRIOR-ROOTS-COMPLETED-DOWNLOAD-PLANS
   ( ^ARENA:arena -- )
   {: ar :}
   s" a new root's activation purges the prior root's completed download plans"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" download" s" rev-download" REMOTE-FILE DOWNLOAD-DECISION
   ar OPERATIONS {: download :}
   p OPEN {: j :}
   j s" /sync/first" 2 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j s" download.txt" DISPLAY download ar RECORD-PLAN RECORDED-PLAN >ID
   {: down :}
   j down ar SUPERSEDE-PLAN SUPERSEDED? TTRUE
   j ar COMPLETED-DOWNLOAD-PLANS VEC:COUNT 1 T=
   j s" /sync/second" 4 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j >CONNECTION down ar READ-PLAN PLAN-GONE? TTRUE
   j ar COMPLETED-DOWNLOAD-PLANS VEC:COUNT 0 T=
   j CLOSE
   d GONE ;

\ A new root's activation deletes every copy stage the prior root
\ recorded, held or not.
: ACTIVATION-PURGES-THE-PRIOR-ROOTS-COPY-STAGES ( ^ARENA:arena -- )
   {: ar :}
   s" a new root's activation purges the prior root's copy stages" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   s" held" s" rev-held" REMOTE-FILE DOWNLOAD-DECISION
   ar OPERATIONS {: plan :}
   ar A-HASH {: a:DROPBOX:hash :}
   p OPEN {: j :}
   j s" /sync/first" 2 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j s" held.txt" DISPLAY plan ar RECORD-PLAN RECORDED-PLAN drop
   j s" held-copy.txt" DISPLAY a s" held.txt" ar CANONICAL
   RECORD-COPY-STAGE
   j s" free-copy.txt" DISPLAY a s" free.txt" ar CANONICAL
   RECORD-COPY-STAGE
   j COPY-STAGE-ROWS 2 T=
   j s" /sync/second" 4 LOCAL-ROOT ar ACTIVATE-LOCAL-ROOT ACTIVATED
   j COPY-STAGE-ROWS 0 T=
   j CLOSE
   d GONE ;

\ Every transaction that completes an operation forgets its session, so
\ a completed operation holds one only when checkpointed after it
\ completed; the prune that removes it removes the session too.
: PRUNING-REMOVES-THE-OPERATIONS-UPLOAD-SESSION ( ^ARENA:arena -- )
   {: ar :}
   s" pruning removes the operation's upload session" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" big.bin" ar UPLOADING {: plan :}
   s" upload" s" rev-server" REMOTE-FILE MODEL-BASELINE:PRESENT
   {: uploaded :}
   j plan FIRST-ID uploaded OPTION:SOME ar COMPLETE-OPERATION
   COMPLETION-N 7 T=
   j plan FIRST-ID s" session-a" 100 CHECKPOINTED
   j SESSION-ROWS 1 T=
   j PRUNE-COMPLETED-WORK 1 T=
   j plan FIRST-ID ar UPLOAD-SESSION SESSION-NONE? TTRUE
   j SESSION-ROWS 0 T=
   j CLOSE
   d GONE ;

: BLOCKING-AND-UNBLOCKING-KEEP-THE-UPLOAD-SESSION ( ^ARENA:arena -- )
   {: ar :}
   s" blocking and unblocking keep the upload session" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p OPEN {: j :}
   j s" big.bin" ar CHECKPOINTED-PLAN {: plan :}
   j plan >ID MODEL-BLOCKAGE:REMOTE-OBJECT 1700000000 ar BLOCK-PLAN
   BLOCK-N 2 T=
   j plan FIRST-ID ar UPLOAD-SESSION s" session-a" 100 SESSION-AT? TTRUE
   j plan >ID ar UNBLOCK-PLAN UNBLOCK-N 2 T=
   j plan FIRST-ID ar UPLOAD-SESSION s" session-a" 100 SESSION-AT? TTRUE
   j CLOSE
   d GONE ;

\ A schema-10 journal gains the empty upload session table.
: A-SCHEMA-10-JOURNAL-MIGRATES-TO-14 ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-10 journal migrates to schema 14" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p TEN-ORACLE
   p VERSION-AT 10 T=
   p OPEN {: j :}
   j SCHEMA-14
   j SESSION-ROWS 0 T=
   j CLOSE
   d GONE ;


\ ---- stored values MODEL cannot read -----------------------------

\ The oracle journal, copied into a case's directory and opened, with
\ the SQL run on it; the journal and arena are held for a reader.
: PLANTED ( str ^ARENA:arena -- str )
   {: sql:str ar :}
   ar JOURNAL-AT {: d:str p:str :}
   s" src/oracle/journal.sqlite3" p FS:COPY-FILE-STREAM
   p OPEN {: j :}
   j >CONNECTION sql SQLITE:EXEC
   j HELD-JOURNAL !  ar HELD-ARENA !
   d ;

: PLANTED-GONE ( str -- ) HELD-JOURNAL @ CLOSE GONE ;

\ `op` could not process the record for `path`, as MODEL:E-STORED.
: STORED-LINE ( str str -- str )
   {: op:str path:str :}
   s" `" 0 PUT  op swap PUT
   s" ` could not process the record for `" swap PUT
   path swap PUT  s" `: " swap PUT
   MODEL:E-STORED swap PUT-N  s"  " swap PUT
   MODEL:E-STORED ERROR:NAME$ swap PUT {: u :}
   0 u WANT-PART ;

\ The reader throws E-JSON after one line naming op, path and cause.
: UNREADABLE ( [ -- ] str str str ^ARENA:arena -- )
   {: reader d:str op:str path:str ar :}
   op path STORED-LINE {: a:str :}
   reader E-JSON d a ar LOGGED ;

: HELD-PENDING-PLANS ( -- )
   HELD-JOURNAL @ HELD-ARENA @ PENDING-PLANS drop ;

: HELD-BLOCKED-PLANS ( -- )
   HELD-JOURNAL @ HELD-ARENA @ BLOCKED-PLANS drop ;

: HELD-CONFLICTS ( -- ) HELD-JOURNAL @ HELD-ARENA @ CONFLICTS drop ;

: HELD-PENDING-RECOVERIES ( -- )
   HELD-JOURNAL @ HELD-ARENA @ PENDING-RECOVERIES drop ;

: PLANT-AT ( str str -- )
   {: sql:str p:str :}
   p SQLITE:OPEN {: c :}
   c sql SQLITE:EXEC
   c SQLITE:CLOSE ;

\ At schema 9, a baseline MODEL cannot read refuses the migration.
: AN-UNKNOWN-BASELINE-REFUSES-THE-MIGRATION ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored baseline refuses the migration" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p NINE-ORACLE
   s\" UPDATE baselines SET baseline_json = '{\"Future\":1}'
      WHERE hex(path) = hex('Docs')" p PLANT-AT
   p SUBJECT !
   [: SUBJECT @ OPEN CLOSE ;] d s" deserialize baseline" s" Docs" ar
   UNREADABLE
   p VERSION-AT 9 T=
   p SQLITE:OPEN {: c :}
   c s\" SELECT count(*) FROM baselines
      WHERE baseline_json = '{\"Future\":1}'" QUERY-INT 1 T=
   c s" SELECT count(*) FROM baselines" QUERY-INT 2 T=
   c s" SELECT count(*) FROM sqlite_master
      WHERE name = 'converted_baselines'" QUERY-INT 0 T=
   c SQLITE:CLOSE
   d GONE ;

\ A present, a directory and an absent baseline at schema 9 migrate; the
\ absent one's row goes.
: A-SCHEMA-9-JOURNAL-MIGRATES-ITS-BASELINES ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-9 journal migrates each kind of baseline" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p NINE-ORACLE
   s\" INSERT INTO baselines(path, baseline_json, canonical_path)
      VALUES (CAST('Old/Gone.txt' AS BLOB), '\"Absent\"',
         CAST('old/gone.txt' AS BLOB))" p PLANT-AT
   p OPEN {: j :}
   j >CONNECTION VERSION 14 T=
   j s" Docs" DISPLAY ar BASELINE MODEL-BASELINE:DIRECTORY
   BASELINE-HELD? TTRUE
   j s" Docs/A.txt" DISPLAY ar BASELINE ORACLE-FILE BASELINE-HELD? TTRUE
   j >CONNECTION s" SELECT count(*) FROM baselines
      WHERE path = CAST('Old/Gone.txt' AS BLOB)" QUERY-INT 0 T=
   j >CONNECTION s" SELECT count(*) FROM baselines" QUERY-INT 2 T=
   j CLOSE
   d GONE ;

\ At schema 9, a remote observation MODEL cannot read refuses the
\ migration.
: AN-UNKNOWN-REMOTE-OBSERVATION-REFUSES-THE-MIGRATION ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored remote observation refuses the migration" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p NINE-ORACLE
   s\" UPDATE remote_observations SET observation_json = '{\"Future\":1}'
      WHERE hex(path) = hex('Docs')" p PLANT-AT
   p SUBJECT !
   [: SUBJECT @ OPEN CLOSE ;] d s" deserialize remote observation"
   s" Docs" ar UNREADABLE
   p VERSION-AT 9 T=
   p SQLITE:OPEN {: c :}
   c s\" SELECT count(*) FROM remote_observations
      WHERE observation_json = '{\"Future\":1}'" QUERY-INT 1 T=
   c s" SELECT count(*) FROM remote_observations" QUERY-INT 3 T=
   c s" SELECT count(*) FROM sqlite_master
      WHERE name LIKE 'converted%'" QUERY-INT 0 T=
   c SQLITE:CLOSE
   d GONE ;

\ The oracle's remote rows, a directory, a file and an inaccessible
\ folder, and one of each other kind, as schema 9 holds them.
: EVERY-REMOTE-KIND ( -- str )
   s\" INSERT INTO remote_observations(path, observation_json,
         canonical_path)
      SELECT CAST(column1 AS BLOB), column2, CAST(column1 AS BLOB)
      FROM (VALUES ('gone', '\"ConfirmedAbsent\"'),
         ('incomplete', '{\"Unknown\":\"Incomplete\"}'),
         ('unavailable', '{\"Unknown\":\"Unavailable\"}'),
         ('stale', '{\"Unknown\":\"Stale\"}'),
         ('reset', '{\"Unknown\":\"CursorReset\"}'),
         ('unsupported', '{\"Unknown\":\"Unsupported\"}'))" ;

: UNKNOWN-REMOTE
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:UNKNOWN ;

\ The records hold an unknown observation for the reason at the key.
: UNKNOWN-HELD?
   ( ^VEC:vector<MODEL:remote-record> str MODEL:unknown-reason
     ^ARENA:arena -- bool )
   {: v k:str why ar :}
   v k ar CANONICAL why UNKNOWN-REMOTE ANY-HOLDS? ;

\ A remote observation of each kind at schema 9 migrates; the absent
\ one's row goes.
: A-SCHEMA-9-JOURNAL-MIGRATES-ITS-REMOTE-OBSERVATIONS
   ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-9 journal migrates each kind of remote observation"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p NINE-ORACLE
   EVERY-REMOTE-KIND p PLANT-AT
   p OPEN {: j :}
   j >CONNECTION VERSION 14 T=
   j ar REMOTE-INVENTORY JOURNAL-REMOTE--INVENTORY:UNMAKE {: cur v :}
   v VEC:COUNT 8 T=
   v ar ORACLE-REMOTES? TTRUE
   v s" incomplete" MODEL-UNKNOWN--REASON:INCOMPLETE ar UNKNOWN-HELD?
   TTRUE
   v s" unavailable" MODEL-UNKNOWN--REASON:UNAVAILABLE ar UNKNOWN-HELD?
   TTRUE
   v s" stale" MODEL-UNKNOWN--REASON:STALE ar UNKNOWN-HELD? TTRUE
   v s" reset" MODEL-UNKNOWN--REASON:CURSOR-RESET ar UNKNOWN-HELD?
   TTRUE
   v s" unsupported" MODEL-UNKNOWN--REASON:UNSUPPORTED ar UNKNOWN-HELD?
   TTRUE
   j >CONNECTION s" SELECT count(*) FROM remote_observations
      WHERE path = CAST('gone' AS BLOB)" QUERY-INT 0 T=
   j CLOSE
   d GONE ;

\ A local row of each kind the oracle lacks, and one MODEL cannot read,
\ as schema 9 holds them; each canonical path is its path in lower
\ case, as MODEL:FOLD gives it.
: EVERY-LOCAL-KIND ( -- str )
   s\" INSERT INTO local_observations(path, observation_json,
         canonical_path)
      SELECT CAST(column1 AS BLOB), column2,
         CAST(lower(column1) AS BLOB)
      FROM (VALUES ('Gone', '\"ConfirmedAbsent\"'),
         ('Incomplete', '{\"Unknown\":\"Incomplete\"}'),
         ('Unavailable', '{\"Unknown\":\"Unavailable\"}'),
         ('Stale', '{\"Unknown\":\"Stale\"}'),
         ('Reset', '{\"Unknown\":\"CursorReset\"}'),
         ('Unsupported', '{\"Unknown\":\"Unsupported\"}'),
         ('Future', '{\"Future\":1}'))" ;

\ The local record at the path, unknown for the reason.
: UNKNOWN-AT
   ( str MODEL:unknown-reason -- MODEL:local-record )
   UNKNOWN-LOCAL LOCAL-RECORD ;

\ ORACLE-LOCALS and EVERY-LOCAL-KIND's records, by path: Gone's gone
\ and Future's unknown, Incomplete.
: MIGRATED-LOCALS
   ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   ORACLE-LOCALS {: v :}
   s" Future" MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-AT v LOCAL+
   s" Incomplete" MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-AT
   v LOCAL+
   s" Reset" MODEL-UNKNOWN--REASON:CURSOR-RESET UNKNOWN-AT v LOCAL+
   s" Stale" MODEL-UNKNOWN--REASON:STALE UNKNOWN-AT v LOCAL+
   s" Unavailable" MODEL-UNKNOWN--REASON:UNAVAILABLE UNKNOWN-AT
   v LOCAL+
   s" Unsupported" MODEL-UNKNOWN--REASON:UNSUPPORTED UNKNOWN-AT
   v LOCAL+
   v ;

\ Whether the answer is the record.
: LOCAL-IS? ( option<MODEL:local-record> MODEL:local-record -- bool )
   {: want :}
   MATCH option
      none OF false ENDOF
      some OF want MODEL:LOCAL-RECORD= ENDOF
   ;MATCH ;

: NO-LOCAL? ( option<MODEL:local-record> -- bool )
   MATCH option none OF true ENDOF some OF drop false ENDOF ;MATCH ;

\ A local observation of each kind at schema 9 migrates; the absent
\ one's row goes, and the one MODEL cannot read stays, unknown, at its
\ path and canonical path.
: A-SCHEMA-9-JOURNAL-MIGRATES-ITS-LOCAL-OBSERVATIONS
   ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-9 journal migrates each kind of local observation"
   T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p NINE-ORACLE
   EVERY-LOCAL-KIND p PLANT-AT
   p OPEN {: j :}
   j >CONNECTION VERSION 14 T=
   j ar LOCAL-INVENTORY ar MIGRATED-LOCALS LOCAL-RECORDS= TTRUE
   s" Future" MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-AT {: f :}
   j s" future" ar CANONICAL ar LOCAL-AT f LOCAL-IS? TTRUE
   j s" gone" ar CANONICAL ar LOCAL-AT NO-LOCAL? TTRUE
   j CLOSE
   d GONE ;

\ Hash cache rows of generation 1 as schema 9 holds them, each a
\ fingerprint, where # stands for its four time members, and content,
\ where * stands for 63 a's: Kept and Spaced convert, then one row each
\ of malformed text, a missing member, a repeated member, content not
\ 64 lowercase hex digits, with a NUL past them, a negative size and an
\ inode above SQLite's largest integer.
: EVERY-HASH-KIND ( -- str )
   s\" INSERT INTO local_hash_cache(root_generation, path, hash_json)
      SELECT 1, CAST(column1 AS BLOB),
         '{\"fingerprint\":' || replace(column2, '#',
            '\"modified_seconds\":1,\"modified_nanoseconds\":10,'
            || '\"changed_seconds\":2,\"changed_nanoseconds\":10')
         || ',\"content\":\"'
         || replace(column3, '*', printf('%.63c', 'a')) || '\"}'
      FROM (VALUES ('Kept', '{\"inode\":11,\"size\":12,#}', 'a*'),
         ('Spaced', '{ \"changed_nanoseconds\" : 10,
            \"inode\" : 9223372036854775807, \"device\" : [3],
            \"size\" : 6, \"modified_seconds\" : -7,
            \"modified_nanoseconds\" : 8, \"changed_seconds\" : -9 }',
            'a*'),
         ('Malformed', '{\"inode\":11,\"size\":12,#', 'a*'),
         ('Missing', '{\"inode\":11,#}', 'a*'),
         ('Repeated', '{\"inode\":11,\"size\":12,\"size\":12,#}',
            'a*'),
         ('Upper', '{\"inode\":11,\"size\":12,#}', 'A*'),
         ('Nul', '{\"inode\":11,\"size\":12,#}', 'a*\\u0000'),
         ('Negative', '{\"inode\":11,\"size\":-12,#}', 'a*'),
         ('Big', '{\"inode\":9223372036854775808,\"size\":12,#}',
            'a*'))" ;

\ EVERY-HASH-KIND's Spaced row as its record.
: SPACED-RECORD ( ^ARENA:arena -- MODEL:hash-record )
   {: ar :}
   s" Spaced" DISPLAY
   $7FFFFFFFFFFFFFFF 6 -7 8 -9 10 MODEL-FINGERPRINT:MAKE
   ar A-HASH MODEL-HASH--RECORD:MAKE ;

: HASH-HELD ( ^VEC:vector<MODEL:hash-record> MODEL:hash-record -- )
   {: v r :}
   false v VEC:COUNT 0 ?do v i VEC:AT @ r MODEL:HASH-RECORD= or loop
   TTRUE ;

: AT-PATH? ( MODEL:hash-record str -- bool )
   {: r p:str :}
   r MODEL-HASH--RECORD:UNMAKE {: q:MODEL:path f h :}
   q MODEL:PATH>STR p STR:= ;

: HASH-GONE ( ^VEC:vector<MODEL:hash-record> str -- )
   {: v p:str :}
   false v VEC:COUNT 0 ?do v i VEC:AT @ p AT-PATH? or loop TFALSE ;

\ The active root's cache holds the rows that convert as their records
\ and no other.
: HASHES-MIGRATED ( journal ^ARENA:arena -- )
   {: j ar :}
   j ar LOCAL-HASH-CACHE {: v :}
   v s" Kept" 10 ar LOCAL-HASH HASH-HELD
   v ar SPACED-RECORD HASH-HELD
   v s" Malformed" HASH-GONE  v s" Missing" HASH-GONE
   v s" Repeated" HASH-GONE  v s" Upper" HASH-GONE
   v s" Nul" HASH-GONE  v s" Negative" HASH-GONE
   v s" Big" HASH-GONE ;

\ The rows that convert join the oracle's one; the others go.
: A-SCHEMA-9-JOURNAL-MIGRATES-ITS-HASH-CACHE ( ^ARENA:arena -- )
   {: ar :}
   s" a schema-9 journal migrates its hash cache" T-LABEL
   ar JOURNAL-AT {: d:str p:str :}
   p NINE-ORACLE
   EVERY-HASH-KIND p PLANT-AT
   p OPEN {: j :}
   j >CONNECTION VERSION 14 T=
   j >CONNECTION s" SELECT count(*) FROM local_hash_cache" QUERY-INT
   3 T=
   j ar HASHES-MIGRATED
   j CLOSE
   d GONE ;

\ The text set by the update at schema 9 in c, then migrated, in one
\ transaction: whether the migration refused it as op's, rolled back,
\ or else left the transaction open. f takes the refusal's log.
: MIGRATED?
   ( SQLITE:connection str str str str ^ARENA:arena -- bool )
   {: c t:str update:str op:str f:str ar :}
   c s" BEGIN" SQLITE:EXEC
   c update [: t 1 SQLITE:BIND-TEXT RAN ;] SQLITE:WITH-STATEMENT
   [: c MIGRATE-TYPED-COLUMNS ;] f ar STDERR:CAPTURING {: code e:str :}
   code 0= if false exit then
   code E-JSON T=  e op STR:CONTAINS? TTRUE
   c s" ROLLBACK" SQLITE:EXEC
   true ;

\ The text as Docs's baseline at schema 9 in c, migrated, then rolled
\ back: the baseline read back, and whether the migration refused it.
: MIGRATION-READ
   ( SQLITE:connection str str ^ARENA:arena
     -- option<MODEL:baseline> bool )
   {: c t:str f:str ar :}
   c t s" UPDATE baselines SET baseline_json = ?1
      WHERE path = CAST('Docs' AS BLOB)" s" deserialize baseline" f ar
   MIGRATED? if NO-BASELINE true exit then
   c s" SELECT kind, content, revision FROM baselines
      WHERE path = CAST('Docs' AS BLOB)" [: ar BASELINE-ROW ;]
   SQLITE:WITH-STATEMENT {: b :}
   c s" ROLLBACK" SQLITE:EXEC
   b false ;

: SAME-BASELINE? ( option<MODEL:baseline> option<MODEL:baseline> -- bool )
   {: want :}
   MATCH option
      none OF want NO-BASELINE? ENDOF
      some OF {: b :} want b BASELINE-HELD? ENDOF
   ;MATCH ;

\ The migration takes the text, and reads back the baseline
\ serde reads from it, want, none for absent.
: CONVERTS
   ( SQLITE:connection str option<MODEL:baseline> str ^ARENA:arena
     -- )
   {: c t:str want f:str ar :}
   t T-LABEL
   c t f ar MIGRATION-READ {: got refuses:bool :}
   refuses TFALSE
   got want SAME-BASELINE? TTRUE ;

\ The migration refuses the text.
: BASELINE-REFUSES ( SQLITE:connection str str ^ARENA:arena -- )
   {: c t:str f:str ar :}
   t T-LABEL
   c t f ar MIGRATION-READ {: got refuses:bool :}
   refuses TTRUE
   got NO-BASELINE? TTRUE ;

\ The expected file baseline of that content and revision.
: FILE-BASELINE ( str str -- option<MODEL:baseline> )
   REMOTE-FILE MODEL-BASELINE:PRESENT OPTION:SOME ;

: DIRECTORY-BASELINE ( -- option<MODEL:baseline> )
   MODEL-BASELINE:DIRECTORY OPTION:SOME ;

: READ-TEXTS ( SQLITE:connection str ^ARENA:arena -- )
   {: c f:str ar :}
   c s\" \"Directory\"" DIRECTORY-BASELINE f ar CONVERTS
   c s\" \"Absent\"" NO-BASELINE f ar CONVERTS
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\"}}"
   s" h" s" r" FILE-BASELINE f ar CONVERTS
   c s\"  \"Directory\" " DIRECTORY-BASELINE f ar CONVERTS
   c s\" \"Dir\\u0065ctory\"" DIRECTORY-BASELINE f ar CONVERTS
   c s\" {\"Pr\\u0065sent\":{\"c\\u006fntent\":\"h\\u0041\",\"revision\":\"r\"}}"
   s" hA" s" r" FILE-BASELINE f ar CONVERTS
   c s\" {\"Present\":{\"revision\":\"r\",\"x\":[1,{\"y\":null}],\"content\":\"h\"}}"
   s" h" s" r" FILE-BASELINE f ar CONVERTS
   c s\" {\"Present\":{\"content\":\"\",\"revision\":\"\"}}"
   s" " s" " FILE-BASELINE f ar CONVERTS
   c s\" {\"Present\":{\"content\":\"\\ud83d\\ude00\",\"revision\":\"r\"}}"
   s\" \xF0\x9F\x98\x80" s" r" FILE-BASELINE f ar CONVERTS
   c s\" {\"Present\":{\"content\":\"a\\u0000b\",\"revision\":\"r\"}}"
   s\" a\x00b" s" r" FILE-BASELINE f ar CONVERTS
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\",\"n\":123456789012345678901234567890}}"
   s" h" s" r" FILE-BASELINE f ar CONVERTS
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\",\"x\":{\"a\":1,\"a\":2}}}"
   s" h" s" r" FILE-BASELINE f ar CONVERTS ;

\ serde reads a unit variant as an object, {"Directory":null}, but
\ no version writes one; here and below the migration refuses it.
: REFUSED-TEXTS ( SQLITE:connection str ^ARENA:arena -- )
   {: c f:str ar :}
   c s\" \"Present\"" f ar BASELINE-REFUSES
   c s\" {\"Directory\":null}" f ar BASELINE-REFUSES
   c s\" {\"Absent\":null}" f ar BASELINE-REFUSES
   c s" not json" f ar BASELINE-REFUSES
   c s\" {\"Present\":{\"content\":\"h\"}}" f ar BASELINE-REFUSES
   c s\" {\"Present\":{\"content\":\"h\",\"content\":\"h\",\"revision\":\"r\"}}" f ar BASELINE-REFUSES
   c s\" {\"Present\":{\"content\":1,\"revision\":\"r\"}}" f ar BASELINE-REFUSES
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":null}}" f ar BASELINE-REFUSES
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\"},\"x\":1}" f ar BASELINE-REFUSES
   c s\" {'Present':{\"content\":\"h\",\"revision\":\"r\"}}" f ar BASELINE-REFUSES
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\",}}" f ar BASELINE-REFUSES
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\"}} x" f ar BASELINE-REFUSES
   c s" []" f ar BASELINE-REFUSES
   c s\" {\"Present\":[]}" f ar BASELINE-REFUSES
   c s\" \"directory\"" f ar BASELINE-REFUSES
   c s\" \"Directory\\u0000\"" f ar BASELINE-REFUSES
   c s\" {\"Future\":1}" f ar BASELINE-REFUSES ;

\ The text as Docs's remote observation at schema 9 in c, migrated,
\ then rolled back: its record read back, and whether the migration
\ refused it.
: REMOTE-MIGRATION-READ
   ( SQLITE:connection str str ^ARENA:arena
     -- option<MODEL:remote-record> bool )
   {: c t:str f:str ar :}
   c t s" UPDATE remote_observations SET observation_json = ?1
      WHERE path = CAST('Docs' AS BLOB)"
   s" deserialize remote observation" f ar
   MIGRATED? if NO-REMOTE true exit then
   c s" SELECT canonical_path, path, kind, content, revision
      FROM remote_observations WHERE path = CAST('Docs' AS BLOB)"
   [: ar REMOTE-AT-ROW ;] SQLITE:WITH-STATEMENT {: r :}
   c s" ROLLBACK" SQLITE:EXEC
   r false ;

: SAME-REMOTE?
   ( option<MODEL:remote-record> option<MODEL:remote-record> -- bool )
   {: want :}
   MATCH option
      none OF want NO-REMOTE? ENDOF
      some OF {: r :} want r REMOTE-IS? ENDOF
   ;MATCH ;

\ The migration takes the text, and reads back Docs's record of
\ the remote observation serde reads from it, want, none for
\ absent.
: REMOTE-CONVERTS
   ( SQLITE:connection str option<MODEL:remote-record> str
     ^ARENA:arena -- )
   {: c t:str want f:str ar :}
   t T-LABEL
   c t f ar REMOTE-MIGRATION-READ {: got refuses:bool :}
   refuses TFALSE
   got want SAME-REMOTE? TTRUE ;

\ The migration refuses the text.
: REMOTE-REFUSES ( SQLITE:connection str str ^ARENA:arena -- )
   {: c t:str f:str ar :}
   t T-LABEL
   c t f ar REMOTE-MIGRATION-READ {: got refuses:bool :}
   refuses TTRUE
   got NO-REMOTE? TTRUE ;

\ Docs's expected record of the remote observation.
: DOCS-REMOTE
   ( MODEL:observation<MODEL:remote> ^ARENA:arena
     -- option<MODEL:remote-record> )
   {: o ar :}
   s" docs" ar CANONICAL s" Docs" DISPLAY o MODEL-REMOTE--RECORD:MAKE
   OPTION:SOME ;

: REMOTE-READ-TEXTS ( SQLITE:connection str ^ARENA:arena -- )
   {: c f:str ar :}
   c s\" \"Directory\"" REMOTE-DIRECTORY ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" \"ConfirmedAbsent\"" NO-REMOTE f ar REMOTE-CONVERTS
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\"}}"
   s" h" s" r" PRESENT-REMOTE ar DOCS-REMOTE f ar REMOTE-CONVERTS
   c s\" {\"Unknown\":\"Incomplete\"}"
   MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" {\"Unknown\":\"Inaccessible\"}"
   MODEL-UNKNOWN--REASON:INACCESSIBLE UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" {\"Unknown\":\"Unavailable\"}"
   MODEL-UNKNOWN--REASON:UNAVAILABLE UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" {\"Unknown\":\"Stale\"}"
   MODEL-UNKNOWN--REASON:STALE UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" {\"Unknown\":\"CursorReset\"}"
   MODEL-UNKNOWN--REASON:CURSOR-RESET UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" {\"Unknown\":\"Unsupported\"}"
   MODEL-UNKNOWN--REASON:UNSUPPORTED UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\"  { \"Unknown\" : \"Stale\" } "
   MODEL-UNKNOWN--REASON:STALE UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" {\"Unkn\\u006fwn\":\"St\\u0061le\"}"
   MODEL-UNKNOWN--REASON:STALE UNKNOWN-REMOTE ar DOCS-REMOTE
   f ar REMOTE-CONVERTS
   c s\" \"Confirmed\\u0041bsent\"" NO-REMOTE f ar REMOTE-CONVERTS ;

: REMOTE-REFUSED-TEXTS ( SQLITE:connection str ^ARENA:arena -- )
   {: c f:str ar :}
   c s\" \"Absent\"" f ar REMOTE-REFUSES
   c s\" \"Unknown\"" f ar REMOTE-REFUSES
   c s\" \"Present\"" f ar REMOTE-REFUSES
   c s\" {\"Directory\":null}" f ar REMOTE-REFUSES
   c s\" {\"ConfirmedAbsent\":null}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":null}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"stale\"}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"Future\"}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"\"}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"Stale\\u0000\"}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":{\"Stale\":null}}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":[\"Stale\"]}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":3}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"Stale\",\"x\":1}" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"Stale\",\"Unknown\":\"Stale\"}"
   f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"Stale\"} x" f ar REMOTE-REFUSES
   c s\" {\"Unknown\":\"Stale\",}" f ar REMOTE-REFUSES
   c s\" {'Unknown':\"Stale\"}" f ar REMOTE-REFUSES
   c s\" {\"Present\":{\"content\":\"h\"}}"
   f ar REMOTE-REFUSES
   c s\" {\"Future\":1}" f ar REMOTE-REFUSES
   c s" not json" f ar REMOTE-REFUSES ;

\ The text as Docs's local observation at schema 9 in c, migrated,
\ then rolled back: its record read back. The migration never refuses
\ a local text.
: LOCAL-MIGRATION-READ
   ( SQLITE:connection str str ^ARENA:arena
     -- option<MODEL:local-record> )
   {: c t:str f:str ar :}
   c t s" UPDATE local_observations SET observation_json = ?1
      WHERE path = CAST('Docs' AS BLOB)"
   s" deserialize local observation" f ar
   MIGRATED? dup TFALSE if NO-LOCAL exit then
   c s" SELECT path, kind, content FROM local_observations
      WHERE path = CAST('Docs' AS BLOB)"
   [: ar LOCAL-AT-ROW ;] SQLITE:WITH-STATEMENT {: r :}
   c s" ROLLBACK" SQLITE:EXEC
   r ;

: SAME-LOCAL?
   ( option<MODEL:local-record> option<MODEL:local-record> -- bool )
   {: want :}
   MATCH option
      none OF want NO-LOCAL? ENDOF
      some OF {: r :} want r LOCAL-IS? ENDOF
   ;MATCH ;

\ The migration reads back want, Docs's record of the local
\ observation serde reads from the text, none for absent.
: LOCAL-CONVERTS
   ( SQLITE:connection str option<MODEL:local-record> str
     ^ARENA:arena -- )
   {: c t:str want f:str ar :}
   t T-LABEL
   c t f ar LOCAL-MIGRATION-READ want SAME-LOCAL? TTRUE ;

\ Docs's expected record of the local observation.
: DOCS-LOCAL
   ( MODEL:observation<MODEL:local> -- option<MODEL:local-record> )
   {: o :} s" Docs" o LOCAL-RECORD OPTION:SOME ;

\ A refused text reads as Docs's unknown record, Incomplete.
: LOCAL-REFUSED ( SQLITE:connection str str ^ARENA:arena -- )
   {: c t:str f:str ar :}
   c t MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS ;

: LOCAL-READ-TEXTS ( SQLITE:connection str ^ARENA:arena -- )
   {: c f:str ar :}
   c s\" \"Directory\"" LOCAL-DIRECTORY DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" \"ConfirmedAbsent\"" NO-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"content\":\"h\"}}"
   s" h" PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Unknown\":\"Incomplete\"}"
   MODEL-UNKNOWN--REASON:INCOMPLETE UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" {\"Unknown\":\"Inaccessible\"}"
   MODEL-UNKNOWN--REASON:INACCESSIBLE UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" {\"Unknown\":\"Unavailable\"}"
   MODEL-UNKNOWN--REASON:UNAVAILABLE UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" {\"Unknown\":\"Stale\"}"
   MODEL-UNKNOWN--REASON:STALE UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" {\"Unknown\":\"CursorReset\"}"
   MODEL-UNKNOWN--REASON:CURSOR-RESET UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" {\"Unknown\":\"Unsupported\"}"
   MODEL-UNKNOWN--REASON:UNSUPPORTED UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\"  { \"Unknown\" : \"Stale\" } "
   MODEL-UNKNOWN--REASON:STALE UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" {\"Unkn\\u006fwn\":\"St\\u0061le\"}"
   MODEL-UNKNOWN--REASON:STALE UNKNOWN-LOCAL DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" \"Confirmed\\u0041bsent\"" NO-LOCAL f ar LOCAL-CONVERTS
   c s\" \"Dir\\u0065ctory\"" LOCAL-DIRECTORY DOCS-LOCAL
   f ar LOCAL-CONVERTS
   c s\" {\"Pr\\u0065sent\":{\"c\\u006fntent\":\"h\\u0041\"}}"
   s" hA" PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"x\":[1,{\"y\":null}],\"content\":\"h\"}}"
   s" h" PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"content\":\"h\",\"revision\":\"r\"}}"
   s" h" PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"content\":\"\"}}"
   s" " PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"content\":\"\\ud83d\\ude00\"}}"
   s\" \xF0\x9F\x98\x80" PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"content\":\"a\\u0000b\"}}"
   s\" a\x00b" PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"content\":\"\",\"x\":{\"a\":1,\"a\":2}}}"
   s" " PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS
   c s\" {\"Present\":{\"content\":\"\",\"n\":1234567890123456789012}}"
   s" " PRESENT-LOCAL DOCS-LOCAL f ar LOCAL-CONVERTS ;

: LOCAL-REFUSED-TEXTS ( SQLITE:connection str ^ARENA:arena -- )
   {: c f:str ar :}
   c s\" \"Absent\"" f ar LOCAL-REFUSED
   c s\" \"Unknown\"" f ar LOCAL-REFUSED
   c s\" \"Present\"" f ar LOCAL-REFUSED
   c s\" \"directory\"" f ar LOCAL-REFUSED
   c s\" \"Directory\\u0000\"" f ar LOCAL-REFUSED
   c s\" {\"Directory\":null}" f ar LOCAL-REFUSED
   c s\" {\"ConfirmedAbsent\":null}" f ar LOCAL-REFUSED
   c s\" {\"Unknown\":null}" f ar LOCAL-REFUSED
   c s\" {\"Unknown\":\"stale\"}" f ar LOCAL-REFUSED
   c s\" {\"Unknown\":\"Future\"}" f ar LOCAL-REFUSED
   c s\" {\"Unknown\":\"Stale\",\"x\":1}" f ar LOCAL-REFUSED
   c s\" {\"Present\":{}}" f ar LOCAL-REFUSED
   c s\" {\"Present\":[]}" f ar LOCAL-REFUSED
   c s\" {\"Present\":{\"content\":1}}" f ar LOCAL-REFUSED
   c s\" {\"Present\":{\"content\":null}}" f ar LOCAL-REFUSED
   c s\" {\"Present\":{\"content\":\"h\",\"content\":\"h\"}}"
   f ar LOCAL-REFUSED
   c s\" {\"Present\":{\"content\":\"h\"},\"x\":1}"
   f ar LOCAL-REFUSED
   c s\" {'Present':{\"content\":\"h\"}}" f ar LOCAL-REFUSED
   c s\" {\"Present\":{\"content\":\"h\",}}" f ar LOCAL-REFUSED
   c s\" {\"Present\":{\"content\":\"h\"}} x" f ar LOCAL-REFUSED
   c s" []" f ar LOCAL-REFUSED
   c s\" {\"Future\":1}" f ar LOCAL-REFUSED
   c s" not json" f ar LOCAL-REFUSED ;

\ Each text as Docs's baseline, then as its remote and its local
\ observation, of a schema-9 journal.
: THE-MIGRATION-CONVERTS-OR-REFUSES-EACH-TEXT ( ^ARENA:arena -- )
   {: ar :}
   ar JOURNAL-AT {: d:str p:str :}
   p NINE-ORACLE
   d s" stderr.txt" ar INSIDE {: f:str :}
   p SQLITE:OPEN {: c :}
   c f ar READ-TEXTS
   c f ar REFUSED-TEXTS
   c f ar REMOTE-READ-TEXTS
   c f ar REMOTE-REFUSED-TEXTS
   c f ar LOCAL-READ-TEXTS
   c f ar LOCAL-REFUSED-TEXTS
   c SQLITE:CLOSE
   d GONE ;

\ Plan 2's only operation, which PENDING-PLANS reads.
: AN-UNKNOWN-OPERATION-IS-REFUSED ( ^ARENA:arena -- )
   {: ar :}
   s" an unknown stored operation is refused" T-LABEL
   s\" UPDATE operations SET operation_json = '{\"Future\":1}'
      WHERE id = 2" ar PLANTED {: d:str :}
   [: HELD-PENDING-PLANS ;] d s" deserialize operation"
   s" Docs/New.txt" ar UNREADABLE
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
   ar ORACLE-JOURNAL-IS-MIGRATED
   ar SCHEMA-11-JOURNAL-IS-MIGRATED
   ar SCHEMA-12-JOURNAL-IS-MIGRATED
   ar SCHEMA-13-JOURNAL-IS-MIGRATED
   ar FAILED-MIGRATION-LEAVES-SCHEMA-8
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
   ar REMOTE-AT-ANSWERS-THE-RECORD-AT-A-KEY
   ar A-HOLD-HIDES-THE-RECORD-UNTIL-ITS-UNHOLD
   ar A-HELD-KEY-OUTLIVES-ITS-OWN-DELETION
   ar AN-UNHOLD-RELEASES-THE-HOLDS-BENEATH-IT
   ar A-SUBTREE-DELETION-RELEASES-THE-HOLDS-BENEATH-IT
   ar A-LISTING-HOLDS-A-DIRECTORY-KEY
   ar A-HOLD-ON-ANOTHER-FOLD-IS-REFUSED
   ar A-HOLD-SPELLED-AS-ANOTHER-KEY-IS-REFUSED
   ar UNKNOWN-OBSERVATIONS-ARE-READ-ALONE
   ar JOURNAL-LOCAL-SCAN-REPLACES-INVENTORY-AND-HASHES-ATOMICALLY
   ar EACH-LOCAL-COLLISION-VISITS-IN-KEY-ORDER
   ar LOCAL-COUNT-AND-LOCAL-AT
   ar KNOWN-PATHS-ARE-READ-ROW-BY-ROW
   ar SUBTREE-HOLDS-ONLY-TRUE-DESCENDANTS
   ar A-SCAN-PUBLISHES-ONLY-ITS-DIFFERENCE
   ar A-SCAN-DROPS-HASHES-OF-ANOTHER-GENERATION
   ar WITH-SCAN-EMPTIES-THE-PREVIOUS-SCAN
   ar A-SCAN-FOR-ANOTHER-ROOT-WRITES-NOTHING
   ar EACH-SCAN-JOB-VISITS-EACH-ROW-ONCE-IN-PATH-ORDER
   ar A-VISIT-PUBLISHES-WHAT-IT-OBSERVES-AND-HASHES
   ar THE-SCAN-STAGES-ONLY-WHAT-DIFFERS
   ar A-STORED-STREAM-RESUMES-PAST-ITS-BOUND
   ar A-SKIPPED-FOLDER-KEEPS-ITS-STORED-ROWS
   ar A-SKIP-STAGES-GONE-WHAT-THE-WALK-PASSED-OVER
   ar A-RANGE-MERGES-ONLY-BENEATH-ITS-FOLDER
   ar TWO-RANGES-IN-ONE-SCAN-MERGE-EACH-FOLDER
   ar SCAN-FILE-REUSES-ONLY-REUSABLE-HASHES
   ar A-THROW-OUT-OF-WITH-SCAN-LEAVES-NO-TRANSACTION-OPEN
   ar A-VISIT-HOLDS-NO-LOCK-OF-THE-SCAN-BEFORE-IT
   ar A-FULL-SCAN-LEAVES-THE-NEXT-SCAN-WHOLE
   ar A-PUBLISHED-LISTED-FOLDER-IS-CLEAN
   ar AN-UNPUBLISHED-SCAN-STIRS-WHAT-IT-LISTED
   ar A-REFUSED-PUBLICATION-LEAVES-THE-MARKS
   ar NEXT-STIRRED-ANSWERS-IN-PATH-ORDER
   ar WATCH-RECORDS-ARE-REPLACED-AND-FORGOTTEN
   ar A-TRIED-FOLDER-IS-STIRRED-AFTER-ITS-SCAN
   ar A-PUBLISHED-SCAN-FORGETS-THE-RECORDS-OF-FOLDERS-IT-DROPS
   ar A-STOPPED-SCAN-PUBLISHES-NOTHING
   ar ORACLE-JOURNAL-HOLDS-ITS-BASELINES
   ar JOURNAL-REOPEN-EXPOSES-INTENT-WITHOUT-ADVANCING-BASELINE
   ar RECONCILIATION-DECISIONS-COMMIT-ATOMICALLY
   ar JOURNAL-NOOP-REFRESHES-REVISION-BUT-CANNOT-CROSS-A-PENDING-PLAN
   ar ABSENT-BASELINE-REMOVES-ITS-ROW
   ar CASE-COLLISION-INVALIDATION-COVERS-A-CHILD-NAMED-WITH-A-HIGH-BYTE
   ar CASE-COLLISION-INVALIDATION-JUDGES-EACH-RECORDED-SPELLING
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
   ar COMPLETED-DOWNLOAD-PLANS-WAIT-TO-BE-FORGOTTEN
   ar COPY-STAGES-ARE-RECORDED-ONCE-AND-FORGOTTEN-ALONE
   ar UNHELD-COPY-STAGES-LEAVE-OUT-HELD-KEYS
   ar JOURNAL-PLAN-CONFLICT-COMPLETES-ONCE-WITHOUT-ADVANCING-BASELINE
   ar LIVE-PLAN-AT-ANSWERS-ONLY-A-LIVE-PLAN
   ar AN-UNKNOWN-BASELINE-REFUSES-THE-MIGRATION
   ar A-SCHEMA-9-JOURNAL-MIGRATES-ITS-BASELINES
   ar AN-UNKNOWN-REMOTE-OBSERVATION-REFUSES-THE-MIGRATION
   ar A-SCHEMA-9-JOURNAL-MIGRATES-ITS-REMOTE-OBSERVATIONS
   ar A-SCHEMA-9-JOURNAL-MIGRATES-ITS-LOCAL-OBSERVATIONS
   ar A-SCHEMA-9-JOURNAL-MIGRATES-ITS-HASH-CACHE
   ar THE-MIGRATION-CONVERTS-OR-REFUSES-EACH-TEXT
   ar AN-UNKNOWN-OPERATION-IS-REFUSED
   ar AN-UNKNOWN-BLOCKAGE-IS-REFUSED
   ar AN-UNKNOWN-CONFLICT-IS-REFUSED
   ar AN-UNREADABLE-RECOVERY-CONTENT-IS-REFUSED
   ar AN-UPLOAD-SESSION-IS-CHECKPOINTED-READ-AND-RETIRED
   ar A-CHECKPOINT-REFUSES-OTHER-CONTENT
   ar COMPLETING-AN-OPERATION-FORGETS-ITS-UPLOAD-SESSION
   ar A-CONFLICT-FORGETS-ITS-PLANS-UPLOAD-SESSION
   ar SUPERSESSION-FORGETS-ITS-PLANS-UPLOAD-SESSION
   ar ACTIVATION-PURGES-THE-PRIOR-ROOTS-UPLOAD-SESSIONS
   ar ACTIVATION-PURGES-THE-PRIOR-ROOTS-COMPLETED-DOWNLOAD-PLANS
   ar ACTIVATION-PURGES-THE-PRIOR-ROOTS-COPY-STAGES
   ar PRUNING-REMOVES-THE-OPERATIONS-UPLOAD-SESSION
   ar BLOCKING-AND-UNBLOCKING-KEEP-THE-UPLOAD-SESSION
   ar A-SCHEMA-10-JOURNAL-MIGRATES-TO-14 ;


: TESTS ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   HEAP:ALLOCATOR 0 [type] u8 VEC:NEW BODY-V !
   HEAP:ALLOCATOR 0 [type] u8 VEC:NEW LINE-V !
   HEAP:ALLOCATOR 0 [type] u8 VEC:NEW WANT-V !
   [: ar CASES ;]
   [: BODY VEC:DELETE LINE VEC:DELETE WANT VEC:DELETE
      ar ARENA:RELEASE ;] finally
   s" journal-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

TESTS

;package
