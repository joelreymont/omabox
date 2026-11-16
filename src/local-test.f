\ local-test.f - LOCAL's shared words, scan, upload and download stages,
\ download slots and partials, installs, deletes, directories and
\ conflicts: local.rs's tests that an entry's existence below the root
\ never follows a symlink and takes a failed probe as unconfirmed, that
\ the content hash composes block hashes, and that neither the hash nor a
\ stage's copy depends on how a reader fragments the bytes; its scan
\ tests, the reason each failure one entry raises publishes among them,
\ but those the comment on CASES names, each journal test keeping the
\ half without the journal, in the part LOCAL SCAN-TEST, which sees
\ LOCAL's private types; that upload stage collection removes only
\ verified unreferenced content; then each stage outcome, each inspected
\ download stage, a stage marker set, read and removed, a second mark
\ failing with one xattr line on stderr, each upload stage outcome, an
\ upload source that vanished or is a directory, and each parent a
\ download opens; then that a slot's state keeps its last checkpoint,
\ that slot identity and state bytes are the Rust daemon's, a reset never
\ touches a replacement swapped in, the pool's four fixed slots, a
\ protected slot kept and a stale one rebound; then that a cut download
\ resumes from its last durable checkpoint, a completed partial is
\ promoted before or after its rename, a corrupt one restarts only in its
\ own slot, a promotion keeps a swapped replacement, a copy across
\ filesystems frees its slot, and a reset slot replays to offset 0, each
\ completed stage installed and read back at its target; then local.rs's
\ install tests, each install outcome, an install a directory or an
\ unreadable file at its stage's name blocks, each replacement
\ preparation, that a complete disposable download closes its parent, and
\ the scan lock test's half without the lock: a disposable partial
\ appended is staged and leaves its staging directory empty; then that
\ directory effects never overwrite or recurse, that a delete's replay
\ keeps a raced edit, and each delete, directory and conflict outcome. A
\ case that makes files works in its own directory under TMPDIR and
\ removes it.
\ Run from the repository root: hb --load src/local-test.f </dev/null
require src/lib/test.f
require src/lib/test/stderr.f
require src/lib/fmt.f
require src/lib/arena.f
require src/lib/memory.f
require src/lib/property.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fs-list.f
require src/lib/fd.f
require src/lib/xattr.f
require src/lib/adt/option.f
require src/dropbox.f
require src/model.f
require src/local.f

\ LOCAL reopened for the stream a fragmenting reader feeds, its stage
\ words, and the names of its private results' variants.
package LOCAL
private

\ The variant's name; a verified stage's descriptor is closed.
: DOWNLOAD-STAGE$ ( download-stage -- ^u8 n )
   MATCH download-stage
      missing OF s" missing" ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :} f DISCARD s" verified"
      ENDOF
      destination-occupied OF {: p:str :} s" destination-occupied" ENDOF
   ;MATCH ;

: INSPECTED$
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   INSPECT-DOWNLOAD-STAGE DOWNLOAD-STAGE$ ;

: MARKER$ ( fd ^u8 n ^u8 n -- ^u8 n )
   READ-DOWNLOAD-MARKER MATCH download-marker
      missing OF s" missing" ENDOF
      expected OF s" expected" ENDOF
      other OF s" other" ENDOF
   ;MATCH ;

\ WRITE-VERIFIED-STAGE's result as its caller sees it, the stage 0.
: WRITE-STAGE-OUTCOME
   ( fd ^u8 n ^u8 n DROPBOX:hash [ ^u8 n -- n ] option<str> ^u8 n
     ^ARENA:arena -- stage-outcome<n> )
   WRITE-VERIFIED-STAGE [: 0 ;] MAP-STAGE-WRITE ;

\ OPEN-PARENT's answer apart: its descriptor, name, parent path and true;
\ for none, -1, empty spans and false.
: PARENT-OF ( fd ^u8 n bool -- fd ^u8 n ^u8 n bool )
   OPEN-PARENT MATCH option
      none OF -1 >FD s" " s" " false ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str path:str :}
         f name str> path str> true
      ENDOF
   ;MATCH ;

\ The lease's slot, its binding and true; for none, -1, a zero binding
\ and false.
: LEASE-OF ( option<download-slot-lease> -- n binding bool )
   MATCH option
      none OF -1 0 0 0 0 BINDING-MAKE false ENDOF
      some OF DOWNLOAD-SLOT-LEASE-UNMAKE {: d:str slot:n b:binding :}
         slot b true
      ENDOF
   ;MATCH ;

: STATE-APART ( option<download-slot-state> -- binding n bool )
   MATCH option
      none OF 0 0 0 0 BINDING-MAKE 0 false ENDOF
      some OF DOWNLOAD-SLOT-STATE-UNMAKE true ENDOF
   ;MATCH ;

\ The slot's state apart: its binding, its offset and true.
: SLOT-STATE-OF ( fd ^u8 n -- binding n bool )
   READ-DOWNLOAD-SLOT-STATE STATE-APART ;

\ The state encoded and decoded again, apart.
: STATE-ROUND-TRIP ( binding n -- binding n bool )
   DOWNLOAD-SLOT-STATE-MAKE ENCODE-DOWNLOAD-SLOT-STATE
   DECODE-DOWNLOAD-SLOT-STATE STATE-APART ;

\ The slot state's bytes for the binding at offset, valid until the
\ next encode.
: STATE-BYTES ( binding n -- ^u8 n )
   DOWNLOAD-SLOT-STATE-MAKE ENCODE-DOWNLOAD-SLOT-STATE ;

32 BUFFER: FILLED

\ The binding whose 32 bytes are all c.
: FILLED-BINDING ( n -- binding )
   {: c:n :}
   32 0 ?do c FILLED i + c! loop
   FILLED BYTES>BINDING ;

\ The slot opened for writing and true; for a missing or occupied one,
\ -1 and false.
: OPENED-SLOT ( fd ^u8 n ^u8 n -- fd bool )
   OPEN-DOWNLOAD-SLOT MATCH download-slot-open
      missing OF -1 >FD false ENDOF
      file OF true ENDOF
      occupied OF -1 >FD false ENDOF
   ;MATCH ;

\ The preparation's partial; anything else ends the run, as Rust's test
\ returns an error.
: READY-PARTIAL ( download-preparation -- ^download-partial )
   MATCH download-preparation
      ready OF ENDOF
      complete OF DROP-STAGE-OUTCOME
         s" test expected a ready download partial" 1 die
      ENDOF
      ephemeral OF s" test expected a ready download partial" 1 die ENDOF
   ;MATCH ;

\ Whether the partial is an unnamed file in a staging directory, as
\ Rust's DownloadSource::Disposable.
: DISPOSABLE? ( ^download-partial -- bool )
   DOWNLOAD-PARTIAL-LOCATION SOURCE@ RESUMABLE? 0= ;

: LEASED ( option<download-slot-lease> -- download-slot-lease )
   MATCH option
      none OF s" test expected a download slot lease" 1 die ENDOF
      some OF ENDOF
   ;MATCH ;

\ Rust's tests' raw fsetxattr of the partial's stage marker, then fsync.
: MARK-PARTIAL ( ^download-partial ^ARENA:arena -- )
   {: x ar:^ARENA:arena :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   x PARTIAL-FILE DOWNLOAD-STAGE-XATTR
   loc TARGET@ loc EXPECTED@ ar STAGE-MARKER XATTR:ADD
   x PARTIAL-FILE FD:SYNC ;

\ Moves the partial's slot to its stage's name, as renameat NOREPLACE.
: RENAME-TO-STAGE ( ^download-partial -- bool )
   {: x :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   loc SOURCE@ MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         slots name str> loc TARGET-DIR@ loc STAGE-NAME@
         FS:TRY-RENAME-NEW-AT
      ENDOF
      disposable OF {: p:str :} false ENDOF
   ;MATCH ;

\ Empties the partial's slot and records offset 0 for its binding.
: ZERO-CHECKPOINT ( ^download-partial -- )
   {: x :}
   x PARTIAL-FILE 0 FD:RESIZE
   x DOWNLOAD-PARTIAL-LOCATION SOURCE@ MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         x PARTIAL-FILE DOWNLOAD-PARTIAL-XATTR
         b 0 DOWNLOAD-SLOT-STATE-MAKE ENCODE-DOWNLOAD-SLOT-STATE XATTR:SET
      ENDOF
      disposable OF {: p:str :} ENDOF
   ;MATCH
   x PARTIAL-FILE FD:SYNC ;

: PROMOTE-WITH
   ( ^download-partial [ -- ] ^ARENA:arena -- stage-outcome<n> )
   {: x before ar:^ARENA:arena :}
   x PARTIAL-FILE x DOWNLOAD-PARTIAL-LOCATION before ar
   PROMOTE-COMPLETED-SLOT-WITH ;

: COPY-PARTIAL ( ^download-partial ^ARENA:arena -- stage-outcome<n> )
   {: x ar:^ARENA:arena :}
   x PARTIAL-FILE x DOWNLOAD-PARTIAL-LOCATION ar COPY-COMPLETED-SLOT ;

: PARTIAL-STAGE-PATH ( ^download-partial -- ^u8 n )
   DOWNLOAD-PARTIAL-LOCATION STAGE-PATH@ ;

\ The name target t's stage of want takes.
: STAGE-NAME ( ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   s" download" t tu want ar INTERNAL-NAME ;

: DROP-INSTALL-OUTCOME ( install-outcome -- ) drop ;

\ The stage INSPECT-DOWNLOAD-STAGE verified for x; any other fails the
\ run.
: VERIFIED-STAGE ( install -- verified-download-stage )
   INSPECT-INSTALL-STAGE MATCH download-stage
      missing OF E-CHANGED throw ENDOF
      verified OF ENDOF
      destination-occupied OF {: p:str :} E-OCCUPIED throw ENDOF
   ;MATCH ;

\ Writes "mutant" over the sealed stage through w, opened before it.
: MUTATE ( fd -- )
   {: w:fd :}
   w FS:MODE-PRIVATE-FILE FD:MODE! w 0 FD:SEEK
   w s" mutant" FD:WRITE-FULL w FD:SYNC ;

: RENAME-REFUSED ( install verified-download-stage -- )
   {: x:install s:verified-download-stage :}
   [: x s RENAME-STAGE-INTO-ABSENT-TARGET DROP-INSTALL-OUTCOME ;]
   E-CHANGED TTHROWSQ ;

\ Verifies x's stage, mutates it through w, then renames it.
: RENAME-MUTATED ( install fd -- )
   {: x:install w:fd :}
   x VERIFIED-STAGE {: s:verified-download-stage :}
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   [: w MUTATE x s RENAME-REFUSED ;] [: f DISCARD ;] finally ;

\ RENAME-MUTATED on target t's install below the root fd at r, its
\ parent opened as INSTALL-DOWNLOAD-AT opens it.
: INSTALL-RENAME-MUTATED
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena fd -- )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena
      w:fd :}
   root t tu false OPEN-PARENT MATCH option
      none OF E-CHANGED throw ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         [: f name rel r ru t tu want ar INSTALL-OF w RENAME-MUTATED ;]
         [: f DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ PREPARE-REPLACEMENT-AT on target t below the root fd at r, its parent
\ opened as INSTALL-DOWNLOAD-AT opens it.
: PREPARE-BELOW
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- replacement-preparation )
   {: root:fd r:^ ru:n t:^ tu:n c:DROPBOX:hash ar:^ARENA:arena :}
   root t tu false OPEN-PARENT MATCH option
      none OF E-CHANGED throw ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         r ru rel str> ar JOIN {: dp:^ du:n :}
         [: f dp du name str> t tu c ar PREPARE-REPLACEMENT-AT ;]
         [: f DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ SYNC-RENAMED-DOWNLOAD of the file at t in dir, as a stage verified
\ now, refuses it: it carries no marker.
: RENAMED-WITHOUT-MARKER
   ( fd fd ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: f:fd dir:fd t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   f t tu s" inspect test download" STAT-FD t tu FILE-FINGERPRINT
   {: print:MODEL:fingerprint :}
   f print VERIFIED-DOWNLOAD-STAGE-MAKE {: s:verified-download-stage :}
   [: s dir t tu t tu want ar SYNC-RENAMED-DOWNLOAD ;]
   E-CHANGED TTHROWSQ ;

public
EXPORT READY-PARTIAL
EXPORT DISPOSABLE?
EXPORT LEASED
EXPORT MARK-PARTIAL
EXPORT RENAME-TO-STAGE
EXPORT ZERO-CHECKPOINT
EXPORT PROMOTE-WITH
EXPORT COPY-PARTIAL
EXPORT PARTIAL-STAGE-PATH
EXPORT PARTIAL-FILE
EXPORT PARTIAL-PATH
EXPORT DOWNLOAD-PARTIAL-XATTR
EXPORT DOWNLOAD-CHECKPOINT-BYTES
EXPORT DOWNLOAD-SLOT-NAME
EXPORT RESET-DOWNLOAD-SLOT-FILE-WITH
EXPORT TAKEN?
EXPORT LEASE-OF
EXPORT SLOT-STATE-OF
EXPORT STATE-ROUND-TRIP
EXPORT STATE-BYTES
EXPORT FILLED-BINDING
EXPORT OPENED-SLOT
EXPORT STAGE-NAME
EXPORT GUARD-NAME
EXPORT SYNC-INSTALLED-DOWNLOAD
EXPORT INSTALL-RENAME-MUTATED
EXPORT PREPARE-BELOW
EXPORT RENAMED-WITHOUT-MARKER
EXPORT INTERNAL-NAME
EXPORT PARENT-OF
EXPORT HASH-STREAM
EXPORT COPY-AND-HASH
EXPORT DOWNLOAD-STAGE-XATTR
EXPORT STAGE-MARKER
EXPORT SET-XATTR
EXPORT REMOVE-XATTR
EXPORT MARKER$
EXPORT INSPECTED$
EXPORT WRITE-STAGE-OUTCOME
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

\ A new directory under TMPDIR, its path copied to buf; the path's length.
: TEMP-DIR ( ^u8 n ^u8 -- n )
   {: pre:^ pu:n buf:^ :}
   pre pu FS:MKTEMP-DIR {: p:^ u:n :}
   p buf u BYTE-COPY u ;

\ Runs q in a new root under TMPDIR, which it then removes.
: IN-CASE ( [ -- ] -- )
   {: q :}
   s" local-scan-test" ROOT-BUF TEMP-DIR ROOT-U !
   [: q execute ;] [: ROOT$ FS:REMOVE-TREE ;] finally ;

FS:PATHZ-CAP BUFFER: OUTSIDE-BUF
variable OUTSIDE-U

: OUTSIDE$ ( -- ^u8 n ) OUTSIDE-BUF OUTSIDE-U @ ;

\ Runs q beside a new directory under TMPDIR, outside the case's root,
\ which it then removes.
: BESIDE-OUTSIDE ( [ -- ] -- )
   {: q :}
   s" local-scan-outside" OUTSIDE-BUF TEMP-DIR OUTSIDE-U !
   [: q execute ;] [: OUTSIDE$ FS:REMOVE-TREE ;] finally ;

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

FUNCTION: MKFIFO-CALL mkfifo ( ^u8 n -- i32 ) ;FUNCTION
FUNCTION: SOCKET-CALL socket ( n n n -- i32 ) ;FUNCTION
FUNCTION: BIND-CALL bind ( n ^u8 n -- i32 ) ;FUNCTION
FUNCTION: GETEUID-CALL geteuid ( -- i32 ) ;FUNCTION

384 constant MODE-0600
1 constant AF-UNIX
1 constant SOCK-STREAM
\ Linux sockaddr_un: a u16 sun_family, then a 108-byte sun_path.
110 BUFFER: SOCKADDR

\ A socket bound at the name below the case's root, as Rust's
\ UnixListener::bind leaves one; its descriptor.
: BOUND ( ^u8 n -- fd )
   AT {: p:^ u:n :}
   u 108 < TTRUE
   AF-UNIX SOCKADDR c! 0 SOCKADDR 1 + c!
   p SOCKADDR 2 + u BYTE-COPY 0 SOCKADDR 2 + u + c!
   AF-UNIX SOCK-STREAM 0 SOCKET-CALL {: s:n :}
   s 0 >= TTRUE
   s SOCKADDR u 3 + BIND-CALL 0 T=
   s >FD ;

FS:PATHZ-CAP BUFFER: TARGET

\ The name below the case's root, valid until the next TARGET-AT.
: TARGET-AT ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   ROOT$ p u TARGET FS:JOIN-PATH TARGET swap ;

\ Root opens a file and searches a directory whatever its mode.
: ROOT-USER? ( -- bool ) GETEUID-CALL 0 = ;

256 BUFFER: ERR

\ Runs q with fd 2 sent to stderr.txt below the case's root; what that
\ file then holds, after which it is removed.
: STDERR-OF ( [ -- ] -- ^u8 n )
   {: q :}
   s" stderr.txt" AT STDERR:CAPTURE
   [: q execute ;] [: STDERR:;CAPTURE ;] finally
   s" stderr.txt" AT ERR 256 FS:READ-ALL {: n :}
   s" stderr.txt" AT FS:REMOVE-FILE
   ERR n ;

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
   root p u s" open test scan file" E-IO E-UNSUPPORTED
   OPEN-RELATIVE-REGULAR {: f:fd :}
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
      x RECORD-FINGERPRINT y RECORD-FINGERPRINT SAME-FINGERPRINT? TTRUE
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

: FILE-LOCKED-AFTER-ENUMERATION-IS-INACCESSIBLE ( -- )
   s" file_locked_after_enumeration_is_inaccessible" T-LABEL
   s" locked.txt" s" locked" WRITE
   s" stable.txt" s" stable" WRITE
   NO-CACHE NO-CUTOFF ENUMERATE {: ps:pending-scan :}
   s" locked.txt" DENY
   ps FINISH-SCAN {: s:complete-scan :}
   s s" locked.txt" INACCESSIBLE SEEN
   s s" stable.txt" PRESENT SEEN ;

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

: ENUMERATE-SCAN-ACROSS-DEVICES ( ^u8 n ^ARENA:arena -- pending-scan )
   {: p:^ u:n ar:^ARENA:arena :}
   p u ar KEEP ar NEW-ENTRIES {: root:str en:scan-entries :}
   p u s" open sync root for scan" OPEN-ABSOLUTE-DIRECTORY {: rfd:fd :}
   rfd p u ROOT-STAT {: before:stat :}
   root en rfd before ar [type] MODEL:hash-record NEW-VEC NO-CUTOFF
   before STAT-DEV 1 xor ar ENUMERATE-SCAN-ON-DEVICE ;

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

: LINKED-OUTSIDE ( -- )
   s" kept.txt" s" kept" WRITE
   NO-CACHE STABLE [: STABLE ;] CACHED-SCAN REUSABLE {: cache :}
   cache VEC:COUNT 1 T=
   OUTSIDE$ s" unsupported-link" AT FS:MAKE-SYMLINK
   cache STABLE [: STABLE ;] CACHED-SCAN {: s:complete-scan :}
   s s" unsupported-link" UNSUPPORTED-KIND SEEN
   s s" kept.txt" PRESENT SEEN
   s PUBLISHED 2 T=
   s REUSABLE VEC:COUNT 1 T= ;

\ The half without the journal: the first scan's reusable hashes stand for
\ the cache it would publish, and the second's observations and reusable
\ hashes for the inventory and cache it publishes.
: SYMLINK-IS-PUBLISHED-AS-UNSUPPORTED-BESIDE-A-SYNCHRONIZED-FILE ( -- )
   s" symlink_is_published_as_unsupported_beside_a_synchronized_file"
   T-LABEL
   [: LINKED-OUTSIDE ;] BESIDE-OUTSIDE ;

: SPECIAL-ENTRIES-ARE-PUBLISHED-AS-UNSUPPORTED ( -- )
   s" special_entries_are_published_as_unsupported" T-LABEL
   s" regular.txt" s" regular" WRITE
   s" regular.txt" TARGET-AT s" link" AT FS:MAKE-SYMLINK
   s" fifo" AT FS:>PATHZ MODE-0600 MKFIFO-CALL 0 T=
   s" socket" BOUND {: sock:fd :}
   [: ROOT-SCAN ;] [: sock DISCARD ;] finally {: s:complete-scan :}
   s s" fifo" UNSUPPORTED-KIND SEEN
   s s" link" UNSUPPORTED-KIND SEEN
   s s" socket" UNSUPPORTED-KIND SEEN
   s s" regular.txt" PRESENT SEEN
   s PUBLISHED 4 T= ;

: INACCESSIBLE-FILE-IS-UNKNOWN-BESIDE-A-READABLE-FILE ( -- )
   s" inaccessible_file_is_unknown_beside_a_readable_file" T-LABEL
   s" locked.txt" s" locked" WRITE
   s" open.txt" s" open" WRITE
   s" locked.txt" DENY
   ROOT-SCAN {: s:complete-scan :}
   s s" locked.txt" INACCESSIBLE SEEN
   s s" open.txt" PRESENT SEEN
   s PUBLISHED 2 T= ;

: HASH-LOCKED ( fd -- )
   s" locked.txt" s" locked.txt" s" hash unreadable test file" AR @
   HASH-AT-IF-PRESENT drop ;

\ The throw carries no path; the one line it logs names it.
: UNREADABLE-REGULAR-FILE-IS-REPORTED-AS-UNREADABLE ( -- )
   s" unreadable_regular_file_is_reported_as_unreadable" T-LABEL
   ROOT-USER? if exit then
   s" locked.txt" s" locked" WRITE
   ROOT$ s" open test root" OPEN-ROOT {: root:fd :}
   s" locked.txt" DENY
   [: [: root HASH-LOCKED ;] E-UNREADABLE TTHROWSQ ;] STDERR-OF
   s" local path `locked.txt` is a file Omabox cannot read" CONTAINS?
   TTRUE
   root DISCARD ;

variable CAUGHT

: HASH-BELOW ( fd -- )
   s" file.txt" s" closed/file.txt"
   s" hash file below unsearchable parent" AR @
   HASH-AT-IF-PRESENT drop ;

\ The errno is read before the parent is searchable again.
: UNSEARCHABLE-PARENT-IS-AN-IO-FAILURE ( -- )
   s" unsearchable_parent_is_an_io_failure" T-LABEL
   ROOT-USER? if exit then
   s" closed" MKDIR
   s" closed/file.txt" s" inside" WRITE
   s" closed" AT s" open test parent" OPEN-ROOT {: parent:fd :}
   s" closed" AT MODE-0600 FS:CHMOD-MODE
   [: [: parent HASH-BELOW ;]
      [: FS:ERRNO CAUGHT ! s" closed" ALLOW ;] finally
   ;] E-IO TTHROWSQ
   CAUGHT @ FS:EACCES T=
   parent DISCARD ;

\ "earlier" is walked before "locked", so discarding the unreadable
\ subtree must not reach back into a sibling already collected.
: INACCESSIBLE-DIRECTORY-PUBLISHES-NOTHING-BENEATH-ITSELF ( -- )
   s" inaccessible_directory_publishes_nothing_beneath_itself" T-LABEL
   s" earlier" MKDIR
   s" earlier/inner.txt" s" inner" WRITE
   s" locked" MKDIR
   s" locked/secret.txt" s" secret" WRITE
   s" open.txt" s" open" WRITE
   s" locked" DENY
   [: ROOT-SCAN ;] [: s" locked" ALLOW ;] finally {: s:complete-scan :}
   s s" locked" INACCESSIBLE SEEN
   s s" locked/secret.txt" MISSING SEEN
   s s" earlier" DIRECTORY SEEN
   s s" earlier/inner.txt" PRESENT SEEN
   s s" open.txt" PRESENT SEEN
   s PUBLISHED 4 T= ;

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

: WRITE-OVER ( ^u8 n -- ) s" no longer a directory" WRITE ;

: LINK-OVER ( ^u8 n -- )
   {: p:^ u:n :}
   s" elsewhere" p u AT FS:MAKE-SYMLINK ;

\ Replaces an enumerated directory with what put makes at its name. The
\ reopen fails ENOTDIR or ELOOP, which the scan owes that one path; the
\ removal changed the parent, which carries the reason, so the whole
\ subtree beneath it leaves the publication.
: SWAPPED-SUBTREE-IS-INCOMPLETE ( [ ^u8 n -- ] -- )
   {: put :}
   s" outer" MKDIR s" outer/swapped" MKDIR
   s" outer/swapped/inside.txt" s" inside" WRITE
   s" outer/sibling.txt" s" sibling" WRITE
   s" kept.txt" s" kept" WRITE
   NO-CACHE NO-CUTOFF ENUMERATE {: ps:pending-scan :}
   s" outer/swapped/inside.txt" REMOVE
   s" outer/swapped" AT FS:REMOVE-DIR
   s" outer/swapped" put execute
   ps FINISH-SCAN {: s:complete-scan :}
   s s" outer" INCOMPLETE SEEN
   s s" outer/swapped" MISSING SEEN
   s s" outer/swapped/inside.txt" MISSING SEEN
   s s" outer/sibling.txt" MISSING SEEN
   s s" kept.txt" PRESENT SEEN
   s PUBLISHED 2 T= ;

: A-DIRECTORY-REPLACED-BY-A-FILE-IS-INCOMPLETE ( -- )
   s" a_directory_replaced_by_a_file_is_incomplete" T-LABEL
   [: WRITE-OVER ;] SWAPPED-SUBTREE-IS-INCOMPLETE ;

: A-DIRECTORY-REPLACED-BY-A-SYMLINK-IS-INCOMPLETE ( -- )
   s" a_directory_replaced_by_a_symlink_is_incomplete" T-LABEL
   [: LINK-OVER ;] SWAPPED-SUBTREE-IS-INCOMPLETE ;

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
   p u s" nested/" STARTS-WITH? ;

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

\ Linux asm-generic errnos FS does not name.
5 constant EIO
6 constant ENXIO
19 constant ENODEV
110 constant ETIMEDOUT

\ What a failure with the errno, raised against one entry, throws.
: RAISED ( n -- n )
   {: e:n :}
   [: e s" observe scanned entry" s" subject.txt" SYSCALL-FAILURE ;]
   ['] ENTRY-CODE? CONVERTING ;

: WALK-KIND ( n -- n ) WALK-UNKNOWN REASON-KIND ;

: ESCAPES ( n -- )
   RAISED {: code:n :}
   [: code WALK-KIND drop ;] E-IO TTHROWSQ ;

: READS-AS ( n n -- )
   {: e:n want:n :}
   e RAISED WALK-KIND want T= ;

\ A reason carries no path: the caller holds the one it observed.
: ONLY-EXHAUSTION-ESCAPES-A-FAILURE-RAISED-AGAINST-ONE-ENTRY ( -- )
   s" only_exhaustion_escapes_a_failure_raised_against_one_entry" T-LABEL
   FS:EMFILE ESCAPES FS:ENFILE ESCAPES
   FS:ENOMEM ESCAPES FS:ENOSPC ESCAPES
   FS:ENOENT INCOMPLETE READS-AS FS:ENOTDIR INCOMPLETE READS-AS
   FS:ELOOP INCOMPLETE READS-AS FS:ESTALE INCOMPLETE READS-AS
   \ Anticipated or not, an errno raised against one object concerns that
   \ object: the default is an unknown path, never a scan that stops.
   FS:EACCES INACCESSIBLE READS-AS FS:EPERM INACCESSIBLE READS-AS
   EIO INACCESSIBLE READS-AS ENXIO INACCESSIBLE READS-AS
   ETIMEDOUT INACCESSIBLE READS-AS ENODEV INACCESSIBLE READS-AS
   \ The walk meets an object it cannot synchronize; the hash stage
   \ already saw a regular file, so a different type there is a change.
   [: s" subject.txt" E-UNSUPPORTED UNSUPPORTED-FAILS ;]
   ['] ENTRY-CODE? CONVERTING {: odd:n :}
   odd WALK-KIND UNSUPPORTED-KIND T=
   odd REVISITED-UNKNOWN REASON-KIND INCOMPLETE T=
   \ A failure that is not about an object still stops the scan.
   [: s" subject.txt" UNSAFE ;] ['] ENTRY-CODE? CONVERTING
   {: bad:n :}
   [: bad WALK-KIND drop ;] E-UNSAFE-PATH TTHROWSQ ;

: CASES ( -- )
   [: SCAN-PUBLISHES-EMPTY-AND-NESTED-DIRECTORIES ;] IN-CASE
   [: FILES-REMOVED-DURING-HASHING-PUBLISH-AN-INCOMPLETE-DIRECTORY ;]
   IN-CASE
   [: FILE-LOCKED-AFTER-ENUMERATION-IS-INACCESSIBLE ;] IN-CASE
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
   [: SYMLINK-IS-PUBLISHED-AS-UNSUPPORTED-BESIDE-A-SYNCHRONIZED-FILE ;]
   IN-CASE
   [: SPECIAL-ENTRIES-ARE-PUBLISHED-AS-UNSUPPORTED ;] IN-CASE
   [: INACCESSIBLE-FILE-IS-UNKNOWN-BESIDE-A-READABLE-FILE ;] IN-CASE
   [: UNREADABLE-REGULAR-FILE-IS-REPORTED-AS-UNREADABLE ;] IN-CASE
   [: UNSEARCHABLE-PARENT-IS-AN-IO-FAILURE ;] IN-CASE
   [: INACCESSIBLE-DIRECTORY-PUBLISHES-NOTHING-BENEATH-ITSELF ;] IN-CASE
   [: DIRECTORY-CHANGED-DURING-THE-SCAN-HIDES-ITS-CONTENTS ;] IN-CASE
   [: A-DIRECTORY-REPLACED-BY-A-FILE-IS-INCOMPLETE ;] IN-CASE
   [: A-DIRECTORY-REPLACED-BY-A-SYMLINK-IS-INCOMPLETE ;] IN-CASE
   [: A-DISCARDED-SUBTREE-KEEPS-ITS-VALIDATED-HASHES ;] IN-CASE
   [: HASHES-THE-WALK-RETAINED-REACH-THE-PUBLICATION ;] IN-CASE
   TRUNCATING-A-FAILED-ENTRY-KEEPS-ITS-VALIDATED-HASHES
   ONLY-EXHAUSTION-ESCAPES-A-FAILURE-RAISED-AGAINST-ONE-ENTRY ;

public

: SCAN-CASES ( ^ARENA:arena -- ) AR ! CASES ;

;package
public
EXPORT SCAN-TEST:SCAN-CASES
EXPORT SCAN-TEST:ROOT-USER?
;package

package LOCAL-TEST
private

TYPED-VARIABLE AR ^ARENA:arena

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

\ Runs q on the case directory's fd, then removes the directory.
: IN-CASE-DIR ( [ fd -- ] -- )
   {: q :}
   CASE-DIR ROOT$ s" open test root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root q execute ;]
   [: root FS:CLOSE-DIR ROOT$ FS:REMOVE-TREE ;] finally ;

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
      u at - DROPBOX:BLOCK min {: k:n :}
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
      2 of DROPBOX:BLOCK 1- endof
      3 of DROPBOX:BLOCK endof
      4 of DROPBOX:BLOCK 1+ endof
      5 of DROPBOX:BLOCK 2 * 1- endof
      6 of DROPBOX:BLOCK 2 * endof
      7 of DROPBOX:BLOCK 2 * 1+ endof
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

1 BUFFER: ONE

: FULL? ( FD:fill -- bool )
   MATCH FD:fill
      full OF true ENDOF
      eof OF {: k:n :} false ENDOF
   ;MATCH ;

\ What COPY-AND-HASH gives an unnamed file in dir from the fragments.
: COPY ( fd -- ^u8 n fd )
   {: dir:fd :}
   dir FS:TEMP-AT {: f:fd :}
   [: FRAGMENT ;] f s" fragmented-download"
   s" test fragmented download copy" AR @ LOCAL:COPY-AND-HASH
   DROPBOX:HASH>STR str> f ;

\ The file's bytes from its start fill back, and nothing follows them.
: READ-BACK ( fd ^u8 n -- )
   {: f:fd back:^ u:n :}
   f 0 FD:SEEK
   f back u SPAN:MAKE FD:READ-EXACT FULL? TTRUE
   f ONE 1 SPAN:MAKE FD:READ-EXACT FULL? TFALSE ;

\ The bytes copied hash as want and read back as they were.
: COPIED ( ^u8 n ^u8 n fd ^u8 -- )
   {: bytes:^ u:n want:^ wu:n dir:fd back:^ :}
   bytes u START
   dir COPY {: c:^ cu:n f:fd :}
   [: c cu want wu T$= f back u READ-BACK bytes u back u STR= TTRUE ;]
   [: f FS:CLOSE-DIR ;] finally ;

\ Case i takes length arm i mod 9 and schedule arm i mod 3.
: FRAGMENTED ( ^u8 ^u8 fd n -- )
   {: bytes:^ back:^ dir:fd i:n :}
   i 9 mod LENGTH {: u:n :}
   i 3 mod SCHEDULE
   bytes u 256 PROP:RND% PATTERNED
   bytes u REFERENCE {: want:^ wu:n :}
   bytes u START
   [: FRAGMENT ;] AR @ LOCAL:HASH-STREAM DROPBOX:HASH>STR str>
   want wu T$=
   bytes u want wu dir back COPIED ;

: FRAGMENT-CASES ( fd ^u8 ^u8 -- )
   {: dir:fd bytes:^ back:^ :}
   12 0 ?do bytes back dir i FRAGMENTED loop ;

\ Twelve cases, as proptest's, from a fixed seed.
: DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION ( -- )
   s" dropbox_hash_and_copy_are_independent_of_reader_fragmentation" T-LABEL
   1 PROP:SEED!
   DROPBOX:BLOCK 2 * 1+ MEM:BYTES-ALLOC-LEN
   {: len:NUM:alloc-byte-len :}
   len MEM:ALLOC-BYTES {: bytes:^ cap:NUM:alloc-byte-len :}
   len MEM:ALLOC-BYTES {: back:^ cap2:NUM:alloc-byte-len :}
   [: [: bytes back FRAGMENT-CASES ;] IN-CASE-DIR ;]
   [: bytes cap MEM:RELEASE-BYTES back cap2 MEM:RELEASE-BYTES ;]
   finally ;

\ ---- download stages

: HASH-OF ( ^u8 n -- DROPBOX:hash ) IDENTITY >str DROPBOX:>HASH ;
: TARGET ( -- ^u8 n ) s" target.txt" ;
: WANT ( -- DROPBOX:hash ) s" remote" HASH-OF ;
: MARKER ( -- ^u8 n ) TARGET WANT AR @ LOCAL:STAGE-MARKER ;

: PUT-FILE ( ^u8 n ^u8 n -- )
   {: name:^ nu:n b:^ bu:n :}
   name nu AT b bu FS:WRITE-ALL ;

: OPEN-AT ( fd ^u8 n -- fd )
   FS:TRY-OPEN-READ-AT MATCH option
      none OF E-FS-OPEN throw ENDOF
      some OF ENDOF
   ;MATCH ;

: MARK ( fd ^u8 n -- )
   {: f:fd p:^ u:n :}
   f LOCAL:DOWNLOAD-STAGE-XATTR MARKER true p u s" test mark"
   LOCAL:SET-XATTR ;

\ The Rust daemon's marker for target.txt holding "remote".
: MARKER-IS-RUSTS ( -- )
   s" stage marker is the Rust daemon's" T-LABEL
   MARKER
   s" .omabox-download-marker-v1-650b14d6787578d77de1e8b7f15a0de414baf0aa96888b334fb9a1b1dd9fe93a"
   T$= ;

: UNMARK ( fd -- )
   LOCAL:DOWNLOAD-STAGE-XATTR s" marked" s" test unmark"
   LOCAL:REMOVE-XATTR ;

256 BUFFER: ERR

\ Marking an attribute that exists throws LOCAL's code with EEXIST, fd 2
\ sent to stderr.txt, which then holds XATTR's one line and is removed.
: ONE-XATTR-LINE ( fd ^u8 n -- )
   {: f:fd p:^ u:n :}
   s" stderr.txt" AT STDERR:CAPTURE
   [: [: f p u MARK ;] LOCAL:E-IO TTHROWSQ FS:ERRNO FS:EEXIST T= ;]
   [: STDERR:;CAPTURE ;] finally
   s" stderr.txt" AT ERR 256 FS:READ-ALL {: n :}
   s" stderr.txt" AT FS:REMOVE-FILE
   ERR n 10 COUNT-CHAR 1 T=
   ERR n s" xattr: fsetxattr" CONTAINS? TTRUE ;

: MARKER-CHECKS ( fd -- )
   {: f:fd :}
   f s" marked" MARK
   f MARKER s" marked" LOCAL:MARKER$ s" expected" T$=
   f s" other" s" marked" LOCAL:MARKER$ s" other" T$=
   f s" marked" ONE-XATTR-LINE
   f UNMARK
   f MARKER s" marked" LOCAL:MARKER$ s" missing" T$=
   f UNMARK ;

: MARKER-ROUND-TRIP ( fd -- )
   {: root:fd :}
   s" marked" s" remote" PUT-FILE
   root s" marked" OPEN-AT {: f:fd :}
   [: f MARKER-CHECKS ;] [: f FS:CLOSE-DIR ;] finally ;

: STAGE-MARKER-IS-SET-READ-AND-REMOVED ( -- )
   s" stage marker is set, read and removed" T-LABEL
   [: MARKER-ROUND-TRIP ;] IN-CASE-DIR ;

: INSPECTED ( fd ^u8 n ^u8 n -- )
   {: root:fd p:^ u:n want:^ wu:n :}
   p u T-LABEL
   root p u p u TARGET WANT AR @ LOCAL:INSPECTED$ want wu T$= ;

: OWNED-STAGE ( fd -- )
   {: root:fd :}
   s" owned" s" remote" PUT-FILE
   root s" owned" OPEN-AT {: f:fd :}
   [: f s" owned" MARK ;] [: f FS:CLOSE-DIR ;] finally ;

: INSPECT-CASES ( fd -- )
   {: root:fd :}
   s" foreign" s" mutant" PUT-FILE
   s" unmarked" s" remote" PUT-FILE
   root OWNED-STAGE
   root s" absent" s" missing" INSPECTED
   root s" foreign" s" destination-occupied" INSPECTED
   root s" unmarked" s" destination-occupied" INSPECTED
   root s" owned" s" verified" INSPECTED ;

: EACH-DOWNLOAD-STAGE-IS-INSPECTED ( -- )
   s" each download stage is inspected" T-LABEL
   [: INSPECT-CASES ;] IN-CASE-DIR ;

\ The outcome's variant, and its actual hash or path, else empty.
: OUTCOME$ ( LOCAL:stage-outcome<n> -- ^u8 n ^u8 n )
   MATCH LOCAL:stage-outcome
      staged OF drop s" staged" s" " ENDOF
      already-staged OF drop s" already-staged" s" " ENDOF
      content-changed OF {: c:DROPBOX:hash :}
         s" content-changed" c DROPBOX:HASH>STR str>
      ENDOF
      destination-occupied OF {: p:str :}
         s" destination-occupied" p str>
      ENDOF
   ;MATCH ;

\ Stages bytes at name, marked as target's owned download of "remote".
: STAGED ( fd ^u8 n ^u8 n -- ^u8 n ^u8 n )
   {: root:fd name:^ nu:n b:^ bu:n :}
   name nu T-LABEL
   b bu START 0 SCHEDULE
   root name nu name nu WANT [: FRAGMENT ;] MARKER >str OPTION:SOME
   s" test stage" AR @ LOCAL:WRITE-STAGE-OUTCOME OUTCOME$ ;

: STAGE-CASES ( fd -- )
   {: root:fd :}
   root s" fresh" s" remote" STAGED s" " T$= s" staged" T$=
   root s" fresh" s" remote" STAGED s" " T$= s" already-staged" T$=
   root s" fresh" s" verified" INSPECTED
   root s" changed" s" mutant" STAGED
   s" mutant" IDENTITY T$= s" content-changed" T$=
   root s" changed" LOCAL:ENTRY-EXISTS-AT TFALSE
   s" foreign" s" mutant" PUT-FILE
   root s" foreign" s" remote" STAGED
   s" foreign" T$= s" destination-occupied" T$= ;

: EACH-STAGE-OUTCOME-IS-REACHED ( -- )
   s" each stage outcome is reached" T-LABEL
   [: STAGE-CASES ;] IN-CASE-DIR ;

\ ---- upload stages

\ The bytes laid in the arena, so they outlive the next AT.
: HOLD ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   AR @ u ARENA:ALLOC {: dst:^ size:n :}
   p dst u BYTE-COPY dst u ;

: UPLOAD-ROOT ( -- ^u8 n ) s" root" AT HOLD ;
: STAGING ( -- ^u8 n ) s" staging" AT HOLD ;

: UPLOAD-DIRS ( -- ) s" root" AT FS:MAKE-DIR s" staging" AT FS:MAKE-DIR ;

\ The stage path of content c, valid until the next AT.
: STAGE-PATH ( DROPBOX:hash -- ^u8 n )
   {: c:DROPBOX:hash :}
   STAGING c DROPBOX:HASH>STR str> JOINED FS:JOIN-PATH JOINED swap ;

\ The entry's file type bits, 0 when nothing is there.
: KIND ( ^u8 n -- n )
   FS:TRY-LSTAT 0= if 0 exit then
   FS:STAT-MODE@ FS:S-IFMT and ;

64 BUFFER: CONTENTS-BUF

: CONTENTS ( ^u8 n -- ^u8 n )
   CONTENTS-BUF 64 FS:READ-ALL CONTENTS-BUF swap ;

\ Stages the file at name below the upload root as content want.
: UPLOAD-STAGE
   ( ^u8 n DROPBOX:hash -- LOCAL:stage-outcome<^LOCAL:staged-upload> )
   {: name:^ nu:n want:DROPBOX:hash :}
   UPLOAD-ROOT name nu STAGING want AR @ LOCAL:STAGE-UPLOAD ;

\ The hash of what the stage's verified descriptor reads.
: VERIFIED$ ( ^LOCAL:staged-upload -- ^u8 n )
   AR @ LOCAL:OPEN-VERIFIED-UPLOAD {: f:fd :}
   f AR @ LOCAL:DROPBOX-CONTENT-HASH f FS:CLOSE-DIR
   DROPBOX:HASH>STR str> ;

\ The outcome's variant, and the stage's verified hash, the actual hash
\ or the path.
: UPLOAD-OUTCOME$
   ( LOCAL:stage-outcome<^LOCAL:staged-upload> -- ^u8 n ^u8 n )
   MATCH LOCAL:stage-outcome
      staged OF {: rec:^ :} s" staged" rec VERIFIED$ ENDOF
      already-staged OF {: rec:^ :} s" already-staged" rec VERIFIED$
      ENDOF
      content-changed OF {: c:DROPBOX:hash :}
         s" content-changed" c DROPBOX:HASH>STR str>
      ENDOF
      destination-occupied OF {: p:str :}
         s" destination-occupied" p str>
      ENDOF
   ;MATCH ;

: SAME-HASH? ( DROPBOX:hash DROPBOX:hash -- bool )
   {: a:DROPBOX:hash b:DROPBOX:hash :}
   a DROPBOX:HASH>STR str> b DROPBOX:HASH>STR str> STR= ;

\ The entries local.rs's collection test lays in the staging directory.
: COLLECTION-ENTRIES ( DROPBOX:hash DROPBOX:hash DROPBOX:hash -- )
   {: corrupt:DROPBOX:hash directory:DROPBOX:hash link:DROPBOX:hash :}
   corrupt STAGE-PATH s" different bytes" FS:WRITE-ALL
   directory STAGE-PATH FS:MAKE-DIR
   s" root/retained" AT HOLD link STAGE-PATH FS:MAKE-SYMLINK
   s" staging/unrecognized" s" leave me" PUT-FILE ;

: COLLECTION-CHECKS
   ( DROPBOX:hash DROPBOX:hash DROPBOX:hash DROPBOX:hash DROPBOX:hash -- )
   {: retained:DROPBOX:hash orphan:DROPBOX:hash corrupt:DROPBOX:hash
      directory:DROPBOX:hash link:DROPBOX:hash :}
   retained STAGE-PATH KIND FS:S-IFREG T=
   orphan STAGE-PATH KIND 0 T=
   corrupt STAGE-PATH CONTENTS s" different bytes" T$=
   directory STAGE-PATH KIND FS:S-IFDIR T=
   link STAGE-PATH KIND FS-ABI:S-IFLNK T=
   s" staging/unrecognized" AT CONTENTS s" leave me" T$= ;

: COLLECTION-CASE ( -- )
   UPLOAD-DIRS
   s" root/retained" s" pending bytes" PUT-FILE
   s" root/orphan" s" completed bytes" PUT-FILE
   s" pending bytes" HASH-OF {: retained:DROPBOX:hash :}
   s" completed bytes" HASH-OF {: orphan:DROPBOX:hash :}
   s" claimed bytes" HASH-OF {: corrupt:DROPBOX:hash :}
   s" directory entry" HASH-OF {: directory:DROPBOX:hash :}
   s" symlink entry" HASH-OF {: link:DROPBOX:hash :}
   s" retained" retained UPLOAD-STAGE UPLOAD-OUTCOME$ 2drop
   s" staged" T$=
   s" orphan" orphan UPLOAD-STAGE UPLOAD-OUTCOME$ 2drop s" staged" T$=
   corrupt directory link COLLECTION-ENTRIES
   STAGING [: retained SAME-HASH? ;] AR @
   LOCAL:REMOVE-UNREFERENCED-UPLOAD-STAGES 1 T=
   retained orphan corrupt directory link COLLECTION-CHECKS ;

: UPLOAD-STAGE-COLLECTION-REMOVES-ONLY-VERIFIED-UNREFERENCED-CONTENT
   ( -- )
   s" upload_stage_collection_removes_only_verified_unreferenced_content"
   T-LABEL
   [: drop COLLECTION-CASE ;] IN-CASE-DIR ;

\ A directory at the stage's path answers destination-occupied, a
\ converted failure, so no LOCAL line goes to stderr.txt, which is removed.
: OCCUPIED-QUIETLY ( ^u8 n DROPBOX:hash -- )
   {: name:^ nu:n want:DROPBOX:hash :}
   s" stderr.txt" AT STDERR:CAPTURE
   [: name nu want UPLOAD-STAGE UPLOAD-OUTCOME$ HOLD
      want STAGE-PATH T$= s" destination-occupied" T$= ;]
   [: STDERR:;CAPTURE ;] finally
   s" stderr.txt" AT ERR 256 FS:READ-ALL {: n :}
   s" stderr.txt" AT FS:REMOVE-FILE
   n 0 T= ;

\ Each outcome STAGE-UPLOAD answers, from one source file.
: UPLOAD-OUTCOME-CASES ( -- )
   UPLOAD-DIRS
   s" root/source" s" source bytes" PUT-FILE
   s" source bytes" HASH-OF {: want:DROPBOX:hash :}
   want DROPBOX:HASH>STR str> {: w:^ wu:n :}
   s" staged" T-LABEL
   s" source" want UPLOAD-STAGE UPLOAD-OUTCOME$ w wu T$= s" staged" T$=
   s" already staged" T-LABEL
   s" source" want UPLOAD-STAGE UPLOAD-OUTCOME$
   w wu T$= s" already-staged" T$=
   s" content changed" T-LABEL
   s" other bytes" HASH-OF {: other:DROPBOX:hash :}
   s" source" other UPLOAD-STAGE UPLOAD-OUTCOME$
   w wu T$= s" content-changed" T$=
   other STAGE-PATH KIND 0 T=
   s" destination occupied" T-LABEL
   s" root/occupied" s" occupied bytes" PUT-FILE
   s" occupied bytes" HASH-OF {: occupied:DROPBOX:hash :}
   occupied STAGE-PATH FS:MAKE-DIR
   s" occupied" occupied OCCUPIED-QUIETLY ;

: EACH-UPLOAD-STAGE-OUTCOME-IS-REACHED ( -- )
   s" each upload stage outcome is reached" T-LABEL
   [: drop UPLOAD-OUTCOME-CASES ;] IN-CASE-DIR ;

\ STAGE-UPLOAD-AT of r below the root as content want, its outcome
\ dropped.
: STAGE-AT ( fd ^u8 n DROPBOX:hash -- )
   {: root:fd r:^ ru:n want:DROPBOX:hash :}
   root r ru STAGING want AR @ LOCAL:STAGE-UPLOAD-AT
   UPLOAD-OUTCOME$ 2drop 2drop ;

: OBSERVE-AT ( fd ^u8 n -- )
   AR @ LOCAL:OBSERVE-UPLOAD-SOURCE-AT DROPBOX:HASH>STR str> 2drop ;

: SOURCE-CHANGED-CASES ( fd -- )
   {: root:fd :}
   UPLOAD-DIRS
   s" source bytes" HASH-OF {: want:DROPBOX:hash :}
   s" vanished source stages" T-LABEL
   [: root s" vanished" want STAGE-AT ;] LOCAL:E-SOURCE-CHANGED TTHROWSQ
   FS:ERRNO FS:ENOENT T=
   s" vanished source is observed" T-LABEL
   [: root s" vanished" OBSERVE-AT ;] LOCAL:E-SOURCE-CHANGED TTHROWSQ
   s" directory source stages" T-LABEL
   s" directory" AT FS:MAKE-DIR
   [: root s" directory" want STAGE-AT ;] LOCAL:E-SOURCE-CHANGED TTHROWSQ ;

: VANISHED-OR-DIRECTORY-SOURCE-IS-SOURCE-CHANGED ( -- )
   s" vanished or directory source is source-changed" T-LABEL
   [: SOURCE-CHANGED-CASES ;] IN-CASE-DIR ;

\ ---- download slots

\ One case of Rust's property: the checkpoint at or below x round-trips,
\ is the last at or before x, and is a whole number of blocks.
: CHECKPOINT ( n -- )
   {: x:n :}
   LOCAL:DOWNLOAD-CHECKPOINT-BYTES {: cp:n :}
   x cp / cp * {: offset:n :}
   7 LOCAL:FILLED-BINDING {: seven:LOCAL:binding :}
   seven offset LOCAL:STATE-ROUND-TRIP
   {: b:LOCAL:binding at:n found:bool :}
   found TTRUE at offset T= b seven LOCAL:BINDING= TTRUE
   offset x <= TTRUE x offset cp + < TTRUE
   offset DROPBOX:BLOCK mod 0 T= ;

64 BUFFER: UNHEXED

\ The byte the two hex digits at p spell.
: HEX-BYTE ( ^u8 -- n )
   {: p:^ :}
   p c@ STR-HEX-DIGIT-VALUE 4 lshift p 1+ c@ STR-HEX-DIGIT-VALUE or ;

\ The bytes the hex digits spell, valid until the next.
: UNHEX ( ^u8 n -- ^u8 n )
   {: h:^ hu:n :}
   hu 2 / 0 ?do h i 2 * + HEX-BYTE UNHEXED i + c! loop
   UNHEXED hu 2 / ;

\ Rust's DownloadSlotIdentity::new and encode_download_slot_state; the
\ binding is sha256sum of Rust's input for this download.
: SLOT-BYTES-ARE-RUSTS ( -- )
   s" slot identity and state bytes are the Rust daemon's" T-LABEL
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   >str DROPBOX:>HASH s" 015f1a2b3c4d" >str DROPBOX:>REV
   MODEL-REMOTE:MAKE {: r:MODEL:remote :}
   7 42 s" Docs/a.txt" r LOCAL:NEW-SLOT-IDENTITY LOCAL:SLOT-BINDING
   $0102030405060708 LOCAL:STATE-BYTES {: p:^ u:n :}
   u 63 T=
   p 23 s" omabox-download-slot-v1" T$=
   p 23 + 32
   s" 5ab14b7f1ecd878a5ce03fa13ad45efd36df5aad8c4bef0129fefdc17a4b9430"
   UNHEX T$=
   p 55 + 8 s" 0102030405060708" UNHEX T$= ;

\ Rust's range is 0 to 1024 checkpoints and a block; its boundaries are
\ 0, each checkpoint and the bytes either side of it, and the last.
: DOWNLOAD-CHECKPOINT-STATE-ENCODES-THE-LAST-COMPLETE-BOUNDARY ( -- )
   s" download_checkpoint_state_encodes_the_last_complete_boundary"
   T-LABEL
   LOCAL:DOWNLOAD-CHECKPOINT-BYTES {: cp:n :}
   0 CHECKPOINT
   1025 1 ?do
      i cp * 1- CHECKPOINT i cp * CHECKPOINT i cp * 1+ CHECKPOINT
   loop
   1024 cp * DROPBOX:BLOCK + CHECKPOINT ;

32 BUFFER: TEXT-BUF

\ The prefix and n's digits, valid until the next.
: NUMBERED ( ^u8 n n -- ^u8 n )
   {: x:^ xu:n k:n :}
   x TEXT-BUF xu BYTE-COPY
   k FMT:INT$ {: d:^ du:n :}
   d TEXT-BUF xu + du BYTE-COPY
   TEXT-BUF xu du + ;

\ Rust's test_slot_identity: target t's download of c at "revision-<op>".
: SLOT-IDENTITY
   ( ^u8 n DROPBOX:hash n n -- LOCAL:download-slot-identity )
   {: t:^ tu:n c:DROPBOX:hash generation:n op:n :}
   c s" revision-" op NUMBERED >str DROPBOX:>REV MODEL-REMOTE:MAKE
   {: r:MODEL:remote :}
   generation op t tu r LOCAL:NEW-SLOT-IDENTITY ;

: DOWNLOAD ( -- DROPBOX:hash ) s" download" HASH-OF ;

\ The lease of the case directory's slots for the identity, apart.
: LEASE
   ( ^u8 n DROPBOX:hash n n [ LOCAL:binding -- bool ]
     -- n LOCAL:binding bool )
   {: t:^ tu:n c:DROPBOX:hash generation:n op:n protected :}
   t tu c generation op SLOT-IDENTITY {: id:LOCAL:download-slot-identity :}
   ROOT$ id protected LOCAL:LEASE-DOWNLOAD-SLOT LOCAL:LEASE-OF ;

: UNPROTECTED ( LOCAL:binding -- bool ) drop false ;

TYPED-VARIABLE HELD-BINDING LOCAL:binding
: HELD? ( LOCAL:binding -- bool ) HELD-BINDING @ LOCAL:BINDING= ;

4 TYPED-BUFFER LEASED LOCAL:binding
variable LEASED-COUNT

: LEASED? ( LOCAL:binding -- bool )
   {: b:LOCAL:binding :}
   LEASED-COUNT @ 0 ?do
      i LEASED @ b LOCAL:BINDING= if true unloop exit then
   loop false ;

: SLOT-AT ( n -- ^u8 n ) LOCAL:DOWNLOAD-SLOT-NAME AT ;

64 BUFFER: HELD-BYTES

\ The file at the path holds exactly the bytes.
: HOLDS ( ^u8 n ^u8 n -- )
   {: p:^ u:n b:^ bu:n :}
   p u HELD-BYTES 64 FS:READ-ALL {: k:n :}
   HELD-BYTES k b bu T$= ;

\ The open file carries the binding at offset at.
: STATE-IS ( fd ^u8 n LOCAL:binding n -- )
   {: f:fd name:^ nu:n want:LOCAL:binding offset:n :}
   f name nu LOCAL:SLOT-STATE-OF {: b:LOCAL:binding at:n found:bool :}
   found TTRUE b want LOCAL:BINDING= TTRUE at offset T= ;

\ The file at name below the root carries the binding at offset at.
: STATE-AT ( fd ^u8 n LOCAL:binding n -- )
   {: root:fd name:^ nu:n want:LOCAL:binding offset:n :}
   root name nu OPEN-AT {: f:fd :}
   [: f name nu want offset STATE-IS ;] [: f FS:CLOSE-DIR ;] finally ;

variable FILES

: POOL-LEASE ( n -- )
   {: op:n :}
   s" target-" op NUMBERED DOWNLOAD 1 op 1+ [: LEASED? ;] LEASE
   {: slot:n b:LOCAL:binding found:bool :}
   found if b LEASED-COUNT @ LEASED ! 1 LEASED-COUNT +! then ;

\ A one-slot lease takes a slot per call, so the leases already held
\ are protected, as one Rust call's leases are from each other.
: POOL ( fd -- )
   {: root:fd :}
   0 LEASED-COUNT !
   5 0 ?do i POOL-LEASE loop
   LEASED-COUNT @ 4 T=
   0 FILES ! ROOT$ [: 2drop 1 FILES +! ;] FS:WALK-FILES FILES @ 4 T=
   4 0 ?do i SLOT-AT FS:FILE? TTRUE loop ;

: DOWNLOAD-SLOT-POOL-HAS-FOUR-FIXED-PATHS-WITHOUT-OVERFLOW ( -- )
   s" download_slot_pool_has_four_fixed_paths_without_overflow" T-LABEL
   [: POOL ;] IN-CASE-DIR ;

: PROTECTED ( fd -- )
   {: root:fd :}
   s" held.bin" DOWNLOAD 1 20 [: UNPROTECTED ;] LEASE
   {: hs:n hb:LOCAL:binding held:bool :}
   held TTRUE hb HELD-BINDING !
   hs SLOT-AT s" partial download bytes" FS:WRITE-ALL
   s" other.bin" DOWNLOAD 1 21 [: HELD? ;] LEASE
   {: os:n ob:LOCAL:binding other:bool :}
   other TTRUE os hs <> TTRUE
   hs SLOT-AT s" partial download bytes" HOLDS
   root hs LOCAL:DOWNLOAD-SLOT-NAME hb 0 STATE-AT ;

: PROTECTED-DOWNLOAD-SLOT-KEEPS-ITS-BINDING-AND-BYTES ( -- )
   s" protected_download_slot_keeps_its_binding_and_bytes" T-LABEL
   [: PROTECTED ;] IN-CASE-DIR ;

: STALE ( n -- ) SLOT-AT s" stale bytes" FS:WRITE-ALL ;

\ The slot is empty and carries the binding at offset 0.
: EMPTY-SLOT ( fd n LOCAL:binding -- )
   {: root:fd slot:n b:LOCAL:binding :}
   slot SLOT-AT FS:FILE-SIZE 0 T=
   root slot LOCAL:DOWNLOAD-SLOT-NAME b 0 STATE-AT ;

\ A one-slot lease has no empty form to free a stale slot with, so a
\ second stale slot shows the freeing: the rebinding lease claims the
\ first and empties the second, its binding kept.
: STALE-SLOTS ( fd -- )
   {: root:fd :}
   TARGET DOWNLOAD 1 10 [: UNPROTECTED ;] LEASE
   {: old:n ob:LOCAL:binding f0:bool :}
   f0 TTRUE ob HELD-BINDING ! old STALE
   s" other.bin" DOWNLOAD 1 30 [: HELD? ;] LEASE
   {: other:n xb:LOCAL:binding f1:bool :}
   f1 TTRUE other STALE
   TARGET DOWNLOAD 2 10 SLOT-IDENTITY LOCAL:SLOT-BINDING
   ob LOCAL:BINDING= TFALSE
   TARGET DOWNLOAD 1 11 SLOT-IDENTITY LOCAL:SLOT-BINDING
   ob LOCAL:BINDING= TFALSE
   TARGET DOWNLOAD 2 10 [: UNPROTECTED ;] LEASE
   {: new:n nb:LOCAL:binding f2:bool :}
   f2 TTRUE
   root new nb EMPTY-SLOT
   root other xb EMPTY-SLOT ;

: STALE-SLOT-IS-REBOUND-ACROSS-ROOT-AND-OPERATION-IDENTITY ( -- )
   s" stale_slot_is_rebound_across_root_and_operation_identity" T-LABEL
   [: STALE-SLOTS ;] IN-CASE-DIR ;

FS:PATHZ-CAP BUFFER: JOINED2
32 BUFFER: SLOT-NAME-BUF
variable SLOT-NAME-U
FS:PATHZ-CAP BUFFER: SLOT-PATH-BUF
variable SLOT-PATH-U

\ AT into a buffer of its own.
: AT2 ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   ROOT$ p u JOINED2 FS:JOIN-PATH JOINED2 swap ;

: SLOT$ ( -- ^u8 n ) SLOT-NAME-BUF SLOT-NAME-U @ ;
: SLOT-PATH$ ( -- ^u8 n ) SLOT-PATH-BUF SLOT-PATH-U @ ;

\ Keeps the slot's name and path where only the case reads them.
: KEEP-SLOT ( n -- )
   {: slot:n :}
   slot LOCAL:DOWNLOAD-SLOT-NAME {: p:^ u:n :}
   p SLOT-NAME-BUF u BYTE-COPY u SLOT-NAME-U !
   SLOT$ AT {: q:^ qu:n :}
   q SLOT-PATH-BUF qu BYTE-COPY qu SLOT-PATH-U ! ;

\ Rust's before_reset here: the slot moves to held-slot and a new file
\ takes its name.
: SWAP-SLOT ( -- )
   SLOT$ AT2 s" held-slot" AT FS:RENAME-FILE
   SLOT$ AT s" replacement" FS:WRITE-ALL ;

: EXPECTED ( -- DROPBOX:hash ) s" expected bytes" HASH-OF ;

\ The reset of the slot open at f, with the swap before its truncate.
: SWAP-RESET ( fd fd LOCAL:binding -- bool )
   {: f:fd root:fd b:LOCAL:binding :}
   f root SLOT$ SLOT-PATH$ b [: SWAP-SLOT ;]
   LOCAL:RESET-DOWNLOAD-SLOT-FILE-WITH LOCAL:TAKEN? ;

\ prepare_download_slot_at answers a fresh lease's slot opened, which
\ this case opens itself: it leaves prepare_download_slot_at out.
: SWAPPED ( fd -- )
   {: root:fd :}
   TARGET EXPECTED 1 1 [: UNPROTECTED ;] LEASE
   {: slot:n b:LOCAL:binding found:bool :}
   found TTRUE slot KEEP-SLOT
   root SLOT$ SLOT-PATH$ LOCAL:OPENED-SLOT {: f:fd opened:bool :}
   opened TTRUE
   [: f root b SWAP-RESET TFALSE ;] [: f FS:CLOSE-DIR ;] finally
   SLOT$ AT s" replacement" HOLDS
   s" held-slot" AT FS:FILE-SIZE 0 T=
   root s" held-slot" b 0 STATE-AT
   root s" held-slot" OPEN-AT {: moved:fd :}
   [: moved TARGET EXPECTED AR @ LOCAL:STAGE-MARKER s" held-slot"
      LOCAL:MARKER$ s" missing" T$= ;]
   [: moved FS:CLOSE-DIR ;] finally ;

: PARTIAL-RESET-NEVER-MUTATES-A-SWAPPED-REPLACEMENT ( -- )
   s" partial_reset_never_mutates_a_swapped_replacement" T-LABEL
   [: SWAPPED ;] IN-CASE-DIR ;

\ ---- resumed downloads

FS:PATHZ-CAP BUFFER: SYNC-BUF
variable SYNC-U

: SYNC$ ( -- ^u8 n ) SYNC-BUF SYNC-U @ ;

: WITH-SYNC-ROOT ( fd [ fd -- ] -- )
   {: case:fd q :}
   s" sync" AT FS:MAKE-DIR
   s" sync" AT {: p:^ u:n :}
   p SYNC-BUF u BYTE-COPY u SYNC-U !
   SYNC$ s" open test sync root" LOCAL:OPEN-ROOT {: root:fd :}
   [: root q execute ;] [: root FS:CLOSE-DIR ;] finally ;

\ Runs q on a sync root in the case directory, which holds the slots as
\ Rust's staging TempDir does.
: IN-SYNC-ROOT ( [ fd -- ] -- )
   {: q :}
   [: q WITH-SYNC-ROOT ;] IN-CASE-DIR ;

\ Rust's test_download_lease: the slot leased for target t's download
\ of c, root generation 1, operation 1.
: TEST-LEASE ( ^u8 n DROPBOX:hash -- LOCAL:download-slot-lease )
   {: t:^ tu:n c:DROPBOX:hash :}
   t tu c 1 1 SLOT-IDENTITY {: id:LOCAL:download-slot-identity :}
   ROOT$ id [: UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT LOCAL:LEASED ;

: DOWNLOAD-PREPARE
   ( fd ^u8 n DROPBOX:hash LOCAL:download-slot-lease
     -- LOCAL:download-preparation )
   {: root:fd t:^ tu:n c:DROPBOX:hash lease:LOCAL:download-slot-lease :}
   root SYNC$ t tu c lease AR @ LOCAL:PREPARE-DOWNLOAD-SLOT-AT ;

: DROP-OUTCOME ( LOCAL:stage-outcome<n> -- ) drop ;

\ The preparation's variant, a complete one's outcome and its path; a
\ ready partial is freed.
: DOWNLOAD-PREPARATION$ ( LOCAL:download-preparation -- ^u8 n ^u8 n )
   MATCH LOCAL:download-preparation
      ready OF LOCAL:CLOSE-PARTIAL s" ready" s" " ENDOF
      complete OF OUTCOME$ ENDOF
      ephemeral OF s" ephemeral" s" " ENDOF
   ;MATCH ;

: PREPARED-AS ( LOCAL:download-preparation ^u8 n -- )
   {: p:LOCAL:download-preparation want:^ wu:n :}
   p DOWNLOAD-PREPARATION$ s" " T$= want wu T$= ;

104 constant ECONNRESET
variable REMAINING

\ Rust's FailingBytes: "x" bytes until none remain, then a reset
\ connection.
: FAILING ( ^u8 n -- n )
   {: dst:^ cap:n :}
   REMAINING @ 0= if ECONNRESET FS:CAUSE! E-FS-IO throw then
   REMAINING @ cap min {: k:n :}
   k 0 ?do $78 dst i + c! loop
   k negate REMAINING +!
   k ;

: TOTAL ( -- n )
   LOCAL:DOWNLOAD-CHECKPOINT-BYTES DROPBOX:BLOCK 2 * + ;

: BOUNDARY ( -- ^u8 n ) s" boundary.bin" ;

: SIZE-OF ( fd -- n ) FS:FD-STAT FS:STAT-SIZE@ ;

\ A download cut after cut bytes leaves written bytes and resumes at
\ durable.
: INTERRUPTED ( fd n n n -- )
   {: root:fd cut:n written:n durable:n :}
   s" download never reaches verification" HASH-OF {: c:DROPBOX:hash :}
   BOUNDARY c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root BOUNDARY c lease DOWNLOAD-PREPARE LOCAL:READY-PARTIAL {: x :}
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   cut REMAINING !
   [: x TOTAL [: FAILING ;] AR @ LOCAL:APPEND-PARTIAL DROP-OUTCOME ;]
   LOCAL:E-STAGE-READ TTHROWSQ
   p u FS:FILE-SIZE written T=
   root BOUNDARY c lease DOWNLOAD-PREPARE LOCAL:READY-PARTIAL {: y :}
   y LOCAL:PARTIAL-OFFSET@ durable T=
   y LOCAL:PARTIAL-FILE SIZE-OF durable T=
   y LOCAL:CLOSE-PARTIAL ;

: INTERRUPTED-DOWNLOADS-RESUME-FROM-DURABLE-BOUNDARIES ( -- )
   s" interrupted_downloads_resume_from_durable_boundaries" T-LABEL
   LOCAL:DOWNLOAD-CHECKPOINT-BYTES {: cp:n :}
   DROPBOX:BLOCK {: b:n :}
   [: cp 1- cp b - 0 INTERRUPTED ;] IN-SYNC-ROOT
   [: cp cp cp INTERRUPTED ;] IN-SYNC-ROOT
   [: cp 1+ cp cp INTERRUPTED ;] IN-SYNC-ROOT
   [: cp b + 1+ cp b + cp INTERRUPTED ;] IN-SYNC-ROOT ;

\ The prepared partial of target.txt's download of c, its bytes written.
: WRITTEN
   ( fd DROPBOX:hash LOCAL:download-slot-lease ^u8 n
     -- ^LOCAL:download-partial )
   {: root:fd c:DROPBOX:hash lease:LOCAL:download-slot-lease b:^ bu:n :}
   root TARGET c lease DOWNLOAD-PREPARE LOCAL:READY-PARTIAL {: x :}
   x LOCAL:PARTIAL-FILE b bu FD:WRITE-FULL
   x ;

: STAGE-HOLDS ( ^LOCAL:download-partial ^u8 n -- )
   {: x b:^ bu:n :}
   x LOCAL:PARTIAL-STAGE-PATH b bu HOLDS ;

: NO-CONTENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;

: ACTUAL$ ( option<DROPBOX:hash> -- ^u8 n )
   MATCH option
      none OF s" none" ENDOF
      some OF DROPBOX:HASH>STR str> ENDOF
   ;MATCH ;

\ The outcome's variant, and its path or actual content, else empty.
: INSTALL$ ( LOCAL:install-outcome -- ^u8 n ^u8 n )
   MATCH LOCAL:install-outcome
      installed OF s" installed" s" " ENDOF
      already-installed OF s" already-installed" s" " ENDOF
      download-required OF s" download-required" s" " ENDOF
      stage-destination-occupied OF {: p:str :}
         s" stage-destination-occupied" p str>
      ENDOF
      precondition-changed OF {: a:option<DROPBOX:hash> :}
         s" precondition-changed" a ACTUAL$
      ENDOF
   ;MATCH ;

\ Rust's install_download of c at the target below the sync root, then
\ the target read back: it holds b.
: INSTALLS ( fd DROPBOX:hash ^u8 n -- )
   {: root:fd c:DROPBOX:hash b:^ bu:n :}
   root SYNC$ TARGET c NO-CONTENT AR @ LOCAL:INSTALL-DOWNLOAD-AT
   INSTALL$ s" " T$= s" installed" T$=
   SYNC$ TARGET JOINED FS:JOIN-PATH JOINED swap b bu HOLDS ;

: RECOVERED ( fd bool -- )
   {: root:fd renamed:bool :}
   s" completed bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   renamed if x LOCAL:RENAME-TO-STAGE TTRUE then
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease DOWNLOAD-PREPARE
   renamed if s" already-staged" else s" staged" then PREPARED-AS
   root TARGET c lease DOWNLOAD-PREPARE s" already-staged" PREPARED-AS
   x b bu STAGE-HOLDS
   root c b bu INSTALLS ;

: COMPLETED-PARTIAL-RECOVERS-BEFORE-AND-AFTER-RENAME ( -- )
   s" completed_partial_recovers_before_and_after_rename" T-LABEL
   [: false RECOVERED ;] IN-SYNC-ROOT
   [: true RECOVERED ;] IN-SYNC-ROOT ;

: RESTARTED-EMPTY ( LOCAL:download-preparation -- )
   LOCAL:READY-PARTIAL {: y :}
   y LOCAL:PARTIAL-OFFSET@ 0 T=
   y LOCAL:PARTIAL-FILE SIZE-OF 0 T=
   y LOCAL:CLOSE-PARTIAL ;

: CORRUPT ( fd bool -- )
   {: root:fd owned:bool :}
   s" complete bytes" HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease s" incomplete" WRITTEN {: x :}
   owned 0= if
      x LOCAL:PARTIAL-FILE LOCAL:DOWNLOAD-PARTIAL-XATTR s" foreign owner"
      XATTR:SET
   then
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease DOWNLOAD-PREPARE
   {: prep:LOCAL:download-preparation :}
   owned if prep RESTARTED-EMPTY exit then
   prep s" ephemeral" PREPARED-AS
   p u s" incomplete" HOLDS ;

: CORRUPT-COMPLETED-PARTIAL-RESTARTS-ONLY-WHEN-OWNED ( -- )
   s" corrupt_completed_partial_restarts_only_when_owned" T-LABEL
   [: true CORRUPT ;] IN-SYNC-ROOT
   [: false CORRUPT ;] IN-SYNC-ROOT ;

\ Rust's before_move here: the slot moves to held-slot and a new file
\ takes its name.
: SWAP-PARTIAL ( ^u8 n -- )
   {: p:^ u:n :}
   p u s" held-slot" AT FS:RENAME-FILE
   p u s" replacement" FS:WRITE-ALL ;

: SWAPPED-PROMOTION ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   [: x [: p u SWAP-PARTIAL ;] AR @ LOCAL:PROMOTE-WITH OUTCOME$
      p u T$= s" destination-occupied" T$= ;]
   [: x LOCAL:CLOSE-PARTIAL ;] finally
   p u s" replacement" HOLDS
   s" held-slot" AT b bu HOLDS
   x LOCAL:PARTIAL-STAGE-PATH FS:TRY-LSTAT TFALSE ;

: COMPLETED-PARTIAL-PROMOTION-PRESERVES-A-SWAPPED-REPLACEMENT ( -- )
   s" completed_partial_promotion_preserves_a_swapped_replacement" T-LABEL
   [: SWAPPED-PROMOTION ;] IN-SYNC-ROOT ;

: CROSS-FILESYSTEM ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   [: x AR @ LOCAL:COPY-PARTIAL OUTCOME$ s" " T$= s" staged" T$= ;]
   [: x LOCAL:CLOSE-PARTIAL ;] finally
   x LOCAL:PARTIAL-PATH FS:FILE-SIZE 0 T=
   x b bu STAGE-HOLDS
   root c b bu INSTALLS ;

: CROSS-FILESYSTEM-SLOT-COMPLETION-COPIES-REHASHES-AND-FREES-THE-SLOT
   ( -- )
   s" cross_filesystem_slot_completion_copies_rehashes_and_frees_the_slot"
   T-LABEL
   [: CROSS-FILESYSTEM ;] IN-SYNC-ROOT ;

\ Rust's staged_download(stage_download(...)): b staged from a reader
\ below the sync root fd.
: STAGE-BYTES ( fd ^u8 n DROPBOX:hash -- )
   {: root:fd b:^ bu:n c:DROPBOX:hash :}
   b bu START 0 SCHEDULE
   root SYNC$ TARGET c [: FRAGMENT ;] AR @ LOCAL:STAGE-DOWNLOAD-AT
   OUTCOME$
   s" " T$= s" staged" T$= ;

: ZERO-REPLAY ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b bu WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:ZERO-CHECKPOINT
   root b bu c STAGE-BYTES
   x LOCAL:PARTIAL-PATH {: p:^ u:n :}
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease DOWNLOAD-PREPARE s" already-staged" PREPARED-AS
   p u FS:FILE-SIZE 0 T=
   root TARGET c lease DOWNLOAD-PREPARE s" already-staged" PREPARED-AS
   root c b bu INSTALLS ;

: INTERRUPTED-PARTIAL-RESET-REPLAYS-TO-A-REUSABLE-ZERO-CHECKPOINT ( -- )
   s" interrupted_partial_reset_replays_to_a_reusable_zero_checkpoint"
   T-LABEL
   [: ZERO-REPLAY ;] IN-SYNC-ROOT ;

\ ---- installs

64 BUFFER: READ-BUF

\ The bytes of the file at the name below the case's directory.
: READ$ ( ^u8 n -- ^u8 n )
   AT READ-BUF 64 FS:READ-ALL READ-BUF swap ;

: HELD ( ^u8 n -- option<DROPBOX:hash> ) HASH-OF OPTION:SOME ;

: REPLACEMENT-PREPARATION$
   ( LOCAL:replacement-preparation -- ^u8 n ^u8 n )
   MATCH LOCAL:replacement-preparation
      prepared OF s" prepared" s" " ENDOF
      already-prepared OF s" already-prepared" s" " ENDOF
      precondition-changed OF {: a:option<DROPBOX:hash> :}
         s" precondition-changed" a ACTUAL$
      ENDOF
   ;MATCH ;

: STAGE-NAME$ ( ^u8 n -- ^u8 n ) WANT AR @ LOCAL:STAGE-NAME ;

\ STAGE-DOWNLOAD-AT of "remote" as t's owned download below the case's
\ directory, whose fd is root.
: STAGE-REMOTE ( fd ^u8 n -- )
   {: root:fd t:^ tu:n :}
   s" remote" START 0 SCHEDULE
   root ROOT$ t tu WANT [: FRAGMENT ;] AR @ LOCAL:STAGE-DOWNLOAD-AT
   OUTCOME$ s" " T$= s" staged" T$= ;

\ INSTALL-DOWNLOAD-AT of "remote" at t below the case's directory, whose
\ fd is root.
: INSTALL ( fd ^u8 n option<DROPBOX:hash> -- ^u8 n ^u8 n )
   {: root:fd t:^ tu:n expected:option<DROPBOX:hash> :}
   t tu T-LABEL
   root ROOT$ t tu WANT expected AR @ LOCAL:INSTALL-DOWNLOAD-AT
   INSTALL$ ;

: REPLACEMENT-PREPARE ( fd ^u8 n ^u8 n -- ^u8 n ^u8 n )
   {: root:fd t:^ tu:n c:^ cu:n :}
   t tu T-LABEL
   root ROOT$ t tu c cu HASH-OF AR @ LOCAL:PREPARE-BELOW
   REPLACEMENT-PREPARATION$ ;

: ABSENT-INSTALL ( fd -- )
   {: root:fd :}
   root TARGET STAGE-REMOTE
   TARGET s" local" PUT-FILE
   root TARGET NO-CONTENT INSTALL
   s" local" IDENTITY T$= s" precondition-changed" T$=
   TARGET READ$ s" local" T$= ;

: ABSENT-INSTALL-NEVER-OVERWRITES-AN-EXISTING-FILE ( -- )
   s" absent_install_never_overwrites_an_existing_file" T-LABEL
   [: ABSENT-INSTALL ;] IN-CASE-DIR ;

: OPEN-WRITE-AT ( fd ^u8 n -- fd )
   FS:TRY-OPEN-WRITE-AT MATCH option
      none OF E-FS-OPEN throw ENDOF
      some OF ENDOF
   ;MATCH ;

: MUTATED-STAGE ( fd -- )
   {: root:fd :}
   root TARGET STAGE-REMOTE
   TARGET STAGE-NAME$ {: sn:^ snu:n :}
   sn snu AT FS:MODE-PRIVATE-FILE FS:CHMOD-MODE
   root sn snu OPEN-WRITE-AT {: w:fd :}
   [: root ROOT$ TARGET WANT AR @ w LOCAL:INSTALL-RENAME-MUTATED ;]
   [: w FS:CLOSE-DIR ;] finally
   root TARGET LOCAL:ENTRY-EXISTS-AT TFALSE
   sn snu READ$ s" mutant" T$= ;

\ The stage is verified, then changed through a writer opened before it
\ was sealed; the rename refuses it and leaves both names as they are.
: INSTALL-REJECTS-STAGE-CHANGED-THROUGH-A-PREEXISTING-WRITER ( -- )
   s" install_rejects_stage_changed_through_a_preexisting_writer" T-LABEL
   [: MUTATED-STAGE ;] IN-CASE-DIR ;

64 BUFFER: XATTR-BUF

: PARTIAL? ( fd -- bool )
   LOCAL:DOWNLOAD-PARTIAL-XATTR XATTR-BUF 64 SPAN:MAKE XATTR:GET
   MATCH XATTR:got
      absent OF false ENDOF
      value OF drop true ENDOF
      oversize OF true ENDOF
   ;MATCH ;

: INSTALLED-BYTES ( -- ^u8 n ) s" installed bytes" ;
: INSTALLED-MARKER ( -- ^u8 n )
   TARGET INSTALLED-BYTES HASH-OF AR @ LOCAL:STAGE-MARKER ;

\ The download slot words are not LOCAL's yet: the partial marker holds
\ bytes no slot state decodes, which cleanup removes all the same.
: MARK-INSTALLED ( fd -- )
   {: f:fd :}
   f LOCAL:DOWNLOAD-PARTIAL-XATTR s" slot state" true TARGET
   s" test mark" LOCAL:SET-XATTR
   f LOCAL:DOWNLOAD-STAGE-XATTR INSTALLED-MARKER true TARGET
   s" test mark" LOCAL:SET-XATTR
   f $100 FD:MODE! f FD:SYNC ;

: REMOVE-PARTIAL ( fd -- )
   {: f:fd :}
   f FS:MODE-PRIVATE-FILE FD:MODE!
   f LOCAL:DOWNLOAD-PARTIAL-XATTR XATTR:ERASE f FD:SYNC ;

: SYNC-INSTALLED ( fd -- )
   TARGET TARGET INSTALLED-BYTES HASH-OF AR @
   LOCAL:SYNC-INSTALLED-DOWNLOAD ;

: CLEANED-UP ( fd fd -- )
   {: root:fd f:fd :}
   root SYNC-INSTALLED
   f INSTALLED-MARKER TARGET LOCAL:MARKER$ s" missing" T$=
   f PARTIAL? TFALSE
   f FS:FD-STAT FS:STAT-MODE@ FS:MODE-PRIVATE-FILE and
   FS:MODE-PRIVATE-FILE T=
   root SYNC-INSTALLED ;

: PARTIAL-CLEANUP ( fd bool -- )
   {: root:fd removed:bool :}
   TARGET INSTALLED-BYTES PUT-FILE
   root TARGET OPEN-WRITE-AT {: f:fd :}
   [: f MARK-INSTALLED
      removed if f REMOVE-PARTIAL else f PARTIAL? TTRUE then
      f INSTALLED-MARKER TARGET LOCAL:MARKER$ s" expected" T$=
      root f CLEANED-UP ;]
   [: f FS:CLOSE-DIR ;] finally ;

: INSTALLED-DOWNLOAD-CLEANUP-REPLAYS-AROUND-PARTIAL-MARKER-REMOVAL ( -- )
   s" installed_download_cleanup_replays_around_partial_marker_removal"
   T-LABEL
   [: false PARTIAL-CLEANUP ;] IN-CASE-DIR
   [: true PARTIAL-CLEANUP ;] IN-CASE-DIR ;

: UNMARKED-RENAME ( fd -- )
   {: root:fd :}
   TARGET s" remote" PUT-FILE
   root TARGET OPEN-AT {: f:fd :}
   [: f root TARGET WANT AR @ LOCAL:RENAMED-WITHOUT-MARKER
      root TARGET TARGET WANT AR @ LOCAL:SYNC-INSTALLED-DOWNLOAD ;]
   [: f FS:CLOSE-DIR ;] finally ;

: RENAMED-DOWNLOAD-REQUIRES-ITS-OWNERSHIP-MARKER ( -- )
   s" renamed_download_requires_its_ownership_marker" T-LABEL
   [: UNMARKED-RENAME ;] IN-CASE-DIR ;

\ An absent target: none staged, then installed and installed again.
: ABSENT-OUTCOMES ( fd -- )
   {: root:fd :}
   root TARGET NO-CONTENT INSTALL s" " T$= s" download-required" T$=
   root s" missing/target.txt" NO-CONTENT INSTALL
   s" " T$= s" download-required" T$=
   root TARGET STAGE-REMOTE
   root TARGET NO-CONTENT INSTALL s" " T$= s" installed" T$=
   TARGET READ$ s" remote" T$=
   root TARGET STAGE-NAME$ LOCAL:ENTRY-EXISTS-AT TFALSE
   TARGET AT FS:TRY-LSTAT TTRUE
   FS:STAT-MODE@ $1FF and FS:MODE-PRIVATE-FILE T=
   root TARGET NO-CONTENT INSTALL s" " T$= s" already-installed" T$= ;

: OCCUPIED-STAGE ( fd -- )
   {: root:fd :}
   s" other.txt" STAGE-NAME$ {: sn:^ snu:n :}
   sn snu s" mutant" PUT-FILE
   root s" other.txt" NO-CONTENT INSTALL
   sn snu AT T$= s" stage-destination-occupied" T$= ;

\ A replacement installs over the content expected and keeps any other.
: REPLACEMENT-OUTCOMES ( fd -- )
   {: root:fd :}
   s" old.txt" s" local" PUT-FILE
   root s" old.txt" STAGE-REMOTE
   root s" old.txt" s" local" HELD INSTALL s" " T$= s" installed" T$=
   s" old.txt" READ$ s" remote" T$=
   root s" old.txt" s" local" HASH-OF AR @ LOCAL:GUARD-NAME
   LOCAL:ENTRY-EXISTS-AT TFALSE
   s" edited.txt" s" edit" PUT-FILE
   root s" edited.txt" STAGE-REMOTE
   root s" edited.txt" s" local" HELD INSTALL
   s" edit" IDENTITY T$= s" precondition-changed" T$=
   s" edited.txt" READ$ s" edit" T$= ;

: INSTALL-CASES ( fd -- )
   {: root:fd :}
   root ABSENT-OUTCOMES root OCCUPIED-STAGE root REPLACEMENT-OUTCOMES ;

: EACH-INSTALL-OUTCOME-IS-REACHED ( -- )
   s" each install outcome is reached" T-LABEL
   [: INSTALL-CASES ;] IN-CASE-DIR ;

\ A directory at the stage's name blocks the install and stays.
: DIRECTORY-STAGE ( fd -- )
   {: root:fd :}
   s" dir.txt" STAGE-NAME$ {: sn:^ snu:n :}
   sn snu AT FS:MAKE-DIR
   root s" dir.txt" NO-CONTENT INSTALL
   sn snu AT T$= s" stage-destination-occupied" T$=
   sn snu AT KIND FS:S-IFDIR T= ;

\ A file Omabox cannot read at the stage's name blocks the install and
\ keeps its bytes.
: UNREADABLE-STAGE ( fd -- )
   {: root:fd :}
   LOCAL:ROOT-USER? if exit then
   s" denied.txt" STAGE-NAME$ {: sn:^ snu:n :}
   sn snu s" mutant" PUT-FILE
   sn snu AT 0 FS:CHMOD-MODE
   [: root s" denied.txt" NO-CONTENT INSTALL
      sn snu AT T$= s" stage-destination-occupied" T$= ;]
   [: sn snu AT MODE-0700 FS:CHMOD-MODE ;] finally
   sn snu READ$ s" mutant" T$= ;

\ Rust's inspect_download_stage throws for both.
: OBJECT-AT-STAGE-NAME-BLOCKS-ONLY-ITS-INSTALL ( -- )
   s" an object at a stage's name blocks only its install" T-LABEL
   [: dup DIRECTORY-STAGE UNREADABLE-STAGE ;] IN-CASE-DIR ;

: PREPARE-CASES ( fd -- )
   {: root:fd :}
   s" prep.txt" s" old" PUT-FILE
   root s" prep.txt" s" old" REPLACEMENT-PREPARE
   s" " T$= s" prepared" T$=
   root s" prep.txt" LOCAL:ENTRY-EXISTS-AT TFALSE
   s" prep.txt" s" old" HASH-OF AR @ LOCAL:GUARD-NAME READ$ s" old" T$=
   root s" prep.txt" s" old" REPLACEMENT-PREPARE
   s" " T$= s" already-prepared" T$=
   s" other.txt" s" new" PUT-FILE
   root s" other.txt" s" old" REPLACEMENT-PREPARE
   s" new" IDENTITY T$= s" precondition-changed" T$=
   s" other.txt" READ$ s" new" T$=
   root s" absent.txt" s" old" REPLACEMENT-PREPARE
   s" none" T$= s" precondition-changed" T$= ;

: EACH-REPLACEMENT-PREPARATION-IS-REACHED ( -- )
   s" each replacement preparation is reached" T-LABEL
   [: PREPARE-CASES ;] IN-CASE-DIR ;

variable ENTRIES

: COUNT-ENTRY ( ^u8 n -- ) 2drop 1 ENTRIES +! ;

\ The count of the directory's entries but . and ..
: ENTRY-COUNT ( ^u8 n -- n )
   0 ENTRIES ! [: COUNT-ENTRY ;] FS-LIST:EACH ENTRIES @ ;

: FD-COUNT ( -- n ) s" /proc/self/fd" ENTRY-COUNT ;

\ A disposable download whose stage is complete keeps no descriptor.
: COMPLETE-DISPOSABLE ( fd -- )
   {: root:fd :}
   root TARGET STAGE-REMOTE
   FD-COUNT {: before:n :}
   root ROOT$ TARGET WANT ROOT$ AR @
   LOCAL:PREPARE-DISPOSABLE-DOWNLOAD-AT
   DOWNLOAD-PREPARATION$ s" " T$= s" already-staged" T$=
   FD-COUNT before T= ;

: COMPLETE-DISPOSABLE-DOWNLOAD-CLOSES-ITS-PARENT ( -- )
   s" complete disposable download closes its parent" T-LABEL
   [: COMPLETE-DISPOSABLE ;] IN-CASE-DIR ;

: FALLBACK ( -- ^u8 n ) s" fallback.bin" ;

: EXISTING$ ( option<LOCAL:stage-outcome<n>> -- ^u8 n ^u8 n )
   MATCH option
      none OF s" none" s" " ENDOF
      some OF OUTCOME$ ENDOF
   ;MATCH ;

\ The disposable partial of fallback.bin's download of c: an unnamed
\ file in a staging directory beside the sync root.
: DISPOSABLE-PARTIAL ( fd DROPBOX:hash -- ^LOCAL:download-partial )
   {: root:fd c:DROPBOX:hash :}
   s" staging" AT FS:MAKE-DIR
   root SYNC$ FALLBACK c STAGING AR @
   LOCAL:PREPARE-DISPOSABLE-DOWNLOAD-AT LOCAL:READY-PARTIAL ;

\ Rust's test without the scan lock: the appended partial is staged,
\ the stage is then already staged, and the staging directory is empty.
: DISPOSABLE-BODY ( fd -- )
   {: root:fd :}
   s" disposable download" {: b:^ bu:n :}
   b bu HASH-OF {: c:DROPBOX:hash :}
   root c DISPOSABLE-PARTIAL {: x :}
   x LOCAL:DISPOSABLE? TTRUE
   b bu START 0 SCHEDULE
   x bu [: FRAGMENT ;] AR @ LOCAL:APPEND-PARTIAL OUTCOME$
   s" " T$= s" staged" T$=
   root SYNC$ FALLBACK c AR @ LOCAL:EXISTING-DOWNLOAD-STAGE-AT
   EXISTING$ s" " T$= s" already-staged" T$=
   STAGING ENTRY-COUNT 0 T= ;

: DISPOSABLE-DOWNLOAD-BODY-DOES-NOT-HOLD-THE-SCAN-LOCK ( -- )
   s" disposable_download_body_does_not_hold_the_scan_lock" T-LABEL
   [: DISPOSABLE-BODY ;] IN-SYNC-ROOT ;

\ ---- parents

: INODE ( fd -- n ) FS:FD-STAT FS:STAT-INO@ ;

: PATH-INODE ( ^u8 n -- n ) AT FS:TRY-LSTAT TTRUE FS:STAT-INO@ ;

: SAME-ADDRESS ( ^u8 ^u8 -- )
   {: a:^ b:^ :}
   a NULL-PTR - b NULL-PTR - T= ;

\ p's parent opens, its name and path spans of p; answers the descriptor.
: PARENT ( fd ^u8 n bool ^u8 n ^u8 n -- fd )
   {: root:fd p:^ u:n create:bool name:^ nu:n path:^ pu:n :}
   p u T-LABEL
   root p u create LOCAL:PARENT-OF TTRUE
   {: f:fd got:^ gu:n gp:^ gpu:n :}
   got gu name nu T$= gp gpu path pu T$=
   got p u + nu - SAME-ADDRESS gp p SAME-ADDRESS
   f ;

\ Closes the descriptor PARENT-OF answers, if any.
: TRY-PARENT ( fd ^u8 n bool -- )
   LOCAL:PARENT-OF {: f:fd n:^ nu:n pp:^ pu:n found:bool :}
   found if f FS:CLOSE-DIR then ;

: ROOT-PARENT ( fd -- )
   {: root:fd :}
   s" present" s" bytes" PUT-FILE
   root s" present" false s" present" s" " PARENT {: f:fd :}
   f FD>N root FD>N <> TTRUE
   f INODE root INODE T=
   f FS:CLOSE-DIR
   root s" present" LOCAL:ENTRY-EXISTS-AT TTRUE ;

: EXISTING-PARENT ( fd -- )
   {: root:fd :}
   s" a/b" AT FS:MAKE-DIRS
   root s" a/b/file" false s" file" s" a/b" PARENT {: f:fd :}
   f INODE s" a/b" PATH-INODE T=
   f FS:CLOSE-DIR ;

: MISSING-PARENT ( fd -- )
   {: root:fd :}
   s" a" AT FS:MAKE-DIR
   s" a/missing/file" T-LABEL
   root s" a/missing/file" false LOCAL:PARENT-OF TFALSE
   {: f:fd n:^ nu:n pp:^ pu:n :}
   root s" a/missing" LOCAL:ENTRY-EXISTS-AT TFALSE ;

: PRIVATE-DIR ( ^u8 n -- )
   {: p:^ u:n :}
   p u T-LABEL
   p u AT FS:TRY-LSTAT TTRUE
   FS:STAT-MODE@ FS:S-IFMT and FS:S-IFDIR T=
   FS:STAT-MODE@ $1FF and MODE-0700 T= ;

: CREATED-PARENTS ( fd -- )
   {: root:fd :}
   root s" x/y/z/file" true s" file" s" x/y/z" PARENT {: f:fd :}
   s" x" PRIVATE-DIR s" x/y" PRIVATE-DIR s" x/y/z" PRIVATE-DIR
   f INODE s" x/y/z" PATH-INODE T=
   f FS:CLOSE-DIR
   root s" x/y/z/file" LOCAL:ENTRY-EXISTS-AT TFALSE ;

: SYMLINK-PARENT ( fd -- )
   {: root:fd :}
   s" real" AT FS:MAKE-DIR
   s" real" s" link" AT FS:MAKE-SYMLINK
   s" link/sub/file" T-LABEL
   [: root s" link/sub/file" true TRY-PARENT ;] LOCAL:E-IO TTHROWSQ
   FS:ERRNO FS:ENOTDIR T=
   root s" real/sub" LOCAL:ENTRY-EXISTS-AT TFALSE ;

: UNSAFE-PARENT ( fd ^u8 n -- )
   {: root:fd p:^ u:n :}
   p u T-LABEL
   [: root p u false TRY-PARENT ;] LOCAL:E-UNSAFE-PATH TTHROWSQ ;

: UNSAFE-PARENTS ( fd -- )
   {: root:fd :}
   root s" " UNSAFE-PARENT
   root s" /absolute" UNSAFE-PARENT
   root s" ./file" UNSAFE-PARENT
   root s" a/../file" UNSAFE-PARENT ;

: ONE-COMPONENT-PARENT-IS-A-DUPLICATE-ROOT ( -- )
   s" one component's parent is a duplicate root" T-LABEL
   [: ROOT-PARENT ;] IN-CASE-DIR ;

: EXISTING-PARENT-OPENS ( -- )
   s" existing parent opens" T-LABEL
   [: EXISTING-PARENT ;] IN-CASE-DIR ;

: MISSING-PARENT-IS-NONE-WITHOUT-CREATE ( -- )
   s" missing parent is none without create" T-LABEL
   [: MISSING-PARENT ;] IN-CASE-DIR ;

: CREATE-MAKES-PRIVATE-PARENTS ( -- )
   s" create makes private parents" T-LABEL
   [: CREATED-PARENTS ;] IN-CASE-DIR ;

: SYMLINK-PARENT-IS-REFUSED ( -- )
   s" symlink parent is refused" T-LABEL
   [: SYMLINK-PARENT ;] IN-CASE-DIR ;

: UNSAFE-PARENT-PATH-FAILS ( -- )
   s" unsafe parent path fails" T-LABEL
   [: UNSAFE-PARENTS ;] IN-CASE-DIR ;

\ ---- deletes

: OLD ( -- DROPBOX:hash ) s" old" HASH-OF ;

\ The outcome's variant, and its actual hash, else empty.
: DELETED$ ( LOCAL:delete-outcome -- ^u8 n ^u8 n )
   MATCH LOCAL:delete-outcome
      deleted OF s" deleted" s" " ENDOF
      already-deleted OF s" already-deleted" s" " ENDOF
      precondition-changed OF {: c:option<DROPBOX:hash> :}
         s" precondition-changed" c ACTUAL$
      ENDOF
   ;MATCH ;

\ Deletes target.txt below the case directory, whose fd is root, while
\ it holds "old".
: DELETE ( fd -- ^u8 n ^u8 n )
   ROOT$ TARGET OLD AR @ LOCAL:DELETE-LOCAL-AT DELETED$ ;

: GUARD ( -- ^u8 n ) s" deleted" TARGET OLD AR @ LOCAL:INTERNAL-NAME ;

64 BUFFER: BACK

\ The bytes of the file at the name below the case directory.
: BYTES ( ^u8 n -- ^u8 n ) AT BACK 64 FS:READ-ALL BACK swap ;

: PRESENT? ( ^u8 n -- bool ) AT FS:TRY-LSTAT ;

: DELETE-REPLAY ( fd -- )
   {: root:fd :}
   TARGET s" old" PUT-FILE
   root TARGET root GUARD FS:TRY-RENAME-AT TTRUE
   TARGET s" raced edit" PUT-FILE
   root DELETE s" raced edit" IDENTITY T$= s" precondition-changed" T$=
   TARGET BYTES s" raced edit" T$=
   GUARD PRESENT? TFALSE ;

: DELETE-REPLAY-PRESERVES-A-RACED-EDIT-AND-REMOVES-ITS-GUARD ( -- )
   s" delete_replay_preserves_a_raced_edit_and_removes_its_guard" T-LABEL
   [: DELETE-REPLAY ;] IN-CASE-DIR ;

\ An interrupted delete's guard holding other bytes goes back.
: GUARD-RESTORED ( fd -- )
   {: root:fd :}
   s" guard restored" T-LABEL
   GUARD s" edited" PUT-FILE
   root DELETE s" edited" IDENTITY T$= s" precondition-changed" T$=
   TARGET BYTES s" edited" T$=
   GUARD PRESENT? TFALSE ;

: DELETE-CASES ( fd -- )
   {: root:fd :}
   s" deleted" T-LABEL
   TARGET s" old" PUT-FILE
   root DELETE s" " T$= s" deleted" T$=
   TARGET PRESENT? TFALSE GUARD PRESENT? TFALSE
   s" already deleted" T-LABEL
   root DELETE s" " T$= s" already-deleted" T$=
   s" precondition changed" T-LABEL
   TARGET s" new" PUT-FILE
   root DELETE s" new" IDENTITY T$= s" precondition-changed" T$=
   TARGET BYTES s" new" T$=
   TARGET AT FS:REMOVE-FILE
   root GUARD-RESTORED ;

\ precondition-changed with none needs the guard to vanish between its
\ hash and its restore, a race a scratch tree cannot stage; left out.
: EACH-DELETE-OUTCOME-IS-REACHED ( -- )
   s" each delete outcome is reached" T-LABEL
   [: DELETE-CASES ;] IN-CASE-DIR ;

\ ---- directories

: CREATED$ ( LOCAL:create-directory-outcome -- ^u8 n )
   MATCH LOCAL:create-directory-outcome
      created OF s" created" ENDOF
      already-present OF s" already-present" ENDOF
      fresh-observation OF s" fresh-observation" ENDOF
   ;MATCH ;

: REMOVED$ ( LOCAL:delete-directory-outcome -- ^u8 n )
   MATCH LOCAL:delete-directory-outcome
      deleted OF s" deleted" ENDOF
      already-absent OF s" already-absent" ENDOF
      fresh-observation OF s" fresh-observation" ENDOF
   ;MATCH ;

: MKDIR ( fd ^u8 n ^u8 n -- )
   {: root:fd p:^ u:n want:^ wu:n :}
   p u T-LABEL
   root p u LOCAL:CREATE-DIRECTORY-AT CREATED$ want wu T$= ;

: RMDIR ( fd ^u8 n ^u8 n -- )
   {: root:fd p:^ u:n want:^ wu:n :}
   p u T-LABEL
   root p u LOCAL:DELETE-DIRECTORY-AT REMOVED$ want wu T$= ;

: DIRECTORY-EFFECTS ( fd -- )
   {: root:fd :}
   root s" parent/child" s" created" MKDIR
   root s" parent/child" s" already-present" MKDIR
   root s" parent" s" fresh-observation" RMDIR
   root s" parent/child" s" deleted" RMDIR
   root s" parent" s" deleted" RMDIR
   s" occupied" s" preserved bytes" PUT-FILE
   root s" occupied" s" fresh-observation" MKDIR
   root s" occupied" s" fresh-observation" RMDIR
   s" occupied" BYTES s" preserved bytes" T$=
   root s" parent" s" already-absent" RMDIR ;

\ local.rs's test, then the absent directory's outcome.
: DIRECTORY-EFFECTS-ARE-NONOVERWRITING-AND-NONRECURSIVE ( -- )
   s" directory_effects_are_nonoverwriting_and_nonrecursive" T-LABEL
   [: DIRECTORY-EFFECTS ;] IN-CASE-DIR ;

\ ---- conflicts

\ The outcome's variant, and its path or actual hash.
: CONFLICT$ ( LOCAL:conflict-outcome -- ^u8 n ^u8 n )
   MATCH LOCAL:conflict-outcome
      created OF {: p:str :} s" created" p str> ENDOF
      already-present OF {: p:str :} s" already-present" p str> ENDOF
      content-changed OF {: c:DROPBOX:hash :}
         s" content-changed" c DROPBOX:HASH>STR str>
      ENDOF
   ;MATCH ;

: ORIGINAL ( -- ^u8 n ) s" dir/original.txt" ;

\ Materializes the bytes as ORIGINAL's remote conflict copy of "remote"
\ below the case directory, whose fd is root.
: MATERIALIZED ( fd ^u8 n -- ^u8 n ^u8 n )
   {: root:fd b:^ bu:n :}
   b bu START 0 SCHEDULE
   root ROOT$ ORIGINAL LOCAL-CONFLICT--SIDE:remote WANT [: FRAGMENT ;]
   AR @ LOCAL:MATERIALIZE-CONFLICT-AT CONFLICT$ ;

: COPY-PATH ( -- ^u8 n )
   ORIGINAL LOCAL-CONFLICT--SIDE:remote WANT AR @
   LOCAL:CONFLICT-RELATIVE-PATH ;

\ A conflict copy whose reader fails with a file failure throws E-IO.
: FAILED-CONFLICT-READ ( fd -- )
   {: root:fd :}
   0 REMAINING !
   [: root ROOT$ ORIGINAL LOCAL-CONFLICT--SIDE:remote WANT [: FAILING ;]
      AR @ LOCAL:MATERIALIZE-CONFLICT-AT CONFLICT$ 2drop 2drop ;]
   LOCAL:E-IO TTHROWSQ ;

: CONFLICT-CASES ( fd -- )
   {: root:fd :}
   s" created" T-LABEL
   root s" remote" MATERIALIZED COPY-PATH T$= s" created" T$=
   COPY-PATH BYTES s" remote" T$=
   COPY-PATH drop 4 s" dir/" T$=
   s" already present" T-LABEL
   root s" remote" MATERIALIZED COPY-PATH T$= s" already-present" T$=
   s" content changed" T-LABEL
   COPY-PATH AT FS:REMOVE-FILE
   root s" mutant" MATERIALIZED s" mutant" IDENTITY T$=
   s" content-changed" T$=
   COPY-PATH PRESENT? TFALSE
   s" failed read" T-LABEL
   root FAILED-CONFLICT-READ
   COPY-PATH PRESENT? TFALSE ;

: EACH-CONFLICT-OUTCOME-IS-REACHED ( -- )
   s" each conflict outcome is reached" T-LABEL
   [: CONFLICT-CASES ;] IN-CASE-DIR ;

\ Dropped: parallel_cold_scan_matches_single_worker_scan compares hash
\ workers and download_promotion_cannot_invalidate_complete_scan holds the
\ scan lock; one task has neither. With their words, on a later lane:
\ case_variant_rename_preserves_tree_and_retries_races,
\ case_variant_rename_preserves_a_swapped_source,
\ scan_of_a_stand_in_publishes_nothing,
\ unchanged_tree_beside_a_same_named_directory_republishes_nothing,
\ switching_local_root_clears_the_hash_cache (JOURNAL) and
\ slots_lease_through_a_symlinked_state_home (CONFIG).
: CASES ( -- )
   ENTRY-EXISTENCE-NEVER-FOLLOWS-SYMLINKS-AND-TREATS-PROBE-FAILURES-AS-UNCONFIRMED
   DROPBOX-HASH-USES-BLOCK-HASH-COMPOSITION
   DROPBOX-HASH-AND-COPY-ARE-INDEPENDENT-OF-READER-FRAGMENTATION
   AR @ LOCAL:SCAN-CASES
   MARKER-IS-RUSTS
   STAGE-MARKER-IS-SET-READ-AND-REMOVED
   EACH-DOWNLOAD-STAGE-IS-INSPECTED
   EACH-STAGE-OUTCOME-IS-REACHED
   UPLOAD-STAGE-COLLECTION-REMOVES-ONLY-VERIFIED-UNREFERENCED-CONTENT
   EACH-UPLOAD-STAGE-OUTCOME-IS-REACHED
   VANISHED-OR-DIRECTORY-SOURCE-IS-SOURCE-CHANGED
   ONE-COMPONENT-PARENT-IS-A-DUPLICATE-ROOT
   EXISTING-PARENT-OPENS
   MISSING-PARENT-IS-NONE-WITHOUT-CREATE
   CREATE-MAKES-PRIVATE-PARENTS
   SYMLINK-PARENT-IS-REFUSED
   UNSAFE-PARENT-PATH-FAILS
   DOWNLOAD-CHECKPOINT-STATE-ENCODES-THE-LAST-COMPLETE-BOUNDARY
   SLOT-BYTES-ARE-RUSTS
   PARTIAL-RESET-NEVER-MUTATES-A-SWAPPED-REPLACEMENT
   DOWNLOAD-SLOT-POOL-HAS-FOUR-FIXED-PATHS-WITHOUT-OVERFLOW
   PROTECTED-DOWNLOAD-SLOT-KEEPS-ITS-BINDING-AND-BYTES
   STALE-SLOT-IS-REBOUND-ACROSS-ROOT-AND-OPERATION-IDENTITY
   INTERRUPTED-DOWNLOADS-RESUME-FROM-DURABLE-BOUNDARIES
   COMPLETED-PARTIAL-RECOVERS-BEFORE-AND-AFTER-RENAME
   CORRUPT-COMPLETED-PARTIAL-RESTARTS-ONLY-WHEN-OWNED
   COMPLETED-PARTIAL-PROMOTION-PRESERVES-A-SWAPPED-REPLACEMENT
   CROSS-FILESYSTEM-SLOT-COMPLETION-COPIES-REHASHES-AND-FREES-THE-SLOT
   INTERRUPTED-PARTIAL-RESET-REPLAYS-TO-A-REUSABLE-ZERO-CHECKPOINT
   ABSENT-INSTALL-NEVER-OVERWRITES-AN-EXISTING-FILE
   INSTALL-REJECTS-STAGE-CHANGED-THROUGH-A-PREEXISTING-WRITER
   INSTALLED-DOWNLOAD-CLEANUP-REPLAYS-AROUND-PARTIAL-MARKER-REMOVAL
   RENAMED-DOWNLOAD-REQUIRES-ITS-OWNERSHIP-MARKER
   EACH-INSTALL-OUTCOME-IS-REACHED
   OBJECT-AT-STAGE-NAME-BLOCKS-ONLY-ITS-INSTALL
   EACH-REPLACEMENT-PREPARATION-IS-REACHED
   COMPLETE-DISPOSABLE-DOWNLOAD-CLOSES-ITS-PARENT
   DISPOSABLE-DOWNLOAD-BODY-DOES-NOT-HOLD-THE-SCAN-LOCK
   DIRECTORY-EFFECTS-ARE-NONOVERWRITING-AND-NONRECURSIVE
   DELETE-REPLAY-PRESERVES-A-RACED-EDIT-AND-REMOVES-ITS-GUARD
   EACH-DELETE-OUTCOME-IS-REACHED
   EACH-CONFLICT-OUTCOME-IS-REACHED ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   [: CASES ;] [: AR @ ARENA:RELEASE ;] finally
   s" local-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

LOCAL-TEST:RUN
