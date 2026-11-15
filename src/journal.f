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
\ A baseline and a plan are keyed by the canonical path MODEL:FOLD gives
\ the display path; every stored value is MODEL's JSON, and a stored
\ value that does not read is logged and thrown as E-JSON. Each write is
\ one immediate transaction.
\ STORAGE CLASS. CALLER-OWNED: a journal borrows the path it was opened
\ with until CLOSE, and a binding INSPECT answers borrows its path; every
\ string and vector a reader answers, and every stored value's text a
\ writer makes, lies in the arena the caller passes. A journal
\ belongs to the task that opened it. TASK-LOCAL: the bytes a root's
\ inode and subvolume are bound from, a TASK:+USERS row.

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
: MIGRATE-BLOCKED-PLANS ( SQLITE:connection -- )
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
   c MIGRATE-BLOCKED-PLANS
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

\ Deletes each completed plan, and its operations, that no pending or
\ unretained recovery record of its operations holds. The plans' delete
\ selects the plans the operations' did: a held plan keeps the operation
\ its record names.
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

\ The journal at path, schema 8 created in a new or empty file, its
\ completed work pruned. Another version is E-UNSUPPORTED-VERSION, the
\ file unchanged.
: OPEN ( str -- journal )
   {: path:str :}
   path OWNER-ONLY
   path str> SQLITE:OPEN path JOURNAL-MAKE [: READY ;] SET-UP ;

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
$2F constant SLASH
$2E constant DOT
$30 constant SUBTREE-END       \ the byte after SLASH
64 constant JSON-CAP           \ a stored value's first buffer, in bytes

ARENA WRITERS JSON:writer


\ ---- stored values -------------------------------------------------

: PATH-BYTES ( MODEL:path -- ^u8 n ) MODEL:PATH>STR str> ;
: KEY-BYTES ( MODEL:key -- ^u8 n ) MODEL:KEY>STR str> ;

\ What emit writes, its bytes copied into the arena.
: ENCODED ( [ ^JSON:writer -- ^JSON:writer ] ^ARENA:arena -- str )
   {: emit ar :}
   ar BUF:HDR-BYTES ARENA:ALLOC drop CELL-VIEW {: buf :}
   buf JSON-CAP BUF:N>BLEN BUF:INIT
   ar WRITERS-NEW {: w :}
   [: w buf JSON:WRITE-OPEN-BUF emit execute JSON:WRITE-CLOSE
      buf BUF:SPAN$ BUF:BLEN>N ar COPIED ;]
   [: buf BUF:DISPOSE ;] finally ;

\ op could not read path's stored value; any code but MODEL:E-STORED
\ goes on unchanged.
: UNREADABLE ( n str str -- )
   {: code op:str path:str :}
   code MODEL:E-STORED <> if code throw then
   op OPERATION s" could not process the record for `" LOG:TEXT+
   path STR+ s" `: " LOG:TEXT+ code LOG:CODE+ LOG:;LINE
   E-JSON throw ;

\ Runs a read that replaces the seed it is given, as catch keeps the
\ stack's shape; a stored value that does not read is op's on path.
: DECODED ( R [ R -- R ] str MODEL:path -- R )
   {: read op:str path :}
   [: read execute ;] catch {: code :}
   code 0= if exit then
   code op path MODEL:PATH>STR UNREADABLE ;

\ A seed's typed drop, which types the read that replaces it.
: DROP-BASELINE ( MODEL:baseline -- ) drop ;
: DROP-OPERATION ( MODEL:operation -- ) drop ;
: DROP-BLOCKAGE ( MODEL:blockage -- ) drop ;

: DECODE-BASELINE ( str MODEL:path ^ARENA:arena -- MODEL:baseline )
   {: json:str path ar :}
   MODEL-BASELINE:absent
   [: DROP-BASELINE json ar MODEL:JSON>BASELINE ;]
   s" deserialize baseline" >str path DECODED ;

: OPERATION-AS
   ( str MODEL:path ^ARENA:arena str -- MODEL:operation )
   {: json:str path ar op:str :}
   MODEL-OPERATION:create-local-directory
   [: DROP-OPERATION json ar MODEL:JSON>OPERATION ;] op path DECODED ;

: DECODE-OPERATION ( str MODEL:path ^ARENA:arena -- MODEL:operation )
   s" deserialize operation" >str OPERATION-AS ;

: DECODE-BLOCKAGE ( str MODEL:path ^ARENA:arena -- MODEL:blockage )
   {: json:str path ar :}
   MODEL-BLOCKAGE:stage-occupied
   [: DROP-BLOCKAGE json ar MODEL:JSON>BLOCKAGE ;]
   s" deserialize block reason" >str path DECODED ;

: ENCODE-BASELINE ( MODEL:baseline ^ARENA:arena -- str )
   {: b ar :}
   [: b swap MODEL:BASELINE>JSON ;] ar ENCODED ;

: ENCODE-OPERATION ( MODEL:operation ^ARENA:arena -- str )
   {: o ar :}
   [: o swap MODEL:OPERATION>JSON ;] ar ENCODED ;

: ENCODE-BLOCKAGE ( MODEL:blockage ^ARENA:arena -- str )
   {: b ar :}
   [: b swap MODEL:BLOCKAGE>JSON ;] ar ENCODED ;

: ABSENT? ( MODEL:baseline -- bool )
   MATCH MODEL:baseline
      absent OF true ENDOF
      present OF drop false ENDOF
      directory OF false ENDOF
   ;MATCH ;

: NO-BASELINE ( -- option<MODEL:baseline> ) OPTION:NONE ;
: NO-PATH ( -- option<MODEL:path> ) OPTION:NONE ;
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

: PATH-COPY ( SQLITE:statement n ^ARENA:arena
     -- SQLITE:statement MODEL:path )
   BLOB-COPY MODEL:>PATH ;

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

: SPELLING-ROW
   ( SQLITE:statement ^ARENA:arena
     -- option<MODEL:path> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-PATH swap exit then
   0 ar PATH-COPY OPTION:SOME swap ;

public

\ The common baseline recorded for the display path; absent is none.
: BASELINE ( journal MODEL:path ^ARENA:arena -- option<MODEL:baseline> )
   {: j path ar :}
   path ar MODEL:FOLD {: k :}
   j >CONNECTION
   s" SELECT baseline_json FROM baselines WHERE canonical_path = ?1"
   [: k KEY-BYTES 1 SQLITE:BIND-BLOB path ar BASELINE-ROW ;]
   SQLITE:WITH-STATEMENT ;

\ Every path with a baseline, in the order of its bytes.
: BASELINE-PATHS ( journal ^ARENA:arena -- ^VEC:vector<MODEL:path> )
   {: j ar :}
   ar [type] MODEL:path NEW-VECTOR {: paths :}
   j >CONNECTION
   s\" SELECT path FROM baselines WHERE baseline_json != '\"Absent\"'
      ORDER BY path"
   [: begin SQLITE:STEP while paths ar PATH-ROW repeat ;]
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
   [: begin SQLITE:STEP while records ar RECORD-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   records ;

\ The display path the canonical path's baseline was recorded under.
: BASELINE-SPELLING
   ( journal MODEL:key ^ARENA:arena -- option<MODEL:path> )
   {: j k ar :}
   j >CONNECTION
   s\" SELECT path FROM baselines
      WHERE canonical_path = ?1 AND baseline_json != '\"Absent\"'"
   [: k KEY-BYTES 1 SQLITE:BIND-BLOB ar SPELLING-ROW ;]
   SQLITE:WITH-STATEMENT ;

private


\ ---- a case-collision rename ---------------------------------------

: DOT? ( ^u8 n -- bool )
   {: p:^ u :}
   u 1 = if p c@ DOT = exit then
   false ;

\ The bytes of a path's root or leading "." component.
: LEAD ( ^u8 n -- n )
   {: p:^ u :}
   u 0= if 0 exit then
   p c@ SLASH = if 1 exit then
   p u SLASH 0 SPLIT-NEXT 2drop DOT? if 1 exit then
   0 ;

\ The component from at and the index after it, empty and "." ones
\ skipped; false past the last.
: NEXT-PART ( ^u8 n n -- ^u8 n n bool )
   {: p:^ u at :}
   p u SLASH at SPLIT-NEXT 0= if false exit then
   {: q:^ v next :}
   v 0= q v DOT? or if p u next RECURSE exit then
   q v next true ;

\ Whether the second path's components from its index match the first's
\ from its, each in turn.
: FOLLOWS? ( ^u8 n n ^u8 n n -- bool )
   {: p:^ u pat q:^ v qat :}
   q v qat NEXT-PART 0= if 2drop drop true exit then
   {: b:^ bu qnext :}
   p u pat NEXT-PART 0= if 2drop drop false exit then
   {: a:^ au pnext :}
   a au b bu STR= 0= if false exit then
   p u pnext q v qnext RECURSE ;

\ Rust's Path::starts_with: the second path's components, its root or
\ leading "." included, begin the first's.
: BEGINS? ( MODEL:path MODEL:path -- bool )
   PATH-BYTES {: q:^ v :}
   PATH-BYTES {: p:^ u :}
   p u LEAD {: pl :}
   q v LEAD {: ql :}
   p pl q ql STR= 0= if false exit then
   p u pl q v ql FOLLOWS? ;

\ The canonical path with one byte after it, in the arena.
: SUFFIXED ( MODEL:key n ^ARENA:arena -- ^u8 n )
   {: k c ar :}
   k KEY-BYTES {: p:^ u :}
   ar u 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst u BYTE-COPY
   c dst u + c!
   dst u 1+ ;

: FORGET ( SQLITE:connection MODEL:key -- )
   {: c k :}
   c s" DELETE FROM baselines WHERE canonical_path = ?1"
   [: k KEY-BYTES 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
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
   k SLASH ar SUFFIXED {: from:^ fu :}
   k SUBTREE-END ar SUFFIXED {: to:^ tu :}
   c s" SELECT canonical_path, path FROM baselines
      WHERE canonical_path = ?1
         OR (canonical_path >= ?2 AND canonical_path < ?3)"
   [: k KEY-BYTES 1 SQLITE:BIND-BLOB
      from fu 2 SQLITE:BIND-BLOB
      to tu 3 SQLITE:BIND-BLOB
      begin SQLITE:STEP while found ar COLLECT-SPELLING repeat ;]
   SQLITE:WITH-STATEMENT
   found ;

\ Forgets the baseline recorded at the renamed path or beneath it, or
\ one whose display path exists does not confirm.
: FORGET-STALE
   ( SQLITE:connection MODEL:path [ MODEL:path -- bool ] spelling -- )
   {: c renamed exists s :}
   s SPELLING-UNMAKE {: k path :}
   path renamed BEGINS? if c k FORGET exit then
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

\ Forgets the common history a case-collision rename of the display
\ path would leave stale: each baseline at its canonical path or beneath
\ it, judged by its own display path, goes when that path is the renamed
\ one or beneath it, or exists answers false. Forgetting never plans a
\ Dropbox deletion. exists runs inside the transaction; its throw
\ forgets nothing and goes on.
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

: DECODE-STATUS ( ^u8 n str MODEL:path -- record-status )
   {: s:^ u op:str path :}
   s u s" pending" STR= if construct record-status pending exit then
   s u s" completed" STR= if construct record-status completed exit then
   op path s" record has an unrecognized status" PATH-INVALID ;

: NO-JSON? ( option<str> -- bool )
   MATCH option
      none OF true ENDOF
      some OF drop false ENDOF
   ;MATCH ;

: NO-RETRY? ( option<n> -- bool )
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
   json NO-JSON? retry NO-RETRY? and {: clear:bool :}
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
   at 3 + SQLITE:COL-TEXT s" read operation status" >str path
   DECODE-STATUS {: s :}
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

\ Every plan whose status is the text, by PLAN-QUERY.
: READ-PLANS-WITH-STATUS
   ( SQLITE:connection ^u8 n ^u8 n str ^ARENA:arena
     -- ^VEC:vector<plan-record> )
   {: c q:^ qu s:^ su op:str ar :}
   ar [type] plan-record NEW-VECTOR {: plans :}
   c q qu
   [: s su 1 SQLITE:BIND-TEXT
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
   [: id PLAN-ID>N 1 SQLITE:BIND-INT op ar STATE-ROW ;]
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
   [: id PLAN-ID>N 1 SQLITE:BIND-INT
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
   [: k KEY-BYTES 1 SQLITE:BIND-BLOB LIVE-ROW ;]
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
   ( SQLITE:connection MODEL:path MODEL:baseline ^ARENA:arena -- )
   {: c path b ar :}
   path ar MODEL:FOLD {: k :}
   b ABSENT? if c k FORGET exit then
   b ar ENCODE-BASELINE {: json:str :}
   c UPSERT-BASELINE
   [: path PATH-BYTES 1 SQLITE:BIND-BLOB
      json str> 2 SQLITE:BIND-TEXT
      k KEY-BYTES 3 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: RETIRE-CONFLICTS ( SQLITE:connection MODEL:key -- )
   {: c k :}
   c s" DELETE FROM conflicts WHERE canonical_path = ?1"
   [: k KEY-BYTES 1 SQLITE:BIND-BLOB SQLITE:STEP drop ;]
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
   [: path PATH-BYTES 1 SQLITE:BIND-BLOB
      k KEY-BYTES 2 SQLITE:BIND-BLOB
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c SQLITE:LAST-ROWID >PLAN-ID ;

: INSERT-OPERATION ( SQLITE:connection plan-id n str -- )
   {: c id ordinal json:str :}
   c s" INSERT INTO operations(plan_id, ordinal, operation_json, status)
      VALUES (?1, ?2, ?3, 'pending')"
   [: id PLAN-ID>N 1 SQLITE:BIND-INT
      ordinal 2 SQLITE:BIND-INT
      json str> 3 SQLITE:BIND-TEXT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: NEW-PLAN
   ( SQLITE:connection MODEL:path MODEL:key
     ^VEC:vector<MODEL:operation> ^ARENA:arena -- plan-record )
   {: c path k ops ar :}
   c path k INSERT-PLAN {: id :}
   ops VEC:COUNT 0 ?do
      c id i ops i VEC:AT @ ar ENCODE-OPERATION INSERT-OPERATION
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
     -- plan-write )
   {: c path plan ar :}
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
         c path k ops ar NEW-PLAN construct plan-write recorded
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
     ^ARENA:arena -- n )
   {: c e live ar :}
   e JOURNAL-PATH--PLAN:UNMAKE {: path plan :}
   c path plan ar RECORD-PLAN-IN MATCH plan-write
      recorded OF drop 1 ENDOF
      already-live OF drop path live VEC:PUSH ! 0 ENDOF
   ;MATCH ;

: NOOPS-IN
   ( SQLITE:connection ^VEC:vector<path-baseline>
     ^VEC:vector<MODEL:path> ^ARENA:arena -- n )
   {: c noops live ar :}
   0 noops VEC:COUNT 0 ?do
      c noops i VEC:AT @ live ar NOOP-ENTRY +
   loop ;

: PLANS-IN
   ( SQLITE:connection ^VEC:vector<path-plan>
     ^VEC:vector<MODEL:path> ^ARENA:arena -- n )
   {: c plans live ar :}
   0 plans VEC:COUNT 0 ?do
      c plans i VEC:AT @ live ar PLAN-ENTRY +
   loop ;

: RECONCILED
   ( SQLITE:connection ^VEC:vector<path-baseline>
     ^VEC:vector<path-plan> ^VEC:vector<MODEL:path> ^ARENA:arena
     -- reconciliation-write )
   {: c noops plans live ar :}
   c noops live ar NOOPS-IN {: n :}
   c plans live ar PLANS-IN {: p :}
   n p live JOURNAL-RECONCILIATION--WRITE:MAKE ;

public

\ Records a planner-approved baseline that needs no effect, unless a
\ live plan owns the path; the path's conflicts are resolved.
: RECORD-NOOP
   ( journal MODEL:path MODEL:baseline ^ARENA:arena -- noop-write )
   {: j path b ar :}
   j >CONNECTION {: c :}
   c [: c path b ar RECORD-NOOP-IN ;] SQLITE:WITH-TRANSACTION ;

\ Commits an ordered plan before an effect executor sees it; a live
\ plan the path already owns is answered instead.
: RECORD-PLAN
   ( journal MODEL:path operation-plan ^ARENA:arena -- plan-write )
   {: j path plan ar :}
   j >CONNECTION {: c :}
   c [: c path plan ar RECORD-PLAN-IN ;] SQLITE:WITH-TRANSACTION ;

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
   c [: c noops plans live ar RECONCILED ;] SQLITE:WITH-TRANSACTION ;

\ Every plan awaiting its next effect, by id, each one's operations in
\ order.
: PENDING-PLANS ( journal ^ARENA:arena -- ^VEC:vector<plan-record> )
   {: j ar :}
   j >CONNECTION PLAN-QUERY s" pending" s" read pending plans" >str ar
   READ-PLANS-WITH-STATUS ;

\ Every plan a classified failure holds, by id, each one's operations in
\ order.
: BLOCKED-PLANS ( journal ^ARENA:arena -- ^VEC:vector<plan-record> )
   {: j ar :}
   j >CONNECTION PLAN-QUERY s" blocked" s" read blocked plans" >str ar
   READ-PLANS-WITH-STATUS ;

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
   {: c id json:str at path :}
   at 0 < if
      s" block plan" >str path
      s" retry time exceeds the supported range" PATH-INVALID
   then
   c s" UPDATE plans SET status = 'blocked', blocked_json = ?2,
         retry_at = ?3
      WHERE id = ?1"
   [: id PLAN-ID>N 1 SQLITE:BIND-INT
      json str> 2 SQLITE:BIND-TEXT
      at 3 SQLITE:BIND-INT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT ;

: BLOCK-STATED
   ( SQLITE:connection plan-id MODEL:blockage n plan-state ^ARENA:arena
     -- plan-block )
   {: c id reason at state ar :}
   state PLAN-STATE-UNMAKE {: path status :}
   status COMPLETED? if
      construct plan-block already-completed exit
   then
   c id reason ar ENCODE-BLOCKAGE at path BLOCKING
   construct plan-block blocked ;

: BLOCK-IN
   ( SQLITE:connection plan-id MODEL:blockage n ^ARENA:arena
     -- plan-block )
   {: c id reason at ar :}
   c id s" read plan status for blocking" >str ar READ-PLAN-STATE
   MATCH option
      none OF construct plan-block not-found ENDOF
      some OF {: state :} c id reason at state ar BLOCK-STATED ENDOF
   ;MATCH ;

: UNBLOCKING ( SQLITE:connection plan-id -- )
   {: c id :}
   c s" UPDATE plans SET status = 'pending', blocked_json = NULL,
         retry_at = NULL
      WHERE id = ?1"
   [: id PLAN-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
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

\ Holds a live plan until its classified cause is worth retrying, at
\ retry-at, seconds since the epoch.
: BLOCK-PLAN
   ( journal plan-id MODEL:blockage n ^ARENA:arena -- plan-block )
   {: j id reason at ar :}
   j >CONNECTION {: c :}
   c [: c id reason at ar BLOCK-IN ;] SQLITE:WITH-TRANSACTION ;

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
   [: begin SQLITE:STEP while hashes ar UPLOAD-ROW repeat ;]
   SQLITE:WITH-STATEMENT
   hashes ;

;package
