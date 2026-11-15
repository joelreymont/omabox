\ local-test.f - LOCAL's shared words: local.rs's tests that an entry's
\ existence below the root never follows a symlink and takes a failed probe
\ as unconfirmed, that the content hash composes block hashes, and the
\ hashing half of its test that the hash does not depend on how a reader
\ fragments the bytes; and LOCAL's scan: local.rs's scan tests but the
\ parallel one, each journal test keeping the half without the journal,
\ in the part LOCAL SCAN-TEST, which sees LOCAL's private types. Each case
\ that makes files works in its own directory under TMPDIR and removes it.
\ Run from the repository root: hb --load src/local-test.f </dev/null
require src/lib/test.f
require src/lib/fmt.f
require src/lib/arena.f
require src/lib/memory.f
require src/lib/property.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fd.f
require src/dropbox.f
require src/local.f

\ LOCAL reopened for the stream a fragmenting reader feeds.
package LOCAL
public
EXPORT HASH-STREAM
;package

\ LOCAL reopened for its scan's cases, which name its private types.
package LOCAL
private
package SCAN-TEST

TYPED-VARIABLE AR ^ARENA:arena

448 constant MODE-0700
-100 constant AT-FDCWD

\ ---- the case's tree

FS:PATHZ-CAP BUFFER: ROOT-BUF
variable ROOT-U
FS:PATHZ-CAP BUFFER: JOINED

: ROOT$ ( -- ^u8 n ) ROOT-BUF ROOT-U @ ;

\ The name below the case's root, valid until the next AT.
: AT ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   ROOT$ p u JOINED FS:JOIN-PATH JOINED swap ;

: WRITE ( ^u8 n ^u8 n -- ) {: p:^ u:n b:^ bu:n :} p u AT b bu FS:WRITE-ALL ;
: MKDIR ( ^u8 n -- ) AT FS:MAKE-DIR ;
: REMOVE ( ^u8 n -- ) AT FS:REMOVE-FILE ;
: DENY ( ^u8 n -- ) AT 0 FS:CHMOD-MODE ;
: ALLOW ( ^u8 n -- ) AT MODE-0700 FS:CHMOD-MODE ;

\ Runs q in a new root under TMPDIR, which it then removes.
: IN-CASE ( [ -- ] -- )
   {: q :}
   s" local-scan-test" FS:MKTEMP-DIR {: p:^ u:n :}
   p ROOT-BUF u BYTE-COPY u ROOT-U !
   [: q execute ;] [: ROOT$ FS:REMOVE-TREE ;] finally ;

64 BUFFER: READ-BUF

: CONTENT-OF ( ^u8 n -- ^u8 n ) AT READ-BUF 64 FS:READ-ALL READ-BUF swap ;

PROCESS-SYMBOLS
FUNCTION: UTIMENSAT-CALL utimensat ( n ^u8 ^u8 n -- i32 ) ;FUNCTION
FUNCTION: READLINK-CALL readlink ( ^u8 ^u8 n -- n ) ;FUNCTION

create TIMES 32 allot

\ Rust's force_changed: access and modification one second past the epoch.
: FORCE-CHANGED ( ^u8 n -- )
   AT FS:>PATHZ {: z:^ :}
   1 TIMES ! 0 TIMES 8 + ! 1 TIMES 16 + ! 0 TIMES 24 + !
   AT-FDCWD z TIMES 0 UTIMENSAT-CALL 0 T= ;

: LINK-OF ( ^u8 n -- ^u8 n )
   AT FS:>PATHZ READ-BUF 64 READLINK-CALL READ-BUF swap ;

\ ---- the scan's values

: ZEROS ( -- ^u8 n )
   s" 0000000000000000000000000000000000000000000000000000000000000000" ;

: STABLE ( -- option<cutoff> )
   $7FFFFFFFFFFFFFFF 999999999 CUTOFF-MAKE OPTION:SOME ;

: NO-CACHE ( -- ^VEC:vector<MODEL:hash-record> )
   AR @ [type] MODEL:hash-record NEW-VEC ;

: TEST-CACHE
   ( ^u8 n MODEL:fingerprint ^u8 n -- ^VEC:vector<MODEL:hash-record> )
   {: p:^ u:n f:MODEL:fingerprint c:^ cu:n :}
   NO-CACHE {: v :}
   p u >str MODEL:>PATH f c cu >str DROPBOX:>HASH MODEL-HASH--RECORD:MAKE
   v VEC:PUSH !
   v ;

\ Rust's fingerprint: the file's below the case's root.
: FINGERPRINT-AT ( ^u8 n -- MODEL:fingerprint )
   {: p:^ u:n :}
   ROOT$ s" open test scan root" OPEN-ROOT {: root:fd :}
   root p u s" open test scan file" OPEN-RELATIVE-REGULAR {: f:fd :}
   f p u s" inspect test scan file" STAT-FD p u FILE-FINGERPRINT
   f DISCARD root DISCARD ;

\ Rust's identity: the content hash of the bytes, read from a pipe.
: IDENTITY ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   FD:PIPE {: r:fd w:fd :}
   w p u FD:WRITE-FULL w DISCARD
   r AR @ DROPBOX-CONTENT-HASH r DISCARD
   DROPBOX:HASH>STR str> ;

: ROOT-SCAN ( -- complete-scan ) ROOT$ AR @ SCAN ;

: CACHED-SCAN ( ^VEC:vector<MODEL:hash-record> option<cutoff>
     [ -- option<cutoff> ] -- complete-scan )
   {: cache cut:option<cutoff> q :}
   ROOT$ cache cut q AR @ SCAN-WITH-CACHE-COMPLETED-AT ;

: ENUMERATE ( ^VEC:vector<MODEL:hash-record> option<cutoff>
     -- pending-scan )
   {: cache cut:option<cutoff> :}
   ROOT$ cache cut AR @ ENUMERATE-SCAN ;

: REUSABLE ( complete-scan -- ^VEC:vector<MODEL:hash-record> )
   COMPLETE-SCAN-UNMAKE nip ;

: PUBLISHED ( complete-scan -- n ) SCAN-OBSERVATIONS VEC:COUNT ;

: PENDING-ENTRIES ( pending-scan -- scan-entries )
   PENDING-SCAN-UNMAKE {: r:str f:fd b:stat en:scan-entries ar :} en ;

\ Closes the root a pending scan holds, as Rust's drop of one.
: RELEASE ( pending-scan -- )
   PENDING-SCAN-UNMAKE {: r:str f:fd b:stat en:scan-entries ar :}
   f DISCARD ;

\ The kind each observation is, and unknown's reason after it.
-1 constant MISSING
0 constant PRESENT
1 constant DIRECTORY
2 constant ABSENT
3 constant INCOMPLETE
4 constant INACCESSIBLE
5 constant UNSUPPORTED-KIND

: REASON-KIND ( MODEL:unknown-reason -- n )
   MATCH MODEL:unknown-reason
      incomplete OF INCOMPLETE ENDOF
      inaccessible OF INACCESSIBLE ENDOF
      unavailable OF 10 ENDOF
      stale OF 11 ENDOF
      cursor-reset OF 12 ENDOF
      unsupported OF UNSUPPORTED-KIND ENDOF
   ;MATCH ;

: KIND ( MODEL:observation<MODEL:local> -- n )
   MATCH MODEL:observation
      present OF {: l:MODEL:local :} PRESENT ENDOF
      directory OF DIRECTORY ENDOF
      absent OF ABSENT ENDOF
      unknown OF REASON-KIND ENDOF
   ;MATCH ;

: RECORD-OBSERVATION
   ( MODEL:local-record -- MODEL:observation<MODEL:local> )
   MODEL-LOCAL--RECORD:UNMAKE
   {: p:MODEL:path o:MODEL:observation<MODEL:local> :} o ;

\ The observation of the path, none where the scan published none.
: FIND ( complete-scan ^u8 n -- option<MODEL:local-record> )
   {: s:complete-scan p:^ u:n :}
   s SCAN-OBSERVATIONS {: v :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ {: r:MODEL:local-record :}
      r OBSERVATION-PATH p u STR= if r OPTION:SOME unloop exit then
   loop OPTION:NONE ;

: KIND-AT ( complete-scan ^u8 n -- n )
   FIND MATCH option
      none OF MISSING ENDOF
      some OF RECORD-OBSERVATION KIND ENDOF
   ;MATCH ;

: SEEN ( complete-scan ^u8 n n -- )
   {: s:complete-scan p:^ u:n want:n :}
   s p u KIND-AT want T= ;

\ Rust's scanned_content: a present file's content hash, else empty.
: SCANNED-CONTENT ( complete-scan ^u8 n -- ^u8 n )
   FIND MATCH option
      none OF s" " ENDOF
      some OF RECORD-OBSERVATION MATCH MODEL:observation
            present OF MODEL-LOCAL:UNMAKE DROPBOX:HASH>STR str> ENDOF
            directory OF s" " ENDOF
            absent OF s" " ENDOF
            unknown OF {: why:MODEL:unknown-reason :} s" " ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ Rust's observed_paths refuses a path published twice; the observations
\ are also in strictly increasing byte order.
: ORDERED ( complete-scan -- )
   SCAN-OBSERVATIONS {: v :}
   true v VEC:COUNT 1 max 1 ?do
      v i 1- VEC:AT OBSERVATION-PATH@ v i VEC:AT OBSERVATION-PATH@ STR< and
   loop TTRUE ;

: SAME-RECORDS
   ( ^VEC:vector<MODEL:hash-record> ^VEC:vector<MODEL:hash-record> -- )
   {: a b :}
   a VEC:COUNT b VEC:COUNT T=
   a VEC:COUNT b VEC:COUNT min 0 ?do
      a i VEC:AT @ {: x:MODEL:hash-record :}
      b i VEC:AT @ {: y:MODEL:hash-record :}
      x RECORD-PATH y RECORD-PATH T$=
      x RECORD-FINGERPRINT y RECORD-FINGERPRINT SAME-FINGERPRINT TTRUE
      x RECORD-CONTENT DROPBOX:HASH>STR str>
      y RECORD-CONTENT DROPBOX:HASH>STR str> T$=
   loop ;

\ ---- cases

: SCAN-PUBLISHES-EMPTY-AND-NESTED-DIRECTORIES ( -- )
   s" scan_publishes_empty_and_nested_directories" T-LABEL
   s" parent" MKDIR s" parent/child" MKDIR s" empty" MKDIR
   ROOT-SCAN {: s:complete-scan :}
   s ORDERED
   s s" empty" DIRECTORY SEEN
   s s" parent" DIRECTORY SEEN
   s s" parent/child" DIRECTORY SEEN ;

: FILES-REMOVED-DURING-HASHING-PUBLISH-AN-INCOMPLETE-DIRECTORY ( -- )
   s" files_removed_during_hashing_publish_an_incomplete_directory" T-LABEL
   s" nested" MKDIR
   s" kept" s" kept" WRITE
   s" nested/a-missing" s" a" WRITE
   s" nested/b-missing" s" b" WRITE
   NO-CACHE NO-CUTOFF ENUMERATE {: ps:pending-scan :}
   s" nested/a-missing" REMOVE s" nested/b-missing" REMOVE
   s" nested" FORCE-CHANGED
   ps FINISH-SCAN {: s:complete-scan :}
   s ORDERED
   s s" nested" INCOMPLETE SEEN
   s s" nested/a-missing" MISSING SEEN
   s s" nested/b-missing" MISSING SEEN
   s s" kept" PRESENT SEEN
   s PUBLISHED 2 T= ;

\ The half without the journal: the first scan's reusable hashes stand for
\ the cache it would publish, and the check that a failed scan leaves the
\ published inventory and cache alone is JOURNAL's. The throw carries no
\ path; only the root's change escapes FINISH-SCAN.
: CHANGED-ROOT-FAILS-THE-SCAN-AND-PRESERVES-THE-PUBLICATION ( -- )
   s" changed_root_fails_the_scan_and_preserves_the_publication" T-LABEL
   s" kept" s" kept" WRITE
   NO-CACHE STABLE [: STABLE ;] CACHED-SCAN REUSABLE {: cache :}
   s" a-missing" s" a" WRITE
   cache STABLE ENUMERATE {: ps:pending-scan :}
   s" a-missing" REMOVE
   [: ps FINISH-SCAN drop ;] E-CHANGED TTHROWSQ ;

: OBJECTS-ON-ANOTHER-DEVICE-ARE-UNSUPPORTED-AND-UNSCANNED ( -- )
   s" objects_on_another_device_are_unsupported_and_unscanned" T-LABEL
   s" volume" MKDIR
   s" volume/inside.txt" s" inside" WRITE
   s" outside.txt" s" outside" WRITE
   ROOT$ AR @ ENUMERATE-SCAN-ACROSS-DEVICES FINISH-SCAN
   {: across:complete-scan :}
   across ORDERED
   across s" volume" UNSUPPORTED-KIND SEEN
   across s" outside.txt" UNSUPPORTED-KIND SEEN
   across s" volume/inside.txt" MISSING SEEN
   across PUBLISHED 2 T=
   across REUSABLE VEC:COUNT 0 T=
   ROOT-SCAN {: same:complete-scan :}
   same s" volume" DIRECTORY SEEN
   same s" volume/inside.txt" PRESENT SEEN
   same s" outside.txt" PRESENT SEEN
   same PUBLISHED 3 T= ;

: CHANGING-FILES-ARE-UNKNOWN-WITHOUT-HIDING-STABLE-FILES ( -- )
   s" changing_files_are_unknown_without_hiding_stable_files" T-LABEL
   s" cached" s" before" WRITE
   NO-CACHE NO-CUTOFF [: STABLE ;] CACHED-SCAN REUSABLE {: cache :}
   s" hashing" s" before" WRITE
   s" stable" s" stable" WRITE
   cache STABLE ENUMERATE {: ps:pending-scan :}
   ps PENDING-ENTRIES JOBS VEC:COUNT 2 T=
   ps PENDING-ENTRIES CACHED VEC:COUNT 1 T=
   s" cached" s" changed after enumeration" WRITE
   s" hashing" s" also changed" WRITE
   ps FINISH-SCAN {: s:complete-scan :}
   s s" cached" INCOMPLETE SEEN
   s s" hashing" INCOMPLETE SEEN
   s s" stable" PRESENT SEEN ;

: UNCHANGED-SCAN-FILE-REUSES-CACHED-HASH-WITHOUT-READING-BYTES ( -- )
   s" unchanged_scan_file_reuses_cached_hash_without_reading_bytes" T-LABEL
   s" cached.txt" s" bytes that would hash differently" WRITE
   s" cached.txt" s" cached.txt" FINGERPRINT-AT ZEROS TEST-CACHE {: cache :}
   ROOT$ cache STABLE AR @ SCAN-WITH-CACHE-AT {: s:complete-scan :}
   s s" cached.txt" SCANNED-CONTENT ZEROS T$= ;

\ The half without the journal: the first scan's reusable hashes stand for
\ the cache JOURNAL would store and answer in path-byte order.
: FILE-BESIDE-A-SAME-NAMED-DIRECTORY-KEEPS-ITS-CACHED-HASH ( -- )
   s" file_beside_a_same_named_directory_keeps_its_cached_hash" T-LABEL
   s" x" MKDIR
   s" x.txt" s" beside the directory" WRITE
   s" x/y.txt" s" under the directory" WRITE
   NO-CACHE NO-CUTOFF [: STABLE ;] CACHED-SCAN REUSABLE {: cache :}
   cache VEC:COUNT 2 T=
   cache STABLE ENUMERATE {: ps:pending-scan :}
   ps PENDING-ENTRIES JOBS VEC:COUNT 0 T=
   ps PENDING-ENTRIES CACHED VEC:COUNT 2 T=
   ps RELEASE
   NO-CACHE NO-CUTOFF [: STABLE ;] CACHED-SCAN REUSABLE cache SAME-RECORDS ;

: RECENT-CACHE-ENTRY-IS-REHASHED-AND-OMITTED ( -- )
   s" recent_cache_entry_is_rehashed_and_omitted" T-LABEL
   s" recent.txt" s" actual bytes" WRITE
   s" recent.txt" FINGERPRINT-AT {: f:MODEL:fingerprint :}
   f MODEL-FINGERPRINT:UNMAKE {: i sz ms mn cs cn :}
   ms mn CUTOFF-MAKE OPTION:SOME {: cut:option<cutoff> :}
   s" recent.txt" f ZEROS TEST-CACHE cut [: NO-CUTOFF ;] CACHED-SCAN
   {: s:complete-scan :}
   s s" recent.txt" SCANNED-CONTENT s" actual bytes" IDENTITY T$=
   s REUSABLE VEC:COUNT 0 T= ;

\ The fingerprint with the field at idx flipped in its lowest bit.
: FLIPPED ( MODEL:fingerprint n -- MODEL:fingerprint )
   {: f:MODEL:fingerprint at:n :}
   f MODEL-FINGERPRINT:UNMAKE {: i sz ms mn cs cn :}
   i at 0 = if 1 xor then
   sz at 1 = if 1 xor then
   ms at 2 = if 1 xor then
   mn at 3 = if 1 xor then
   cs at 4 = if 1 xor then
   cn at 5 = if 1 xor then
   MODEL-FINGERPRINT:MAKE ;

: EVERY-FINGERPRINT-FIELD-MISMATCH-REHASHES-THE-FILE ( -- )
   s" every_fingerprint_field_mismatch_rehashes_the_file" T-LABEL
   s" changed.txt" s" actual bytes" WRITE
   s" changed.txt" FINGERPRINT-AT {: f:MODEL:fingerprint :}
   6 0 ?do
      s" changed.txt" f i FLIPPED ZEROS TEST-CACHE {: cache :}
      ROOT$ cache STABLE AR @ SCAN-WITH-CACHE-AT
      s" changed.txt" SCANNED-CONTENT s" actual bytes" IDENTITY T$=
   loop ;

: ZEROED ( MODEL:hash-record -- MODEL:hash-record )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :}
   p f ZEROS >str DROPBOX:>HASH MODEL-HASH--RECORD:MAKE ;

\ The half without the journal: a stored row with a device and its JSON
\ are JOURNAL's and MODEL's; here the first scan's record, its content
\ replaced by one only the cache could supply, is reused.
: CACHED-HASH-WITH-A-STORED-DEVICE-IS-REUSED ( -- )
   s" cached_hash_with_a_stored_device_is_reused" T-LABEL
   s" kept.txt" s" actual bytes" WRITE
   NO-CACHE NO-CUTOFF [: STABLE ;] CACHED-SCAN REUSABLE {: first :}
   first VEC:COUNT 1 T=
   NO-CACHE {: cache :}
   first 0 VEC:AT @ ZEROED cache VEC:PUSH !
   cache STABLE [: STABLE ;] CACHED-SCAN
   s" kept.txt" SCANNED-CONTENT ZEROS T$= ;

\ The half without the journal: the scan's reusable hashes are the cache
\ the publication stores.
: SCAN-PUBLICATION-USES-COMPLETION-CUTOFF-FOR-NEW-HASHES ( -- )
   s" scan_publication_uses_completion_cutoff_for_new_hashes" T-LABEL
   s" slow.txt" s" newly hashed" WRITE
   NO-CACHE NO-CUTOFF [: STABLE ;] CACHED-SCAN REUSABLE VEC:COUNT 1 T= ;

: EXCLUDED-TREE ( -- )
   s" kept.txt" s" kept" WRITE
   s" .DS_Store" s" Finder metadata" WRITE
   s" ~$private" MKDIR
   s" ~$private/child.txt" s" private" WRITE
   s" missing" s" .dropbox" AT FS:MAKE-SYMLINK ;

\ The half without the journal: the scan's reusable hashes are the cache
\ the publication stores.
: EXCLUDED-ENTRIES-ARE-NOT-OPENED-HASHED-OR-PUBLISHED ( -- )
   s" excluded_entries_are_not_opened_hashed_or_published" T-LABEL
   EXCLUDED-TREE
   s" ~$private" DENY
   [: NO-CACHE STABLE [: STABLE ;] CACHED-SCAN ;]
   [: s" ~$private" ALLOW ;] finally {: s:complete-scan :}
   s PUBLISHED 1 T=
   s s" kept.txt" PRESENT SEEN
   s REUSABLE VEC:COUNT 1 T=
   s" .DS_Store" CONTENT-OF s" Finder metadata" T$=
   s" ~$private/child.txt" CONTENT-OF s" private" T$=
   s" .dropbox" LINK-OF s" missing" T$= ;

: INACCESSIBLE-FILE-IS-UNKNOWN-BESIDE-A-READABLE-FILE ( -- )
   s" inaccessible_file_is_unknown_beside_a_readable_file" T-LABEL
   s" locked.txt" s" locked" WRITE
   s" open.txt" s" open" WRITE
   s" locked.txt" DENY
   ROOT-SCAN {: s:complete-scan :}
   s s" locked.txt" INACCESSIBLE SEEN
   s s" open.txt" PRESENT SEEN
   s PUBLISHED 2 T= ;

: DIRECTORY-CHANGED-DURING-THE-SCAN-HIDES-ITS-CONTENTS ( -- )
   s" directory_changed_during_the_scan_hides_its_contents" T-LABEL
   s" nested" MKDIR
   s" nested/file" s" bytes" WRITE
   s" stable.txt" s" stable" WRITE
   NO-CACHE NO-CUTOFF ENUMERATE {: ps:pending-scan :}
   s" nested/appeared" s" new" WRITE
   ps FINISH-SCAN {: s:complete-scan :}
   s s" nested" INCOMPLETE SEEN
   s s" nested/file" MISSING SEEN
   s s" nested/appeared" MISSING SEEN
   s s" stable.txt" PRESENT SEEN
   s PUBLISHED 2 T= ;

: NESTED-TREE ( -- )
   s" nested" MKDIR
   s" nested/kept.txt" s" kept below" WRITE
   s" stable.txt" s" stable" WRITE ;

\ The rescan Rust's two retained-hash cases end with.
: RESCAN-REUSES ( complete-scan -- )
   {: s:complete-scan :}
   s REUSABLE VEC:COUNT 2 T=
   s REUSABLE STABLE ENUMERATE {: ps:pending-scan :}
   ps PENDING-ENTRIES JOBS VEC:COUNT 0 T=
   ps PENDING-ENTRIES CACHED VEC:COUNT 2 T=
   ps RELEASE ;

\ The half without the journal: the first scan's reusable hashes stand for
\ the cache it would publish.
: A-DISCARDED-SUBTREE-KEEPS-ITS-VALIDATED-HASHES ( -- )
   s" a_discarded_subtree_keeps_its_validated_hashes" T-LABEL
   NESTED-TREE
   NO-CACHE NO-CUTOFF [: STABLE ;] CACHED-SCAN REUSABLE {: cache :}
   cache VEC:COUNT 2 T=
   cache STABLE ENUMERATE {: ps:pending-scan :}
   ps PENDING-ENTRIES JOBS VEC:COUNT 0 T=
   s" nested" FORCE-CHANGED
   ps [: STABLE ;] FINISH-SCAN-AT {: s:complete-scan :}
   s s" nested" INCOMPLETE SEEN
   s s" nested/kept.txt" MISSING SEEN
   s RESCAN-REUSES ;

: NESTED? ( ^u8 n -- bool )
   {: p:^ u:n :}
   p u s" nested" STR= if true exit then
   p u s" nested/" PREFIX? ;

\ Moves the cached hashes beneath "nested" to retained.
: RETAIN-NESTED ( scan-entries -- )
   {: en:scan-entries :}
   en SCAN-ENTRIES-UNMAKE {: o c r d j :}
   AR @ [type] MODEL:hash-record NEW-VEC {: kept :}
   c VEC:COUNT 0 ?do
      c i VEC:AT @ {: x:MODEL:hash-record :}
      x RECORD-PATH NESTED? if x r VEC:PUSH ! else x kept VEC:PUSH ! then
   loop
   r VEC:COUNT 1 T=
   c 0 VEC:RESIZE
   kept VEC:COUNT 0 ?do kept i VEC:AT @ c VEC:PUSH ! loop ;

\ Drops the observations and directories at or beneath "nested".
: DROP-NESTED ( scan-entries -- )
   {: en:scan-entries :}
   en SCAN-ENTRIES-UNMAKE {: o c r d j :}
   AR @ [type] MODEL:local-record NEW-VEC {: seen :}
   o VEC:COUNT 0 ?do
      o i VEC:AT @ {: x:MODEL:local-record :}
      x OBSERVATION-PATH NESTED? 0= if x seen VEC:PUSH ! then
   loop
   o 0 VEC:RESIZE
   seen VEC:COUNT 0 ?do seen i VEC:AT @ o VEC:PUSH ! loop
   AR @ [type] scanned-directory NEW-VEC {: kept :}
   d VEC:COUNT 0 ?do
      d i VEC:AT @ {: x:scanned-directory :}
      x SCANNED-DIRECTORY-UNMAKE {: p:str b:stat :}
      p str> NESTED? 0= if x kept VEC:PUSH ! then
   loop
   d 0 VEC:RESIZE
   kept VEC:COUNT 0 ?do kept i VEC:AT @ d VEC:PUSH ! loop ;

\ The half without the journal: the first scan's reusable hashes stand for
\ the cache it would publish. The enumeration is shaped as TRUNCATE leaves
\ it when an entry fails after its subtree was validated, which only a
\ concurrent writer reaches through the walk.
: HASHES-THE-WALK-RETAINED-REACH-THE-PUBLICATION ( -- )
   s" hashes_the_walk_retained_reach_the_publication" T-LABEL
   NESTED-TREE
   NO-CACHE NO-CUTOFF [: STABLE ;] CACHED-SCAN REUSABLE {: cache :}
   cache VEC:COUNT 2 T=
   cache STABLE ENUMERATE {: ps:pending-scan :}
   ps PENDING-ENTRIES {: en:scan-entries :}
   en JOBS VEC:COUNT 0 T=
   en RETAIN-NESTED
   en DROP-NESTED
   en s" nested" >str MODEL-UNKNOWN--REASON:incomplete UNKNOWN
   ps [: STABLE ;] FINISH-SCAN-AT {: s:complete-scan :}
   s s" nested" INCOMPLETE SEEN
   s s" nested/kept.txt" MISSING SEEN
   s RESCAN-REUSES ;

: TEST-RECORD ( ^u8 n DROPBOX:hash -- MODEL:hash-record )
   {: p:^ u:n c:DROPBOX:hash :}
   p u >str MODEL:>PATH 2 5 3 0 3 0 MODEL-FINGERPRINT:MAKE c
   MODEL-HASH--RECORD:MAKE ;

: TRUNCATING-A-FAILED-ENTRY-KEEPS-ITS-VALIDATED-HASHES ( -- )
   s" truncating_a_failed_entry_keeps_its_validated_hashes" T-LABEL
   s" bytes" IDENTITY >str DROPBOX:>HASH {: c:DROPBOX:hash :}
   AR @ NEW-ENTRIES {: en:scan-entries :}
   en SCAN-ENTRIES-UNMAKE {: o cf r d j :}
   s" before.txt" c TEST-RECORD cf VEC:PUSH !
   en MARK {: mk:scan-mark :}
   s" sub" >str MODEL:>PATH DIRECTORY-OBSERVATION MODEL-LOCAL--RECORD:MAKE
   o VEC:PUSH !
   s" sub/kept.txt" c TEST-RECORD cf VEC:PUSH !
   s" sub/fresh.txt" >str 2 5 3 0 3 0 MODEL-FINGERPRINT:MAKE HASH-JOB-MAKE
   j VEC:PUSH !
   en mk TRUNCATE
   en s" sub" >str MODEL-UNKNOWN--REASON:incomplete UNKNOWN
   cf VEC:COUNT 1 T=
   cf 0 VEC:AT RECORD-PATH@ s" before.txt" T$=
   r VEC:COUNT 1 T=
   r 0 VEC:AT RECORD-PATH@ s" sub/kept.txt" T$=
   j VEC:COUNT 0 T=
   o VEC:COUNT 1 T=
   o 0 VEC:AT @ {: x:MODEL:local-record :}
   x OBSERVATION-PATH s" sub" T$=
   x RECORD-OBSERVATION KIND INCOMPLETE T= ;

: CASES ( -- )
   [: SCAN-PUBLISHES-EMPTY-AND-NESTED-DIRECTORIES ;] IN-CASE
   [: FILES-REMOVED-DURING-HASHING-PUBLISH-AN-INCOMPLETE-DIRECTORY ;]
   IN-CASE
   [: CHANGED-ROOT-FAILS-THE-SCAN-AND-PRESERVES-THE-PUBLICATION ;] IN-CASE
   [: OBJECTS-ON-ANOTHER-DEVICE-ARE-UNSUPPORTED-AND-UNSCANNED ;] IN-CASE
   [: CHANGING-FILES-ARE-UNKNOWN-WITHOUT-HIDING-STABLE-FILES ;] IN-CASE
   [: UNCHANGED-SCAN-FILE-REUSES-CACHED-HASH-WITHOUT-READING-BYTES ;]
   IN-CASE
   [: FILE-BESIDE-A-SAME-NAMED-DIRECTORY-KEEPS-ITS-CACHED-HASH ;] IN-CASE
   [: RECENT-CACHE-ENTRY-IS-REHASHED-AND-OMITTED ;] IN-CASE
   [: EVERY-FINGERPRINT-FIELD-MISMATCH-REHASHES-THE-FILE ;] IN-CASE
   [: CACHED-HASH-WITH-A-STORED-DEVICE-IS-REUSED ;] IN-CASE
   [: SCAN-PUBLICATION-USES-COMPLETION-CUTOFF-FOR-NEW-HASHES ;] IN-CASE
   [: EXCLUDED-ENTRIES-ARE-NOT-OPENED-HASHED-OR-PUBLISHED ;] IN-CASE
   [: INACCESSIBLE-FILE-IS-UNKNOWN-BESIDE-A-READABLE-FILE ;] IN-CASE
   [: DIRECTORY-CHANGED-DURING-THE-SCAN-HIDES-ITS-CONTENTS ;] IN-CASE
   [: A-DISCARDED-SUBTREE-KEEPS-ITS-VALIDATED-HASHES ;] IN-CASE
   [: HASHES-THE-WALK-RETAINED-REACH-THE-PUBLICATION ;] IN-CASE
   TRUNCATING-A-FAILED-ENTRY-KEEPS-ITS-VALIDATED-HASHES ;

public

: SCAN-CASES ( ^ARENA:arena -- ) AR ! CASES ;

;package
public
EXPORT SCAN-TEST:SCAN-CASES
;package

package LOCAL-TEST
private

TYPED-VARIABLE AR ^ARENA:arena

$400000 constant BLOCK
448 constant MODE-0700

\ ---- entry existence

FS:PATHZ-CAP BUFFER: ROOT-BUF
variable ROOT-U
FS:PATHZ-CAP BUFFER: JOINED

: ROOT$ ( -- ^u8 n ) ROOT-BUF ROOT-U @ ;

\ The name below the case's directory, valid until the next AT.
: AT ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   ROOT$ p u JOINED FS:JOIN-PATH JOINED swap ;

: CASE-DIR ( -- )
   s" local-test" FS:MKTEMP-DIR {: p:^ u:n :}
   p ROOT-BUF u BYTE-COPY u ROOT-U ! ;

: ENTRY-TREE ( -- )
   s" dir" AT FS:MAKE-DIR
   s" dir/file.txt" AT s" bytes" FS:WRITE-ALL
   s" file.txt" AT s" bytes" FS:WRITE-ALL
   s" missing" s" dangling" AT FS:MAKE-SYMLINK
   s" dir" s" linked" AT FS:MAKE-SYMLINK
   s" denied" AT FS:MAKE-DIR ;

: EXISTS ( fd ^u8 n bool -- )
   {: root:fd p:^ u:n want:bool :}
   p u T-LABEL
   root p u LOCAL:ENTRY-EXISTS-AT want if TTRUE else TFALSE then ;

: ENTRY-CHECKS ( fd -- )
   {: root:fd :}
   root s" dir" true EXISTS
   root s" dir/file.txt" true EXISTS
   root s" dangling" true EXISTS
   root s" linked" true EXISTS
   root s" missing.txt" false EXISTS
   root s" missing/file.txt" false EXISTS
   root s" file.txt/child" false EXISTS
   root s" linked/file.txt" false EXISTS ;

\ Rust's deny_all_access, then allow_owner_access whatever the probe did.
: DENIED ( fd -- )
   {: root:fd :}
   s" denied" AT 0 FS:CHMOD-MODE
   [: root s" denied/file.txt" false EXISTS ;]
   [: s" denied" AT MODE-0700 FS:CHMOD-MODE ;] finally ;

: ENTRY-EXISTENCE-NEVER-FOLLOWS-SYMLINKS-AND-TREATS-PROBE-FAILURES-AS-UNCONFIRMED
   ( -- )
   CASE-DIR ENTRY-TREE
   ROOT$ s" open test root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root ENTRY-CHECKS root DENIED ;]
   [: root FS:CLOSE-DIR ROOT$ FS:REMOVE-TREE ;] finally ;

\ ---- content hashes

\ Rust's identity: the content hash of the bytes, read from a pipe.
: IDENTITY ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   FD:PIPE {: r:fd w:fd :}
   w p u FD:WRITE-FULL w FS:CLOSE-DIR
   r AR @ LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR
   DROPBOX:HASH>STR str> ;

: DROPBOX-HASH-USES-BLOCK-HASH-COMPOSITION ( -- )
   s" dropbox_hash_uses_block_hash_composition" T-LABEL
   s" " IDENTITY
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" T$=
   s" abc" IDENTITY
   s" 4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358" T$= ;

\ The bytes a FRAGMENT reader answers from, and the schedule of the most
\ each of its reads gives, taken in turn.
PTR-VARIABLE SOURCE
variable SOURCE-U
variable POSITION
variable NEXT-FRAGMENT
12 constant FRAGMENT-CAP
FRAGMENT-CAP TYPED-BUFFER FRAGMENTS n
variable FRAGMENT-COUNT

: SOURCE@ ( -- ^u8 ) SOURCE @ ;

: START ( ^u8 n -- )
   {: p:^ u:n :}
   p SOURCE ! u SOURCE-U ! 0 POSITION ! 0 NEXT-FRAGMENT ! ;

\ Rust's FragmentedReader: the next fragment's bytes, at most the span's.
: FRAGMENT ( ^u8 n -- n )
   {: dst:^ cap:n :}
   SOURCE-U @ POSITION @ - {: left:n :}
   cap 0= left 0= or if 0 exit then
   NEXT-FRAGMENT @ FRAGMENT-COUNT @ mod FRAGMENTS @ {: most:n :}
   left cap min most min {: k:n :}
   SOURCE@ POSITION @ + dst k BYTE-COPY
   k POSITION +! 1 NEXT-FRAGMENT +!
   k ;

\ Rust's patterned_bytes: one xorshift64 step per byte, its low byte.
: PATTERNED ( ^u8 n n -- )
   {: a:^ u:n seed:n :}
   seed 1 or
   u 0 ?do
      dup 13 lshift xor dup 7 rshift xor dup 17 lshift xor
      dup $FF and a i + c!
   loop drop ;

SHA256-CTX-BYTES BUFFER: WHOLE
SHA256-CTX-BYTES BUFFER: PART
32 BUFFER: DIGEST
64 BUFFER: HEX

\ Rust's reference_dropbox_hash: SHA-256 over each block's SHA-256.
: REFERENCE ( ^u8 n -- ^u8 n )
   {: a:^ u:n :}
   WHOLE SHA256-BEGIN
   0 begin dup u < while
      {: at:n :}
      u at - BLOCK min {: k:n :}
      PART a at + k DIGEST SHA256-IN
      WHOLE DIGEST 32 SHA256-FEED
      at k +
   repeat drop
   WHOLE DIGEST SHA256-END DIGEST HEX SHA256>HEX
   HEX 64 ;

\ Rust's hash_length_strategy, its random arm 2..=65536.
: LENGTH ( n -- n )
   case
      0 of 0 endof
      1 of 1 endof
      2 of BLOCK 1- endof
      3 of BLOCK endof
      4 of BLOCK 1+ endof
      5 of BLOCK 2 * 1- endof
      6 of BLOCK 2 * endof
      7 of BLOCK 2 * 1+ endof
      65535 PROP:RND% 2 + swap
   endcase ;

: PUT ( n n -- ) {: v:n idx:n :} v idx FRAGMENTS ! ;

\ Rust's fragment_strategy, its random arm 1 to 11 reads of 1..=128 KiB.
: SCHEDULE ( n -- )
   {: k:n :}
   k 0 = if
      1 0 PUT 7 1 PUT 4096 2 PUT 65535 3 PUT 4 FRAGMENT-COUNT ! exit
   then
   k 1 = if 17 0 PUT 1021 1 PUT 16384 2 PUT 3 FRAGMENT-COUNT ! exit then
   11 PROP:RND% 1+ {: count:n :}
   count 0 ?do 131072 PROP:RND% 1+ i PUT loop
   count FRAGMENT-COUNT ! ;

\ Case i takes length arm i mod 9 and schedule arm i mod 3.
: FRAGMENTED ( ^u8 n -- )
   {: bytes:^ i:n :}
   i 9 mod LENGTH {: u:n :}
   i 3 mod SCHEDULE
   bytes u 256 PROP:RND% PATTERNED
   bytes u REFERENCE {: want:^ wu:n :}
   bytes u START
   [: FRAGMENT ;] AR @ LOCAL:HASH-STREAM DROPBOX:HASH>STR str>
   want wu T$= ;

\ The hashing half of local.rs's property; its copy half waits for
\ copy_and_hash. Twelve cases, as proptest's, from a fixed seed.
: DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION ( -- )
   s" dropbox_hash_and_copy_are_independent_of_reader_fragmentation" T-LABEL
   1 PROP:SEED!
   BLOCK 2 * 1+ MEM:BYTES-ALLOC-LEN MEM:ALLOC-BYTES
   {: bytes:^ cap:NUM:alloc-byte-len :}
   [: 12 0 ?do bytes i FRAGMENTED loop ;]
   [: bytes cap MEM:RELEASE-BYTES ;] finally ;

: CASES ( -- )
   ENTRY-EXISTENCE-NEVER-FOLLOWS-SYMLINKS-AND-TREATS-PROBE-FAILURES-AS-UNCONFIRMED
   DROPBOX-HASH-USES-BLOCK-HASH-COMPOSITION
   DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION
   AR @ LOCAL:SCAN-CASES ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   [: CASES ;] [: AR @ ARENA:RELEASE ;] finally
   s" local-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

LOCAL-TEST:RUN
