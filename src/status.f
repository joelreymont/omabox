\ status.f - package STATUS: the daemon's status.json, which the widget
\ reads: $XDG_RUNTIME_DIR/omabox/status.json, schema 3, written as
\ serde_json writes the Rust version's snapshot, 0600 in a 0700
\ directory. A publish writes .status.<pid>.tmp in the directory, new and
\ 0600, and renames it over status.json, which replaces the entry itself:
\ a link there is replaced, never followed. Every change publishes; a
\ publish that fails is logged where it fails, removes its temporary and
\ leaves the snapshot to the next change.
\ The snapshot holds at most one transfer, as one task syncs. A progress
\ sample replaces it; a finish of that transfer keeps it, shown as
\ finished, until the next sample or a change of phase clears it.
\ LOCK guards every snapshot, which the sync task and BEAT share.
\ The heartbeat is one task per process, BEAT, which refreshes
\ updated_at every 20 s from HEARTBEAT-START to HEARTBEAT-STOP.
\ A status DETACHED makes has no file: no change publishes, and its
\ heartbeat neither starts nor stops a task.
\ STORAGE CLASS. CALLER-OWNED: NEW and DETACHED lay the status in the
\ caller's arena, NEW its paths and buffers too, whose release disposes
\ them and closes the directory's descriptor, so HEARTBEAT-STOP precedes
\ that release; an error text a status holds is the caller's, which
\ outlives the status.
\ PROCESS-WIDE: LOCK, BEAT and the cells BEAT reads.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/byte-buffer.f
require src/lib/arena.f
require src/lib/json.f
require src/lib/log.f
require src/lib/task.f
require src/lib/adt/option.f
require src/lib/adt/result.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fd.f
require src/lib/fmt.f
require src/lib/utf8-scalar.f
require src/lib/utf8-lossy.f

package STATUS
public

-100100 constant E-FIRST
-100199 constant E-LAST
-100100 s" XDG_RUNTIME_DIR is not set" ERROR:CODE E-RUNTIME-MISSING
-100101 s" XDG_RUNTIME_DIR must be absolute"
   ERROR:CODE E-RUNTIME-NOT-ABSOLUTE
-100102 s" XDG_RUNTIME_DIR is unavailable"
   ERROR:CODE E-RUNTIME-UNAVAILABLE
-100103 s" a runtime status filesystem operation failed"
   ERROR:CODE E-IO
-100104 s" could not timestamp runtime status" ERROR:CODE E-CLOCK
-100105 s" could not encode runtime status" ERROR:CODE E-SERIALIZE

ENUM phase DERIVE eq
   starting syncing waiting backoff error stopped ;ENUM

ENUM direction DERIVE eq upload download ;ENUM

\ path is relative to the sync root; total is none when unknown.
STRUCTURE transfer
   FIELD direction direction
   FIELD path str
   FIELD done n
   FIELD total option<n>
;STRUCTURE

ENUM event
   VARIANT progress FIELD sample transfer ;VARIANT
   VARIANT finished FIELD sample transfer ;VARIANT
;ENUM

\ anchor is dir open and temp the temporary's name in it; slot's path is
\ shown's bytes, and spare takes a sample's path before it replaces them.
STRUCTURE status OPAQUE DERIVE addr
   FIELD dir str
   FIELD anchor fd
   FIELD temp str
   FIELD now phase
   FIELD slot option<transfer>
   FIELD error option<str>
   FIELD updated n
   FIELD shown ^n
   FIELD spare ^n
   FIELD out ^n
   FIELD writer JSON:writer
   FIELD detached bool
;STRUCTURE

private

3 constant SCHEMA
20000 constant BEAT-MS
256 constant FIRST-CAP
$2F constant SLASH
$1FF constant MODE-BITS
$180 constant MODE-FILE

ARENA STATUSES status

: FILE$ ( -- ^u8 n ) s" status.json" ;

TASK:FACILITY LOCK
LOCK TASK:FACILITY-INIT

TASK:MIN-STACK TASK:TASK BEAT
TYPED-VARIABLE BEATING ^status
variable PERIOD                 \ ms between BEAT's heartbeats
variable BEAT-LIVE              \ main thread's: BEAT is activated


\ ---- failures ------------------------------------------------------

: LOG-OPEN ( -- ) LOG:ERROR s" status" LOG:LINE ;


: REFUSED ( n -- )
   {: code :}
   LOG-OPEN code LOG:CODE+ LOG:;LINE
   code throw ;


\ errno is FS:ERRNO as the failure left it, 0 for none.
: IO-FAILED ( ^u8 n n n -- )
   {: op:^ opu code errno :}
   LOG-OPEN s" could not " LOG:TEXT+ op opu LOG:TEXT+
   s" : " LOG:TEXT+
   errno 0= if code LOG:CODE+ else errno FS:ERRNO$ LOG:TEXT+ then
   LOG:;LINE
   E-IO throw ;


\ Runs io; its failure is the operation op's.
: IO ( [ -- ] ^u8 n -- )
   {: io op:^ opu :}
   FS:CAUSE-CLEAR
   io catch {: code :}
   code 0= if exit then
   op opu code FS:ERRNO IO-FAILED ;


\ ---- paths ---------------------------------------------------------

: ABSOLUTE? ( ^u8 n -- bool )
   {: a:^ u :}
   u 0 > if a c@ SLASH = exit then
   false ;


\ base/name in the arena.
: JOINED ( str ^u8 n ^ARENA:arena -- str )
   {: base:str n:^ nu ar :}
   base str> {: b:^ bu :}
   ar bu nu + 1 + ARENA:ALLOC SPAN:MAKE {: dst :}
   b bu n nu dst FS:JOIN-PATH-INTO {: u :}
   dst SPAN:$ drop u >str ;


\ .status.<pid>.tmp in the arena.
: TEMP-NAME ( ^ARENA:arena -- str )
   {: ar :}
   s" .status." {: h:^ hu :}
   getpid FMT:INT$ {: p:^ pu :}
   s" .tmp" {: t:^ tu :}
   hu pu + tu + {: u :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   h dst hu BYTE-COPY
   p dst hu + pu BYTE-COPY
   t dst hu + pu + tu BYTE-COPY
   dst u >str ;


\ An existing directory is kept, as mkdir's EEXIST for one says.
: MADE ( str -- )
   {: d:str :}
   FS:CAUSE-CLEAR
   [: d str> FS:MODE-PRIVATE-DIR FS:MKDIR-MODE ;] catch {: code :}
   code 0= if exit then
   FS:ERRNO {: errno :}
   errno FS:EEXIST = if d str> FS:DIR? if exit then then
   s" create the runtime status directory" code errno IO-FAILED ;


: PRIVATE-DIR ( str -- )
   {: d:str :}
   d MADE
   [: d str> FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;]
   s" secure the runtime status directory" IO ;


: CLOSED ( fd -- )
   FD>N FS:CLOSE-FD drop ;


\ d open, closed when the arena is released; the cell the release reads
\ is taken before the open, so a refused allocation leaks nothing.
: ANCHORED ( str ^ARENA:arena -- fd )
   {: d:str ar :}
   ar CELL [: CELL-VIEW @ dup 0 < if drop exit then >FD CLOSED ;]
   ARENA:ALLOC-DISPOSE drop CELL-VIEW {: held :}
   -1 held !
   FS:CAUSE-CLEAR
   0 >FD [: drop d str> FS:OPEN-DIR-FOLLOW ;] catch {: f code :}
   code 0= if f FD>N held ! f exit then
   s" open the runtime status directory" code FS:ERRNO IO-FAILED ;


\ ---- the transfer's path -------------------------------------------

\ buf's bytes after the replace, as one str.
: FILLED ( ^u8 n ^n -- str )
   {: a:^ u buf :}
   a u BUF:N>BLEN buf BUF:REPLACE
   buf BUF:SPAN$ BUF:BLEN>N >str ;


: REPAIRED ( ^u8 n ^n ^ARENA:arena -- str )
   {: a:^ u buf ar :}
   a u ar UTF8-LOSSY:REPAIR buf FILLED ;


\ The path as the widget shows it, in buf: an absolute one is never
\ shown, an empty one is the root, and bytes not UTF-8 are repaired.
: DISPLAYED ( str ^n -- str )
   {: p:str buf :}
   p str> {: a:^ u :}
   a u ABSOLUTE? if
      s" (invalid synchronized path)" buf FILLED exit
   then
   u 0= if s" ." buf FILLED exit then
   a u UTF8:VALID? if a u buf FILLED exit then
   a u buf [: REPAIRED ;] ARENA:WITH ;


\ ---- the snapshot --------------------------------------------------

: BUFFER ( ^ARENA:arena -- ^n )
   BUF:HDR-BYTES [: CELL-VIEW BUF:DISPOSE ;] ARENA:ALLOC-DISPOSE
   drop CELL-VIEW
   dup FIRST-CAP BUF:N>BLEN BUF:INIT ;


: NO-SAMPLE ( -- option<transfer> ) OPTION:NONE ;
: NO-TEXT ( -- option<str> ) OPTION:NONE ;


: CLEARED ( ^status -- )
   NO-SAMPLE swap STATUS-SLOT ! ;


: SAME? ( transfer transfer -- bool )
   STATUS-TRANSFER:UNMAKE 2drop {: d:direction p:str :}
   STATUS-TRANSFER:UNMAKE 2drop {: e:direction q:str :}
   d e STATUS-DIRECTION:EQ 0= if false exit then
   p str> q str> STR= ;


: HOLDS? ( transfer ^status -- bool )
   {: t s :}
   s STATUS-SLOT @ MATCH option
      some OF t SAME? ENDOF
      none OF false ENDOF
   ;MATCH ;


\ t as the widget shows it, its path in spare.
: SHOWN ( transfer ^status -- transfer )
   {: t s :}
   t STATUS-TRANSFER:UNMAKE {: d:direction p:str done total :}
   d p s STATUS-SPARE @ DISPLAYED done total
   STATUS-TRANSFER:MAKE ;


\ t, its path in spare, goes to slot; shown's bytes become spare.
: KEPT ( transfer ^status -- )
   {: t s :}
   s STATUS-SHOWN @ s STATUS-SPARE @ {: old new :}
   new s STATUS-SHOWN !
   old s STATUS-SPARE !
   t OPTION:SOME s STATUS-SLOT ! ;


\ Each change answers whether to publish.
: PROGRESSED ( ^status transfer -- bool )
   {: s t :}
   t s SHOWN s KEPT
   true ;


\ A finish of a transfer slot does not hold changes nothing.
: ENDED ( ^status transfer -- bool )
   {: s t :}
   t s SHOWN {: shown :}
   shown s HOLDS? 0= if false exit then
   shown s KEPT
   true ;


: PHASED ( ^status phase -- bool )
   {: s p:phase :}
   s STATUS-NOW @ p STATUS-PHASE:EQ 0= if s CLEARED then
   p s STATUS-NOW !
   true ;


: ERRED ( ^status str phase -- bool )
   {: s text:str p:phase :}
   p s STATUS-NOW !
   s CLEARED
   text OPTION:SOME s STATUS-ERROR !
   true ;


: SYNC-FAILED ( ^status -- bool )
   {: s :}
   construct phase error s STATUS-NOW !
   s" One or more files could not be synchronized." >str
   OPTION:SOME s STATUS-ERROR !
   true ;


: NO-ERROR ( ^status -- bool )
   NO-TEXT swap STATUS-ERROR !
   true ;


\ ---- the JSON ------------------------------------------------------

: PHASE$ ( phase -- ^u8 n )
   MATCH phase
      starting OF s" starting" ENDOF
      syncing OF s" syncing" ENDOF
      waiting OF s" waiting" ENDOF
      backoff OF s" backoff" ENDOF
      error OF s" error" ENDOF
      stopped OF s" stopped" ENDOF
   ;MATCH ;


: DIRECTION$ ( direction -- ^u8 n )
   MATCH direction
      upload OF s" upload" ENDOF
      download OF s" download" ENDOF
   ;MATCH ;


: TOTAL ( ^JSON:writer option<n> -- ^JSON:writer )
   MATCH option
      some OF JSON:WRITE-U ENDOF
      none OF JSON:WRITE-NULL ENDOF
   ;MATCH ;


: SAMPLE ( ^JSON:writer transfer -- ^JSON:writer )
   STATUS-TRANSFER:UNMAKE {: w d:direction p:str done total :}
   w JSON:WRITE-OBJECT-START
   s" direction" d DIRECTION$ JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" path" p str> JSON:WRITE-FIELD-S JSON:WRITE-COMMA
   s" bytes_done" done JSON:WRITE-FIELD-U JSON:WRITE-COMMA
   s" bytes_total" JSON:WRITE-KEY total TOTAL
   JSON:WRITE-OBJECT-END ;


: TRANSFERS ( ^JSON:writer option<transfer> -- ^JSON:writer )
   {: w slot :}
   w JSON:WRITE-ARRAY-START
   slot MATCH option
      some OF SAMPLE ENDOF
      none OF ENDOF
   ;MATCH
   JSON:WRITE-ARRAY-END ;


: LAST-ERROR ( ^JSON:writer option<str> -- ^JSON:writer )
   MATCH option
      some OF str> JSON:WRITE-STRING ENDOF
      none OF JSON:WRITE-NULL ENDOF
   ;MATCH ;


\ serde's field order, compact, into out.
: ENCODE ( ^status -- )
   {: s :}
   s STATUS-WRITER s STATUS-OUT @ JSON:WRITE-OPEN-BUF
   JSON:WRITE-OBJECT-START
   s" version" SCHEMA JSON:WRITE-FIELD-U JSON:WRITE-COMMA
   s" phase" s STATUS-NOW @ PHASE$ JSON:WRITE-FIELD-S
   JSON:WRITE-COMMA
   s" transfers" JSON:WRITE-KEY s STATUS-SLOT @ TRANSFERS
   JSON:WRITE-COMMA
   s" last_error" JSON:WRITE-KEY s STATUS-ERROR @ LAST-ERROR
   JSON:WRITE-COMMA
   s" updated_at" s STATUS-UPDATED @ JSON:WRITE-FIELD-U
   JSON:WRITE-OBJECT-END JSON:WRITE-CLOSE ;


\ ---- publishing ----------------------------------------------------

: STAMPED ( ^status -- )
   {: s :}
   epoch-seconds {: t :}
   t 0 < if
      LOG-OPEN s" could not timestamp runtime status: the clock reads "
      LOG:TEXT+ t LOG:INT+ LOG:;LINE
      E-CLOCK throw
   then
   t s STATUS-UPDATED ! ;


: ENCODED ( ^status -- ^u8 n )
   {: s :}
   [: s ENCODE ;] catch {: code :}
   code 0<> if
      LOG-OPEN s" could not encode runtime status: " LOG:TEXT+
      code LOG:CODE+ LOG:;LINE
      E-SERIALIZE throw
   then
   s STATUS-OUT @ BUF:SPAN$ BUF:BLEN>N ;


\ The temporary removed, an absent one included. Another failure is only
\ logged: the caller's own failure, or the create's EEXIST, is what throws.
: SWEPT ( ^status -- )
   {: s :}
   s STATUS-ANCHOR @ s STATUS-TEMP @ str> FS:TRY-REMOVE-FILE-AT
   if exit then
   FS:ERRNO {: errno :}
   errno FS:ENOENT = if exit then
   LOG:WARN s" status" LOG:LINE
   s" could not remove a temporary runtime status file: " LOG:TEXT+
   errno FS:ERRNO$ LOG:TEXT+ LOG:;LINE ;


\ The temporary removed, then the failure of op.
: DISCARDED ( ^status ^u8 n n n -- )
   {: s op:^ opu code errno :}
   s SWEPT
   op opu code errno IO-FAILED ;


\ The temporary, a new unnamed 0600 file in the directory, open.
: CREATED ( ^status -- fd )
   {: s :}
   s SWEPT
   FS:CAUSE-CLEAR
   0 >FD [: drop s STATUS-ANCHOR @ FS:TEMP-AT ;] catch {: f code :}
   code 0= if f exit then
   s" create the temporary status file" code FS:ERRNO IO-FAILED ;


\ Runs io on the unnamed f; its failure closes f and is op's.
: STAGED ( fd [ -- ] ^u8 n -- )
   {: f:fd io op:^ opu :}
   FS:CAUSE-CLEAR
   io catch {: code :}
   code 0= if exit then
   FS:ERRNO {: errno :}
   f CLOSED
   op opu code errno IO-FAILED ;


: WRITTEN ( fd ^u8 n -- )
   {: f:fd a:^ u :}
   f [: f MODE-FILE FD:MODE! ;]
   s" secure the temporary status file" STAGED
   f [: f a u FD:WRITE-FULL ;]
   s" write the temporary status file" STAGED ;


\ A failed close is not reported, as Rust's drop of a File does not.
: NAMED ( ^status fd -- )
   {: s f:fd :}
   f s STATUS-ANCHOR @ s STATUS-TEMP @ str> FS:TRY-LINK-AT {: linked :}
   FS:ERRNO {: errno :}
   f CLOSED
   linked if exit then
   s" create the temporary status file" E-IO errno IO-FAILED ;


: REPLACED ( ^status -- )
   {: s :}
   s STATUS-ANCHOR @ {: dir:fd :}
   dir s STATUS-TEMP @ str> dir FILE$ FS:TRY-RENAME-AT
   if exit then
   s s" replace the status file" E-IO FS:ERRNO DISCARDED ;


: PUBLISH ( ^status -- )
   {: s :}
   s STAMPED
   s ENCODED {: a:^ u :}
   s CREATED {: f:fd :}
   f a u WRITTEN
   s f NAMED
   s REPLACED ;


: LOGGED? ( n -- bool )
   {: code :}
   code E-IO = code E-CLOCK = or code E-SERIALIZE = or ;


\ A failure PUBLISH logged ends here; any other throw passes.
: REPUBLISHED ( ^status -- )
   {: s :}
   [: s PUBLISH ;] catch {: code :}
   code LOGGED? if exit then
   code 0<> if code throw then ;


: CHANGED ( ^status [ ^status -- bool ] -- )
   {: s change :}
   s change execute if s REPUBLISHED then ;


: LOCKED ( ^status [ ^status -- ] -- )
   {: s q :}
   LOCK TASK:GET
   [: s q execute ;] [: LOCK TASK:RELEASE ;] finally ;


: UPDATE ( ^status [ ^status -- bool ] -- )
   {: s change :}
   s STATUS-DETACHED @ if exit then
   s [: change CHANGED ;] LOCKED ;


public

\ ---- a status ------------------------------------------------------

\ Under runtime, an absolute path to a directory.
: NEW ( str ^ARENA:arena -- ^status )
   {: runtime:str ar :}
   runtime str> ABSOLUTE? 0= if E-RUNTIME-NOT-ABSOLUTE REFUSED then
   runtime str> FS:DIR? 0= if E-RUNTIME-UNAVAILABLE REFUSED then
   ar STATUSES-NEW {: s :}
   runtime s" omabox" ar JOINED s STATUS-DIR !
   s STATUS-DIR @ PRIVATE-DIR
   s STATUS-DIR @ ar ANCHORED s STATUS-ANCHOR !
   ar TEMP-NAME s STATUS-TEMP !
   ar BUFFER s STATUS-SHOWN !
   ar BUFFER s STATUS-SPARE !
   ar BUFFER s STATUS-OUT !
   construct phase starting s STATUS-NOW !
   s CLEARED
   NO-TEXT s STATUS-ERROR !
   s [: PUBLISH ;] LOCKED
   s ;


: FROM-ENVIRONMENT ( ^ARENA:arena -- ^status )
   {: ar :}
   s" XDG_RUNTIME_DIR" GETENV {: v:^ vu :}
   v NULL-PTR = if E-RUNTIME-MISSING REFUSED then
   v vu >str ar NEW ;


\ A status that writes nothing, for a daemon with no runtime directory.
: DETACHED ( ^ARENA:arena -- ^status )
   STATUSES-NEW {: s :}
   true s STATUS-DETACHED !
   construct phase starting s STATUS-NOW !
   s CLEARED
   NO-TEXT s STATUS-ERROR !
   s ;


: PHASE ( phase ^status -- )
   {: p:phase s :}
   s [: p PHASED ;] UPDATE ;


\ Refreshes updated_at alone.
: HEARTBEAT ( ^status -- )
   [: drop true ;] UPDATE ;


\ text is a fixed summary, never a path or a token.
: ERROR ( str ^status -- )
   {: text:str s :}
   s [: text construct phase error ERRED ;] UPDATE ;


\ The daemon exits after a failure it does not retry.
: STOPPED ( str ^status -- )
   {: text:str s :}
   s [: text construct phase stopped ERRED ;] UPDATE ;


\ Only after a clean reconciliation pass.
: CLEAR-ERROR ( ^status -- )
   [: NO-ERROR ;] UPDATE ;


\ A path failed to sync; the transfer stays.
: SYNC-ERROR ( ^status -- )
   [: SYNC-FAILED ;] UPDATE ;


\ What a blocking upload or download reports.
: TRANSFER ( event ^status -- )
   {: e s :}
   e MATCH event
      progress OF {: t :} s [: t PROGRESSED ;] UPDATE ENDOF
      finished OF {: t :} s [: t ENDED ;] UPDATE ENDOF
   ;MATCH ;

private

\ ---- the heartbeat -------------------------------------------------

\ A halt is served between heartbeats, after an answer JOIN reads as a
\ clean stop.
: BEAT-BODY ( -- )
   BEATING @ {: s :}
   PERIOD @ >MS {: wait:ms :}
   begin
      wait TASK:WAIT-MS
      TASK:HALT-DUE? if 0 TASK:RETURN TASK:PAUSE then
      0= if s HEARTBEAT then
   again ;


\ ms is the period. A start before HEARTBEAT-STOP has ended the last
\ one is E-TASK-STATE.
: HEARTBEAT-EVERY ( n ^status -- )
   {: ms s :}
   BEAT-LIVE @ 0<> if E-TASK-STATE throw then
   s BEATING !
   ms PERIOD !
   [: ['] BEAT-BODY BEAT TASK:ACTIVATE ;] catch {: code :}
   code 0<> if
      LOG-OPEN s" could not start the runtime status heartbeat: "
      LOG:TEXT+ code LOG:CODE+ LOG:;LINE
      code throw
   then
   1 BEAT-LIVE ! ;

public

: HEARTBEAT-START ( ^status -- )
   {: s :}
   s STATUS-DETACHED @ if exit then
   BEAT-MS s HEARTBEAT-EVERY ;


\ Ends BEAT and waits for it; what ended it otherwise is rethrown. A
\ status BEAT does not refresh is E-TASK-STATE.
: HEARTBEAT-STOP ( ^status -- )
   {: s :}
   s STATUS-DETACHED @ if exit then
   BEAT-LIVE @ 0= if E-TASK-STATE throw then
   BEATING @ s - 0<> if E-TASK-STATE throw then
   0 BEAT-LIVE !
   BEAT TASK:HALT
   BEAT TASK:JOIN MATCH result
      ok OF drop ENDOF
      err OF throw ENDOF
   ;MATCH ;

;package
