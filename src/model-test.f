\ model-test.f - MODEL's values: every line of src/oracle/fold.tsv, the
\ Rust version's answers, through FOLD; model.rs's tests of a key's order,
\ folding and BENEATH?; SUBTREE-RANGE against BENEATH?; BEGINS? and
\ PATH-CMP on display paths; exclusions.rs's tests through EXCLUDED?; the planner's
\ equality words on one equal and one unequal pair, and the observation,
\ fingerprint and record ones on values that differ in one field or
\ variant; each display word on every variant against model.rs's text;
\ every line of src/oracle/json.tsv through the JSON writers and readers,
\ and the readers' acceptance and refusals.
\ Run from the repository root: hb --load src/model-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/fs.f
require src/lib/test.f
require src/lib/fmt.f
require src/lib/vector.f
require src/lib/heap.f
require src/lib/json.f
require src/dropbox.f
require src/model.f

package MODEL-TEST
private

TYPED-VARIABLE AR ^ARENA:arena

10 constant LF
9 constant TAB

: HASH ( str -- DROPBOX:hash ) DROPBOX:>HASH ;
: REV ( str -- DROPBOX:rev ) DROPBOX:>REV ;
: LOCAL ( str -- MODEL:local ) HASH MODEL-LOCAL:MAKE ;

: REMOTE ( str str -- MODEL:remote )
   {: c r :}
   c HASH r REV MODEL-REMOTE:MAKE ;

: KEY ( str -- MODEL:key ) MODEL:>PATH AR @ MODEL:FOLD ;
\ A key from its bytes, as Rust's CanonicalPath::from_bytes.
: RAW ( str -- MODEL:key ) MODEL:>KEY ;

: KEY$ ( MODEL:key -- str ) MODEL:KEY>STR ;


\ The bytes the hex digits spell, written at `dst`; answers their count.
: UNHEX ( str ^u8 -- n )
   {: s dst:^ :}
   s str> {: h:^ u:n :}
   u 2 / 0 ?do
      h i 2 * + c@ STR-HEX-DIGIT-VALUE 16 *
      h i 2 * + 1+ c@ STR-HEX-DIGIT-VALUE +
      dst i + c!
   loop
   u 2 / ;

: DECODED ( str -- str )
   {: h :}
   AR @ h STR:len 2 / ARENA:ALLOC drop {: dst:^ :}
   dst h dst UNHEX >str ;

\ One line: a display path, a tab, its fold, both in hex.
: FOLD-LINE ( str -- )
   {: line :}
   line TAB 0 SPLIT-NEXT drop {: next:n :}
   DECODED {: p :}
   line str> {: l:^ lu:n :}
   l next + lu next - >str DECODED {: w :}
   p KEY KEY$ w T$= ;

\ Folds each line from `at` on; answers how many it folded.
: FOLD-FROM ( str n -- n )
   {: t at:n :}
   t LF at SPLIT-NEXT 0= if drop drop 0 exit then
   {: line next:n :}
   line STR:len 0= if t next RECURSE exit then
   line FOLD-LINE
   t next RECURSE 1+ ;

: LINES ( str -- n )
   str> {: t:^ u:n :}
   0 u 0 ?do t i + c@ LF = if 1+ then loop ;

: FOLD-CASE ( -- )
   s" fold.tsv" T-LABEL
   s" src/oracle/fold.tsv" {: f :}
   AR @ f FS:FILE-SIZE ARENA:ALLOC {: t:^ u:n :}
   f t u FS:READ-ALL u T=
   t u >str 0 FOLD-FROM t u >str LINES T= ;


: CANONICAL-ORDER-IS-BYTEWISE-NOT-COMPONENT-WISE ( -- )
   s" canonical_order_is_bytewise_not_component_wise" T-LABEL
   s" report" KEY {: directory:MODEL:key :}
   s" report.txt" KEY {: sibling:MODEL:key :}
   s" report/x" KEY {: child:MODEL:key :}
   directory sibling MODEL:KEY-CMP 0 < TTRUE
   sibling child MODEL:KEY-CMP 0 < TTRUE
   child sibling MODEL:KEY-CMP 0 > TTRUE
   s" REPORT" KEY directory MODEL:KEY-CMP 0 T= ;

: CANONICAL-PATHS-FOLD-CASE-AND-COMPARE-BY-BYTES ( -- )
   s" canonical_paths_fold_case_and_compare_by_bytes" T-LABEL
   s" Report/X.TXT" KEY s" report/x.txt" KEY MODEL:KEY= TTRUE
   s" Report/X.TXT" KEY KEY$ s" report/x.txt" T$=
   s" report" KEY s" report.txt" KEY MODEL:KEY= TFALSE ;

: ONLY-TRUE-DESCENDANTS-ARE-BENEATH-AN-ANCESTOR ( -- )
   s" only_true_descendants_are_beneath_an_ancestor" T-LABEL
   s" report" KEY {: top:MODEL:key :}
   s" report/x" KEY top MODEL:BENEATH? TTRUE
   s" report/x/deep" KEY top MODEL:BENEATH? TTRUE
   s" report.txt" KEY top MODEL:BENEATH? TFALSE
   s" report2/x" KEY top MODEL:BENEATH? TFALSE
   top top MODEL:BENEATH? TFALSE
   s" other/report/x" KEY top MODEL:BENEATH? TFALSE ;

: DISPLAY ( str -- MODEL:path ) MODEL:>PATH ;

\ BEGINS? compares whole components: a byte prefix is not a parent.
: PATHS-BEGIN-BY-COMPONENT ( -- )
   s" begins" T-LABEL
   s" /a/b" DISPLAY s" /a/b" DISPLAY MODEL:BEGINS? TTRUE
   s" /a/b" DISPLAY s" /a" DISPLAY MODEL:BEGINS? TTRUE
   s" /a" DISPLAY s" /a/b" DISPLAY MODEL:BEGINS? TFALSE
   s" /a/b" DISPLAY s" /a/bc" DISPLAY MODEL:BEGINS? TFALSE
   s" /a/bc" DISPLAY s" /a/b" DISPLAY MODEL:BEGINS? TFALSE
   s" /a/b" DISPLAY s" /" DISPLAY MODEL:BEGINS? TTRUE
   s" /" DISPLAY s" /" DISPLAY MODEL:BEGINS? TTRUE
   s" a/b" DISPLAY s" /" DISPLAY MODEL:BEGINS? TFALSE ;

\ PATH-CMP's sign for two display paths.
: PATH-ORDER ( str str -- n )
   {: a b :}
   a DISPLAY b DISPLAY MODEL:PATH-CMP {: c:n :}
   c 0 < if -1 exit then
   c 0 > if 1 exit then
   0 ;

\ Path::cmp's answers; each pair but the equal ones orders the other way
\ by bytes.
: PATHS-SORT-BY-COMPONENT ( -- )
   s" PATHS-SORT-BY-COMPONENT" T-LABEL
   s" a/b" s" a-b" PATH-ORDER -1 T=
   s" a-b" s" a/b" PATH-ORDER 1 T=
   s" /z" s" ." PATH-ORDER -1 T=
   s" ./z" s" .." PATH-ORDER -1 T=
   s" ../z" s" -" PATH-ORDER -1 T=
   s" a//b" s" a/b" PATH-ORDER 0 T=
   s" a/./b" s" a/b" PATH-ORDER 0 T= ;

: EXCLUDED ( str -- ) DISPLAY MODEL:EXCLUDED? TTRUE ;
: SYNCED ( str -- ) DISPLAY MODEL:EXCLUDED? TFALSE ;

: DOCUMENTED-NAMES-AND-DESCENDANTS-ARE-EXCLUDED ( -- )
   s" documented_names_and_descendants_are_excluded" T-LABEL
   s" .DS_Store" EXCLUDED
   s" folder/DESKTOP.INI" EXCLUDED
   s" folder/Thumbs.db" EXCLUDED
   s\" folder/Icon\r" EXCLUDED
   s" folder/.dropbox" EXCLUDED
   s" folder/.DROPBOX.ATTR" EXCLUDED
   s" folder/metadata.ds_store" EXCLUDED
   s" folder/~$draft.docx" EXCLUDED
   s" folder/.~draft.docx" EXCLUDED
   s" folder/.dropbox/child.txt" EXCLUDED
   s" ~$temporary/child.txt" EXCLUDED
   s\" folder/~$\xff" EXCLUDED ;

: OTHER-NAMES-STILL-SYNC ( -- )
   s" other_names_still_sync" T-LABEL
   s" notes.md" SYNCED
   s" .obsidian/settings.json" SYNCED
   s" .gitignore" SYNCED
   s" file.tmp" SYNCED
   s" file~" SYNCED
   s" DS_Store" SYNCED
   s" .DS_Store.backup" SYNCED
   s" thumbs.db.txt" SYNCED
   s" icon" SYNCED
   s" icon\r" SYNCED
   s" rules.dropboxignore" SYNCED
   s" .dropbox-folder/notes.md" SYNCED ;

\ True when the key falls in the top's subtree range.
: IN-RANGE? ( MODEL:key MODEL:key -- bool )
   {: k:MODEL:key top:MODEL:key :}
   top AR @ MODEL:SUBTREE-RANGE {: lo:str hi:str :}
   k KEY$ {: p :}
   p lo STR< 0= p hi STR< and ;

\ BENEATH? and the range both answer `want` for the key.
: RANGE-AGREES ( MODEL:key MODEL:key bool -- )
   {: k:MODEL:key top:MODEL:key want:bool :}
   k top MODEL:BENEATH? bool>n want bool>n T=
   k top IN-RANGE? bool>n want bool>n T= ;

\ model.rs's subtree range test.
: SUBTREE-RANGE-HOLDS-EXACTLY-THE-PATHS-BENEATH-AN-ANCESTOR ( -- )
   s" subtree_range_holds_exactly_the_paths_beneath_an_ancestor" T-LABEL
   s" report" KEY {: top:MODEL:key :}
   s\" report/\xFF" RAW top true RANGE-AGREES
   s\" report/\xFFdeep/\xFF" RAW top true RANGE-AGREES
   s" report/x" KEY top true RANGE-AGREES
   s\" report/\xF4\x8F\xBF\xBF" KEY top true RANGE-AGREES
   s" report" KEY top false RANGE-AGREES
   s" report.txt" KEY top false RANGE-AGREES
   s" report0" KEY top false RANGE-AGREES
   s" reports/x" KEY top false RANGE-AGREES
   s" a" KEY {: a:MODEL:key :}
   a AR @ MODEL:SUBTREE-RANGE {: lo:str hi:str :}
   lo s" a/" T$=
   hi s" a0" T$=
   s" a/b" KEY a true RANGE-AGREES
   s" a/b/c" KEY a true RANGE-AGREES
   s\" a/\xFF" RAW a true RANGE-AGREES
   s" a.b" KEY a false RANGE-AGREES
   s" a0" KEY a false RANGE-AGREES
   a a false RANGE-AGREES ;


: R1 ( -- MODEL:remote ) s" h1" s" r1" REMOTE ;
: R2 ( -- MODEL:remote ) s" h1" s" r2" REMOTE ;

\ Each pair's strings are separate literals, so equal means equal bytes.
: EQUALITY-CASE ( -- )
   s" equality" T-LABEL
   s" h1" LOCAL s" h1" LOCAL MODEL:LOCAL= TTRUE
   s" h1" LOCAL s" h2" LOCAL MODEL:LOCAL= TFALSE
   R1 R1 MODEL:REMOTE= TTRUE
   R1 R2 MODEL:REMOTE= TFALSE
   R1 MODEL-BASELINE:PRESENT R1 MODEL-BASELINE:PRESENT
   MODEL:BASELINE= TTRUE
   R1 MODEL-BASELINE:PRESENT R2 MODEL-BASELINE:PRESENT
   MODEL:BASELINE= TFALSE
   R1 s" h0" HASH MODEL-OPERATION:REPLACE-LOCAL
   R1 s" h0" HASH MODEL-OPERATION:REPLACE-LOCAL
   MODEL:OPERATION= TTRUE
   R1 MODEL-OPERATION:INSTALL-LOCAL R1 MODEL-OPERATION:PRESERVE-REMOTE
   MODEL:OPERATION= TFALSE
   s" h1" LOCAL R1 MODEL-CONFLICT:DIVERGENT
   s" h1" LOCAL R1 MODEL-CONFLICT:DIVERGENT
   MODEL:CONFLICT= TTRUE
   s" h1" LOCAL R1 MODEL-CONFLICT:DIVERGENT
   s" h2" LOCAL R1 MODEL-CONFLICT:DIVERGENT
   MODEL:CONFLICT= TFALSE
   s" h1" LOCAL R1 MODEL-CONFLICT:INITIAL MODEL-DECISION:CONFLICTED
   s" h1" LOCAL R1 MODEL-CONFLICT:INITIAL MODEL-DECISION:CONFLICTED
   MODEL:DECISION= TTRUE
   MODEL-BASELINE:ABSENT MODEL-DECISION:NOOP
   MODEL-BLOCKED--REASON:UNKNOWN MODEL-DECISION:BLOCKED
   MODEL:DECISION= TFALSE ;


\ ---- The observation, fingerprint and record equality words: value 0 and
\ each other value differ in one field or variant, and every value is
\ built afresh, its strings copied, so equal means equal bytes.

: FRESH ( str -- str )
   str> {: p:^ u:n :}
   AR @ u ARENA:ALLOC drop {: d:^ :}
   p d u BYTE-COPY d u >str ;

: FRESH-HASH ( str -- DROPBOX:hash ) FRESH DROPBOX:>HASH ;
: FRESH-REV ( str -- DROPBOX:rev ) FRESH DROPBOX:>REV ;
: FRESH-PATH ( str -- MODEL:path ) FRESH MODEL:>PATH ;
: FRESH-KEY ( str -- MODEL:key ) FRESH MODEL:>KEY ;

: FRESH-REMOTE ( str str -- MODEL:remote )
   {: c r :}
   c FRESH-HASH r FRESH-REV MODEL-REMOTE:MAKE ;

\ Each of `count` values equals itself, built again, and no other.
: MATRIX ( n [ n n -- bool ] -- )
   {: count:n eq :}
   count 0 ?do count 0 ?do
      j i eq execute bool>n i j = bool>n T=
   loop loop ;

: LOCAL-OBSERVATION-AT ( n -- MODEL:observation<MODEL:local> )
   {: k:n :}
   k 0 = if s" h1" FRESH-HASH MODEL-LOCAL:MAKE
      MODEL-OBSERVATION:PRESENT exit then
   k 1 = if s" h2" FRESH-HASH MODEL-LOCAL:MAKE
      MODEL-OBSERVATION:PRESENT exit then
   k 2 = if MODEL-OBSERVATION:DIRECTORY exit then
   k 3 = if MODEL-OBSERVATION:ABSENT exit then
   k 4 = if MODEL-UNKNOWN--REASON:STALE MODEL-OBSERVATION:UNKNOWN exit then
   MODEL-UNKNOWN--REASON:INCOMPLETE MODEL-OBSERVATION:UNKNOWN ;

: LOCAL-OBSERVATIONS= ( n n -- bool )
   {: a:n b:n :}
   a LOCAL-OBSERVATION-AT b LOCAL-OBSERVATION-AT
   MODEL:LOCAL-OBSERVATION= ;

: REMOTE-OBSERVATION-AT ( n -- MODEL:observation<MODEL:remote> )
   {: k:n :}
   k 0 = if s" h1" s" r1" FRESH-REMOTE MODEL-OBSERVATION:PRESENT exit then
   k 1 = if s" h2" s" r1" FRESH-REMOTE MODEL-OBSERVATION:PRESENT exit then
   k 2 = if s" h1" s" r2" FRESH-REMOTE MODEL-OBSERVATION:PRESENT exit then
   k 3 = if MODEL-OBSERVATION:DIRECTORY exit then
   k 4 = if MODEL-OBSERVATION:ABSENT exit then
   k 5 = if MODEL-UNKNOWN--REASON:STALE MODEL-OBSERVATION:UNKNOWN exit then
   MODEL-UNKNOWN--REASON:INCOMPLETE MODEL-OBSERVATION:UNKNOWN ;

: REMOTE-OBSERVATIONS= ( n n -- bool )
   {: a:n b:n :}
   a REMOTE-OBSERVATION-AT b REMOTE-OBSERVATION-AT
   MODEL:REMOTE-OBSERVATION= ;

\ The field's value, ten more when it is the k-th field.
: BUMP ( n n n -- n )
   {: v:n k:n field:n :}
   k field = if v 10 + exit then
   v ;

: FINGERPRINT-AT ( n -- MODEL:fingerprint )
   {: k:n :}
   1 k 1 BUMP 2 k 2 BUMP 3 k 3 BUMP
   4 k 4 BUMP 5 k 5 BUMP 6 k 6 BUMP
   MODEL-FINGERPRINT:MAKE ;

: FINGERPRINTS= ( n n -- bool )
   {: a:n b:n :}
   a FINGERPRINT-AT b FINGERPRINT-AT MODEL:FINGERPRINT= ;

: LOCAL-RECORD-AT ( n -- MODEL:local-record )
   {: k:n :}
   k 1 = if s" y" else s" x" then FRESH-PATH
   k 2 = if 2 else 0 then LOCAL-OBSERVATION-AT
   MODEL-LOCAL--RECORD:MAKE ;

: LOCAL-RECORDS= ( n n -- bool )
   {: a:n b:n :}
   a LOCAL-RECORD-AT b LOCAL-RECORD-AT MODEL:LOCAL-RECORD= ;

: HASH-RECORD-AT ( n -- MODEL:hash-record )
   {: k:n :}
   k 1 = if s" y" else s" x" then FRESH-PATH
   k 2 = if 1 else 0 then FINGERPRINT-AT
   k 3 = if s" h2" else s" h1" then FRESH-HASH
   MODEL-HASH--RECORD:MAKE ;

: HASH-RECORDS= ( n n -- bool )
   {: a:n b:n :}
   a HASH-RECORD-AT b HASH-RECORD-AT MODEL:HASH-RECORD= ;

\ Value 2's path differs from value 0's in case alone.
: REMOTE-RECORD-AT ( n -- MODEL:remote-record )
   {: k:n :}
   k 1 = if s" y" else s" x" then FRESH-KEY
   k 2 = if s" x" else s" X" then FRESH-PATH
   k 3 = if 2 else 0 then REMOTE-OBSERVATION-AT
   MODEL-REMOTE--RECORD:MAKE ;

: REMOTE-RECORDS= ( n n -- bool )
   {: a:n b:n :}
   a REMOTE-RECORD-AT b REMOTE-RECORD-AT MODEL:REMOTE-RECORD= ;

: RECORD-EQUALITY-CASE ( -- )
   s" LOCAL-OBSERVATION=" T-LABEL 6 [: LOCAL-OBSERVATIONS= ;] MATRIX
   s" REMOTE-OBSERVATION=" T-LABEL 7 [: REMOTE-OBSERVATIONS= ;] MATRIX
   s" FINGERPRINT=" T-LABEL 7 [: FINGERPRINTS= ;] MATRIX
   s" LOCAL-RECORD=" T-LABEL 3 [: LOCAL-RECORDS= ;] MATRIX
   s" HASH-RECORD=" T-LABEL 4 [: HASH-RECORDS= ;] MATRIX
   s" REMOTE-RECORD=" T-LABEL 4 [: REMOTE-RECORDS= ;] MATRIX ;


: UNKNOWN-TEXT-CASE ( -- )
   s" UNKNOWN$" T-LABEL
   MODEL-UNKNOWN--REASON:INCOMPLETE MODEL:UNKNOWN$
   s" observation is incomplete" T$=
   MODEL-UNKNOWN--REASON:INACCESSIBLE MODEL:UNKNOWN$
   s" path is inaccessible" T$=
   MODEL-UNKNOWN--REASON:UNAVAILABLE MODEL:UNKNOWN$
   s" source is unavailable" T$=
   MODEL-UNKNOWN--REASON:STALE MODEL:UNKNOWN$
   s" inventory is stale" T$=
   MODEL-UNKNOWN--REASON:CURSOR-RESET MODEL:UNKNOWN$
   s" remote cursor was reset" T$=
   MODEL-UNKNOWN--REASON:UNSUPPORTED MODEL:UNKNOWN$
   s" object is unsupported" T$= ;

: DIRECTORY-TEXT-CASE ( -- )
   MODEL-OPERATION:CREATE-LOCAL-DIRECTORY MODEL:OPERATION$
   s" create local directory if still absent" T$=
   MODEL-OPERATION:CREATE-REMOTE-DIRECTORY MODEL:OPERATION$
   s" create remote directory if still absent" T$=
   MODEL-OPERATION:DELETE-LOCAL-DIRECTORY MODEL:OPERATION$
   s" delete empty local directory" T$=
   MODEL-OPERATION:DELETE-REMOTE-DIRECTORY MODEL:OPERATION$
   s" delete empty remote directory" T$= ;

: FILE-TEXT-CASE ( -- )
   s" h1" HASH MODEL-OPERATION:CREATE-REMOTE MODEL:OPERATION$
   s" create remote file if still absent" T$=
   R1 MODEL-OPERATION:INSTALL-LOCAL MODEL:OPERATION$
   s" install remote content locally" T$=
   s" h1" LOCAL MODEL-OPERATION:PRESERVE-LOCAL MODEL:OPERATION$
   s" preserve displaced local payload" T$=
   R1 s" h0" HASH MODEL-OPERATION:REPLACE-LOCAL MODEL:OPERATION$
   s" replace local content" T$=
   s" h0" HASH MODEL-OPERATION:DELETE-LOCAL MODEL:OPERATION$
   s" delete local file" T$=
   R1 MODEL-OPERATION:PRESERVE-REMOTE MODEL:OPERATION$
   s" preserve displaced remote payload" T$=
   s" h1" HASH s" r1" REV MODEL-OPERATION:REPLACE-REMOTE MODEL:OPERATION$
   s" replace remote content if the expected revision still matches"
   T$=
   s" r1" REV MODEL-OPERATION:DELETE-REMOTE MODEL:OPERATION$
   s" delete remote file if the expected revision still matches" T$= ;

: CONFLICT-TEXT-CASE ( -- )
   s" CONFLICT$" T-LABEL
   s" h1" LOCAL R1 MODEL-CONFLICT:INITIAL MODEL:CONFLICT$
   s" different local and remote payloads were introduced; preserve both payloads"
   T$=
   s" h1" LOCAL R1 MODEL-CONFLICT:DIVERGENT MODEL:CONFLICT$
   s" local and remote payloads diverged; preserve both payloads" T$=
   R1 MODEL-CONFLICT:LOCAL-DELETED MODEL:CONFLICT$
   s" local deletion conflicts with a remote edit; preserve the remote payload"
   T$=
   s" h1" LOCAL MODEL-CONFLICT:REMOTE-DELETED MODEL:CONFLICT$
   s" remote deletion conflicts with a local edit; preserve the local payload"
   T$= ;


\ ---- JSON

TYPED-VARIABLE OUT ^VEC:vector<u8>
TYPED-VARIABLE W JSON:writer
46 constant PERIOD

\ The writer's bytes for one value equal the line's JSON.
: WRITES ( str [ ^JSON:writer -- ^JSON:writer ] -- )
   {: j q :}
   W OUT @ JSON:OPEN q execute JSON:WRITTEN$ j T$= ;

: H0$ ( -- str )
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ;
: H1$ ( -- str )
   s" 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae" ;
: R0$ ( -- str ) s" 5f0a1b2c3d4e" ;
: R1$ ( -- str ) s" 5f0a1b2c3d4f" ;
\ The .escapes lines' string: a quote, a backslash, U+0001, DEL, é and
\ U+2028.
: ESC$ ( -- str ) s\" \"\\\x01\x7F\xC3\xA9\xE2\x80\xA8" ;

: OR-ESC ( str bool -- str ) if drop ESC$ then ;
: C0 ( bool -- DROPBOX:hash ) {: e:bool :} H0$ e OR-ESC HASH ;
: C1 ( bool -- DROPBOX:hash ) {: e:bool :} H1$ e OR-ESC HASH ;
: V0 ( bool -- DROPBOX:rev ) {: e:bool :} R0$ e OR-ESC REV ;
: V1 ( bool -- DROPBOX:rev ) {: e:bool :} R1$ e OR-ESC REV ;
: LOCAL0 ( bool -- MODEL:local ) C0 MODEL-LOCAL:MAKE ;

: REMOTE0 ( bool -- MODEL:remote )
   {: e:bool :} e C0 e V0 MODEL-REMOTE:MAKE ;

: REMOTE1 ( bool -- MODEL:remote )
   {: e:bool :} e C1 e V1 MODEL-REMOTE:MAKE ;

: FINGERPRINT ( -- MODEL:fingerprint )
   -1 12345 -1 999999999 $7FFFFFFFFFFFFFFF 0 MODEL-FINGERPRINT:MAKE ;

: BASELINE-OF ( str bool -- MODEL:baseline )
   {: v e:bool :}
   v s" Absent" STR= if MODEL-BASELINE:ABSENT exit then
   v s" Directory" STR= if MODEL-BASELINE:DIRECTORY exit then
   e REMOTE0 MODEL-BASELINE:PRESENT ;

: REASON-OF ( str -- MODEL:unknown-reason )
   {: v :}
   v s" Incomplete" STR= if MODEL-UNKNOWN--REASON:INCOMPLETE exit then
   v s" Inaccessible" STR= if
      MODEL-UNKNOWN--REASON:INACCESSIBLE exit then
   v s" Unavailable" STR= if
      MODEL-UNKNOWN--REASON:UNAVAILABLE exit then
   v s" Stale" STR= if MODEL-UNKNOWN--REASON:STALE exit then
   v s" CursorReset" STR= if
      MODEL-UNKNOWN--REASON:CURSOR-RESET exit then
   MODEL-UNKNOWN--REASON:UNSUPPORTED ;

\ An Unknown observation's label names its reason after a period.
: UNKNOWN-REASON-OF ( str -- MODEL:unknown-reason )
   str> {: v:^ vu:n :}
   v 8 + vu 8 - >str REASON-OF ;

: LOCAL-OBSERVATION-OF ( str bool -- MODEL:observation<MODEL:local> )
   {: v e:bool :}
   v s" ConfirmedAbsent" STR= if MODEL-OBSERVATION:ABSENT exit then
   v s" Directory" STR= if MODEL-OBSERVATION:DIRECTORY exit then
   v s" Present" STR= if e LOCAL0 MODEL-OBSERVATION:PRESENT exit then
   v UNKNOWN-REASON-OF MODEL-OBSERVATION:UNKNOWN ;

: REMOTE-OBSERVATION-OF ( str bool -- MODEL:observation<MODEL:remote> )
   {: v e:bool :}
   v s" ConfirmedAbsent" STR= if MODEL-OBSERVATION:ABSENT exit then
   v s" Directory" STR= if MODEL-OBSERVATION:DIRECTORY exit then
   v s" Present" STR= if e REMOTE0 MODEL-OBSERVATION:PRESENT exit then
   v UNKNOWN-REASON-OF MODEL-OBSERVATION:UNKNOWN ;

: DIRECTORY-OPERATION-OF ( str -- MODEL:operation )
   {: v :}
   v s" CreateLocalDirectory" STR= if
      MODEL-OPERATION:CREATE-LOCAL-DIRECTORY exit then
   v s" CreateRemoteDirectory" STR= if
      MODEL-OPERATION:CREATE-REMOTE-DIRECTORY exit then
   v s" DeleteLocalDirectory" STR= if
      MODEL-OPERATION:DELETE-LOCAL-DIRECTORY exit then
   MODEL-OPERATION:DELETE-REMOTE-DIRECTORY ;

: OPERATION-OF ( str bool -- MODEL:operation )
   {: v e:bool :}
   v s" CreateRemote" STR= if
      e C0 MODEL-OPERATION:CREATE-REMOTE exit then
   v s" InstallLocal" STR= if
      e REMOTE0 MODEL-OPERATION:INSTALL-LOCAL exit then
   v s" PreserveLocal" STR= if
      e LOCAL0 MODEL-OPERATION:PRESERVE-LOCAL exit then
   v s" ReplaceLocal" STR= if
      e REMOTE1 e C0 MODEL-OPERATION:REPLACE-LOCAL exit then
   v s" DeleteLocal" STR= if
      e C0 MODEL-OPERATION:DELETE-LOCAL exit then
   v s" PreserveRemote" STR= if
      e REMOTE0 MODEL-OPERATION:PRESERVE-REMOTE exit then
   v s" ReplaceRemote" STR= if
      e C1 e V0 MODEL-OPERATION:REPLACE-REMOTE exit then
   v s" DeleteRemote" STR= if
      e V0 MODEL-OPERATION:DELETE-REMOTE exit then
   v DIRECTORY-OPERATION-OF ;

: CONFLICT-OF ( str bool -- MODEL:conflict )
   {: v e:bool :}
   v s" InitialCollision" STR= if
      e LOCAL0 e REMOTE1 MODEL-CONFLICT:INITIAL exit then
   v s" DivergentEdits" STR= if
      e LOCAL0 e REMOTE1 MODEL-CONFLICT:DIVERGENT exit then
   v s" LocalDeletionRemoteEdit" STR= if
      e REMOTE1 MODEL-CONFLICT:LOCAL-DELETED exit then
   e LOCAL0 MODEL-CONFLICT:REMOTE-DELETED ;

: TAG ( bool -- str )
   {: e:bool :} s" insufficient_space" e OR-ESC ;

: BLOCKAGE-OF ( str bool -- MODEL:blockage )
   {: v e:bool :}
   v s" UnsupportedFileSize" STR= if
      MODEL-BLOCKAGE:UNSUPPORTED-FILE-SIZE exit then
   v s" RemoteRejected" STR= if
      e TAG MODEL-BLOCKAGE:REMOTE-REJECTED exit then
   v s" DownloadUnavailable" STR= if
      409 MODEL-BLOCKAGE:DOWNLOAD-UNAVAILABLE exit then
   v s" DownloadVerificationFailed" STR= if
      MODEL-BLOCKAGE:DOWNLOAD-VERIFICATION-FAILED exit then
   v s" StageOccupied" STR= if MODEL-BLOCKAGE:STAGE-OCCUPIED exit then
   v s" LocalObjectInWay" STR= if
      MODEL-BLOCKAGE:LOCAL-OBJECT-IN-WAY exit then
   v s" RemoteObject" STR= if MODEL-BLOCKAGE:REMOTE-OBJECT exit then
   MODEL-BLOCKAGE:CONFLICT-COPY-OCCUPIED ;

: HASH-RECORD ( MODEL:fingerprint DROPBOX:hash -- MODEL:hash-record )
   {: f:MODEL:fingerprint c:DROPBOX:hash :}
   s" x" MODEL:>PATH f c MODEL-HASH--RECORD:MAKE ;

\ One line's checks: its variant label, whether it is an .escapes line,
\ and its JSON.
: BASELINE-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: v e BASELINE-OF swap MODEL:BASELINE>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>BASELINE
      swap MODEL:BASELINE>JSON ;] WRITES ;

: BLOCKAGE-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: v e BLOCKAGE-OF swap MODEL:BLOCKAGE>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>BLOCKAGE
      swap MODEL:BLOCKAGE>JSON ;] WRITES ;

: CONFLICT-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: v e CONFLICT-OF swap MODEL:CONFLICT>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>CONFLICT
      swap MODEL:CONFLICT>JSON ;] WRITES ;

: HASH-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: e C0 swap MODEL:HASH>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>HASH
      swap MODEL:HASH>JSON ;] WRITES ;

: REV-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: e V0 swap MODEL:REV>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>REV
      swap MODEL:REV>JSON ;] WRITES ;

: LOCAL-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: e LOCAL0 swap MODEL:LOCAL>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>LOCAL
      swap MODEL:LOCAL>JSON ;] WRITES ;

: REMOTE-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: e REMOTE0 swap MODEL:REMOTE>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>REMOTE
      swap MODEL:REMOTE>JSON ;] WRITES ;

: HASH-VALUE-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: FINGERPRINT e C0 HASH-RECORD
      swap MODEL:HASH-VALUE>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>HASH-VALUE HASH-RECORD
      swap MODEL:HASH-VALUE>JSON ;] WRITES ;

: LOCAL-OBSERVATION-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: v e LOCAL-OBSERVATION-OF
      swap MODEL:LOCAL-OBSERVATION>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>LOCAL-OBSERVATION
      swap MODEL:LOCAL-OBSERVATION>JSON ;] WRITES ;

: REMOTE-OBSERVATION-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: v e REMOTE-OBSERVATION-OF
      swap MODEL:REMOTE-OBSERVATION>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>REMOTE-OBSERVATION
      swap MODEL:REMOTE-OBSERVATION>JSON ;] WRITES ;

: OPERATION-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: v e OPERATION-OF swap MODEL:OPERATION>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>OPERATION
      swap MODEL:OPERATION>JSON ;] WRITES ;

: REASON-LINE ( str bool str -- )
   {: v e:bool j :}
   j [: v REASON-OF swap MODEL:UNKNOWN-REASON>JSON ;] WRITES
   j [: j AR @ MODEL:JSON>UNKNOWN-REASON
      swap MODEL:UNKNOWN-REASON>JSON ;] WRITES ;

\ A label's type, then its variant and whether it is an .escapes line.
: LABEL ( str -- str str bool )
   {: s :}
   s PERIOD 0 SPLIT-NEXT drop {: at:n :}
   s str> {: l:^ lu:n :}
   l at + lu at - >str {: v :}
   v s" .escapes" ENDS-WITH? {: e:bool :}
   v STR:len {: vu:n :}
   v STR:data e if vu 8 - else vu then >str e ;

: JSON-LINE ( str -- )
   {: line :}
   line TAB 0 SPLIT-NEXT drop {: next:n :}
   LABEL {: t v e:bool :}
   line str> {: l:^ lu:n :}
   l next + lu next - >str {: j :}
   v e j
   t s" Baseline" STR= if BASELINE-LINE exit then
   t s" BlockReason" STR= if BLOCKAGE-LINE exit then
   t s" Conflict" STR= if CONFLICT-LINE exit then
   t s" ContentIdentity" STR= if HASH-LINE exit then
   t s" DropboxRevision" STR= if REV-LINE exit then
   t s" LocalFile" STR= if LOCAL-LINE exit then
   t s" LocalHashValue" STR= if HASH-VALUE-LINE exit then
   t s" LocalObservation" STR= if LOCAL-OBSERVATION-LINE exit then
   t s" Operation" STR= if OPERATION-LINE exit then
   t s" RemoteFile" STR= if REMOTE-LINE exit then
   t s" RemoteObservation" STR= if REMOTE-OBSERVATION-LINE exit then
   t s" UnknownReason" STR= if REASON-LINE exit then
   drop drop drop s" a json.tsv type" s" none" T$= ;

: JSON-FROM ( str n -- n )
   {: t at:n :}
   t LF at SPLIT-NEXT 0= if drop drop 0 exit then
   {: line next:n :}
   line STR:len 0= if t next RECURSE exit then
   line JSON-LINE
   t next RECURSE 1+ ;

: JSON-CASE ( -- )
   s" json.tsv" T-LABEL
   s" src/oracle/json.tsv" {: f :}
   AR @ f FS:FILE-SIZE ARENA:ALLOC {: t:^ u:n :}
   f t u FS:READ-ALL u T=
   t u >str 0 JSON-FROM t u >str LINES T= ;


\ Each text reads as the value the second text, serde's bytes, holds.
: READS-REMOTE ( str str -- )
   {: s j :}
   j [: s AR @ MODEL:JSON>REMOTE
      swap MODEL:REMOTE>JSON ;] WRITES ;

: READS-BASELINE ( str str -- )
   {: s j :}
   j [: s AR @ MODEL:JSON>BASELINE
      swap MODEL:BASELINE>JSON ;] WRITES ;

: READS-FINGERPRINT ( str str -- )
   {: s j :}
   j [: s AR @ MODEL:JSON>FINGERPRINT
      swap MODEL:FINGERPRINT>JSON ;] WRITES ;

: READS-HASH-VALUE ( str str -- )
   {: s j :}
   j [: s AR @ MODEL:JSON>HASH-VALUE HASH-RECORD
      swap MODEL:HASH-VALUE>JSON ;] WRITES ;

: READS-HASH ( str str -- )
   {: s j :}
   j [: s AR @ MODEL:JSON>HASH
      swap MODEL:HASH>JSON ;] WRITES ;

: FP$ ( -- str )
   s\" {\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6}" ;

\ Whitespace between tokens, members in any order, any escape, and an
\ unknown member with its value, as serde reads them.
: ACCEPTED-CASE ( -- )
   s" reader accepts" T-LABEL
   s\"  \t\r\n{ \"revision\" : \"r\" ,\n\"content\":\"c\" } \n"
   s\" {\"content\":\"c\",\"revision\":\"r\"}" READS-REMOTE
   s\" {\"Pre\\u0073ent\":{\"c\\u006Fntent\":\"\\u0063\",\"revision\":\"\\/\"}}"
   s\" {\"Present\":{\"content\":\"c\",\"revision\":\"/\"}}" READS-BASELINE
   s\" \"\\ud83d\\ude00\\b\\f\\n\\r\\t\\u001f\\u00e9\""
   s\" \"\xF0\x9F\x98\x80\\b\\f\\n\\r\\t\\u001f\xC3\xA9\"" READS-HASH
   s\" {\"device\":7,\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6}"
   FP$ READS-FINGERPRINT
   s\" {\"changed_nanoseconds\":6,\"device\":{\"a\":[1,null,true]},\"changed_seconds\":5,\"modified_nanoseconds\":4,\"modified_seconds\":-3,\"size\":2,\"device\":\"x\",\"inode\":1}"
   FP$ READS-FINGERPRINT
   s\" {\"Present\":{\"content\":\"c\",\"revision\":\"r\",\"extra\":[]}}"
   s\" {\"Present\":{\"content\":\"c\",\"revision\":\"r\"}}" READS-BASELINE ;


\ Each text a reader refuses with E-STORED.
: REFUSES-REMOTE ( str -- )
   {: s :}
   [: s AR @ MODEL:JSON>REMOTE drop ;]
   MODEL:E-STORED TTHROWSQ ;

: REFUSES-BASELINE ( str -- )
   {: s :}
   [: s AR @ MODEL:JSON>BASELINE drop ;]
   MODEL:E-STORED TTHROWSQ ;

: REFUSES-BLOCKAGE ( str -- )
   {: s :}
   [: s AR @ MODEL:JSON>BLOCKAGE drop ;]
   MODEL:E-STORED TTHROWSQ ;

: REFUSES-FINGERPRINT ( str -- )
   {: s :}
   [: s AR @ MODEL:JSON>FINGERPRINT drop ;]
   MODEL:E-STORED TTHROWSQ ;

: REFUSES-HASH-VALUE ( str -- )
   {: s :}
   [: s AR @ MODEL:JSON>HASH-VALUE drop drop ;]
   MODEL:E-STORED TTHROWSQ ;

: REFUSES-HASH ( str -- )
   {: s :}
   [: s AR @ MODEL:JSON>HASH drop ;]
   MODEL:E-STORED TTHROWSQ ;

\ A fingerprint whose inode is the given number's text.
: FP-INODE$ ( str -- str )
   str> {: d:^ du:n :}
   s\" {\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6,\"inode\":"
   str> {: a:^ au:n :}
   AR @ au du + 1+ ARENA:ALLOC drop {: b:^ :}
   a b au BYTE-COPY d b au + du BYTE-COPY
   $7D b au + du + c!
   b au du + 1+ >str ;

: REFUSED-CASE ( -- )
   s" reader refuses" T-LABEL
   s\" \"Gone\"" REFUSES-BASELINE
   s\" {\"content\":\"c\"}" REFUSES-REMOTE
   s\" {\"content\":\"c\",\"revision\":\"r\",\"content\":\"c\"}" REFUSES-REMOTE
   s\" {\"content\":\"c\",\"revision\":\"r\",\"c\\u006fntent\":\"d\"}" REFUSES-REMOTE
   s\" {\"content\":1,\"revision\":\"r\"}" REFUSES-REMOTE
   s\" \"Present\"" REFUSES-BASELINE
   s\" {\"DownloadUnavailable\":{\"status\":\"409\"}}" REFUSES-BLOCKAGE
   s\" {\"DownloadUnavailable\":{\"status\":409.0}}" REFUSES-BLOCKAGE
   s\" {\"DownloadUnavailable\":{\"status\":65536}}" REFUSES-BLOCKAGE
   s\" {\"DownloadUnavailable\":{\"status\":-1}}" REFUSES-BLOCKAGE
   s\" {\"DownloadUnavailable\":{\"status\":-0}}" REFUSES-BLOCKAGE
   s" -1" FP-INODE$ REFUSES-FINGERPRINT
   s" 18446744073709551616" FP-INODE$ REFUSES-FINGERPRINT
   s\" {\"inode\":1,\"size\":2,\"modified_seconds\":9223372036854775808,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6}"
   REFUSES-FINGERPRINT
   s\" \"Absent\" x" REFUSES-BASELINE
   s\" \"Absent\"\"Absent\"" REFUSES-BASELINE
   s\" \"\xFF\"" REFUSES-HASH
   s\" \"\xC3\"" REFUSES-HASH
   s\" \"\\ud800\"" REFUSES-HASH
   s\" [\"c\",\"r\"]" REFUSES-REMOTE
   s\" {\"Present\":[\"c\",\"r\"]}" REFUSES-BASELINE
   s\" {\"Absent\":null}" REFUSES-BASELINE
   s\" {\"Absent\":null,\"Directory\":null}" REFUSES-BASELINE
   s\" {}" REFUSES-BASELINE
   s" " REFUSES-BASELINE ;

: HV$ ( -- str )
   s\" {\"fingerprint\":{\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6},\"content\":\"c\"}" ;

: HASH-VALUE-ORDER-CASE ( -- )
   s" hash value reads its members in any order" T-LABEL
   s\" {\"content\":\"c\",\"fingerprint\":{\"changed_nanoseconds\":6,\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5}}"
   HV$ READS-HASH-VALUE ;

: HASH-VALUE-UNKNOWN-CASE ( -- )
   s" hash value skips an unknown member, repeated or not" T-LABEL
   s\" {\"device\":[1],\"fingerprint\":{\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6},\"device\":{\"content\":7},\"content\":\"c\"}"
   HV$ READS-HASH-VALUE ;

: HASH-VALUE-REPEATED-CASE ( -- )
   s" hash value and fingerprint refuse a repeated member" T-LABEL
   s\" {\"fingerprint\":{\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6},\"content\":\"c\",\"cont\\u0065nt\":\"c\"}"
   REFUSES-HASH-VALUE
   s\" {\"fingerprint\":{\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6},\"content\":\"c\",\"fingerprint\":{}}"
   REFUSES-HASH-VALUE
   s\" {\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6,\"s\\u0069ze\":2}"
   REFUSES-FINGERPRINT ;

: FINGERPRINT-SIGNED-CASE ( -- )
   s" fingerprint's changed seconds is signed" T-LABEL
   s\" {\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":-5,\"changed_nanoseconds\":6}"
   dup READS-FINGERPRINT
   s\" {\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":9223372036854775808,\"changed_nanoseconds\":6}"
   REFUSES-FINGERPRINT ;

\ The cells keep the previous row's values, so a missing member must not
\ read them.
: HASH-VALUE-MISSING-CASE ( -- )
   s" hash value refuses a missing member after a full one" T-LABEL
   HV$ HV$ READS-HASH-VALUE
   s\" {\"fingerprint\":{\"inode\":1,\"size\":2,\"modified_seconds\":-3,\"modified_nanoseconds\":4,\"changed_seconds\":5,\"changed_nanoseconds\":6}}"
   REFUSES-HASH-VALUE ;


: CASES ( -- )
   FOLD-CASE
   CANONICAL-ORDER-IS-BYTEWISE-NOT-COMPONENT-WISE
   CANONICAL-PATHS-FOLD-CASE-AND-COMPARE-BY-BYTES
   SUBTREE-RANGE-HOLDS-EXACTLY-THE-PATHS-BENEATH-AN-ANCESTOR
   ONLY-TRUE-DESCENDANTS-ARE-BENEATH-AN-ANCESTOR
   PATHS-BEGIN-BY-COMPONENT
   PATHS-SORT-BY-COMPONENT
   DOCUMENTED-NAMES-AND-DESCENDANTS-ARE-EXCLUDED
   OTHER-NAMES-STILL-SYNC
   EQUALITY-CASE
   RECORD-EQUALITY-CASE
   UNKNOWN-TEXT-CASE
   s" OPERATION$" T-LABEL DIRECTORY-TEXT-CASE FILE-TEXT-CASE
   CONFLICT-TEXT-CASE
   JSON-CASE ACCEPTED-CASE REFUSED-CASE
   HASH-VALUE-ORDER-CASE HASH-VALUE-UNKNOWN-CASE HASH-VALUE-REPEATED-CASE
   FINGERPRINT-SIGNED-CASE HASH-VALUE-MISSING-CASE ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   HEAP:ALLOCATOR 0 [type] u8 VEC:NEW OUT !
   [: CASES ;] [: OUT @ VEC:DELETE AR @ ARENA:RELEASE ;] finally
   s" model-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

MODEL-TEST:RUN
