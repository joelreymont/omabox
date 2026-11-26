\ journal.f - package JOURNAL: the sync journal, a SQLite file at schema 14
\ (rust src/journal.rs at schema 8), and the Dropbox account and local root
\ it is bound to. OPEN makes the file 0600 without following a link,
\ creates schema 14 in a new one and migrates schema 8 to 13 to it, each
\ in one transaction, from migrations/, whose texts this file lays in the
\ program as it loads; any version but 0 and 8 to 14 is refused
\ unchanged, and OPEN-READ refuses any but 14. A SQLite failure is
\ SQLITE's throw, passed up unchanged. JOURNAL's own failures are logged
\ once with the Rust version's text, then thrown as its codes. E-FILE,
\ E-DISK-FULL and E-ROOT leave the host errno in FS:ERRNO, 0 where there
\ is none; E-DISK-FULL is E-FILE on ENOSPC.
\ A root binding is the root's inode, birth time and subvolume: btrfs gives
\ a subvolume a new device number at every mount, so the device is none
\ of it. A binding with no birth time is one a version-6 journal recorded;
\ an activation whose path and inode match it upgrades it in place.
\ A baseline, a plan, a conflict, a conflict block and a local
\ observation are keyed by the canonical path MODEL:FOLD gives the
\ display path. A baseline, a remote and a local observation, a hash
\ record and an upload session are stored in typed columns; every other
\ stored value is written and read by MODEL's JSON words. A value MODEL
\ cannot read, a version-nine baseline or remote observation refusing
\ the migration included, is logged with the record's path and its
\ cause and thrown as E-JSON; a version-nine local observation is kept
\ as unknown, and a version-nine hash cache row that does not convert is
\ dropped.
\ Each write to the file is one immediate transaction, and the remote
\ cursor and inventory are read in one deferred one.
\ A local scan merges the walk, in path byte order, with the stored local
\ inventory and hash cache, and stages in the connection's temporary
\ tables only what differs: the rows that changed and the paths and
\ hashes gone. Its publish applies them in SQL, so an unchanged row keeps
\ its rowid and an unchanged scan writes nothing.
\ A full listing stages its changes in temporary tables too, a batch per
\ transaction, as the rows they leave; its publish streams those rows
\ into the remote inventory, each path spelled at every part by the
\ folder staged at the key up to it.
\ STORAGE CLASS. CALLER-OWNED: a journal OPEN makes borrows its path
\ until CLOSE, and a binding INSPECT answers borrows its path; every
\ string and vector a reader answers lies in the arena the caller passes.
\ A journal belongs to the task that opened it. TASK-LOCAL: the bytes a
\ root's inode and subvolume are bound from, and the JSON writer and
\ buffer a write encodes with, TASK:+USERS rows.

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
require src/lib/fsm.f
require src/lib/type/deftype.f
require src/lib/byte-buffer.f
require src/lib/vector.f
require src/lib/heap.f
require src/lib/json/write.f
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
-100305 s" sync root could not be opened or inspected"
   ERROR:CODE E-ROOT
-100306 s" journal operation found the disk full" ERROR:CODE E-DISK-FULL

\ The connection and the name its logs give.
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

14 constant SCHEMA
5000 constant BUSY-MS
$180 constant MODE-OWNER            \ 0600
$1FF constant MODE-BITS
$7FFFFFFFFFFFFFFF constant INT-MAX  \ SQLite's largest integer
1000000000 constant NS-PER-S

\ A stored kind, the number MODEL gives an observation's form; an
\ unknown observation's is 3 plus its reason's index.
0 constant KIND-PRESENT
1 constant KIND-DIRECTORY
2 constant KIND-ABSENT

16 TASK:+USERS ID-ROW u8


\ ---- stored rows ---------------------------------------------------

: BYTES-PATH ( str ^ARENA:arena -- MODEL:path ) ARENA:COPY MODEL:>PATH ;

\ Runs the statement's row, reset for the next.
: RAN ( SQLITE:statement -- SQLITE:statement )
   SQLITE:STEP drop SQLITE:RESET ;

: REASON-KIND ( MODEL:unknown-reason -- n )
   MATCH MODEL:unknown-reason
      incomplete OF 3 ENDOF
      inaccessible OF 4 ENDOF
      unavailable OF 5 ENDOF
      stale OF 6 ENDOF
      cursor-reset OF 7 ENDOF
      unsupported OF 8 ENDOF
   ;MATCH ;

\ The reason of an unknown kind, 3 to 8.
: KIND-REASON ( n -- MODEL:unknown-reason )
   case
      3 of MODEL-UNKNOWN--REASON:INCOMPLETE endof
      4 of MODEL-UNKNOWN--REASON:INACCESSIBLE endof
      5 of MODEL-UNKNOWN--REASON:UNAVAILABLE endof
      6 of MODEL-UNKNOWN--REASON:STALE endof
      7 of MODEL-UNKNOWN--REASON:CURSOR-RESET endof
      MODEL-UNKNOWN--REASON:UNSUPPORTED swap
   endcase ;

\ Binds a file's kind, content and revision to ?3 to ?5.
: BIND-PRESENT ( SQLITE:statement MODEL:remote -- SQLITE:statement )
   MODEL-REMOTE:UNMAKE {: h v :}
   KIND-PRESENT 3 SQLITE:BIND-INT
   h DROPBOX:HASH>STR 4 SQLITE:BIND-TEXT
   v DROPBOX:REV>STR 5 SQLITE:BIND-TEXT ;

\ Binds the kind to ?3, and NULL content and revision to ?4 and ?5.
: BIND-KIND ( SQLITE:statement n -- SQLITE:statement )
   3 SQLITE:BIND-INT 4 SQLITE:BIND-NULL 5 SQLITE:BIND-NULL ;

\ Migration 9's insert, into schema 9's JSON table.
: INSERT-LOCAL ( -- str )
   s" INSERT INTO local_observations(
         path, observation_json, canonical_path
      ) VALUES (?1, ?2, ?3)" ;

\ Binds the path's canonical_path to ?3, for INSERT-LOCAL and
\ OBSERVE-SCAN.
: BIND-KEY
   ( SQLITE:statement MODEL:path ^ARENA:arena -- SQLITE:statement )
   MODEL:FOLD MODEL:KEY>STR 3 SQLITE:BIND-BLOB ;


\ ---- migrations ----------------------------------------------------

\ Lays the file's length, then its bytes, in the word just created. Its
\ name precedes the create: a top-level string is itself laid at here.
: LAY ( str -- )
   SOURCE-ROOT:RESOLVE drop {: p :}
   p FS:FILE-SIZE {: size :}
   size ,
   p here size FS:READ-ALL drop
   size allot align ;


s" migrations/0001.sql" create V1 LAY
s" migrations/0002.sql" create V2 LAY
s" migrations/0003.sql" create V3 LAY
s" migrations/0004.sql" create V4 LAY
s" migrations/0005.sql" create V5 LAY
s" migrations/0006.sql" create V6 LAY
s" migrations/0007.sql" create V7 LAY
s" migrations/0008.sql" create V8 LAY
s" migrations/0009.sql" create V9 LAY
s" migrations/0010.sql" create V10 LAY
s" migrations/0011.sql" create V11 LAY
s" migrations/0012.sql" create V12 LAY
s" migrations/0013.sql" create V13 LAY
s" migrations/0014.sql" create V14 LAY

: TEXT ( ^n -- str )
   {: p:^n :}
   p CELL + BYTE-VIEW p @ >str ;

: RUN ( SQLITE:connection ^n -- ) TEXT SQLITE:EXEC ;


\ ---- failures ------------------------------------------------------

: LOG-OPEN ( -- ) LOG:ERROR s" journal" LOG:LINE ;

: OPERATION ( str -- )
   LOG-OPEN s" journal operation `" LOG:TEXT+ LOG:TEXT+ s" ` " LOG:TEXT+ ;

: FAILED-FOR ( str str -- )
   {: op:str path:str :}
   op OPERATION s" failed for `" LOG:TEXT+ path LOG:TEXT+ s" `: " LOG:TEXT+ ;

\ Logs op's failure on path, caused by errno, else by code.
: LOG-FAILED ( str str n n -- )
   {: op:str path:str code errno :}
   op path FAILED-FOR
   errno 0= if code LOG:CODE+ else errno FS:ERRNO$ LOG:TEXT+ then
   LOG:;LINE errno FS:CAUSE! ;

: FILE-FAILED ( str str n n -- )
   dup FS:ENOSPC = {: full:bool :}
   LOG-FAILED full if E-DISK-FULL else E-FILE then throw ;

\ The sync root's failure, logged as FILE-FAILED logs one.
: ROOT-FAILED ( str str n n -- ) LOG-FAILED E-ROOT throw ;

: FILE-REFUSED ( str str str -- )
   {: op:str path:str why:str :}
   op path FAILED-FOR why LOG:TEXT+ LOG:;LINE
   0 FS:CAUSE! E-FILE throw ;

: INVALID ( str str str -- )
   {: op:str path:str detail:str :}
   op OPERATION s" found invalid state for `" LOG:TEXT+ path LOG:TEXT+
   s" `: " LOG:TEXT+ detail LOG:TEXT+ LOG:;LINE
   E-INVALID-STATE throw ;

\ op could not read path's stored value, as code says.
: UNPROCESSED ( n str str -- )
   {: code op:str path:str :}
   op OPERATION s" could not process the record for `" LOG:TEXT+
   path LOG:TEXT+ s" `: " LOG:TEXT+ code LOG:CODE+ LOG:;LINE
   E-JSON throw ;

: UNSUPPORTED ( str n -- )
   {: path:str found :}
   LOG-OPEN s" journal `" LOG:TEXT+ path LOG:TEXT+
   s" ` has unsupported schema version " LOG:TEXT+ found LOG:INT+
   s" ; supported version is " LOG:TEXT+ SCHEMA LOG:INT+ LOG:;LINE
   E-UNSUPPORTED-VERSION throw ;

: REFUSE-UNBORN ( str -- )
   LOG-OPEN s" sync root `" LOG:TEXT+ LOG:TEXT+
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
: QUERY-INT ( SQLITE:connection str -- n )
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
   path FS:TRY-LSTAT 0= if op path E-FS-STAT 0 FILE-FAILED then
   FS:STAT-MODE@ FS:S-IFMT and FS:S-IFREG = if exit then
   op path s" existing path is not a regular file" FILE-REFUSED ;

\ A new empty file only its owner may read, or the regular file there.
: OWNER-ONLY ( str -- )
   {: path:str :}
   s" create journal database" {: op:str :}
   FS:CAUSE-CLEAR
   false [: drop path s" " FS:ATOMIC-CREATE-PRIVATE ;] catch
   {: code :}
   code 0= if if exit then op path REGULAR exit then
   drop op path code FS:ERRNO FILE-FAILED ;

: DELETE-MODE? ( SQLITE:statement -- bool SQLITE:statement )
   SQLITE:STEP drop 0 SQLITE:COL-TEXT s" delete" STR:=CI swap ;

\ The daemon holds its connection for life, so the main database keeps
\ 128 KiB of pages and the temporary one 64 KiB, not SQLite's 2 MB each;
\ the OS page cache holds the rest.
\ The temporary database journals in memory, so a failed scan write
\ rolls back, and does not zero freed pages, which would journal every
\ page a pass's DELETE of its scan tables frees. temp.watches holds one
\ record per watched folder: its watch descriptor, journal path and mark.
: CONFIGURE-WRITABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   c s" PRAGMA cache_size = -128" SQLITE:EXEC
   c s" PRAGMA temp.cache_size = -64" SQLITE:EXEC
   c s" PRAGMA temp.journal_mode = MEMORY" SQLITE:EXEC
   c s" PRAGMA temp.secure_delete = OFF" SQLITE:EXEC
   c s" CREATE TABLE IF NOT EXISTS temp.watches(
         wd INTEGER PRIMARY KEY,
         path BLOB NOT NULL,
         mark INTEGER NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS temp.watches_path
         ON watches(path);
      CREATE INDEX IF NOT EXISTS temp.watches_stirred
         ON watches(path) WHERE mark = 1" SQLITE:EXEC
   c s" PRAGMA foreign_keys = ON" SQLITE:EXEC
   c s" PRAGMA main.journal_mode = DELETE" [: DELETE-MODE? ;]
   SQLITE:WITH-STATEMENT 0= if
      s" set rollback journal mode" j >PATH
      s" SQLite did not enable DELETE journal mode" INVALID
   then
   c s" PRAGMA synchronous = FULL" SQLITE:EXEC
   c s" PRAGMA synchronous" QUERY-INT 2 <> if
      s" verify SQLite synchronization" j >PATH
      s" SQLite did not enable FULL synchronization" INVALID
   then ;

\ The indexes and version the step after migration 4 leaves on
\ empty tables.
: CANONICAL-PATHS ( SQLITE:connection -- )
   s" CREATE UNIQUE INDEX baselines_by_canonical_path
         ON baselines(canonical_path);
      CREATE UNIQUE INDEX remote_observations_by_canonical_path
         ON remote_observations(canonical_path);
      CREATE INDEX plans_by_canonical_path ON plans(canonical_path);
      CREATE INDEX conflicts_by_canonical_path
         ON conflicts(canonical_path);
      PRAGMA user_version = 4;" SQLITE:EXEC ;

\ What the step around migration 6 leaves on empty tables.
: MIGRATE-BLOCKED-PLANS ( SQLITE:connection -- )
   {: c :}
   c s" DROP INDEX baselines_by_canonical_path;
      DROP INDEX remote_observations_by_canonical_path;" SQLITE:EXEC
   c V6 RUN
   c s" PRAGMA user_version = 6" SQLITE:EXEC ;

\ The top statement's row inserted through the one under it.
: LOCAL-COPIED
   ( SQLITE:statement SQLITE:statement ^ARENA:arena
     -- SQLITE:statement SQLITE:statement )
   {: ar :}
   0 SQLITE:COL-BLOB {: p:str :}
   1 SQLITE:COL-TEXT {: o:str :}
   swap p 1 SQLITE:BIND-BLOB o 2 SQLITE:BIND-TEXT
   p ar BYTES-PATH ar BIND-KEY RAN swap ;

: ROWS-COPIED
   ( SQLITE:statement SQLITE:statement ^ARENA:arena
     -- SQLITE:statement SQLITE:statement )
   {: ar :}
   begin SQLITE:STEP while ar LOCAL-COPIED ar ARENA:RESET repeat ;

\ Each schema-8 row inserted through the statement.
: ROWS-READ
   ( SQLITE:statement SQLITE:connection ^ARENA:arena
     -- SQLITE:statement )
   {: c ar :}
   c s" SELECT path, observation_json FROM local_observations_8" [: ar ROWS-COPIED ;] SQLITE:WITH-STATEMENT ;

: LOCALS-COPIED ( SQLITE:connection ^ARENA:arena -- )
   {: c ar :}
   c INSERT-LOCAL [: c ar ROWS-READ ;] SQLITE:WITH-STATEMENT ;

\ Migration 9: local observations keyed by canonical path, each row
\ copied with its path folded.
: MIGRATE-LOCAL-OBSERVATIONS ( SQLITE:connection -- )
   {: c :}
   c V9 RUN
   c [: LOCALS-COPIED ;] ARENA:WITH
   c s" DROP TABLE local_observations_8; PRAGMA user_version = 9"
   SQLITE:EXEC ;

\ The first converted row MODEL cannot read refuses the migration, as
\ op's failure.
: UNCONVERTED ( SQLITE:statement str -- SQLITE:statement )
   {: op:str :}
   SQLITE:STEP 0= if exit then
   0 SQLITE:COL-BLOB {: path:str :}
   MODEL:E-STORED op path UNPROCESSED ;

\ Migration 10: baselines, remote and local observations and the hash
\ cache in typed columns.
: MIGRATE-TYPED-COLUMNS ( SQLITE:connection -- )
   {: c :}
   c V10 RUN
   c s" SELECT path FROM converted_baselines WHERE kind IS NULL
      ORDER BY path LIMIT 1"
   [: s" deserialize baseline" UNCONVERTED ;] SQLITE:WITH-STATEMENT
   c s" SELECT path FROM converted_remote_observations
      WHERE kind IS NULL ORDER BY path LIMIT 1"
   [: s" deserialize remote observation" UNCONVERTED ;]
   SQLITE:WITH-STATEMENT
   c s" DROP TABLE converted_baselines;
      DROP TABLE converted_remote_observations;
      PRAGMA user_version = 10" SQLITE:EXEC ;

\ Schema 8 in a new file: migrations 1 to 8 in order.
: CREATE-SCHEMA ( SQLITE:connection -- )
   {: c :}
   c V1 RUN  c V2 RUN  c V3 RUN  c V4 RUN
   c CANONICAL-PATHS
   c V5 RUN
   c MIGRATE-BLOCKED-PLANS
   c V7 RUN  c V8 RUN ;

\ Schema v, 0 or 8 to 13, brought to SCHEMA by each migration it lacks;
\ 0011.sql to 0014.sql each set the version.
: MIGRATE ( SQLITE:connection n -- )
   {: c v :}
   v 0= if c CREATE-SCHEMA then
   v 9 < if c MIGRATE-LOCAL-OBSERVATIONS then
   v 10 < if c MIGRATE-TYPED-COLUMNS then
   v 11 < if c V11 RUN then
   v 12 < if c V12 RUN then
   v 13 < if c V13 RUN then
   c V14 RUN ;

: WRITABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   BUSY-MS c SQLITE:BUSY-MS!
   [: j >PATH MODE-OWNER FS:CHMOD-MODE ;]
   s" restrict journal permissions" j >PATH FILE-IO
   c VERSION {: v :}
   v 0<> v 8 <> and v 9 <> and v 10 <> and v 11 <> and v 12 <> and
   v 13 <> and v SCHEMA <> and if
      j >PATH v UNSUPPORTED
   then
   j CONFIGURE-WRITABLE
   v SCHEMA = if exit then
   c [: c v MIGRATE ;] SQLITE:WITH-TRANSACTION ;

\ Deletes each completed plan that no pending or unretained recovery
\ record holds and none of whose operations installs a Dropbox file, its
\ operations' upload sessions first, then its operations: the three
\ deletes select the same plans. A plan with such an operation waits for
\ FORGET-COMPLETED-PLAN, after its stage is retired.
: PRUNE ( SQLITE:connection -- n )
   {: c :}
   c s" DELETE FROM upload_sessions WHERE operation_id IN (
         SELECT operations.id FROM operations WHERE plan_id IN (
            SELECT plans.id FROM plans WHERE plans.status = 'completed'
            AND NOT EXISTS (
               SELECT 1 FROM operations JOIN recovery_records
                  ON recovery_records.operation_id = operations.id
               WHERE operations.plan_id = plans.id
                  AND (recovery_records.status = 'pending'
                     OR recovery_records.retained_at IS NULL))
            AND NOT EXISTS (
               SELECT 1 FROM operations AS d WHERE d.plan_id = plans.id
                  AND json_valid(d.operation_json)
                  AND (json_type(d.operation_json, '$.InstallLocal')
                        IS NOT NULL
                     OR json_type(d.operation_json, '$.ReplaceLocal')
                        IS NOT NULL))))"
   SQLITE:EXEC
   c s" DELETE FROM operations WHERE plan_id IN (
         SELECT plans.id FROM plans WHERE plans.status = 'completed'
         AND NOT EXISTS (
            SELECT 1 FROM operations JOIN recovery_records
               ON recovery_records.operation_id = operations.id
            WHERE operations.plan_id = plans.id
               AND (recovery_records.status = 'pending'
                  OR recovery_records.retained_at IS NULL))
         AND NOT EXISTS (
            SELECT 1 FROM operations AS d WHERE d.plan_id = plans.id
               AND json_valid(d.operation_json)
               AND (json_type(d.operation_json, '$.InstallLocal') IS NOT NULL
                  OR json_type(d.operation_json, '$.ReplaceLocal')
                     IS NOT NULL)))"
   SQLITE:EXEC
   c s" DELETE FROM plans WHERE plans.status = 'completed'
      AND NOT EXISTS (
         SELECT 1 FROM operations JOIN recovery_records
            ON recovery_records.operation_id = operations.id
         WHERE operations.plan_id = plans.id
            AND (recovery_records.status = 'pending'
               OR recovery_records.retained_at IS NULL))
      AND NOT EXISTS (
         SELECT 1 FROM operations AS d WHERE d.plan_id = plans.id
            AND json_valid(d.operation_json)
            AND (json_type(d.operation_json, '$.InstallLocal') IS NOT NULL
               OR json_type(d.operation_json, '$.ReplaceLocal')
                  IS NOT NULL))"
   SQLITE:EXEC
   c SQLITE:CHANGES ;

public

\ Removes completed plans, their operations and their operations'
\ upload sessions, that no pending recovery needs; completed recovery
\ records stay, and so does every completed plan with an operation that
\ installs a Dropbox file, until FORGET-COMPLETED-PLAN. Answers the
\ plans removed.
: PRUNE-COMPLETED-WORK ( journal -- n )
   >CONNECTION {: c :}
   c [: c PRUNE ;] SQLITE:WITH-TRANSACTION ;

private

: READY ( journal -- )
   {: j :}
   j WRITABLE
   j PRUNE-COMPLETED-WORK drop ;

: READABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   BUSY-MS c SQLITE:BUSY-MS!
   c VERSION {: v :}
   v SCHEMA <> if j >PATH v UNSUPPORTED then ;

public

\ The journal at path: schema 14 created in a new or empty file or migrated
\ from 8 to 13, completed work pruned; any other version refused unchanged.
: OPEN ( str -- journal )
   {: path:str :}
   path OWNER-ONLY
   path SQLITE:OPEN path JOURNAL-MAKE [: READY ;] SET-UP ;

\ The schema-14 journal at path, never created or changed. Its log lines
\ name it `[Omabox journal]`, as Rust's status redacts the path.
: OPEN-READ ( str -- journal )
   {: path:str :}
   path SQLITE:OPEN-READ s" [Omabox journal]" JOURNAL-MAKE
   [: READABLE ;] SET-UP ;


private


\ ---- strings -------------------------------------------------------

: SAME? ( str str -- bool )
   {: a:str b:str :}
   a b STR:= ;

: TEXT-COPY ( SQLITE:statement n ^ARENA:arena -- SQLITE:statement str )
   {: col ar :}
   col SQLITE:COL-TEXT ar ARENA:COPY ;

: BLOB-COPY ( SQLITE:statement n ^ARENA:arena -- SQLITE:statement str )
   {: col ar :}
   col SQLITE:COL-BLOB ar ARENA:COPY ;


\ ---- the Dropbox binding -------------------------------------------

: SELECT-BINDING ( -- str )
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

public

: BINDING= ( dropbox-binding dropbox-binding -- bool )
   JOURNAL-DROPBOX--BINDING:UNMAKE {: a:str b:str c:str :}
   JOURNAL-DROPBOX--BINDING:UNMAKE {: d:str e:str f:str :}
   a d SAME? b e SAME? and c f SAME? and ;

private

: INSERT-BINDING ( SQLITE:connection dropbox-binding -- )
   {: c b :}
   b JOURNAL-DROPBOX--BINDING:UNMAKE
   {: account:str namespace:str root:str :}
   c s" INSERT INTO dropbox_binding(
         singleton, account_id, root_namespace_id, remote_root
      ) VALUES (1, ?1, ?2, ?3)
      ON CONFLICT(singleton) DO NOTHING" [: account 1 SQLITE:BIND-TEXT
      namespace 2 SQLITE:BIND-TEXT
      root 3 SQLITE:BIND-TEXT
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

: NO-INT? ( option<n> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: SUBVOLUME= ( option<n> option<n> -- bool )
   MATCH option
      none OF NO-INT? ENDOF
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

: INSPECTING ( -- str ) s" inspect local root" ;

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
   0 >FD [: drop path FS:OPEN-DIR ;] catch {: code :}
   code 0= if exit then
   drop INSPECTING path code FS:ERRNO ROOT-FAILED ;

: BORN-BINDING ( str n birth-time n bool -- local-root-binding )
   {: path:str inode birth sub has:bool :}
   path inode birth OPTION:SOME
   has if sub OPTION:SOME else NO-SUBVOLUME then
   JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

\ The identity statx gave: a birth time unreported is E-NO-BIRTH-TIME,
\ a subvolume unreported is none.
: FROM-STATX-FIELDS
   ( str n birth-time bool n bool -- local-root-binding )
   {: path:str inode birth born:bool sub has:bool :}
   born 0= if path REFUSE-UNBORN then
   path inode birth sub has BORN-BINDING ;

\ STATX's fields, the birth time as one; a failure is E-ROOT for path.
: IDENTITY ( str fd -- n birth-time bool n bool )
   {: path:str dir:fd :}
   FS:CAUSE-CLEAR
   0 0 0 false 0 false [: 2drop 2drop 2drop dir STATX ;] catch
   {: code :}
   code 0= if
      {: inode s ns born:bool sub has:bool :}
      inode s ns JOURNAL-BIRTH--TIME:MAKE born sub has exit
   then
   2drop 2drop 2drop INSPECTING path code FS:ERRNO ROOT-FAILED ;

\ IDENTITY of the directory at the canonical path, opened without
\ following a link.
: PATH-IDENTITY ( str -- n birth-time bool n bool )
   {: path:str :}
   path OPENED {: dir:fd :}
   [: path dir IDENTITY ;] [: dir FS:CLOSE-DIR ;] finally ;

\ Whether a missing-birth-time refusal of path, inode n, means another
\ directory stands in for the root: it had a birth time or another inode.
: STOOD-IN-BY? ( local-root-record str n -- bool )
   {: r path:str inode :}
   r >BINDING {: b :}
   b ROOT-PATH path SAME? 0= if false exit then
   b ROOT-BIRTH BIRTHLESS? 0= if true exit then
   b ROOT-INODE inode <> ;

: STAND-IN? ( option<local-root-record> str n -- bool )
   {: path:str inode :}
   MATCH option
      none OF false ENDOF
      some OF path inode STOOD-IN-BY? ENDOF
   ;MATCH ;

public

\ The identity of the directory at the canonical path, opened without
\ following a link; any failure but a birth time's is E-ROOT.
: INSPECT ( str -- local-root-binding )
   {: path:str :}
   path path PATH-IDENTITY FROM-STATX-FIELDS ;

private


\ ---- the root's row ------------------------------------------------

: SELECT-ROOT ( -- str )
   s" SELECT canonical_path, inode, birth_seconds, birth_nanoseconds,
         subvolume, generation
      FROM local_root_binding WHERE singleton = 1" ;

: UPSERT-ROOT ( -- str )
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
: BE-BYTES ( n n -- str )
   {: v at :}
   at ID-ROW {: p:^ :}
   v p BE:U64!
   p 8 >str ;

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
   p 1 SQLITE:BIND-BLOB
   inode 0 BE-BYTES 2 SQLITE:BIND-BLOB
   birth BIND-BIRTH
   sub BIND-SUBVOLUME
   g 6 SQLITE:BIND-INT
   SQLITE:STEP drop ;

: WRITE-LOCAL-ROOT ( SQLITE:connection local-root-record -- )
   {: c r :}
   r c UPSERT-ROOT [: BIND-ROOT ;] SQLITE:WITH-STATEMENT ;

: DECODE-U64 ( str str str -- n )
   {: s op:str path:str :}
   s str> {: a:^ u :}
   u 8 <> if
      op path s" filesystem identity has an invalid byte length"
      INVALID
   then
   a BE:U64@ ;

: BLOB-U64 ( SQLITE:statement n str str -- SQLITE:statement n )
   {: col op:str path:str :}
   col SQLITE:COL-BLOB op path DECODE-U64 ;

: BIRTH-INVALID ( str str -- )
   {: path:str detail:str :}
   s" read local root birth time" path detail INVALID ;

: ROW-BIRTH ( SQLITE:statement str -- SQLITE:statement option<birth-time> )
   {: path:str :}
   2 SQLITE:COL-NULL? {: no-s:bool :}
   3 SQLITE:COL-NULL? {: no-ns:bool :}
   no-s no-ns and if NO-BIRTH exit then
   no-s no-ns or if
      path s" local root birth time is only partly recorded"
      BIRTH-INVALID
   then
   2 SQLITE:COL-INT {: s :}
   3 SQLITE:COL-INT {: ns :}
   ns 0 < ns NS-PER-S >= or if
      path s" local root birth nanoseconds are out of range"
      BIRTH-INVALID
   then
   s ns JOURNAL-BIRTH--TIME:MAKE OPTION:SOME ;

: ROW-SUBVOLUME ( SQLITE:statement str -- SQLITE:statement option<n> )
   {: path:str :}
   4 SQLITE:COL-NULL? if NO-SUBVOLUME exit then
   4 s" read local root subvolume" path BLOB-U64 OPTION:SOME ;

: ROW-GENERATION ( SQLITE:statement str -- SQLITE:statement n )
   {: db:str :}
   5 SQLITE:COL-INT {: g :}
   g 0 < if
      s" read local root generation" db
      s" local root generation is outside the supported range"
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
   1 s" read local root inode" p BLOB-U64 {: inode :}
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

: NO-ROOT ( -- option<local-root-binding> ) OPTION:NONE ;

: UNBORN
   ( journal ^ARENA:arena str n -- option<local-root-binding> )
   {: j ar path:str inode :}
   j ar LOCAL-ROOT-BINDING path inode STAND-IN? if NO-ROOT exit then
   path REFUSE-UNBORN ;

public

\ The identity of the root the descriptor names, path its canonical path;
\ none where its filesystem has no birth time and it stands in for the root.
: INSPECT-ROOT-AT
   ( str fd journal ^ARENA:arena -- option<local-root-binding> )
   {: path:str dir:fd j ar :}
   path dir IDENTITY {: inode birth born:bool sub has:bool :}
   born 0= if j ar path inode UNBORN exit then
   path inode birth sub has BORN-BINDING OPTION:SOME ;

\ INSPECT-ROOT-AT of the directory at path.
: INSPECT-ROOT
   ( str journal ^ARENA:arena -- option<local-root-binding> )
   {: path:str j ar :}
   path OPENED {: dir:fd :}
   [: path dir j ar INSPECT-ROOT-AT ;] [: dir FS:CLOSE-DIR ;] finally ;

\ Whether the binding is the active root's.
: ACTIVE-ROOT? ( local-root-binding journal ^ARENA:arena -- bool )
   {: b j ar :}
   j ar LOCAL-ROOT-BINDING MATCH option
      none OF false ENDOF
      some OF >BINDING b ROOT= ENDOF
   ;MATCH ;

private


\ ---- activation ----------------------------------------------------

\ A new root carries none of the old one's history; the watched folders go
\ too, as their clean marks vouch for the old observations.
: RETIRE ( SQLITE:connection -- )
   s" DELETE FROM recovery_records
      WHERE status = 'pending' OR operation_id IN (
         SELECT operations.id FROM operations
         JOIN plans ON plans.id = operations.plan_id
         WHERE plans.status IN ('pending', 'blocked')
      );
      DELETE FROM upload_sessions WHERE operation_id IN (
         SELECT operations.id FROM operations
         JOIN plans ON plans.id = operations.plan_id
         WHERE plans.status IN ('pending', 'blocked')
      );
      DELETE FROM operations WHERE plan_id IN (
         SELECT id FROM plans WHERE status IN ('pending', 'blocked')
      );
      DELETE FROM plans WHERE status IN ('pending', 'blocked');
      DELETE FROM upload_sessions WHERE operation_id IN (
         SELECT operations.id FROM operations
         JOIN plans ON plans.id = operations.plan_id
         WHERE plans.status = 'completed' AND EXISTS (
            SELECT 1 FROM operations AS d WHERE d.plan_id = plans.id
               AND json_valid(d.operation_json)
               AND (json_type(d.operation_json, '$.InstallLocal') IS NOT NULL
                  OR json_type(d.operation_json, '$.ReplaceLocal')
                     IS NOT NULL))
      );
      DELETE FROM operations WHERE plan_id IN (
         SELECT plans.id FROM plans WHERE plans.status = 'completed'
         AND EXISTS (
            SELECT 1 FROM operations AS d WHERE d.plan_id = plans.id
               AND json_valid(d.operation_json)
               AND (json_type(d.operation_json, '$.InstallLocal') IS NOT NULL
                  OR json_type(d.operation_json, '$.ReplaceLocal')
                     IS NOT NULL))
      );
      DELETE FROM plans WHERE status = 'completed' AND NOT EXISTS (
         SELECT 1 FROM operations WHERE operations.plan_id = plans.id
      );
      DELETE FROM baselines;
      DELETE FROM local_observations;
      DELETE FROM local_hash_cache;
      DELETE FROM conflicts;
      DELETE FROM conflict_blocks;
      DELETE FROM copy_stages;
      DELETE FROM temp.watches;
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
            s" write local root binding" db
            s" local root generation exceeds SQLite integer range"
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

\ One step of a cursor continuation. ensure-directory adds a missing
\ ancestor and never replaces a stored path or an unknown observation.
\ hold: the entry at lower, which folds to key but is not key's own,
\ holds key unsupported, its record spelled path; unhold: the entry at
\ lower and every one beneath it hold nothing.
ENUM remote-inventory-change
   VARIANT upsert FIELD record MODEL:remote-record ;VARIANT
   VARIANT ensure-directory FIELD record MODEL:remote-record ;VARIANT
   VARIANT delete-subtree FIELD key MODEL:key ;VARIANT
   VARIANT hold
      FIELD lower MODEL:path FIELD key MODEL:key FIELD path MODEL:path
   ;VARIANT
   VARIANT unhold FIELD lower MODEL:path FIELD key MODEL:key ;VARIANT
;ENUM

private

1 TASK:+USERS ENCODER JSON:writer


\ ---- stored columns ------------------------------------------------

: BYTES-KEY ( str ^ARENA:arena -- MODEL:key ) ARENA:COPY MODEL:>KEY ;

: ON-VECTOR ( R ^VEC:vector<u8> [ R ^JSON:writer -- S ] -- S )
   {: v body :}
   0 ENCODER v JSON:OPEN body execute ;

\ Runs body on the task's JSON writer, whose vector is deleted after.
: ENCODING ( R [ R ^JSON:writer -- S ] -- S )
   {: body :}
   HEAP:ALLOCATOR 0 [type] u8 VEC:NEW {: v :}
   v body [: ON-VECTOR ;] [: v VEC:DELETE ;] finally ;

\ The JSON `write` puts on the writer, until the writer's next use.
: ENCODE ( ^JSON:writer [ ^JSON:writer -- ^JSON:writer ] -- str )
   {: w write :}
   w JSON:RESET write execute JSON:WRITTEN$ ;

\ Runs a MODEL read that replaces the seed it is given; a stored value
\ MODEL cannot read is op's E-JSON on path.
: DECODE ( R [ R -- R ] str str -- R )
   {: read op:str path:str :}
   [: read execute ;] catch {: code :}
   code 0= if exit then
   code MODEL:E-STORED <> if code throw then
   code op path UNPROCESSED ;

: NOT-CONTENT-HASH ( str str -- )
   {: op:str path:str :}
   op path
   s" cached content identity is not a Dropbox content hash"
   INVALID ;


\ ---- reading -------------------------------------------------------

\ A seed's typed drop, which types the read that replaces it.
: DROP-HASH ( DROPBOX:hash -- ) drop ;
: DROP-OPERATION ( MODEL:operation -- ) drop ;
: DROP-BLOCKAGE ( MODEL:blockage -- ) drop ;
: DROP-CONFLICT ( MODEL:conflict -- ) drop ;

: NO-CURSOR ( -- option<DROPBOX:cursor> ) OPTION:NONE ;
: NO-PATH ( -- option<MODEL:path> ) OPTION:NONE ;

: PATH-COPY ( SQLITE:statement n ^ARENA:arena
     -- SQLITE:statement MODEL:path )
   BLOB-COPY MODEL:>PATH ;

: SPELLING-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<MODEL:path> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-PATH swap exit then
   0 ar PATH-COPY OPTION:SOME swap ;

\ The local observation in columns col and col+1: its kind and
\ content.
: LOCAL-OBSERVATION-COPY
   ( SQLITE:statement n ^ARENA:arena
     -- SQLITE:statement MODEL:observation<MODEL:local> )
   {: col ar :}
   col SQLITE:COL-INT {: kind :}
   kind KIND-PRESENT = if
      col 1+ ar TEXT-COPY DROPBOX:>HASH MODEL-LOCAL:MAKE
      MODEL-OBSERVATION:PRESENT exit
   then
   kind KIND-DIRECTORY = if MODEL-OBSERVATION:DIRECTORY exit then
   kind KIND-REASON MODEL-OBSERVATION:UNKNOWN ;

: LOCAL-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement MODEL:local-record )
   {: ar :}
   0 SQLITE:COL-BLOB ar BYTES-PATH {: p:MODEL:path :}
   1 ar LOCAL-OBSERVATION-COPY {: o :}
   p o MODEL-LOCAL--RECORD:MAKE ;

\ The file in columns col and col+1: its content and revision.
: REMOTE-FILE-COPY
   ( SQLITE:statement n ^ARENA:arena -- SQLITE:statement MODEL:remote )
   {: col ar :}
   col ar TEXT-COPY DROPBOX:>HASH {: h:DROPBOX:hash :}
   col 1+ ar TEXT-COPY DROPBOX:>REV {: v:DROPBOX:rev :}
   h v MODEL-REMOTE:MAKE ;

\ The remote observation in columns col to col+2: its kind, content
\ and revision.
: REMOTE-OBSERVATION-COPY
   ( SQLITE:statement n ^ARENA:arena
     -- SQLITE:statement MODEL:observation<MODEL:remote> )
   {: col ar :}
   col SQLITE:COL-INT {: kind :}
   kind KIND-PRESENT = if
      col 1+ ar REMOTE-FILE-COPY MODEL-OBSERVATION:PRESENT exit
   then
   kind KIND-DIRECTORY = if MODEL-OBSERVATION:DIRECTORY exit then
   kind KIND-REASON MODEL-OBSERVATION:UNKNOWN ;

: REMOTE-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement MODEL:remote-record )
   {: ar :}
   0 SQLITE:COL-BLOB ar BYTES-KEY {: k:MODEL:key :}
   1 SQLITE:COL-BLOB ar BYTES-PATH {: p:MODEL:path :}
   2 ar REMOTE-OBSERVATION-COPY {: o :}
   k p o MODEL-REMOTE--RECORD:MAKE ;

: CURSOR-ROW
   ( ^ARENA:arena SQLITE:statement
     -- option<DROPBOX:cursor> SQLITE:statement )
   swap {: ar :}
   SQLITE:STEP 0= if NO-CURSOR swap exit then
   0 ar TEXT-COPY DROPBOX:>CURSOR OPTION:SOME swap ;

\ The local records the statement selects as path, kind, content.
: LOCAL-ROWS
   ( SQLITE:connection str ^ARENA:arena
     -- ^VEC:vector<MODEL:local-record> )
   {: c q:str ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:local-record VEC:NEW {: v :}
   c q [: begin SQLITE:STEP while ar LOCAL-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

\ The remote records the statement selects as canonical_path, path,
\ kind, content, revision.
: REMOTE-ROWS
   ( SQLITE:connection str ^ARENA:arena
     -- ^VEC:vector<MODEL:remote-record> )
   {: c q:str ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: v :}
   c q [: begin SQLITE:STEP while ar REMOTE-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

public

\ The committed local inventory, by path.
: LOCAL-INVENTORY
   ( journal ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: j ar :}
   j >CONNECTION
   s" SELECT path, kind, content FROM local_observations
      ORDER BY path" ar LOCAL-ROWS ;

\ The committed cursor, without the inventory.
: REMOTE-CURSOR ( journal ^ARENA:arena -- option<DROPBOX:cursor> )
   {: j ar :}
   ar j >CONNECTION
   s" SELECT cursor FROM remote_inventory WHERE singleton = 1" [: CURSOR-ROW ;] SQLITE:WITH-STATEMENT ;

private

: SNAPSHOT ( journal ^ARENA:arena -- remote-inventory )
   {: j ar :}
   j ar REMOTE-CURSOR
   j >CONNECTION
   s" SELECT canonical_path, path, kind, content, revision
      FROM remote_observations ORDER BY canonical_path" ar REMOTE-ROWS
   JOURNAL-REMOTE--INVENTORY:MAKE ;

public

\ The cursor and the inventory it produced, read as one snapshot.
: REMOTE-INVENTORY ( journal ^ARENA:arena -- remote-inventory )
   {: j ar :}
   j >CONNECTION [: j ar SNAPSHOT ;] SQLITE:WITH-READ ;

\ The committed local records whose observation is unknown, by path.
: UNKNOWN-LOCALS
   ( journal ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: j ar :}
   j >CONNECTION
   s" SELECT path, kind, content FROM local_observations
      WHERE kind >= 3 ORDER BY path" ar LOCAL-ROWS ;

\ The committed remote records whose observation is unknown, by
\ canonical path.
: UNKNOWN-REMOTES
   ( journal ^ARENA:arena -- ^VEC:vector<MODEL:remote-record> )
   {: j ar :}
   j >CONNECTION
   s" SELECT canonical_path, path, kind, content, revision
      FROM remote_observations WHERE kind >= 3
      ORDER BY canonical_path" ar REMOTE-ROWS ;

private


\ ---- watched folders -----------------------------------------------

\ A watched folder's record: its watch descriptor, its journal path (the
\ root ""), and its mark: 0 clean, 1 stirred, 2 listed by the running scan,
\ 3 tried by the running scan.

public

\ A stirred folder's watch descriptor and journal path.
STRUCTURE stirred
   FIELD wd n
   FIELD path str
;STRUCTURE

private

\ Runs the statement on wd n, bound to ?1.
: ON-WD ( journal n str -- )
   {: j n sql:str :}
   j >CONNECTION sql [: n 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: CLEAN-ROW ( SQLITE:statement -- bool SQLITE:statement )
   SQLITE:STEP swap ;

: NO-STIRRED ( -- option<stirred> ) OPTION:NONE ;

: STIRRED-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<stirred> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-STIRRED swap exit then
   0 SQLITE:COL-INT {: n :}
   1 ar BLOB-COPY {: p:str :}
   n p JOURNAL-STIRRED:MAKE OPTION:SOME swap ;

\ Every folder the scan listed or tried is stirred again: the scan ended
\ unpublished.
: LISTED-STIRRED ( journal -- )
   >CONNECTION
   s" UPDATE temp.watches SET mark = 1 WHERE mark IN (2, 3)" SQLITE:EXEC ;

\ Every folder the scan listed is clean, every one it tried stirred again
\ and every one at a path it staged as no folder (a file, gone or
\ unsupported) forgotten: its publication is committing.
: LISTED-CLEANED ( journal -- )
   >CONNECTION
   s" DELETE FROM temp.watches WHERE path IN (
         SELECT path FROM temp.scan_observations WHERE kind IN (0, 2, 8)
      );
      UPDATE temp.watches
      SET mark = CASE mark WHEN 2 THEN 0 ELSE 1 END WHERE mark IN (2, 3)"
   SQLITE:EXEC ;

public

\ Forgets every watched folder.
: WATCHES-RESET ( journal -- )
   >CONNECTION s" DELETE FROM temp.watches" SQLITE:EXEC ;

\ Records wd n watching the folder at path str, replacing any record of
\ wd n or at str; the running scan tries the folder until WATCH-LISTED.
: WATCH-RECORD ( journal n str -- )
   {: j n p:str :}
   j >CONNECTION
   s" INSERT OR REPLACE INTO temp.watches(wd, path, mark)
      VALUES (?1, ?2, 3)"
   [: n 1 SQLITE:BIND-INT p 2 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ Whether wd n watches folder str, which a published scan listed with
\ nothing stirred since and published a directory.
: WATCH-CLEAN? ( journal n str -- bool )
   {: j n p:str :}
   j >CONNECTION
   s" SELECT 1 FROM temp.watches AS w
      WHERE w.wd = ?1 AND w.path = ?2 AND w.mark = 0
         AND EXISTS (
            SELECT 1 FROM local_observations AS o
            WHERE o.path = w.path AND o.kind = 1
         )"
   [: n 1 SQLITE:BIND-INT p 2 SQLITE:BIND-BLOB CLEAN-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Marks wd n's folder stirred; false when no record has wd n.
: WATCH-STIR ( journal n -- bool )
   {: j n :}
   j >CONNECTION
   s" UPDATE temp.watches SET mark = 1 WHERE wd = ?1 RETURNING wd"
   [: n 1 SQLITE:BIND-INT SQLITE:STEP swap ;] SQLITE:WITH-STATEMENT ;

\ Marks wd n's folder listed by the running scan.
: WATCH-LISTED ( journal n -- )
   s" UPDATE temp.watches SET mark = 2 WHERE wd = ?1" ON-WD ;

\ Marks wd n's folder tried by the running scan, stirred again once the
\ scan ends; an unrecorded wd changes nothing.
: WATCH-TRIED ( journal n -- )
   s" UPDATE temp.watches SET mark = 3 WHERE wd = ?1" ON-WD ;

\ Forgets wd n's record.
: WATCH-FORGET ( journal n -- )
   s" DELETE FROM temp.watches WHERE wd = ?1" ON-WD ;

\ The stirred folder first in path byte order, its path in ar; none when
\ no folder is stirred.
: NEXT-STIRRED ( journal ^ARENA:arena -- option<stirred> )
   {: j ar :}
   j >CONNECTION
   s" SELECT wd, path FROM temp.watches WHERE mark = 1
      ORDER BY path LIMIT 1" [: ar STIRRED-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Whether any folder is stirred.
: STIRRED? ( journal -- bool )
   >CONNECTION s" SELECT 1 FROM temp.watches WHERE mark = 1 LIMIT 1"
   [: SQLITE:STEP swap ;] SQLITE:WITH-STATEMENT ;

private


\ ---- the local scan ------------------------------------------------

\ Where the stored stream stands: ended, no group held; last, a group
\ held and the stream past its end; more, a group held and the stream on
\ the row after it.
ENUM stored-state ended last more ;ENUM

\ The stored rows a scan merges the walk against, read in path byte
\ order: the group held is the observation and the active generation's
\ cached hash at one path, kind NO-KIND and content "" for no
\ observation; state tells whether a group is held and whether the
\ stream stands on a row past it, and rows counts the rows read since
\ the stream's reset. group holds path, content and digest, the cached
\ hash. The walk never sees a path beneath an unknown entry; prefixes
\ holds the lengths of the unknown paths, each a prefix of the last one,
\ unknown, beneath which a stored row may still lie.
STRUCTURE stored DERIVE addr
   FIELD state stored-state
   FIELD rows n
   FIELD path str
   FIELD kind n
   FIELD content str
   FIELD cached bool
   FIELD print MODEL:fingerprint
   FIELD digest str
   FIELD group ^ARENA:arena
   FIELD unknown ^VEC:vector<u8>
   FIELD prefixes ^VEC:vector<n>
;STRUCTURE

ARENA STORES stored

public

\ A scan stages only what differs from the stored rows, in temp
\ tables: scan_observations, a gone path as kind 2, and scan_hashes, a
\ gone hash as a row without content, which PUBLISH-SCAN applies;
\ scan_jobs holds the files to hash. Its writes autocommit.
STRUCTURE scan OPAQUE
   FIELD observe-insert SQLITE:statement
   FIELD hash-insert SQLITE:statement
   FIELD job-insert SQLITE:statement
   FIELD stream SQLITE:statement
   FIELD stored ^stored
   FIELD journal journal
   FIELD arena ^ARENA:arena
;STRUCTURE

private

$2F constant SLASH
-1 constant NO-KIND

\ The most rows the stored stream reads, finishing a group, before it resets,
\ so main stays read locked only that long; and a plan batch's most plans.
512 constant BATCH-BOUND

\ Binds a local observation's kind to ?2 and NULL content to ?4.
: BIND-LOCAL-KIND ( SQLITE:statement n -- SQLITE:statement )
   2 SQLITE:BIND-INT 4 SQLITE:BIND-NULL ;

\ Binds a file's kind to ?2 and its content to ?4.
: BIND-LOCAL-FILE ( SQLITE:statement MODEL:local -- SQLITE:statement )
   MODEL-LOCAL:UNMAKE {: h :}
   KIND-PRESENT 2 SQLITE:BIND-INT
   h DROPBOX:HASH>STR 4 SQLITE:BIND-TEXT ;

\ Binds the record's path to ?1, its key to ?3 and its observation to
\ ?2 and ?4; an absent one binds kind 2, its path gone.
: LOCAL-INSERTED
   ( SQLITE:statement MODEL:local-record ^ARENA:arena
     -- SQLITE:statement )
   {: r ar :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   p MODEL:PATH>STR 1 SQLITE:BIND-BLOB
   o MATCH MODEL:observation
      present OF BIND-LOCAL-FILE ENDOF
      directory OF KIND-DIRECTORY BIND-LOCAL-KIND ENDOF
      absent OF KIND-ABSENT BIND-LOCAL-KIND ENDOF
      unknown OF REASON-KIND BIND-LOCAL-KIND ENDOF
   ;MATCH
   p ar BIND-KEY RAN ;

\ Binds the path ?1 and the fingerprint ?2 to ?7.
: FILE-BOUND
   ( SQLITE:statement str MODEL:fingerprint -- SQLITE:statement )
   {: p:str f :}
   f MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   p 1 SQLITE:BIND-BLOB
   i 2 SQLITE:BIND-INT  s 3 SQLITE:BIND-INT
   ms 4 SQLITE:BIND-INT  mn 5 SQLITE:BIND-INT
   cs 6 SQLITE:BIND-INT  cn 7 SQLITE:BIND-INT ;

\ FILE-BOUND of the record's path and fingerprint, then its content ?8.
: RECORD-INSERTED
   ( SQLITE:statement MODEL:hash-record -- SQLITE:statement )
   MODEL-HASH--RECORD:UNMAKE {: p:MODEL:path f h :}
   p MODEL:PATH>STR f FILE-BOUND
   h DROPBOX:HASH>STR 8 SQLITE:BIND-TEXT RAN ;

\ RECORD-INSERTED of a hash the scan computed; one that is not
\ Dropbox's is never cached.
: HASH-INSERTED
   ( SQLITE:statement MODEL:hash-record -- SQLITE:statement )
   {: r :}
   r MODEL-HASH--RECORD:UNMAKE {: p:MODEL:path f h :}
   h DROPBOX:HASH>STR DROPBOX:CONTENT-HASH? 0= if
      s" publish local hash cache" p MODEL:PATH>STR
      NOT-CONTENT-HASH
   then
   r RECORD-INSERTED ;

: JOB-INSERTED
   ( SQLITE:statement str MODEL:fingerprint -- SQLITE:statement )
   FILE-BOUND RAN ;

\ Binds the path, kind 2 and no key or content: the path is gone.
: GONE-INSERTED ( SQLITE:statement str -- SQLITE:statement )
   {: p:str :}
   p 1 SQLITE:BIND-BLOB KIND-ABSENT 2 SQLITE:BIND-INT
   3 SQLITE:BIND-NULL 4 SQLITE:BIND-NULL RAN ;

\ Binds the path and no fingerprint or content: its hash is gone.
: TOMBSTONE-INSERTED ( SQLITE:statement str -- SQLITE:statement )
   {: p:str :}
   p 1 SQLITE:BIND-BLOB
   9 2 do i SQLITE:BIND-NULL loop RAN ;

: JOB-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement str MODEL:fingerprint )
   {: ar :}
   0 ar BLOB-COPY {: p:str :}
   1 SQLITE:COL-INT {: i :}  2 SQLITE:COL-INT {: s :}
   3 SQLITE:COL-INT {: ms :}  4 SQLITE:COL-INT {: mn :}
   5 SQLITE:COL-INT {: cs :}  6 SQLITE:COL-INT {: cn :}
   p i s ms mn cs cn MODEL-FINGERPRINT:MAKE ;

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

\ A gone path never replaces an observation the scan holds.
: OBSERVE-SCAN ( -- str )
   s" INSERT INTO temp.scan_observations(
         path, kind, canonical_path, content
      ) VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(path) DO UPDATE SET
         kind = excluded.kind,
         canonical_path = excluded.canonical_path,
         content = excluded.content
      WHERE excluded.kind != 2" ;

\ A gone hash never replaces a hash the scan holds.
: HASH-SCAN ( -- str )
   s" INSERT INTO temp.scan_hashes(
         path, inode, size, modified_seconds, modified_nanoseconds,
         changed_seconds, changed_nanoseconds, content_hash
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
      ON CONFLICT(path) DO UPDATE SET
         inode = excluded.inode,
         size = excluded.size,
         modified_seconds = excluded.modified_seconds,
         modified_nanoseconds = excluded.modified_nanoseconds,
         changed_seconds = excluded.changed_seconds,
         changed_nanoseconds = excluded.changed_nanoseconds,
         content_hash = excluded.content_hash
      WHERE excluded.content_hash IS NOT NULL" ;

: JOB-SCAN ( -- str )
   s" INSERT OR REPLACE INTO temp.scan_jobs(
         path, inode, size, modified_seconds, modified_nanoseconds,
         changed_seconds, changed_nanoseconds
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)" ;

\ The stored observations and the active generation's cached hashes
\ from the path ?1 on, merged by path; a hash row's kind is NO-KIND.
\ Both selects read in index order, so SQLite merges them unsorted.
: STREAM-SCAN ( -- str )
   s" SELECT path, kind, content, NULL, NULL, NULL, NULL, NULL, NULL
      FROM local_observations WHERE path >= ?1
      UNION ALL
      SELECT path, -1, content_hash, inode, size, modified_seconds,
         modified_nanoseconds, changed_seconds, changed_nanoseconds
      FROM local_hash_cache
      WHERE root_generation = (SELECT generation
            FROM local_root_binding WHERE singleton = 1)
         AND path >= ?1
      ORDER BY 1" ;

: SCAN-TABLES ( -- str )
   s" CREATE TABLE IF NOT EXISTS temp.scan_observations(
         path BLOB PRIMARY KEY,
         canonical_path BLOB,
         kind INTEGER NOT NULL,
         content TEXT
      );
      CREATE TABLE IF NOT EXISTS temp.scan_hashes(
         path BLOB PRIMARY KEY,
         inode INTEGER,
         size INTEGER,
         modified_seconds INTEGER,
         modified_nanoseconds INTEGER,
         changed_seconds INTEGER,
         changed_nanoseconds INTEGER,
         content_hash TEXT
      );
      CREATE TABLE IF NOT EXISTS temp.scan_jobs(
         path BLOB PRIMARY KEY,
         inode INTEGER NOT NULL,
         size INTEGER NOT NULL,
         modified_seconds INTEGER NOT NULL,
         modified_nanoseconds INTEGER NOT NULL,
         changed_seconds INTEGER NOT NULL,
         changed_nanoseconds INTEGER NOT NULL
      );
      DELETE FROM temp.scan_observations;
      DELETE FROM temp.scan_hashes;
      DELETE FROM temp.scan_jobs;" ;

\ ---- the stored stream

\ Whether a group is held.
: GROUP-HELD? ( ^stored -- bool )
   STORED-STATE @ MATCH stored-state
      ended OF false ENDOF
      last OF true ENDOF
      more OF true ENDOF
   ;MATCH ;

\ Whether the stream stands on a row past the group held.
: ROW-AHEAD? ( ^stored -- bool )
   STORED-STATE @ MATCH stored-state
      ended OF false ENDOF
      last OF false ENDOF
      more OF true ENDOF
   ;MATCH ;

\ Steps the stream: more on a row, else last; at its end it is reset,
\ so it reads main no more.
: STEPPED ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   SQLITE:STEP if
      construct stored-state more st STORED-STATE !
      1 st STORED-ROWS +! exit
   then
   construct stored-state last st STORED-STATE !
   SQLITE:RESET ;

\ The cached hash the stream stands on, held, its text in the group.
: CACHE-HELD ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   3 SQLITE:COL-INT {: i :}  4 SQLITE:COL-INT {: s :}
   5 SQLITE:COL-INT {: ms :}  6 SQLITE:COL-INT {: mn :}
   7 SQLITE:COL-INT {: cs :}  8 SQLITE:COL-INT {: cn :}
   i s ms mn cs cn MODEL-FINGERPRINT:MAKE st STORED-PRINT !
   2 SQLITE:COL-TEXT st STORED-GROUP @ ARENA:COPY st STORED-DIGEST !
   true st STORED-CACHED ! ;

\ The observation of kind k the stream stands on, held.
: OBSERVATION-HELD ( SQLITE:statement n ^stored -- SQLITE:statement )
   {: k st :}
   k st STORED-KIND !
   2 SQLITE:COL-NULL? if exit then
   2 SQLITE:COL-TEXT st STORED-GROUP @ ARENA:COPY st STORED-CONTENT ! ;

: ROW-HELD ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   1 SQLITE:COL-INT {: k :}
   k NO-KIND = if st CACHE-HELD exit then
   k st OBSERVATION-HELD ;

\ Whether the stream stands on another row at the held path.
: SAME-PATH? ( SQLITE:statement ^stored -- SQLITE:statement bool )
   {: st :}
   st ROW-AHEAD? 0= if false exit then
   0 SQLITE:COL-BLOB st STORED-PATH @ STR:= ;

\ s followed by the byte b, laid in ar.
: SUFFIXED ( str n ^ARENA:arena -- str )
   {: s:str b ar :}
   s str> {: a:^ u:n :}
   ar u 1+ ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   b dst u + c!
   dst u 1+ >str ;

\ The stream reset, then resumed at the least path above the held one:
\ the held path followed by a zero byte.
: RESUMED ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   st STORED-PATH @ 0 st STORED-GROUP @ SUFFIXED {: k:str :}
   SQLITE:RESET k 1 SQLITE:BIND-BLOB
   0 st STORED-ROWS ! st STEPPED ;

\ The rows at the path the stream stands on, held as the group.
: GROUP-READ ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   st STORED-GROUP @ ARENA:RESET
   0 SQLITE:COL-BLOB st STORED-GROUP @ ARENA:COPY st STORED-PATH !
   NO-KIND st STORED-KIND !  s" " st STORED-CONTENT !
   false st STORED-CACHED !
   begin st ROW-HELD st STEPPED st SAME-PATH? 0= until ;

\ Holds the next group, none past the last: ended from last.
: NEXT-GROUP ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   st ROW-AHEAD? 0= if construct stored-state ended st STORED-STATE ! exit then
   st GROUP-READ
   st ROW-AHEAD? 0= if exit then
   st STORED-ROWS @ BATCH-BOUND >= if st RESUMED then ;

\ The stream reset and resumed at the path k, its first group held.
: SOUGHT ( SQLITE:statement str ^stored -- SQLITE:statement )
   {: k:str st :}
   SQLITE:RESET k 1 SQLITE:BIND-BLOB
   0 st STORED-ROWS ! st STEPPED st NEXT-GROUP ;

\ The stream from the first stored path, its first group held.
: STREAM-OPENED ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   s" " st SOUGHT ;

\ The group held dropped, staging nothing; the stream reads main no
\ more.
: GROUP-DROPPED ( SQLITE:statement ^stored -- SQLITE:statement )
   {: st :}
   SQLITE:RESET construct stored-state ended st STORED-STATE ! ;

\ The first path beneath the folder at p, laid in ar: p then "/", and
\ "" for the root's "".
: RANGE-START ( str ^ARENA:arena -- str )
   {: p:str ar :}
   p str> nip 0= if p exit then
   p SLASH ar SUFFIXED ;

\ Whether a group is held below p.
: BELOW? ( str ^stored -- bool )
   {: p:str st :}
   st GROUP-HELD? 0= if false exit then
   st STORED-PATH @ {: h:str :}
   h p STR:= if false exit then
   h p STR:< ;

\ Whether the group held is at p.
: AT? ( str ^stored -- bool )
   {: p:str st :}
   st GROUP-HELD? 0= if false exit then
   st STORED-PATH @ p STR:= ;

\ ---- unknown paths

\ The last unknown path the walk saw.
: UNKNOWN$ ( ^stored -- str ) STORED-UNKNOWN @ VEC:SPAN SPAN:$ ;

\ Whether p lies beneath t's first u bytes.
: UNDER? ( str str n -- bool )
   {: p:str t:str u:n :}
   p str> {: a:^ pu:n :}
   pu u <= if false exit then
   a u + c@ SLASH <> if false exit then
   a u >str t str> drop u >str STR:= ;

\ Whether p lies beneath an unknown path whose subtree may lie ahead.
: BENEATH-UNKNOWN? ( str ^stored -- bool )
   {: p:str st :}
   st UNKNOWN$ {: t:str :}
   st STORED-PREFIXES @ {: v :}
   false v VEC:COUNT 0 ?do p t v i VEC:AT @ UNDER? or loop ;

\ Whether the last unknown path held is a prefix of p.
: TOP-PREFIX? ( str str ^VEC:vector<n> -- bool )
   {: p:str t:str v :}
   v v VEC:COUNT 1- VEC:AT @ {: u:n :}
   p t str> drop u >str STR:STARTS-WITH? ;

\ The bytes of s, the vector's only ones.
: BYTES-SET ( str ^VEC:vector<u8> -- )
   {: s:str v :}
   s str> {: a:^ u:n :}
   v u VEC:RESIZE
   u 0= if exit then
   a v 0 VEC:AT u BYTE-COPY ;

\ Holds p as an unknown path. Paths come in byte order, so one held that
\ is not a prefix of p sorts below p's and its subtree: its subtree is
\ behind; those that are prefixes are prefixes of each other.
: UNKNOWN-HELD ( str ^stored -- )
   {: p:str st :}
   st STORED-PREFIXES @ {: v :}
   st UNKNOWN$ {: t:str :}
   begin v VEC:COUNT 0 > if p t v TOP-PREFIX? 0= else false then
   while v v VEC:COUNT 1- VEC:RESIZE repeat
   p st STORED-UNKNOWN @ BYTES-SET
   p str> nip v VEC:PUSH ! ;

\ ---- the merge

\ Whether the held cache is the file's: its fingerprint is the file's,
\ both times before the cutoff; with no cutoff, none is.
: CACHE-AGREES? ( MODEL:fingerprint option<MODEL:cutoff> ^stored -- bool )
   {: f o:option<MODEL:cutoff> st :}
   st STORED-CACHED @ 0= if false exit then
   f st STORED-PRINT @ MODEL:FINGERPRINT= 0= if false exit then
   o MATCH option
      none OF false ENDOF
      some OF f swap MODEL:BEFORE? ENDOF
   ;MATCH ;

\ Whether the held observation is a file of the cached hash.
: CACHE-OBSERVED? ( ^stored -- bool )
   {: st :}
   st STORED-KIND @ KIND-PRESENT <> if false exit then
   st STORED-CONTENT @ st STORED-DIGEST @ STR:= ;

\ The observation's kind and content, as stored.
: RECORD-KIND ( MODEL:observation<MODEL:local> -- n str )
   MATCH MODEL:observation
      present OF
         MODEL-LOCAL:UNMAKE {: h :} KIND-PRESENT h DROPBOX:HASH>STR
      ENDOF
      directory OF KIND-DIRECTORY s" " ENDOF
      absent OF KIND-ABSENT s" " ENDOF
      unknown OF REASON-KIND s" " ENDOF
   ;MATCH ;

\ Whether the held observation is o.
: OBSERVED? ( MODEL:observation<MODEL:local> ^stored -- bool )
   {: o st :}
   o RECORD-KIND {: k:n c:str :}
   st STORED-KIND @ k <> if false exit then
   st STORED-CONTENT @ c STR:= ;

\ Stages the record when stage holds, and its path's hash gone when
\ gone holds. The statements are the scan's, its stream on top.
: SEEN-STAGED
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement MODEL:local-record bool bool ^ARENA:arena
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: r stage:bool gone:bool ar :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   >r >r
   gone if p MODEL:PATH>STR TOMBSTONE-INSERTED then
   >r stage if r ar LOCAL-INSERTED ar ARENA:RESET then r>
   r> r> ;

\ A job at p; with cached, the hash held there is gone until the job
\ hashes the file again.
: JOB-STAGED
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement str MODEL:fingerprint bool
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: p:str f cached:bool :}
   >r p f JOB-INSERTED
   >r cached if p TOMBSTONE-INSERTED then r>
   r> ;

\ The held group, which the walk passed over, staged gone; a cached hash
\ beneath an unknown path stays, so the subtree is not hashed again.
: GROUP-PASSED
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement ^stored
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: st :}
   st STORED-PATH @ {: p:str :}
   st STORED-CACHED @ p st BENEATH-UNKNOWN? 0= and {: gone:bool :}
   >r >r gone if p TOMBSTONE-INSERTED then
   >r st STORED-KIND @ NO-KIND <> if p GONE-INSERTED then r>
   r> r> st NEXT-GROUP ;

\ Stages gone each group held below p.
: PASSED-BELOW
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement str ^stored
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: p:str st :}
   begin p st BELOW? while st GROUP-PASSED repeat ;

\ Stages gone every group still held: the walk is over.
: STREAM-ENDED
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement ^stored
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: st :}
   begin st GROUP-HELD? while st GROUP-PASSED repeat ;

\ The cached hash staged as the observation at p.
: CACHE-STAGED
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement str ^stored ^ARENA:arena
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: p:str st ar :}
   p MODEL:>PATH st STORED-DIGEST @ DROPBOX:>HASH MODEL-LOCAL:MAKE
   MODEL-OBSERVATION:PRESENT MODEL-LOCAL--RECORD:MAKE
   true false ar SEEN-STAGED ;

\ The file at the held path: nothing staged when the cache and the
\ observation both agree with it, the cached hash's observation when
\ only the cache does, and else a job.
: FILE-REACHED
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement str MODEL:fingerprint option<MODEL:cutoff> ^stored
     ^ARENA:arena
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: p:str f o:option<MODEL:cutoff> st ar :}
   f o st CACHE-AGREES? 0= if
      p f st STORED-CACHED @ JOB-STAGED st NEXT-GROUP exit
   then
   st CACHE-OBSERVED? 0= if p st ar CACHE-STAGED then
   st NEXT-GROUP ;

\ A directory or unknown entry at the held path: staged unless the
\ stored observation is the same; a hash held there is gone.
: SEEN-REACHED
   ( SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement MODEL:local-record ^stored ^ARENA:arena
     -- SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: r st ar :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   o RECORD-KIND {: k:n c:str :}
   o st OBSERVED? 0= {: stage:bool :}
   st STORED-CACHED @ k KIND-PRESENT <> and {: gone:bool :}
   r stage gone ar SEEN-STAGED st NEXT-GROUP ;

: UNKNOWN-RECORD? ( MODEL:local-record -- bool )
   MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   o RECORD-KIND {: k:n c:str :}
   k KIND-ABSENT > ;

: RECORD-PATH ( MODEL:local-record -- str )
   MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   p MODEL:PATH>STR ;

\ Stages gone every group still held, the walk over.
: WALK-ENDED ( scan -- scan )
   SCAN-UNMAKE {: st j ar :}
   st STREAM-ENDED
   st j ar SCAN-MAKE ;

: NEW-STORED ( ^ARENA:arena ^ARENA:arena -- ^stored )
   {: sa ga :}
   sa STORES-NEW {: st :}
   construct stored-state ended st STORED-STATE !  0 st STORED-ROWS !
   ga st STORED-GROUP !
   sa ARENA:ALLOCATOR 0 [type] u8 VEC:NEW st STORED-UNKNOWN !
   sa ARENA:ALLOCATOR 0 [type] n VEC:NEW st STORED-PREFIXES !
   st ;

\ The scan of the statements handed to body: ar holds its writes' keys,
\ sa its stored state and ga the group it holds.
: SCAN-RUN
   ( R SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement ^ARENA:arena ^ARENA:arena ^ARENA:arena journal
     [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: ar sa ga j body :}
   sa ga NEW-STORED {: st :}
   st STREAM-OPENED
   st j ar SCAN-MAKE body execute
   SCAN-UNMAKE drop drop drop ;

: STREAM-PREPARED
   ( R SQLITE:statement SQLITE:statement SQLITE:statement journal
     [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement SQLITE:statement )
   {: j body :}
   j >CONNECTION STREAM-SCAN [:
      [: [: [: j body SCAN-RUN ;] ARENA:WITH ;] ARENA:WITH ;] ARENA:WITH
   ;] SQLITE:WITH-STATEMENT ;

: JOB-PREPARED
   ( R SQLITE:statement SQLITE:statement journal [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement )
   {: j body :}
   j >CONNECTION JOB-SCAN [: j body STREAM-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

: HASH-PREPARED
   ( R SQLITE:statement journal [ R scan -- S scan ]
     -- S SQLITE:statement )
   {: j body :}
   j >CONNECTION HASH-SCAN [: j body JOB-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

: SCAN-JOURNAL ( scan -- scan journal )
   SCAN-UNMAKE {: st j ar :}
   st j ar SCAN-MAKE j ;

\ Runs visit on each row the statement answers, in ar reset before each.
: VISITED
   ( R scan SQLITE:statement ^ARENA:arena
     [ R scan SQLITE:statement ^ARENA:arena -- R scan SQLITE:statement ]
     -- R scan SQLITE:statement )
   {: ar visit :}
   begin SQLITE:STEP while ar ARENA:RESET ar visit execute repeat ;

\ VISITED in an arena of its own.
: ROWS-VISITED
   ( R scan SQLITE:statement
     [ R scan SQLITE:statement ^ARENA:arena -- R scan SQLITE:statement ]
     -- R scan SQLITE:statement )
   {: visit :}
   [: visit VISITED ;] ARENA:WITH ;

\ Visits the rows select answers, then runs empty.
: EACH-ROW
   ( R scan
     [ R scan SQLITE:statement ^ARENA:arena -- R scan SQLITE:statement ]
     str str -- R scan )
   {: visit select:str empty:str :}
   SCAN-JOURNAL >CONNECTION {: c :}
   c select [: visit ROWS-VISITED ;] SQLITE:WITH-STATEMENT
   c empty SQLITE:EXEC ;

: JOB-VISITED
   ( R scan SQLITE:statement ^ARENA:arena
     [ R scan str MODEL:fingerprint -- R scan ]
     -- R scan SQLITE:statement )
   {: ar body :}
   ar JOB-ROW {: p:str f :}
   >r p f body execute r> ;

\ Deletes each staged observation gone and writes each other that
\ differs.
: OBSERVATIONS-DIFFERENCE ( -- str )
   s" DELETE FROM local_observations WHERE path IN (
         SELECT path FROM temp.scan_observations WHERE kind = 2
      );
      INSERT INTO local_observations(path, canonical_path, kind, content)
         SELECT path, canonical_path, kind, content
         FROM temp.scan_observations WHERE kind != 2
      ON CONFLICT(path) DO UPDATE SET
         canonical_path = excluded.canonical_path,
         kind = excluded.kind,
         content = excluded.content
      WHERE local_observations.canonical_path != excluded.canonical_path
         OR local_observations.kind != excluded.kind
         OR local_observations.content IS NOT excluded.content;" ;

\ ?1 is the active generation; a row of any other is deleted.
: OTHER-GENERATIONS ( -- str )
   s" DELETE FROM local_hash_cache
      WHERE root_generation < ?1 OR root_generation > ?1" ;

\ The active generation's rows whose hash the scan staged gone.
: GONE-HASHES ( -- str )
   s" DELETE FROM local_hash_cache
      WHERE root_generation = ?1 AND path IN (
         SELECT path FROM temp.scan_hashes WHERE content_hash IS NULL
      )" ;

\ The scan's hashes, each written where it differs.
: FRESH-HASHES ( -- str )
   s" INSERT INTO local_hash_cache(
         root_generation, path, inode, size, modified_seconds,
         modified_nanoseconds, changed_seconds, changed_nanoseconds,
         content_hash
      ) SELECT ?1, path, inode, size, modified_seconds,
         modified_nanoseconds, changed_seconds, changed_nanoseconds,
         content_hash
      FROM temp.scan_hashes WHERE content_hash IS NOT NULL
      ON CONFLICT(root_generation, path) DO UPDATE SET
         inode = excluded.inode,
         size = excluded.size,
         modified_seconds = excluded.modified_seconds,
         modified_nanoseconds = excluded.modified_nanoseconds,
         changed_seconds = excluded.changed_seconds,
         changed_nanoseconds = excluded.changed_nanoseconds,
         content_hash = excluded.content_hash
      WHERE local_hash_cache.inode != excluded.inode
         OR local_hash_cache.size != excluded.size
         OR local_hash_cache.modified_seconds
            != excluded.modified_seconds
         OR local_hash_cache.modified_nanoseconds
            != excluded.modified_nanoseconds
         OR local_hash_cache.changed_seconds
            != excluded.changed_seconds
         OR local_hash_cache.changed_nanoseconds
            != excluded.changed_nanoseconds
         OR local_hash_cache.content_hash != excluded.content_hash" ;

\ g, the generation, was read as an SQLite integer, so it binds as one.
: AT-GENERATION ( SQLITE:connection n str -- )
   {: c g sql:str :}
   c sql [: g 1 SQLITE:BIND-INT RAN ;] SQLITE:WITH-STATEMENT ;

: DIFFERENCE-WRITTEN ( SQLITE:connection n -- )
   {: c g :}
   c OBSERVATIONS-DIFFERENCE SQLITE:EXEC
   c g OTHER-GENERATIONS AT-GENERATION
   c g GONE-HASHES AT-GENERATION
   c g FRESH-HASHES AT-GENERATION ;

: ACTIVE-DIFFERENCE
   ( local-root-record journal local-root-binding -- bool )
   {: r j b :}
   r >BINDING b ROOT= 0= if false exit then
   j >CONNECTION r >GENERATION DIFFERENCE-WRITTEN
   true ;

: BOUND-DIFFERENCE
   ( journal local-root-binding ^ARENA:arena -- bool )
   {: j b ar :}
   j ar LOCAL-ROOT-BINDING MATCH option
      none OF false ENDOF
      some OF j b ACTIVE-DIFFERENCE ENDOF
   ;MATCH ;

\ BOUND-DIFFERENCE; on publishing, the folders the scan listed are clean,
\ those it tried stirred again and those it staged as no folder
\ forgotten.
: PUBLISHED ( journal local-root-binding ^ARENA:arena -- bool )
   {: j b ar :}
   j b ar BOUND-DIFFERENCE {: done:bool :}
   done if j LISTED-CLEANED then
   done ;

public

\ Runs body over a scan that starts empty, to publish with PUBLISH-SCAN;
\ body hands the scan back. The walk's SCAN-FILE and SCAN-SEEN calls
\ come first, in path byte order through the whole walk or within each
\ range from SCAN-FROM to SCAN-TO, and end at EACH-SCAN-JOB or
\ PUBLISH-SCAN; a scan of ranges alone calls SCAN-STOP first. However
\ body ends, by returning or by a throw, every folder it marked listed or
\ tried and did not publish is stirred again.
: WITH-SCAN ( R journal [ R scan -- S scan ] -- S )
   {: j body :}
   [: j >CONNECTION SCAN-TABLES SQLITE:EXEC
      j >CONNECTION OBSERVE-SCAN [: j body HASH-PREPARED ;]
      SQLITE:WITH-STATEMENT ;]
   [: j LISTED-STIRRED ;] finally ;

\ The file the walk found at p with the fingerprint: nothing is staged
\ when the active root's cache holds the fingerprint, both its times
\ before the cutoff, and the stored observation is that hash; the
\ hash's observation is when only the cache agrees; else a job is,
\ and any hash the cache held at p is gone until the job hashes the
\ file. Every stored path the walk passed over is staged gone.
: SCAN-FILE ( scan str MODEL:fingerprint option<MODEL:cutoff> -- scan )
   {: p:str f o:option<MODEL:cutoff> :}
   SCAN-UNMAKE {: st j ar :}
   p st PASSED-BELOW
   p st AT? if p f o st ar FILE-REACHED
   else p f false JOB-STAGED then
   st j ar SCAN-MAKE ;

\ A directory or unknown entry the walk found: staged unless stored
\ the same, any hash the cache held at its path gone. Every stored path
\ the walk passed over is staged gone; beneath an unknown entry, which
\ the walk does not enter, its cached hash stays.
: SCAN-SEEN ( scan MODEL:local-record -- scan )
   {: r :}
   r RECORD-PATH {: p:str :}
   SCAN-UNMAKE {: st j ar :}
   p st PASSED-BELOW
   p st AT? if r st ar SEEN-REACHED
   else r true false ar SEEN-STAGED then
   r UNKNOWN-RECORD? if p st UNKNOWN-HELD then
   st j ar SCAN-MAKE ;

\ The folder at p, not entered, at its subtree's turn: stored groups
\ below p then "/" the walk passed over are gone; those beneath p stay.
: SCAN-SKIP ( scan str -- scan )
   {: p:str :}
   SCAN-UNMAKE {: st j ar :}
   p SLASH ar SUFFIXED st PASSED-BELOW
   p SLASH 1+ ar SUFFIXED {: past:str :}
   past st BELOW? if past st SOUGHT then
   ar ARENA:RESET
   st j ar SCAN-MAKE ;

\ Starts the range of the folder at p, "" the root's: the group held is
\ dropped, staging nothing, and the stream starts anew beneath p.
: SCAN-FROM ( scan str -- scan )
   {: p:str :}
   SCAN-UNMAKE {: st j ar :}
   st STORED-UNKNOWN @ 0 VEC:RESIZE
   st STORED-PREFIXES @ 0 VEC:RESIZE
   p ar RANGE-START st SOUGHT
   ar ARENA:RESET
   st j ar SCAN-MAKE ;

\ Stops the stream, staging nothing, until the next SCAN-FROM, so stored
\ rows outside the ranges that follow stay.
: SCAN-STOP ( scan -- scan )
   SCAN-UNMAKE {: st j ar :}
   st STORED-UNKNOWN @ 0 VEC:RESIZE
   st STORED-PREFIXES @ 0 VEC:RESIZE
   st GROUP-DROPPED
   st j ar SCAN-MAKE ;

\ Whether the scan has staged an observation at p, of any kind.
: SCAN-STAGED? ( scan str -- scan bool )
   {: p:str :}
   SCAN-UNMAKE {: st j ar :}
   j >CONNECTION
   s" SELECT 1 FROM temp.scan_observations WHERE path = ?1"
   [: p 1 SQLITE:BIND-BLOB CLEAN-ROW ;] SQLITE:WITH-STATEMENT
   {: staged:bool :}
   st j ar SCAN-MAKE staged ;

\ Ends the range of the folder at p: stored groups beneath p the walk
\ passed over are gone, and the stream stops until the next SCAN-FROM.
: SCAN-TO ( scan str -- scan )
   {: p:str :}
   SCAN-UNMAKE {: st j ar :}
   p str> nip 0= if st STREAM-ENDED
   else p SLASH 1+ ar SUFFIXED st PASSED-BELOW then
   st GROUP-DROPPED
   ar ARENA:RESET
   st j ar SCAN-MAKE ;

\ Records the observation in the scan, replacing one at its path.
: SCAN-OBSERVE ( scan MODEL:local-record -- scan )
   {: r :}
   SCAN-UNMAKE {: st j ar :}
   >r >r >r
   r ar LOCAL-INSERTED ar ARENA:RESET
   r> r> r>
   st j ar SCAN-MAKE ;

\ Records the hash in the scan, replacing one at its path.
: SCAN-HASH ( scan MODEL:hash-record -- scan )
   {: r :}
   SCAN-UNMAKE {: st j ar :}
   >r >r
   r HASH-INSERTED
   r> r>
   st j ar SCAN-MAKE ;

\ The walk over, runs body on each file to hash in path byte order, then
\ forgets them. A row is valid only during body, which reads no journal
\ table and writes the scan only through SCAN-OBSERVE and SCAN-HASH.
: EACH-SCAN-JOB
   ( R scan [ R scan str MODEL:fingerprint -- R scan ] -- R scan )
   {: body :}
   WALK-ENDED
   [: body JOB-VISITED ;]
   s" SELECT path, inode, size, modified_seconds, modified_nanoseconds,
         changed_seconds, changed_nanoseconds
      FROM temp.scan_jobs ORDER BY path"
   s" DELETE FROM temp.scan_jobs" EACH-ROW ;

\ The walk over, applies what the scan staged to the local inventory
\ and the active root's hash cache, makes every folder it listed clean
\ and forgets every one it staged as no folder, in one transaction,
\ which an unchanged tree leaves without a write; false, nothing
\ written, when binding is no longer the active root.
: PUBLISH-SCAN ( scan local-root-binding -- scan bool )
   {: b :}
   WALK-ENDED
   SCAN-JOURNAL {: j :}
   j >CONNECTION [: j b [: PUBLISHED ;] ARENA:WITH ;]
   SQLITE:WITH-TRANSACTION ;

private


\ ---- the remote inventory ------------------------------------------

: UPSERT-REMOTE ( -- str )
   s" INSERT INTO remote_observations(
         path, canonical_path, kind, content, revision
      ) VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(canonical_path) DO UPDATE SET
         path = excluded.path,
         kind = excluded.kind,
         content = excluded.content,
         revision = excluded.revision
      WHERE remote_observations.path != excluded.path
         OR remote_observations.kind != excluded.kind
         OR remote_observations.content IS NOT excluded.content
         OR remote_observations.revision IS NOT excluded.revision" ;

\ An unknown observation, kind 3 on, stays.
: ENSURE-REMOTE ( -- str )
   s" INSERT INTO remote_observations(
         path, canonical_path, kind, content, revision
      ) VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(canonical_path) DO UPDATE SET
         kind = excluded.kind,
         content = excluded.content,
         revision = excluded.revision
      WHERE remote_observations.kind < 3
         AND (remote_observations.kind != excluded.kind
            OR remote_observations.content IS NOT excluded.content
            OR remote_observations.revision IS NOT excluded.revision)" ;

: DELETE-REMOTE-DESCENDANTS ( -- str )
   s" DELETE FROM remote_observations
      WHERE canonical_path >= ?1 AND canonical_path < ?2" ;

\ Binds the record's path and key to ?1 and ?2, its observation to ?3
\ to ?5; an absent one binds kind 2, which the table refuses.
: BIND-REMOTE
   ( SQLITE:statement MODEL:remote-record -- SQLITE:statement )
   MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   p MODEL:PATH>STR 1 SQLITE:BIND-BLOB
   k MODEL:KEY>STR 2 SQLITE:BIND-BLOB
   o MATCH MODEL:observation
      present OF BIND-PRESENT ENDOF
      directory OF KIND-DIRECTORY BIND-KIND ENDOF
      absent OF KIND-ABSENT BIND-KIND ENDOF
      unknown OF REASON-KIND BIND-KIND ENDOF
   ;MATCH ;

: PUBLISH-CURSOR ( SQLITE:connection DROPBOX:cursor -- )
   {: c cur:DROPBOX:cursor :}
   c s" INSERT INTO remote_inventory(singleton, cursor) VALUES (1, ?1)
      ON CONFLICT(singleton) DO UPDATE SET cursor = excluded.cursor" [: cur DROPBOX:CURSOR>STR 1 SQLITE:BIND-TEXT RAN ;]
   SQLITE:WITH-STATEMENT ;

\ An entry holds one key: its row at lower is replaced.
: HOLD-WRITTEN ( SQLITE:connection MODEL:path MODEL:key MODEL:path -- )
   {: c l:MODEL:path k:MODEL:key p:MODEL:path :}
   c s" INSERT INTO remote_mismatches(lower, canonical_path, path)
      VALUES (?1, ?2, ?3)
      ON CONFLICT(lower) DO UPDATE SET
         canonical_path = excluded.canonical_path, path = excluded.path" [: l MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      k MODEL:KEY>STR 2 SQLITE:BIND-BLOB
      p MODEL:PATH>STR 3 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The holds of the entries at the bytes or beneath them.
: HOLDS-DELETED ( SQLITE:connection str -- )
   {: c s:str :}
   c s" DELETE FROM remote_mismatches
      WHERE lower = ?1
         OR (lower > CAST(?1 || '/' AS BLOB)
            AND lower < CAST(?1 || '0' AS BLOB))" [: s 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The hold in the statement's row: lower, canonical_path, path.
: HOLD-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement remote-inventory-change )
   {: ar :}
   0 ar PATH-COPY {: l :}
   1 ar BLOB-COPY MODEL:>KEY {: k :}
   2 ar PATH-COPY {: p :}
   l k p JOURNAL-REMOTE--INVENTORY--CHANGE:HOLD ;

public

\ The stored holds of the key and of every key beneath it, each a
\ hold change, by lower.
: SUBTREE-HOLDS
   ( journal MODEL:key ^ARENA:arena
     -- ^VEC:vector<remote-inventory-change> )
   {: j k ar :}
   ar ARENA:ALLOCATOR 0 [type] remote-inventory-change VEC:NEW {: v :}
   k ar MODEL:SUBTREE-RANGE {: lo:str hi:str :}
   j >CONNECTION s" SELECT lower, canonical_path, path FROM remote_mismatches
      WHERE canonical_path = ?1
         OR (canonical_path >= ?2 AND canonical_path < ?3)
      ORDER BY lower" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
      lo 2 SQLITE:BIND-BLOB hi 3 SQLITE:BIND-BLOB
      begin SQLITE:STEP while ar HOLD-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

private

\ Hides each held key's record behind an unsupported one, kind 8,
\ spelled as the key's hold of least lower spells it.
: SETTLE ( SQLITE:connection -- )
   s" INSERT INTO remote_shadows(
         canonical_path, path, kind, content, revision)
      SELECT canonical_path, path, kind, content, revision
      FROM remote_observations WHERE canonical_path IN
         (SELECT canonical_path FROM remote_mismatches);
      DELETE FROM remote_observations WHERE canonical_path IN
         (SELECT canonical_path FROM remote_mismatches);
      INSERT INTO remote_observations(canonical_path, path, kind)
      SELECT canonical_path, path, 8 FROM remote_mismatches AS m
      WHERE lower = (SELECT min(lower) FROM remote_mismatches
         WHERE canonical_path = m.canonical_path);" SQLITE:EXEC ;

\ Undoes SETTLE while remote_mismatches holds the keys SETTLE saw.
: UNSETTLE ( SQLITE:connection -- )
   s" DELETE FROM remote_observations WHERE canonical_path IN
         (SELECT canonical_path FROM remote_mismatches);
      INSERT INTO remote_observations(
         canonical_path, path, kind, content, revision)
      SELECT canonical_path, path, kind, content, revision
      FROM remote_shadows;
      DELETE FROM remote_shadows;" SQLITE:EXEC ;

: DELTA-INVALID ( str str -- )
   {: path:str detail:str :}
   s" validate remote inventory delta" path detail INVALID ;

\ An upserted or ensured record's key is its path's.
: CHECK-KEY ( MODEL:remote-record ^ARENA:arena -- )
   {: r ar :}
   r MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   p ar MODEL:FOLD k MODEL:KEY= if exit then
   p MODEL:PATH>STR
   s" canonical path does not match display path" DELTA-INVALID ;

: REMOTE-DIRECTORY ( -- MODEL:observation<MODEL:remote> )
   MODEL-OBSERVATION:DIRECTORY ;

: RECORD-DIRECTORY? ( MODEL:remote-record -- bool )
   MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   o REMOTE-DIRECTORY MODEL:REMOTE-OBSERVATION= ;

: CHECK-ENSURED ( MODEL:remote-record ^ARENA:arena -- )
   {: r ar :}
   r ar CHECK-KEY
   r RECORD-DIRECTORY? if exit then
   r MODEL-REMOTE--RECORD:UNMAKE {: k:MODEL:key p:MODEL:path o :}
   p MODEL:PATH>STR
   s" ensured remote ancestor is not a directory" DELTA-INVALID ;

: CHECK-SUBTREE ( MODEL:key -- )
   {: k:MODEL:key :}
   k MODEL:KEY>STR STR:len 0<> if exit then
   k MODEL:KEY>STR
   s" subtree deletion path is empty" DELTA-INVALID ;

\ A hold's key is its lower's fold, and its lower names an entry.
: CHECK-HOLD ( MODEL:path MODEL:key ^ARENA:arena -- )
   {: l:MODEL:path k:MODEL:key ar :}
   l MODEL:PATH>STR {: s:str :}
   s STR:len 0<> if l ar MODEL:FOLD k MODEL:KEY= if exit then then
   s s" canonical path does not match display path" DELTA-INVALID ;

: CHECK-CHANGE ( remote-inventory-change ^ARENA:arena -- )
   {: ar :}
   MATCH remote-inventory-change
      upsert OF ar CHECK-KEY ENDOF
      ensure-directory OF ar CHECK-ENSURED ENDOF
      delete-subtree OF CHECK-SUBTREE ENDOF
      hold OF {: l:MODEL:path k:MODEL:key p:MODEL:path :}
         l k ar CHECK-HOLD
         p ar MODEL:FOLD k MODEL:KEY= 0= if
            p MODEL:PATH>STR
            s" canonical path does not match display path" DELTA-INVALID
         then
      ENDOF
      unhold OF ar CHECK-HOLD ENDOF
   ;MATCH ;

: DELTA-CHECKED
   ( ^VEC:vector<remote-inventory-change> ^ARENA:arena -- )
   {: v ar :}
   v VEC:COUNT 0 ?do v i VEC:AT @ ar CHECK-CHANGE loop ;

\ The record written by the statement sql names.
: RECORD-WRITTEN ( SQLITE:connection MODEL:remote-record str -- )
   {: c r sql:str :}
   c sql [: r BIND-REMOTE SQLITE:STEP drop ;] SQLITE:WITH-STATEMENT ;

: SUBTREE-DELETED ( SQLITE:connection MODEL:key ^ARENA:arena -- )
   {: c k:MODEL:key ar :}
   c s" DELETE FROM remote_observations WHERE canonical_path = ?1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   k ar MODEL:SUBTREE-RANGE {: lo:str hi:str :}
   c DELETE-REMOTE-DESCENDANTS
    [: lo 1 SQLITE:BIND-BLOB hi 2 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c k MODEL:KEY>STR HOLDS-DELETED ;

: CHANGE-APPLIED
   ( remote-inventory-change SQLITE:connection ^ARENA:arena -- )
   {: c ar :}
   MATCH remote-inventory-change
      upsert OF {: r :} c r UPSERT-REMOTE RECORD-WRITTEN ENDOF
      ensure-directory OF
         {: r :} c r ENSURE-REMOTE RECORD-WRITTEN
      ENDOF
      delete-subtree OF {: k :} c k ar SUBTREE-DELETED ENDOF
      hold OF {: l k p :} c l k p HOLD-WRITTEN ENDOF
      unhold OF
         drop {: l :} c l MODEL:PATH>STR HOLDS-DELETED
      ENDOF
   ;MATCH ;

: DELTA-WRITTEN
   ( SQLITE:connection DROPBOX:cursor
     ^VEC:vector<remote-inventory-change> ^ARENA:arena -- )
   {: c cur:DROPBOX:cursor v ar :}
   c UNSETTLE
   v VEC:COUNT 0 ?do v i VEC:AT @ c ar CHANGE-APPLIED loop
   c SETTLE
   c cur PUBLISH-CURSOR ;

\ Every change is checked before the transaction begins.
: DELTA-APPLIED
   ( SQLITE:connection DROPBOX:cursor
     ^VEC:vector<remote-inventory-change> ^ARENA:arena -- )
   {: c cur:DROPBOX:cursor v ar :}
   v ar DELTA-CHECKED
   c [: c cur v ar DELTA-WRITTEN ;] SQLITE:WITH-TRANSACTION ;

public

\ Applies a cursor continuation's changes, in order, and publishes its
\ cursor, in one transaction.
: APPLY-REMOTE-INVENTORY-DELTA
   ( journal DROPBOX:cursor ^VEC:vector<remote-inventory-change> -- )
   {: j cur:DROPBOX:cursor v :}
   j >CONNECTION cur v [: DELTA-APPLIED ;] ARENA:WITH ;

private


\ ---- a full listing's staging --------------------------------------

\ Staged observations carry no CHECK, so a later change may replace or delete
\ a record remote_observations refuses; publication refuses only what is left.
: LISTING-TABLES ( journal -- )
   >CONNECTION
   s" CREATE TABLE IF NOT EXISTS temp.listing_observations(
         canonical_path BLOB PRIMARY KEY NOT NULL,
         path BLOB NOT NULL,
         kind INTEGER NOT NULL,
         content TEXT,
         revision TEXT
      ) STRICT;
      CREATE TABLE IF NOT EXISTS temp.listing_mismatches(
         lower BLOB PRIMARY KEY NOT NULL,
         canonical_path BLOB NOT NULL,
         path BLOB NOT NULL
      ) STRICT;
      DELETE FROM temp.listing_observations;
      DELETE FROM temp.listing_mismatches;" SQLITE:EXEC ;

: CLEAR-LISTING ( journal -- )
   >CONNECTION
   s" DROP TABLE IF EXISTS temp.listing_observations;
      DROP TABLE IF EXISTS temp.listing_mismatches;" SQLITE:EXEC ;

: STAGED-UPSERT ( -- str )
   s" INSERT OR REPLACE INTO temp.listing_observations(
         path, canonical_path, kind, content, revision
      ) VALUES (?1, ?2, ?3, ?4, ?5)" ;

\ A staged row keeps its spelling, and an unknown one, kind 3 on, its
\ observation.
: STAGED-ENSURE ( -- str )
   s" INSERT INTO temp.listing_observations(
         path, canonical_path, kind, content, revision
      ) VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(canonical_path) DO UPDATE SET
         kind = 1, content = NULL, revision = NULL
      WHERE listing_observations.kind < 3" ;

\ The staged holds of the entries at the bytes or beneath them.
: STAGED-HOLDS-DELETED ( SQLITE:connection str -- )
   {: c s:str :}
   c s" DELETE FROM temp.listing_mismatches
      WHERE lower = ?1
         OR (lower > CAST(?1 || '/' AS BLOB)
            AND lower < CAST(?1 || '0' AS BLOB))" [: s 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: STAGED-SUBTREE-DELETED
   ( SQLITE:connection MODEL:key ^ARENA:arena -- )
   {: c k:MODEL:key ar :}
   k ar MODEL:SUBTREE-RANGE {: lo:str hi:str :}
   c s" DELETE FROM temp.listing_observations
      WHERE canonical_path = ?1
         OR (canonical_path >= ?2 AND canonical_path < ?3)" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
      lo 2 SQLITE:BIND-BLOB hi 3 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c k MODEL:KEY>STR STAGED-HOLDS-DELETED ;

\ An entry holds one key: its staged row at lower is replaced.
: STAGED-HOLD ( SQLITE:connection MODEL:path MODEL:key MODEL:path -- )
   {: c l:MODEL:path k:MODEL:key p:MODEL:path :}
   c s" INSERT OR REPLACE INTO temp.listing_mismatches(
         lower, canonical_path, path
      ) VALUES (?1, ?2, ?3)" [: l MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      k MODEL:KEY>STR 2 SQLITE:BIND-BLOB
      p MODEL:PATH>STR 3 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: STAGE-CHANGE
   ( remote-inventory-change SQLITE:connection ^ARENA:arena -- )
   {: c ar :}
   MATCH remote-inventory-change
      upsert OF {: r :} c r STAGED-UPSERT RECORD-WRITTEN ENDOF
      ensure-directory OF
         {: r :} c r STAGED-ENSURE RECORD-WRITTEN
      ENDOF
      delete-subtree OF {: k :} c k ar STAGED-SUBTREE-DELETED ENDOF
      hold OF {: l k p :} c l k p STAGED-HOLD ENDOF
      unhold OF
         drop {: l :} c l MODEL:PATH>STR STAGED-HOLDS-DELETED
      ENDOF
   ;MATCH ;

\ Every change is checked before the transaction begins.
: BATCH-STAGED
   ( SQLITE:connection ^VEC:vector<remote-inventory-change>
     ^ARENA:arena -- )
   {: c v ar :}
   v ar DELTA-CHECKED
   c [: v VEC:COUNT 0 ?do v i VEC:AT @ c ar STAGE-CHANGE loop ;]
   SQLITE:WITH-TRANSACTION ;

: LISTING-INVALID ( str str -- )
   {: path:str detail:str :}
   s" publish remote inventory listing" path detail INVALID ;

\ A part Path::file_name does not skip: neither empty nor ".".
: NAMED? ( str -- bool )
   {: s:str :}
   s STR:len 0<> s s" ." STR:= 0= and ;

\ The index of the last separator before at, or -1.
: SEPARATOR-BEFORE ( str n -- n )
   {: s:str at:n :}
   s str> drop {: p:^ :}
   at begin 1- dup 0 >= while
      dup p + c@ SLASH = if exit then
   repeat ;

\ The last part NAMED? accepts before at, else empty.
: NAME-BEFORE ( str n -- str )
   {: s:str at:n :}
   s at SEPARATOR-BEFORE {: sep:n :}
   s str> drop sep 1+ + at sep 1+ - >str {: part:str :}
   part NAMED? if part exit then
   sep 0 < if s" " exit then
   s sep RECURSE ;

\ Path::file_name of a folder's path, its casing.
: FOLDER-NAME ( str -- str )
   {: p:str :}
   p p STR:len NAME-BEFORE {: name:str :}
   name STR:len 0= name s" .." STR:= or if
      p s" a folder's path has no name" LISTING-INVALID
   then
   name ;

\ The spelling of the folder or restricted folder staged at a key.
: FOLDER-SPELLING ( -- str )
   s" SELECT path FROM temp.listing_observations
      WHERE canonical_path = ?1 AND kind IN (1, 4)" ;

\ Appends the part, after a separator unless out is empty.
: PART+ ( str ^VEC:vector<u8> -- )
   {: s:str out :}
   out VEC:COUNT 0 > if SLASH out VEC:PUSH c! then
   s out VEC:APPEND ;

\ Appends the casing of the folder staged at the key bytes, if one is;
\ whether one is.
: CASING+
   ( SQLITE:statement str ^VEC:vector<u8>
     -- SQLITE:statement bool )
   {: k:str out :}
   k 1 SQLITE:BIND-BLOB SQLITE:STEP if
      0 SQLITE:COL-BLOB FOLDER-NAME out PART+ true
   else false then
   >r SQLITE:RESET r> ;

\ Appends each part of the key from ki, spelled by its casing, else as
\ the path's part from pi.
: SPELLED-FROM
   ( SQLITE:statement str str n n ^VEC:vector<u8> -- SQLITE:statement )
   {: ks:str ps:str ki:n pi:n out :}
   ks SLASH ki STR:SPLIT-NEXT drop {: kp:str kn:n :}
   ps SLASH pi STR:SPLIT-NEXT drop {: pp:str pn:n :}
   ks str> drop kn 1- >str out CASING+ 0= if pp out PART+ then
   kn ks STR:len > if exit then
   ks ps kn pn out RECURSE ;

\ Each part of the path takes the casing of the folder staged at the
\ key up to it, if one is.
: LISTING-PATH
   ( SQLITE:statement MODEL:key MODEL:path ^ARENA:arena
     -- SQLITE:statement MODEL:path )
   {: k:MODEL:key p:MODEL:path ar :}
   k MODEL:KEY>STR {: ks:str :}
   p MODEL:PATH>STR {: ps:str :}
   ks SLASH STR:COUNT-CHAR ps SLASH STR:COUNT-CHAR <> if
      ps s" its parts are not its canonical path's" LISTING-INVALID
   then
   ar ARENA:ALLOCATOR 0 [type] u8 VEC:NEW {: out :}
   ks ps 0 0 out SPELLED-FROM
   out VEC:BYTES MODEL:>PATH ;

\ Writes the select's row, its id, key and path, with the path respelled;
\ the statements are FOLDER-SPELLING's, the write's and the select's.
: ROW-PUBLISHED
   ( SQLITE:statement SQLITE:statement SQLITE:statement ^ARENA:arena
     -- SQLITE:statement SQLITE:statement SQLITE:statement )
   {: ar :}
   0 SQLITE:COL-BLOB {: id:str :}
   1 SQLITE:COL-BLOB MODEL:>KEY {: k :}
   2 SQLITE:COL-BLOB MODEL:>PATH {: p :}
   rot k p ar LISTING-PATH {: q :}
   rot q MODEL:PATH>STR 1 SQLITE:BIND-BLOB id 2 SQLITE:BIND-BLOB RAN
   rot ;

: ROWS-PUBLISHED
   ( SQLITE:statement SQLITE:statement SQLITE:statement ^ARENA:arena
     -- SQLITE:statement SQLITE:statement SQLITE:statement )
   {: ar :}
   begin SQLITE:STEP while ar ROW-PUBLISHED ar ARENA:RESET repeat ;

\ Each row select answers written through write, one row's scratch in
\ ar at a time.
: LISTED-ROWS ( SQLITE:connection str str ^ARENA:arena -- )
   {: c write:str select:str ar :}
   c FOLDER-SPELLING [: c write [: c select [: ar ROWS-PUBLISHED ;]
      SQLITE:WITH-STATEMENT ;] SQLITE:WITH-STATEMENT ;]
   SQLITE:WITH-STATEMENT ;

: LISTED-OBSERVATIONS ( -- str str )
   s" INSERT INTO remote_observations(
         path, canonical_path, kind, content, revision)
      SELECT ?1, canonical_path, kind, content, revision
      FROM temp.listing_observations WHERE canonical_path = ?2"
   s" SELECT canonical_path, canonical_path, path
      FROM temp.listing_observations" ;

: LISTED-HOLDS ( -- str str )
   s" INSERT INTO remote_mismatches(lower, canonical_path, path)
      SELECT lower, canonical_path, ?1
      FROM temp.listing_mismatches WHERE lower = ?2"
   s" SELECT lower, canonical_path, path
      FROM temp.listing_mismatches" ;

: LISTING-WRITTEN
   ( SQLITE:connection DROPBOX:cursor ^ARENA:arena -- )
   {: c cur:DROPBOX:cursor ar :}
   c s" DELETE FROM remote_observations;
      DELETE FROM remote_mismatches;
      DELETE FROM remote_shadows;" SQLITE:EXEC
   c LISTED-OBSERVATIONS ar LISTED-ROWS
   c LISTED-HOLDS ar LISTED-ROWS
   c SETTLE
   c cur PUBLISH-CURSOR ;

: PUBLISH-LISTING ( journal DROPBOX:cursor -- )
   {: j cur:DROPBOX:cursor :}
   j >CONNECTION {: c :}
   c [: c cur [: LISTING-WRITTEN ;] ARENA:WITH ;]
   SQLITE:WITH-TRANSACTION ;

public

\ body stages a full listing with STAGE-LISTING and answers its cursor;
\ one transaction then replaces the inventory, holds and cursor with it.
: WITH-REMOTE-LISTING ( journal [ -- DROPBOX:cursor ] -- )
   {: j body :}
   [: j LISTING-TABLES j body execute PUBLISH-LISTING ;]
   [: j CLEAR-LISTING ;] finally ;

\ Applies a batch of a full listing's changes to its staging, in order,
\ in one transaction; only inside WITH-REMOTE-LISTING.
: STAGE-LISTING
   ( journal ^VEC:vector<remote-inventory-change> -- )
   {: j v :}
   j >CONNECTION v [: BATCH-STAGED ;] ARENA:WITH ;


\ ---- baselines and plans: values -----------------------------------

public

DEFTYPE PLAN-ID
DEFTYPE OPERATION-ID

\ Whether an operation's effect still has to finish.
ENUM record-status pending completed ;ENUM

\ ordinal: the operation's place in its plan's execution order, from 0.
STRUCTURE planned-operation
   FIELD id operation-id
   FIELD ordinal u32
   FIELD operation MODEL:operation
   FIELD status record-status
;STRUCTURE

\ blocked: a classified failure holds the plan until retry-at, seconds
\ since the epoch.
ENUM plan-status
   VARIANT pending ;VARIANT
   VARIANT blocked FIELD reason MODEL:blockage FIELD retry-at n ;VARIANT
   VARIANT completed ;VARIANT
;ENUM

\ A path's plan, its operations in execution order.
STRUCTURE plan-record
   FIELD id plan-id
   FIELD path MODEL:path
   FIELD operations ^VEC:vector<planned-operation>
   FIELD status plan-status
;STRUCTURE

\ The planner's operations in their execution order; a plan records at
\ least one.
STRUCTURE operation-plan
   FIELD operations ^VEC:vector<MODEL:operation>
;STRUCTURE

\ already-live: the path's live plan, committed before and kept.
ENUM plan-write
   VARIANT recorded FIELD plan plan-record ;VARIANT
   VARIANT already-live FIELD plan plan-record ;VARIANT
;ENUM

\ live-plan: a live plan owns the path, so its baseline stays.
ENUM noop-write
   VARIANT recorded ;VARIANT
   VARIANT live-plan FIELD id plan-id ;VARIANT
;ENUM

\ A no-op's path and the baseline it records.
STRUCTURE path-baseline
   FIELD path MODEL:path
   FIELD baseline MODEL:baseline
;STRUCTURE

\ A plan's path and the plan.
STRUCTURE path-plan
   FIELD path MODEL:path
   FIELD plan operation-plan
;STRUCTURE

\ not-found: no such plan; already-completed: the plan finished, so
\ nothing was blocked; blocked: the reason and retry time committed.
ENUM plan-block not-found already-completed blocked ;ENUM

\ not-blocked: the plan is pending or completed, unchanged.
ENUM plan-unblock not-found not-blocked unblocked ;ENUM

\ live-paths: the paths whose decision a live plan, pending or blocked,
\ kept from being recorded.
STRUCTURE reconciliation-write
   FIELD recorded-noops n
   FIELD recorded-plans n
   FIELD live-paths ^VEC:vector<MODEL:path>
;STRUCTURE

private

\ A recorded baseline's canonical path and its display path.
STRUCTURE spelling
   FIELD key MODEL:key
   FIELD path MODEL:path
;STRUCTURE

\ A plan's display path and status.
STRUCTURE plan-state
   FIELD path MODEL:path
   FIELD status plan-status
;STRUCTURE

$FFFFFFFF constant U32-MAX


\ ---- stored values -------------------------------------------------

: OPERATION-AS
   ( str MODEL:path ^ARENA:arena str -- MODEL:operation )
   {: json:str path ar op:str :}
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY
   [: DROP-OPERATION json ar MODEL:JSON>OPERATION ;]
   op path MODEL:PATH>STR DECODE ;

: DECODE-OPERATION ( str MODEL:path ^ARENA:arena -- MODEL:operation )
   s" deserialize operation" OPERATION-AS ;

: DECODE-BLOCKAGE ( str MODEL:path ^ARENA:arena -- MODEL:blockage )
   {: json:str path ar :}
   MODEL-BLOCKAGE:STAGE-OCCUPIED
   [: DROP-BLOCKAGE json ar MODEL:JSON>BLOCKAGE ;]
   s" deserialize block reason" path MODEL:PATH>STR DECODE ;

: ENCODE-OPERATION ( MODEL:operation ^JSON:writer -- str )
   {: o w :}
   w [: o swap MODEL:OPERATION>JSON ;] ENCODE ;

: ENCODE-BLOCKAGE ( MODEL:blockage ^JSON:writer -- str )
   {: b w :}
   w [: b swap MODEL:BLOCKAGE>JSON ;] ENCODE ;

: ABSENT? ( MODEL:baseline -- bool )
   MATCH MODEL:baseline
      absent OF true ENDOF
      present OF drop false ENDOF
      directory OF false ENDOF
   ;MATCH ;

: NO-BASELINE ( -- option<MODEL:baseline> ) OPTION:NONE ;
: NO-PLAN-ID ( -- option<plan-id> ) OPTION:NONE ;
: NO-PLAN ( -- option<plan-record> ) OPTION:NONE ;
: NO-STATE ( -- option<plan-state> ) OPTION:NONE ;
: NO-TEXT ( -- option<str> ) OPTION:NONE ;
: NO-INT ( -- option<n> ) OPTION:NONE ;

\ A text column, borrowed until the next STEP; NULL is none.
: TEXT? ( SQLITE:statement n -- SQLITE:statement option<str> )
   {: col :}
   col SQLITE:COL-NULL? if NO-TEXT exit then
   col SQLITE:COL-TEXT OPTION:SOME ;

: INT? ( SQLITE:statement n -- SQLITE:statement option<n> )
   {: col :}
   col SQLITE:COL-NULL? if NO-INT exit then
   col SQLITE:COL-INT OPTION:SOME ;

: KEY-COPY ( SQLITE:statement n ^ARENA:arena
     -- SQLITE:statement MODEL:key )
   BLOB-COPY MODEL:>KEY ;

: NEW-VECTOR ( ^ARENA:arena width<t> -- ^VEC:vector<t> )
   {: ar w :}
   ar ARENA:ALLOCATOR 0 w VEC:NEW ;


\ ---- baselines -----------------------------------------------------

\ The baseline in columns col to col+2: its kind, content and revision.
: BASELINE-COPY
   ( SQLITE:statement n ^ARENA:arena
     -- SQLITE:statement MODEL:baseline )
   {: col ar :}
   col SQLITE:COL-INT KIND-DIRECTORY = if
      MODEL-BASELINE:DIRECTORY exit
   then
   col 1+ ar REMOTE-FILE-COPY MODEL-BASELINE:PRESENT ;

: BASELINE-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<MODEL:baseline> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-BASELINE swap exit then
   0 ar BASELINE-COPY OPTION:SOME swap ;

: PATH-ROW
   ( SQLITE:statement ^VEC:vector<MODEL:path> ^ARENA:arena
     -- SQLITE:statement )
   {: paths ar :}
   0 ar PATH-COPY paths VEC:PUSH ! ;

public

\ The common baseline recorded for the display path; absent is none.
: BASELINE ( journal MODEL:path ^ARENA:arena -- option<MODEL:baseline> )
   {: j path ar :}
   path ar MODEL:FOLD {: k :}
   j >CONNECTION
   s" SELECT kind, content, revision FROM baselines
      WHERE canonical_path = ?1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB ar BASELINE-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Every path with a baseline, in the order of its bytes.
: BASELINE-PATHS ( journal ^ARENA:arena -- ^VEC:vector<MODEL:path> )
   {: j ar :}
   ar [type] MODEL:path NEW-VECTOR {: paths :}
   j >CONNECTION
   s" SELECT path FROM baselines ORDER BY path"
   [: begin SQLITE:STEP while paths ar PATH-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   paths ;

\ The display path the canonical path's baseline was recorded under.
: BASELINE-SPELLING
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:path> )
   {: j k ar :}
   j >CONNECTION
   s" SELECT path FROM baselines WHERE canonical_path = ?1"
   [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB ar SPELLING-ROW ;]
   SQLITE:WITH-STATEMENT ;

private

: LOCAL-RECORDS ( ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   [type] MODEL:local-record NEW-VECTOR ;

\ The row's record joins v; at its key's last row the visitor takes v,
\ and a new vector follows it for the next key.
: COLLISION-ROW
   ( SQLITE:statement ^VEC:vector<MODEL:local-record> ^ARENA:arena
     [ ^VEC:vector<MODEL:local-record> -- bool ]
     -- SQLITE:statement ^VEC:vector<MODEL:local-record> bool )
   {: v ar visit :}
   ar LOCAL-ROW v VEC:PUSH !
   3 SQLITE:COL-INT 0= if v false exit then
   v visit execute {: stop:bool :}
   ar LOCAL-RECORDS stop ;

\ Every visited key ends at its last row, so no records are left over.
: COLLISION-ROWS
   ( SQLITE:statement ^ARENA:arena
     [ ^VEC:vector<MODEL:local-record> -- bool ] -- SQLITE:statement )
   {: ar visit :}
   ar LOCAL-RECORDS
   begin swap SQLITE:STEP while
      swap ar visit COLLISION-ROW if drop exit then
   repeat
   nip ;

: NO-LOCAL ( -- option<MODEL:local-record> ) OPTION:NONE ;

: LOCAL-AT-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<MODEL:local-record> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-LOCAL swap exit then
   ar LOCAL-ROW OPTION:SOME swap ;

: NO-REMOTE ( -- option<MODEL:remote-record> ) OPTION:NONE ;

: REMOTE-AT-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<MODEL:remote-record> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-REMOTE swap exit then
   ar REMOTE-ROW OPTION:SOME swap ;

public

\ The records of each canonical path several local rows hold, by key then
\ path bytes, to the visitor inside the statement until it answers true.
: EACH-LOCAL-COLLISION
   ( journal ^ARENA:arena [ ^VEC:vector<MODEL:local-record> -- bool ]
     -- )
   {: j ar visit :}
   j >CONNECTION
   s" SELECT o.path, o.kind, o.content, o.path = c.last
      FROM (SELECT canonical_path, max(path) AS last
            FROM local_observations
            GROUP BY canonical_path HAVING count(*) > 1) AS c
      JOIN local_observations AS o
         ON o.canonical_path = c.canonical_path
      ORDER BY o.canonical_path, o.path" [: ar visit COLLISION-ROWS ;] SQLITE:WITH-STATEMENT ;

: LOCAL-COUNT ( journal -- n )
   >CONNECTION s" SELECT count(*) FROM local_observations" QUERY-INT ;

\ The local record with the least path at the canonical path.
: LOCAL-AT
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:local-record> )
   {: j k ar :}
   j >CONNECTION
   s" SELECT path, kind, content FROM local_observations
      WHERE canonical_path = ?1 ORDER BY path LIMIT 1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB ar LOCAL-AT-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Every local record at the canonical path, in the order of its path's
\ bytes.
: LOCALS-AT
   ( journal MODEL:key ^ARENA:arena
     -- ^VEC:vector<MODEL:local-record> )
   {: j k ar :}
   ar LOCAL-RECORDS {: v :}
   j >CONNECTION
   s" SELECT path, kind, content FROM local_observations
      WHERE canonical_path = ?1 ORDER BY path" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
      begin SQLITE:STEP while ar LOCAL-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

\ The remote record at the canonical path.
: REMOTE-AT
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:remote-record> )
   {: j k ar :}
   j >CONNECTION
   s" SELECT canonical_path, path, kind, content, revision
      FROM remote_observations WHERE canonical_path = ?1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB ar REMOTE-AT-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ The record the listing left at the canonical path beneath any hold:
\ a held key's shadow, an unheld key's observation; none at a key only
\ a hold makes.
: REMOTE-LISTED-AT
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:remote-record> )
   {: j k ar :}
   j >CONNECTION
   s" SELECT canonical_path, path, kind, content, revision
      FROM remote_shadows WHERE canonical_path = ?1
      UNION ALL SELECT canonical_path, path, kind, content, revision
      FROM remote_observations WHERE canonical_path = ?1
         AND NOT EXISTS (SELECT 1 FROM remote_mismatches
            WHERE canonical_path = ?1)" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB ar REMOTE-AT-ROW ;]
   SQLITE:WITH-STATEMENT ;

private


\ ---- known paths ---------------------------------------------------

public

\ What one canonical path holds. baseline: none for Absent; local: the
\ least path's row; subtree: remote rows beneath; live: a live plan.
STRUCTURE known-path
   FIELD key MODEL:key
   FIELD baseline option<path-baseline>
   FIELD local option<MODEL:local-record>
   FIELD locals n
   FIELD remote option<MODEL:remote-record>
   FIELD subtree MODEL:subtree
   FIELD live bool
;STRUCTURE

private

: NO-PATH-BASELINE ( -- option<path-baseline> ) OPTION:NONE ;

\ Fills temp.unsettled with each key a row holds but a conflict alone, less the
\ settled: baseline, remote and local agree, with no live plan or conflict.
: KNOWN-KEYS ( -- str )
   s" WITH lone(k) AS (
         SELECT canonical_path FROM local_observations
         EXCEPT SELECT canonical_path FROM baselines),
      rone(k) AS (
         SELECT canonical_path FROM remote_observations
         EXCEPT SELECT canonical_path FROM baselines),
      keys(k) AS (
         SELECT b.canonical_path FROM baselines b
         LEFT JOIN local_observations l
            ON l.canonical_path = b.canonical_path
         LEFT JOIN remote_observations r
            ON r.canonical_path = b.canonical_path
         WHERE NOT ((b.kind = 1 AND r.kind = 1 AND l.kind = 1)
            OR (b.kind = 0 AND r.kind = 0 AND l.kind = 0
               AND l.content = b.content AND r.content = b.content
               AND r.revision = b.revision)) IS 1
         UNION SELECT k FROM lone
         UNION SELECT k FROM rone
         UNION SELECT canonical_path FROM local_observations
            GROUP BY canonical_path HAVING count(*) > 1
         UNION SELECT canonical_path FROM plans
            WHERE status IN ('pending', 'blocked')
         UNION SELECT c.canonical_path FROM conflicts c
            WHERE EXISTS (SELECT 1 FROM baselines o
               WHERE o.canonical_path = c.canonical_path)) " ;

: ONE-KEY ( -- str ) s" WITH keys(k) AS (SELECT ?1) " ;

\ What each key of keys holds. || makes text of a blob; the CAST keeps
\ the subtree's bounds, the key then "/" and the key then "0", bytes.
: KNOWN-SELECT ( -- str )
   s" SELECT keys.k, b.path, b.kind, b.content, b.revision,
         l.path, l.kind, l.content,
         (SELECT count(*) FROM local_observations c
            WHERE c.canonical_path = keys.k),
         r.path, r.kind, r.content, r.revision,
         EXISTS (SELECT 1 FROM plans p
            WHERE p.canonical_path = keys.k
               AND p.status IN ('pending', 'blocked')),
         EXISTS (SELECT 1 FROM remote_observations s
            WHERE s.canonical_path > CAST(keys.k || '/' AS BLOB)
               AND s.canonical_path < CAST(keys.k || '0' AS BLOB))
      FROM keys
      LEFT JOIN baselines b ON b.canonical_path = keys.k
      LEFT JOIN local_observations l ON l.path = (
         SELECT m.path FROM local_observations m
         WHERE m.canonical_path = keys.k ORDER BY m.path LIMIT 1)
      LEFT JOIN remote_observations r ON r.canonical_path = keys.k
      ORDER BY keys.k" ;

\ Lays the two strings' total length, then their bytes, in the word just
\ created, for TEXT to read.
: LAY-BOTH ( str str -- )
   {: x y :}
   x str> {: a:^ au:n :}
   y str> {: b:^ bu:n :}
   au bu + ,
   a here au BYTE-COPY  au allot
   b here bu BYTE-COPY  bu allot align ;

\ KNOWN-KEYS' keys into temp.unsettled.
: UNSETTLED-INSERT ( -- str )
   s" INSERT INTO temp.unsettled SELECT k FROM keys" ;

\ The least unsettled key, then the least above ?1.
: FIRST-KEY ( -- str )
   s" WITH keys(k) AS (SELECT k FROM temp.unsettled ORDER BY k LIMIT 1) " ;
: NEXT-KEY ( -- str )
   s" WITH keys(k) AS (SELECT k FROM temp.unsettled WHERE k > ?1
      ORDER BY k LIMIT 1) " ;

create FILL-UNSETTLED KNOWN-KEYS UNSETTLED-INSERT LAY-BOTH
create FIRST-KNOWN FIRST-KEY KNOWN-SELECT LAY-BOTH
create NEXT-KNOWN NEXT-KEY KNOWN-SELECT LAY-BOTH
create ONE-KNOWN ONE-KEY KNOWN-SELECT LAY-BOTH

\ Columns 1 to 4, NULL where no baseline is.
: KNOWN-BASELINE
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement option<path-baseline> )
   {: ar :}
   1 SQLITE:COL-NULL? if NO-PATH-BASELINE exit then
   1 ar PATH-COPY {: p :}
   2 ar BASELINE-COPY {: b :}
   p b JOURNAL-PATH--BASELINE:MAKE OPTION:SOME ;

\ Columns 5 to 7, NULL where no local row is.
: KNOWN-LOCAL
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement option<MODEL:local-record> )
   {: ar :}
   5 SQLITE:COL-NULL? if NO-LOCAL exit then
   5 ar PATH-COPY {: p :}
   6 ar LOCAL-OBSERVATION-COPY {: o :}
   p o MODEL-LOCAL--RECORD:MAKE OPTION:SOME ;

\ Columns 9 to 12, NULL where no remote row is.
: KNOWN-REMOTE
   ( SQLITE:statement MODEL:key ^ARENA:arena
     -- SQLITE:statement option<MODEL:remote-record> )
   {: k ar :}
   9 SQLITE:COL-NULL? if NO-REMOTE exit then
   9 ar PATH-COPY {: p :}
   10 ar REMOTE-OBSERVATION-COPY {: o :}
   k p o MODEL-REMOTE--RECORD:MAKE OPTION:SOME ;

: KNOWN-SUBTREE ( SQLITE:statement -- SQLITE:statement MODEL:subtree )
   14 SQLITE:COL-INT 0= if MODEL-SUBTREE:EMPTY exit then
   MODEL-SUBTREE:OCCUPIED ;

\ The row of a KNOWN-SELECT statement, decoded into ar.
: KNOWN-ROW
   ( SQLITE:statement ^ARENA:arena -- SQLITE:statement known-path )
   {: ar :}
   0 ar KEY-COPY {: k :}
   ar KNOWN-BASELINE {: b :}
   ar KNOWN-LOCAL {: l :}
   8 SQLITE:COL-INT {: n :}
   k ar KNOWN-REMOTE {: r :}
   KNOWN-SUBTREE {: s :}
   13 SQLITE:COL-INT 0<> {: live:bool :}
   k b l n r s live JOURNAL-KNOWN--PATH:MAKE ;

\ ONE-KEY's statement answers one row.
: KNOWN-ROW-AT
   ( SQLITE:statement MODEL:key ^ARENA:arena
     -- known-path SQLITE:statement )
   {: k ar :}
   k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
   SQLITE:STEP drop ar KNOWN-ROW swap ;

\ The table of the keys a walk visits, made empty; the walk empties it
\ after.
: UNSETTLED-TABLE ( SQLITE:connection -- )
   s" CREATE TABLE IF NOT EXISTS temp.unsettled(
         k BLOB PRIMARY KEY NOT NULL
      ) WITHOUT ROWID;
      DELETE FROM temp.unsettled" SQLITE:EXEC ;

: CLEAR-UNSETTLED ( SQLITE:connection -- )
   s" DELETE FROM temp.unsettled" SQLITE:EXEC ;

: NO-KNOWN ( -- option<known-path> ) OPTION:NONE ;

\ FIRST-KNOWN's row, decoded into ar after its reset; none past the
\ last.
: FIRST-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<known-path> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-KNOWN swap exit then
   ar ARENA:RESET ar KNOWN-ROW OPTION:SOME swap ;

\ NEXT-KNOWN's row above kp's key, decoded into ar after its reset;
\ kp and false past the last. The binding copies the key.
: NEXT-ROW
   ( SQLITE:statement known-path ^ARENA:arena
     -- known-path bool SQLITE:statement )
   {: kp ar :}
   kp JOURNAL-KNOWN--PATH:UNMAKE {: k b l n:n r t live:bool :}
   k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
   SQLITE:STEP 0= if kp false rot exit then
   ar ARENA:RESET ar KNOWN-ROW true rot ;

: FIRST-UNSETTLED ( SQLITE:connection ^ARENA:arena -- option<known-path> )
   {: c ar :}
   c FIRST-KNOWN TEXT [: ar FIRST-ROW ;] SQLITE:WITH-STATEMENT ;

: NEXT-UNSETTLED
   ( SQLITE:connection known-path ^ARENA:arena -- known-path bool )
   {: c kp ar :}
   c NEXT-KNOWN TEXT [: kp ar NEXT-ROW ;] SQLITE:WITH-STATEMENT ;

\ 1 when the row held a baseline, else 0.
: BASELINES-IN ( known-path -- n )
   JOURNAL-KNOWN--PATH:UNMAKE {: k b l n:n r t live:bool :}
   b MATCH option
      none OF 0 ENDOF
      some OF drop 1 ENDOF
   ;MATCH ;

\ Visits kp and each unsettled key above it, no statement open, until the
\ visitor answers false; n counts the visited keys that held a baseline.
: VISIT-FROM
   ( SQLITE:connection known-path ^ARENA:arena [ known-path -- bool ]
     -- n )
   {: c kp ar visit :}
   0 kp
   begin
      dup BASELINES-IN rot + swap
      dup visit execute if c swap ar NEXT-UNSETTLED else false then
   while repeat
   drop ;

: VISIT-UNSETTLED
   ( SQLITE:connection ^ARENA:arena [ known-path -- bool ] -- n )
   {: c ar visit :}
   c FILL-UNSETTLED RUN
   c ar FIRST-UNSETTLED MATCH option
      none OF 0 ENDOF
      some OF {: kp :} c kp ar visit VISIT-FROM ENDOF
   ;MATCH ;

public

\ Visits each unsettled key in byte order, decoded into ar, reset before each;
\ visit may write the journal. n counts the settled keys unless visit stopped.
: EACH-UNSETTLED-PATH
   ( journal ^ARENA:arena [ known-path -- bool ] -- n )
   {: j ar visit :}
   j >CONNECTION {: c :}
   c s" SELECT count(*) FROM baselines" QUERY-INT {: all:n :}
   c UNSETTLED-TABLE
   [: c ar visit VISIT-UNSETTLED ;] [: c CLEAR-UNSETTLED ;] finally
   {: held:n :}
   all held - ;

\ What the journal holds at the key, decoded into ar.
: KNOWN-PATH-AT ( journal MODEL:key ^ARENA:arena -- known-path )
   {: j k ar :}
   j >CONNECTION ONE-KNOWN TEXT [: k ar KNOWN-ROW-AT ;]
   SQLITE:WITH-STATEMENT ;

private

: HELD-ROWS
   ( SQLITE:statement ^ARENA:arena [ MODEL:path -- ]
     -- SQLITE:statement )
   {: ar visit :}
   begin SQLITE:STEP while 0 ar PATH-COPY visit execute repeat ;

public

\ Each baseline directory the planner holds undeleted, by key, its path in
\ ar: no local row at or unknown above it; entries beneath on Dropbox.
: EACH-HELD-DELETION ( journal ^ARENA:arena [ MODEL:path -- ] -- )
   {: j ar visit :}
   j >CONNECTION
   s" WITH unknown(c) AS MATERIALIZED (SELECT canonical_path
         FROM local_observations WHERE kind >= 3)
      SELECT b.path FROM baselines b
      JOIN remote_observations r ON r.canonical_path = b.canonical_path
      WHERE b.kind = 1 AND r.kind = 1
         AND NOT EXISTS (SELECT 1 FROM local_observations l
            WHERE l.canonical_path = b.canonical_path)
         AND EXISTS (SELECT 1 FROM remote_observations s
            WHERE s.canonical_path > CAST(b.canonical_path || '/' AS BLOB)
               AND s.canonical_path < CAST(b.canonical_path || '0' AS BLOB))
         AND NOT EXISTS (SELECT 1 FROM unknown u
            WHERE b.canonical_path > CAST(u.c || '/' AS BLOB)
               AND b.canonical_path < CAST(u.c || '0' AS BLOB))
      ORDER BY b.canonical_path" [: ar visit HELD-ROWS ;]
   SQLITE:WITH-STATEMENT ;

private


\ ---- a case-collision rename ---------------------------------------

: FORGET ( SQLITE:connection MODEL:key -- )
   {: c k :}
   c s" DELETE FROM baselines WHERE canonical_path = ?1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: COLLECT-SPELLING
   ( SQLITE:statement ^VEC:vector<spelling> ^ARENA:arena
     -- SQLITE:statement )
   {: found ar :}
   0 ar KEY-COPY {: k :}
   1 ar PATH-COPY {: path :}
   k path SPELLING-MAKE found VEC:PUSH ! ;

\ Every baseline at the canonical path and beneath it.
: SPELLINGS
   ( SQLITE:connection MODEL:key ^ARENA:arena -- ^VEC:vector<spelling> )
   {: c k ar :}
   ar [type] spelling NEW-VECTOR {: found :}
   k ar MODEL:SUBTREE-RANGE {: from:str to:str :}
   c s" SELECT canonical_path, path FROM baselines
      WHERE canonical_path = ?1
         OR (canonical_path >= ?2 AND canonical_path < ?3)" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
      from 2 SQLITE:BIND-BLOB
      to 3 SQLITE:BIND-BLOB
      begin SQLITE:STEP while found ar COLLECT-SPELLING repeat ;]
   SQLITE:WITH-STATEMENT
   found ;

\ Forgets the baseline recorded at the renamed path or beneath it, or
\ one whose display path exists does not confirm.
: FORGET-STALE
   ( SQLITE:connection MODEL:path [ MODEL:path -- bool ] spelling -- )
   {: c renamed exists s :}
   s SPELLING-UNMAKE {: k path :}
   path renamed MODEL:BEGINS? if c k FORGET exit then
   path exists execute if exit then
   c k FORGET ;

: FORGET-ALL-STALE
   ( SQLITE:connection MODEL:path MODEL:key [ MODEL:path -- bool ]
     ^ARENA:arena -- )
   {: c renamed k exists ar :}
   c k ar SPELLINGS {: found :}
   found VEC:COUNT 0 ?do
      c renamed exists found i VEC:AT @ FORGET-STALE
   loop ;

public

\ Forgets each baseline at renamed's key or beneath it that renamed
\ covers or exists denies; a throw of exists forgets none.
: INVALIDATE-CASE-COLLISION-BASELINES
   ( journal MODEL:path [ MODEL:path -- bool ] ^ARENA:arena -- )
   {: j renamed exists ar :}
   renamed ar MODEL:FOLD {: k :}
   k MODEL:KEY>STR STR:len 0= if
      s" invalidate case-collision history"
      renamed MODEL:PATH>STR
      s" case-collision path is empty" INVALID
   then
   j >CONNECTION {: c :}
   c [: c renamed k exists ar FORGET-ALL-STALE ;]
   SQLITE:WITH-TRANSACTION ;

private


\ ---- plans ---------------------------------------------------------

: PLAN-SELECT ( -- str )
   s" SELECT plans.id, plans.path, plans.status, plans.blocked_json,
         plans.retry_at, operations.id, operations.ordinal,
         operations.operation_json, operations.status
      FROM plans JOIN operations ON operations.plan_id = plans.id" ;

\ A batch's plans are the subselect's: at most ?2 above id ?1, by id.
: PENDING-IN ( -- str )
   s"  WHERE plans.id IN (SELECT p.id FROM plans AS p
         WHERE p.status = 'pending' AND p.id > ?1
         ORDER BY p.id LIMIT ?2)
      ORDER BY plans.id, operations.ordinal" ;

: BLOCKED-IN ( -- str )
   s"  WHERE plans.id IN (SELECT p.id FROM plans AS p
         WHERE p.status = 'blocked' AND p.id > ?1
         ORDER BY p.id LIMIT ?2)
      ORDER BY plans.id, operations.ordinal" ;

\ The status is a literal: one_live_plan_per_path is partial on it, so a
\ bound status would re-prepare the statement at every bind.
create PENDING-QUERY PLAN-SELECT PENDING-IN LAY-BOTH
create BLOCKED-QUERY PLAN-SELECT BLOCKED-IN LAY-BOTH

: TALLY-ROW ( SQLITE:statement -- n n SQLITE:statement )
   SQLITE:STEP drop 0 SQLITE:COL-INT swap 1 SQLITE:COL-INT swap ;

\ Completed plans with an operation that installs a Dropbox file, run or not.
: DOWNLOADED-IN ( -- str )
   s"  WHERE plans.id IN (SELECT p.id FROM plans AS p
         WHERE p.status = 'completed' AND p.id > ?1 AND EXISTS (
            SELECT 1 FROM operations AS d WHERE d.plan_id = p.id
               AND json_valid(d.operation_json)
               AND (json_type(d.operation_json, '$.InstallLocal')
                     IS NOT NULL
                  OR json_type(d.operation_json, '$.ReplaceLocal')
                     IS NOT NULL))
         ORDER BY p.id LIMIT ?2)
      ORDER BY plans.id, operations.ordinal" ;

create DOWNLOADED-QUERY PLAN-SELECT DOWNLOADED-IN LAY-BOTH

: PATH-INVALID ( str MODEL:path str -- )
   {: op:str path d:str :}
   op path MODEL:PATH>STR d INVALID ;

: DECODE-STATUS ( str str str -- record-status )
   {: s:str op:str path:str :}
   s s" pending" STR:= if construct record-status pending exit then
   s s" completed" STR:= if construct record-status completed exit then
   op path s" record has an unrecognized status" INVALID ;

: NO-JSON? ( option<str> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: DISAGREES ( str MODEL:path -- )
   s" plan status disagrees with its block columns" PATH-INVALID ;

: RETRY-AT ( n str MODEL:path -- n )
   {: at op:str path :}
   at 0 < if
      op path s" blocked plan has a negative retry time" PATH-INVALID
   then
   at ;

: BLOCKED-AT
   ( str option<n> str MODEL:path ^ARENA:arena -- plan-status )
   {: json:str retry op:str path ar :}
   retry MATCH option
      none OF op path DISAGREES ENDOF
      some OF
         {: at :}
         json path ar DECODE-BLOCKAGE at op path RETRY-AT
         construct plan-status blocked
      ENDOF
   ;MATCH ;

: BLOCKED-STATUS
   ( option<str> option<n> str MODEL:path ^ARENA:arena -- plan-status )
   {: retry op:str path ar :}
   MATCH option
      none OF op path DISAGREES ENDOF
      some OF retry op path ar BLOCKED-AT ENDOF
   ;MATCH ;

: KNOWN? ( str -- bool )
   {: s:str :}
   s s" pending" STR:= s s" completed" STR:= or
   s s" blocked" STR:= or ;

\ A plan's status from its status, blocked_json and retry_at columns.
: DECODE-PLAN-STATUS
   ( str option<str> option<n> str MODEL:path ^ARENA:arena
     -- plan-status )
   {: s:str json retry op:str path ar :}
   json NO-JSON? retry NO-INT? and {: clear:bool :}
   s s" pending" STR:= clear and if
      construct plan-status pending exit
   then
   s s" completed" STR:= clear and if
      construct plan-status completed exit
   then
   s s" blocked" STR:= if
      json retry op path ar BLOCKED-STATUS exit
   then
   s KNOWN? if op path DISAGREES then
   op path s" plan has an unrecognized status" PATH-INVALID ;

: ORDINAL ( n str MODEL:path -- u32 )
   {: v op:str path :}
   v 0 < v U32-MAX > or if
      op path s" operation ordinal exceeds the supported range"
      PATH-INVALID
   then
   v ;

\ The operation in columns at to at + 3: its id, ordinal, JSON and
\ status; an ordinal out of range is op's.
: PLANNED
   ( SQLITE:statement n str MODEL:path ^ARENA:arena
     -- SQLITE:statement planned-operation )
   {: at op:str path ar :}
   at 1+ SQLITE:COL-INT op path ORDINAL {: ordinal :}
   at 2 + SQLITE:COL-TEXT path ar DECODE-OPERATION {: o :}
   at 3 + SQLITE:COL-TEXT s" read operation status"
   path MODEL:PATH>STR DECODE-STATUS {: s :}
   at SQLITE:COL-INT >OPERATION-ID {: id :}
   id ordinal o s JOURNAL-PLANNED--OPERATION:MAKE ;

: >OPERATIONS ( plan-record -- ^VEC:vector<planned-operation> )
   JOURNAL-PLAN--RECORD:UNMAKE {: i p o s :} o ;

: >ID ( plan-record -- plan-id )
   JOURNAL-PLAN--RECORD:UNMAKE {: i p o s :} i ;

: ID= ( plan-id plan-id -- bool ) PLAN-ID>N swap PLAN-ID>N = ;

\ The last plan read, when it is plan id.
: LAST? ( ^VEC:vector<plan-record> plan-id -- bool )
   {: plans id :}
   plans VEC:COUNT {: u :}
   u 0= if false exit then
   plans u 1- VEC:AT @ >ID id ID= ;

\ The id the next batch reads above: the batch's last plan's.
: LAST-ID ( ^VEC:vector<plan-record> -- option<plan-id> )
   {: plans :}
   plans plans VEC:COUNT 1- VEC:AT @ >ID OPTION:SOME ;

: NEW-PLAN-ROW
   ( SQLITE:statement ^VEC:vector<plan-record> plan-id MODEL:path
     planned-operation str ^ARENA:arena -- SQLITE:statement )
   {: plans id path planned op:str ar :}
   ar [type] planned-operation NEW-VECTOR {: ops :}
   planned ops VEC:PUSH !
   2 SQLITE:COL-TEXT {: s:str :}
   3 TEXT? {: json :}
   4 INT? {: retry :}
   s json retry op path ar DECODE-PLAN-STATUS {: status :}
   id path ops status JOURNAL-PLAN--RECORD:MAKE plans VEC:PUSH ! ;

\ A row of a plans query: its operation joins the last plan when the row is
\ that plan's, else starts a new one.
: PLAN-ROW
   ( SQLITE:statement ^VEC:vector<plan-record> str ^ARENA:arena
     -- SQLITE:statement )
   {: plans op:str ar :}
   1 ar PATH-COPY {: path :}
   5 op path ar PLANNED {: planned :}
   0 SQLITE:COL-INT >PLAN-ID {: id :}
   plans id LAST? if
      planned plans plans VEC:COUNT 1- VEC:AT @ >OPERATIONS VEC:PUSH !
      exit
   then
   plans id path planned op ar NEW-PLAN-ROW ;

\ The id a batch reads above; none reads from the first plan, as SQLite
\ numbers plans from 1.
: ABOVE-ID ( option<plan-id> -- n )
   MATCH option
      none OF 0 ENDOF
      some OF PLAN-ID>N ENDOF
   ;MATCH ;

: BATCH-BIND
   ( SQLITE:statement option<plan-id> -- SQLITE:statement )
   ABOVE-ID 1 SQLITE:BIND-INT BATCH-BOUND 2 SQLITE:BIND-INT ;

\ The query's batch above the id, each plan's operations in order.
: READ-BATCH
   ( SQLITE:connection str option<plan-id> str ^ARENA:arena
     -- ^VEC:vector<plan-record> )
   {: c q:str above op:str ar :}
   ar [type] plan-record NEW-VECTOR {: plans :}
   c q [: above BATCH-BIND
      begin SQLITE:STEP while plans op ar PLAN-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   plans ;

: STATE-ROW
   ( SQLITE:statement str ^ARENA:arena
     -- option<plan-state> SQLITE:statement )
   {: op:str ar :}
   SQLITE:STEP 0= if NO-STATE swap exit then
   0 ar PATH-COPY {: path :}
   1 SQLITE:COL-TEXT {: s:str :}
   2 TEXT? {: json :}
   3 INT? {: retry :}
   s json retry op path ar DECODE-PLAN-STATUS {: status :}
   path status PLAN-STATE-MAKE OPTION:SOME swap ;

: READ-PLAN-STATE
   ( SQLITE:connection plan-id str ^ARENA:arena -- option<plan-state> )
   {: c id op:str ar :}
   c s" SELECT path, status, blocked_json, retry_at FROM plans
      WHERE id = ?1" [: id PLAN-ID>N 1 SQLITE:BIND-INT op ar STATE-ROW ;]
   SQLITE:WITH-STATEMENT ;

: OPERATION-ROW
   ( SQLITE:statement ^VEC:vector<planned-operation> MODEL:path
     ^ARENA:arena -- SQLITE:statement )
   {: ops path ar :}
   0 s" read operation ordinal" path ar PLANNED ops VEC:PUSH ! ;

: PLAN-OPERATIONS
   ( SQLITE:connection plan-id MODEL:path ^ARENA:arena
     -- ^VEC:vector<planned-operation> )
   {: c id path ar :}
   ar [type] planned-operation NEW-VECTOR {: ops :}
   c s" SELECT id, ordinal, operation_json, status
      FROM operations WHERE plan_id = ?1 ORDER BY ordinal" [: id PLAN-ID>N 1 SQLITE:BIND-INT
      begin SQLITE:STEP while ops path ar OPERATION-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   ops ;

: STATED-PLAN
   ( SQLITE:connection plan-id plan-state ^ARENA:arena -- plan-record )
   {: c id state ar :}
   state PLAN-STATE-UNMAKE {: path status :}
   id path c id path ar PLAN-OPERATIONS status
   JOURNAL-PLAN--RECORD:MAKE ;

: READ-PLAN
   ( SQLITE:connection plan-id ^ARENA:arena -- option<plan-record> )
   {: c id ar :}
   c id s" read plan" ar READ-PLAN-STATE MATCH option
      none OF NO-PLAN ENDOF
      some OF {: state :} c id state ar STATED-PLAN OPTION:SOME ENDOF
   ;MATCH ;


\ ---- recording -----------------------------------------------------

: LIVE-ROW ( SQLITE:statement -- option<plan-id> SQLITE:statement )
   SQLITE:STEP 0= if NO-PLAN-ID swap exit then
   0 SQLITE:COL-INT >PLAN-ID OPTION:SOME swap ;

\ The path's live plan, pending or blocked, if any.
: LIVE-PLAN ( SQLITE:connection MODEL:key -- option<plan-id> )
   {: c k :}
   c s" SELECT id FROM plans
      WHERE canonical_path = ?1 AND status IN ('pending', 'blocked')" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB LIVE-ROW ;]
   SQLITE:WITH-STATEMENT ;

: UPSERT-BASELINE ( -- str )
   s" INSERT INTO baselines(path, canonical_path, kind, content, revision)
      VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(canonical_path) DO UPDATE SET
         path = excluded.path,
         kind = excluded.kind,
         content = excluded.content,
         revision = excluded.revision
      WHERE baselines.path != excluded.path
         OR baselines.kind != excluded.kind
         OR baselines.content IS NOT excluded.content
         OR baselines.revision IS NOT excluded.revision" ;

\ The path's row, its kind, content and revision bound by bind; an
\ unchanged row writes nothing.
: PUT-BASELINE
   ( SQLITE:connection MODEL:path MODEL:key
     [ SQLITE:statement -- SQLITE:statement ] -- )
   {: c path k bind :}
   c UPSERT-BASELINE
    [: path MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      k MODEL:KEY>STR 2 SQLITE:BIND-BLOB
      bind execute SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ An absent baseline removes the path's row.
: WRITE-BASELINE
   ( SQLITE:connection MODEL:path MODEL:baseline ^ARENA:arena -- )
   {: c path b ar :}
   path ar MODEL:FOLD {: k :}
   b MATCH MODEL:baseline
      absent OF c k FORGET ENDOF
      present OF
         {: r :} c path k [: r BIND-PRESENT ;] PUT-BASELINE
      ENDOF
      directory OF
         c path k [: KIND-DIRECTORY BIND-KIND ;] PUT-BASELINE
      ENDOF
   ;MATCH ;

: RETIRE-CONFLICTS ( SQLITE:connection MODEL:key -- )
   {: c k :}
   c s" DELETE FROM conflicts WHERE canonical_path = ?1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: AGREED
   ( SQLITE:connection MODEL:path MODEL:key MODEL:baseline ^ARENA:arena
     -- noop-write )
   {: c path k b ar :}
   c path b ar WRITE-BASELINE
   c k RETIRE-CONFLICTS
   construct noop-write recorded ;

: RECORD-NOOP-IN
   ( SQLITE:connection MODEL:path MODEL:baseline ^ARENA:arena
     -- noop-write )
   {: c path b ar :}
   path ar MODEL:FOLD {: k :}
   c k LIVE-PLAN MATCH option
      some OF construct noop-write live-plan ENDOF
      none OF c path k b ar AGREED ENDOF
   ;MATCH ;

\ The plan read inside the transaction that wrote or found it; none is
\ op's invalid state.
: HELD-PLAN ( option<plan-record> str MODEL:path str -- plan-record )
   {: op:str path d:str :}
   MATCH option
      some OF ENDOF
      none OF op path d PATH-INVALID ENDOF
   ;MATCH ;

: INSERT-PLAN ( SQLITE:connection MODEL:path MODEL:key -- plan-id )
   {: c path k :}
   c s" INSERT INTO plans(path, status, canonical_path)
      VALUES (?1, 'pending', ?2)" [: path MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      k MODEL:KEY>STR 2 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c SQLITE:LAST-ROWID >PLAN-ID ;

: INSERT-OPERATION ( SQLITE:connection plan-id n str -- )
   {: c id ordinal js:str :}
   c s" INSERT INTO operations(plan_id, ordinal, operation_json, status)
      VALUES (?1, ?2, ?3, 'pending')" [: id PLAN-ID>N 1 SQLITE:BIND-INT
      ordinal 2 SQLITE:BIND-INT
      js 3 SQLITE:BIND-TEXT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: NEW-PLAN
   ( SQLITE:connection MODEL:path MODEL:key
     ^VEC:vector<MODEL:operation> ^ARENA:arena ^JSON:writer
     -- plan-record )
   {: c path k ops ar w :}
   c path k INSERT-PLAN {: id :}
   ops VEC:COUNT 0 ?do
      c id i ops i VEC:AT @ w ENCODE-OPERATION INSERT-OPERATION
   loop
   c id ar READ-PLAN s" read recorded plan" path
   s" new plan disappeared inside its transaction" HELD-PLAN ;

: LIVE
   ( SQLITE:connection plan-id MODEL:path ^ARENA:arena -- plan-record )
   {: c id path ar :}
   c id ar READ-PLAN s" read existing live plan" path
   s" live plan disappeared inside its transaction" HELD-PLAN ;

: PLAN-OPERATIONS-OF
   ( operation-plan -- ^VEC:vector<MODEL:operation> )
   JOURNAL-OPERATION--PLAN:UNMAKE ;

: RECORD-PLAN-IN
   ( SQLITE:connection MODEL:path operation-plan ^ARENA:arena
     ^JSON:writer -- plan-write )
   {: c path plan ar w :}
   plan PLAN-OPERATIONS-OF {: ops :}
   ops VEC:COUNT 0= if
      s" record plan" path
      s" a plan must carry at least one operation" PATH-INVALID
   then
   path ar MODEL:FOLD {: k :}
   c k LIVE-PLAN MATCH option
      some OF
         {: id :} c id path ar LIVE construct plan-write already-live
      ENDOF
      none OF
         c path k ops ar w NEW-PLAN construct plan-write recorded
      ENDOF
   ;MATCH ;

: NOOP-ENTRY
   ( SQLITE:connection path-baseline ^VEC:vector<MODEL:path>
     ^ARENA:arena -- n )
   {: c e live ar :}
   e JOURNAL-PATH--BASELINE:UNMAKE {: path b :}
   c path b ar RECORD-NOOP-IN MATCH noop-write
      recorded OF 1 ENDOF
      live-plan OF drop path live VEC:PUSH ! 0 ENDOF
   ;MATCH ;

: PLAN-ENTRY
   ( SQLITE:connection path-plan ^VEC:vector<MODEL:path>
     ^ARENA:arena ^JSON:writer -- n )
   {: c e live ar w :}
   e JOURNAL-PATH--PLAN:UNMAKE {: path plan :}
   c path plan ar w RECORD-PLAN-IN MATCH plan-write
      recorded OF drop 1 ENDOF
      already-live OF drop path live VEC:PUSH ! 0 ENDOF
   ;MATCH ;

: NOOPS-IN
   ( SQLITE:connection ^VEC:vector<path-baseline>
     ^VEC:vector<MODEL:path> ^ARENA:arena -- n )
   {: c noops live ar :}
   0 noops VEC:COUNT 0 ?do
      c noops i VEC:AT @ live ar NOOP-ENTRY + ar ARENA:RESET
   loop ;

: PLANS-IN
   ( SQLITE:connection ^VEC:vector<path-plan>
     ^VEC:vector<MODEL:path> ^ARENA:arena ^JSON:writer -- n )
   {: c plans live ar w :}
   0 plans VEC:COUNT 0 ?do
      c plans i VEC:AT @ live ar w PLAN-ENTRY + ar ARENA:RESET
   loop ;

: RECONCILED
   ( SQLITE:connection ^VEC:vector<path-baseline>
     ^VEC:vector<path-plan> ^VEC:vector<MODEL:path> ^ARENA:arena
     ^JSON:writer -- reconciliation-write )
   {: c noops plans live ar w :}
   c noops live ar NOOPS-IN {: n :}
   c plans live ar w PLANS-IN {: p :}
   n p live JOURNAL-RECONCILIATION--WRITE:MAKE ;

public

\ Commits a batch of journal-only decisions together: all, or none
\ when one throws. The answer's vector is in ar.
: RECORD-RECONCILIATION
   ( journal ^VEC:vector<path-baseline> ^VEC:vector<path-plan>
     ^ARENA:arena -- reconciliation-write )
   {: j noops plans ar :}
   ar [type] MODEL:path NEW-VECTOR {: live :}
   noops VEC:COUNT plans VEC:COUNT or 0= if
      0 0 live JOURNAL-RECONCILIATION--WRITE:MAKE exit
   then
   j >CONNECTION {: c :}
   ar ARENA:NEW-IN {: row :}
   [: c [: c noops plans live row [: RECONCILED ;] ENCODING ;]
      SQLITE:WITH-TRANSACTION ;] [: row ARENA:RELEASE ;] finally ;

\ At most BATCH-BOUND plans awaiting their next effect whose id is above
\ the one given (all, for none), by id, each one's operations in order.
: PENDING-BATCH
   ( journal option<plan-id> ^ARENA:arena -- ^VEC:vector<plan-record> )
   {: j above ar :}
   j >CONNECTION PENDING-QUERY TEXT above s" read pending plans" ar
   READ-BATCH ;

\ The live plans, pending or blocked, and the blocked ones among them.
: LIVE-TALLY ( journal -- n n )
   >CONNECTION
   s" SELECT count(*), count(*) FILTER (WHERE status = 'blocked')
      FROM plans WHERE status IN ('pending', 'blocked')"
   [: TALLY-ROW ;] SQLITE:WITH-STATEMENT ;

\ At most BATCH-BOUND plans a classified failure holds, above the id as
\ PENDING-BATCH reads.
: BLOCKED-BATCH
   ( journal option<plan-id> ^ARENA:arena -- ^VEC:vector<plan-record> )
   {: j above ar :}
   j >CONNECTION BLOCKED-QUERY TEXT above s" read blocked plans" ar
   READ-BATCH ;

\ At most BATCH-BOUND completed, unforgotten plans that install a Dropbox
\ file, above the id, as PENDING-BATCH: a verified stage of each may remain.
: DOWNLOADED-BATCH
   ( journal option<plan-id> ^ARENA:arena -- ^VEC:vector<plan-record> )
   {: j above ar :}
   j >CONNECTION DOWNLOADED-QUERY TEXT above
   s" read completed download plans" ar READ-BATCH ;

\ Works each batch of read in ar, above the last plan of the one before, taken
\ before work may shrink it: true at an empty batch, false once work answers so.
: EACH-BATCH
   ( journal
     [ journal option<plan-id> ^ARENA:arena -- ^VEC:vector<plan-record> ]
     [ ^VEC:vector<plan-record> ^ARENA:arena -- bool ] ^ARENA:arena
     -- bool )
   {: j read work ar :}
   NO-PLAN-ID begin
      j swap ar read execute
      dup VEC:COUNT 0= if drop true exit then
      dup LAST-ID swap ar work execute 0= if drop false exit then
   again ;

\ The plan with this id as the journal holds it now, if any.
: PLAN-OF ( journal plan-id ^ARENA:arena -- option<plan-record> )
   {: j id ar :}
   j >CONNECTION id ar READ-PLAN ;

\ A remote conflict copy's verified stage that may be on disk: target the
\ copy's path, content the hash staged, key the canonical path of the
\ conflicted path whose live plan or conflict block may install it.
STRUCTURE copy-stage
   FIELD target MODEL:path
   FIELD content DROPBOX:hash
   FIELD key MODEL:key
;STRUCTURE

private

: STAGE-WRITTEN
   ( SQLITE:connection MODEL:path DROPBOX:hash MODEL:key -- )
   {: c target h:DROPBOX:hash k :}
   c s" INSERT INTO copy_stages(target, content, canonical_path)
      VALUES (?1, ?2, ?3) ON CONFLICT(target, content) DO NOTHING"
   [: target MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      h DROPBOX:HASH>STR 2 SQLITE:BIND-TEXT
      k MODEL:KEY>STR 3 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The stage in columns 0 to 2: its target, content and key.
: STAGE-COPY
   ( SQLITE:statement ^ARENA:arena -- SQLITE:statement copy-stage )
   {: ar :}
   0 ar PATH-COPY {: target :}
   1 ar TEXT-COPY DROPBOX:>HASH {: h:DROPBOX:hash :}
   2 ar KEY-COPY {: k :}
   target h k JOURNAL-COPY--STAGE:MAKE ;

: STAGE-ROWS
   ( SQLITE:statement ^VEC:vector<copy-stage> ^ARENA:arena
     -- SQLITE:statement )
   {: v ar :}
   begin SQLITE:STEP while ar STAGE-COPY v VEC:PUSH ! repeat ;

: STAGE-FORGOTTEN ( SQLITE:connection MODEL:path DROPBOX:hash -- )
   {: c target h:DROPBOX:hash :}
   c s" DELETE FROM copy_stages WHERE target = ?1 AND content = ?2"
   [: target MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      h DROPBOX:HASH>STR 2 SQLITE:BIND-TEXT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

public

\ Commits that a stage of content for the copy at target may be on disk,
\ held by canonical path k; a stage already recorded keeps its key.
: RECORD-COPY-STAGE ( journal MODEL:path DROPBOX:hash MODEL:key -- )
   {: j target h:DROPBOX:hash k :}
   j >CONNECTION {: c :}
   c [: c target h k STAGE-WRITTEN ;] SQLITE:WITH-TRANSACTION ;

\ The keys that hold a stage: those of a pending or blocked plan or of a
\ conflict block. Both copy-stage queries read this one definition, so a
\ stage either query calls held the other never retires. The status is a
\ literal, as at PENDING-QUERY.
: HELD-WITH ( -- str )
   s" WITH held AS (SELECT canonical_path FROM plans
         WHERE status IN ('pending', 'blocked')
      UNION SELECT canonical_path FROM conflict_blocks) " ;

: UNHELD-SELECT ( -- str )
   s" SELECT target, content, canonical_path FROM copy_stages
      WHERE canonical_path NOT IN (SELECT canonical_path FROM held)
      ORDER BY target, content" ;

: HELD-SELECT ( -- str )
   s" SELECT 1 FROM copy_stages WHERE target = ?1 AND content = ?2
      AND canonical_path IN (SELECT canonical_path FROM held)" ;

create UNHELD-QUERY HELD-WITH UNHELD-SELECT LAY-BOTH
create HELD-QUERY HELD-WITH HELD-SELECT LAY-BOTH

\ Every recorded stage whose key has no pending or blocked plan and no
\ conflict block, by target: nothing may install it any more.
: UNHELD-COPY-STAGES
   ( journal ^ARENA:arena -- ^VEC:vector<copy-stage> )
   {: j ar :}
   ar [type] copy-stage NEW-VECTOR {: v :}
   j >CONNECTION UNHELD-QUERY TEXT [: v ar STAGE-ROWS ;]
   SQLITE:WITH-STATEMENT
   v ;

\ Whether a stage of content for the copy at target is recorded with its
\ key held by a pending or blocked plan or a conflict block: something
\ may still install it.
: COPY-STAGE-HELD? ( journal MODEL:path DROPBOX:hash -- bool )
   {: j target h:DROPBOX:hash :}
   j >CONNECTION HELD-QUERY TEXT
   [: target MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      h DROPBOX:HASH>STR 2 SQLITE:BIND-TEXT
      SQLITE:STEP swap ;]
   SQLITE:WITH-STATEMENT ;

\ Forgets the stage recorded for target and content, if any; the caller
\ removes it from disk first.
: FORGET-COPY-STAGE ( journal MODEL:path DROPBOX:hash -- )
   {: j target h:DROPBOX:hash :}
   j >CONNECTION {: c :}
   c [: c target h STAGE-FORGOTTEN ;] SQLITE:WITH-TRANSACTION ;

private

: FIRST-PLAN ( ^VEC:vector<plan-record> -- option<plan-record> )
   {: plans :}
   plans VEC:COUNT 0= if NO-PLAN exit then
   plans 0 VEC:AT @ OPTION:SOME ;

public

\ The plan pending or blocked at the canonical path; the journal keeps
\ at most one.
: LIVE-PLAN-AT
   ( journal MODEL:key ^ARENA:arena -- option<plan-record> )
   {: j k ar :}
   ar [type] plan-record NEW-VECTOR {: plans :}
   j >CONNECTION
   s" SELECT plans.id, plans.path, plans.status, plans.blocked_json,
         plans.retry_at, operations.id, operations.ordinal,
         operations.operation_json, operations.status
      FROM plans JOIN operations ON operations.plan_id = plans.id
      WHERE plans.canonical_path = ?1
         AND plans.status IN ('pending', 'blocked')
      ORDER BY plans.id, operations.ordinal" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
      begin SQLITE:STEP while
         plans s" read live plan" ar PLAN-ROW
      repeat ;]
   SQLITE:WITH-STATEMENT
   plans FIRST-PLAN ;

private


\ ---- blocking ------------------------------------------------------

: COMPLETED? ( plan-status -- bool )
   MATCH plan-status
      pending OF false ENDOF
      blocked OF 2drop false ENDOF
      completed OF true ENDOF
   ;MATCH ;

: BLOCKED? ( plan-status -- bool )
   MATCH plan-status
      pending OF false ENDOF
      blocked OF 2drop true ENDOF
      completed OF false ENDOF
   ;MATCH ;

\ A retry time past SQLite's integer range is a u64 above INT-MAX, which
\ a cell holds as a negative number.
: BLOCKING ( SQLITE:connection plan-id str n MODEL:path -- )
   {: c id js:str at path :}
   at 0 < if
      s" block plan" path
      s" retry time exceeds the supported range" PATH-INVALID
   then
   c s" UPDATE plans SET status = 'blocked', blocked_json = ?2,
         retry_at = ?3
      WHERE id = ?1" [: id PLAN-ID>N 1 SQLITE:BIND-INT
      js 2 SQLITE:BIND-TEXT
      at 3 SQLITE:BIND-INT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: BLOCK-STATED
   ( SQLITE:connection plan-id MODEL:blockage n plan-state ^JSON:writer
     -- plan-block )
   {: c id reason at state w :}
   state PLAN-STATE-UNMAKE {: path status :}
   status COMPLETED? if
      construct plan-block already-completed exit
   then
   c id reason w ENCODE-BLOCKAGE at path BLOCKING
   construct plan-block blocked ;

: BLOCK-IN
   ( SQLITE:connection plan-id MODEL:blockage n ^ARENA:arena
     ^JSON:writer -- plan-block )
   {: c id reason at ar w :}
   c id s" read plan status for blocking" ar READ-PLAN-STATE
   MATCH option
      none OF construct plan-block not-found ENDOF
      some OF {: state :} c id reason at state w BLOCK-STATED ENDOF
   ;MATCH ;

: UNBLOCKING ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE plans SET status = 'pending', blocked_json = NULL,
         retry_at = NULL
      WHERE id = ?1" [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: UNBLOCK-STATED
   ( SQLITE:connection plan-id plan-state -- plan-unblock )
   {: c id state :}
   state PLAN-STATE-UNMAKE {: path status :}
   status BLOCKED? 0= if construct plan-unblock not-blocked exit then
   c id UNBLOCKING
   construct plan-unblock unblocked ;

: UNBLOCK-IN ( SQLITE:connection plan-id ^ARENA:arena -- plan-unblock )
   {: c id ar :}
   c id s" read plan status for unblocking" ar READ-PLAN-STATE
   MATCH option
      none OF construct plan-unblock not-found ENDOF
      some OF {: state :} c id state UNBLOCK-STATED ENDOF
   ;MATCH ;

\ The upload payload a remote mutation still references, if any.
: PUSH-UPLOAD ( MODEL:operation ^VEC:vector<DROPBOX:hash> -- )
   {: hashes :}
   MATCH MODEL:operation
      create-local-directory OF ENDOF
      create-remote-directory OF ENDOF
      delete-local-directory OF ENDOF
      delete-remote-directory OF ENDOF
      create-remote OF hashes VEC:PUSH ! ENDOF
      install-local OF drop ENDOF
      preserve-local OF drop ENDOF
      replace-local OF 2drop ENDOF
      delete-local OF drop ENDOF
      preserve-remote OF drop ENDOF
      replace-remote OF drop hashes VEC:PUSH ! ENDOF
      delete-remote OF drop ENDOF
   ;MATCH ;

: UPLOAD-ROW
   ( SQLITE:statement ^VEC:vector<DROPBOX:hash> ^ARENA:arena
     -- SQLITE:statement )
   {: hashes ar :}
   0 ar PATH-COPY {: path :}
   1 SQLITE:COL-TEXT path ar
   s" deserialize pending upload operation" OPERATION-AS
   hashes PUSH-UPLOAD ;

public

\ How long a blocked plan waits for its next attempt, in seconds.
3600 constant BLOCK-RETRY-SECONDS

\ Holds a live plan until its classified cause is worth retrying, at
\ retry-at, seconds since the epoch.
: BLOCK-PLAN
   ( journal plan-id MODEL:blockage n ^ARENA:arena -- plan-block )
   {: j id reason at ar :}
   j >CONNECTION {: c :}
   c [: c id reason at ar [: BLOCK-IN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

\ Returns a blocked plan to pending work for one more attempt.
: UNBLOCK-PLAN ( journal plan-id ^ARENA:arena -- plan-unblock )
   {: j id ar :}
   j >CONNECTION {: c :}
   c [: c id ar UNBLOCK-IN ;] SQLITE:WITH-TRANSACTION ;

\ The upload payloads pending remote mutations of live plans still
\ reference, in operation order.
: PENDING-UPLOAD-CONTENT
   ( journal ^ARENA:arena -- ^VEC:vector<DROPBOX:hash> )
   {: j ar :}
   ar [type] DROPBOX:hash NEW-VECTOR {: hashes :}
   j >CONNECTION
   s" SELECT plans.path, operations.operation_json
      FROM operations JOIN plans ON plans.id = operations.plan_id
      WHERE plans.status IN ('pending', 'blocked')
         AND operations.status = 'pending'
      ORDER BY operations.id" [: begin SQLITE:STEP while hashes ar UPLOAD-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   hashes ;


\ ---- completions and conflicts: values ----------------------------

public

\ What completing one operation answered: a final operation takes its
\ resulting baseline, a non-final one none; id is the pending earlier one.
ENUM operation-completion
   VARIANT not-found ;VARIANT
   VARIANT already-completed ;VARIANT
   VARIANT waiting-for-earlier-operation FIELD id operation-id ;VARIANT
   VARIANT baseline-required ;VARIANT
   VARIANT unexpected-baseline ;VARIANT
   VARIANT baseline-mismatch ;VARIANT
   VARIANT operation-completed ;VARIANT
   VARIANT plan-completed ;VARIANT
;ENUM

\ A final operation and the baseline it resulted in.
STRUCTURE operation-baseline
   FIELD id operation-id
   FIELD baseline MODEL:baseline
;STRUCTURE

\ One durable conflict, the planner's payload whole.
STRUCTURE conflict-record
   FIELD id n
   FIELD path MODEL:path
   FIELD conflict MODEL:conflict
;STRUCTURE

\ recorded: the conflict and the plan's completion committed together.
ENUM plan-conflict-completion not-found already-completed recorded ;ENUM

\ superseded: the plan and its pending operations retired together.
ENUM plan-supersede not-found already-completed superseded ;ENUM

private

\ An operation's plan, its ordinal, whether it or its plan has
\ completed, its plan's path and its stored JSON.
STRUCTURE operation-state
   FIELD plan plan-id
   FIELD ordinal n
   FIELD done bool
   FIELD path MODEL:path
   FIELD json str
;STRUCTURE


\ ---- completions and conflicts: stored values ---------------------

: DECODE-CONFLICT ( str MODEL:path ^ARENA:arena -- MODEL:conflict )
   {: json:str path ar :}
   MODEL:NO-HASH MODEL-LOCAL:MAKE MODEL-CONFLICT:REMOTE-DELETED
   [: DROP-CONFLICT json ar MODEL:JSON>CONFLICT ;]
   s" deserialize conflict" path MODEL:PATH>STR DECODE ;

: ENCODE-CONFLICT ( MODEL:conflict ^JSON:writer -- str )
   {: x w :}
   w [: x swap MODEL:CONFLICT>JSON ;] ENCODE ;

: NO-OPERATION-ID ( -- option<operation-id> ) OPTION:NONE ;
: NO-STEP ( -- option<operation-state> ) OPTION:NONE ;

: SOME-BASELINE? ( option<MODEL:baseline> -- bool )
   MATCH option
      none OF false ENDOF
      some OF drop true ENDOF
   ;MATCH ;

: DONE? ( record-status -- bool )
   MATCH record-status
      pending OF false ENDOF
      completed OF true ENDOF
   ;MATCH ;


\ ---- a final operation's baseline ----

: HASH= ( DROPBOX:hash DROPBOX:hash -- bool )
   {: a b :}
   a DROPBOX:HASH>STR b DROPBOX:HASH>STR STR:= ;

: DIRECTORY? ( MODEL:baseline -- bool )
   MATCH MODEL:baseline
      absent OF false ENDOF
      present OF drop false ENDOF
      directory OF true ENDOF
   ;MATCH ;

\ The baseline is a present file with the content.
: HAS-CONTENT? ( DROPBOX:hash MODEL:baseline -- bool )
   {: c b :}
   b MATCH MODEL:baseline
      absent OF false ENDOF
      present OF MODEL-REMOTE:UNMAKE drop c HASH= ENDOF
      directory OF false ENDOF
   ;MATCH ;

\ The baseline is the present remote file.
: HOLDS? ( MODEL:remote MODEL:baseline -- bool )
   {: r b :}
   b MATCH MODEL:baseline
      absent OF false ENDOF
      present OF r MODEL:REMOTE= ENDOF
      directory OF false ENDOF
   ;MATCH ;

\ Whether the baseline is the one the final operation results in.
: OPERATION-MATCHES-BASELINE? ( MODEL:operation MODEL:baseline -- bool )
   {: b :}
   MATCH MODEL:operation
      create-local-directory OF b DIRECTORY? ENDOF
      create-remote-directory OF b DIRECTORY? ENDOF
      delete-local-directory OF b ABSENT? ENDOF
      delete-remote-directory OF b ABSENT? ENDOF
      create-remote OF b HAS-CONTENT? ENDOF
      install-local OF b HOLDS? ENDOF
      preserve-local OF drop false ENDOF
      replace-local OF drop b HOLDS? ENDOF
      delete-local OF drop b ABSENT? ENDOF
      preserve-remote OF drop false ENDOF
      replace-remote OF drop b HAS-CONTENT? ENDOF
      delete-remote OF drop b ABSENT? ENDOF
   ;MATCH ;


\ ---- the writes they share -----------------------------------------

\ The operation's upload session, if any, forgotten.
: RETIRE-SESSION ( SQLITE:connection operation-id -- )
   {: c id :}
   c s" DELETE FROM upload_sessions WHERE operation_id = ?1" [: id OPERATION-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The upload sessions of the plan's operations forgotten.
: RETIRE-SESSIONS ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" DELETE FROM upload_sessions WHERE operation_id IN (
         SELECT id FROM operations WHERE plan_id = ?1
      )" [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: FINISH-PLAN ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE plans
      SET status = 'completed', blocked_json = NULL, retry_at = NULL
      WHERE id = ?1" [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The plan's completed recovery copies start their retention now.
: START-RECOVERY-RETENTION ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE recovery_records SET retained_at = unixepoch()
      WHERE status = 'completed' AND retained_at IS NULL
         AND operation_id IN (
            SELECT id FROM operations WHERE plan_id = ?1
         )" [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The plan and every operation of it completed, its baseline unchanged,
\ and their upload sessions forgotten.
: RETIRE-PLAN ( SQLITE:connection plan-id -- )
   {: c id :}
   c id RETIRE-SESSIONS
   c s" UPDATE operations SET status = 'completed' WHERE plan_id = ?1" [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c id FINISH-PLAN
   c id START-RECOVERY-RETENTION ;

\ Deletes the plan with this id, its operations' upload sessions first,
\ then its operations, when it is completed and no pending or unretained
\ recovery record holds it.
: FORGET-PLAN ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" DELETE FROM upload_sessions WHERE operation_id IN (
         SELECT operations.id FROM operations WHERE plan_id IN (
            SELECT plans.id FROM plans
            WHERE plans.id = ?1 AND plans.status = 'completed'
            AND NOT EXISTS (
               SELECT 1 FROM operations JOIN recovery_records
                  ON recovery_records.operation_id = operations.id
               WHERE operations.plan_id = plans.id
                  AND (recovery_records.status = 'pending'
                     OR recovery_records.retained_at IS NULL))))"
   [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c s" DELETE FROM operations WHERE plan_id IN (
         SELECT plans.id FROM plans
         WHERE plans.id = ?1 AND plans.status = 'completed'
         AND NOT EXISTS (
            SELECT 1 FROM operations JOIN recovery_records
               ON recovery_records.operation_id = operations.id
            WHERE operations.plan_id = plans.id
               AND (recovery_records.status = 'pending'
                  OR recovery_records.retained_at IS NULL)))"
   [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c s" DELETE FROM plans WHERE plans.id = ?1
      AND plans.status = 'completed'
      AND NOT EXISTS (
         SELECT 1 FROM operations JOIN recovery_records
            ON recovery_records.operation_id = operations.id
         WHERE operations.plan_id = plans.id
            AND (recovery_records.status = 'pending'
               OR recovery_records.retained_at IS NULL))"
   [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The new conflict's id.
: INSERT-CONFLICT
   ( SQLITE:connection MODEL:path MODEL:conflict ^ARENA:arena
     ^JSON:writer -- n )
   {: c path x ar w :}
   x w ENCODE-CONFLICT {: js:str :}
   path ar MODEL:FOLD {: k :}
   c s" INSERT INTO conflicts(path, conflict_json, canonical_path)
      VALUES (?1, ?2, ?3)" [: path MODEL:PATH>STR 1 SQLITE:BIND-BLOB
      js 2 SQLITE:BIND-TEXT
      k MODEL:KEY>STR 3 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c SQLITE:LAST-ROWID ;


\ ---- completing an operation ----

: STEP-QUERY ( -- str )
   s" SELECT operations.plan_id, operations.ordinal, operations.status,
         plans.status, plans.path, operations.operation_json,
         plans.blocked_json, plans.retry_at
      FROM operations JOIN plans ON plans.id = operations.plan_id
      WHERE operations.id = ?1" ;

\ STEP-QUERY's row; a status that does not read is invalid state.
: STEP-COLS
   ( SQLITE:statement ^ARENA:arena -- SQLITE:statement operation-state )
   {: ar :}
   4 ar PATH-COPY {: path :}
   2 SQLITE:COL-TEXT s" read operation status"
   path MODEL:PATH>STR DECODE-STATUS {: s :}
   3 SQLITE:COL-TEXT {: ps:str :}
   6 TEXT? {: json :}
   7 INT? {: retry :}
   ps json retry s" read plan status" path ar DECODE-PLAN-STATUS
   {: status :}
   5 ar TEXT-COPY {: o:str :}
   0 SQLITE:COL-INT >PLAN-ID {: plan :}
   1 SQLITE:COL-INT {: ordinal :}
   plan ordinal s DONE? status COMPLETED? or path o
   OPERATION-STATE-MAKE ;

: STEP-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<operation-state> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-STEP swap exit then
   ar STEP-COLS OPTION:SOME swap ;

: READ-STEP
   ( SQLITE:connection operation-id ^ARENA:arena
     -- option<operation-state> )
   {: c id ar :}
   c STEP-QUERY
    [: id OPERATION-ID>N 1 SQLITE:BIND-INT ar STEP-ROW ;]
   SQLITE:WITH-STATEMENT ;

: EARLIER-ROW ( SQLITE:statement -- option<operation-id> SQLITE:statement )
   SQLITE:STEP 0= if NO-OPERATION-ID swap exit then
   0 SQLITE:COL-INT >OPERATION-ID OPTION:SOME swap ;

\ The first pending operation of the plan before the ordinal, if any.
: EARLIER ( SQLITE:connection operation-state -- option<operation-id> )
   {: c s :}
   s OPERATION-STATE-UNMAKE {: plan ordinal done:bool path json:str :}
   c s" SELECT id FROM operations
      WHERE plan_id = ?1 AND ordinal < ?2 AND status = 'pending'
      ORDER BY ordinal LIMIT 1" [: plan PLAN-ID>N 1 SQLITE:BIND-INT ordinal 2 SQLITE:BIND-INT
      EARLIER-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Whether the plan holds an operation after the ordinal.
: LATER? ( SQLITE:connection operation-state -- bool )
   {: c s :}
   s OPERATION-STATE-UNMAKE {: plan ordinal done:bool path json:str :}
   c s" SELECT EXISTS(SELECT 1 FROM operations
      WHERE plan_id = ?1 AND ordinal > ?2)" [: plan PLAN-ID>N 1 SQLITE:BIND-INT ordinal 2 SQLITE:BIND-INT
      INT-ROW ;]
   SQLITE:WITH-STATEMENT 0<> ;

\ The operation completed, the legacy recovery intent it had, and its
\ upload session forgotten.
: MARK-COMPLETED ( SQLITE:connection operation-id -- )
   {: c id :}
   c id RETIRE-SESSION
   c s" UPDATE operations SET status = 'completed' WHERE id = ?1" [: id OPERATION-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c s" UPDATE recovery_records SET status = 'completed'
      WHERE operation_id = ?1 AND status = 'pending'" [: id OPERATION-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The final operation, its plan and the actual baseline completed; the
\ path's conflicts are resolved.
: COMPLETE-FINAL
   ( SQLITE:connection operation-id operation-state MODEL:operation
     MODEL:baseline ^ARENA:arena -- operation-completion )
   {: c id s o b ar :}
   o b OPERATION-MATCHES-BASELINE? 0= if
      construct operation-completion baseline-mismatch exit
   then
   s OPERATION-STATE-UNMAKE {: plan ordinal done:bool path json:str :}
   c id MARK-COMPLETED
   c path b ar WRITE-BASELINE
   c path ar MODEL:FOLD RETIRE-CONFLICTS
   c plan FINISH-PLAN
   c plan START-RECOVERY-RETENTION
   construct operation-completion plan-completed ;

\ No earlier operation is pending: a non-final one completes with no
\ baseline, the final one with its own.
: COMPLETE-IN-ORDER
   ( SQLITE:connection operation-id operation-state MODEL:operation
     option<MODEL:baseline> ^ARENA:arena -- operation-completion )
   {: c id s o b ar :}
   c s LATER? if
      b SOME-BASELINE? if
         construct operation-completion unexpected-baseline exit
      then
      c id MARK-COMPLETED
      construct operation-completion operation-completed exit
   then
   b MATCH option
      none OF construct operation-completion baseline-required ENDOF
      some OF {: r :} c id s o r ar COMPLETE-FINAL ENDOF
   ;MATCH ;

: COMPLETE-FOUND
   ( SQLITE:connection operation-id operation-state
     option<MODEL:baseline> ^ARENA:arena -- operation-completion )
   {: c id s b ar :}
   s OPERATION-STATE-UNMAKE {: plan ordinal done:bool path json:str :}
   done if construct operation-completion already-completed exit then
   json path ar DECODE-OPERATION {: o :}
   c s EARLIER MATCH option
      some OF construct operation-completion waiting-for-earlier-operation
      ENDOF
      none OF c id s o b ar COMPLETE-IN-ORDER ENDOF
   ;MATCH ;

: COMPLETE-OPERATION-IN
   ( SQLITE:connection operation-id option<MODEL:baseline> ^ARENA:arena
     -- operation-completion )
   {: c id b ar :}
   c id ar READ-STEP MATCH option
      none OF construct operation-completion not-found ENDOF
      some OF {: s :} c id s b ar COMPLETE-FOUND ENDOF
   ;MATCH ;

: COMPLETE-ALL
   ( SQLITE:connection ^VEC:vector<operation-baseline>
     ^VEC:vector<operation-completion> ^ARENA:arena -- )
   {: c finals outcomes ar :}
   finals VEC:COUNT 0 ?do
      finals i VEC:AT @ JOURNAL-OPERATION--BASELINE:UNMAKE {: id b :}
      c id b OPTION:SOME ar COMPLETE-OPERATION-IN outcomes VEC:PUSH !
   loop ;


\ ---- plan retirement -----------------------------------------------

: RECORD-LIVE-CONFLICT
   ( SQLITE:connection plan-id plan-state MODEL:conflict ^ARENA:arena
     ^JSON:writer -- plan-conflict-completion )
   {: c id st x ar w :}
   st PLAN-STATE-UNMAKE {: path status :}
   status COMPLETED? if
      construct plan-conflict-completion already-completed exit
   then
   c path x ar w INSERT-CONFLICT drop
   c id RETIRE-PLAN
   construct plan-conflict-completion recorded ;

: FINISH-WITH-CONFLICT-IN
   ( SQLITE:connection plan-id MODEL:conflict ^ARENA:arena ^JSON:writer
     -- plan-conflict-completion )
   {: c id x ar w :}
   c id s" read plan status for conflict" ar READ-PLAN-STATE
   MATCH option
      none OF construct plan-conflict-completion not-found ENDOF
      some OF {: st :} c id st x ar w RECORD-LIVE-CONFLICT ENDOF
   ;MATCH ;

: SUPERSEDE-LIVE ( SQLITE:connection plan-id plan-state -- plan-supersede )
   {: c id st :}
   st PLAN-STATE-UNMAKE {: path status :}
   status COMPLETED? if construct plan-supersede already-completed exit then
   c id RETIRE-PLAN
   construct plan-supersede superseded ;

: SUPERSEDE-IN
   ( SQLITE:connection plan-id ^ARENA:arena -- plan-supersede )
   {: c id ar :}
   c id s" read plan status for supersession" ar READ-PLAN-STATE
   MATCH option
      none OF construct plan-supersede not-found ENDOF
      some OF {: st :} c id st SUPERSEDE-LIVE ENDOF
   ;MATCH ;

: CONFLICT-ROW
   ( SQLITE:statement ^VEC:vector<conflict-record> ^ARENA:arena
     -- SQLITE:statement )
   {: found ar :}
   1 ar PATH-COPY {: path :}
   2 SQLITE:COL-TEXT path ar DECODE-CONFLICT {: x :}
   0 SQLITE:COL-INT path x JOURNAL-CONFLICT--RECORD:MAKE
   found VEC:PUSH ! ;

public

\ Completes one operation in its plan's order; the final one completes
\ its plan and writes its resulting baseline in the same transaction.
: COMPLETE-OPERATION
   ( journal operation-id option<MODEL:baseline> ^ARENA:arena
     -- operation-completion )
   {: j id b ar :}
   j >CONNECTION {: c :}
   c [: c id b ar COMPLETE-OPERATION-IN ;]
   SQLITE:WITH-TRANSACTION ;

\ Completes independent final operations in one transaction: all, or
\ none when one throws; an outcome for each, in order.
: COMPLETE-FINAL-OPERATIONS
   ( journal ^VEC:vector<operation-baseline> ^ARENA:arena
     -- ^VEC:vector<operation-completion> )
   {: j finals ar :}
   ar [type] operation-completion NEW-VECTOR {: outcomes :}
   finals VEC:COUNT 0= if outcomes exit then
   j >CONNECTION {: c :}
   c [: c finals outcomes ar COMPLETE-ALL ;]
   SQLITE:WITH-TRANSACTION
   outcomes ;

\ Records the conflict and retires its live plan together; the baseline
\ stays.
: FINISH-PLAN-WITH-CONFLICT
   ( journal plan-id MODEL:conflict ^ARENA:arena
     -- plan-conflict-completion )
   {: j id x ar :}
   j >CONNECTION {: c :}
   c [: c id x ar [: FINISH-WITH-CONFLICT-IN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

\ Deletes the completed plan with this id, its operations and their
\ upload sessions, unless a pending or unretained recovery record holds
\ it; a live plan, or one already gone, is left as it is.
: FORGET-COMPLETED-PLAN ( journal plan-id -- )
   {: j id :}
   j >CONNECTION {: c :}
   c [: c id FORGET-PLAN ;] SQLITE:WITH-TRANSACTION ;

\ Retires a stale live plan without advancing or deleting its baseline.
: SUPERSEDE-PLAN ( journal plan-id ^ARENA:arena -- plan-supersede )
   {: j id ar :}
   j >CONNECTION {: c :}
   c [: c id ar SUPERSEDE-IN ;] SQLITE:WITH-TRANSACTION ;

\ Records a planner conflict as it is, neither side interpreted or
\ dropped.
: RECORD-CONFLICT
   ( journal MODEL:path MODEL:conflict ^ARENA:arena -- conflict-record )
   {: j path x ar :}
   j >CONNECTION {: c :}
   c [: c path x ar [: INSERT-CONFLICT ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION {: id :}
   id path x JOURNAL-CONFLICT--RECORD:MAKE ;

\ Every recorded conflict, by id.
: CONFLICTS ( journal ^ARENA:arena -- ^VEC:vector<conflict-record> )
   {: j ar :}
   ar [type] conflict-record NEW-VECTOR {: found :}
   j >CONNECTION
   s" SELECT id, path, conflict_json FROM conflicts ORDER BY id" [: begin SQLITE:STEP while found ar CONFLICT-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   found ;


\ ---- upload sessions ------------------------------------------------

\ The upload session Dropbox holds open for an operation: its id, the
\ bytes Dropbox confirmed, the upload's length and the content hash of
\ its bytes. Completing the operation, a conflict or supersession of its
\ plan, a new root's activation and the prune that removes the operation
\ forget it; blocking and unblocking the plan keep it.
STRUCTURE upload-session
   FIELD id str
   FIELD offset n
   FIELD length n
   FIELD content DROPBOX:hash
;STRUCTURE

private

: NO-SESSION ( -- option<upload-session> ) OPTION:NONE ;

: SESSION-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<upload-session> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-SESSION swap exit then
   0 ar TEXT-COPY {: sid:str :}
   1 SQLITE:COL-INT {: at :}
   2 SQLITE:COL-INT {: u :}
   3 ar TEXT-COPY DROPBOX:>HASH {: h:DROPBOX:hash :}
   sid at u h JOURNAL-UPLOAD--SESSION:MAKE OPTION:SOME swap ;

: UPSERT-SESSION ( -- str )
   s" INSERT INTO upload_sessions(
         operation_id, session_id, confirmed_offset, length, content
      ) VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT(operation_id) DO UPDATE SET
         session_id = excluded.session_id,
         confirmed_offset = excluded.confirmed_offset,
         length = excluded.length,
         content = excluded.content" ;

\ An offset past the length, an empty id or an operation the journal
\ does not hold is SQLITE's throw.
: SESSION-WRITTEN
   ( SQLITE:connection operation-id str n n DROPBOX:hash -- )
   {: c id sid:str at u h:DROPBOX:hash :}
   c UPSERT-SESSION
   [: id OPERATION-ID>N 1 SQLITE:BIND-INT
      sid 2 SQLITE:BIND-TEXT
      at 3 SQLITE:BIND-INT
      u 4 SQLITE:BIND-INT
      h DROPBOX:HASH>STR 5 SQLITE:BIND-TEXT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

public

\ The operation's recorded upload session, if any.
: UPLOAD-SESSION
   ( journal operation-id ^ARENA:arena -- option<upload-session> )
   {: j id ar :}
   j >CONNECTION
   s" SELECT session_id, confirmed_offset, length, content
      FROM upload_sessions WHERE operation_id = ?1"
   [: id OPERATION-ID>N 1 SQLITE:BIND-INT ar SESSION-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Records that Dropbox confirmed offset bytes of the operation's upload
\ of length bytes with the content hash in the session named by the
\ string, replacing what the operation held. A content hash that is not
\ Dropbox's is never recorded.
: CHECKPOINT-UPLOAD
   ( journal operation-id str n n DROPBOX:hash -- )
   {: j id sid:str at u h:DROPBOX:hash :}
   h DROPBOX:HASH>STR DROPBOX:CONTENT-HASH? 0= if
      s" checkpoint upload session" j >PATH
      s" upload content is not a Dropbox content hash" INVALID
   then
   j >CONNECTION {: c :}
   c [: c id sid at u h SESSION-WRITTEN ;] SQLITE:WITH-TRANSACTION ;

\ Forgets the operation's upload session, if any.
: RETIRE-UPLOAD ( journal operation-id -- )
   {: j id :}
   j >CONNECTION {: c :}
   c [: c id RETIRE-SESSION ;] SQLITE:WITH-TRANSACTION ;


\ ---- conflict blocks ------------------------------------------------

public

\ A new conflict's copies blocked: why, and retry-at, seconds since the
\ epoch.
STRUCTURE conflict-block
   FIELD path MODEL:path
   FIELD reason MODEL:blockage
   FIELD retry-at n
;STRUCTURE

private

: NO-BLOCK ( -- option<conflict-block> ) OPTION:NONE ;

\ The block in columns 0 to 2: its path, reason and retry time.
: BLOCK-COPY
   ( SQLITE:statement ^ARENA:arena -- SQLITE:statement conflict-block )
   {: ar :}
   0 ar PATH-COPY {: path :}
   1 SQLITE:COL-TEXT path ar DECODE-BLOCKAGE {: why :}
   2 SQLITE:COL-INT {: at :}
   at 0 < if
      s" read conflict block" path
      s" conflict block has a negative retry time" PATH-INVALID
   then
   path why at JOURNAL-CONFLICT--BLOCK:MAKE ;

: BLOCK-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<conflict-block> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-BLOCK swap exit then
   ar BLOCK-COPY OPTION:SOME swap ;

: BLOCK-ROWS
   ( SQLITE:statement ^VEC:vector<conflict-block> ^ARENA:arena
     -- SQLITE:statement )
   {: v ar :}
   begin SQLITE:STEP while ar BLOCK-COPY v VEC:PUSH ! repeat ;

: BLOCK-KEYS
   ( SQLITE:statement ^VEC:vector<MODEL:key> ^ARENA:arena
     -- SQLITE:statement )
   {: v ar :}
   begin SQLITE:STEP while 0 ar KEY-COPY v VEC:PUSH ! repeat ;

: BLOCKING-CONFLICT
   ( SQLITE:connection MODEL:path MODEL:blockage n ^ARENA:arena
     ^JSON:writer -- )
   {: c path why at ar w :}
   why w ENCODE-BLOCKAGE {: js:str :}
   path ar MODEL:FOLD {: k :}
   c s" INSERT INTO conflict_blocks(
         canonical_path, path, blocked_json, retry_at
      ) VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(canonical_path) DO UPDATE SET path = ?2,
         blocked_json = ?3, retry_at = ?4" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB
      path MODEL:PATH>STR 2 SQLITE:BIND-BLOB
      js 3 SQLITE:BIND-TEXT
      at 4 SQLITE:BIND-INT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: UNBLOCKING-CONFLICT ( SQLITE:connection MODEL:key -- )
   {: c k :}
   c s" DELETE FROM conflict_blocks WHERE canonical_path = ?1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

public

\ Records the new conflict at path blocked for why until at, seconds
\ since the epoch, replacing any block at its canonical path.
: BLOCK-NEW-CONFLICT
   ( journal MODEL:path MODEL:blockage n ^ARENA:arena -- )
   {: j path why at ar :}
   at 0 < if
      s" block conflict" path
      s" retry time exceeds the supported range" PATH-INVALID
   then
   j >CONNECTION {: c :}
   c [: c path why at ar [: BLOCKING-CONFLICT ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

\ The conflict block at canonical path k, if any.
: CONFLICT-BLOCK-AT
   ( journal MODEL:key ^ARENA:arena -- option<conflict-block> )
   {: j k ar :}
   j >CONNECTION
   s" SELECT path, blocked_json, retry_at FROM conflict_blocks
      WHERE canonical_path = ?1" [: k MODEL:KEY>STR 1 SQLITE:BIND-BLOB ar BLOCK-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Every conflict block, by canonical path.
: CONFLICT-BLOCKS ( journal ^ARENA:arena -- ^VEC:vector<conflict-block> )
   {: j ar :}
   ar [type] conflict-block NEW-VECTOR {: v :}
   j >CONNECTION
   s" SELECT path, blocked_json, retry_at FROM conflict_blocks
      ORDER BY canonical_path" [: v ar BLOCK-ROWS ;]
   SQLITE:WITH-STATEMENT
   v ;

\ The canonical path of every conflict block, in order.
: CONFLICT-BLOCK-KEYS ( journal ^ARENA:arena -- ^VEC:vector<MODEL:key> )
   {: j ar :}
   ar [type] MODEL:key NEW-VECTOR {: v :}
   j >CONNECTION
   s" SELECT canonical_path FROM conflict_blocks
      ORDER BY canonical_path" [: v ar BLOCK-KEYS ;]
   SQLITE:WITH-STATEMENT
   v ;

\ Forgets the conflict block at canonical path k, if any.
: UNBLOCK-CONFLICT ( journal MODEL:key -- )
   {: j k :}
   j >CONNECTION {: c :}
   c [: c k UNBLOCKING-CONFLICT ;] SQLITE:WITH-TRANSACTION ;


\ ---- recoveries: values ---------------------------------------------

public

DEFTYPE RECOVERY-ID

\ A recovery copy an older Omabox version kept. retained-at: seconds
\ since the epoch at which its destructive work committed.
STRUCTURE recovery-record
   FIELD id recovery-id
   FIELD operation-id operation-id
   FIELD original-path MODEL:path
   FIELD recovery-path MODEL:path
   FIELD content DROPBOX:hash
   FIELD status record-status
   FIELD retained-at option<n>
;STRUCTURE

\ pending: unfinished work may still need the recovery payload.
ENUM recovery-forget not-found pending forgotten ;ENUM

private


\ ---- recoveries: reading ---------------------------------------------

: NO-RECOVERY ( -- option<recovery-record> ) OPTION:NONE ;
: NO-FLAG ( -- option<bool> ) OPTION:NONE ;

: DECODE-CONTENT ( str MODEL:path ^ARENA:arena -- DROPBOX:hash )
   {: json:str path ar :}
   MODEL:NO-HASH
   [: DROP-HASH json ar MODEL:JSON>HASH ;]
   s" deserialize recovery content" path MODEL:PATH>STR DECODE ;

: RETAINED-AT ( option<n> MODEL:path -- option<n> )
   {: path :}
   MATCH option
      none OF NO-INT ENDOF
      some OF
         {: at :}
         at 0 < if
            s" read recovery retention start" path
            s" recovery retention start is outside the supported range"
            PATH-INVALID
         then
         at OPTION:SOME
      ENDOF
   ;MATCH ;

\ The record in a row of READ-RECOVERY's query; a failure names its
\ original path.
: RECOVERY-COLS
   ( SQLITE:statement recovery-id ^ARENA:arena
     -- SQLITE:statement recovery-record )
   {: id ar :}
   1 ar PATH-COPY {: original :}
   5 INT? original RETAINED-AT {: retained :}
   2 ar PATH-COPY {: copy :}
   3 SQLITE:COL-TEXT original ar DECODE-CONTENT {: content :}
   4 SQLITE:COL-TEXT s" read recovery status"
   original MODEL:PATH>STR DECODE-STATUS {: status :}
   0 SQLITE:COL-INT >OPERATION-ID {: op :}
   id op original copy content status retained
   JOURNAL-RECOVERY--RECORD:MAKE ;

: RECOVERY-ROW
   ( SQLITE:statement recovery-id ^ARENA:arena
     -- option<recovery-record> SQLITE:statement )
   {: id ar :}
   SQLITE:STEP 0= if NO-RECOVERY swap exit then
   id ar RECOVERY-COLS OPTION:SOME swap ;

: READ-RECOVERY
   ( SQLITE:connection recovery-id ^ARENA:arena -- option<recovery-record> )
   {: c id ar :}
   c s" SELECT operation_id, original_path, recovery_path, content_json,
         status, retained_at
      FROM recovery_records WHERE id = ?1" [: id RECOVERY-ID>N 1 SQLITE:BIND-INT id ar RECOVERY-ROW ;]
   SQLITE:WITH-STATEMENT ;

: PUSH-RECOVERY-ID
   ( SQLITE:statement ^VEC:vector<recovery-id> -- SQLITE:statement )
   {: ids :}
   0 SQLITE:COL-INT >RECOVERY-ID ids VEC:PUSH ! ;

\ Each selected record, read again; one gone since is op's invalid state
\ on path, as detail says.
: READ-EACH
   ( SQLITE:connection ^VEC:vector<recovery-id> str str str
     ^ARENA:arena -- ^VEC:vector<recovery-record> )
   {: c ids op:str path:str d:str ar :}
   ar [type] recovery-record NEW-VECTOR {: found :}
   ids VEC:COUNT 0 ?do
      c ids i VEC:AT @ ar READ-RECOVERY MATCH option
         none OF op path d INVALID ENDOF
         some OF found VEC:PUSH ! ENDOF
      ;MATCH
   loop
   found ;

\ Every record whose status is the text, by id; op names a failure.
: READ-RECOVERIES-WITH-STATUS
   ( SQLITE:connection str str str ^ARENA:arena
     -- ^VEC:vector<recovery-record> )
   {: c path:str s:str op:str ar :}
   ar [type] recovery-id NEW-VECTOR {: ids :}
   c s" SELECT id FROM recovery_records WHERE status = ?1 ORDER BY id" [: s 1 SQLITE:BIND-TEXT
      begin SQLITE:STEP while ids PUSH-RECOVERY-ID repeat ;]
   SQLITE:WITH-STATEMENT
   c ids op path
   s" selected recovery disappeared while reading the journal" ar
   READ-EACH ;

: ELIGIBLE-QUERY ( -- str )
   s" SELECT recovery_records.id FROM recovery_records
      LEFT JOIN operations
         ON operations.id = recovery_records.operation_id
      LEFT JOIN plans ON plans.id = operations.plan_id
      WHERE recovery_records.status = 'completed'
         AND recovery_records.retained_at IS NOT NULL
         AND (operations.id IS NULL
            OR (operations.status = 'completed'
               AND plans.status = 'completed'))
      ORDER BY recovery_records.id" ;


\ ---- recoveries: writing ---------------------------------------------

: FORGET-QUERY ( -- str )
   s" SELECT recovery_records.status,
         recovery_records.retained_at IS NOT NULL
         AND (operations.id IS NULL
            OR (operations.status = 'completed'
               AND plans.status = 'completed'))
      FROM recovery_records
      LEFT JOIN operations
         ON operations.id = recovery_records.operation_id
      LEFT JOIN plans ON plans.id = operations.plan_id
      WHERE recovery_records.id = ?1" ;

\ Whether the row the statement steps to, if any, is completed and no
\ unfinished work needs its payload.
: FORGETTABLE-ROW
   ( SQLITE:statement str -- option<bool> SQLITE:statement )
   {: path:str :}
   SQLITE:STEP 0= if NO-FLAG swap exit then
   0 SQLITE:COL-TEXT s" read recovery status to forget" path
   DECODE-STATUS {: s :}
   1 SQLITE:COL-INT 0<> {: eligible:bool :}
   s DONE? eligible and OPTION:SOME swap ;

: FORGOTTEN ( bool SQLITE:connection recovery-id -- recovery-forget )
   {: done:bool c id :}
   done 0= if construct recovery-forget pending exit then
   c s" DELETE FROM recovery_records
      WHERE id = ?1 AND status = 'completed'" [: id RECOVERY-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   construct recovery-forget forgotten ;

: FORGET-IN
   ( SQLITE:connection recovery-id str -- recovery-forget )
   {: c id path:str :}
   c FORGET-QUERY
    [: id RECOVERY-ID>N 1 SQLITE:BIND-INT path FORGETTABLE-ROW ;]
   SQLITE:WITH-STATEMENT
   MATCH option
      none OF construct recovery-forget not-found ENDOF
      some OF c id FORGOTTEN ENDOF
   ;MATCH ;

public

\ Every unfinished recovery record, by id.
: PENDING-RECOVERIES
   ( journal ^ARENA:arena -- ^VEC:vector<recovery-record> )
   {: j ar :}
   j >CONNECTION j >PATH s" pending" s" read pending recovery" ar
   READ-RECOVERIES-WITH-STATUS ;

\ Every retained recovery record whose payload no unfinished work needs,
\ by id.
: COMPLETED-RECOVERIES
   ( journal ^ARENA:arena -- ^VEC:vector<recovery-record> )
   {: j ar :}
   ar [type] recovery-id NEW-VECTOR {: ids :}
   j >CONNECTION {: c :}
   c ELIGIBLE-QUERY
    [: begin SQLITE:STEP while ids PUSH-RECOVERY-ID repeat ;]
   SQLITE:WITH-STATEMENT
   c ids s" read completed recovery" j >PATH
   s" eligible recovery disappeared while reading the journal" ar
   READ-EACH ;

\ Forgets a completed recovery record once no unfinished work needs its
\ payload.
: FORGET-COMPLETED-RECOVERY ( journal recovery-id -- recovery-forget )
   {: j id :}
   j >CONNECTION {: c :}
   c [: c id j >PATH FORGET-IN ;] SQLITE:WITH-TRANSACTION ;

;package
