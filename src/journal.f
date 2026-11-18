\ journal.f - package JOURNAL: the sync journal, a SQLite file at schema 9
\ (rust src/journal.rs at schema 8), and the Dropbox account and local root
\ it is bound to. OPEN makes the file 0600 without following a link,
\ creates schema 9 in a new one and migrates schema 8 to it, each in one
\ transaction, from migrations/, whose texts this file lays in the program
\ as it loads; any version but 0, 8 and 9 is refused unchanged, and
\ OPEN-READ refuses any but 9. A SQLite failure is SQLITE's throw, passed
\ up unchanged. JOURNAL's own failures are logged once with the Rust
\ version's text, then thrown as its codes. E-FILE, E-DISK-FULL and E-ROOT
\ leave the host errno in FS:ERRNO, 0 where there is none; E-DISK-FULL is
\ E-FILE on ENOSPC.
\ A root binding is the root's inode, birth time and subvolume: btrfs gives
\ a subvolume a new device number at every mount, so the device is none
\ of it. A binding with no birth time is one a version-6 journal recorded;
\ an activation whose path and inode match it upgrades it in place.
\ A baseline, a plan, a conflict and a local observation are keyed by
\ the canonical path MODEL:FOLD gives the display path. Every stored
\ value is written and read by MODEL's JSON words; one MODEL cannot read
\ is logged with the record's path and its cause and thrown as E-JSON.
\ Each write to the file is one immediate transaction, and the remote
\ cursor and inventory are read in one deferred one.
\ A local scan is gathered in the connection's temporary tables, then
\ published as its difference in SQL: the local inventory and hash cache
\ lose each row the scan does not hold with the same value and gain each
\ row they lack, so an unchanged row keeps its rowid and an unchanged scan
\ writes nothing.
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
require src/lib/type/deftype.f
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

9 constant SCHEMA
5000 constant BUSY-MS
$180 constant MODE-OWNER            \ 0600
$1FF constant MODE-BITS
$7FFFFFFFFFFFFFFF constant INT-MAX  \ SQLite's largest integer
1000000000 constant NS-PER-S

16 TASK:+USERS ID-ROW u8


\ ---- stored rows ---------------------------------------------------

: COPIED ( ^u8 n ^ARENA:arena -- str )
   {: a:^ u ar :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   a dst u BYTE-COPY
   dst u >str ;

: PATH-BYTES ( MODEL:path -- ^u8 n ) MODEL:PATH>STR str> ;

: BYTES-PATH ( ^u8 n ^ARENA:arena -- MODEL:path ) COPIED MODEL:>PATH ;

: KEY-BYTES ( MODEL:key -- ^u8 n ) MODEL:KEY>STR str> ;

\ Runs the statement's row, reset for the next.
: RAN ( SQLITE:statement -- SQLITE:statement )
   SQLITE:STEP drop SQLITE:RESET ;

: INSERT-LOCAL ( -- ^u8 n )
   s" INSERT INTO local_observations(
         path, observation_json, canonical_path
      ) VALUES (?1, ?2, ?3)" ;

\ Binds INSERT-LOCAL's canonical_path, ?3.
: BIND-KEY
   ( SQLITE:statement MODEL:path ^ARENA:arena -- SQLITE:statement )
   MODEL:FOLD KEY-BYTES >str 3 SQLITE:BIND-BLOB ;


\ ---- migrations ----------------------------------------------------

\ Lays the file's length, then its bytes, in the word just created. Its
\ name precedes the create: a top-level string is itself laid at here.
: LAY ( ^u8 n -- )
   SOURCE-ROOT:RESOLVE drop {: at:^ u :}
   at u >str FS:FILE-SIZE {: size :}
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
s" migrations/0009.sql" create V9 LAY

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

\ Logs op's failure on path, caused by errno, else by code.
: LOG-FAILED ( str str n n -- )
   {: op:str path:str code errno :}
   op path FAILED-FOR
   errno 0= if code LOG:CODE+ else errno FS:ERRNO$ str> LOG:TEXT+ then
   LOG:;LINE errno FS:CAUSE! ;

: FILE-FAILED ( str str n n -- )
   dup FS:ENOSPC = {: full:bool :}
   LOG-FAILED full if E-DISK-FULL else E-FILE then throw ;

\ The sync root's failure, logged as FILE-FAILED logs one.
: ROOT-FAILED ( str str n n -- ) LOG-FAILED E-ROOT throw ;

: FILE-REFUSED ( str str str -- )
   {: op:str path:str why:str :}
   op path FAILED-FOR why STR+ LOG:;LINE
   0 FS:CAUSE! E-FILE throw ;

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
   >str [: INT-ROW ;] SQLITE:WITH-STATEMENT ;

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
   SQLITE:STEP drop 0 SQLITE:COL-TEXT >str s" delete" >str STR=CI swap ;

\ The daemon holds its connection for life, so each of its databases keeps
\ 64 KiB of pages, not SQLite's 2 MB; the OS page cache holds the rest.
\ The temporary database journals in memory, so a failed scan write
\ rolls back.
: CONFIGURE-WRITABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   c s" PRAGMA cache_size = -64" SQLITE:EXEC
   c s" PRAGMA temp.cache_size = -64" SQLITE:EXEC
   c s" PRAGMA temp.journal_mode = MEMORY" SQLITE:EXEC
   c s" PRAGMA foreign_keys = ON" SQLITE:EXEC
   c s" PRAGMA main.journal_mode = DELETE" >str [: DELETE-MODE? ;]
   SQLITE:WITH-STATEMENT 0= if
      s" set rollback journal mode" >str j >PATH
      s" SQLite did not enable DELETE journal mode" >str INVALID
   then
   c s" PRAGMA synchronous = FULL" SQLITE:EXEC
   c s" PRAGMA synchronous" QUERY-INT 2 <> if
      s" verify SQLite synchronization" >str j >PATH
      s" SQLite did not enable FULL synchronization" >str INVALID
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
   1 SQLITE:COL-TEXT >str {: o:str :}
   swap p 1 SQLITE:BIND-BLOB o 2 SQLITE:BIND-TEXT
   p str> ar BYTES-PATH ar BIND-KEY RAN swap ;

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
   c s" SELECT path, observation_json FROM local_observations_8"
   >str [: ar ROWS-COPIED ;] SQLITE:WITH-STATEMENT ;

: LOCALS-COPIED ( SQLITE:connection ^ARENA:arena -- )
   {: c ar :}
   c INSERT-LOCAL >str [: c ar ROWS-READ ;] SQLITE:WITH-STATEMENT ;

\ Migration 9: local observations keyed by canonical path, each row
\ copied with its path folded.
: MIGRATE-LOCAL-OBSERVATIONS ( SQLITE:connection -- )
   {: c :}
   c V9 RUN
   c [: LOCALS-COPIED ;] ARENA:WITH
   c s" DROP TABLE local_observations_8; PRAGMA user_version = 9"
   SQLITE:EXEC ;

\ Schema 9 in a new file: every migration in order.
: CREATE-SCHEMA ( SQLITE:connection -- )
   {: c :}
   c V1 RUN  c V2 RUN  c V3 RUN  c V4 RUN
   c CANONICAL-PATHS
   c V5 RUN
   c MIGRATE-BLOCKED-PLANS
   c V7 RUN  c V8 RUN
   c MIGRATE-LOCAL-OBSERVATIONS ;

: WRITABLE ( journal -- )
   {: j :}
   j >CONNECTION {: c :}
   BUSY-MS c SQLITE:BUSY-MS!
   [: j >PATH MODE-OWNER FS:CHMOD-MODE ;]
   s" restrict journal permissions" >str j >PATH FILE-IO
   c VERSION {: v :}
   v 0<> v 8 <> and v SCHEMA <> and if j >PATH v UNSUPPORTED then
   j CONFIGURE-WRITABLE
   v 0= if c [: c CREATE-SCHEMA ;] SQLITE:WITH-TRANSACTION then
   v 8 = if
      c [: c MIGRATE-LOCAL-OBSERVATIONS ;] SQLITE:WITH-TRANSACTION
   then ;

\ Deletes each completed plan no pending or unretained recovery record
\ holds, operations first: both deletes select the same plans.
: PRUNE ( SQLITE:connection -- n )
   {: c :}
   c s" DELETE FROM operations WHERE plan_id IN (
         SELECT plans.id FROM plans WHERE plans.status = 'completed'
         AND NOT EXISTS (
            SELECT 1 FROM operations JOIN recovery_records
               ON recovery_records.operation_id = operations.id
            WHERE operations.plan_id = plans.id
               AND (recovery_records.status = 'pending'
                  OR recovery_records.retained_at IS NULL)))"
   SQLITE:EXEC
   c s" DELETE FROM plans WHERE plans.status = 'completed'
      AND NOT EXISTS (
         SELECT 1 FROM operations JOIN recovery_records
            ON recovery_records.operation_id = operations.id
         WHERE operations.plan_id = plans.id
            AND (recovery_records.status = 'pending'
               OR recovery_records.retained_at IS NULL))"
   SQLITE:EXEC
   c SQLITE:CHANGES ;

public

\ Removes completed plans and their operations that no pending recovery
\ needs; completed recovery records stay. Answers the plans removed.
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

\ The journal at path, schema 9 created in a new or empty file or
\ migrated from 8, and its completed work pruned; another version is
\ refused, the file unchanged.
: OPEN ( str -- journal )
   {: path:str :}
   path OWNER-ONLY
   path str> SQLITE:OPEN path JOURNAL-MAKE [: READY ;] SET-UP ;

\ The schema-9 journal at path, never created or changed. Its log lines
\ name it `[Omabox journal]`, as Rust's status redacts the path.
: OPEN-READ ( str -- journal )
   {: path:str :}
   path SQLITE:OPEN-READ s" [Omabox journal]" >str JOURNAL-MAKE
   [: READABLE ;] SET-UP ;


private


\ ---- strings -------------------------------------------------------

: SAME? ( str str -- bool )
   {: a:str b:str :}
   a str> b str> STR= ;

: TEXT-COPY ( SQLITE:statement n ^ARENA:arena -- SQLITE:statement str )
   {: col ar :}
   col SQLITE:COL-TEXT ar COPIED ;

: BLOB-COPY ( SQLITE:statement n ^ARENA:arena -- SQLITE:statement str )
   {: col ar :}
   col SQLITE:COL-BLOB str> ar COPIED ;


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
      ON CONFLICT(singleton) DO NOTHING"
   >str [: account 1 SQLITE:BIND-TEXT
      namespace 2 SQLITE:BIND-TEXT
      root 3 SQLITE:BIND-TEXT
      SQLITE:STEP drop ;] SQLITE:WITH-STATEMENT ;

: BIND-WRITE
   ( SQLITE:connection dropbox-binding ^ARENA:arena
     -- dropbox-binding-write )
   {: c b ar :}
   c b INSERT-BINDING
   c SQLITE:CHANGES 1 = if construct dropbox-binding-write bound exit then
   ar c SELECT-BINDING >str [: EXISTING-ROW ;] SQLITE:WITH-STATEMENT
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
   ar j >CONNECTION SELECT-BINDING >str [: BINDING-ROW ;]
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

\ The identity of the root the descriptor names, path its canonical path.
: FROM-STATX ( str fd -- local-root-binding )
   {: path:str dir:fd :}
   path path dir IDENTITY FROM-STATX-FIELDS ;

\ The identity of the directory at the canonical path, opened without
\ following a link; any failure but a birth time's is E-ROOT.
: INSPECT ( str -- local-root-binding )
   {: path:str :}
   path path PATH-IDENTITY FROM-STATX-FIELDS ;

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
      some OF 8 BE-BYTES >str 5 SQLITE:BIND-BLOB ENDOF
   ;MATCH ;

: BIND-ROOT ( local-root-record SQLITE:statement -- SQLITE:statement )
   swap JOURNAL-LOCAL--ROOT--RECORD:UNMAKE {: b g :}
   b JOURNAL-LOCAL--ROOT--BINDING:UNMAKE {: p:str inode birth sub :}
   p 1 SQLITE:BIND-BLOB
   inode 0 BE-BYTES >str 2 SQLITE:BIND-BLOB
   birth BIND-BIRTH
   sub BIND-SUBVOLUME
   g 6 SQLITE:BIND-INT
   SQLITE:STEP drop ;

: WRITE-LOCAL-ROOT ( SQLITE:connection local-root-record -- )
   {: c r :}
   r c UPSERT-ROOT >str [: BIND-ROOT ;] SQLITE:WITH-STATEMENT ;

: DECODE-U64 ( ^u8 n str str -- n )
   {: a:^ u op:str path:str :}
   u 8 <> if
      op path s" filesystem identity has an invalid byte length" >str
      INVALID
   then
   a BE:U64@ ;

: BLOB-U64 ( SQLITE:statement n str str -- SQLITE:statement n )
   {: col op:str path:str :}
   col SQLITE:COL-BLOB str> op path DECODE-U64 ;

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
   ar j >PATH j >CONNECTION SELECT-ROOT >str [: ROOT-ROW ;]
   SQLITE:WITH-STATEMENT ;

private

: NO-ROOT ( -- option<local-root-binding> ) OPTION:NONE ;

: UNBORN
   ( journal ^ARENA:arena str n -- option<local-root-binding> )
   {: j ar path:str inode :}
   j ar LOCAL-ROOT-BINDING path inode STAND-IN? if NO-ROOT exit then
   path REFUSE-UNBORN ;

public

\ FROM-STATX's identity of the descriptor's directory, or none where its
\ filesystem reports no birth time and it stands in for the root.
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

\ One step of a cursor continuation. ensure-directory adds a missing
\ ancestor and never replaces a stored path or an unknown observation.
ENUM remote-inventory-change
   VARIANT upsert FIELD record MODEL:remote-record ;VARIANT
   VARIANT ensure-directory FIELD record MODEL:remote-record ;VARIANT
   VARIANT delete-subtree FIELD key MODEL:key ;VARIANT
;ENUM

private

1 TASK:+USERS ENCODER JSON:writer
BUF:HDR-BYTES TASK:+USERS ENCODED u8
256 constant ENCODED-CAP


\ ---- stored columns ------------------------------------------------

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

\ op could not read path's stored value, as code says.
: UNPROCESSED ( n str str -- )
   {: code op:str path:str :}
   op OPERATION s" could not process the record for `" LOG:TEXT+
   path STR+ s" `: " LOG:TEXT+ code LOG:CODE+ LOG:;LINE
   E-JSON throw ;

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
   s" cached content identity is not a Dropbox content hash" >str
   INVALID ;


\ ---- reading -------------------------------------------------------

\ A seed's typed drop, which types the read that replaces it.
: DROP-LOCAL ( MODEL:observation<MODEL:local> -- ) drop ;
: DROP-REMOTE ( MODEL:observation<MODEL:remote> -- ) drop ;
: DROP-FINGERPRINT ( MODEL:fingerprint -- ) drop ;
: DROP-HASH ( DROPBOX:hash -- ) drop ;
: DROP-BASELINE ( MODEL:baseline -- ) drop ;
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

: LOCAL-OBSERVATION-OF
   ( str str ^ARENA:arena -- MODEL:observation<MODEL:local> )
   {: json:str path:str ar :}
   MODEL-OBSERVATION:DIRECTORY
   [: DROP-LOCAL json ar MODEL:JSON>LOCAL-OBSERVATION ;]
   s" deserialize local observation" >str path DECODE ;

: REMOTE-OBSERVATION-OF
   ( str str ^ARENA:arena -- MODEL:observation<MODEL:remote> )
   {: json:str path:str ar :}
   MODEL-OBSERVATION:DIRECTORY
   [: DROP-REMOTE json ar MODEL:JSON>REMOTE-OBSERVATION ;]
   s" deserialize remote observation" >str path DECODE ;

: HASH-VALUE-OF
   ( str str ^ARENA:arena -- MODEL:fingerprint DROPBOX:hash )
   {: json:str path:str ar :}
   MODEL:NO-FINGERPRINT MODEL:NO-HASH
   [: DROP-HASH DROP-FINGERPRINT json ar MODEL:JSON>HASH-VALUE ;]
   s" deserialize local hash cache" >str path DECODE ;

: LOCAL-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement MODEL:local-record )
   {: ar :}
   0 SQLITE:COL-BLOB str> ar BYTES-PATH {: p:MODEL:path :}
   1 SQLITE:COL-TEXT >str p MODEL:PATH>STR ar LOCAL-OBSERVATION-OF
   {: o :}
   p o MODEL-LOCAL--RECORD:MAKE ;

\ The hash record stored at the path as the JSON.
: HASH-OF ( MODEL:path str ^ARENA:arena -- MODEL:hash-record )
   {: p:MODEL:path json:str ar :}
   json p MODEL:PATH>STR ar HASH-VALUE-OF {: f h :}
   h DROPBOX:HASH>STR str> DROPBOX:CONTENT-HASH? 0= if
      s" read local hash cache" >str p MODEL:PATH>STR NOT-CONTENT-HASH
   then
   p f h MODEL-HASH--RECORD:MAKE ;

: REMOTE-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement MODEL:remote-record )
   {: ar :}
   0 SQLITE:COL-BLOB str> ar BYTES-KEY {: k:MODEL:key :}
   1 SQLITE:COL-BLOB str> ar BYTES-PATH {: p:MODEL:path :}
   2 SQLITE:COL-TEXT >str p MODEL:PATH>STR ar REMOTE-OBSERVATION-OF
   {: o :}
   k p o MODEL-REMOTE--RECORD:MAKE ;

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
   >str [: begin SQLITE:STEP while ar LOCAL-ROW v VEC:PUSH ! repeat ;]
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
   >str [: begin SQLITE:STEP while ar HASH-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

: READ-REMOTE-OBSERVATIONS
   ( SQLITE:connection ^ARENA:arena
     -- ^VEC:vector<MODEL:remote-record> )
   {: c ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:remote-record VEC:NEW {: v :}
   c s" SELECT canonical_path, path, observation_json
      FROM remote_observations ORDER BY canonical_path"
   >str [: begin SQLITE:STEP while ar REMOTE-ROW v VEC:PUSH ! repeat ;]
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
   >str [: CURSOR-ROW ;] SQLITE:WITH-STATEMENT ;

\ The display path of the directory or restricted folder Dropbox holds
\ at the key; none for a file or nothing.
: REMOTE-DIRECTORY-AT
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:path> )
   {: j k ar :}
   j >CONNECTION
   s\" SELECT path FROM remote_observations
      WHERE canonical_path = ?1 AND observation_json IN
         ('\"Directory\"', '{\"Unknown\":\"Inaccessible\"}')"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB ar SPELLING-ROW ;]
   SQLITE:WITH-STATEMENT ;

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

public

\ A scan's rows lie in temp tables: scan_observations and scan_hashes,
\ which it publishes, and scan_cached, scan_jobs and scan_listed, which
\ hold reused hashes, files to hash and listed directories until visited.
STRUCTURE scan OPAQUE
   FIELD observe-insert SQLITE:statement
   FIELD hash-insert SQLITE:statement
   FIELD reuse-insert SQLITE:statement
   FIELD job-insert SQLITE:statement
   FIELD listed-insert SQLITE:statement
   FIELD cached-lookup SQLITE:statement
   FIELD journal journal
   FIELD writer ^JSON:writer
   FIELD arena ^ARENA:arena
;STRUCTURE

private

$2F constant SLASH

: LOCAL-INSERTED
   ( SQLITE:statement MODEL:local-record ^JSON:writer ^ARENA:arena
     -- SQLITE:statement )
   {: r w ar :}
   r MODEL-LOCAL--RECORD:UNMAKE {: p:MODEL:path o :}
   p PATH-BYTES >str 1 SQLITE:BIND-BLOB
   w [: o swap MODEL:LOCAL-OBSERVATION>JSON ;] ENCODE >str 2 SQLITE:BIND-TEXT
   p ar BIND-KEY RAN ;

: LOCALS-INSERTED
   ( SQLITE:statement ^VEC:vector<MODEL:local-record> ^JSON:writer
     ^ARENA:arena -- SQLITE:statement )
   {: v w ar :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ w ar LOCAL-INSERTED ar ARENA:RESET
   loop ;

: LOCAL-INSERTS
   ( SQLITE:statement ^VEC:vector<MODEL:local-record> ^JSON:writer
     -- SQLITE:statement )
   [: LOCALS-INSERTED ;] ARENA:WITH ;

\ Binds path ?1 and hash_json ?2. A hash that is not Dropbox's is never
\ cached.
: HASH-INSERTED
   ( SQLITE:statement MODEL:hash-record ^JSON:writer -- SQLITE:statement )
   {: r w :}
   r MODEL-HASH--RECORD:UNMAKE {: p:MODEL:path f h :}
   h DROPBOX:HASH>STR str> DROPBOX:CONTENT-HASH? 0= if
      s" publish local hash cache" >str p MODEL:PATH>STR
      NOT-CONTENT-HASH
   then
   p PATH-BYTES >str 1 SQLITE:BIND-BLOB
   w [: r swap MODEL:HASH-VALUE>JSON ;] ENCODE >str 2 SQLITE:BIND-TEXT
   RAN ;

: JOB-INSERTED
   ( SQLITE:statement str MODEL:fingerprint -- SQLITE:statement )
   {: p:str f :}
   f MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   p 1 SQLITE:BIND-BLOB
   i 2 SQLITE:BIND-INT  s 3 SQLITE:BIND-INT
   ms 4 SQLITE:BIND-INT  mn 5 SQLITE:BIND-INT
   cs 6 SQLITE:BIND-INT  cn 7 SQLITE:BIND-INT RAN ;

: LISTED-INSERTED
   ( SQLITE:statement str MODEL:stat -- SQLITE:statement )
   {: p:str st :}
   st MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :}
   p 1 SQLITE:BIND-BLOB
   d 2 SQLITE:BIND-INT  i 3 SQLITE:BIND-INT
   m 4 SQLITE:BIND-INT  s 5 SQLITE:BIND-INT
   ms 6 SQLITE:BIND-INT  mn 7 SQLITE:BIND-INT
   cs 8 SQLITE:BIND-INT  cn 9 SQLITE:BIND-INT RAN ;

: JOB-ROW
   ( SQLITE:statement ^ARENA:arena
     -- SQLITE:statement str MODEL:fingerprint )
   {: ar :}
   0 ar BLOB-COPY {: p:str :}
   1 SQLITE:COL-INT {: i :}  2 SQLITE:COL-INT {: s :}
   3 SQLITE:COL-INT {: ms :}  4 SQLITE:COL-INT {: mn :}
   5 SQLITE:COL-INT {: cs :}  6 SQLITE:COL-INT {: cn :}
   p i s ms mn cs cn MODEL-FINGERPRINT:MAKE ;

: LISTED-ROW
   ( SQLITE:statement ^ARENA:arena -- SQLITE:statement str MODEL:stat )
   {: ar :}
   0 ar BLOB-COPY {: p:str :}
   1 SQLITE:COL-INT {: d :}  2 SQLITE:COL-INT {: i :}
   3 SQLITE:COL-INT {: m :}  4 SQLITE:COL-INT {: s :}
   5 SQLITE:COL-INT {: ms :}  6 SQLITE:COL-INT {: mn :}
   7 SQLITE:COL-INT {: cs :}  8 SQLITE:COL-INT {: cn :}
   p d i m s ms mn cs cn MODEL-STAT:MAKE ;

: NO-HASH-RECORD ( -- MODEL:hash-record )
   s" " >str MODEL:>PATH MODEL:NO-FINGERPRINT MODEL:NO-HASH
   MODEL-HASH--RECORD:MAKE ;

\ The row is copied before the statement is reset, so a record that
\ does not decode leaves the statement ready for the next lookup.
: LOOKED-UP
   ( SQLITE:statement str ^ARENA:arena
     -- SQLITE:statement MODEL:hash-record bool )
   {: p:str ar :}
   p 1 SQLITE:BIND-BLOB
   SQLITE:STEP 0= if SQLITE:RESET NO-HASH-RECORD false exit then
   0 ar PATH-COPY {: q:MODEL:path :}
   1 ar TEXT-COPY {: json:str :}
   SQLITE:RESET q json ar HASH-OF true ;

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

: OBSERVE-SCAN ( -- ^u8 n )
   s" INSERT OR REPLACE INTO temp.scan_observations(
         path, observation_json, canonical_path
      ) VALUES (?1, ?2, ?3)" ;

: HASH-SCAN ( -- ^u8 n )
   s" INSERT OR REPLACE INTO temp.scan_hashes(path, hash_json)
      VALUES (?1, ?2)" ;

: REUSE-SCAN ( -- ^u8 n )
   s" INSERT OR REPLACE INTO temp.scan_cached(path, hash_json)
      VALUES (?1, ?2)" ;

: JOB-SCAN ( -- ^u8 n )
   s" INSERT OR REPLACE INTO temp.scan_jobs(
         path, inode, size, modified_seconds, modified_nanoseconds,
         changed_seconds, changed_nanoseconds
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)" ;

: LISTED-SCAN ( -- ^u8 n )
   s" INSERT OR REPLACE INTO temp.scan_listed(
         path, dev, inode, mode, size, modified_seconds,
         modified_nanoseconds, changed_seconds, changed_nanoseconds
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)" ;

: CACHED-SCAN ( -- ^u8 n )
   s" SELECT cache.path, cache.hash_json
      FROM local_hash_cache AS cache
      JOIN local_root_binding AS root
         ON root.singleton = 1 AND cache.root_generation = root.generation
      WHERE cache.path = ?1" ;

: SCAN-TABLES ( -- ^u8 n )
   s" CREATE TABLE IF NOT EXISTS temp.scan_observations(
         path BLOB PRIMARY KEY,
         observation_json TEXT NOT NULL,
         canonical_path BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS temp.scan_hashes(
         path BLOB PRIMARY KEY,
         hash_json TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS temp.scan_cached(
         path BLOB PRIMARY KEY,
         hash_json TEXT NOT NULL
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
      CREATE TABLE IF NOT EXISTS temp.scan_listed(
         path BLOB PRIMARY KEY,
         dev INTEGER NOT NULL,
         inode INTEGER NOT NULL,
         mode INTEGER NOT NULL,
         size INTEGER NOT NULL,
         modified_seconds INTEGER NOT NULL,
         modified_nanoseconds INTEGER NOT NULL,
         changed_seconds INTEGER NOT NULL,
         changed_nanoseconds INTEGER NOT NULL
      );
      DELETE FROM temp.scan_observations;
      DELETE FROM temp.scan_hashes;
      DELETE FROM temp.scan_cached;
      DELETE FROM temp.scan_jobs;
      DELETE FROM temp.scan_listed;" ;

: SCANNING
   ( R SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement SQLITE:statement journal
     [ R scan -- S scan ] ^JSON:writer ^ARENA:arena
     -- S SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement SQLITE:statement )
   {: j body w ar :}
   j w ar SCAN-MAKE body execute SCAN-UNMAKE drop drop drop ;

: SCAN-ENCODED
   ( R SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement SQLITE:statement journal
     [ R scan -- S scan ] ^JSON:writer
     -- S SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement SQLITE:statement )
   [: SCANNING ;] ARENA:WITH ;

: SCAN-PREPARED
   ( R SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement SQLITE:statement journal
     [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement SQLITE:statement )
   [: SCAN-ENCODED ;] ENCODING ;

: LOOKUP-PREPARED
   ( R SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement journal [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement SQLITE:statement )
   {: j body :}
   j >CONNECTION CACHED-SCAN >str [: j body SCAN-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

: LISTED-PREPARED
   ( R SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement journal [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement SQLITE:statement
     SQLITE:statement )
   {: j body :}
   j >CONNECTION LISTED-SCAN >str [: j body LOOKUP-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

: JOB-PREPARED
   ( R SQLITE:statement SQLITE:statement SQLITE:statement journal
     [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement SQLITE:statement )
   {: j body :}
   j >CONNECTION JOB-SCAN >str [: j body LISTED-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

: REUSE-PREPARED
   ( R SQLITE:statement SQLITE:statement journal [ R scan -- S scan ]
     -- S SQLITE:statement SQLITE:statement )
   {: j body :}
   j >CONNECTION REUSE-SCAN >str [: j body JOB-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

: HASH-PREPARED
   ( R SQLITE:statement journal [ R scan -- S scan ]
     -- S SQLITE:statement )
   {: j body :}
   j >CONNECTION HASH-SCAN >str [: j body REUSE-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

: SCAN-JOURNAL ( scan -- scan journal )
   SCAN-UNMAKE {: j w ar :}
   j w ar SCAN-MAKE j ;

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
   c empty str> SQLITE:EXEC ;

\ The statement waits on the return stack while body runs.
: REUSE-VISITED
   ( R scan SQLITE:statement ^ARENA:arena
     [ R scan MODEL:hash-record -- R scan ] -- R scan SQLITE:statement )
   {: ar body :}
   ar HASH-ROW {: r :}
   >r r body execute r> ;

: JOB-VISITED
   ( R scan SQLITE:statement ^ARENA:arena
     [ R scan str MODEL:fingerprint -- R scan ]
     -- R scan SQLITE:statement )
   {: ar body :}
   ar JOB-ROW {: p:str f :}
   >r p f body execute r> ;

: LISTED-VISITED
   ( R scan SQLITE:statement ^ARENA:arena
     [ R scan str MODEL:stat -- R scan ] -- R scan SQLITE:statement )
   {: ar body :}
   ar LISTED-ROW {: p:str st :}
   >r p st body execute r> ;

\ The path then one byte.
: SUFFIXED ( str n ^ARENA:arena -- str )
   {: p:str b ar :}
   p str> {: a:^ u :}
   ar u 1+ ARENA:ALLOC drop {: d:^ :}
   a d u BYTE-COPY
   b d u + c!
   d u 1+ >str ;

\ ?1 is the path and [?2, ?3) the byte range of the paths beneath it:
\ the path then "/", to the path then "0", the byte after "/".
: SUBTREE-RAN ( SQLITE:connection str str str ^u8 n -- )
   {: c p:str lo:str hi:str sql:^ u :}
   c sql u >str [:
      p 1 SQLITE:BIND-BLOB lo 2 SQLITE:BIND-BLOB hi 3 SQLITE:BIND-BLOB
      RAN
   ;] SQLITE:WITH-STATEMENT ;

: DISCARDED ( SQLITE:connection str ^ARENA:arena -- )
   {: c p:str ar :}
   p SLASH ar SUFFIXED {: lo:str :}
   p SLASH 1+ ar SUFFIXED {: hi:str :}
   c p lo hi s" INSERT OR REPLACE INTO temp.scan_hashes(path, hash_json)
      SELECT path, hash_json FROM temp.scan_cached
      WHERE path = ?1 OR (path >= ?2 AND path < ?3)" SUBTREE-RAN
   c p lo hi s" DELETE FROM temp.scan_cached
      WHERE path = ?1 OR (path >= ?2 AND path < ?3)" SUBTREE-RAN
   c p lo hi s" DELETE FROM temp.scan_observations
      WHERE path = ?1 OR (path >= ?2 AND path < ?3)" SUBTREE-RAN
   c p lo hi s" DELETE FROM temp.scan_jobs
      WHERE path = ?1 OR (path >= ?2 AND path < ?3)" SUBTREE-RAN
   c p lo hi s" DELETE FROM temp.scan_listed
      WHERE path = ?1 OR (path >= ?2 AND path < ?3)" SUBTREE-RAN ;

: OBSERVATIONS-DIFFERENCE ( -- ^u8 n )
   s" DELETE FROM local_observations WHERE NOT EXISTS (
         SELECT 1 FROM temp.scan_observations AS s
         WHERE s.path = local_observations.path
            AND s.observation_json = local_observations.observation_json
      );
      INSERT INTO local_observations(path, observation_json, canonical_path)
         SELECT s.path, s.observation_json, s.canonical_path
         FROM temp.scan_observations AS s
         WHERE NOT EXISTS (
            SELECT 1 FROM local_observations AS o WHERE o.path = s.path
         );" ;

\ ?1 is the active generation; a row of any other is deleted.
: STALE-HASHES ( -- ^u8 n )
   s" DELETE FROM local_hash_cache
      WHERE root_generation != ?1 OR NOT EXISTS (
         SELECT 1 FROM temp.scan_hashes AS s
         WHERE s.path = local_hash_cache.path
            AND s.hash_json = local_hash_cache.hash_json
      )" ;

: MISSING-HASHES ( -- ^u8 n )
   s" INSERT INTO local_hash_cache(root_generation, path, hash_json)
      SELECT ?1, s.path, s.hash_json FROM temp.scan_hashes AS s
      WHERE NOT EXISTS (
         SELECT 1 FROM local_hash_cache AS c
         WHERE c.root_generation = ?1 AND c.path = s.path
      )" ;

\ g, the generation, was read as an SQLite integer, so it binds as one.
: AT-GENERATION ( SQLITE:connection n ^u8 n -- )
   {: c g a:^ u:n :}
   c a u >str [: g 1 SQLITE:BIND-INT RAN ;] SQLITE:WITH-STATEMENT ;

: DIFFERENCE-WRITTEN ( SQLITE:connection n -- )
   {: c g :}
   c OBSERVATIONS-DIFFERENCE SQLITE:EXEC
   c g STALE-HASHES AT-GENERATION
   c g MISSING-HASHES AT-GENERATION ;

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

public

\ Runs body over a scan that starts empty, to publish with PUBLISH-SCAN;
\ body hands the scan back.
: WITH-SCAN ( R journal [ R scan -- S scan ] -- S )
   {: j body :}
   j >CONNECTION SCAN-TABLES SQLITE:EXEC
   j >CONNECTION OBSERVE-SCAN >str [: j body HASH-PREPARED ;]
   SQLITE:WITH-STATEMENT ;

\ Records the observation in the scan, replacing one at its path.
: SCAN-OBSERVE ( scan MODEL:local-record -- scan )
   {: r :}
   SCAN-UNMAKE {: j w ar :}
   >r >r >r >r >r
   r w ar LOCAL-INSERTED ar ARENA:RESET
   r> r> r> r> r>
   j w ar SCAN-MAKE ;

\ Records the hash in the scan, replacing one at its path.
: SCAN-HASH ( scan MODEL:hash-record -- scan )
   {: r :}
   SCAN-UNMAKE {: j w ar :}
   >r >r >r >r
   r w HASH-INSERTED
   r> r> r> r>
   j w ar SCAN-MAKE ;

\ Records a cached hash the walk reused, replacing one at its path.
: SCAN-REUSE ( scan MODEL:hash-record -- scan )
   {: r :}
   SCAN-UNMAKE {: j w ar :}
   >r >r >r  r w HASH-INSERTED  r> r> r>
   j w ar SCAN-MAKE ;

\ Records a file no cached hash covers, replacing one at its path.
: SCAN-JOB ( scan str MODEL:fingerprint -- scan )
   {: p:str f :}
   SCAN-UNMAKE {: j w ar :}
   >r >r  p f JOB-INSERTED  r> r>
   j w ar SCAN-MAKE ;

\ Records a directory the walk listed, with its stat before the listing,
\ replacing one at its path.
: SCAN-LISTED ( scan str MODEL:stat -- scan )
   {: p:str st :}
   SCAN-UNMAKE {: j w ar :}
   >r  p st LISTED-INSERTED  r>
   j w ar SCAN-MAKE ;

\ Runs body on each reused hash in path byte order, then forgets them.
\ The record is valid only during body, which may write the scan only
\ through SCAN-OBSERVE and SCAN-HASH. Body reads no journal table.
: EACH-SCAN-REUSE
   ( R scan [ R scan MODEL:hash-record -- R scan ] -- R scan )
   {: body :}
   [: body REUSE-VISITED ;]
   s" SELECT path, hash_json FROM temp.scan_cached ORDER BY path" >str
   s" DELETE FROM temp.scan_cached" >str EACH-ROW ;

\ Runs body on each file to hash in path byte order, then forgets them.
: EACH-SCAN-JOB
   ( R scan [ R scan str MODEL:fingerprint -- R scan ] -- R scan )
   {: body :}
   [: body JOB-VISITED ;]
   s" SELECT path, inode, size, modified_seconds, modified_nanoseconds,
         changed_seconds, changed_nanoseconds
      FROM temp.scan_jobs ORDER BY path" >str
   s" DELETE FROM temp.scan_jobs" >str EACH-ROW ;

\ Runs body on each listed directory in path byte order, then forgets them.
: EACH-SCAN-LISTED
   ( R scan [ R scan str MODEL:stat -- R scan ] -- R scan )
   {: body :}
   [: body LISTED-VISITED ;]
   s" SELECT path, dev, inode, mode, size, modified_seconds,
         modified_nanoseconds, changed_seconds, changed_nanoseconds
      FROM temp.scan_listed ORDER BY path" >str
   s" DELETE FROM temp.scan_listed" >str EACH-ROW ;

\ Forgets the path, never the root "", and every path beneath it. A
\ cached hash among them matched its file's fingerprint when the walk
\ took it, so it is kept as a published hash: dropping it would rehash
\ an untouched subtree on every later pass.
: SCAN-DISCARD ( scan str -- scan )
   {: p:str :}
   SCAN-UNMAKE {: j w ar :}
   j >CONNECTION p ar DISCARDED ar ARENA:RESET
   j w ar SCAN-MAKE ;

\ The hash the active root's cache holds for the path, decoded into ar;
\ false, with an empty record, when it holds none.
: CACHED-HASH ( scan str ^ARENA:arena -- scan MODEL:hash-record bool )
   {: p:str ar :}
   SCAN-UNMAKE {: j w sa :}
   p ar LOOKED-UP {: r found :}
   j w sa SCAN-MAKE r found ;

\ Makes the local inventory and the active root's hash cache the scan's
\ in one transaction; false, nothing written, when binding is no longer
\ the active root.
: PUBLISH-SCAN ( scan local-root-binding -- scan bool )
   {: b :}
   SCAN-JOURNAL {: j :}
   j >CONNECTION [: j b [: BOUND-DIFFERENCE ;] ARENA:WITH ;]
   SQLITE:WITH-TRANSACTION ;

\ Publishes the observations and hashes as one scan; false, nothing
\ written, when binding is no longer the active root.
: PUBLISH-LOCAL-SCAN
   ( journal local-root-binding ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> -- bool )
   {: j b obs hashes :}
   j [:
      obs VEC:COUNT 0 ?do obs i VEC:AT @ SCAN-OBSERVE loop
      hashes VEC:COUNT 0 ?do hashes i VEC:AT @ SCAN-HASH loop
      b PUBLISH-SCAN swap
   ;] WITH-SCAN ;

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
   p PATH-BYTES >str 1 SQLITE:BIND-BLOB
   w [: o swap MODEL:REMOTE-OBSERVATION>JSON ;] ENCODE >str 2 SQLITE:BIND-TEXT
   k KEY-BYTES >str 3 SQLITE:BIND-BLOB ;

: REMOTE-INSERTS
   ( SQLITE:statement ^VEC:vector<MODEL:remote-record> ^JSON:writer
     -- SQLITE:statement )
   {: v w :}
   v VEC:COUNT 0 ?do v i VEC:AT @ w BIND-REMOTE RAN loop ;

: PUBLISH-CURSOR ( SQLITE:connection DROPBOX:cursor -- )
   {: c cur:DROPBOX:cursor :}
   c s" INSERT INTO remote_inventory(singleton, cursor) VALUES (1, ?1)
      ON CONFLICT(singleton) DO UPDATE SET cursor = excluded.cursor"
   >str [: cur DROPBOX:CURSOR>STR 1 SQLITE:BIND-TEXT RAN ;]
   SQLITE:WITH-STATEMENT ;

: REMOTE-WRITTEN
   ( SQLITE:connection DROPBOX:cursor
     ^VEC:vector<MODEL:remote-record> ^JSON:writer -- )
   {: c cur:DROPBOX:cursor v w :}
   c s" DELETE FROM remote_observations" SQLITE:EXEC
   c INSERT-REMOTE >str [: v w REMOTE-INSERTS ;] SQLITE:WITH-STATEMENT
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
   c sql u >str [: r w BIND-REMOTE SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: SUBTREE-DELETED ( SQLITE:connection MODEL:key ^ARENA:arena -- )
   {: c k:MODEL:key ar :}
   c s" DELETE FROM remote_observations WHERE canonical_path = ?1"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   k ar MODEL:SUBTREE-RANGE {: lo:str hi:str :}
   c DELETE-REMOTE-DESCENDANTS
   >str [: lo 1 SQLITE:BIND-BLOB hi 2 SQLITE:BIND-BLOB
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

: DECODE-BASELINE ( str MODEL:path ^ARENA:arena -- MODEL:baseline )
   {: json:str path ar :}
   MODEL-BASELINE:ABSENT
   [: DROP-BASELINE json ar MODEL:JSON>BASELINE ;]
   s" deserialize baseline" >str path MODEL:PATH>STR DECODE ;

: OPERATION-AS
   ( str MODEL:path ^ARENA:arena str -- MODEL:operation )
   {: json:str path ar op:str :}
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY
   [: DROP-OPERATION json ar MODEL:JSON>OPERATION ;]
   op path MODEL:PATH>STR DECODE ;

: DECODE-OPERATION ( str MODEL:path ^ARENA:arena -- MODEL:operation )
   s" deserialize operation" >str OPERATION-AS ;

: DECODE-BLOCKAGE ( str MODEL:path ^ARENA:arena -- MODEL:blockage )
   {: json:str path ar :}
   MODEL-BLOCKAGE:STAGE-OCCUPIED
   [: DROP-BLOCKAGE json ar MODEL:JSON>BLOCKAGE ;]
   s" deserialize block reason" >str path MODEL:PATH>STR DECODE ;

: ENCODE-BASELINE ( MODEL:baseline ^JSON:writer -- ^u8 n )
   {: b w :}
   w [: b swap MODEL:BASELINE>JSON ;] ENCODE ;

: ENCODE-OPERATION ( MODEL:operation ^JSON:writer -- ^u8 n )
   {: o w :}
   w [: o swap MODEL:OPERATION>JSON ;] ENCODE ;

: ENCODE-BLOCKAGE ( MODEL:blockage ^JSON:writer -- ^u8 n )
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
   col SQLITE:COL-TEXT >str OPTION:SOME ;

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

: BASELINE-ROW
   ( SQLITE:statement MODEL:path ^ARENA:arena
     -- option<MODEL:baseline> SQLITE:statement )
   {: path ar :}
   SQLITE:STEP 0= if NO-BASELINE swap exit then
   0 SQLITE:COL-TEXT >str path ar DECODE-BASELINE {: b :}
   b ABSENT? if NO-BASELINE swap exit then
   b OPTION:SOME swap ;

: PATH-ROW
   ( SQLITE:statement ^VEC:vector<MODEL:path> ^ARENA:arena
     -- SQLITE:statement )
   {: paths ar :}
   0 ar PATH-COPY paths VEC:PUSH ! ;

: RECORD-ROW
   ( SQLITE:statement ^VEC:vector<MODEL:baseline-record> ^ARENA:arena
     -- SQLITE:statement )
   {: records ar :}
   0 ar KEY-COPY {: k :}
   1 ar PATH-COPY {: path :}
   2 SQLITE:COL-TEXT >str path ar DECODE-BASELINE {: b :}
   b ABSENT? if exit then
   k path b MODEL-BASELINE--RECORD:MAKE records VEC:PUSH ! ;

public

\ The common baseline recorded for the display path; absent is none.
: BASELINE ( journal MODEL:path ^ARENA:arena -- option<MODEL:baseline> )
   {: j path ar :}
   path ar MODEL:FOLD {: k :}
   j >CONNECTION
   s" SELECT baseline_json FROM baselines WHERE canonical_path = ?1"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB path ar BASELINE-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Every path with a baseline, in the order of its bytes.
: BASELINE-PATHS ( journal ^ARENA:arena -- ^VEC:vector<MODEL:path> )
   {: j ar :}
   ar [type] MODEL:path NEW-VECTOR {: paths :}
   j >CONNECTION
   s\" SELECT path FROM baselines WHERE baseline_json != '\"Absent\"'
      ORDER BY path"
   >str [: begin SQLITE:STEP while paths ar PATH-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   paths ;

\ Every baseline, in the order of its canonical path's bytes.
: BASELINES
   ( journal ^ARENA:arena -- ^VEC:vector<MODEL:baseline-record> )
   {: j ar :}
   ar [type] MODEL:baseline-record NEW-VECTOR {: records :}
   j >CONNECTION
   s\" SELECT canonical_path, path, baseline_json FROM baselines
      WHERE baseline_json != '\"Absent\"' ORDER BY canonical_path"
   >str [: begin SQLITE:STEP while records ar RECORD-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   records ;

\ The display path the canonical path's baseline was recorded under.
: BASELINE-SPELLING
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:path> )
   {: j k ar :}
   j >CONNECTION
   s\" SELECT path FROM baselines
      WHERE canonical_path = ?1 AND baseline_json != '\"Absent\"'"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB ar SPELLING-ROW ;]
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
   2 SQLITE:COL-INT 0= if v false exit then
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

public

\ The records of each canonical path several local rows hold, by key then
\ path bytes, to the visitor inside the statement until it answers true.
: EACH-LOCAL-COLLISION
   ( journal ^ARENA:arena [ ^VEC:vector<MODEL:local-record> -- bool ]
     -- )
   {: j ar visit :}
   j >CONNECTION
   s" SELECT o.path, o.observation_json, o.path = c.last
      FROM (SELECT canonical_path, max(path) AS last
            FROM local_observations
            GROUP BY canonical_path HAVING count(*) > 1) AS c
      JOIN local_observations AS o
         ON o.canonical_path = c.canonical_path
      ORDER BY o.canonical_path, o.path"
   >str [: ar visit COLLISION-ROWS ;] SQLITE:WITH-STATEMENT ;

: LOCAL-COUNT ( journal -- n )
   >CONNECTION s" SELECT count(*) FROM local_observations" QUERY-INT ;

\ The local record with the least path at the canonical path.
: LOCAL-AT
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:local-record> )
   {: j k ar :}
   j >CONNECTION
   s" SELECT path, observation_json FROM local_observations
      WHERE canonical_path = ?1 ORDER BY path LIMIT 1"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB ar LOCAL-AT-ROW ;]
   SQLITE:WITH-STATEMENT ;

private


\ ---- a case-collision rename ---------------------------------------

: FORGET ( SQLITE:connection MODEL:key -- )
   {: c k :}
   c s" DELETE FROM baselines WHERE canonical_path = ?1"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
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
         OR (canonical_path >= ?2 AND canonical_path < ?3)"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB
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
   k KEY-BYTES nip 0= if
      s" invalidate case-collision history" >str
      renamed MODEL:PATH>STR
      s" case-collision path is empty" >str INVALID
   then
   j >CONNECTION {: c :}
   c [: c renamed k exists ar FORGET-ALL-STALE ;]
   SQLITE:WITH-TRANSACTION ;

private


\ ---- plans ---------------------------------------------------------

: PLAN-QUERY ( -- ^u8 n )
   s" SELECT plans.id, plans.path, plans.status, plans.blocked_json,
         plans.retry_at, operations.id, operations.ordinal,
         operations.operation_json, operations.status
      FROM plans JOIN operations ON operations.plan_id = plans.id
      WHERE plans.status = ?1 ORDER BY plans.id, operations.ordinal" ;

: PATH-INVALID ( str MODEL:path ^u8 n -- )
   {: op:str path d:^ du :}
   op path MODEL:PATH>STR d du >str INVALID ;

: DECODE-STATUS ( ^u8 n str str -- record-status )
   {: s:^ u op:str path:str :}
   s u s" pending" STR= if construct record-status pending exit then
   s u s" completed" STR= if construct record-status completed exit then
   op path s" record has an unrecognized status" >str INVALID ;

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

: KNOWN? ( ^u8 n -- bool )
   {: s:^ u :}
   s u s" pending" STR= s u s" completed" STR= or
   s u s" blocked" STR= or ;

\ A plan's status from its status, blocked_json and retry_at columns.
: DECODE-PLAN-STATUS
   ( ^u8 n option<str> option<n> str MODEL:path ^ARENA:arena
     -- plan-status )
   {: s:^ u json retry op:str path ar :}
   json NO-JSON? retry NO-INT? and {: clear:bool :}
   s u s" pending" STR= clear and if
      construct plan-status pending exit
   then
   s u s" completed" STR= clear and if
      construct plan-status completed exit
   then
   s u s" blocked" STR= if
      json retry op path ar BLOCKED-STATUS exit
   then
   s u KNOWN? if op path DISAGREES then
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
   at 2 + SQLITE:COL-TEXT >str path ar DECODE-OPERATION {: o :}
   at 3 + SQLITE:COL-TEXT s" read operation status" >str
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

: NEW-PLAN-ROW
   ( SQLITE:statement ^VEC:vector<plan-record> plan-id MODEL:path
     planned-operation str ^ARENA:arena -- SQLITE:statement )
   {: plans id path planned op:str ar :}
   ar [type] planned-operation NEW-VECTOR {: ops :}
   planned ops VEC:PUSH !
   2 SQLITE:COL-TEXT {: s:^ u :}
   3 TEXT? {: json :}
   4 INT? {: retry :}
   s u json retry op path ar DECODE-PLAN-STATUS {: status :}
   id path ops status JOURNAL-PLAN--RECORD:MAKE plans VEC:PUSH ! ;

\ A row of PLAN-QUERY: its operation joins the last plan when the row is
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

\ Every plan whose status is the text, each one's operations in order.
: READ-PLANS-WITH-STATUS
   ( SQLITE:connection ^u8 n str ^ARENA:arena
     -- ^VEC:vector<plan-record> )
   {: c s:^ su op:str ar :}
   ar [type] plan-record NEW-VECTOR {: plans :}
   c PLAN-QUERY
   >str [: s su >str 1 SQLITE:BIND-TEXT
      begin SQLITE:STEP while plans op ar PLAN-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   plans ;

: STATE-ROW
   ( SQLITE:statement str ^ARENA:arena
     -- option<plan-state> SQLITE:statement )
   {: op:str ar :}
   SQLITE:STEP 0= if NO-STATE swap exit then
   0 ar PATH-COPY {: path :}
   1 SQLITE:COL-TEXT {: s:^ u :}
   2 TEXT? {: json :}
   3 INT? {: retry :}
   s u json retry op path ar DECODE-PLAN-STATUS {: status :}
   path status PLAN-STATE-MAKE OPTION:SOME swap ;

: READ-PLAN-STATE
   ( SQLITE:connection plan-id str ^ARENA:arena -- option<plan-state> )
   {: c id op:str ar :}
   c s" SELECT path, status, blocked_json, retry_at FROM plans
      WHERE id = ?1"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT op ar STATE-ROW ;]
   SQLITE:WITH-STATEMENT ;

: OPERATION-ROW
   ( SQLITE:statement ^VEC:vector<planned-operation> MODEL:path
     ^ARENA:arena -- SQLITE:statement )
   {: ops path ar :}
   0 s" read operation ordinal" >str path ar PLANNED ops VEC:PUSH ! ;

: PLAN-OPERATIONS
   ( SQLITE:connection plan-id MODEL:path ^ARENA:arena
     -- ^VEC:vector<planned-operation> )
   {: c id path ar :}
   ar [type] planned-operation NEW-VECTOR {: ops :}
   c s" SELECT id, ordinal, operation_json, status
      FROM operations WHERE plan_id = ?1 ORDER BY ordinal"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT
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
   c id s" read plan" >str ar READ-PLAN-STATE MATCH option
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
      WHERE canonical_path = ?1 AND status IN ('pending', 'blocked')"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB LIVE-ROW ;]
   SQLITE:WITH-STATEMENT ;

: UPSERT-BASELINE ( -- ^u8 n )
   s" INSERT INTO baselines(path, baseline_json, canonical_path)
      VALUES (?1, ?2, ?3)
      ON CONFLICT(canonical_path) DO UPDATE SET
         path = excluded.path,
         baseline_json = excluded.baseline_json
      WHERE baselines.path != excluded.path
         OR baselines.baseline_json != excluded.baseline_json" ;

\ An absent baseline removes the path's row; an unchanged one writes
\ nothing.
: WRITE-BASELINE
   ( SQLITE:connection MODEL:path MODEL:baseline ^ARENA:arena
     ^JSON:writer -- )
   {: c path b ar w :}
   path ar MODEL:FOLD {: k :}
   b ABSENT? if c k FORGET exit then
   c UPSERT-BASELINE
   >str [: path PATH-BYTES >str 1 SQLITE:BIND-BLOB
      b w ENCODE-BASELINE >str 2 SQLITE:BIND-TEXT
      k KEY-BYTES >str 3 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: RETIRE-CONFLICTS ( SQLITE:connection MODEL:key -- )
   {: c k :}
   c s" DELETE FROM conflicts WHERE canonical_path = ?1"
   >str [: k KEY-BYTES >str 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: AGREED
   ( SQLITE:connection MODEL:path MODEL:key MODEL:baseline ^ARENA:arena
     ^JSON:writer -- noop-write )
   {: c path k b ar w :}
   c path b ar w WRITE-BASELINE
   c k RETIRE-CONFLICTS
   construct noop-write recorded ;

: RECORD-NOOP-IN
   ( SQLITE:connection MODEL:path MODEL:baseline ^ARENA:arena
     ^JSON:writer -- noop-write )
   {: c path b ar w :}
   path ar MODEL:FOLD {: k :}
   c k LIVE-PLAN MATCH option
      some OF construct noop-write live-plan ENDOF
      none OF c path k b ar w AGREED ENDOF
   ;MATCH ;

\ The plan read inside the transaction that wrote or found it; none is
\ op's invalid state.
: HELD-PLAN ( option<plan-record> str MODEL:path ^u8 n -- plan-record )
   {: op:str path d:^ du :}
   MATCH option
      some OF ENDOF
      none OF op path d du PATH-INVALID ENDOF
   ;MATCH ;

: INSERT-PLAN ( SQLITE:connection MODEL:path MODEL:key -- plan-id )
   {: c path k :}
   c s" INSERT INTO plans(path, status, canonical_path)
      VALUES (?1, 'pending', ?2)"
   >str [: path PATH-BYTES >str 1 SQLITE:BIND-BLOB
      k KEY-BYTES >str 2 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c SQLITE:LAST-ROWID >PLAN-ID ;

: INSERT-OPERATION ( SQLITE:connection plan-id n ^u8 n -- )
   {: c id ordinal js:^ ju :}
   c s" INSERT INTO operations(plan_id, ordinal, operation_json, status)
      VALUES (?1, ?2, ?3, 'pending')"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT
      ordinal 2 SQLITE:BIND-INT
      js ju >str 3 SQLITE:BIND-TEXT
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
   c id ar READ-PLAN s" read recorded plan" >str path
   s" new plan disappeared inside its transaction" HELD-PLAN ;

: LIVE
   ( SQLITE:connection plan-id MODEL:path ^ARENA:arena -- plan-record )
   {: c id path ar :}
   c id ar READ-PLAN s" read existing live plan" >str path
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
      s" record plan" >str path
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
     ^ARENA:arena ^JSON:writer -- n )
   {: c e live ar w :}
   e JOURNAL-PATH--BASELINE:UNMAKE {: path b :}
   c path b ar w RECORD-NOOP-IN MATCH noop-write
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
     ^VEC:vector<MODEL:path> ^ARENA:arena ^JSON:writer -- n )
   {: c noops live ar w :}
   0 noops VEC:COUNT 0 ?do
      c noops i VEC:AT @ live ar w NOOP-ENTRY +
   loop ;

: PLANS-IN
   ( SQLITE:connection ^VEC:vector<path-plan>
     ^VEC:vector<MODEL:path> ^ARENA:arena ^JSON:writer -- n )
   {: c plans live ar w :}
   0 plans VEC:COUNT 0 ?do
      c plans i VEC:AT @ live ar w PLAN-ENTRY +
   loop ;

: RECONCILED
   ( SQLITE:connection ^VEC:vector<path-baseline>
     ^VEC:vector<path-plan> ^VEC:vector<MODEL:path> ^ARENA:arena
     ^JSON:writer -- reconciliation-write )
   {: c noops plans live ar w :}
   c noops live ar w NOOPS-IN {: n :}
   c plans live ar w PLANS-IN {: p :}
   n p live JOURNAL-RECONCILIATION--WRITE:MAKE ;

public

\ Records a planner-approved baseline that needs no effect, unless a
\ live plan owns the path; the path's conflicts are resolved.
: RECORD-NOOP
   ( journal MODEL:path MODEL:baseline ^ARENA:arena -- noop-write )
   {: j path b ar :}
   j >CONNECTION {: c :}
   c [: c path b ar [: RECORD-NOOP-IN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

\ Commits an ordered plan before an effect executor sees it; a live
\ plan the path already owns is answered instead.
: RECORD-PLAN
   ( journal MODEL:path operation-plan ^ARENA:arena -- plan-write )
   {: j path plan ar :}
   j >CONNECTION {: c :}
   c [: c path plan ar [: RECORD-PLAN-IN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

\ Commits every journal-only decision of one complete observation
\ together: all, or none when one throws.
: RECORD-RECONCILIATION
   ( journal ^VEC:vector<path-baseline> ^VEC:vector<path-plan>
     ^ARENA:arena -- reconciliation-write )
   {: j noops plans ar :}
   ar [type] MODEL:path NEW-VECTOR {: live :}
   noops VEC:COUNT plans VEC:COUNT or 0= if
      0 0 live JOURNAL-RECONCILIATION--WRITE:MAKE exit
   then
   j >CONNECTION {: c :}
   c [: c noops plans live ar [: RECONCILED ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

\ Every plan awaiting its next effect, by id, each one's operations in
\ order.
: PENDING-PLANS ( journal ^ARENA:arena -- ^VEC:vector<plan-record> )
   {: j ar :}
   j >CONNECTION s" pending" s" read pending plans" >str ar
   READ-PLANS-WITH-STATUS ;

\ Every plan a classified failure holds, by id, each one's operations in
\ order.
: BLOCKED-PLANS ( journal ^ARENA:arena -- ^VEC:vector<plan-record> )
   {: j ar :}
   j >CONNECTION s" blocked" s" read blocked plans" >str ar
   READ-PLANS-WITH-STATUS ;

\ The plan with this id as the journal holds it now, if any.
: PLAN-OF ( journal plan-id ^ARENA:arena -- option<plan-record> )
   {: j id ar :}
   j >CONNECTION id ar READ-PLAN ;

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
: BLOCKING ( SQLITE:connection plan-id ^u8 n n MODEL:path -- )
   {: c id js:^ ju at path :}
   at 0 < if
      s" block plan" >str path
      s" retry time exceeds the supported range" PATH-INVALID
   then
   c s" UPDATE plans SET status = 'blocked', blocked_json = ?2,
         retry_at = ?3
      WHERE id = ?1"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT
      js ju >str 2 SQLITE:BIND-TEXT
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
   c id s" read plan status for blocking" >str ar READ-PLAN-STATE
   MATCH option
      none OF construct plan-block not-found ENDOF
      some OF {: state :} c id reason at state w BLOCK-STATED ENDOF
   ;MATCH ;

: UNBLOCKING ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE plans SET status = 'pending', blocked_json = NULL,
         retry_at = NULL
      WHERE id = ?1"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
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
   c id s" read plan status for unblocking" >str ar READ-PLAN-STATE
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
   1 SQLITE:COL-TEXT >str path ar
   s" deserialize pending upload operation" >str OPERATION-AS
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
      ORDER BY operations.id"
   >str [: begin SQLITE:STEP while hashes ar UPLOAD-ROW repeat ;]
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
   s" deserialize conflict" >str path MODEL:PATH>STR DECODE ;

: ENCODE-CONFLICT ( MODEL:conflict ^JSON:writer -- ^u8 n )
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
   DROPBOX:HASH>STR str> {: b:^ bu :}
   DROPBOX:HASH>STR str> b bu STR= ;

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

: FINISH-PLAN ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE plans
      SET status = 'completed', blocked_json = NULL, retry_at = NULL
      WHERE id = ?1"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The plan's completed recovery copies start their retention now.
: START-RECOVERY-RETENTION ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE recovery_records SET retained_at = unixepoch()
      WHERE status = 'completed' AND retained_at IS NULL
         AND operation_id IN (
            SELECT id FROM operations WHERE plan_id = ?1
         )"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The plan and every operation of it completed, its baseline unchanged.
: RETIRE-PLAN ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE operations SET status = 'completed' WHERE plan_id = ?1"
   >str [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c id FINISH-PLAN
   c id START-RECOVERY-RETENTION ;

\ The new conflict's id.
: INSERT-CONFLICT
   ( SQLITE:connection MODEL:path MODEL:conflict ^ARENA:arena
     ^JSON:writer -- n )
   {: c path x ar w :}
   x w ENCODE-CONFLICT {: js:^ ju :}
   path ar MODEL:FOLD {: k :}
   c s" INSERT INTO conflicts(path, conflict_json, canonical_path)
      VALUES (?1, ?2, ?3)"
   >str [: path PATH-BYTES >str 1 SQLITE:BIND-BLOB
      js ju >str 2 SQLITE:BIND-TEXT
      k KEY-BYTES >str 3 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c SQLITE:LAST-ROWID ;


\ ---- completing an operation ----

: STEP-QUERY ( -- ^u8 n )
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
   2 SQLITE:COL-TEXT s" read operation status" >str
   path MODEL:PATH>STR DECODE-STATUS {: s :}
   3 SQLITE:COL-TEXT {: ps:^ pu :}
   6 TEXT? {: json :}
   7 INT? {: retry :}
   ps pu json retry s" read plan status" >str path ar DECODE-PLAN-STATUS
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
   >str [: id OPERATION-ID>N 1 SQLITE:BIND-INT ar STEP-ROW ;]
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
      ORDER BY ordinal LIMIT 1"
   >str [: plan PLAN-ID>N 1 SQLITE:BIND-INT ordinal 2 SQLITE:BIND-INT
      EARLIER-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Whether the plan holds an operation after the ordinal.
: LATER? ( SQLITE:connection operation-state -- bool )
   {: c s :}
   s OPERATION-STATE-UNMAKE {: plan ordinal done:bool path json:str :}
   c s" SELECT EXISTS(SELECT 1 FROM operations
      WHERE plan_id = ?1 AND ordinal > ?2)"
   >str [: plan PLAN-ID>N 1 SQLITE:BIND-INT ordinal 2 SQLITE:BIND-INT
      INT-ROW ;]
   SQLITE:WITH-STATEMENT 0<> ;

\ The operation completed, and the legacy recovery intent it had.
: MARK-COMPLETED ( SQLITE:connection operation-id -- )
   {: c id :}
   c s" UPDATE operations SET status = 'completed' WHERE id = ?1"
   >str [: id OPERATION-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c s" UPDATE recovery_records SET status = 'completed'
      WHERE operation_id = ?1 AND status = 'pending'"
   >str [: id OPERATION-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

\ The final operation, its plan and the actual baseline completed; the
\ path's conflicts are resolved.
: COMPLETE-FINAL
   ( SQLITE:connection operation-id operation-state MODEL:operation
     MODEL:baseline ^ARENA:arena ^JSON:writer -- operation-completion )
   {: c id s o b ar w :}
   o b OPERATION-MATCHES-BASELINE? 0= if
      construct operation-completion baseline-mismatch exit
   then
   s OPERATION-STATE-UNMAKE {: plan ordinal done:bool path json:str :}
   c id MARK-COMPLETED
   c path b ar w WRITE-BASELINE
   c path ar MODEL:FOLD RETIRE-CONFLICTS
   c plan FINISH-PLAN
   c plan START-RECOVERY-RETENTION
   construct operation-completion plan-completed ;

\ No earlier operation is pending: a non-final one completes with no
\ baseline, the final one with its own.
: COMPLETE-IN-ORDER
   ( SQLITE:connection operation-id operation-state MODEL:operation
     option<MODEL:baseline> ^ARENA:arena ^JSON:writer
     -- operation-completion )
   {: c id s o b ar w :}
   c s LATER? if
      b SOME-BASELINE? if
         construct operation-completion unexpected-baseline exit
      then
      c id MARK-COMPLETED
      construct operation-completion operation-completed exit
   then
   b MATCH option
      none OF construct operation-completion baseline-required ENDOF
      some OF {: r :} c id s o r ar w COMPLETE-FINAL ENDOF
   ;MATCH ;

: COMPLETE-FOUND
   ( SQLITE:connection operation-id operation-state
     option<MODEL:baseline> ^ARENA:arena ^JSON:writer
     -- operation-completion )
   {: c id s b ar w :}
   s OPERATION-STATE-UNMAKE {: plan ordinal done:bool path json:str :}
   done if construct operation-completion already-completed exit then
   json path ar DECODE-OPERATION {: o :}
   c s EARLIER MATCH option
      some OF construct operation-completion waiting-for-earlier-operation
      ENDOF
      none OF c id s o b ar w COMPLETE-IN-ORDER ENDOF
   ;MATCH ;

: COMPLETE-OPERATION-IN
   ( SQLITE:connection operation-id option<MODEL:baseline> ^ARENA:arena
     ^JSON:writer -- operation-completion )
   {: c id b ar w :}
   c id ar READ-STEP MATCH option
      none OF construct operation-completion not-found ENDOF
      some OF {: s :} c id s b ar w COMPLETE-FOUND ENDOF
   ;MATCH ;

: COMPLETE-ALL
   ( SQLITE:connection ^VEC:vector<operation-baseline>
     ^VEC:vector<operation-completion> ^ARENA:arena ^JSON:writer -- )
   {: c finals outcomes ar w :}
   finals VEC:COUNT 0 ?do
      finals i VEC:AT @ JOURNAL-OPERATION--BASELINE:UNMAKE {: id b :}
      c id b OPTION:SOME ar w COMPLETE-OPERATION-IN outcomes VEC:PUSH !
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
   c id s" read plan status for conflict" >str ar READ-PLAN-STATE
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
   c id s" read plan status for supersession" >str ar READ-PLAN-STATE
   MATCH option
      none OF construct plan-supersede not-found ENDOF
      some OF {: st :} c id st SUPERSEDE-LIVE ENDOF
   ;MATCH ;

: CONFLICT-ROW
   ( SQLITE:statement ^VEC:vector<conflict-record> ^ARENA:arena
     -- SQLITE:statement )
   {: found ar :}
   1 ar PATH-COPY {: path :}
   2 SQLITE:COL-TEXT >str path ar DECODE-CONFLICT {: x :}
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
   c [: c id b ar [: COMPLETE-OPERATION-IN ;] ENCODING ;]
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
   c [: c finals outcomes ar [: COMPLETE-ALL ;] ENCODING ;]
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
   s" SELECT id, path, conflict_json FROM conflicts ORDER BY id"
   >str [: begin SQLITE:STEP while found ar CONFLICT-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   found ;


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
   s" deserialize recovery content" >str path MODEL:PATH>STR DECODE ;

: RETAINED-AT ( option<n> MODEL:path -- option<n> )
   {: path :}
   MATCH option
      none OF NO-INT ENDOF
      some OF
         {: at :}
         at 0 < if
            s" read recovery retention start" >str path
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
   3 SQLITE:COL-TEXT >str original ar DECODE-CONTENT {: content :}
   4 SQLITE:COL-TEXT s" read recovery status" >str
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
      FROM recovery_records WHERE id = ?1"
   >str [: id RECOVERY-ID>N 1 SQLITE:BIND-INT id ar RECOVERY-ROW ;]
   SQLITE:WITH-STATEMENT ;

: PUSH-RECOVERY-ID
   ( SQLITE:statement ^VEC:vector<recovery-id> -- SQLITE:statement )
   {: ids :}
   0 SQLITE:COL-INT >RECOVERY-ID ids VEC:PUSH ! ;

\ Each selected record, read again; one gone since is op's invalid state
\ on path, as detail says.
: READ-EACH
   ( SQLITE:connection ^VEC:vector<recovery-id> str str ^u8 n
     ^ARENA:arena -- ^VEC:vector<recovery-record> )
   {: c ids op:str path:str d:^ du ar :}
   ar [type] recovery-record NEW-VECTOR {: found :}
   ids VEC:COUNT 0 ?do
      c ids i VEC:AT @ ar READ-RECOVERY MATCH option
         none OF op path d du >str INVALID ENDOF
         some OF found VEC:PUSH ! ENDOF
      ;MATCH
   loop
   found ;

\ Every record whose status is the text, by id; op names a failure.
: READ-RECOVERIES-WITH-STATUS
   ( SQLITE:connection str ^u8 n str ^ARENA:arena
     -- ^VEC:vector<recovery-record> )
   {: c path:str s:^ su op:str ar :}
   ar [type] recovery-id NEW-VECTOR {: ids :}
   c s" SELECT id FROM recovery_records WHERE status = ?1 ORDER BY id"
   >str [: s su >str 1 SQLITE:BIND-TEXT
      begin SQLITE:STEP while ids PUSH-RECOVERY-ID repeat ;]
   SQLITE:WITH-STATEMENT
   c ids op path
   s" selected recovery disappeared while reading the journal" ar
   READ-EACH ;

: ELIGIBLE-QUERY ( -- ^u8 n )
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

: FORGET-QUERY ( -- ^u8 n )
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
   0 SQLITE:COL-TEXT s" read recovery status to forget" >str path
   DECODE-STATUS {: s :}
   1 SQLITE:COL-INT 0<> {: eligible:bool :}
   s DONE? eligible and OPTION:SOME swap ;

: FORGOTTEN ( bool SQLITE:connection recovery-id -- recovery-forget )
   {: done:bool c id :}
   done 0= if construct recovery-forget pending exit then
   c s" DELETE FROM recovery_records
      WHERE id = ?1 AND status = 'completed'"
   >str [: id RECOVERY-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   construct recovery-forget forgotten ;

: FORGET-IN
   ( SQLITE:connection recovery-id str -- recovery-forget )
   {: c id path:str :}
   c FORGET-QUERY
   >str [: id RECOVERY-ID>N 1 SQLITE:BIND-INT path FORGETTABLE-ROW ;]
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
   j >CONNECTION j >PATH s" pending" s" read pending recovery" >str ar
   READ-RECOVERIES-WITH-STATUS ;

\ Every retained recovery record whose payload no unfinished work needs,
\ by id.
: COMPLETED-RECOVERIES
   ( journal ^ARENA:arena -- ^VEC:vector<recovery-record> )
   {: j ar :}
   ar [type] recovery-id NEW-VECTOR {: ids :}
   j >CONNECTION {: c :}
   c ELIGIBLE-QUERY
   >str [: begin SQLITE:STEP while ids PUSH-RECOVERY-ID repeat ;]
   SQLITE:WITH-STATEMENT
   c ids s" read completed recovery" >str j >PATH
   s" eligible recovery disappeared while reading the journal" ar
   READ-EACH ;

\ Forgets a completed recovery record once no unfinished work needs its
\ payload.
: FORGET-COMPLETED-RECOVERY ( journal recovery-id -- recovery-forget )
   {: j id :}
   j >CONNECTION {: c :}
   c [: c id j >PATH FORGET-IN ;] SQLITE:WITH-TRANSACTION ;

;package
