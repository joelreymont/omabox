\ test-journal.f - JOURNAL's words for tests, never production: the Rust
\ version's test-only words (rust src/journal.rs, #[cfg(test)]), a
\ private comparison exported, and readers and writers of the local scan.
\ RECORD-RECOVERY-INTENT commits the recovery intent an older Omabox
\ version recorded before a destructive operation, answering a
\ recovery-write, COMPLETE-RECOVERY completes a recovery record,
\ answering a recovery-completion, TOTAL-CHANGES answers the rows the
\ journal's connection has changed since it opened, CHANGE-COUNTER
\ answers SQLite's file change counter, LOCAL-RECORDS= answers whether
\ two local inventories hold equal records in the same order,
\ LOCAL-HASH-CACHE answers the active root's hash cache,
\ PUBLISH-LOCAL-SCAN publishes given observations and hashes as one
\ scan, and SCAN-COUNTS answers how many files a scan has still to hash
\ and how many observations and hashes it staged. Tests alone load this
\ file; nothing in the program calls these words.
\ STORAGE CLASS. CALLER-OWNED, as JOURNAL's: a record answered lies in the
\ arena the caller passes. TASK-LOCAL: the bytes CHANGE-COUNTER reads,
\ TASK:+USERS rows.

require src/lib/arena.f
require src/lib/be.f
require src/lib/fs.f
require src/lib/task.f
require src/lib/adt/option.f
require src/lib/sqlite.f
require src/lib/json.f
require src/dropbox.f
require src/model.f
require src/journal.f

\ JOURNAL reopened: these words read and write its rows through its
\ private connection, decoders and readers.
package JOURNAL
public

\ already-recorded: the intent committed before; operation-not-
\ destructive: the operation neither replaces nor deletes content.
ENUM recovery-write
   VARIANT recorded FIELD record recovery-record ;VARIANT
   VARIANT already-recorded FIELD record recovery-record ;VARIANT
   VARIANT operation-not-found ;VARIANT
   VARIANT operation-completed ;VARIANT
   VARIANT operation-not-destructive ;VARIANT
;ENUM

ENUM recovery-completion not-found already-completed completed ;ENUM

: TOTAL-CHANGES ( journal -- n )
   >CONNECTION s" SELECT total_changes()" QUERY-INT ;

private

4 TASK:+USERS COUNTER-BYTES u8

public

\ SQLite's file change counter, which every commit that writes the
\ journal file increments.
: CHANGE-COUNTER ( journal -- n )
   >PATH 24 0 COUNTER-BYTES 4 FS:READ-AT
   0 COUNTER-BYTES BE:U32@ ;

EXPORT LOCAL-RECORDS=

\ The hashes verified for the active root, by path.
: LOCAL-HASH-CACHE
   ( journal ^ARENA:arena -- ^VEC:vector<MODEL:hash-record> )
   {: j ar :}
   ar ARENA:ALLOCATOR 0 [type] MODEL:hash-record VEC:NEW {: v :}
   j >CONNECTION s" SELECT cache.path, cache.inode, cache.size,
         cache.modified_seconds, cache.modified_nanoseconds,
         cache.changed_seconds, cache.changed_nanoseconds,
         cache.content_hash
      FROM local_hash_cache AS cache
      JOIN local_root_binding AS root
         ON root.singleton = 1 AND cache.root_generation = root.generation
      ORDER BY cache.path" [: begin SQLITE:STEP while ar REUSE-ROW v VEC:PUSH ! repeat ;]
   SQLITE:WITH-STATEMENT
   v ;

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

\ The scan's files still to hash, then the observations and the hashes
\ it staged, gone ones among them; all stay in the scan.
: SCAN-COUNTS ( scan -- scan n n n )
   SCAN-JOURNAL >CONNECTION {: c :}
   c s" SELECT COUNT(*) FROM temp.scan_jobs" QUERY-INT
   c s" SELECT COUNT(*) FROM temp.scan_observations" QUERY-INT
   c s" SELECT COUNT(*) FROM temp.scan_hashes" QUERY-INT ;

private


\ ---- completing a recovery ----

: NO-RECORD-STATUS ( -- option<record-status> ) OPTION:NONE ;

\ The status of the row the statement steps to, if any.
: RECOVERY-STATUS
   ( SQLITE:statement str str
     -- option<record-status> SQLITE:statement )
   {: op:str path:str :}
   SQLITE:STEP 0= if NO-RECORD-STATUS swap exit then
   0 SQLITE:COL-TEXT op path DECODE-STATUS OPTION:SOME swap ;

: RECOVERY-COMPLETED
   ( record-status SQLITE:connection recovery-id -- recovery-completion )
   {: s c id :}
   s DONE? if construct recovery-completion already-completed exit then
   c s" UPDATE recovery_records SET status = 'completed' WHERE id = ?1" [: id RECOVERY-ID>N 1 SQLITE:BIND-INT SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   construct recovery-completion completed ;

: COMPLETE-RECOVERY-IN
   ( SQLITE:connection recovery-id str -- recovery-completion )
   {: c id path:str :}
   c s" SELECT status FROM recovery_records WHERE id = ?1" [: id RECOVERY-ID>N 1 SQLITE:BIND-INT
      s" read recovery status" path RECOVERY-STATUS ;]
   SQLITE:WITH-STATEMENT
   MATCH option
      none OF construct recovery-completion not-found ENDOF
      some OF c id RECOVERY-COMPLETED ENDOF
   ;MATCH ;

public

\ Completes a recovery record; its operation and baseline stay.
: COMPLETE-RECOVERY ( journal recovery-id -- recovery-completion )
   {: j id :}
   j >CONNECTION {: c :}
   c [: c id j >PATH COMPLETE-RECOVERY-IN ;]
   SQLITE:WITH-TRANSACTION ;

private


\ ---- test-only recovery words of the Rust version ----------------

\ A plan's row and its operation's, as a recovery intent reads them.
STRUCTURE intent
   FIELD path MODEL:path
   FIELD json str
   FIELD status str
   FIELD plan plan-id
   FIELD ordinal n
;STRUCTURE

: NO-INTENT ( -- option<intent> ) OPTION:NONE ;
: NO-RECOVERY-ID ( -- option<recovery-id> ) OPTION:NONE ;
: NO-CONTENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;
: NO-REV ( -- option<DROPBOX:rev> ) OPTION:NONE ;

: REV= ( DROPBOX:rev DROPBOX:rev -- bool )
   {: a b :}
   a DROPBOX:REV>STR b DROPBOX:REV>STR STR:= ;

: DESTRUCTIVE? ( MODEL:operation -- bool )
   MATCH MODEL:operation
      create-local-directory OF false ENDOF
      create-remote-directory OF false ENDOF
      delete-local-directory OF false ENDOF
      delete-remote-directory OF false ENDOF
      create-remote OF drop false ENDOF
      install-local OF drop false ENDOF
      preserve-local OF drop false ENDOF
      replace-local OF drop drop true ENDOF
      delete-local OF drop true ENDOF
      preserve-remote OF drop false ENDOF
      replace-remote OF drop drop true ENDOF
      delete-remote OF drop true ENDOF
   ;MATCH ;

: MISSING-PRESERVATION ( MODEL:path -- )
   {: path :}
   s" derive recovery content" path
   s" destructive operation lacks immediately preceding matching preservation"
   PATH-INVALID ;

\ The content a local replacement or deletion expects to displace.
: EXPECTED-CONTENT ( MODEL:operation -- option<DROPBOX:hash> )
   MATCH MODEL:operation
      create-local-directory OF NO-CONTENT ENDOF
      create-remote-directory OF NO-CONTENT ENDOF
      delete-local-directory OF NO-CONTENT ENDOF
      delete-remote-directory OF NO-CONTENT ENDOF
      create-remote OF drop NO-CONTENT ENDOF
      install-local OF drop NO-CONTENT ENDOF
      preserve-local OF drop NO-CONTENT ENDOF
      replace-local OF {: r e :} e OPTION:SOME ENDOF
      delete-local OF OPTION:SOME ENDOF
      preserve-remote OF drop NO-CONTENT ENDOF
      replace-remote OF drop drop NO-CONTENT ENDOF
      delete-remote OF drop NO-CONTENT ENDOF
   ;MATCH ;

\ The revision a remote replacement or deletion expects to displace.
: EXPECTED-REV ( MODEL:operation -- option<DROPBOX:rev> )
   MATCH MODEL:operation
      create-local-directory OF NO-REV ENDOF
      create-remote-directory OF NO-REV ENDOF
      delete-local-directory OF NO-REV ENDOF
      delete-remote-directory OF NO-REV ENDOF
      create-remote OF drop NO-REV ENDOF
      install-local OF drop NO-REV ENDOF
      preserve-local OF drop NO-REV ENDOF
      replace-local OF drop drop NO-REV ENDOF
      delete-local OF drop NO-REV ENDOF
      preserve-remote OF drop NO-REV ENDOF
      replace-remote OF {: c r :} r OPTION:SOME ENDOF
      delete-remote OF OPTION:SOME ENDOF
   ;MATCH ;

: KEEPS-LOCAL ( MODEL:local MODEL:operation -- option<DROPBOX:hash> )
   {: file d :}
   file MODEL-LOCAL:UNMAKE {: c :}
   d EXPECTED-CONTENT MATCH option
      none OF NO-CONTENT ENDOF
      some OF c HASH= if c OPTION:SOME else NO-CONTENT then ENDOF
   ;MATCH ;

: KEEPS-REMOTE ( MODEL:remote MODEL:operation -- option<DROPBOX:hash> )
   {: file d :}
   file MODEL-REMOTE:UNMAKE {: c rev :}
   d EXPECTED-REV MATCH option
      none OF NO-CONTENT ENDOF
      some OF rev REV= if c OPTION:SOME else NO-CONTENT then ENDOF
   ;MATCH ;

\ The preserved content the destructive operation displaces, if it
\ expects what the preservation kept.
: DISPLACED-CONTENT
   ( MODEL:operation MODEL:operation -- option<DROPBOX:hash> )
   {: d :}
   MATCH MODEL:operation
      create-local-directory OF NO-CONTENT ENDOF
      create-remote-directory OF NO-CONTENT ENDOF
      delete-local-directory OF NO-CONTENT ENDOF
      delete-remote-directory OF NO-CONTENT ENDOF
      create-remote OF drop NO-CONTENT ENDOF
      install-local OF drop NO-CONTENT ENDOF
      preserve-local OF d KEEPS-LOCAL ENDOF
      replace-local OF drop drop NO-CONTENT ENDOF
      delete-local OF drop NO-CONTENT ENDOF
      preserve-remote OF d KEEPS-REMOTE ENDOF
      replace-remote OF drop drop NO-CONTENT ENDOF
      delete-remote OF drop NO-CONTENT ENDOF
   ;MATCH ;

: RECOVERY-ID-ROW
   ( SQLITE:statement -- option<recovery-id> SQLITE:statement )
   SQLITE:STEP 0= if NO-RECOVERY-ID swap exit then
   0 SQLITE:COL-INT >RECOVERY-ID OPTION:SOME swap ;

: READ-RECOVERY-FOR-OPERATION
   ( SQLITE:connection operation-id ^ARENA:arena
     -- option<recovery-record> )
   {: c id ar :}
   c s" SELECT id FROM recovery_records WHERE operation_id = ?1" [: id OPERATION-ID>N 1 SQLITE:BIND-INT RECOVERY-ID-ROW ;]
   SQLITE:WITH-STATEMENT
   MATCH option
      none OF NO-RECOVERY ENDOF
      some OF c swap ar READ-RECOVERY ENDOF
   ;MATCH ;

: INTENT-ROW
   ( SQLITE:statement ^ARENA:arena -- option<intent> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-INTENT swap exit then
   0 ar PATH-COPY {: path :}
   1 ar TEXT-COPY {: json:str :}
   2 ar TEXT-COPY {: status:str :}
   3 SQLITE:COL-INT >PLAN-ID {: plan :}
   4 SQLITE:COL-INT {: ordinal :}
   path json status plan ordinal INTENT-MAKE OPTION:SOME swap ;

: READ-INTENT
   ( SQLITE:connection operation-id ^ARENA:arena -- option<intent> )
   {: c id ar :}
   c s" SELECT plans.path, operations.operation_json, operations.status,
         operations.plan_id, operations.ordinal
      FROM operations JOIN plans ON plans.id = operations.plan_id
      WHERE operations.id = ?1" [: id OPERATION-ID>N 1 SQLITE:BIND-INT ar INTENT-ROW ;]
   SQLITE:WITH-STATEMENT ;

: JSON-ROW
   ( SQLITE:statement ^ARENA:arena -- option<str> SQLITE:statement )
   {: ar :}
   SQLITE:STEP 0= if NO-TEXT swap exit then
   0 ar TEXT-COPY OPTION:SOME swap ;

\ The operation just before the intent's, which must preserve what it
\ displaces.
: PRESERVATION ( SQLITE:connection intent ^ARENA:arena -- MODEL:operation )
   {: c t ar :}
   t INTENT-UNMAKE {: path json:str status:str plan ordinal :}
   c s" SELECT operation_json FROM operations
      WHERE plan_id = ?1 AND ordinal = ?2" [: plan PLAN-ID>N 1 SQLITE:BIND-INT ordinal 1- 2 SQLITE:BIND-INT
      ar JSON-ROW ;]
   SQLITE:WITH-STATEMENT MATCH option
      none OF path MISSING-PRESERVATION ENDOF
      some OF
         path ar s" deserialize preservation operation" OPERATION-AS
      ENDOF
   ;MATCH ;

: DISPLACED ( MODEL:operation MODEL:operation MODEL:path -- DROPBOX:hash )
   {: prev o path :}
   prev o DISPLACED-CONTENT MATCH option
      none OF path MISSING-PRESERVATION ENDOF
      some OF ENDOF
   ;MATCH ;

: INTENT-RECORDED
   ( SQLITE:connection operation-id MODEL:path MODEL:path DROPBOX:hash
     ^ARENA:arena ^JSON:writer -- recovery-write )
   {: c id original copy content ar w :}
   w [: content swap MODEL:HASH>JSON ;] ENCODE {: js:str :}
   c s" INSERT INTO recovery_records(operation_id, original_path,
         recovery_path, content_json, status)
      VALUES (?1, ?2, ?3, ?4, 'pending')" [: id OPERATION-ID>N 1 SQLITE:BIND-INT
      original MODEL:PATH>STR 2 SQLITE:BIND-BLOB
      copy MODEL:PATH>STR 3 SQLITE:BIND-BLOB
      js 4 SQLITE:BIND-TEXT
      SQLITE:STEP drop ;]
   SQLITE:WITH-STATEMENT
   c c SQLITE:LAST-ROWID >RECOVERY-ID ar READ-RECOVERY MATCH option
      none OF
         s" read recorded recovery intent" original
         s" new recovery record disappeared inside its transaction"
         PATH-INVALID
      ENDOF
      some OF construct recovery-write recorded ENDOF
   ;MATCH ;

: NEW-INTENT
   ( SQLITE:connection operation-id MODEL:path intent ^ARENA:arena
     ^JSON:writer -- recovery-write )
   {: c id copy t ar w :}
   t INTENT-UNMAKE {: path json:str status:str plan ordinal :}
   status s" read recovery operation status"
   path MODEL:PATH>STR DECODE-STATUS DONE? if
      construct recovery-write operation-completed exit
   then
   json path ar s" deserialize recovery operation" OPERATION-AS {: o :}
   o DESTRUCTIVE? 0= if
      construct recovery-write operation-not-destructive exit
   then
   c t ar PRESERVATION o path DISPLACED {: content :}
   c id path copy content ar w INTENT-RECORDED ;

: INTENT-OF
   ( SQLITE:connection operation-id MODEL:path intent ^ARENA:arena
     ^JSON:writer -- recovery-write )
   {: c id copy t ar w :}
   c id ar READ-RECOVERY-FOR-OPERATION MATCH option
      some OF construct recovery-write already-recorded ENDOF
      none OF c id copy t ar w NEW-INTENT ENDOF
   ;MATCH ;

: RECORD-RECOVERY-INTENT-IN
   ( SQLITE:connection operation-id MODEL:path ^ARENA:arena ^JSON:writer
     -- recovery-write )
   {: c id copy ar w :}
   c id ar READ-INTENT MATCH option
      none OF construct recovery-write operation-not-found ENDOF
      some OF {: t :} c id copy t ar w INTENT-OF ENDOF
   ;MATCH ;

public

\ Commits a legacy recovery intent, copied to the path given.
: RECORD-RECOVERY-INTENT
   ( journal operation-id MODEL:path ^ARENA:arena -- recovery-write )
   {: j id copy ar :}
   j >CONNECTION {: c :}
   c [: c id copy ar [: RECORD-RECOVERY-INTENT-IN ;] ENCODING ;]
   SQLITE:WITH-TRANSACTION ;

;package
