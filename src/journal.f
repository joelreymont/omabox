\ journal.f - package JOURNAL: the sync journal, a SQLite file at schema 8
\ (rust src/journal.rs), and the Dropbox account and local root it is
\ bound to. OPEN makes the file 0600 without following a link and creates
\ schema 8 in a new one, in one transaction, from migrations/, whose texts
\ this file lays in the program as it loads; any version but 0 and 8 is
\ refused unchanged, and OPEN-READ refuses any but 8. A SQLite failure is
\ SQLITE's throw, passed up unchanged. JOURNAL's own failures are logged
\ once with the Rust version's text, then thrown as its codes.
\ A root binding is the root's inode, birth time and subvolume: btrfs gives
\ a subvolume a new device number at every mount, so the device is none
\ of it. A binding with no birth time is one a version-6 journal recorded;
\ an activation whose path and inode match it upgrades it in place.
\ Each publication is one immediate transaction, and the remote cursor
\ and inventory are read in one deferred one. A stored value is written
\ and read by MODEL's JSON words; one MODEL cannot read is E-JSON, logged
\ with the record's path.
\ STORAGE CLASS. CALLER-OWNED: a journal borrows the path it was opened
\ with until CLOSE, and a binding INSPECT answers borrows its path; every
\ string and vector a reader answers lies in the arena the caller passes.
\ A journal belongs to the task that opened it. TASK-LOCAL: the bytes a
\ root's inode and subvolume are bound from, and the JSON writer and
\ buffer a publication encodes with, TASK:+USERS rows.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/be.f
require src/lib/task.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fs-statx.f
require src/lib/sqlite.f
require src/lib/byte-buffer.f
require src/lib/json.f
require src/lib/vector.f
require src/dropbox.f
require src/model.f

package JOURNAL
public

-100300 constant E-FIRST
-100399 constant E-LAST
-100300 s" journal operation failed" ERROR:CODE E-FILE
-100301 s" journal operation could not process the record"
   ERROR:CODE E-JSON
-100302 s" journal operation found invalid state"
   ERROR:CODE E-INVALID-STATE
-100303 s" journal has unsupported schema version"
   ERROR:CODE E-UNSUPPORTED-VERSION
-100304
   s" sync root is on a filesystem that does not record creation times"
   ERROR:CODE E-NO-BIRTH-TIME

\ The connection and the path it was opened on, which logs name.
STRUCTURE journal OPAQUE
   FIELD connection SQLITE:connection
   FIELD path str
;STRUCTURE

\ The Dropbox account and the root in its namespace this journal syncs.
STRUCTURE dropbox-binding
   FIELD account-id str
   FIELD root-namespace-id str
   FIELD remote-root str
;STRUCTURE

\ mismatch: another binding is stored, which stays.
ENUM dropbox-binding-write
   VARIANT bound ;VARIANT
   VARIANT already-bound ;VARIANT
   VARIANT mismatch FIELD existing dropbox-binding ;VARIANT
;ENUM

\ Seconds since the epoch, then nanoseconds below one billion.
STRUCTURE birth-time
   FIELD seconds n
   FIELD nanoseconds n
;STRUCTURE

\ subvolume is none where statx reports none (not btrfs or bcachefs).
STRUCTURE local-root-binding
   FIELD canonical-path str
   FIELD inode n
   FIELD birth option<birth-time>
   FIELD subvolume option<n>
;STRUCTURE

\ generation counts the roots this journal has held, from 1.
STRUCTURE local-root-record
   FIELD binding local-root-binding
   FIELD generation n
;STRUCTURE

\ activated: a new generation, the root's state reset; current: this
\ root holds; unavailable: another directory stands at the recorded path.
ENUM local-root-activation
   VARIANT activated FIELD record local-root-record ;VARIANT
   VARIANT current FIELD record local-root-record ;VARIANT
   VARIANT unavailable
      FIELD recorded local-root-binding
      FIELD actual local-root-binding
   ;VARIANT
;ENUM

private

8 constant SCHEMA
5000 constant BUSY-MS
$180 constant MODE-OWNER            \ 0600
$1FF constant MODE-BITS
$7FFFFFFFFFFFFFFF constant INT-MAX  \ SQLite's largest integer
1000000000 constant NS-PER-S

16 TASK:+USERS ID-ROW u8


\ ---- migrations ----------------------------------------------------

\ Lays a migration's length, then its bytes, in the body of the word just
\ created, read as this file loads from where a require would find the
\ name, so a built program carries the text. The name is on the stack
\ before the create: a top-level string is laid at here.
: LAY ( ^u8 n -- )
   SOURCE-ROOT:RESOLVE drop {: at:^ u :}
   at u FS:FILE-SIZE {: size :}
   size ,
   at u here size FS:READ-ALL drop
   size allot align ;


s" migrations/0001.sql" create V1 LAY
s" migrations/0002.sql" create V2 LAY
s" migrations/0003.sql" create V3 LAY
s" migrations/0004.sql" create V4 LAY
s" migrations/0005.sql" create V5 LAY
s" migrations/0006.sql" create V6 LAY
s" migrations/0007.sql" create V7 LAY
s" migrations/0008.sql" create V8 LAY

: TEXT ( ^n -- ^u8 n )
   {: p:^n :}
   p CELL + BYTE-VIEW p @ ;

: RUN ( SQLITE:connection ^n -- ) TEXT SQLITE:EXEC ;


\ ---- failures ------------------------------------------------------

: LOG-OPEN ( -- ) LOG:ERROR s" journal" LOG:LINE ;

: STR+ ( str -- ) str> LOG:TEXT+ ;

: OPERATION ( str -- )
   LOG-OPEN s" journal operation `" LOG:TEXT+ STR+ s" ` " LOG:TEXT+ ;

: FAILED-FOR ( str str -- )
   {: op:str path:str :}
   op OPERATION s" failed for `" LOG:TEXT+ path STR+ s" `: " LOG:TEXT+ ;

\ op's File failure on path, caused by errno, else by code.
: FILE-FAILED ( str str n n -- )
   {: op:str path:str code errno :}
   op path FAILED-FOR
   errno 0= if code LOG:CODE+ else errno FS:ERRNO$ LOG:TEXT+ then
   LOG:;LINE
   E-FILE throw ;

: FILE-REFUSED ( str str str -- )
   {: op:str path:str why:str :}
   op path FAILED-FOR why STR+ LOG:;LINE
   E-FILE throw ;

: INVALID ( str str str -- )
   {: op:str path:str detail:str :}
   op OPERATION s" found invalid state for `" LOG:TEXT+ path STR+
   s" `: " LOG:TEXT+ detail STR+ LOG:;LINE
   E-INVALID-STATE throw ;

: UNSUPPORTED ( str n -- )
   {: path:str found :}
   LOG-OPEN s" journal `" LOG:TEXT+ path STR+
   s" ` has unsupported schema version " LOG:TEXT+ found LOG:INT+
   s" ; supported version is " LOG:TEXT+ SCHEMA LOG:INT+ LOG:;LINE
   E-UNSUPPORTED-VERSION throw ;

: REFUSE-UNBORN ( str -- )
   LOG-OPEN s" sync root `" LOG:TEXT+ STR+
   s" ` is on a filesystem that does not record creation times"
   LOG:TEXT+ LOG:;LINE
   E-NO-BIRTH-TIME throw ;

\ Runs io; its failure is op's on path.
: FILE-IO ( [ -- ] str str -- )
   {: io op:str path:str :}
   FS:CAUSE-CLEAR
   io catch {: code :}
   code 0= if exit then
   op path code FS:ERRNO FILE-FAILED ;


\ ---- a connection --------------------------------------------------

: >CONNECTION ( journal -- SQLITE:connection ) JOURNAL-UNMAKE drop ;
: >PATH ( journal -- str ) JOURNAL-UNMAKE nip ;

: INT-ROW ( SQLITE:statement -- n SQLITE:statement )
   SQLITE:STEP drop 0 SQLITE:COL-INT swap ;

\ The first column of the query's first row; no row is SQLITE's throw.
: QUERY-INT ( SQLITE:connection ^u8 n -- n )
   [: INT-ROW ;] SQLITE:WITH-STATEMENT ;

: VERSION ( SQLITE:connection -- n )
   s" PRAGMA user_version" QUERY-INT ;

public

: CLOSE ( journal -- ) >CONNECTION SQLITE:CLOSE ;

private

\ The journal, or, when setup throws, its connection closed and the throw.
: SET-UP ( journal [ journal -- ] -- journal )
   {: j setup :}
   [: j setup execute ;] catch {: code :}
   code 0= if j exit then
   j CLOSE code throw ;


\ ---- opening -------------------------------------------------------

\ A name already taken must be a regular file, never followed.
: REGULAR ( str str -- )
   {: op:str path:str :}
   path str> FS:TRY-LSTAT 0= if op path E-FS-STAT 0 FILE-FAILED then
   FS:STAT-MODE@ FS:S-IFMT and FS:S-IFREG = if exit then
   op path s" existing path is not a regular file" >str FILE-REFUSED ;

\ A new empty file only its owner may read, or the regular file there.
: OWNER-ONLY ( str -- )
   {: path:str :}
   s" create journal database" >str {: op:str :}
   FS:CAUSE-CLEAR
   false [: drop path str> s" " FS:ATOMIC-CREATE-PRIVATE ;] catch
   {: code :}
   code 0= if if exit then op path REGULAR exit then
   drop op path code FS:ERRNO FILE-FAILED ;

: DELETE-MODE? ( SQLITE:statement -- bool SQLITE:statement )
   SQLITE:STEP drop 0 SQLITE:COL-TEXT s" delete" STR=CI swap ;

: CONFIGURE-WRITABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   c s" PRAGMA foreign_keys = ON" SQLITE:EXEC
   c s" PRAGMA journal_mode = DELETE" [: DELETE-MODE? ;]
   SQLITE:WITH-STATEMENT 0= if
      s" set rollback journal mode" >str j >PATH
      s" SQLite did not enable DELETE journal mode" >str INVALID
   then
   c s" PRAGMA synchronous = FULL" SQLITE:EXEC
   c s" PRAGMA synchronous" QUERY-INT 2 <> if
      s" verify SQLite synchronization" >str j >PATH
      s" SQLite did not enable FULL synchronization" >str INVALID
   then ;

\ migrate_canonical_paths of the Rust version on empty tables.
: CANONICAL-PATHS ( SQLITE:connection -- )
   s" CREATE UNIQUE INDEX baselines_by_canonical_path
         ON baselines(canonical_path);
      CREATE UNIQUE INDEX remote_observations_by_canonical_path
         ON remote_observations(canonical_path);
      CREATE INDEX plans_by_canonical_path ON plans(canonical_path);
      CREATE INDEX conflicts_by_canonical_path
         ON conflicts(canonical_path);
      PRAGMA user_version = 4;" SQLITE:EXEC ;

\ migrate_blocked_plans of the Rust version on empty tables.
: BLOCKED-PLANS ( SQLITE:connection -- )
   {: c :}
   c s" DROP INDEX baselines_by_canonical_path;
      DROP INDEX remote_observations_by_canonical_path;" SQLITE:EXEC
   c V6 RUN
   c s" PRAGMA user_version = 6" SQLITE:EXEC ;

\ Schema 8 in a new file, by the Rust version's steps from version 0.
: CREATE-SCHEMA ( SQLITE:connection -- )
   {: c :}
   c V1 RUN  c V2 RUN  c V3 RUN  c V4 RUN
   c CANONICAL-PATHS
   c V5 RUN
   c BLOCKED-PLANS
   c V7 RUN  c V8 RUN ;

: WRITABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   BUSY-MS c SQLITE:BUSY-MS!
   [: j >PATH str> MODE-OWNER FS:CHMOD-MODE ;]
   s" restrict journal permissions" >str j >PATH FILE-IO
   c VERSION {: v :}
   v 0<> v SCHEMA <> and if j >PATH v UNSUPPORTED then
   j CONFIGURE-WRITABLE
   v 0= if c [: c CREATE-SCHEMA ;] SQLITE:WITH-TRANSACTION then ;

: READABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   BUSY-MS c SQLITE:BUSY-MS!
   c VERSION {: v :}
   v SCHEMA <> if j >PATH v UNSUPPORTED then ;

public

\ The journal at path, schema 8 created in a new or empty file. Another
\ version is E-UNSUPPORTED-VERSION, the file unchanged.
: OPEN ( str -- journal )
   {: path:str :}
   path OWNER-ONLY
   path str> SQLITE:OPEN path JOURNAL-MAKE [: WRITABLE ;] SET-UP ;

\ The schema-8 journal at path, never created or changed.
: OPEN-READ ( str -- journal )
   {: path:str :}
   path str> SQLITE:OPEN-READ path JOURNAL-MAKE [: READABLE ;] SET-UP ;


private


\ ---- strings -------------------------------------------------------

: SAME? ( str str -- bool )
   {: a:str b:str :}
   a str> b str> STR= ;

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

: TEXT-COPY ( SQLITE:statement n ^ARENA:arena -- SQLITE:statement str )
   {: col ar :}
   col SQLITE:COL-TEXT ar COPIED ;

: BLOB-COPY ( SQLITE:statement n ^ARENA:arena -- SQLITE:statement str )
   {: col ar :}
   col SQLITE:COL-BLOB ar COPIED ;


\ ---- the Dropbox binding -------------------------------------------

: SELECT-BINDING ( -- ^u8 n )
   s" SELECT account_id, root_namespace_id, remote_root
      FROM dropbox_binding WHERE singleton = 1" ;

: BINDING-COLS
   ( SQLITE:statement ^ARENA:arena -- SQLITE:statement dropbox-binding )
   {: ar :}
   0 ar TEXT-COPY {: account:str :}
   1 ar TEXT-COPY {: namespace:str :}
   2 ar TEXT-COPY {: root:str :}
   account namespace root JOURNAL-DROPBOX--BINDING:MAKE ;

: NO-BINDING ( -- option<dropbox-binding> ) OPTION:NONE ;

: BINDING-ROW
   ( ^ARENA:arena SQLITE:statement
     -- option<dropbox-binding> SQLITE:statement )
   swap {: ar :}
   SQLITE:STEP 0= if NO-BINDING swap exit then
   ar BINDING-COLS OPTION:SOME swap ;

\ No row is SQLITE's throw.
: EXISTING-ROW
   ( ^ARENA:arena SQLITE:statement -- dropbox-binding SQLITE:statement )
   swap {: ar :}
   SQLITE:STEP drop ar BINDING-COLS swap ;

: BINDING= ( dropbox-binding dropbox-binding -- bool )
   JOURNAL-DROPBOX--BINDING:UNMAKE {: a:str b:str c:str :}
   JOURNAL-DROPBOX--BINDING:UNMAKE {: d:str e:str f:str :}
   a d SAME? b e SAME? and c f SAME? and ;

: INSERT-BINDING ( SQLITE:connection dropbox-binding -- )
   {: c b :}
   b JOURNAL-DROPBOX--BINDING:UNMAKE
   {: account:str namespace:str root:str :}
   c s" INSERT INTO dropbox_binding(
         singleton, account_id, root_namespace_id, remote_root
      ) VALUES (1, ?1, ?2, ?3)
      ON CONFLICT(singleton) DO NOTHING"
   [: account str> 1 SQLITE:BIND-TEXT
      namespace str> 2 SQLITE:BIND-TEXT
      root str> 3 SQLITE:BIND-TEXT
      SQLITE:STEP drop ;] SQLITE:WITH-STATEMENT ;

: BIND-WRITE
   ( SQLITE:connection dropbox-binding ^ARENA:arena
     -- dropbox-binding-write )
   {: c b ar :}
   c b INSERT-BINDING
   c SQLITE:CHANGES 1 = if construct dropbox-binding-write bound exit then
   ar c SELECT-BINDING [: EXISTING-ROW ;] SQLITE:WITH-STATEMENT
   {: existing :}
   existing b BINDING= if
      construct dropbox-binding-write already-bound exit
   then
   existing construct dropbox-binding-write mismatch ;

public

\ The Dropbox account and root this journal is bound to, if setup
\ completed.
: DROPBOX-BINDING ( journal ^ARENA:arena -- option<dropbox-binding> )
   {: j ar :}
   ar j >CONNECTION SELECT-BINDING [: BINDING-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Binds the journal to one account and root; an existing binding stays.
: BIND-DROPBOX-ROOT
   ( journal dropbox-binding ^ARENA:arena -- dropbox-binding-write )
   {: j b ar :}
   j >CONNECTION {: c :}
   c [: c b ar BIND-WRITE ;] SQLITE:WITH-TRANSACTION ;

private


\ ---- a root's identity ---------------------------------------------

: NO-BIRTH ( -- option<birth-time> ) OPTION:NONE ;
: NO-SUBVOLUME ( -- option<n> ) OPTION:NONE ;
: NO-RECORD ( -- option<local-root-record> ) OPTION:NONE ;
: NO-ACTIVATION ( -- option<local-root-activation> ) OPTION:NONE ;

: >BINDING ( local-root-record -- local-root-binding )
   JOURNAL-LOCAL--ROOT--RECORD:UNMAKE drop ;

: >GENERATION ( local-root-record -- n )
   JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b g :} g ;

: ROOT-PATH ( local-root-binding -- str )
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str i b s :} p ;

: ROOT-INODE ( local-root-binding -- n )
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str i b s :} i ;

: ROOT-BIRTH ( local-root-binding -- option<birth-time> )
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str i b s :} b ;

: BIRTHLESS? ( option<birth-time> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: BIRTH= ( birth-time birth-time -- bool )
   JOURNAL-BIRTH--TIME:UNMAKE {: s1 n1 :}
   JOURNAL-BIRTH--TIME:UNMAKE {: s2 n2 :}
   s1 s2 = n1 n2 = and ;

: SOME-BIRTH= ( option<birth-time> birth-time -- bool )
   {: b :}
   MATCH option
      none OF false ENDOF
      some OF b BIRTH= ENDOF
   ;MATCH ;

: BORN= ( option<birth-time> option<birth-time> -- bool )
   MATCH option
      none OF BIRTHLESS? ENDOF
      some OF SOME-BIRTH= ENDOF
   ;MATCH ;

: SOME-SUBVOLUME= ( option<n> n -- bool )
   {: v :}
   MATCH option
      none OF false ENDOF
      some OF v = ENDOF
   ;MATCH ;

: NO-SUBVOLUME? ( option<n> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: SUBVOLUME= ( option<n> option<n> -- bool )
   MATCH option
      none OF NO-SUBVOLUME? ENDOF
      some OF SOME-SUBVOLUME= ENDOF
   ;MATCH ;

: ROOT= ( local-root-binding local-root-binding -- bool )
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str i b s :}
   JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: q:str j c t :}
   p q SAME? i j = and b c BORN= and s t SUBVOLUME= and ;

\ A binding recorded before schema 7 holds no birth time, so path and
\ inode are all that tie it to the directory inspected now.
: UPGRADES-LEGACY-ROOT? ( local-root-binding local-root-binding -- bool )
   {: recorded actual :}
   recorded ROOT-BIRTH BIRTHLESS?
   recorded ROOT-PATH actual ROOT-PATH SAME? and
   recorded ROOT-INODE actual ROOT-INODE = and ;

: INSPECTING ( -- str ) s" inspect local root" >str ;

\ The descriptor's inode, birth time and whether statx reports it, then
\ its subvolume and whether statx reports that.
: STATX ( fd -- n n n bool n bool )
   {: dir:fd :}
   dir FS:FD-STAT FS:STAT-INO@
   dir FS-STATX:BIRTH
   dir FS-STATX:SUBVOLUME ;

: OPENED ( str -- fd )
   {: path:str :}
   FS:CAUSE-CLEAR
   0 >FD [: drop path str> FS:OPEN-DIR ;] catch {: code :}
   code 0= if exit then
   drop INSPECTING path code FS:ERRNO FILE-FAILED ;

public

\ The identity statx gave: a birth time unreported is E-NO-BIRTH-TIME,
\ a subvolume unreported is none.
: FROM-STATX-FIELDS
   ( str n birth-time bool n bool -- local-root-binding )
   {: path:str inode birth born:bool sub has:bool :}
   born 0= if path REFUSE-UNBORN then
   path inode birth OPTION:SOME
   has if sub OPTION:SOME else NO-SUBVOLUME then
   JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

\ The identity of the root the descriptor names, path its canonical path.
: FROM-STATX ( str fd -- local-root-binding )
   {: path:str dir:fd :}
   FS:CAUSE-CLEAR
   0 0 0 false 0 false [: 2drop 2drop 2drop dir STATX ;] catch
   {: code :}
   code 0= if
      {: inode s ns born:bool sub has:bool :}
      path inode s ns JOURNAL-BIRTH--TIME:MAKE born sub has
      FROM-STATX-FIELDS exit
   then
   2drop 2drop 2drop INSPECTING path code FS:ERRNO FILE-FAILED ;

\ The identity of the directory at the canonical path, opened without
\ following a link; any failure but a birth time's is E-FILE.
: INSPECT ( str -- local-root-binding )
   {: path:str :}
   path OPENED {: dir:fd :}
   [: path dir FROM-STATX ;] [: dir FS:CLOSE-DIR ;] finally ;

\ Whether a refusal for missing birth times of the directory at path,
\ whose inode is n, means another directory stands at this root's path,
\ as the mount point under an absent mount does: the recorded root had a
\ birth time or, recorded before schema 7, another inode.
: STOOD-IN-BY? ( local-root-record str n -- bool )
   {: r path:str inode :}
   r >BINDING {: b :}
   b ROOT-PATH path SAME? 0= if false exit then
   b ROOT-BIRTH BIRTHLESS? 0= if true exit then
   b ROOT-INODE inode <> ;

private


\ ---- the root's row ------------------------------------------------

: SELECT-ROOT ( -- ^u8 n )
   s" SELECT canonical_path, inode, birth_seconds, birth_nanoseconds,
         subvolume, generation
      FROM local_root_binding WHERE singleton = 1" ;

: UPSERT-ROOT ( -- ^u8 n )
   s" INSERT INTO local_root_binding(
         singleton, canonical_path, inode, birth_seconds,
         birth_nanoseconds, subvolume, generation
      ) VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT(singleton) DO UPDATE SET
         canonical_path = excluded.canonical_path,
         inode = excluded.inode,
         birth_seconds = excluded.birth_seconds,
         birth_nanoseconds = excluded.birth_nanoseconds,
         subvolume = excluded.subvolume,
         generation = excluded.generation" ;

\ An inode or subvolume as the eight big-endian bytes a row holds, in
\ this task's ID-ROW at byte at.
: BE-BYTES ( n n -- ^u8 n )
   {: v at :}
   at ID-ROW {: p:^ :}
   v p BE:U64!
   p 8 ;

: BIND-BIRTH ( SQLITE:statement option<birth-time> -- SQLITE:statement )
   MATCH option
      none OF 3 SQLITE:BIND-NULL 4 SQLITE:BIND-NULL ENDOF
      some OF
         JOURNAL-BIRTH--TIME:UNMAKE {: s ns :}
         s 3 SQLITE:BIND-INT ns 4 SQLITE:BIND-INT
      ENDOF
   ;MATCH ;

: BIND-SUBVOLUME ( SQLITE:statement option<n> -- SQLITE:statement )
   MATCH option
      none OF 5 SQLITE:BIND-NULL ENDOF
      some OF 8 BE-BYTES 5 SQLITE:BIND-BLOB ENDOF
   ;MATCH ;

: BIND-ROOT ( local-root-record SQLITE:statement -- SQLITE:statement )
   swap JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b g :}
   b JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str inode birth sub :}
   p str> 1 SQLITE:BIND-BLOB
   inode 0 BE-BYTES 2 SQLITE:BIND-BLOB
   birth BIND-BIRTH
   sub BIND-SUBVOLUME
   g 6 SQLITE:BIND-INT
   SQLITE:STEP drop ;

: WRITE-LOCAL-ROOT ( SQLITE:connection local-root-record -- )
   {: c r :}
   r c UPSERT-ROOT [: BIND-ROOT ;] SQLITE:WITH-STATEMENT ;

: DECODE-U64 ( ^u8 n str str -- n )
   {: a:^ u op:str path:str :}
   u 8 <> if
      op path s" filesystem identity has an invalid byte length" >str
      INVALID
   then
   a BE:U64@ ;

: BLOB-U64 ( SQLITE:statement n str str -- SQLITE:statement n )
   {: col op:str path:str :}
   col SQLITE:COL-BLOB op path DECODE-U64 ;

: BIRTH-INVALID ( str str -- )
   {: path:str detail:str :}
   s" read local root birth time" >str path detail INVALID ;

: ROW-BIRTH ( SQLITE:statement str -- SQLITE:statement option<birth-time> )
   {: path:str :}
   2 SQLITE:COL-NULL? {: no-s:bool :}
   3 SQLITE:COL-NULL? {: no-ns:bool :}
   no-s no-ns and if NO-BIRTH exit then
   no-s no-ns or if
      path s" local root birth time is only partly recorded" >str
      BIRTH-INVALID
   then
   2 SQLITE:COL-INT {: s :}
   3 SQLITE:COL-INT {: ns :}
   ns 0 < ns NS-PER-S >= or if
      path s" local root birth nanoseconds are out of range" >str
      BIRTH-INVALID
   then
   s ns JOURNAL-BIRTH--TIME:MAKE OPTION:SOME ;

: ROW-SUBVOLUME ( SQLITE:statement str -- SQLITE:statement option<n> )
   {: path:str :}
   4 SQLITE:COL-NULL? if NO-SUBVOLUME exit then
   4 s" read local root subvolume" >str path BLOB-U64 OPTION:SOME ;

: ROW-GENERATION ( SQLITE:statement str -- SQLITE:statement n )
   {: db:str :}
   5 SQLITE:COL-INT {: g :}
   g 0 < if
      s" read local root generation" >str db
      s" local root generation is outside the supported range" >str
      INVALID
   then
   g ;

\ The path a failure names is the row's own, the generation's the
\ journal's.
: ROOT-COLS
   ( SQLITE:statement ^ARENA:arena str
     -- SQLITE:statement local-root-record )
   {: ar db:str :}
   0 ar BLOB-COPY {: p:str :}
   p ROW-BIRTH {: birth :}
   p ROW-SUBVOLUME {: sub :}
   1 s" read local root inode" >str p BLOB-U64 {: inode :}
   db ROW-GENERATION {: g :}
   p inode birth sub JOURNAL-LOCAL--ROOT--BINDING:MAKE
   g JOURNAL-LOCAL--ROOT--RECORD:MAKE ;

: ROOT-ROW
   ( ^ARENA:arena str SQLITE:statement
     -- option<local-root-record> SQLITE:statement )
   -rot {: ar db:str :}
   SQLITE:STEP 0= if NO-RECORD swap exit then
   ar db ROOT-COLS OPTION:SOME swap ;

public

\ The active root's identity and generation, if a root was activated.
: LOCAL-ROOT-BINDING ( journal ^ARENA:arena -- option<local-root-record> )
   {: j ar :}
   ar j >PATH j >CONNECTION SELECT-ROOT [: ROOT-ROW ;]
   SQLITE:WITH-STATEMENT ;

private


\ ---- activation ----------------------------------------------------

\ A new root carries none of the old one's history: live plans, their
\ recovery intents, baselines, observations, hashes and conflicts go.
: RETIRE ( SQLITE:connection -- )
   s" DELETE FROM recovery_records
      WHERE status = 'pending' OR operation_id IN (
         SELECT operations.id FROM operations
         JOIN plans ON plans.id = operations.plan_id
         WHERE plans.status IN ('pending', 'blocked')
      );
      DELETE FROM operations WHERE plan_id IN (
         SELECT id FROM plans WHERE status IN ('pending', 'blocked')
      );
      DELETE FROM plans WHERE status IN ('pending', 'blocked');
      DELETE FROM baselines;
      DELETE FROM local_observations;
      DELETE FROM local_hash_cache;
      DELETE FROM conflicts;
      DELETE FROM legacy_local_root_adoption WHERE singleton = 1;"
   SQLITE:EXEC ;

\ A generation past SQLite's integer range is never written.
: NEXT-GENERATION ( option<local-root-record> str -- n )
   {: db:str :}
   MATCH option
      none OF 1 ENDOF
      some OF
         >GENERATION {: g :}
         g INT-MAX = if
            s" write local root binding" >str db
            s" local root generation exceeds SQLite integer range" >str
            INVALID
         then
         g 1 +
      ENDOF
   ;MATCH ;

: ACTIVATE-NEW-LOCAL-ROOT
   ( option<local-root-record> local-root-binding journal
     -- local-root-record )
   {: b j :}
   j >PATH NEXT-GENERATION {: g :}
   j >CONNECTION {: c :}
   c RETIRE
   b g JOURNAL-LOCAL--ROOT--RECORD:MAKE {: r :}
   c r WRITE-LOCAL-ROOT
   r ;

: FRESH
   ( option<local-root-record> local-root-binding journal
     -- local-root-activation )
   ACTIVATE-NEW-LOCAL-ROOT construct local-root-activation activated ;

\ The legacy root's identity rewritten, its generation and state kept.
: UPGRADED
   ( local-root-record local-root-binding journal
     -- local-root-activation )
   {: r b j :}
   b r >GENERATION JOURNAL-LOCAL--ROOT--RECORD:MAKE {: u :}
   j >CONNECTION u WRITE-LOCAL-ROOT
   u construct local-root-activation current ;

: UPGRADE-OR-FRESH
   ( local-root-record local-root-binding journal
     -- local-root-activation )
   {: r b j :}
   r >BINDING b UPGRADES-LEGACY-ROOT? if r b j UPGRADED exit then
   r OPTION:SOME b j FRESH ;

\ A schema-6 root that binding inspected again is upgraded in place;
\ otherwise a new generation starts.
: ACTIVATE-OR-UPGRADE-LOCAL-ROOT
   ( option<local-root-record> local-root-binding journal
     -- local-root-activation )
   {: b j :}
   MATCH option
      none OF NO-RECORD b j FRESH ENDOF
      some OF b j UPGRADE-OR-FRESH ENDOF
   ;MATCH ;

: RECORDED-OUTCOME
   ( local-root-record local-root-binding
     -- option<local-root-activation> )
   {: r b :}
   r >BINDING {: recorded :}
   recorded b ROOT= if
      r construct local-root-activation current OPTION:SOME exit
   then
   recorded b UPGRADES-LEGACY-ROOT? if NO-ACTIVATION exit then
   recorded ROOT-PATH b ROOT-PATH SAME? if
      recorded b construct local-root-activation unavailable
      OPTION:SOME exit
   then
   NO-ACTIVATION ;

\ The outcome the recorded root decides with no write, if any.
: LOCAL-ROOT-ACTIVATION-WITHOUT-WRITE
   ( option<local-root-record> local-root-binding
     -- option<local-root-activation> )
   {: b :}
   MATCH option
      none OF NO-ACTIVATION ENDOF
      some OF b RECORDED-OUTCOME ENDOF
   ;MATCH ;

: UNCHANGED
   ( local-root-record local-root-binding
     -- option<local-root-activation> )
   {: r b :}
   r >BINDING b ROOT= if
      r construct local-root-activation current OPTION:SOME exit
   then
   NO-ACTIVATION ;

\ The current record when it holds binding, if any.
: ADOPTION-WITHOUT-WRITE
   ( option<local-root-record> local-root-binding
     -- option<local-root-activation> )
   {: b :}
   MATCH option
      none OF NO-ACTIVATION ENDOF
      some OF b UNCHANGED ENDOF
   ;MATCH ;

\ The decision of keep, read again inside the transaction, else the
\ write.
: SETTLED
   ( journal local-root-binding ^ARENA:arena
     [ option<local-root-record> local-root-binding
       -- option<local-root-activation> ]
     -- local-root-activation )
   {: j b ar keep :}
   j ar LOCAL-ROOT-BINDING {: existing :}
   existing b keep execute MATCH option
      some OF ENDOF
      none OF existing b j ACTIVATE-OR-UPGRADE-LOCAL-ROOT ENDOF
   ;MATCH ;

\ keep's decision on the recorded root, else SETTLED's in one
\ transaction.
: ACTIVATING
   ( journal local-root-binding ^ARENA:arena
     [ option<local-root-record> local-root-binding
       -- option<local-root-activation> ]
     -- local-root-activation )
   {: j b ar keep :}
   j ar LOCAL-ROOT-BINDING b keep execute MATCH option
      some OF ENDOF
      none OF
         j >CONNECTION [: j b ar keep SETTLED ;]
         SQLITE:WITH-TRANSACTION
      ENDOF
   ;MATCH ;

public

\ Activates the root without carrying another root's deletion history
\ into it.
: ACTIVATE-LOCAL-ROOT
   ( journal local-root-binding ^ARENA:arena -- local-root-activation )
   [: LOCAL-ROOT-ACTIVATION-WITHOUT-WRITE ;] ACTIVATING ;

\ Adopts the root the user selected, a replacement at the same path
\ included.
: ADOPT-LOCAL-ROOT
   ( journal local-root-binding ^ARENA:arena -- local-root-activation )
   [: ADOPTION-WITHOUT-WRITE ;] ACTIVATING ;


\ ---- inventories ---------------------------------------------------

public

\ The committed cursor, none before a first publication, and every
\ observation, in key order.
STRUCTURE remote-inventory
   FIELD cursor option<DROPBOX:cursor>
   FIELD observations ^VEC:vector<MODEL:remote-record>
;STRUCTURE

\ One step of a validated cursor continuation. upsert writes a key's
\ path and observation; ensure-directory adds a missing ancestor, a
\ stored one keeping its path, and its observation when that is unknown;
\ delete-subtree removes a key and every key beneath it.
ENUM remote-inventory-change
   VARIANT upsert FIELD record MODEL:remote-record ;VARIANT
   VARIANT ensure-directory FIELD record MODEL:remote-record ;VARIANT
   VARIANT delete-subtree FIELD key MODEL:key ;VARIANT
;ENUM

\ A remote directory's key and display path.
STRUCTURE remote-directory
   FIELD key MODEL:key
   FIELD path MODEL:path
;STRUCTURE

private

1 TASK:+USERS ENCODER JSON:writer
BUF:HDR-BYTES TASK:+USERS ENCODED u8
256 constant ENCODED-CAP


\ ---- stored columns ------------------------------------------------

: PATH-BYTES ( MODEL:path -- ^u8 n ) MODEL:PATH>STR str> ;

: BYTES-PATH ( ^u8 n ^ARENA:arena -- MODEL:path ) COPIED MODEL:>PATH ;

: KEY-BYTES ( MODEL:key -- ^u8 n ) MODEL:KEY>STR str> ;

: BYTES-KEY ( ^u8 n ^ARENA:arena -- MODEL:key ) COPIED MODEL:>KEY ;

: ON-BUFFER ( R ^n [ R ^JSON:writer -- S ] -- S )
   {: buf body :}
   0 ENCODER buf JSON:WRITE-OPEN-BUF body execute ;

\ Runs body on the task's JSON writer, whose buffer is freed after.
: ENCODING ( R [ R ^JSON:writer -- S ] -- S )
   {: body :}
   0 ENCODED CELL-VIEW {: buf :}
   buf ENCODED-CAP BUF:N>BLEN BUF:INIT
   buf body [: ON-BUFFER ;] [: buf BUF:DISPOSE ;] finally ;

\ The JSON `write` puts on the writer, until the writer's next use.
: ENCODE ( ^JSON:writer [ ^JSON:writer -- ^JSON:writer ] -- ^u8 n )
   {: w write :}
   w JSON:WRITE-RESET write execute JSON:WRITTEN$ ;

: UNPROCESSED ( str str -- )
   {: op:str path:str :}
   op OPERATION s" could not process the record for `" LOG:TEXT+
   path STR+ s" `" LOG:TEXT+ LOG:;LINE
   E-JSON throw ;

\ Runs a MODEL read that replaces the seed it is given; a stored value
\ MODEL cannot read is op's E-JSON on path.
: DECODE ( R [ R -- R ] str str -- R )
   {: read op:str path:str :}
   [: read execute ;] catch {: code :}
   code 0= if exit then
   code MODEL:E-STORED <> if code throw then
   op path UNPROCESSED ;

: HEX-DIGIT? ( u8 -- bool )
   {: c :}
   c 48 >= c 57 <= and c 97 >= c 102 <= and or ;

\ Dropbox's content hash: 64 lower-case hex digits.
: DROPBOX-CONTENT-HASH? ( DROPBOX:hash -- bool )
   DROPBOX:HASH>STR str> {: a:^ u :}
   u 64 <> if false exit then
   true u 0 ?do a i + c@ HEX-DIGIT? and loop ;

: NOT-CONTENT-HASH ( str str -- )
   {: op:str path:str :}
   op path
   s" cached content identity is not a Dropbox content hash" >str
   INVALID ;


\ ---- reading -------------------------------------------------------

\ A seed's typed drop, which types the read that replaces it.
: DROP-LOCAL ( MODEL:observation<MODEL:local> -- ) drop ;
: DROP-REMOTE ( MODEL:observation<MODEL:remote> -- ) drop ;
: DROP-FINGERPRINT ( MODEL:fingerprint -- ) drop ;
: DROP-HASH ( DROPBOX:hash -- ) drop ;

: NO-FINGERPRINT ( -- MODEL:fingerprint )
   0 0 0 0 0 0 MODEL-FINGERPRINT:MAKE ;

: NO-HASH ( -- DROPBOX:hash ) s" " >str DROPBOX:>HASH ;

: NO-CURSOR ( -- option<DROPBOX:cursor> ) OPTION:NONE ;

: LOCAL-OBSERVATION-OF
   ( str str ^ARENA:arena -- MODEL:observation<MODEL:local> )
   {: json:str path:str ar :}
   MODEL-OBSERVATION:directory
   [: DROP-LOCAL json ar MODEL:JSON>LOCAL-OBSERVATION ;]
   s" deserialize local observation" >str path DECODE ;

: REMOTE-OBSERVATION-OF
   ( str str ^ARENA:arena -- MODEL:observation<MODEL:remote> )
   {: json:str path:str ar :}
   MODEL-OBSERVATION:directory
   [: DROP-REMOTE json ar MODEL:JSON>REMOTE-OBSERVATION ;]
   s" deserialize remote observation" >str path DECODE ;

: HASH-VALUE-OF
   ( str str ^ARENA:arena -- MODEL:fingerprint DROPBOX:hash )
   {: json:str path:str ar :}
   NO-FINGERPRINT NO-HASH
   [: DROP-HASH DROP-FINGERPRINT json ar MODEL:JSON>HASH-VALUE ;]
   s" deserialize local hash cache" >str path DECODE ;

: LOCAL-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement MODEL:local-record )
   {: ar :}
   0 SQLITE:COL-BLOB ar BYTES-PATH {: p:MODEL:path :}
   1 SQLITE:COL-TEXT >str p MODEL:PATH>STR ar LOCAL-OBSERVATION-OF
   {: o :}
   p o MODEL-LOCAL--RECORD:MAKE ;

: HASH-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement MODEL:hash-record )
   {: ar :}
   0 SQLITE:COL-BLOB ar BYTES-PATH {: p:MODEL:path :}
   1 SQLITE:COL-TEXT >str p MODEL:PATH>STR ar HASH-VALUE-OF
   {: f h :}
   h DROPBOX-CONTENT-HASH? 0= if
      s" read local hash cache" >str p MODEL:PATH>STR NOT-CONTENT-HASH
   then
   p f h MODEL-HASH--RECORD:MAKE ;

: REMOTE-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement MODEL:remote-record )
   {: ar :}
   0 SQLITE:COL-BLOB ar BYTES-KEY {: k:MODEL:key :}
   1 SQLITE:COL-BLOB ar BYTES-PATH {: p:MODEL:path :}
   2 SQLITE:COL-TEXT >str p MODEL:PATH>STR ar REMOTE-OBSERVATION-OF
   {: o :}
   k p o MODEL-REMOTE--RECORD:MAKE ;

: DIRECTORY-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement remote-directory )
   {: ar :}
   0 SQLITE:COL-BLOB ar BYTES-KEY {: k:MODEL:key :}
   1 SQLITE:COL-BLOB ar BYTES-PATH {: p:MODEL:path :}
   k p JOURNAL-REMOTE--DIRECTORY:MAKE ;

: CURSOR-ROW
   ( ^ARENA:arena SQLITE:statement
     -- option<DROPBOX:cursor> SQLITE:statement )
   swap {: ar :}
   SQLITE:STEP 0= if NO-CURSOR swap exit then
   0 ar TEXT-COPY DROPBOX:>CURSOR OPTION:SOME swap ;

: READ-LOCAL-INVENTORY
   ( SQLITE:connection ^ARENA:arena
     -- ^VEC:vector<MODEL:local-record> )
   {: c ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:local-record VEC:NEW {: v :}
   c s" SELECT path, observation_json FROM local_observations
      ORDER BY path"
   [: begin SQLITE:STEP while ar LOCAL-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

\ The hashes of the active root's generation.
: READ-LOCAL-HASH-CACHE
   ( SQLITE:connection ^ARENA:arena
     -- ^VEC:vector<MODEL:hash-record> )
   {: c ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:hash-record VEC:NEW {: v :}
   c s" SELECT cache.path, cache.hash_json
      FROM local_hash_cache AS cache
      JOIN local_root_binding AS root
         ON root.singleton = 1 AND cache.root_generation = root.generation
      ORDER BY cache.path"
   [: begin SQLITE:STEP while ar HASH-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

: READ-REMOTE-OBSERVATIONS
   ( SQLITE:connection ^ARENA:arena
     -- ^VEC:vector<MODEL:remote-record> )
   {: c ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: v :}
   c s" SELECT canonical_path, path, observation_json
      FROM remote_observations ORDER BY canonical_path"
   [: begin SQLITE:STEP while ar REMOTE-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

public

\ The hashes verified for the active root, by path.
: LOCAL-HASH-CACHE
   ( journal ^ARENA:arena -- ^VEC:vector<MODEL:hash-record> )
   {: j ar :}
   j >CONNECTION ar READ-LOCAL-HASH-CACHE ;

\ The committed local inventory, by path.
: LOCAL-INVENTORY
   ( journal ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: j ar :}
   j >CONNECTION ar READ-LOCAL-INVENTORY ;

\ The committed cursor, without the inventory.
: REMOTE-CURSOR ( journal ^ARENA:arena -- option<DROPBOX:cursor> )
   {: j ar :}
   ar j >CONNECTION
   s" SELECT cursor FROM remote_inventory WHERE singleton = 1"
   [: CURSOR-ROW ;] SQLITE:WITH-STATEMENT ;

\ The directories and restricted folders Dropbox holds, by key.
: REMOTE-DIRECTORY-PATHS
   ( journal ^ARENA:arena -- ^VEC:vector<remote-directory> )
   {: j ar :}
   ar ARENA:ALLOCATOR 0 [type] remote-directory VEC:NEW {: v :}
   j >CONNECTION
   s\" SELECT canonical_path, path FROM remote_observations
      WHERE observation_json IN
         ('\"Directory\"', '{\"Unknown\":\"Inaccessible\"}')
      ORDER BY canonical_path"
   [: begin SQLITE:STEP while ar DIRECTORY-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

private

: SNAPSHOT ( journal ^ARENA:arena -- remote-inventory )
   {: j ar :}
   j ar REMOTE-CURSOR
   j >CONNECTION ar READ-REMOTE-OBSERVATIONS
   JOURNAL-REMOTE--INVENTORY:MAKE ;

public

\ The cursor and the inventory it produced, read as one snapshot.
: REMOTE-INVENTORY ( journal ^ARENA:arena -- remote-inventory )
   {: j ar :}
   j >CONNECTION [: j ar SNAPSHOT ;] SQLITE:WITH-READ ;

private


\ ---- the local scan ------------------------------------------------

: INSERT-LOCAL ( -- ^u8 n )
   s" INSERT INTO local_observations(path, observation_json)
      VALUES (?1, ?2)" ;

: INSERT-HASH ( -- ^u8 n )
   s" INSERT INTO local_hash_cache(root_generation, path, hash_json)
      VALUES (?1, ?2, ?3)" ;

\ Runs the statement's row, reset for the next.
: RAN ( SQLITE:statement -- SQLITE:statement )
   SQLITE:STEP drop SQLITE:RESET ;

: LOCAL-INSERTED
   ( SQLITE:statement MODEL:local-record ^JSON:writer
     -- SQLITE:statement )
   {: r w :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   p PATH-BYTES 1 SQLITE:BIND-BLOB
   w [: o swap MODEL:LOCAL-OBSERVATION>JSON ;] ENCODE 2 SQLITE:BIND-TEXT
   RAN ;

: LOCAL-INSERTS
   ( SQLITE:statement ^VEC:vector<MODEL:local-record> ^JSON:writer
     -- SQLITE:statement )
   {: v w :}
   v VEC:COUNT 0 ?do v i VEC:AT @ w LOCAL-INSERTED loop ;

\ A hash that is not Dropbox's is never cached.
: HASH-INSERTED
   ( SQLITE:statement n MODEL:hash-record ^JSON:writer
     -- SQLITE:statement )
   {: g r w :}
   r MODEL-HASH--RECORD:UNMAKE {: p:MODEL:path f h :}
   h DROPBOX-CONTENT-HASH? 0= if
      s" publish local hash cache" >str p MODEL:PATH>STR
      NOT-CONTENT-HASH
   then
   g 1 SQLITE:BIND-INT
   p PATH-BYTES 2 SQLITE:BIND-BLOB
   w [: r swap MODEL:HASH-VALUE>JSON ;] ENCODE 3 SQLITE:BIND-TEXT
   RAN ;

: HASH-INSERTS
   ( SQLITE:statement n ^VEC:vector<MODEL:hash-record> ^JSON:writer
     -- SQLITE:statement )
   {: g v w :}
   v VEC:COUNT 0 ?do g v i VEC:AT @ w HASH-INSERTED loop ;

: LOCAL-RECORDS=
   ( ^VEC:vector<MODEL:local-record> ^VEC:vector<MODEL:local-record>
     -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   true a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ MODEL:LOCAL-RECORD= and
   loop ;

: HASH-RECORDS=
   ( ^VEC:vector<MODEL:hash-record> ^VEC:vector<MODEL:hash-record>
     -- bool )
   {: a b :}
   a VEC:COUNT b VEC:COUNT <> if false exit then
   true a VEC:COUNT 0 ?do
      a i VEC:AT @ b i VEC:AT @ MODEL:HASH-RECORD= and
   loop ;

: SCAN-UNCHANGED?
   ( SQLITE:connection ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> ^ARENA:arena -- bool )
   {: c obs hashes ar :}
   c ar READ-LOCAL-INVENTORY obs LOCAL-RECORDS= 0= if false exit then
   c ar READ-LOCAL-HASH-CACHE hashes HASH-RECORDS= ;

\ g, the generation, was read as an SQLite integer, so it binds as one.
: SCAN-WRITTEN
   ( SQLITE:connection n ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> ^JSON:writer -- )
   {: c g obs hashes w :}
   c s" DELETE FROM local_observations" SQLITE:EXEC
   c s" DELETE FROM local_hash_cache" SQLITE:EXEC
   c INSERT-LOCAL [: obs w LOCAL-INSERTS ;] SQLITE:WITH-STATEMENT
   c INSERT-HASH [: g hashes w HASH-INSERTS ;] SQLITE:WITH-STATEMENT ;

: ACTIVE-SCAN
   ( local-root-record journal local-root-binding
     ^VEC:vector<MODEL:local-record> ^VEC:vector<MODEL:hash-record>
     ^ARENA:arena -- bool )
   {: r j b obs hashes ar :}
   r >BINDING b ROOT= 0= if false exit then
   j >CONNECTION {: c :}
   c obs hashes ar SCAN-UNCHANGED? if true exit then
   c r >GENERATION obs hashes [: SCAN-WRITTEN ;] ENCODING
   true ;

: SCAN-PUBLISHED
   ( journal local-root-binding ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> ^ARENA:arena -- bool )
   {: j b obs hashes ar :}
   j ar LOCAL-ROOT-BINDING MATCH option
      none OF false ENDOF
      some OF j b obs hashes ar ACTIVE-SCAN ENDOF
   ;MATCH ;

public

\ Replaces the local inventory and its hash cache in one transaction;
\ false, nothing written, when binding is no longer the active root.
: PUBLISH-LOCAL-SCAN
   ( journal local-root-binding ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> -- bool )
   {: j b obs hashes :}
   j >CONNECTION [: j b obs hashes [: SCAN-PUBLISHED ;] ARENA:WITH ;]
   SQLITE:WITH-TRANSACTION ;

private


\ ---- the remote inventory ------------------------------------------

: INSERT-REMOTE ( -- ^u8 n )
   s" INSERT INTO remote_observations(
         path, observation_json, canonical_path
      ) VALUES (?1, ?2, ?3)" ;

: UPSERT-REMOTE ( -- ^u8 n )
   s" INSERT INTO remote_observations(
         path, observation_json, canonical_path
      ) VALUES (?1, ?2, ?3)
      ON CONFLICT(canonical_path) DO UPDATE SET
         path = excluded.path,
         observation_json = excluded.observation_json
      WHERE path != excluded.path
         OR observation_json != excluded.observation_json" ;

: ENSURE-REMOTE ( -- ^u8 n )
   s" INSERT INTO remote_observations(
         path, observation_json, canonical_path
      ) VALUES (?1, ?2, ?3)
      ON CONFLICT(canonical_path) DO UPDATE SET
         observation_json = excluded.observation_json
      WHERE observation_json != excluded.observation_json
         AND json_type(
            remote_observations.observation_json, '$.Unknown'
         ) IS NULL" ;

: DELETE-REMOTE-DESCENDANTS ( -- ^u8 n )
   s" DELETE FROM remote_observations
      WHERE canonical_path >= ?1 AND canonical_path < ?2" ;

\ Binds the record's path, observation and key to ?1, ?2 and ?3.
: BIND-REMOTE
   ( SQLITE:statement MODEL:remote-record ^JSON:writer
     -- SQLITE:statement )
   {: r w :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   p PATH-BYTES 1 SQLITE:BIND-BLOB
   w [: o swap MODEL:REMOTE-OBSERVATION>JSON ;] ENCODE 2 SQLITE:BIND-TEXT
   k KEY-BYTES 3 SQLITE:BIND-BLOB ;

: REMOTE-INSERTS
   ( SQLITE:statement ^VEC:vector<MODEL:remote-record> ^JSON:writer
     -- SQLITE:statement )
   {: v w :}
   v VEC:COUNT 0 ?do v i VEC:AT @ w BIND-REMOTE RAN loop ;

: PUBLISH-CURSOR ( SQLITE:connection DROPBOX:cursor -- )
   {: c cur:DROPBOX:cursor :}
   c s" INSERT INTO remote_inventory(singleton, cursor) VALUES (1, ?1)
      ON CONFLICT(singleton) DO UPDATE SET cursor = excluded.cursor"
   [: cur DROPBOX:CURSOR>STR str> 1 SQLITE:BIND-TEXT RAN ;]
   SQLITE:WITH-STATEMENT ;

: REMOTE-WRITTEN
   ( SQLITE:connection DROPBOX:cursor
     ^VEC:vector<MODEL:remote-record> ^JSON:writer -- )
   {: c cur:DROPBOX:cursor v w :}
   c s" DELETE FROM remote_observations" SQLITE:EXEC
   c INSERT-REMOTE [: v w REMOTE-INSERTS ;] SQLITE:WITH-STATEMENT
   c cur PUBLISH-CURSOR ;

public

\ Replaces the remote inventory and its cursor in one transaction.
: PUBLISH-REMOTE-INVENTORY
   ( journal DROPBOX:cursor ^VEC:vector<MODEL:remote-record> -- )
   {: j cur:DROPBOX:cursor v :}
   j >CONNECTION {: c :}
   c [: c cur v [: REMOTE-WRITTEN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

private

: DELTA-INVALID ( str str -- )
   {: path:str detail:str :}
   s" validate remote inventory delta" >str path detail INVALID ;

\ An upserted or ensured record's key is its path's.
: CHECK-KEY ( MODEL:remote-record ^ARENA:arena -- )
   {: r ar :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   p ar MODEL:FOLD k MODEL:KEY= if exit then
   p MODEL:PATH>STR
   s" canonical path does not match display path" >str DELTA-INVALID ;

: REMOTE-DIRECTORY ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:directory ;

: DIRECTORY? ( MODEL:remote-record -- bool )
   MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   o REMOTE-DIRECTORY MODEL:REMOTE-OBSERVATION= ;

: CHECK-ENSURED ( MODEL:remote-record ^ARENA:arena -- )
   {: r ar :}
   r ar CHECK-KEY
   r DIRECTORY? if exit then
   r MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   p MODEL:PATH>STR
   s" ensured remote ancestor is not a directory" >str DELTA-INVALID ;

: CHECK-SUBTREE ( MODEL:key -- )
   {: k:MODEL:key :}
   k KEY-BYTES nip 0<> if exit then
   k MODEL:KEY>STR
   s" subtree deletion path is empty" >str DELTA-INVALID ;

: CHECK-CHANGE ( remote-inventory-change ^ARENA:arena -- )
   {: ar :}
   MATCH remote-inventory-change
      upsert OF ar CHECK-KEY ENDOF
      ensure-directory OF ar CHECK-ENSURED ENDOF
      delete-subtree OF CHECK-SUBTREE ENDOF
   ;MATCH ;

: DELTA-CHECKED
   ( ^VEC:vector<remote-inventory-change> ^ARENA:arena -- )
   {: v ar :}
   v VEC:COUNT 0 ?do v i VEC:AT @ ar CHECK-CHANGE loop ;

\ The record written by the statement sql names.
: RECORD-WRITTEN
   ( SQLITE:connection MODEL:remote-record ^JSON:writer ^u8 n -- )
   {: c r w sql:^ u :}
   c sql u [: r w BIND-REMOTE SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: SUBTREE-DELETED ( SQLITE:connection MODEL:key ^ARENA:arena -- )
   {: c k:MODEL:key ar :}
   c s" DELETE FROM remote_observations WHERE canonical_path = ?1"
   [: k KEY-BYTES 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   k ar MODEL:SUBTREE-RANGE {: lo:str hi:str :}
   c DELETE-REMOTE-DESCENDANTS
   [: lo str> 1 SQLITE:BIND-BLOB hi str> 2 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: CHANGE-APPLIED
   ( remote-inventory-change SQLITE:connection ^JSON:writer
     ^ARENA:arena -- )
   {: c w ar :}
   MATCH remote-inventory-change
      upsert OF {: r :} c r w UPSERT-REMOTE RECORD-WRITTEN ENDOF
      ensure-directory OF
         {: r :} c r w ENSURE-REMOTE RECORD-WRITTEN
      ENDOF
      delete-subtree OF {: k :} c k ar SUBTREE-DELETED ENDOF
   ;MATCH ;

: DELTA-WRITTEN
   ( SQLITE:connection DROPBOX:cursor
     ^VEC:vector<remote-inventory-change> ^ARENA:arena
     ^JSON:writer -- )
   {: c cur:DROPBOX:cursor v ar w :}
   v VEC:COUNT 0 ?do v i VEC:AT @ c w ar CHANGE-APPLIED loop
   c cur PUBLISH-CURSOR ;

\ Every change is checked before the transaction begins.
: DELTA-APPLIED
   ( SQLITE:connection DROPBOX:cursor
     ^VEC:vector<remote-inventory-change> ^ARENA:arena -- )
   {: c cur:DROPBOX:cursor v ar :}
   v ar DELTA-CHECKED
   c [: c cur v ar [: DELTA-WRITTEN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

public

\ Applies a cursor continuation's changes, in order, and publishes its
\ cursor, in one transaction.
: APPLY-REMOTE-INVENTORY-DELTA
   ( journal DROPBOX:cursor ^VEC:vector<remote-inventory-change> -- )
   {: j cur:DROPBOX:cursor v :}
   j >CONNECTION cur v [: DELTA-APPLIED ;] ARENA:WITH ;

;package
