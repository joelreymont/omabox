\ model.f - package MODEL: the sync planner's values (docs/habu-rewrite.md
\ "Values"): a display path and its Dropbox identity, what each side holds
\ at a path, the last state both agreed on, and the planner's operations,
\ conflicts and decisions, with their equality and display text, the
\ records the journal and the local scan share, and the stored values'
\ JSON, written byte for byte as the Rust version's serde_json writes it
\ and read as serde_json reads any value either version stored. A reader
\ refuses a struct written as an array, a variant with no payload written
\ as an object and a skipped member holding a lone surrogate escape: serde
\ reads them and no writer makes them. The writers give serde_json's bytes
\ only on a compact writer that does not escape non-ASCII.
\ FOLD is Rust's CanonicalPath::from_display over Path::iter: a path that
\ starts with "/" yields the root, else one that starts with "." then "/" or
\ its end yields ".", and the components after it skip empty and "." ones.
\ Each component is lowered in full when it is UTF-8, else byte by byte as
\ ASCII, and they are joined as PathBuf::push joins them: a "/" before each
\ but when the path so far is empty or the root.
\ Equality reads the bytes of every string a value holds. Two values of a
\ family are equal when their forms are: the variant's number, an unknown
\ observation's 3 plus its reason's, then the strings it holds, each in a
\ fixed place, empty where it holds none. Records compare field by field.
\ STORAGE CLASS. CALLER-OWNED: a value travels by value and its strings are
\ borrowed; FOLD lays its answer, and a JSON reader the strings it reads,
\ in the arena the caller passes. A JSON writer appends to the caller's
\ open JSON writer.

require src/lib/type/deftype.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/unicode.f
require src/lib/utf8-scalar.f
require src/lib/error.f
require src/lib/json.f
require src/dropbox.f

package MODEL
public

-100400 constant E-FIRST
-100499 constant E-LAST
-100400 s" a stored value does not read as this version's"
   ERROR:CODE E-STORED

\ A display path, relative to the sync root.
DEFTYPE PATH str
\ A display path's Dropbox identity, FOLD's answer.
DEFTYPE KEY str

STRUCTURE local FIELD content DROPBOX:hash ;STRUCTURE

STRUCTURE remote
   FIELD content DROPBOX:hash
   FIELD rev DROPBOX:rev
;STRUCTURE

\ The last state both sides agreed on at a path.
ENUM baseline
   VARIANT absent ;VARIANT
   VARIANT present FIELD file remote ;VARIANT
   VARIANT directory ;VARIANT
;ENUM

\ Why an observation proves neither presence nor absence.
ENUM unknown-reason
   incomplete inaccessible unavailable stale cursor-reset unsupported
;ENUM

\ What one side holds at a path; absent is a complete observation's.
ENUM observation<a>
   VARIANT present FIELD file a ;VARIANT
   VARIANT directory ;VARIANT
   VARIANT absent ;VARIANT
   VARIANT unknown FIELD why unknown-reason ;VARIANT
;ENUM

\ What Dropbox's inventory holds beneath a path.
ENUM subtree empty occupied ;ENUM

\ preserve-local and preserve-remote are read from old journals only.
ENUM operation
   VARIANT create-local-directory ;VARIANT
   VARIANT create-remote-directory ;VARIANT
   VARIANT delete-local-directory ;VARIANT
   VARIANT delete-remote-directory ;VARIANT
   VARIANT create-remote FIELD content DROPBOX:hash ;VARIANT
   VARIANT install-local FIELD source remote ;VARIANT
   VARIANT preserve-local FIELD file local ;VARIANT
   VARIANT replace-local
      FIELD source remote FIELD expected-content DROPBOX:hash ;VARIANT
   VARIANT delete-local FIELD expected-content DROPBOX:hash ;VARIANT
   VARIANT preserve-remote FIELD file remote ;VARIANT
   VARIANT replace-remote
      FIELD content DROPBOX:hash FIELD expected-rev DROPBOX:rev ;VARIANT
   VARIANT delete-remote FIELD expected-rev DROPBOX:rev ;VARIANT
;ENUM

ENUM conflict
   VARIANT initial FIELD local local FIELD remote remote ;VARIANT
   VARIANT divergent FIELD local local FIELD remote remote ;VARIANT
   VARIANT local-deleted FIELD remote remote ;VARIANT
   VARIANT remote-deleted FIELD local local ;VARIANT
;ENUM

\ A blocked path: an observation is unknown, or the remote directory a
\ local deletion would remove still holds entries.
ENUM blocked-reason unknown occupied ;ENUM

\ A file where the other side holds a directory, which wins.
ENUM collision
   VARIANT local-file FIELD local local ;VARIANT
   VARIANT local-dir FIELD remote remote ;VARIANT
;ENUM

\ What identifies the bytes a local scan hashed: the file's inode and size,
\ and its modification and status change times.
STRUCTURE fingerprint
   FIELD inode n
   FIELD size n
   FIELD modified-seconds n
   FIELD modified-nanoseconds n
   FIELD changed-seconds n
   FIELD changed-nanoseconds n
;STRUCTURE

\ A verified content hash a complete local scan may reuse.
STRUCTURE hash-record
   FIELD path path
   FIELD fingerprint fingerprint
   FIELD content DROPBOX:hash
;STRUCTURE

STRUCTURE local-record
   FIELD path path
   FIELD observation observation<local>
;STRUCTURE

STRUCTURE remote-record
   FIELD key key
   FIELD path path
   FIELD observation observation<remote>
;STRUCTURE

STRUCTURE baseline-record
   FIELD key key
   FIELD path path
   FIELD baseline baseline
;STRUCTURE

\ Why a path waits until its cause is retried or cleared (`block-` is an
\ atom prefix, no family's name); error-tag is Dropbox's, status HTTP's.
ENUM blockage
   VARIANT unsupported-file-size ;VARIANT
   VARIANT remote-rejected FIELD error-tag str ;VARIANT
   VARIANT download-unavailable FIELD status u16 ;VARIANT
   VARIANT download-verification-failed ;VARIANT
   VARIANT stage-occupied ;VARIANT
   VARIANT local-object-in-way ;VARIANT
   VARIANT remote-object ;VARIANT
   VARIANT conflict-copy-occupied ;VARIANT
;ENUM

ENUM decision
   VARIANT noop FIELD baseline baseline ;VARIANT
   VARIANT operate FIELD operation operation ;VARIANT
   VARIANT blocked FIELD reason blocked-reason ;VARIANT
   VARIANT conflicted FIELD conflict conflict ;VARIANT
   VARIANT collided FIELD collision collision ;VARIANT
;ENUM

private

$2F constant SLASH
$2E constant DOT

: ROOT? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 0 > if p c@ SLASH = exit then
   false ;

: CURRENT? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 0= if false exit then
   p c@ DOT <> if false exit then
   u 1 = if true exit then
   p 1+ c@ SLASH = ;

\ The bytes of the root or the leading "." a path starts with.
: LEAD ( ^u8 n -- n )
   2dup ROOT? if 2drop 1 exit then
   CURRENT? if 1 exit then
   0 ;

: PART? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 1 = if p c@ DOT <> exit then
   u 0 > ;

\ A separator goes before a component after `len` bytes but the root.
: SEP? ( n bool -- bool )
   if 1 else 0 then > ;

: LOWERED-BYTES ( ^u8 n -- n )
   2dup UTF8:VALID? if UNICODE:LOWERED-BYTES exit then
   nip ;

: LOWER-INTO ( ^u8 n ^u8 n -- n )
   {: p:^ u:n dst:^ cap:n :}
   p u UTF8:VALID? if p u dst cap UNICODE:LOWER exit then
   u 0 ?do p i + c@ ASCII-LOWER dst i + c! loop
   u ;

\ The bytes a component adds after `len`.
: ADD-SIZE ( n bool ^u8 n -- n )
   {: len:n root:bool p:^ u:n :}
   p u PART? 0= if len exit then
   len len root SEP? if 1+ then
   p u LOWERED-BYTES + ;

\ Writes a component after `len` of `size` bytes at `dst`.
: ADD-BYTES ( n bool ^u8 n ^u8 n -- n )
   {: len:n root:bool p:^ u:n dst:^ size:n :}
   p u PART? 0= if len exit then
   len root SEP? if SLASH dst len + c! len 1+ else len then
   {: at:n :}
   p u dst at + size at - LOWER-INTO at + ;

\ Runs ADD on the component at `at`; false past the last.
: STEP ( ^u8 n bool n n [ n bool ^u8 n -- n ] -- n n bool )
   {: p:^ u:n root:bool len:n at:n add :}
   p u SLASH at SPLIT-NEXT 0= if 2drop drop len at false exit then
   {: next:n :}
   len root 2swap add execute next true ;

\ Runs ADD over every component, from the lead's bytes on.
: PARTS ( ^u8 n [ n bool ^u8 n -- n ] -- n )
   {: p:^ u:n add :}
   p u ROOT? {: root:bool :}
   p u LEAD 0
   begin 2>r p u root 2r> add STEP 0= until
   drop ;

: BYTES ( key -- ^u8 n ) KEY>STR str> ;

\ The key's bytes then one byte, laid in the arena.
: EXTENDED ( key u8 ^ARENA:arena -- str )
   {: k:key b:u8 ar:^ARENA:arena :}
   k BYTES {: p:^ u:n :}
   ar u 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst u BYTE-COPY
   b dst u + c!
   dst u 1+ >str ;

: PATH= ( path path -- bool )
   {: a:path b:path :}
   a PATH>STR str> b PATH>STR str> STR= ;

\ A value's variant and the strings it holds, empty where it holds none.
STRUCTURE form
   FIELD kind n
   FIELD one str
   FIELD two str
   FIELD three str
;STRUCTURE

: NONE ( -- str ) s" " >str ;

: FORM= ( form form -- bool )
   {: a:form b:form :}
   a FORM-UNMAKE {: v:n x:str y:str z:str :}
   b FORM-UNMAKE {: w:n x2:str y2:str z2:str :}
   v w <> if false exit then
   x str> x2 str> STR= 0= if false exit then
   y str> y2 str> STR= 0= if false exit then
   z str> z2 str> STR= ;

: LOCAL-FORM ( n local -- form )
   MODEL-LOCAL:UNMAKE DROPBOX:HASH>STR NONE NONE FORM-MAKE ;

: REMOTE-FORM ( n remote -- form )
   MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :}
   c DROPBOX:HASH>STR NONE r DROPBOX:REV>STR FORM-MAKE ;

: EMPTY-FORM ( n -- form ) NONE NONE NONE FORM-MAKE ;

: BASELINE-FORM ( baseline -- form )
   MATCH baseline
      absent OF 0 EMPTY-FORM ENDOF
      present OF 1 swap REMOTE-FORM ENDOF
      directory OF 2 EMPTY-FORM ENDOF
   ;MATCH ;

: HASH-FORM ( n DROPBOX:hash -- form )
   DROPBOX:HASH>STR NONE NONE FORM-MAKE ;

: REV-FORM ( n DROPBOX:rev -- form )
   {: v:n r:DROPBOX:rev :}
   v NONE NONE r DROPBOX:REV>STR FORM-MAKE ;

\ A remote's content and revision, then the content it expects.
: REPLACE-FORM ( n remote DROPBOX:hash -- form )
   {: v:n s:remote e:DROPBOX:hash :}
   s MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :}
   v c DROPBOX:HASH>STR e DROPBOX:HASH>STR r DROPBOX:REV>STR FORM-MAKE ;

: CONTENT-REV-FORM ( n DROPBOX:hash DROPBOX:rev -- form )
   {: v:n c:DROPBOX:hash r:DROPBOX:rev :}
   v c DROPBOX:HASH>STR NONE r DROPBOX:REV>STR FORM-MAKE ;

: OPERATION-FORM ( operation -- form )
   MATCH operation
      create-local-directory OF 0 EMPTY-FORM ENDOF
      create-remote-directory OF 1 EMPTY-FORM ENDOF
      delete-local-directory OF 2 EMPTY-FORM ENDOF
      delete-remote-directory OF 3 EMPTY-FORM ENDOF
      create-remote OF 4 swap HASH-FORM ENDOF
      install-local OF 5 swap REMOTE-FORM ENDOF
      preserve-local OF 6 swap LOCAL-FORM ENDOF
      replace-local OF {: s e :} 7 s e REPLACE-FORM ENDOF
      delete-local OF 8 swap HASH-FORM ENDOF
      preserve-remote OF 9 swap REMOTE-FORM ENDOF
      replace-remote OF {: c r :} 10 c r CONTENT-REV-FORM ENDOF
      delete-remote OF 11 swap REV-FORM ENDOF
   ;MATCH ;

\ A local's content, then a remote's content and revision.
: PAIR-FORM ( n local remote -- form )
   {: v:n l:local s:remote :}
   l MODEL-LOCAL:UNMAKE DROPBOX:HASH>STR {: lc:str :}
   s MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :}
   v lc c DROPBOX:HASH>STR r DROPBOX:REV>STR FORM-MAKE ;

: CONFLICT-FORM ( conflict -- form )
   MATCH conflict
      initial OF {: l s :} 0 l s PAIR-FORM ENDOF
      divergent OF {: l s :} 1 l s PAIR-FORM ENDOF
      local-deleted OF 2 swap REMOTE-FORM ENDOF
      remote-deleted OF 3 swap LOCAL-FORM ENDOF
   ;MATCH ;

: BLOCKED-FORM ( blocked-reason -- form )
   MATCH blocked-reason
      unknown OF 0 ENDOF
      occupied OF 1 ENDOF
   ;MATCH EMPTY-FORM ;

: COLLISION-FORM ( collision -- form )
   MATCH collision
      local-file OF 0 swap LOCAL-FORM ENDOF
      local-dir OF 1 swap REMOTE-FORM ENDOF
   ;MATCH ;

: REASON-INDEX ( unknown-reason -- n )
   MATCH unknown-reason
      incomplete OF 0 ENDOF
      inaccessible OF 1 ENDOF
      unavailable OF 2 ENDOF
      stale OF 3 ENDOF
      cursor-reset OF 4 ENDOF
      unsupported OF 5 ENDOF
   ;MATCH ;

: UNKNOWN-FORM ( unknown-reason -- form ) REASON-INDEX 3 + EMPTY-FORM ;

: LOCAL-OBSERVATION-FORM ( observation<local> -- form )
   MATCH observation
      present OF 0 swap LOCAL-FORM ENDOF
      directory OF 1 EMPTY-FORM ENDOF
      absent OF 2 EMPTY-FORM ENDOF
      unknown OF UNKNOWN-FORM ENDOF
   ;MATCH ;

: REMOTE-OBSERVATION-FORM ( observation<remote> -- form )
   MATCH observation
      present OF 0 swap REMOTE-FORM ENDOF
      directory OF 1 EMPTY-FORM ENDOF
      absent OF 2 EMPTY-FORM ENDOF
      unknown OF UNKNOWN-FORM ENDOF
   ;MATCH ;

\ A decision's variant and its payload's form.
: DECISION-FORM ( decision -- n form )
   MATCH decision
      noop OF 0 swap BASELINE-FORM ENDOF
      operate OF 1 swap OPERATION-FORM ENDOF
      blocked OF 2 swap BLOCKED-FORM ENDOF
      conflicted OF 3 swap CONFLICT-FORM ENDOF
      collided OF 4 swap COLLISION-FORM ENDOF
   ;MATCH ;

public

\ The display path's Dropbox identity, its bytes in ARENA.
: FOLD ( path ^ARENA:arena -- key )
   {: path:path ar:^ARENA:arena :}
   path PATH>STR str> {: p:^ u:n :}
   p u [: ADD-SIZE ;] PARTS {: size:n :}
   ar size ARENA:ALLOC drop {: dst:^ :}
   p dst p u LEAD BYTE-COPY
   p u [: dst size ADD-BYTES ;] PARTS drop
   dst size >str >KEY ;

\ Below zero, zero or above zero as the first key's bytes sort before,
\ equal or after the second's.
: KEY-CMP ( key key -- n )
   {: a:key b:key :}
   a BYTES b BYTES STR= if 0 exit then
   a BYTES b BYTES STR< if -1 exit then
   1 ;

: KEY= ( key key -- bool ) {: a:key b:key :} a BYTES b BYTES STR= ;

\ True when the first key is strictly beneath the second.
: BENEATH? ( key key -- bool )
   {: k:key top:key :}
   k BYTES {: p:^ u:n :}
   top BYTES {: q:^ v:n :}
   u v <= if false exit then
   p v q v STR= 0= if false exit then
   p v + c@ SLASH = ;

\ The half-open byte range from the key then "/" to the key then the
\ byte after "/": it holds exactly the keys BENEATH? accepts, a child
\ whose name starts with 0xFF among them.
: SUBTREE-RANGE ( key ^ARENA:arena -- str str )
   {: k:key ar:^ARENA:arena :}
   k SLASH ar EXTENDED k SLASH 1+ ar EXTENDED ;

: LOCAL= ( local local -- bool )
   {: a:local b:local :}
   0 a LOCAL-FORM 0 b LOCAL-FORM FORM= ;

: REMOTE= ( remote remote -- bool )
   {: a:remote b:remote :}
   0 a REMOTE-FORM 0 b REMOTE-FORM FORM= ;

: BASELINE= ( baseline baseline -- bool )
   {: a:baseline b:baseline :}
   a BASELINE-FORM b BASELINE-FORM FORM= ;

: OPERATION= ( operation operation -- bool )
   {: a:operation b:operation :}
   a OPERATION-FORM b OPERATION-FORM FORM= ;

: CONFLICT= ( conflict conflict -- bool )
   {: a:conflict b:conflict :}
   a CONFLICT-FORM b CONFLICT-FORM FORM= ;

: DECISION= ( decision decision -- bool )
   {: a:decision b:decision :}
   a DECISION-FORM {: v:n x:form :}
   b DECISION-FORM {: w:n y:form :}
   v w = if x y FORM= exit then
   false ;

: LOCAL-OBSERVATION= ( observation<local> observation<local> -- bool )
   {: a:observation<local> b:observation<local> :}
   a LOCAL-OBSERVATION-FORM b LOCAL-OBSERVATION-FORM FORM= ;

: REMOTE-OBSERVATION= ( observation<remote> observation<remote> -- bool )
   {: a:observation<remote> b:observation<remote> :}
   a REMOTE-OBSERVATION-FORM b REMOTE-OBSERVATION-FORM FORM= ;

: FINGERPRINT= ( fingerprint fingerprint -- bool )
   {: a:fingerprint b:fingerprint :}
   a MODEL-FINGERPRINT:UNMAKE {: i:n s:n ms:n mn:n cs:n cn:n :}
   b MODEL-FINGERPRINT:UNMAKE {: i2:n s2:n ms2:n mn2:n cs2:n cn2:n :}
   i i2 = s s2 = and ms ms2 = and
   mn mn2 = and cs cs2 = and cn cn2 = and ;

: LOCAL-RECORD= ( local-record local-record -- bool )
   {: a:local-record b:local-record :}
   a MODEL-LOCAL--RECORD:UNMAKE {: p:path o:observation<local> :}
   b MODEL-LOCAL--RECORD:UNMAKE {: q:path o2:observation<local> :}
   p q PATH= o o2 LOCAL-OBSERVATION= and ;

: HASH-RECORD= ( hash-record hash-record -- bool )
   {: a:hash-record b:hash-record :}
   a MODEL-HASH--RECORD:UNMAKE {: p:path f:fingerprint c:DROPBOX:hash :}
   b MODEL-HASH--RECORD:UNMAKE {: q:path g:fingerprint d:DROPBOX:hash :}
   p q PATH= f g FINGERPRINT= and c d DROPBOX:HASH= and ;

: REMOTE-RECORD= ( remote-record remote-record -- bool )
   {: a:remote-record b:remote-record :}
   a MODEL-REMOTE--RECORD:UNMAKE {: k:key p:path o:observation<remote> :}
   b MODEL-REMOTE--RECORD:UNMAKE {: k2:key q:path o2:observation<remote> :}
   k k2 KEY= p q PATH= and o o2 REMOTE-OBSERVATION= and ;

: UNKNOWN$ ( unknown-reason -- str )
   MATCH unknown-reason
      incomplete OF s" observation is incomplete" ENDOF
      inaccessible OF s" path is inaccessible" ENDOF
      unavailable OF s" source is unavailable" ENDOF
      stale OF s" inventory is stale" ENDOF
      cursor-reset OF s" remote cursor was reset" ENDOF
      unsupported OF s" object is unsupported" ENDOF
   ;MATCH >str ;

public

: OPERATION$ ( operation -- str )
   MATCH operation
      create-local-directory OF
         s" create local directory if still absent" ENDOF
      create-remote-directory OF
         s" create remote directory if still absent" ENDOF
      delete-local-directory OF s" delete empty local directory" ENDOF
      delete-remote-directory OF s" delete empty remote directory" ENDOF
      create-remote OF drop s" create remote file if still absent" ENDOF
      install-local OF drop s" install remote content locally" ENDOF
      preserve-local OF drop s" preserve displaced local payload" ENDOF
      replace-local OF 2drop s" replace local content" ENDOF
      delete-local OF drop s" delete local file" ENDOF
      preserve-remote OF drop s" preserve displaced remote payload" ENDOF
      replace-remote OF 2drop
         s" replace remote content if the expected revision still matches"
      ENDOF
      delete-remote OF drop
         s" delete remote file if the expected revision still matches"
      ENDOF
   ;MATCH >str ;

: CONFLICT$ ( conflict -- str )
   MATCH conflict
      initial OF 2drop
         s" different local and remote payloads were introduced; preserve both payloads"
      ENDOF
      divergent OF 2drop
         s" local and remote payloads diverged; preserve both payloads"
      ENDOF
      local-deleted OF drop
         s" local deletion conflicts with a remote edit; preserve the remote payload"
      ENDOF
      remote-deleted OF drop
         s" remote deletion conflicts with a local edit; preserve the local payload"
      ENDOF
   ;MATCH >str ;

\ ---- JSON

private

\ The names Rust gives a family's variants, by index; empty past them.
: BASELINE-NAME ( n -- ^u8 n )
   case
      0 of s" Absent" endof
      1 of s" Present" endof
      2 of s" Directory" endof
      s" " rot
   endcase ;

: REASON-NAME ( n -- ^u8 n )
   case
      0 of s" Incomplete" endof
      1 of s" Inaccessible" endof
      2 of s" Unavailable" endof
      3 of s" Stale" endof
      4 of s" CursorReset" endof
      5 of s" Unsupported" endof
      s" " rot
   endcase ;

: OBSERVATION-NAME ( n -- ^u8 n )
   case
      0 of s" Present" endof
      1 of s" Directory" endof
      2 of s" ConfirmedAbsent" endof
      3 of s" Unknown" endof
      s" " rot
   endcase ;

: OPERATION-NAME ( n -- ^u8 n )
   case
      0 of s" CreateLocalDirectory" endof
      1 of s" CreateRemoteDirectory" endof
      2 of s" DeleteLocalDirectory" endof
      3 of s" DeleteRemoteDirectory" endof
      4 of s" CreateRemote" endof
      5 of s" InstallLocal" endof
      6 of s" PreserveLocal" endof
      7 of s" ReplaceLocal" endof
      8 of s" DeleteLocal" endof
      9 of s" PreserveRemote" endof
      10 of s" ReplaceRemote" endof
      11 of s" DeleteRemote" endof
      s" " rot
   endcase ;

: CONFLICT-NAME ( n -- ^u8 n )
   case
      0 of s" InitialCollision" endof
      1 of s" DivergentEdits" endof
      2 of s" LocalDeletionRemoteEdit" endof
      3 of s" RemoteDeletionLocalEdit" endof
      s" " rot
   endcase ;

: BLOCKAGE-NAME ( n -- ^u8 n )
   case
      0 of s" UnsupportedFileSize" endof
      1 of s" RemoteRejected" endof
      2 of s" DownloadUnavailable" endof
      3 of s" DownloadVerificationFailed" endof
      4 of s" StageOccupied" endof
      5 of s" LocalObjectInWay" endof
      6 of s" RemoteObject" endof
      7 of s" ConflictCopyOccupied" endof
      s" " rot
   endcase ;

: >REASON ( n -- unknown-reason )
   case
      0 of MODEL-UNKNOWN--REASON:incomplete endof
      1 of MODEL-UNKNOWN--REASON:inaccessible endof
      2 of MODEL-UNKNOWN--REASON:unavailable endof
      3 of MODEL-UNKNOWN--REASON:stale endof
      4 of MODEL-UNKNOWN--REASON:cursor-reset endof
      MODEL-UNKNOWN--REASON:unsupported swap
   endcase ;

\ The next member's key, after a comma unless it is the first.
: KEY+ ( ^JSON:writer ^u8 n -- ^JSON:writer )
   {: a:^ u:n :}
   JSON:WRITE-COMMA a u JSON:WRITE-KEY ;

\ Opens a variant written with its payload, `{"Name":`; an object end
\ closes it.
: TAGGED+ ( ^JSON:writer ^u8 n -- ^JSON:writer )
   {: a:^ u:n :}
   JSON:WRITE-OBJECT-START a u JSON:WRITE-KEY ;

\ Opens a struct variant, `{"Name":{`; ;FIELDS+ closes it.
: FIELDS+ ( ^JSON:writer ^u8 n -- ^JSON:writer )
   TAGGED+ JSON:WRITE-OBJECT-START ;

: ;FIELDS+ ( ^JSON:writer -- ^JSON:writer )
   JSON:WRITE-OBJECT-END JSON:WRITE-OBJECT-END ;

public

: HASH>JSON ( DROPBOX:hash ^JSON:writer -- ^JSON:writer )
   {: h:DROPBOX:hash w :}
   w h DROPBOX:HASH>STR str> JSON:WRITE-STRING ;

: REV>JSON ( DROPBOX:rev ^JSON:writer -- ^JSON:writer )
   {: r:DROPBOX:rev w :}
   w r DROPBOX:REV>STR str> JSON:WRITE-STRING ;

: LOCAL>JSON ( local ^JSON:writer -- ^JSON:writer )
   {: v:local w :}
   w JSON:WRITE-OBJECT-START
   s" content" KEY+ v MODEL-LOCAL:UNMAKE swap HASH>JSON
   JSON:WRITE-OBJECT-END ;

: REMOTE>JSON ( remote ^JSON:writer -- ^JSON:writer )
   {: v:remote w :}
   v MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash r:DROPBOX:rev :}
   w JSON:WRITE-OBJECT-START
   s" content" KEY+ c swap HASH>JSON
   s" revision" KEY+ r swap REV>JSON
   JSON:WRITE-OBJECT-END ;

: BASELINE>JSON ( baseline ^JSON:writer -- ^JSON:writer )
   {: v:baseline w :}
   v MATCH baseline
      absent OF w 0 BASELINE-NAME JSON:WRITE-STRING ENDOF
      present OF w 1 BASELINE-NAME TAGGED+ REMOTE>JSON
         JSON:WRITE-OBJECT-END ENDOF
      directory OF w 2 BASELINE-NAME JSON:WRITE-STRING ENDOF
   ;MATCH ;

: UNKNOWN-REASON>JSON ( unknown-reason ^JSON:writer -- ^JSON:writer )
   swap REASON-INDEX REASON-NAME JSON:WRITE-STRING ;

private

\ An observation's variants but present, the same for either side.
: UNKNOWN+ ( unknown-reason ^JSON:writer -- ^JSON:writer )
   3 OBSERVATION-NAME TAGGED+ UNKNOWN-REASON>JSON
   JSON:WRITE-OBJECT-END ;

: DIRECTORY+ ( ^JSON:writer -- ^JSON:writer )
   1 OBSERVATION-NAME JSON:WRITE-STRING ;

: ABSENT+ ( ^JSON:writer -- ^JSON:writer )
   2 OBSERVATION-NAME JSON:WRITE-STRING ;

public

: LOCAL-OBSERVATION>JSON ( observation<local> ^JSON:writer -- ^JSON:writer )
   {: v:observation<local> w :}
   v MATCH observation
      present OF w 0 OBSERVATION-NAME TAGGED+ LOCAL>JSON
         JSON:WRITE-OBJECT-END ENDOF
      directory OF w DIRECTORY+ ENDOF
      absent OF w ABSENT+ ENDOF
      unknown OF w UNKNOWN+ ENDOF
   ;MATCH ;

: REMOTE-OBSERVATION>JSON ( observation<remote> ^JSON:writer -- ^JSON:writer )
   {: v:observation<remote> w :}
   v MATCH observation
      present OF w 0 OBSERVATION-NAME TAGGED+ REMOTE>JSON
         JSON:WRITE-OBJECT-END ENDOF
      directory OF w DIRECTORY+ ENDOF
      absent OF w ABSENT+ ENDOF
      unknown OF w UNKNOWN+ ENDOF
   ;MATCH ;

private

: DIRECTORY-OPERATION+ ( ^JSON:writer n -- ^JSON:writer )
   OPERATION-NAME JSON:WRITE-STRING ;

: REPLACE-LOCAL+ ( remote DROPBOX:hash ^JSON:writer -- ^JSON:writer )
   {: s:remote e:DROPBOX:hash w :}
   w 7 OPERATION-NAME FIELDS+
   s" source" KEY+ s swap REMOTE>JSON
   s" expected_content" KEY+ e swap HASH>JSON ;FIELDS+ ;

: REPLACE-REMOTE+ ( DROPBOX:hash DROPBOX:rev ^JSON:writer -- ^JSON:writer )
   {: c:DROPBOX:hash r:DROPBOX:rev w :}
   w 10 OPERATION-NAME FIELDS+
   s" content" KEY+ c swap HASH>JSON
   s" expected_revision" KEY+ r swap REV>JSON ;FIELDS+ ;

public

: OPERATION>JSON ( operation ^JSON:writer -- ^JSON:writer )
   {: v:operation w :}
   v MATCH operation
      create-local-directory OF w 0 DIRECTORY-OPERATION+ ENDOF
      create-remote-directory OF w 1 DIRECTORY-OPERATION+ ENDOF
      delete-local-directory OF w 2 DIRECTORY-OPERATION+ ENDOF
      delete-remote-directory OF w 3 DIRECTORY-OPERATION+ ENDOF
      create-remote OF w 4 OPERATION-NAME FIELDS+
         s" content" KEY+ HASH>JSON ;FIELDS+ ENDOF
      install-local OF w 5 OPERATION-NAME FIELDS+
         s" source" KEY+ REMOTE>JSON ;FIELDS+ ENDOF
      preserve-local OF w 6 OPERATION-NAME FIELDS+
         s" file" KEY+ LOCAL>JSON ;FIELDS+ ENDOF
      replace-local OF w REPLACE-LOCAL+ ENDOF
      delete-local OF w 8 OPERATION-NAME FIELDS+
         s" expected_content" KEY+ HASH>JSON ;FIELDS+ ENDOF
      preserve-remote OF w 9 OPERATION-NAME FIELDS+
         s" file" KEY+ REMOTE>JSON ;FIELDS+ ENDOF
      replace-remote OF w REPLACE-REMOTE+ ENDOF
      delete-remote OF w 11 OPERATION-NAME FIELDS+
         s" expected_revision" KEY+ REV>JSON ;FIELDS+ ENDOF
   ;MATCH ;

private

\ A conflict that holds both payloads, the variant's index first.
: BOTH+ ( n local remote ^JSON:writer -- ^JSON:writer )
   {: i:n l:local s:remote w :}
   w i CONFLICT-NAME FIELDS+
   s" local" KEY+ l swap LOCAL>JSON
   s" remote" KEY+ s swap REMOTE>JSON ;FIELDS+ ;

public

: CONFLICT>JSON ( conflict ^JSON:writer -- ^JSON:writer )
   {: v:conflict w :}
   v MATCH conflict
      initial OF {: l s :} 0 l s w BOTH+ ENDOF
      divergent OF {: l s :} 1 l s w BOTH+ ENDOF
      local-deleted OF w 2 CONFLICT-NAME FIELDS+
         s" remote" KEY+ REMOTE>JSON ;FIELDS+ ENDOF
      remote-deleted OF w 3 CONFLICT-NAME FIELDS+
         s" local" KEY+ LOCAL>JSON ;FIELDS+ ENDOF
   ;MATCH ;

: FINGERPRINT>JSON ( fingerprint ^JSON:writer -- ^JSON:writer )
   {: v:fingerprint w :}
   v MODEL-FINGERPRINT:UNMAKE {: ino:n size:n ms:n mn:n cs:n cn:n :}
   w JSON:WRITE-OBJECT-START
   s" inode" KEY+ ino JSON:WRITE-U64
   s" size" KEY+ size JSON:WRITE-U64
   s" modified_seconds" KEY+ ms JSON:WRITE-INT
   s" modified_nanoseconds" KEY+ mn JSON:WRITE-U64
   s" changed_seconds" KEY+ cs JSON:WRITE-INT
   s" changed_nanoseconds" KEY+ cn JSON:WRITE-U64
   JSON:WRITE-OBJECT-END ;

\ Rust's LocalHashValue, the stored half of a hash record.
: HASH-VALUE>JSON ( hash-record ^JSON:writer -- ^JSON:writer )
   {: v:hash-record w :}
   v MODEL-HASH--RECORD:UNMAKE {: p:path f:fingerprint c:DROPBOX:hash :}
   w JSON:WRITE-OBJECT-START
   s" fingerprint" KEY+ f swap FINGERPRINT>JSON
   s" content" KEY+ c swap HASH>JSON
   JSON:WRITE-OBJECT-END ;

private

: UNIT-BLOCKAGE+ ( ^JSON:writer n -- ^JSON:writer )
   BLOCKAGE-NAME JSON:WRITE-STRING ;

public

: BLOCKAGE>JSON ( blockage ^JSON:writer -- ^JSON:writer )
   {: v:blockage w :}
   v MATCH blockage
      unsupported-file-size OF w 0 UNIT-BLOCKAGE+ ENDOF
      remote-rejected OF {: t:str :} w 1 BLOCKAGE-NAME FIELDS+
         s" tag" KEY+ t str> JSON:WRITE-STRING ;FIELDS+ ENDOF
      download-unavailable OF {: s :} w 2 BLOCKAGE-NAME FIELDS+
         s" status" KEY+ s JSON:WRITE-U ;FIELDS+ ENDOF
      download-verification-failed OF w 3 UNIT-BLOCKAGE+ ENDOF
      stage-occupied OF w 4 UNIT-BLOCKAGE+ ENDOF
      local-object-in-way OF w 5 UNIT-BLOCKAGE+ ENDOF
      remote-object OF w 6 UNIT-BLOCKAGE+ ENDOF
      conflict-copy-occupied OF w 7 UNIT-BLOCKAGE+ ENDOF
   ;MATCH ;


private

\ A reader finds a member by searching its object's text, so members come
\ in any order; each step reads its text to the end and reuses one cursor.

\ The cursor a read reuses and the arena that takes its strings.
STRUCTURE reading
   FIELD cursor ^JSON:cursor
   FIELD arena ^ARENA:arena
;STRUCTURE

ARENA CURSORS JSON:cursor

: READING ( ^ARENA:arena -- reading )
   {: ar:^ARENA:arena :}
   ar CURSORS-NEW ar READING-MAKE ;

: EXPECT ( n n -- ) <> if E-STORED throw then ;

\ A reader on text, and its first token.
: OPEN ( ^u8 n reading -- JSON:reader n )
   {: t:^ u:n r:reading :}
   r READING-UNMAKE drop t u JSON:READ-INIT JSON:READ-NEXT ;

\ The text of the object's member named by the second string.
: MEMBER ( ^u8 n ^u8 n reading -- ^u8 n )
   {: k:^ ku:n r:reading :}
   r OPEN JSON:T-OBJ EXPECT
   k ku JSON:READ-FIND-KEY 0= if E-STORED throw then
   JSON:READ-ANY-SPAN$ {: v:^ vu:n :}
   k ku JSON:READ-FIND-KEY if E-STORED throw then
   JSON:READ-FINISH v vu ;

\ A string's decoded bytes, copied into the arena; its text bounds them.
: READ-STRING ( ^u8 n reading -- str )
   {: t:^ u:n r:reading :}
   t u r OPEN JSON:T-STR EXPECT
   r READING-UNMAKE nip u ARENA:ALLOC {: d:^ du:n :}
   d du JSON:READ-STR {: len:n :}
   JSON:READ-FINISH d len >str ;

\ serde_json reads -0 as a float, which no integer field takes.
: READ-I64 ( ^u8 n reading -- n )
   OPEN JSON:T-INT EXPECT
   JSON:READ-SPAN$ s" -0" STR= if E-STORED throw then
   JSON:READ-INT {: v:n :} JSON:READ-FINISH v ;

\ A value at or above 2^63 is a negative cell, its 64 bits.
: READ-U64 ( ^u8 n reading -- n )
   OPEN JSON:T-INT EXPECT JSON:READ-U64 {: v:n :}
   JSON:READ-FINISH v ;

: READ-U16 ( ^u8 n reading -- u16 )
   READ-I64 {: v:n :}
   v 0 < v $FFFF > or if E-STORED throw then
   v ;

\ The index whose name the current string or key decodes to, from i on.
: INDEX ( JSON:reader [ n -- ^u8 n ] n -- JSON:reader n )
   {: names i:n :}
   i names execute {: a:^ u:n :}
   u 0= if E-STORED throw then
   a u JSON:READ-STR-EQ? if i exit then
   names i 1+ RECURSE ;

\ An externally tagged enum's variant index and the text of its payload,
\ empty for a variant written as its name alone.
: TAGGED ( ^u8 n [ n -- ^u8 n ] reading -- n ^u8 n )
   {: t:^ u:n names r:reading :}
   t u r OPEN dup JSON:T-STR = if
      drop names 0 INDEX {: i:n :} JSON:READ-FINISH i t 0 exit
   then
   JSON:T-OBJ EXPECT JSON:READ-NEXT JSON:T-KEY EXPECT
   names 0 INDEX {: i:n :}
   JSON:READ-NEXT drop JSON:READ-ANY-SPAN$ {: p:^ pu:n :}
   JSON:READ-NEXT JSON:T-OBJ-END EXPECT
   JSON:READ-FINISH i p pu ;

\ A variant with no payload is written as its name alone.
: UNIT ( ^u8 n -- ) nip 0<> if E-STORED throw then ;

: READ-HASH ( ^u8 n reading -- DROPBOX:hash )
   READ-STRING DROPBOX:>HASH ;

: READ-REV ( ^u8 n reading -- DROPBOX:rev )
   READ-STRING DROPBOX:>REV ;

: HASH-AT ( ^u8 n ^u8 n reading -- DROPBOX:hash )
   {: r:reading :} r MEMBER r READ-HASH ;

: REV-AT ( ^u8 n ^u8 n reading -- DROPBOX:rev )
   {: r:reading :} r MEMBER r READ-REV ;

: READ-LOCAL ( ^u8 n reading -- local )
   {: r:reading :} s" content" r HASH-AT MODEL-LOCAL:MAKE ;

: READ-REMOTE ( ^u8 n reading -- remote )
   {: t:^ u:n r:reading :}
   t u s" content" r HASH-AT
   t u s" revision" r REV-AT MODEL-REMOTE:MAKE ;

: LOCAL-AT ( ^u8 n ^u8 n reading -- local )
   {: r:reading :} r MEMBER r READ-LOCAL ;

: REMOTE-AT ( ^u8 n ^u8 n reading -- remote )
   {: r:reading :} r MEMBER r READ-REMOTE ;

: READ-BASELINE ( ^u8 n reading -- baseline )
   {: r:reading :}
   [: BASELINE-NAME ;] r TAGGED {: i:n p:^ pu:n :}
   i 1 = if p pu r READ-REMOTE MODEL-BASELINE:present exit then
   p pu UNIT
   i 0 = if MODEL-BASELINE:absent exit then
   MODEL-BASELINE:directory ;

: READ-REASON ( ^u8 n reading -- unknown-reason )
   {: r:reading :}
   [: REASON-NAME ;] r TAGGED {: i:n p:^ pu:n :}
   p pu UNIT i >REASON ;

: READ-LOCAL-OBSERVATION ( ^u8 n reading -- observation<local> )
   {: r:reading :}
   [: OBSERVATION-NAME ;] r TAGGED {: i:n p:^ pu:n :}
   i 0 = if p pu r READ-LOCAL MODEL-OBSERVATION:present exit then
   i 3 = if p pu r READ-REASON MODEL-OBSERVATION:unknown exit then
   p pu UNIT
   i 1 = if MODEL-OBSERVATION:directory exit then
   MODEL-OBSERVATION:absent ;

: READ-REMOTE-OBSERVATION ( ^u8 n reading -- observation<remote> )
   {: r:reading :}
   [: OBSERVATION-NAME ;] r TAGGED {: i:n p:^ pu:n :}
   i 0 = if p pu r READ-REMOTE MODEL-OBSERVATION:present exit then
   i 3 = if p pu r READ-REASON MODEL-OBSERVATION:unknown exit then
   p pu UNIT
   i 1 = if MODEL-OBSERVATION:directory exit then
   MODEL-OBSERVATION:absent ;

: DIRECTORY-OPERATION ( n -- operation )
   case
      0 of MODEL-OPERATION:create-local-directory endof
      1 of MODEL-OPERATION:create-remote-directory endof
      2 of MODEL-OPERATION:delete-local-directory endof
      MODEL-OPERATION:delete-remote-directory swap
   endcase ;

\ An operation on a file, variant index 4 on, from its payload's text.
: FILE-OPERATION ( ^u8 n n reading -- operation )
   {: t:^ u:n i:n r:reading :}
   i 4 = if t u s" content" r HASH-AT
      MODEL-OPERATION:create-remote exit then
   i 5 = if t u s" source" r REMOTE-AT
      MODEL-OPERATION:install-local exit then
   i 6 = if t u s" file" r LOCAL-AT
      MODEL-OPERATION:preserve-local exit then
   i 7 = if t u s" source" r REMOTE-AT
      t u s" expected_content" r HASH-AT
      MODEL-OPERATION:replace-local exit then
   i 8 = if t u s" expected_content" r HASH-AT
      MODEL-OPERATION:delete-local exit then
   i 9 = if t u s" file" r REMOTE-AT
      MODEL-OPERATION:preserve-remote exit then
   i 10 = if t u s" content" r HASH-AT
      t u s" expected_revision" r REV-AT
      MODEL-OPERATION:replace-remote exit then
   t u s" expected_revision" r REV-AT MODEL-OPERATION:delete-remote ;

: READ-OPERATION ( ^u8 n reading -- operation )
   {: r:reading :}
   [: OPERATION-NAME ;] r TAGGED {: i:n p:^ pu:n :}
   i 4 < if p pu UNIT i DIRECTORY-OPERATION exit then
   p pu i r FILE-OPERATION ;

: READ-CONFLICT ( ^u8 n reading -- conflict )
   {: r:reading :}
   [: CONFLICT-NAME ;] r TAGGED {: i:n p:^ pu:n :}
   i 2 = if p pu s" remote" r REMOTE-AT
      MODEL-CONFLICT:local-deleted exit then
   i 3 = if p pu s" local" r LOCAL-AT
      MODEL-CONFLICT:remote-deleted exit then
   p pu s" local" r LOCAL-AT p pu s" remote" r REMOTE-AT
   i 0 = if MODEL-CONFLICT:initial exit then
   MODEL-CONFLICT:divergent ;

: U64-AT ( ^u8 n ^u8 n reading -- n )
   {: r:reading :} r MEMBER r READ-U64 ;

: I64-AT ( ^u8 n ^u8 n reading -- n )
   {: r:reading :} r MEMBER r READ-I64 ;

: READ-FINGERPRINT ( ^u8 n reading -- fingerprint )
   {: t:^ u:n r:reading :}
   t u s" inode" r U64-AT
   t u s" size" r U64-AT
   t u s" modified_seconds" r I64-AT
   t u s" modified_nanoseconds" r U64-AT
   t u s" changed_seconds" r I64-AT
   t u s" changed_nanoseconds" r U64-AT
   MODEL-FINGERPRINT:MAKE ;

: READ-HASH-VALUE ( ^u8 n reading -- fingerprint DROPBOX:hash )
   {: t:^ u:n r:reading :}
   t u s" fingerprint" r MEMBER r READ-FINGERPRINT
   t u s" content" r HASH-AT ;

: UNIT-BLOCKAGE ( n -- blockage )
   case
      0 of MODEL-BLOCKAGE:unsupported-file-size endof
      3 of MODEL-BLOCKAGE:download-verification-failed endof
      4 of MODEL-BLOCKAGE:stage-occupied endof
      5 of MODEL-BLOCKAGE:local-object-in-way endof
      6 of MODEL-BLOCKAGE:remote-object endof
      MODEL-BLOCKAGE:conflict-copy-occupied swap
   endcase ;

: READ-BLOCKAGE ( ^u8 n reading -- blockage )
   {: r:reading :}
   [: BLOCKAGE-NAME ;] r TAGGED {: i:n p:^ pu:n :}
   i 1 = if p pu s" tag" r MEMBER r READ-STRING
      MODEL-BLOCKAGE:remote-rejected exit then
   i 2 = if p pu s" status" r MEMBER r READ-U16
      MODEL-BLOCKAGE:download-unavailable exit then
   p pu UNIT i UNIT-BLOCKAGE ;

\ A JSON read code means the stored text is not this version's value.
: STORED-CODE ( n -- n )
   {: code:n :}
   code E-JSON-READ-LAST >= code E-JSON-READ-FIRST <= and
   if E-STORED exit then
   code ;

\ Runs a read that replaces its seed, as catch keeps the stack's shape; a
\ failure frees what the cursor owns and a refused text throws E-STORED.
: GUARDED ( R reading [ R -- R ] -- R )
   {: r:reading q :}
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   r READING-UNMAKE drop JSON:READ-DISPOSE
   code STORED-CODE throw ;

: NO-HASH ( -- DROPBOX:hash ) NONE DROPBOX:>HASH ;
: NO-REV ( -- DROPBOX:rev ) NONE DROPBOX:>REV ;
: NO-LOCAL ( -- local ) NO-HASH MODEL-LOCAL:MAKE ;
: NO-REMOTE ( -- remote ) NO-HASH NO-REV MODEL-REMOTE:MAKE ;
: NO-FINGERPRINT ( -- fingerprint ) 0 0 0 0 0 0 MODEL-FINGERPRINT:MAKE ;

\ A seed's typed drop, which types the read that replaces it.
: DROP-HASH ( DROPBOX:hash -- ) drop ;
: DROP-REV ( DROPBOX:rev -- ) drop ;
: DROP-LOCAL ( local -- ) drop ;
: DROP-REMOTE ( remote -- ) drop ;
: DROP-BASELINE ( baseline -- ) drop ;
: DROP-REASON ( unknown-reason -- ) drop ;
: DROP-LOCAL-OBSERVATION ( observation<local> -- ) drop ;
: DROP-REMOTE-OBSERVATION ( observation<remote> -- ) drop ;
: DROP-OPERATION ( operation -- ) drop ;
: DROP-CONFLICT ( conflict -- ) drop ;
: DROP-FINGERPRINT ( fingerprint -- ) drop ;
: DROP-BLOCKAGE ( blockage -- ) drop ;

public

\ Each reader copies its strings, and its cursor, into ARENA.
: JSON>HASH ( str ^ARENA:arena -- DROPBOX:hash )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-HASH r [: DROP-HASH s str> r READ-HASH ;] GUARDED ;

: JSON>REV ( str ^ARENA:arena -- DROPBOX:rev )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-REV r [: DROP-REV s str> r READ-REV ;] GUARDED ;

: JSON>LOCAL ( str ^ARENA:arena -- local )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-LOCAL r [: DROP-LOCAL s str> r READ-LOCAL ;] GUARDED ;

: JSON>REMOTE ( str ^ARENA:arena -- remote )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-REMOTE r [: DROP-REMOTE s str> r READ-REMOTE ;] GUARDED ;

: JSON>BASELINE ( str ^ARENA:arena -- baseline )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-BASELINE:absent r
   [: DROP-BASELINE s str> r READ-BASELINE ;] GUARDED ;

: JSON>UNKNOWN-REASON ( str ^ARENA:arena -- unknown-reason )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-UNKNOWN--REASON:stale r
   [: DROP-REASON s str> r READ-REASON ;] GUARDED ;

: JSON>LOCAL-OBSERVATION ( str ^ARENA:arena -- observation<local> )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-OBSERVATION:directory r
   [: DROP-LOCAL-OBSERVATION s str> r READ-LOCAL-OBSERVATION ;]
   GUARDED ;

: JSON>REMOTE-OBSERVATION ( str ^ARENA:arena -- observation<remote> )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-OBSERVATION:directory r
   [: DROP-REMOTE-OBSERVATION s str> r READ-REMOTE-OBSERVATION ;]
   GUARDED ;

: JSON>OPERATION ( str ^ARENA:arena -- operation )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-OPERATION:create-local-directory r
   [: DROP-OPERATION s str> r READ-OPERATION ;] GUARDED ;

: JSON>CONFLICT ( str ^ARENA:arena -- conflict )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-LOCAL MODEL-CONFLICT:remote-deleted r
   [: DROP-CONFLICT s str> r READ-CONFLICT ;] GUARDED ;

: JSON>FINGERPRINT ( str ^ARENA:arena -- fingerprint )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-FINGERPRINT r
   [: DROP-FINGERPRINT s str> r READ-FINGERPRINT ;] GUARDED ;

\ Rust's LocalHashValue: a hash record's fingerprint and content.
: JSON>HASH-VALUE ( str ^ARENA:arena -- fingerprint DROPBOX:hash )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-FINGERPRINT NO-HASH r
   [: DROP-HASH DROP-FINGERPRINT s str> r READ-HASH-VALUE ;] GUARDED ;

: JSON>BLOCKAGE ( str ^ARENA:arena -- blockage )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-BLOCKAGE:stage-occupied r
   [: DROP-BLOCKAGE s str> r READ-BLOCKAGE ;] GUARDED ;

;package
