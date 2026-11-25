\ model.f - package MODEL: the sync planner's values (docs/habu-rewrite.md
\ "Values"): a display path and its Dropbox identity, what each side holds
\ at a path, the last state both agreed on, and the planner's operations,
\ conflicts and decisions, with their equality and display text, the
\ records the journal and the local scan share, and the JSON of what the
\ journal still stores as text: operations, conflicts, blockages and a
\ recovery's content, written byte for byte as the Rust version's
\ serde_json writes it and read as serde_json reads any value either
\ version stored. A reader refuses a struct written as an array, a variant
\ with no payload written as an object and a skipped member holding a lone
\ surrogate escape: serde reads them and no writer makes them. The writers
\ give serde_json's bytes only on a compact writer that does not escape
\ non-ASCII.
\ FOLD is Rust's CanonicalPath::from_display over Path::iter: a path that
\ starts with "/" yields the root, else one that starts with "." then "/" or
\ its end yields ".", and the components after it skip empty and "." ones.
\ Each component is lowered in full when it is UTF-8, else byte by byte as
\ ASCII, and they are joined as PathBuf::push joins them: a "/" before each
\ but when the path so far is empty or the root.
\ PATH-CMP is Rust's Path::cmp over the same components, ".." and a
\ leading root or "." among them; RECONCILE and ATTENTION order paths
\ with it.
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
require src/lib/vector.f
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

\ The time a reusable hash's file was last changed before.
STRUCTURE cutoff
   FIELD seconds n
   FIELD nanoseconds n
;STRUCTURE

private

1000000000 constant NS-PER-S

\ Whether the time is before the cutoff; nanoseconds outside 0 to a
\ second are not.
: TIME-BEFORE? ( n n cutoff -- bool )
   {: s:n ns:n c:cutoff :}
   c MODEL-CUTOFF:UNMAKE {: cs:n cns:n :}
   ns 0 < ns NS-PER-S >= or if false exit then
   s cs < if true exit then
   s cs = ns cns < and ;

public

\ Whether the fingerprint's modification and status change times are
\ both before the cutoff, a nanosecond count outside 0 to a second
\ answering false.
: BEFORE? ( fingerprint cutoff -- bool )
   {: f c:cutoff :}
   f MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   ms mn c TIME-BEFORE? cs cn c TIME-BEFORE? and ;

\ What fstat says of an open entry.
STRUCTURE stat
   FIELD dev n
   FIELD inode n
   FIELD mode n
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
$80 constant ASCII-LIMIT

: ROOT? ( str -- bool )
   str> {: p:^ u:n :}
   u 0 > if p c@ SLASH = exit then
   false ;

: CURRENT? ( str -- bool )
   str> {: p:^ u:n :}
   u 0= if false exit then
   p c@ DOT <> if false exit then
   u 1 = if true exit then
   p 1+ c@ SLASH = ;

\ The bytes of the root or the leading "." a path starts with.
: LEAD ( str -- n )
   dup ROOT? if drop 1 exit then
   CURRENT? if 1 exit then
   0 ;

: PART? ( str -- bool )
   str> {: p:^ u:n :}
   u 1 = if p c@ DOT <> exit then
   u 0 > ;

\ A separator goes before a component after `len` bytes but the root.
: SEP? ( n bool -- bool )
   if 1 else 0 then > ;

: LOWERED-BYTES ( str -- n )
   dup UTF8:VALID? if UNICODE:LOWERED-BYTES exit then
   STR:len ;

: LOWER-INTO ( str ^u8 n -- n )
   {: s dst:^ cap:n :}
   s str> {: p:^ u:n :}
   s UTF8:VALID? if s dst cap UNICODE:LOWER exit then
   u 0 ?do p i + c@ STR:ASCII-LOWER dst i + c! loop
   u ;

\ The bytes a component adds after `len`.
: ADD-SIZE ( n bool str -- n )
   {: len:n root:bool p :}
   len len root SEP? if 1+ then
   p LOWERED-BYTES + ;

\ Writes a component after `len` of `size` bytes at `dst`.
: ADD-BYTES ( n bool str ^u8 n -- n )
   {: len:n root:bool p dst:^ size:n :}
   len root SEP? if SLASH dst len + c! len 1+ else len then
   {: at:n :}
   p dst at + size at - LOWER-INTO at + ;

\ The component from `at` that PART? accepts and the index after it;
\ false past the last.
: NEXT-PART ( str n -- str n bool )
   {: p at:n :}
   p SLASH at STR:SPLIT-NEXT 0= if false exit then
   {: q next:n :}
   q PART? if q next true exit then
   p next RECURSE ;

\ Runs ADD on the next component from `at`; false past the last.
: STEP ( str bool n n [ n bool str -- n ] -- n n bool )
   {: p root:bool len:n at:n add :}
   p at NEXT-PART 0= if drop drop len at false exit then
   {: q next:n :}
   len root q add execute next true ;

\ Runs ADD over every component PART? accepts, from the lead's
\ bytes on.
: PARTS ( str [ n bool str -- n ] -- n )
   {: p add :}
   p ROOT? {: root:bool :}
   p LEAD 0
   begin 2>r p root 2r> add STEP 0= until
   drop ;

\ For PARTS over q: the index in p after p's next component when that is
\ q's component, else -1, which every later component keeps.
: MATCH-PART ( n bool str str -- n )
   {: at:n root:bool q p :}
   at 0 < if -1 exit then
   p at NEXT-PART 0= if drop drop -1 exit then
   {: a next:n :}
   a q STR:= if next exit then
   -1 ;

: BYTES ( key -- str ) KEY>STR ;

\ The key's bytes then one byte, laid in the arena.
: EXTENDED ( key u8 ^ARENA:arena -- str )
   {: k:key b:u8 ar:^ARENA:arena :}
   k BYTES str> {: p:^ u:n :}
   ar u 1+ ARENA:ALLOC drop {: dst:^ :}
   p dst u BYTE-COPY
   b dst u + c!
   dst u 1+ >str ;

: PATH= ( path path -- bool )
   {: a:path b:path :}
   a PATH>STR b PATH>STR STR:= ;

\ A value's variant and the strings it holds, empty where it holds none.
STRUCTURE form
   FIELD kind n
   FIELD one str
   FIELD two str
   FIELD three str
;STRUCTURE

: NONE ( -- str ) s" " ;

: FORM= ( form form -- bool )
   {: a:form b:form :}
   a FORM-UNMAKE {: v:n x:str y:str z:str :}
   b FORM-UNMAKE {: w:n x2:str y2:str z2:str :}
   v w <> if false exit then
   x x2 STR:= 0= if false exit then
   y y2 STR:= 0= if false exit then
   z z2 STR:= ;

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
   path PATH>STR {: s :}
   s [: ADD-SIZE ;] PARTS {: size:n :}
   ar size ARENA:ALLOC drop {: dst:^ :}
   s STR:data dst s LEAD BYTE-COPY
   s [: dst size ADD-BYTES ;] PARTS drop
   dst size >str >KEY ;

\ Below zero, zero or above zero as the first key's bytes sort before,
\ equal or after the second's.
: KEY-CMP ( key key -- n )
   {: a:key b:key :}
   a BYTES b BYTES STR:= if 0 exit then
   a BYTES b BYTES STR:< if -1 exit then
   1 ;

: KEY= ( key key -- bool ) {: a:key b:key :} a BYTES b BYTES STR:= ;

\ True when the first key is strictly beneath the second.
: BENEATH? ( key key -- bool )
   {: k:key top:key :}
   k BYTES str> {: p:^ u:n :}
   top BYTES str> {: q:^ v:n :}
   u v <= if false exit then
   p v >str q v >str STR:= 0= if false exit then
   p v + c@ SLASH = ;

\ The half-open byte range from the key then "/" to the key then the
\ byte after "/": it holds exactly the keys BENEATH? accepts, a child
\ whose name starts with 0xFF among them.
: SUBTREE-RANGE ( key ^ARENA:arena -- str str )
   {: k:key ar:^ARENA:arena :}
   k SLASH ar EXTENDED k SLASH 1+ ar EXTENDED ;

\ Rust's Path::starts_with: the second path's components, its root or
\ leading "." included, begin the first's, byte for byte. PARTS starts
\ at the second's lead length, which the first's lead shares.
: BEGINS? ( path path -- bool )
   {: a:path b:path :}
   a PATH>STR {: p :}
   b PATH>STR {: q :}
   p STR:data p LEAD >str q STR:data q LEAD >str STR:=
   0= if false exit then
   q [: p MATCH-PART ;] PARTS 0 >= ;

private

\ Rust's Component order after a path's end: the root, ".", "..", then
\ a name.
0 constant END-RANK
1 constant ROOT-RANK
2 constant CURRENT-RANK
3 constant PARENT-RANK
4 constant NAME-RANK

\ The component from `at`, its rank and the index after it; END-RANK
\ past the last. At -1, the root or leading "." comes first.
: COMPONENT ( str n -- str n n )
   {: p at:n :}
   p STR:data {: a:^ :}
   at 0 < if
      p ROOT? if a 1 >str ROOT-RANK 1 exit then
      p CURRENT? if a 1 >str CURRENT-RANK 1 exit then
      p 0 RECURSE exit
   then
   p at NEXT-PART 0= if drop drop a 0 >str END-RANK at exit then
   {: q next:n :}
   q s" .." STR:= if q PARENT-RANK next exit then
   q NAME-RANK next ;

\ The components from i in p and j in q: the indices after them, their
\ order, and true when they are equal and neither path has ended.
: CMP-STEP ( str str n n -- n n n bool )
   {: p q i:n j:n :}
   p i COMPONENT {: x xr:n i2:n :}
   q j COMPONENT {: y yr:n j2:n :}
   xr yr <> if i2 j2 xr yr - false exit then
   xr END-RANK = if i2 j2 0 false exit then
   x y STR:= if i2 j2 0 true exit then
   i2 j2 x y STR:< if -1 else 1 then false ;

public

\ Rust's Path::cmp by components: the root, ".", ".." and a name sort in
\ that order, and a path that runs out first is less. Allocates nothing.
: PATH-CMP ( path path -- n )
   {: a:path b:path :}
   a PATH>STR {: p :}
   b PATH>STR {: q :}
   -1 -1 0 begin drop 2>r p q 2r> CMP-STEP 0= until
   nip nip ;

private

: SUFFIX-CI? ( str str -- bool )
   {: s x :}
   s str> {: p:^ u:n :}
   x STR:len {: xu:n :}
   u xu < if false exit then
   p u + xu - xu >str x STR:=CI ;

\ Dropbox's documented temporary-file prefixes and metadata suffixes, the
\ suffixes in any ASCII case (help.dropbox.com/en-en/sync/files-not-syncing).
: DOCUMENTED? ( str -- bool )
   {: p :}
   p s" ~$" STR:STARTS-WITH? if true exit then
   p s" .~" STR:STARTS-WITH? if true exit then
   p s" desktop.ini" SUFFIX-CI? if true exit then
   p s" thumbs.db" SUFFIX-CI? if true exit then
   p s" .ds_store" SUFFIX-CI? if true exit then
   p s\" icon\r" SUFFIX-CI? if true exit then
   p s" .dropbox" SUFFIX-CI? if true exit then
   p s" .dropbox.attr" SUFFIX-CI? ;

\ Some byte is past ASCII, where only Unicode lowering finds the case.
: WIDE? ( str -- bool )
   str> {: p:^ u:n :}
   u 0 ?do p i + c@ ASCII-LIMIT < 0= if true unloop exit then loop
   false ;

\ For ARENA:WITH: the name's lowercase is a documented name.
: LOWER-DOCUMENTED? ( str ^ARENA:arena -- bool )
   {: s:str ar :}
   s LOWERED-BYTES {: size:n :}
   ar size ARENA:ALLOC drop {: dst:^ :}
   s dst size LOWER-INTO {: u:n :}
   dst u >str DOCUMENTED? ;

public

\ The name's lowercase, as FOLD keys it, is a documented name.
: EXCLUDED-NAME? ( str -- bool )
   dup WIDE? 0= if DOCUMENTED? exit then
   [: LOWER-DOCUMENTED? ;] ARENA:WITH ;

private

\ For PARTS: -1 once a component is an excluded name, else `at`.
: EXCLUDED-PART ( n bool str -- n )
   {: at:n root:bool q :}
   at 0 < if -1 exit then
   q EXCLUDED-NAME? if -1 exit then
   at ;

public

\ Some component is an excluded name: an excluded directory excludes
\ everything beneath it.
: EXCLUDED? ( path -- bool )
   PATH>STR [: EXCLUDED-PART ;] PARTS 0 < ;

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
   ;MATCH ;

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
   ;MATCH ;

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
   ;MATCH ;

\ ---- JSON

private

\ The names Rust gives a family's variants, by index; empty past them.
: OPERATION-NAME ( n -- str )
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
      s" " swap
   endcase ;

: CONFLICT-NAME ( n -- str )
   case
      0 of s" InitialCollision" endof
      1 of s" DivergentEdits" endof
      2 of s" LocalDeletionRemoteEdit" endof
      3 of s" RemoteDeletionLocalEdit" endof
      s" " swap
   endcase ;

: BLOCKAGE-NAME ( n -- str )
   case
      0 of s" UnsupportedFileSize" endof
      1 of s" RemoteRejected" endof
      2 of s" DownloadUnavailable" endof
      3 of s" DownloadVerificationFailed" endof
      4 of s" StageOccupied" endof
      5 of s" LocalObjectInWay" endof
      6 of s" RemoteObject" endof
      7 of s" ConflictCopyOccupied" endof
      s" " swap
   endcase ;

\ The next member's key, after a comma unless it is the first.
: KEY+ ( ^JSON:writer str -- ^JSON:writer )
   {: a :}
   JSON:WRITE-COMMA a JSON:WRITE-KEY ;

\ Opens a variant written with its payload, `{"Name":`; an object end
\ closes it.
: TAGGED+ ( ^JSON:writer str -- ^JSON:writer )
   {: a :}
   JSON:WRITE-OBJECT-START a JSON:WRITE-KEY ;

\ Opens a struct variant, `{"Name":{`; ;FIELDS+ closes it.
: FIELDS+ ( ^JSON:writer str -- ^JSON:writer )
   TAGGED+ JSON:WRITE-OBJECT-START ;

: ;FIELDS+ ( ^JSON:writer -- ^JSON:writer )
   JSON:WRITE-OBJECT-END JSON:WRITE-OBJECT-END ;

public

: HASH>JSON ( DROPBOX:hash ^JSON:writer -- ^JSON:writer )
   {: h:DROPBOX:hash w :}
   w h DROPBOX:HASH>STR JSON:WRITE-STRING ;

: REV>JSON ( DROPBOX:rev ^JSON:writer -- ^JSON:writer )
   {: r:DROPBOX:rev w :}
   w r DROPBOX:REV>STR JSON:WRITE-STRING ;

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

private

: UNIT-BLOCKAGE+ ( ^JSON:writer n -- ^JSON:writer )
   BLOCKAGE-NAME JSON:WRITE-STRING ;

public

: BLOCKAGE>JSON ( blockage ^JSON:writer -- ^JSON:writer )
   {: v:blockage w :}
   v MATCH blockage
      unsupported-file-size OF w 0 UNIT-BLOCKAGE+ ENDOF
      remote-rejected OF {: t:str :} w 1 BLOCKAGE-NAME FIELDS+
         s" tag" KEY+ t JSON:WRITE-STRING ;FIELDS+ ENDOF
      download-unavailable OF {: s :} w 2 BLOCKAGE-NAME FIELDS+
         s" status" KEY+ s JSON:WRITE-U ;FIELDS+ ENDOF
      download-verification-failed OF w 3 UNIT-BLOCKAGE+ ENDOF
      stage-occupied OF w 4 UNIT-BLOCKAGE+ ENDOF
      local-object-in-way OF w 5 UNIT-BLOCKAGE+ ENDOF
      remote-object OF w 6 UNIT-BLOCKAGE+ ENDOF
      conflict-copy-occupied OF w 7 UNIT-BLOCKAGE+ ENDOF
   ;MATCH ;


private

\ MEMBER searches an object's text for one member, so members come in any
\ order; each search reads the text to the end and reuses one cursor.

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
: OPEN ( str reading -- JSON:reader n )
   {: t:str r:reading :}
   r READING-UNMAKE drop t JSON:READ-INIT JSON:READ-NEXT ;

\ The text of the object's member named by the second string.
: MEMBER ( str str reading -- str )
   READING-UNMAKE drop JSON:READ-MEMBER$ ;

\ A word ending -HERE decodes the value at the reader's token and leaves the
\ reader on the value's last token.

\ The string at the reader's token, decoded into a vector in the arena
\ sized to its text as written, which bounds it.
: STRING-HERE ( JSON:reader reading -- JSON:reader str )
   {: r:reading :}
   JSON:READ-TOKEN JSON:T-STR EXPECT
   JSON:READ-SPAN$ STR:len {: u:n :}
   r READING-UNMAKE nip ARENA:ALLOCATOR u [type] u8 VEC:NEW JSON:READ-STR ;

: READ-STRING ( str reading -- str )
   {: t:str r:reading :}
   t r OPEN drop r STRING-HERE {: s:str :}
   JSON:READ-FINISH s ;

\ serde_json reads -0 as a float, which no integer field takes.
: I64-HERE ( JSON:reader -- JSON:reader n )
   JSON:READ-TOKEN JSON:T-INT EXPECT
   JSON:READ-SPAN$ s" -0" STR:= if E-STORED throw then
   JSON:READ-INT ;

: READ-I64 ( str reading -- n )
   OPEN drop I64-HERE {: v:n :} JSON:READ-FINISH v ;

: READ-U16 ( str reading -- u16 )
   READ-I64 {: v:n :}
   v 0 < v $FFFF > or if E-STORED throw then
   v ;

\ The index whose name the current string or key decodes to, from i on.
: INDEX ( JSON:reader [ n -- str ] n -- JSON:reader n )
   {: names i:n :}
   i names execute {: a :}
   a STR:len 0= if E-STORED throw then
   a JSON:READ-STR-EQ? if i exit then
   names i 1+ RECURSE ;

\ An externally tagged enum's variant index and the text of its payload,
\ empty for a variant written as its name alone.
: TAGGED ( str [ n -- str ] reading -- n str )
   {: t:str names r:reading :}
   t r OPEN dup JSON:T-STR = if
      drop names 0 INDEX {: i:n :} JSON:READ-FINISH i s" " exit
   then
   JSON:T-OBJ EXPECT JSON:READ-NEXT JSON:T-KEY EXPECT
   names 0 INDEX {: i:n :}
   JSON:READ-NEXT drop JSON:READ-ANY-SPAN$ {: p:str :}
   JSON:READ-NEXT JSON:T-OBJ-END EXPECT
   JSON:READ-FINISH i p ;

\ A variant with no payload is written as its name alone.
: UNIT ( str -- ) STR:len 0<> if E-STORED throw then ;

: READ-HASH ( str reading -- DROPBOX:hash )
   READ-STRING DROPBOX:>HASH ;

: READ-REV ( str reading -- DROPBOX:rev )
   READ-STRING DROPBOX:>REV ;

: HASH-AT ( str str reading -- DROPBOX:hash )
   {: r:reading :} r MEMBER r READ-HASH ;

: REV-AT ( str str reading -- DROPBOX:rev )
   {: r:reading :} r MEMBER r READ-REV ;

: READ-LOCAL ( str reading -- local )
   {: r:reading :} s" content" r HASH-AT MODEL-LOCAL:MAKE ;

: READ-REMOTE ( str reading -- remote )
   {: t:str r:reading :}
   t s" content" r HASH-AT
   t s" revision" r REV-AT MODEL-REMOTE:MAKE ;

: LOCAL-AT ( str str reading -- local )
   {: r:reading :} r MEMBER r READ-LOCAL ;

: REMOTE-AT ( str str reading -- remote )
   {: r:reading :} r MEMBER r READ-REMOTE ;

: DIRECTORY-OPERATION ( n -- operation )
   case
      0 of MODEL-OPERATION:CREATE-LOCAL-DIRECTORY endof
      1 of MODEL-OPERATION:CREATE-REMOTE-DIRECTORY endof
      2 of MODEL-OPERATION:DELETE-LOCAL-DIRECTORY endof
      MODEL-OPERATION:DELETE-REMOTE-DIRECTORY swap
   endcase ;

\ An operation on a file, variant index 4 on, from its payload's text.
: FILE-OPERATION ( str n reading -- operation )
   {: t:str i:n r:reading :}
   i 4 = if t s" content" r HASH-AT
      MODEL-OPERATION:CREATE-REMOTE exit then
   i 5 = if t s" source" r REMOTE-AT
      MODEL-OPERATION:INSTALL-LOCAL exit then
   i 6 = if t s" file" r LOCAL-AT
      MODEL-OPERATION:PRESERVE-LOCAL exit then
   i 7 = if t s" source" r REMOTE-AT
      t s" expected_content" r HASH-AT
      MODEL-OPERATION:REPLACE-LOCAL exit then
   i 8 = if t s" expected_content" r HASH-AT
      MODEL-OPERATION:DELETE-LOCAL exit then
   i 9 = if t s" file" r REMOTE-AT
      MODEL-OPERATION:PRESERVE-REMOTE exit then
   i 10 = if t s" content" r HASH-AT
      t s" expected_revision" r REV-AT
      MODEL-OPERATION:REPLACE-REMOTE exit then
   t s" expected_revision" r REV-AT MODEL-OPERATION:DELETE-REMOTE ;

: READ-OPERATION ( str reading -- operation )
   {: r:reading :}
   [: OPERATION-NAME ;] r TAGGED {: i:n p:str :}
   i 4 < if p UNIT i DIRECTORY-OPERATION exit then
   p i r FILE-OPERATION ;

: READ-CONFLICT ( str reading -- conflict )
   {: r:reading :}
   [: CONFLICT-NAME ;] r TAGGED {: i:n p:str :}
   i 2 = if p s" remote" r REMOTE-AT
      MODEL-CONFLICT:LOCAL-DELETED exit then
   i 3 = if p s" local" r LOCAL-AT
      MODEL-CONFLICT:REMOTE-DELETED exit then
   p s" local" r LOCAL-AT p s" remote" r REMOTE-AT
   i 0 = if MODEL-CONFLICT:INITIAL exit then
   MODEL-CONFLICT:DIVERGENT ;

: UNIT-BLOCKAGE ( n -- blockage )
   case
      0 of MODEL-BLOCKAGE:UNSUPPORTED-FILE-SIZE endof
      3 of MODEL-BLOCKAGE:DOWNLOAD-VERIFICATION-FAILED endof
      4 of MODEL-BLOCKAGE:STAGE-OCCUPIED endof
      5 of MODEL-BLOCKAGE:LOCAL-OBJECT-IN-WAY endof
      6 of MODEL-BLOCKAGE:REMOTE-OBJECT endof
      MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED swap
   endcase ;

: READ-BLOCKAGE ( str reading -- blockage )
   {: r:reading :}
   [: BLOCKAGE-NAME ;] r TAGGED {: i:n p:str :}
   i 1 = if p s" tag" r MEMBER r READ-STRING
      MODEL-BLOCKAGE:REMOTE-REJECTED exit then
   i 2 = if p s" status" r MEMBER r READ-U16
      MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE exit then
   p UNIT i UNIT-BLOCKAGE ;

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

public

\ The empty seeds a read replaces.
: NO-HASH ( -- DROPBOX:hash ) NONE DROPBOX:>HASH ;
: NO-FINGERPRINT ( -- fingerprint ) 0 0 0 0 0 0 MODEL-FINGERPRINT:MAKE ;

private

: NO-LOCAL ( -- local ) NO-HASH MODEL-LOCAL:MAKE ;

\ A seed's typed drop, which types the read that replaces it.
: DROP-HASH ( DROPBOX:hash -- ) drop ;
: DROP-OPERATION ( operation -- ) drop ;
: DROP-CONFLICT ( conflict -- ) drop ;
: DROP-BLOCKAGE ( blockage -- ) drop ;

public

\ Each reader copies its strings, and its cursor, into ARENA.
: JSON>HASH ( str ^ARENA:arena -- DROPBOX:hash )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-HASH r [: DROP-HASH s r READ-HASH ;] GUARDED ;

: JSON>OPERATION ( str ^ARENA:arena -- operation )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY r
   [: DROP-OPERATION s r READ-OPERATION ;] GUARDED ;

: JSON>CONFLICT ( str ^ARENA:arena -- conflict )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   NO-LOCAL MODEL-CONFLICT:REMOTE-DELETED r
   [: DROP-CONFLICT s r READ-CONFLICT ;] GUARDED ;

: JSON>BLOCKAGE ( str ^ARENA:arena -- blockage )
   {: s:str ar:^ARENA:arena :} ar READING {: r:reading :}
   MODEL-BLOCKAGE:STAGE-OCCUPIED r
   [: DROP-BLOCKAGE s r READ-BLOCKAGE ;] GUARDED ;

;package
