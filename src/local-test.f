\ local-test.f - LOCAL's shared words, scan, upload and download stages,
\ download slots and partials, installs, deletes, directories, conflicts
\ and recovery copies: local.rs's tests that an entry's existence below
\ the root never follows a symlink and takes a failed probe as
\ unconfirmed, that the content hash composes block hashes, and that
\ neither the hash nor a stage's copy depends on how a reader fragments
\ the bytes; its scan tests, the reason each failure one entry raises
\ publishes and the lines LOCAL logs for it among them, each scanning
\ into a journal in a directory of its own beside the case's root, in
\ the part LOCAL SCAN-TEST, which sees LOCAL's private types, and
\ there too that a denied write's line gives its directory's and entry's
\ facts, a denied rename's names both directories, one on a directory
\ already closed gives none of its facts, a denied directory creation's
\ names its parent and no entry, an existing directory's denial gives its
\ entry, and a converted denial logs nothing, that WATCHING's lines are
\ formal/LocalWatch.tla's, through TEST-FORMAL:HOLDS, which runs TLC, and
\ that a real watch hears changes in its folders, goes blind when its
\ root moves or is in doubt, and arms anew once a full scan's listings
\ no longer stand; that upload stage collection
\ removes only verified unreferenced content; then each stage outcome,
\ each inspected download stage, a stage marker set, read and removed, a
\ second mark failing with one xattr line on stderr, each upload stage
\ outcome, an upload source that vanished or is a directory, each parent
\ a download opens and an unreadable hash input failing; then that a
\ slot's state keeps its last checkpoint, that slot identity and state
\ bytes are the Rust daemon's, a reset never touches a replacement
\ swapped in, the pool's four fixed slots, a protected slot kept and
\ a stale one rebound; then that a cut download resumes from its last
\ durable checkpoint, a completed partial is promoted before or after
\ its rename, a corrupt one restarts only in its own slot, a promotion
\ keeps a swapped replacement, a refused slot promotion names both
\ sides, a copy across filesystems frees its slot, and a reset slot
\ replays to offset 0, each completed stage
\ installed and read back at its target; that a restart empties its
\ partial, keeps a swapped replacement and fails in a slot directory it
\ cannot search; that slots lease through a symlinked state home; then
\ local.rs's install tests, each install outcome, an install a directory
\ or an unreadable file at its stage's name blocks, each replacement
\ preparation, that a complete disposable download closes its parent,
\ and the scan lock test's half without the lock: a disposable partial
\ appended is staged and leaves its staging directory empty; then that
\ directory effects never overwrite or recurse, that a delete's replay
\ keeps a raced edit, each delete outcome, a delete of an uppercase hash
\ failing, each arm of a changed guard's restore, each directory and
\ conflict outcome, a recovery copy's name the Rust daemon's and each
\ verification of one; then local.rs's tests that a case-variant rename
\ keeps the tree, retries a race and keeps a swapped source, and that
\ a parent's name limit is none when it is missing. A case that makes
\ files works in its own directory under TMPDIR and removes it.
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
require src/lib/fs-statx.f
require src/lib/fs-list.f
require src/lib/fd.f
require src/lib/xattr.f
require src/lib/adt/option.f
require src/dropbox.f
require src/model.f
require src/config.f
require src/journal.f
require src/test-journal.f
require src/local.f
require src/test-client.f
require src/test-formal.f

\ LOCAL reopened for the stream a fragmenting reader feeds, its stage
\ words, and the names of its private results' variants.
package LOCAL
private

\ The variant's name; a verified stage's descriptor is closed.
: DOWNLOAD-STAGE$ ( download-stage -- str )
   MATCH download-stage
      missing OF s" missing" ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :} f DISCARD s" verified"
      ENDOF
      destination-occupied OF {: p:str :} s" destination-occupied" ENDOF
   ;MATCH ;

: INSPECTED$
   ( fd str str str DROPBOX:hash ^ARENA:arena -- str )
   INSPECT-DOWNLOAD-STAGE DOWNLOAD-STAGE$ ;

: MARKER$ ( fd str str -- str )
   READ-DOWNLOAD-MARKER MATCH download-marker
      missing OF s" missing" ENDOF
      expected OF s" expected" ENDOF
      other OF s" other" ENDOF
   ;MATCH ;

\ WRITE-VERIFIED-STAGE's result as its caller sees it, the stage 0.
: WRITE-STAGE-OUTCOME
   ( fd str str DROPBOX:hash [ ^u8 n -- n ] option<str> str
     ^ARENA:arena -- stage-outcome<n> )
   WRITE-VERIFIED-STAGE [: 0 ;] MAP-STAGE-WRITE ;

\ OPEN-PARENT's answer apart: its descriptor, name, parent path and true;
\ for none, -1, empty spans and false.
: PARENT-OF ( fd str bool -- fd str str bool )
   OPEN-PARENT MATCH option
      none OF -1 >FD s" " s" " false ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str path:str :}
         f name path true
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
: SLOT-STATE-OF ( fd str -- binding n bool )
   READ-DOWNLOAD-SLOT-STATE STATE-APART ;

\ The state encoded and decoded again, apart.
: STATE-ROUND-TRIP ( binding n -- binding n bool )
   DOWNLOAD-SLOT-STATE-MAKE ENCODE-DOWNLOAD-SLOT-STATE
   DECODE-DOWNLOAD-SLOT-STATE STATE-APART ;

\ The slot state's bytes for the binding at offset, valid until the
\ next encode.
: STATE-BYTES ( binding n -- str )
   DOWNLOAD-SLOT-STATE-MAKE ENCODE-DOWNLOAD-SLOT-STATE ;

32 BUFFER: FILLED

\ The binding whose 32 bytes are all c.
: FILLED-BINDING ( n -- binding )
   {: c:n :}
   32 0 ?do c FILLED i + c! loop
   FILLED BYTES>BINDING ;

\ The slot opened for writing and true; for a missing or occupied one,
\ -1 and false.
: OPENED-SLOT ( fd str str -- fd bool )
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
         slots name loc TARGET-DIR@ loc STAGE-NAME@
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

: PARTIAL-STAGE-PATH ( ^download-partial -- str )
   DOWNLOAD-PARTIAL-LOCATION STAGE-PATH@ ;

\ The name target t's stage of want takes.
: STAGE-NAME ( str DROPBOX:hash ^ARENA:arena -- str )
   {: t:str want:DROPBOX:hash ar:^ARENA:arena :}
   s" download" t want ar INTERNAL-NAME ;

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
   ( fd str str DROPBOX:hash ^ARENA:arena fd -- )
   {: root:fd r:str t:str want:DROPBOX:hash ar:^ARENA:arena
      w:fd :}
   root t false OPEN-PARENT MATCH option
      none OF E-CHANGED throw ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         [: f name rel r t want ar INSTALL-OF w RENAME-MUTATED ;]
         [: f DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ PREPARE-REPLACEMENT-AT on target t below the root fd at r, its parent
\ opened as INSTALL-DOWNLOAD-AT opens it.
: PREPARE-BELOW
   ( fd str str DROPBOX:hash ^ARENA:arena -- replacement-preparation )
   {: root:fd r:str t:str c:DROPBOX:hash ar:^ARENA:arena :}
   root t false OPEN-PARENT MATCH option
      none OF E-CHANGED throw ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         r rel ar JOIN {: dp:str :}
         [: f dp name t c ar PREPARE-REPLACEMENT-AT ;]
         [: f DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ SYNC-RENAMED-DOWNLOAD of the file at t in dir, as a stage verified
\ now, refuses it: it carries no marker.
: RENAMED-WITHOUT-MARKER
   ( fd fd str DROPBOX:hash ^ARENA:arena -- )
   {: f:fd dir:fd t:str want:DROPBOX:hash ar:^ARENA:arena :}
   f t s" inspect test download" STAT-FD t FILE-FINGERPRINT
   {: print:MODEL:fingerprint :}
   f print VERIFIED-DOWNLOAD-STAGE-MAKE {: s:verified-download-stage :}
   [: s dir t t want ar SYNC-RENAMED-DOWNLOAD ;]
   E-CHANGED TTHROWSQ ;

public
EXPORT READY-PARTIAL
EXPORT DISPOSABLE?
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
EXPORT RESTORE-OR-PRESERVE-CHANGED-GUARD
EXPORT CONFLICT-NAME
EXPORT RENAME-CASE-VARIANT-WITH
;package

\ LOCAL reopened for its scan's cases, which name its private types.
package LOCAL
private
package SCAN-TEST

TYPED-VARIABLE AR ^ARENA:arena

448 constant MODE-0700

\ ---- the case's tree

FS:PATHZ-CAP BUFFER: ROOT-BUF
variable ROOT-U
FS:PATHZ-CAP BUFFER: JOINED

: ROOT$ ( -- str ) ROOT-BUF ROOT-U @ >str ;

\ The name below the case's root, valid until the next AT.
: AT ( str -- str )
   {: p:str :}
   ROOT$ p JOINED FS:JOIN-PATH JOINED swap >str ;

: WRITE ( str str -- ) {: p:str b:str :} p AT b FS:WRITE-ALL ;
: MKDIR ( str -- ) AT FS:MAKE-DIR ;
: REMOVE ( str -- ) AT FS:REMOVE-FILE ;
: DENY ( str -- ) AT 0 FS:CHMOD-MODE ;
: ALLOW ( str -- ) AT MODE-0700 FS:CHMOD-MODE ;

\ A new directory under TMPDIR, its path copied to buf; the path's length.
: TEMP-DIR ( str ^u8 -- n )
   {: pre:str buf:^ :}
   pre FS:MKTEMP-DIR str> {: p:^ u:n :}
   p buf u BYTE-COPY u ;

\ Runs q in a new root under TMPDIR, which it then removes.
: IN-CASE ( [ -- ] -- )
   {: q :}
   s" local-scan-test" ROOT-BUF TEMP-DIR ROOT-U !
   [: q execute ;] [: ROOT$ FS:REMOVE-TREE ;] finally ;

FS:PATHZ-CAP BUFFER: OUTSIDE-BUF
variable OUTSIDE-U

: OUTSIDE$ ( -- str ) OUTSIDE-BUF OUTSIDE-U @ >str ;

\ Runs q beside a new directory under TMPDIR, outside the case's root,
\ which it then removes.
: BESIDE-OUTSIDE ( [ -- ] -- )
   {: q :}
   s" local-scan-outside" OUTSIDE-BUF TEMP-DIR OUTSIDE-U !
   [: q execute ;] [: OUTSIDE$ FS:REMOVE-TREE ;] finally ;

64 BUFFER: READ-BUF

: CONTENT-OF ( str -- str )
   AT READ-BUF 64 FS:READ-ALL READ-BUF swap >str ;

PROCESS-SYMBOLS
FUNCTION: READLINK-CALL readlink ( ^u8 ^u8 n -- n ) ;FUNCTION


: LINK-OF ( str -- str )
   AT FS:>PATHZ READ-BUF 64 READLINK-CALL READ-BUF swap >str ;

FUNCTION: MKFIFO-CALL mkfifo ( ^u8 n -- i32 ) ;FUNCTION
FUNCTION: GETRLIMIT-CALL getrlimit ( n ^u8 -- i32 ) ;FUNCTION
FUNCTION: SETRLIMIT-CALL setrlimit ( n ^u8 -- i32 ) ;FUNCTION

384 constant MODE-0600

FS:PATHZ-CAP BUFFER: TARGET

\ The name below the case's root, valid until the next TARGET-AT.
: TARGET-AT ( str -- str )
   {: p:str :}
   ROOT$ p TARGET FS:JOIN-PATH TARGET swap >str ;

\ Root opens a file and searches a directory whatever its mode.
: ROOT-USER? ( -- bool ) FS:EUID 0 = ;

FS:PATHZ-CAP BUFFER: LOG-AT

\ stderr.txt below the case's root, apart from AT's buffer, which a
\ captured action may reuse.
: LOG-PATH ( -- str )
   ROOT$ s" stderr.txt" LOG-AT FS:JOIN-PATH LOG-AT swap >str ;

\ Runs q with fd 2 sent to LOG-PATH; what that file then holds, in AR,
\ after which it is removed.
: STDERR-OF ( [ -- ] -- str )
   LOG-PATH AR @ STDERR:CAPTURING {: code:n e:str :}
   code 0<> if code throw then
   e ;

\ ---- the case's journal

FS:PATHZ-CAP BUFFER: JOURNAL-BUF
variable JOURNAL-U
FS:PATHZ-CAP BUFFER: JOURNAL-FILE

: JOURNAL-DIR$ ( -- str ) JOURNAL-BUF JOURNAL-U @ >str ;

: JOURNAL-PATH ( -- str )
   JOURNAL-DIR$ s" journal.sqlite3" JOURNAL-FILE FS:JOIN-PATH
   JOURNAL-FILE swap >str ;

\ Runs q on the journal in JOURNAL-DIR$, then closes it.
: OPENED-JOURNAL ( [ JOURNAL:journal -- ] -- )
   {: q :}
   JOURNAL-PATH AR @ KEEP JOURNAL:OPEN {: j :}
   [: j q execute ;] [: j JOURNAL:CLOSE ;] finally ;

\ Runs q on a journal in a new directory under TMPDIR, outside the
\ case's root, which it then removes.
: WITH-JOURNAL ( [ JOURNAL:journal -- ] -- )
   {: q :}
   s" local-scan-journal" JOURNAL-BUF TEMP-DIR JOURNAL-U !
   [: q OPENED-JOURNAL ;] [: JOURNAL-DIR$ FS:REMOVE-TREE ;] finally ;

\ The journal a scan case publishes to, and its active root, ROOT$.
TYPED-VARIABLE JNL JOURNAL:journal
TYPED-VARIABLE BOUND JOURNAL:local-root-binding

: ACTIVATE-ROOT ( JOURNAL:journal -- )
   {: j :}
   ROOT$ AR @ KEEP JOURNAL:INSPECT {: b :}
   j b AR @ JOURNAL:ACTIVATE-LOCAL-ROOT drop
   j JNL ! b BOUND ! ;

\ Runs q in a new root under TMPDIR, the active root of a journal
\ beside it; both are then removed.
: IN-SCAN-CASE ( [ -- ] -- )
   {: q :}
   [: [: ACTIVATE-ROOT q execute ;] WITH-JOURNAL ;] IN-CASE ;

\ ---- the scan's values

: ZEROS ( -- str )
   s" 0000000000000000000000000000000000000000000000000000000000000000" ;

: NO-CUTOFF ( -- option<MODEL:cutoff> ) OPTION:NONE ;

: STABLE ( -- option<MODEL:cutoff> )
   $7FFFFFFFFFFFFFFF 999999999 MODEL-CUTOFF:MAKE OPTION:SOME ;

: NO-CACHE ( -- ^VEC:vector<MODEL:hash-record> )
   AR @ [type] MODEL:hash-record NEW-VEC ;

: TEST-CACHE
   ( str MODEL:fingerprint str -- ^VEC:vector<MODEL:hash-record> )
   {: p:str f:MODEL:fingerprint c:str :}
   NO-CACHE {: v :}
   p MODEL:>PATH f c DROPBOX:>HASH MODEL-HASH--RECORD:MAKE
   v VEC:PUSH !
   v ;

\ Rust's fingerprint: the file's below the case's root.
: FINGERPRINT-AT ( str -- MODEL:fingerprint )
   {: p:str :}
   ROOT$ s" open test scan root" OPEN-ROOT {: root:fd :}
   root p s" open test scan file" E-IO E-UNSUPPORTED
   OPEN-RELATIVE-REGULAR {: f:fd :}
   f p s" inspect test scan file" STAT-FD p FILE-FINGERPRINT
   f DISCARD root DISCARD ;

\ Rust's identity: the content hash of the bytes, read from a pipe.
: IDENTITY ( str -- str )
   {: p:str :}
   FD:PIPE {: r:fd w:fd :}
   w p FD:WRITE-FULL w DISCARD
   r AR @ DROPBOX-CONTENT-HASH r DISCARD
   DROPBOX:HASH>STR ;

: ROOT-CHANGED? ( scan-publication -- bool )
   MATCH scan-publication
      published OF false ENDOF
      root-changed OF true ENDOF
   ;MATCH ;

\ The journal's published inventory and hash cache, in AR.
: INVENTORY ( -- ^VEC:vector<MODEL:local-record> )
   JNL @ AR @ JOURNAL:LOCAL-INVENTORY ;

: REUSABLE ( -- ^VEC:vector<MODEL:hash-record> )
   JNL @ AR @ JOURNAL:LOCAL-HASH-CACHE ;

\ Makes the records the journal's hash cache, its inventory empty.
: SEED ( ^VEC:vector<MODEL:hash-record> -- )
   {: cache :}
   JNL @ BOUND @ AR @ [type] MODEL:local-record NEW-VEC cache
   JOURNAL:PUBLISH-LOCAL-SCAN TTRUE ;

\ Rust's scan_and_publish_at: ROOT$ scanned with the journal's cache and
\ published to it; cut decides which cached hashes the walk reuses, q
\ which hashes it computes stay reusable. The inventory published.
: CACHED-SCAN ( option<MODEL:cutoff> [ -- option<MODEL:cutoff> ]
     -- ^VEC:vector<MODEL:local-record> )
   {: cut:option<MODEL:cutoff> q :}
   JNL @ ROOT$ cut q AR @ SCAN-AND-PUBLISH-AT ROOT-CHANGED? TFALSE
   INVENTORY ;

\ CACHED-SCAN, computed hashes reusable before the current cutoff.
: SCAN-AT ( option<MODEL:cutoff> -- ^VEC:vector<MODEL:local-record> )
   [: CURRENT-HASH-CACHE-CUTOFF ;] CACHED-SCAN ;

: ROOT-SCAN ( -- ^VEC:vector<MODEL:local-record> ) NO-CUTOFF SCAN-AT ;

\ ROOT$ enumerated into the scan with the journal's cache; cut decides
\ which cached hashes the walk reuses.
: ENUMERATE
   ( JOURNAL:scan option<MODEL:cutoff> -- JOURNAL:scan pending-scan )
   {: cut:option<MODEL:cutoff> :}
   ROOT$ cut AR @ ENUMERATE-SCAN ;

\ Finishes the pending scan and publishes it; q decides which hashes it
\ computes stay reusable.
: FINISH-SCAN-AT
   ( JOURNAL:scan pending-scan [ -- option<MODEL:cutoff> ] -- JOURNAL:scan )
   {: ps:pending-scan q :}
   ps q JNL @ FINISH-BOUND-SCAN-AT MATCH option
      none OF false TTRUE ENDOF
      some OF JOURNAL:PUBLISH-SCAN TTRUE ENDOF
   ;MATCH ;

: FINISH-SCAN ( JOURNAL:scan pending-scan -- JOURNAL:scan )
   [: CURRENT-HASH-CACHE-CUTOFF ;] FINISH-SCAN-AT ;

\ Runs body over a scan of the journal; the inventory it published.
: SCANNED ( [ JOURNAL:scan -- JOURNAL:scan ]
     -- ^VEC:vector<MODEL:local-record> )
   {: body :}
   JNL @ body JOURNAL:WITH-SCAN INVENTORY ;

\ Closes the root a pending scan holds, as Rust's drop of one.
: RELEASE ( pending-scan -- )
   PENDING-SCAN-UNMAKE {: r:str f:fd b:MODEL:stat ar :}
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

: PUBLISHED ( ^VEC:vector<MODEL:local-record> -- n ) VEC:COUNT ;

: OBSERVATION-PATH ( MODEL:local-record -- str )
   MODEL-LOCAL--RECORD:UNMAKE
   {: p:MODEL:path o:MODEL:observation<MODEL:local> :}
   p MODEL:PATH>STR ;

\ The observation of the path, none where the inventory holds none.
: FIND
   ( ^VEC:vector<MODEL:local-record> str
     -- option<MODEL:local-record> )
   {: v p:str :}
   v VEC:COUNT 0 ?do
      v i VEC:AT @ {: r:MODEL:local-record :}
      r OBSERVATION-PATH p STR:= if r OPTION:SOME unloop exit then
   loop OPTION:NONE ;

: KIND-AT ( ^VEC:vector<MODEL:local-record> str -- n )
   FIND MATCH option
      none OF MISSING ENDOF
      some OF RECORD-OBSERVATION KIND ENDOF
   ;MATCH ;

: SEEN ( ^VEC:vector<MODEL:local-record> str n -- )
   {: s p:str want:n :}
   s p KIND-AT want T= ;

\ Rust's scanned_content: a present file's content hash, else empty.
: SCANNED-CONTENT ( ^VEC:vector<MODEL:local-record> str -- str )
   FIND MATCH option
      none OF s" " ENDOF
      some OF RECORD-OBSERVATION MATCH MODEL:observation
            present OF MODEL-LOCAL:UNMAKE DROPBOX:HASH>STR ENDOF
            directory OF s" " ENDOF
            absent OF s" " ENDOF
            unknown OF {: why:MODEL:unknown-reason :} s" " ENDOF
         ;MATCH
      ENDOF
   ;MATCH ;

\ Rust's observed_paths refuses a path published twice; the observations
\ are also in strictly increasing byte order.
: ORDERED ( ^VEC:vector<MODEL:local-record> -- )
   {: v :}
   true v VEC:COUNT 1 max 1 ?do
      v i 1- VEC:AT @ OBSERVATION-PATH
      v i VEC:AT @ OBSERVATION-PATH STR:< and
   loop TTRUE ;

: RECORD-CONTENT ( MODEL:hash-record -- DROPBOX:hash )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :} c ;

: SAME-RECORDS
   ( ^VEC:vector<MODEL:hash-record> ^VEC:vector<MODEL:hash-record> -- )
   {: a b :}
   a VEC:COUNT b VEC:COUNT T=
   a VEC:COUNT b VEC:COUNT min 0 ?do
      a i VEC:AT @ {: x:MODEL:hash-record :}
      b i VEC:AT @ {: y:MODEL:hash-record :}
      x RECORD-PATH y RECORD-PATH T$=
      x RECORD-FINGERPRINT y RECORD-FINGERPRINT SAME-FINGERPRINT? TTRUE
      x RECORD-CONTENT DROPBOX:HASH>STR
      y RECORD-CONTENT DROPBOX:HASH>STR T$=
   loop ;

\ Whether the hash records hold one at the path.
: HOLDS? ( ^VEC:vector<MODEL:hash-record> str -- bool )
   {: v p:str :}
   false v VEC:COUNT 0 ?do
      v i VEC:AT @ RECORD-PATH p STR:= or
   loop ;

\ ---- cases

: SCAN-PUBLISHES-EMPTY-AND-NESTED-DIRECTORIES ( -- )
   s" scan_publishes_empty_and_nested_directories" T-LABEL
   s" parent" MKDIR s" parent/child" MKDIR s" empty" MKDIR
   ROOT-SCAN {: s :}
   s ORDERED
   s s" empty" DIRECTORY SEEN
   s s" parent" DIRECTORY SEEN
   s s" parent/child" DIRECTORY SEEN ;

: LOCKED-AFTER-ENUMERATION ( JOURNAL:scan -- JOURNAL:scan )
   NO-CUTOFF ENUMERATE {: ps:pending-scan :}
   s" locked.txt" DENY
   ps FINISH-SCAN ;

: FILE-LOCKED-AFTER-ENUMERATION-IS-INACCESSIBLE ( -- )
   s" file_locked_after_enumeration_is_inaccessible" T-LABEL
   s" locked.txt" s" locked" WRITE
   s" stable.txt" s" stable" WRITE
   [: LOCKED-AFTER-ENUMERATION ;] SCANNED {: s :}
   s s" locked.txt" INACCESSIBLE SEEN
   s s" stable.txt" PRESENT SEEN ;

\ ---- files that change before hashing

\ The walk enumerates "nested/a-missing", which is gone when its job
\ hashes.
: REMOVED-BEFORE-HASHING ( JOURNAL:scan -- JOURNAL:scan )
   NO-CUTOFF ENUMERATE {: ps:pending-scan :}
   s" nested/a-missing" REMOVE
   ps FINISH-SCAN ;

: NEW-FILE-REMOVED-BEFORE-HASHING-IS-INCOMPLETE ( -- )
   s" new_file_removed_before_hashing_is_incomplete" T-LABEL
   s" nested" MKDIR
   s" kept" s" kept" WRITE
   s" nested/a-missing" s" a" WRITE
   [: REMOVED-BEFORE-HASHING ;] SCANNED {: s :}
   s s" nested" DIRECTORY SEEN
   s s" nested/a-missing" INCOMPLETE SEEN
   s s" kept" PRESENT SEEN
   s PUBLISHED 3 T= ;

\ The stored file's new bytes make it a job, and its cached hash is not
\ kept once the job finds the file gone.
: STORED-FILE-CHANGED-THEN-REMOVED-BEFORE-HASHING-IS-INCOMPLETE ( -- )
   s" stored_file_changed_then_removed_before_hashing_is_incomplete"
   T-LABEL
   s" nested" MKDIR
   s" kept" s" kept" WRITE
   s" nested/a-missing" s" a" WRITE
   NO-CUTOFF [: STABLE ;] CACHED-SCAN PUBLISHED 3 T=
   s" nested/a-missing" s" longer bytes" WRITE
   [: REMOVED-BEFORE-HASHING ;] SCANNED {: s :}
   s s" nested" DIRECTORY SEEN
   s s" nested/a-missing" INCOMPLETE SEEN
   s s" kept" PRESENT SEEN
   s PUBLISHED 3 T=
   REUSABLE s" nested/a-missing" HOLDS? TFALSE ;

\ A stable rescan reuses every hash, so it stages no job, and the file
\ is removed after the walk.
: REMOVED-AFTER-THE-WALK ( JOURNAL:scan -- JOURNAL:scan )
   STABLE ENUMERATE {: ps:pending-scan :}
   JOURNAL:SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 0 T= hashes 0 T=
   s" nested/a-missing" REMOVE
   ps [: STABLE ;] FINISH-SCAN-AT ;

\ The walk's observation stands until the next scan finds the file gone.
: CACHED-FILE-REMOVED-AFTER-THE-WALK-STAYS-UNTIL-THE-NEXT-SCAN ( -- )
   s" cached_file_removed_after_the_walk_stays_until_the_next_scan"
   T-LABEL
   s" nested" MKDIR
   s" nested/a-missing" s" a" WRITE
   NO-CUTOFF [: STABLE ;] CACHED-SCAN PUBLISHED 2 T=
   [: REMOVED-AFTER-THE-WALK ;] SCANNED {: s :}
   s s" nested/a-missing" PRESENT SEEN
   STABLE [: STABLE ;] CACHED-SCAN {: t :}
   t s" nested/a-missing" MISSING SEEN
   t s" nested" DIRECTORY SEEN
   REUSABLE s" nested/a-missing" HOLDS? TFALSE ;

\ The walk enumerates "nested/a-missing", which is a symlink to "kept"
\ when its job opens it.
: LINKED-BEFORE-HASHING ( JOURNAL:scan -- JOURNAL:scan )
   NO-CUTOFF ENUMERATE {: ps:pending-scan :}
   s" nested/a-missing" REMOVE
   s" kept" TARGET-AT s" nested/a-missing" AT FS:MAKE-SYMLINK
   ps FINISH-SCAN ;

: FILE-REPLACED-BY-A-SYMLINK-BEFORE-HASHING-IS-INCOMPLETE ( -- )
   s" file_replaced_by_a_symlink_before_hashing_is_incomplete" T-LABEL
   s" nested" MKDIR
   s" kept" s" kept" WRITE
   s" nested/a-missing" s" a" WRITE
   [: LINKED-BEFORE-HASHING ;] SCANNED {: s :}
   s s" nested/a-missing" INCOMPLETE SEEN
   s s" kept" PRESENT SEEN ;

\ A stable scan with "locked" and "locked-x" unreadable.
: DENIED-SCAN ( -- ^VEC:vector<MODEL:local-record> )
   s" locked" DENY s" locked-x" DENY
   [: STABLE [: STABLE ;] CACHED-SCAN ;]
   [: s" locked" ALLOW s" locked-x" ALLOW ;] finally ;

\ Every hash the cache holds is reused: no job, and the six stored rows
\ beneath the two directories staged.
: ALL-HASHES-REUSED ( JOURNAL:scan -- JOURNAL:scan )
   STABLE ENUMERATE {: ps:pending-scan :}
   JOURNAL:SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 6 T= hashes 0 T=
   ps [: STABLE ;] FINISH-SCAN-AT ;

\ The rows beneath an unreadable directory leave the inventory, but
\ their cached hashes stay for the scan that can read them again.
: STORED-ROWS-BENEATH-DENIED-DIRECTORIES-KEEP-THEIR-HASHES ( -- )
   s" stored_rows_beneath_denied_directories_keep_their_hashes" T-LABEL
   s" locked" MKDIR s" locked/secret.txt" s" secret" WRITE
   s" locked/sub" MKDIR s" locked/sub/deep.txt" s" deep" WRITE
   s" locked-x" MKDIR s" locked-x/other.txt" s" other" WRITE
   s" open.txt" s" open" WRITE
   NO-CUTOFF [: STABLE ;] CACHED-SCAN PUBLISHED 7 T=
   REUSABLE VEC:COUNT 4 T=
   DENIED-SCAN {: s :}
   s s" locked" INACCESSIBLE SEEN
   s s" locked-x" INACCESSIBLE SEEN
   s s" locked/secret.txt" MISSING SEEN
   s s" locked/sub" MISSING SEEN
   s s" locked/sub/deep.txt" MISSING SEEN
   s s" locked-x/other.txt" MISSING SEEN
   s s" open.txt" PRESENT SEEN
   s PUBLISHED 3 T=
   REUSABLE VEC:COUNT 4 T=
   [: ALL-HASHES-REUSED ;] SCANNED {: t :}
   t PUBLISHED 7 T=
   t s" locked/sub/deep.txt" PRESENT SEEN
   t s" locked-x/other.txt" PRESENT SEEN
   REUSABLE VEC:COUNT 4 T= ;

\ ---- a listed directory's guards

: TEST-ROOT ( -- fd ) ROOT$ s" open test scan root" OPEN-ROOT ;

\ The walk's no-follow stat of the name in dir.
: WALK-STAT ( fd str -- MODEL:stat ) FS:TRY-STAT-AT TTRUE BUF-STAT ;

: HELD-DIRS ( -- ^VEC:vector<held-dir> ) AR @ [type] held-dir NEW-VEC ;

\ "d" moved aside to "moved", which keeps its inode from reuse.
: D-MOVED ( -- ) s" d" TARGET-AT s" moved" AT FS:RENAME-FILE ;

\ "d" moved aside, a new directory holding "d/x" in its place.
: D-REPLACED ( -- ) D-MOVED s" d" MKDIR s" d/x" s" x" WRITE ;

\ "d" moved aside, a symlink to the directory "target" in its place.
: D-LINKED ( -- )
   s" target" MKDIR s" target/x" s" x" WRITE
   D-MOVED s" target" TARGET-AT s" d" AT FS:MAKE-SYMLINK ;

: A-DIRECTORY-GROWN-SINCE-ITS-STAT-HAS-CHANGED ( -- )
   s" a_directory_grown_since_its_stat_has_changed" T-LABEL
   s" d" MKDIR
   TEST-ROOT {: root:fd :}
   root s" d" s" d" OPEN-DIRECTORY-AT {: child:fd :}
   child s" d" s" inspect test directory" STAT-FD {: before:MODEL:stat :}
   s" d/new" s" new" WRITE
   [: child s" d" before AR @ LISTED-STILL drop ;] ['] ENTRY-CODE? CONVERTING
   E-CHANGED T=
   child DISCARD root DISCARD ;

\ The kind the walk publishes for a nonzero code, MISSING for 0.
: CODE-KIND ( n -- n )
   {: code:n :}
   code 0= if MISSING exit then
   code WALK-UNKNOWN REASON-KIND ;

\ SCAN-SUBDIRECTORY of "d" by the probe, quiet as the walk is: its code
\ and the kind the walk publishes for it; nothing is held.
: SUBDIRECTORY-REFUSED ( JOURNAL:scan fd MODEL:stat -- JOURNAL:scan n n )
   {: root:fd probe:MODEL:stat :}
   HELD-DIRS {: held :}
   [: root s" d" s" d" probe held SCAN-SUBDIRECTORY ;]
   ['] ENTRY-CODE? WITH-CONVERTS {: code:n :}
   code code CODE-KIND
   held VEC:COUNT 0 T= held ALL-RELEASED ;

: ANOTHER-INODE-AT-THE-OPEN ( JOURNAL:scan -- JOURNAL:scan )
   TEST-ROOT {: root:fd :}
   root s" d" WALK-STAT {: probe:MODEL:stat :}
   D-REPLACED
   root probe SUBDIRECTORY-REFUSED INCOMPLETE T= E-CHANGED T=
   root DISCARD ;

: A-DIRECTORY-OF-ANOTHER-INODE-IS-NOT-HELD ( -- )
   s" a_directory_of_another_inode_is_not_held" T-LABEL
   s" d" MKDIR
   [: ANOTHER-INODE-AT-THE-OPEN ;] SCANNED drop ;

\ The open refuses the symlink, so the target is never opened.
: A-SYMLINK-AT-THE-OPEN ( JOURNAL:scan -- JOURNAL:scan )
   TEST-ROOT {: root:fd :}
   root s" d" WALK-STAT {: probe:MODEL:stat :}
   D-LINKED
   root probe SUBDIRECTORY-REFUSED INCOMPLETE T= E-IO T=
   root DISCARD ;

: A-DIRECTORY-NOW-A-SYMLINK-IS-NEVER-LISTED ( -- )
   s" a_directory_now_a_symlink_is_never_listed" T-LABEL
   s" d" MKDIR
   [: A-SYMLINK-AT-THE-OPEN ;] SCANNED drop ;

\ "d" walked by the stat taken before it was replaced, its code
\ published as SCAN-NAME publishes it, then every subtree held, and the
\ scan finished.
: REPLACED-BEFORE-ITS-OPEN ( JOURNAL:scan -- JOURNAL:scan )
   TEST-ROOT {: root:fd :}
   root ROOT$ ROOT-STAT {: before:MODEL:stat :}
   root s" d" WALK-STAT {: probe:MODEL:stat :}
   D-REPLACED
   NO-CUTOFF before STAT-DEV SCAN-CONTEXT-MAKE {: cx:scan-context :}
   HELD-DIRS {: held :}
   [: probe root s" d" s" d" cx held SCAN-PROBED ;]
   ['] ENTRY-CODE? WITH-CONVERTS {: code:n :}
   code 0<> if s" d" code WALK-UNKNOWN SEEN-UNKNOWN then
   held cx ENTERED-ALL
   ROOT$ AR @ KEEP root before AR @ PENDING-SCAN-MAKE FINISH-SCAN ;

: A-DIRECTORY-REPLACED-BEFORE-ITS-OPEN-IS-INCOMPLETE ( -- )
   s" a_directory_replaced_before_its_open_is_incomplete" T-LABEL
   s" d" MKDIR
   [: REPLACED-BEFORE-ITS-OPEN ;] SCANNED {: s :}
   s s" d" INCOMPLETE SEEN
   s s" d/x" MISSING SEEN
   s PUBLISHED 1 T= ;

: ENUMERATE-SCAN-ACROSS-DEVICES
   ( JOURNAL:scan str ^ARENA:arena -- JOURNAL:scan pending-scan )
   {: p:str ar:^ARENA:arena :}
   p ar KEEP {: root:str :}
   p s" open sync root for scan" OPEN-ABSOLUTE-DIRECTORY {: rfd:fd :}
   rfd p ROOT-STAT {: before:MODEL:stat :}
   root rfd before NO-CUTOFF before STAT-DEV 1 xor ar
   ENUMERATE-SCAN-ON-DEVICE ;

: SCANNED-ACROSS-DEVICES ( JOURNAL:scan -- JOURNAL:scan )
   ROOT$ AR @ ENUMERATE-SCAN-ACROSS-DEVICES FINISH-SCAN ;

: OBJECTS-ON-ANOTHER-DEVICE-ARE-UNSUPPORTED-AND-UNSCANNED ( -- )
   s" objects_on_another_device_are_unsupported_and_unscanned" T-LABEL
   s" volume" MKDIR
   s" volume/inside.txt" s" inside" WRITE
   s" outside.txt" s" outside" WRITE
   [: SCANNED-ACROSS-DEVICES ;] SCANNED {: across :}
   across ORDERED
   across s" volume" UNSUPPORTED-KIND SEEN
   across s" outside.txt" UNSUPPORTED-KIND SEEN
   across s" volume/inside.txt" MISSING SEEN
   across PUBLISHED 2 T=
   REUSABLE VEC:COUNT 0 T=
   ROOT-SCAN {: same :}
   same s" volume" DIRECTORY SEEN
   same s" volume/inside.txt" PRESENT SEEN
   same s" outside.txt" PRESENT SEEN
   same PUBLISHED 3 T= ;

: CHANGED-AFTER-ENUMERATION ( JOURNAL:scan -- JOURNAL:scan )
   STABLE ENUMERATE {: ps:pending-scan :}
   JOURNAL:SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 2 T=
   s" hashing" s" changed after enumeration" WRITE
   ps FINISH-SCAN ;

: CHANGING-FILES-ARE-UNKNOWN-WITHOUT-HIDING-STABLE-FILES ( -- )
   s" changing_files_are_unknown_without_hiding_stable_files" T-LABEL
   s" hashing" s" before" WRITE
   s" stable" s" stable" WRITE
   [: CHANGED-AFTER-ENUMERATION ;] SCANNED {: s :}
   s s" hashing" INCOMPLETE SEEN
   s s" stable" PRESENT SEEN ;

: UNCHANGED-SCAN-FILE-REUSES-CACHED-HASH-WITHOUT-READING-BYTES ( -- )
   s" unchanged_scan_file_reuses_cached_hash_without_reading_bytes" T-LABEL
   s" cached.txt" s" bytes that would hash differently" WRITE
   s" cached.txt" s" cached.txt" FINGERPRINT-AT ZEROS TEST-CACHE SEED
   STABLE SCAN-AT s" cached.txt" SCANNED-CONTENT ZEROS T$= ;

\ A stable rescan of an unchanged tree stages nothing.
: ALL-CACHED ( JOURNAL:scan -- JOURNAL:scan )
   STABLE ENUMERATE {: ps:pending-scan :}
   JOURNAL:SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 0 T= hashes 0 T=
   ps RELEASE ;

\ The cache the first scan published, which JOURNAL answers in
\ path-byte order, is the one the enumeration reuses and the next scan
\ publishes.
: FILE-BESIDE-A-SAME-NAMED-DIRECTORY-KEEPS-ITS-CACHED-HASH ( -- )
   s" file_beside_a_same_named_directory_keeps_its_cached_hash" T-LABEL
   s" x" MKDIR
   s" x.txt" s" beside the directory" WRITE
   s" x/y.txt" s" under the directory" WRITE
   NO-CUTOFF [: STABLE ;] CACHED-SCAN drop REUSABLE {: cache :}
   cache VEC:COUNT 2 T=
   [: ALL-CACHED ;] SCANNED drop
   NO-CUTOFF [: STABLE ;] CACHED-SCAN drop REUSABLE cache SAME-RECORDS ;

\ "a-b", "a.txt" and "a0" sort between "a" and what lies beneath it,
\ and "+y" before them all.
: ORDER-TREE ( -- )
   s" a" MKDIR s" a/b" MKDIR s" a-b" MKDIR
   s" a/x" s" x" WRITE s" a/b/c" s" c" WRITE s" a-b/c" s" c" WRITE
   s" a.txt" s" t" WRITE s" +y" s" y" WRITE s" a0" s" 0" WRITE ;

\ Unless the walk reaches JOURNAL in path byte order, the order of the
\ stored rows, the rescan of the unchanged tree stages rows.
: THE-WALK-FOLLOWS-PATH-BYTE-ORDER ( -- )
   s" the_walk_follows_path_byte_order" T-LABEL
   ORDER-TREE
   NO-CUTOFF [: STABLE ;] CACHED-SCAN {: s :}
   s PUBLISHED 9 T=
   s s" a/b/c" PRESENT SEEN
   [: ALL-CACHED ;] SCANNED PUBLISHED 9 T= ;

\ The rescan stages nothing, and its publish changes no row.
: REPUBLISHED-UNCHANGED ( JOURNAL:scan -- JOURNAL:scan )
   STABLE ENUMERATE {: ps:pending-scan :}
   JOURNAL:SCAN-COUNTS {: jobs:n staged:n hashes:n :}
   jobs 0 T= staged 0 T= hashes 0 T=
   JNL @ JOURNAL:TOTAL-CHANGES {: before:n :}
   ps [: STABLE ;] FINISH-SCAN-AT
   JNL @ JOURNAL:TOTAL-CHANGES before T= ;

: AN-UNCHANGED-TREE-STAGES-AND-WRITES-NOTHING ( -- )
   s" an_unchanged_tree_stages_and_writes_nothing" T-LABEL
   s" d" MKDIR s" d/f" s" f" WRITE s" e" MKDIR
   s" d/f" TARGET-AT s" link" AT FS:MAKE-SYMLINK
   NO-CUTOFF [: STABLE ;] CACHED-SCAN PUBLISHED 4 T=
   [: REPUBLISHED-UNCHANGED ;] SCANNED PUBLISHED 4 T= ;

variable ENTRIES

: COUNT-ENTRY ( str -- ) drop 1 ENTRIES +! ;

\ The count of the directory's entries but . and ..
: ENTRY-COUNT ( str -- n )
   0 ENTRIES ! [: COUNT-ENTRY ;] FS-LIST:EACH ENTRIES @ ;

: FD-COUNT ( -- n ) s" /proc/self/fd" ENTRY-COUNT ;

7 constant RLIMIT-NOFILE
create LIMITS 16 allot
variable SOFT

\ Lowers the soft limit on descriptors to n; SOFT holds the old one.
: FD-LIMIT ( n -- )
   RLIMIT-NOFILE LIMITS GETRLIMIT-CALL 0 T=
   LIMITS @ SOFT ! LIMITS !
   RLIMIT-NOFILE LIMITS SETRLIMIT-CALL 0 T= ;

: LIMIT-RESTORED ( -- )
   SOFT @ LIMITS ! RLIMIT-NOFILE LIMITS SETRLIMIT-CALL 0 T= ;

20 constant CHAIN-LEN
create CHAIN-BUF CHAIN-LEN allot

\ "sub/d", "sub/d-", "sub/d--" and on: each sorts before the subtree of
\ every shorter one, so the walk holds them all at once.
: CHAINED ( -- )
   s" sub" MKDIR
   s" sub/d" str> {: a:^u8 u:n :}
   u 0 ?do a i + c@ CHAIN-BUF i + c! loop
   CHAIN-LEN 5 ?do [char] - CHAIN-BUF i + c! loop
   CHAIN-LEN 5 ?do CHAIN-BUF i >str MKDIR loop ;

\ The walk with room for n descriptors more than were open.
: EXHAUSTED-WALK ( JOURNAL:scan n -- JOURNAL:scan )
   {: n :}
   n FD-LIMIT
   [: NO-CUTOFF ENUMERATE RELEASE ;] [: LIMIT-RESTORED ;] finally ;

\ The walk runs out of descriptors inside "sub", "sub" and the chain
\ held; the scan fails, and closes every one.
: A-FAILED-WALK-LEAVES-NO-DESCRIPTOR-OPEN ( -- )
   s" a_failed_walk_leaves_no_descriptor_open" T-LABEL
   CHAINED
   FD-COUNT {: before:n :}
   [: [: [: before 3 + EXHAUSTED-WALK ;] SCANNED drop ;]
      E-IO TTHROWSQ ;] STDERR-OF drop
   FD-COUNT before T= ;

: RECENT-CACHE-ENTRY-IS-REHASHED-AND-OMITTED ( -- )
   s" recent_cache_entry_is_rehashed_and_omitted" T-LABEL
   s" recent.txt" s" actual bytes" WRITE
   s" recent.txt" FINGERPRINT-AT {: f:MODEL:fingerprint :}
   f MODEL-FINGERPRINT:UNMAKE {: i sz ms mn cs cn :}
   ms mn MODEL-CUTOFF:MAKE OPTION:SOME {: cut:option<MODEL:cutoff> :}
   s" recent.txt" f ZEROS TEST-CACHE SEED
   cut [: NO-CUTOFF ;] CACHED-SCAN {: s :}
   s s" recent.txt" SCANNED-CONTENT s" actual bytes" IDENTITY T$=
   REUSABLE VEC:COUNT 0 T= ;

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
      s" changed.txt" f i FLIPPED ZEROS TEST-CACHE SEED
      STABLE SCAN-AT
      s" changed.txt" SCANNED-CONTENT s" actual bytes" IDENTITY T$=
   loop ;

: ZEROED ( MODEL:hash-record -- MODEL:hash-record )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :}
   p f ZEROS DROPBOX:>HASH MODEL-HASH--RECORD:MAKE ;

\ A stored row with a device and its JSON are JOURNAL's and MODEL's;
\ here the hash the first scan published, its content replaced by one
\ only the cache could supply, is reused.
: CACHED-HASH-WITH-A-STORED-DEVICE-IS-REUSED ( -- )
   s" cached_hash_with_a_stored_device_is_reused" T-LABEL
   s" kept.txt" s" actual bytes" WRITE
   NO-CUTOFF [: STABLE ;] CACHED-SCAN drop REUSABLE {: first :}
   first VEC:COUNT 1 T=
   NO-CACHE {: cache :}
   first 0 VEC:AT @ ZEROED cache VEC:PUSH !
   cache SEED
   STABLE [: STABLE ;] CACHED-SCAN
   s" kept.txt" SCANNED-CONTENT ZEROS T$= ;

: SCAN-PUBLICATION-USES-COMPLETION-CUTOFF-FOR-NEW-HASHES ( -- )
   s" scan_publication_uses_completion_cutoff_for_new_hashes" T-LABEL
   s" slow.txt" s" newly hashed" WRITE
   NO-CUTOFF [: STABLE ;] CACHED-SCAN drop REUSABLE VEC:COUNT 1 T= ;

: EXCLUDED-TREE ( -- )
   s" kept.txt" s" kept" WRITE
   s" .DS_Store" s" Finder metadata" WRITE
   s" ~$private" MKDIR
   s" ~$private/child.txt" s" private" WRITE
   s" missing" s" .dropbox" AT FS:MAKE-SYMLINK ;

: EXCLUDED-ENTRIES-ARE-NOT-OPENED-HASHED-OR-PUBLISHED ( -- )
   s" excluded_entries_are_not_opened_hashed_or_published" T-LABEL
   EXCLUDED-TREE
   s" ~$private" DENY
   [: STABLE [: STABLE ;] CACHED-SCAN ;]
   [: s" ~$private" ALLOW ;] finally {: s :}
   s PUBLISHED 1 T=
   s s" kept.txt" PRESENT SEEN
   REUSABLE VEC:COUNT 1 T=
   s" .DS_Store" CONTENT-OF s" Finder metadata" T$=
   s" ~$private/child.txt" CONTENT-OF s" private" T$=
   s" .dropbox" LINK-OF s" missing" T$= ;

\ The second scan reuses the cache the first published.
: LINKED-OUTSIDE ( -- )
   s" kept.txt" s" kept" WRITE
   STABLE [: STABLE ;] CACHED-SCAN drop REUSABLE {: cache :}
   cache VEC:COUNT 1 T=
   OUTSIDE$ s" unsupported-link" AT FS:MAKE-SYMLINK
   STABLE [: STABLE ;] CACHED-SCAN {: s :}
   s s" unsupported-link" UNSUPPORTED-KIND SEEN
   s s" kept.txt" PRESENT SEEN
   s PUBLISHED 2 T=
   REUSABLE VEC:COUNT 1 T= ;

: SYMLINK-IS-PUBLISHED-AS-UNSUPPORTED-BESIDE-A-SYNCHRONIZED-FILE ( -- )
   s" symlink_is_published_as_unsupported_beside_a_synchronized_file"
   T-LABEL
   [: LINKED-OUTSIDE ;] BESIDE-OUTSIDE ;

: SPECIAL-ENTRIES-ARE-PUBLISHED-AS-UNSUPPORTED ( -- )
   s" special_entries_are_published_as_unsupported" T-LABEL
   s" regular.txt" s" regular" WRITE
   s" regular.txt" TARGET-AT s" link" AT FS:MAKE-SYMLINK
   s" fifo" AT FS:>PATHZ MODE-0600 MKFIFO-CALL 0 T=
   s" socket" AT TEST-CLIENT:SOCKET-AT {: sock:fd :}
   [: ROOT-SCAN ;] [: sock DISCARD ;] finally {: s :}
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
   ROOT-SCAN {: s :}
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
   s" local path `locked.txt` is a file Omabox cannot read" STR:CONTAINS?
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

\ "earlier" is walked before "locked", whose unreadable subtree must
\ not hide a sibling already walked.
: INACCESSIBLE-DIRECTORY-PUBLISHES-NOTHING-BENEATH-ITSELF ( -- )
   s" inaccessible_directory_publishes_nothing_beneath_itself" T-LABEL
   s" earlier" MKDIR
   s" earlier/inner.txt" s" inner" WRITE
   s" locked" MKDIR
   s" locked/secret.txt" s" secret" WRITE
   s" open.txt" s" open" WRITE
   s" locked" DENY
   [: ROOT-SCAN ;] [: s" locked" ALLOW ;] finally {: s :}
   s s" locked" INACCESSIBLE SEEN
   s s" locked/secret.txt" MISSING SEEN
   s s" earlier" DIRECTORY SEEN
   s s" earlier/inner.txt" PRESENT SEEN
   s s" open.txt" PRESENT SEEN
   s PUBLISHED 4 T= ;

\ Linux asm-generic errnos FS does not name.
5 constant EIO
6 constant ENXIO
19 constant ENODEV
110 constant ETIMEDOUT

variable RAISED-CODE
variable RAISED-ERRNO

\ The log holds lines lines: none for a failure its catcher converts, one
\ for one it rethrows.
: LOGGED ( str n -- )
   {: p:str lines:n :}
   lines 0= if p str> nip 0 T= exit then
   p 10 STR:COUNT-CHAR lines T= ;

\ What q throws under the scan's predicate, LOCAL's log of it holding
\ lines lines; FS:ERRNO is q's again after the log's file calls.
: ENTRY-RAISES ( [ -- ] n -- n )
   {: q lines:n :}
   [: q ['] ENTRY-CODE? CONVERTING RAISED-CODE !
      FS:ERRNO RAISED-ERRNO ! ;] STDERR-OF
   lines LOGGED
   RAISED-ERRNO @ FS:CAUSE! RAISED-CODE @ ;

\ What a failure with the errno, raised against one entry, throws.
: RAISED ( n n -- n )
   {: e:n lines:n :}
   [: e s" observe scanned entry" s" subject.txt" SYSCALL-FAILURE ;]
   lines ENTRY-RAISES ;

: WALK-KIND ( n -- n ) WALK-UNKNOWN REASON-KIND ;

: ESCAPES ( n n -- )
   {: e:n want:n :}
   e 1 RAISED {: code:n :}
   [: code WALK-KIND drop ;] want TTHROWSQ ;

: READS-AS ( n n -- )
   {: e:n want:n :}
   e 0 RAISED WALK-KIND want T= ;

\ A reason carries no path: the caller holds the one it observed.
: ONLY-EXHAUSTION-ESCAPES-A-FAILURE-RAISED-AGAINST-ONE-ENTRY ( -- )
   s" only_exhaustion_escapes_a_failure_raised_against_one_entry" T-LABEL
   FS:EMFILE E-IO ESCAPES FS:ENFILE E-IO ESCAPES
   FS:ENOMEM E-IO ESCAPES FS:ENOSPC E-DISK-FULL ESCAPES
   FS:ENOENT INCOMPLETE READS-AS FS:ENOTDIR INCOMPLETE READS-AS
   FS:ELOOP INCOMPLETE READS-AS FS:ESTALE INCOMPLETE READS-AS
   \ Anticipated or not, an errno raised against one object concerns that
   \ object: the default is an unknown path, never a scan that stops.
   FS:EACCES INACCESSIBLE READS-AS FS:EPERM INACCESSIBLE READS-AS
   EIO INACCESSIBLE READS-AS ENXIO INACCESSIBLE READS-AS
   ETIMEDOUT INACCESSIBLE READS-AS ENODEV INACCESSIBLE READS-AS
   \ The walk meets an object it cannot synchronize; the hash stage
   \ already saw a regular file, so a different type there is a change.
   [: s" subject.txt" E-UNSUPPORTED UNSUPPORTED-FAILS ;] 0 ENTRY-RAISES
   {: odd:n :}
   odd WALK-KIND UNSUPPORTED-KIND T=
   odd REVISITED-UNKNOWN REASON-KIND INCOMPLETE T=
   \ A failure that is not about an object still stops the scan.
   [: s" subject.txt" UNSAFE ;] 1 ENTRY-RAISES {: bad:n :}
   [: bad WALK-KIND drop ;] E-UNSAFE-PATH TTHROWSQ ;

\ ---- denied writes

488 constant MODE-0750
416 constant MODE-0640
320 constant MODE-0500
192 constant MODE-0300

\ SB holds the clause of kind k for the name p, through its mode's label.
: CLAUSE ( str str -- )
   {: k:str p:str :}
   SB-RESET k SB-APPEND s"  `" SB-APPEND p SB-APPEND
   s" ` mode " SB-APPEND ;

: DIRECTORY? ( str str -- bool )
   {: e:str p:str :}
   s" ; directory" p CLAUSE e SB$ STR:CONTAINS? ;

\ Where the directory clause for the name p starts in the log, -1 when
\ it holds none.
: CLAUSE-AT ( str str -- n )
   {: e:str p:str :}
   s" ; directory" p CLAUSE e SB$ STR:FIND-SUB MATCH option
      none OF -1 ENDOF
      some OF IDX>N ENDOF
   ;MATCH ;

\ Whether the log holds the clause, the mode m, and Omabox's uid as owner.
: OWNED? ( str str str str -- bool )
   {: e:str k:str p:str m:str :}
   k p CLAUSE m SB-APPEND
   s"  owner uid " SB-APPEND FS:EUID FMT:INT$ SB-APPEND
   e SB$ STR:CONTAINS? ;

: RUNS-AS? ( str -- bool )
   {: e:str :}
   SB-RESET s" ; Omabox runs as uid " SB-APPEND
   FS:EUID FMT:INT$ SB-APPEND 10 SB-APPEND-C
   e SB$ STR:CONTAINS? ;

\ EPERM raised against a file: the one line gives the facts of the file
\ and of its directory, and FS:ERRNO keeps EPERM.
: DENIED-WRITE-GIVES-ITS-DIRECTORY-AND-ENTRY ( -- )
   s" denied_write_gives_its_directory_and_entry" T-LABEL
   ROOT-USER? if exit then
   s" denied" MKDIR s" denied/file.txt" s" held" WRITE
   s" denied/file.txt" AT MODE-0640 FS:CHMOD-MODE
   s" denied" AT MODE-0750 FS:CHMOD-MODE
   s" denied" AT FS:OPEN-DIR {: dir:fd :}
   [: [: FS:EPERM FS:CAUSE! dir s" file.txt" s" write test file"
         s" denied/file.txt" IO-FAILURE-AT ;] E-IO TTHROWSQ
      FS:ERRNO CAUGHT ! ;] STDERR-OF {: e:str :}
   dir DISCARD
   CAUGHT @ FS:EPERM T=
   e 1 LOGGED
   e s" : Operation not permitted;" STR:CONTAINS? TTRUE
   e s" ; directory" s" denied" AT s" 0750" OWNED? TTRUE
   e s" ; entry" s" file.txt" s" 0640" OWNED? TTRUE
   e RUNS-AS? TTRUE ;

: RENAME-DENIED ( fd fd -- )
   {: from:fd to:fd :}
   FS:EACCES FS:CAUSE! from s" file.txt" to s" file.txt"
   s" rename test file" s" from/file.txt" IO-FAILURE-ACROSS ;

\ EACCES raised for a rename: the one line names both directories.
: DENIED-RENAME-GIVES-BOTH-DIRECTORIES ( -- )
   s" denied_rename_gives_both_directories" T-LABEL
   ROOT-USER? if exit then
   s" from" MKDIR s" to" MKDIR s" from/file.txt" s" held" WRITE
   s" from" AT FS:OPEN-DIR {: from:fd :}
   s" to" AT FS:OPEN-DIR {: to:fd :}
   [: [: from to RENAME-DENIED ;] E-IO TTHROWSQ
      FS:ERRNO CAUGHT ! ;] STDERR-OF {: e:str :}
   from DISCARD to DISCARD
   CAUGHT @ FS:EACCES T=
   e 1 LOGGED
   e s" : Permission denied;" STR:CONTAINS? TTRUE
   e s" from" AT DIRECTORY? TTRUE
   e s" to" AT DIRECTORY? TTRUE
   s" ; entry" s" file.txt" CLAUSE e SB$ STR:CONTAINS? TTRUE
   e s" from" AT CLAUSE-AT e s" to" AT CLAUSE-AT < TTRUE
   e RUNS-AS? TTRUE ;

\ The descriptor closes inside the capture, so no open there takes its
\ number: statx logs its own line, then LOCAL's has no path or facts.
: DENIED-WRITE-ON-A-CLOSED-DIRECTORY ( -- )
   s" denied_write_on_a_closed_directory" T-LABEL
   ROOT-USER? if exit then
   s" closed" MKDIR
   s" closed" AT FS:OPEN-DIR {: dir:fd :}
   [: [: dir DISCARD FS:EACCES FS:CAUSE! dir s" file.txt"
         s" write test file" s" closed/file.txt" IO-FAILURE-AT ;]
      E-IO TTHROWSQ FS:ERRNO CAUGHT ! ;] STDERR-OF {: e:str :}
   CAUGHT @ FS:EACCES T=
   e 2 LOGGED
   e 10 0 STR:SPLIT-NEXT {: a:str next:n ok:bool :}
   a s" fs-statx: " STR:CONTAINS? TTRUE
   e 10 next STR:SPLIT-NEXT {: b:str end:n more:bool :}
   b s" local: " STR:CONTAINS? TTRUE
   b s" : Permission denied; directory; Omabox runs as uid "
   STR:CONTAINS? TTRUE ;

\ The errno is read before ro is writable again.
: CREATE-DIRECTORY-DENIED-GIVES-ITS-DIRECTORY ( -- )
   s" create_directory_denied_gives_its_directory" T-LABEL
   ROOT-USER? if exit then
   s" root" MKDIR s" root/ro" MKDIR
   s" root/ro" AT MODE-0500 FS:CHMOD-MODE
   s" root" AT FS:OPEN-DIR {: root:fd :}
   [: [: [: root s" ro/new" CREATE-DIRECTORY-AT drop ;]
         [: FS:ERRNO CAUGHT ! s" root/ro" ALLOW ;] finally
      ;] E-IO TTHROWSQ ;] STDERR-OF {: e:str :}
   root DISCARD
   CAUGHT @ FS:EACCES T=
   e 1 LOGGED
   e s" ; directory" s" root/ro" AT s" 0500" OWNED? TTRUE
   e s" ; entry" STR:CONTAINS? TFALSE
   e RUNS-AS? TTRUE ;

\ held exists but cannot be opened to read; root's mode is set, not left
\ to the umask, and the errno is read before held is readable again.
: EXISTING-DIRECTORY-DENIED-GIVES-ITS-ENTRY ( -- )
   s" existing_directory_denied_gives_its_entry" T-LABEL
   ROOT-USER? if exit then
   s" root" MKDIR s" root/held" MKDIR
   s" root" AT MODE-0700 FS:CHMOD-MODE
   s" root/held" AT MODE-0300 FS:CHMOD-MODE
   s" root" AT FS:OPEN-DIR {: root:fd :}
   [: [: [: root s" held" CREATE-DIRECTORY-AT drop ;]
         [: FS:ERRNO CAUGHT ! s" root/held" ALLOW ;] finally
      ;] E-IO TTHROWSQ ;] STDERR-OF {: e:str :}
   root DISCARD
   CAUGHT @ FS:EACCES T=
   e 1 LOGGED
   e s" ; directory" s" root" AT s" 0700" OWNED? TTRUE
   e s" ; entry" s" held" s" 0300" OWNED? TTRUE
   e RUNS-AS? TTRUE ;

\ A denial the scan converts into an entry's outcome logs no line.
: CONVERTED-DENIAL-LOGS-NOTHING ( -- )
   s" converted_denial_logs_nothing" T-LABEL
   ROOT$ FS:OPEN-DIR {: dir:fd :}
   [: FS:EACCES FS:CAUSE! dir s" file.txt" s" write test file"
      s" file.txt" IO-FAILURE-AT ;] 0 ENTRY-RAISES {: code:n :}
   FS:ERRNO FS:EACCES T=
   dir DISCARD
   code E-IO T= ;

\ Immutable and append-only need privilege to set, so the facts are made.
: ATTRIBUTES-ARE-LABELLED ( -- )
   s" attributes_are_labelled" T-LABEL
   [: LOG-OPEN MODE-0640 0 FS-STATX:IMMUTABLE FS-STATX:APPEND or
      FACTS-MAKE OPTION:SOME FACTS+ LOG:;LINE ;] STDERR-OF
   {: e:str :}
   e s"  mode 0640 owner uid 0 immutable append-only" STR:CONTAINS? TTRUE ;

\ ---- publication

: STAND-IN$ ( -- str ) s" /sys/class/mem" ;

\ Activates the directory at the name below the case's root.
: ACTIVATE ( JOURNAL:journal str -- )
   {: j p:str :}
   p AT AR @ KEEP JOURNAL:INSPECT {: b :}
   j b AR @ JOURNAL:ACTIVATE-LOCAL-ROOT drop ;

: NO-SUBVOLUME ( -- option<n> ) OPTION:NONE ;

\ The root /sys/class/mem stands in for.
: STAND-IN-ROOT ( -- JOURNAL:local-root-binding )
   STAND-IN$ 1
   1700000000 5 JOURNAL-BIRTH--TIME:MAKE OPTION:SOME NO-SUBVOLUME
   JOURNAL-LOCAL--ROOT--BINDING:MAKE ;

: NO-ROOT? ( option<fd> -- bool )
   MATCH option
      none OF true ENDOF
      some OF DISCARD false ENDOF
   ;MATCH ;

: REFUSED-STAND-IN ( -- )
   [: STAND-IN$ JOURNAL:INSPECT drop ;]
   JOURNAL:E-NO-BIRTH-TIME TTHROWSQ ;

\ Nothing logged: JOURNAL decides the stand-in before it refuses.
: STAND-IN-PUBLISHES-NOTHING ( JOURNAL:journal -- )
   {: j :}
   j STAND-IN-ROOT AR @ JOURNAL:ACTIVATE-LOCAL-ROOT drop
   j AR @ JOURNAL:LOCAL-INVENTORY {: before :}
   [: j STAND-IN$ AR @ SCAN-AND-PUBLISH ROOT-CHANGED? TTRUE
      j STAND-IN$ OPEN-ACTIVE-ROOT NO-ROOT? TTRUE ;] STDERR-OF
   str> nip 0 T=
   j AR @ JOURNAL:LOCAL-INVENTORY before JOURNAL:LOCAL-RECORDS= TTRUE ;

: SCAN-OF-A-STAND-IN-PUBLISHES-NOTHING ( -- )
   s" scan_of_a_stand_in_publishes_nothing" T-LABEL
   [: REFUSED-STAND-IN ;] STDERR-OF
   s" does not record creation times" STR:CONTAINS? TTRUE
   [: STAND-IN-PUBLISHES-NOTHING ;] WITH-JOURNAL ;

\ Rust's scan_and_publish_at with all_cache_entries_stable completing.
: PUBLISH-STABLE ( JOURNAL:journal str option<MODEL:cutoff> -- )
   {: j p:str cut:option<MODEL:cutoff> :}
   j p AT AR @ KEEP cut [: STABLE ;] AR @ SCAN-AND-PUBLISH-AT
   ROOT-CHANGED? TFALSE ;

: REPUBLISHES-NOTHING ( JOURNAL:journal -- )
   {: j :}
   j s" root" ACTIVATE
   j s" root" NO-CUTOFF PUBLISH-STABLE
   j JOURNAL:CHANGE-COUNTER {: before :}
   j s" root" NO-CUTOFF PUBLISH-STABLE
   j JOURNAL:CHANGE-COUNTER before T= ;

: UNCHANGED-TREE-BESIDE-A-SAME-NAMED-DIRECTORY-REPUBLISHES-NOTHING
   ( -- )
   s" unchanged_tree_beside_a_same_named_directory_republishes_nothing"
   T-LABEL
   s" root" MKDIR s" root/x" MKDIR
   s" root/x.txt" s" beside the directory" WRITE
   s" root/x/y.txt" s" under the directory" WRITE
   [: REPUBLISHES-NOTHING ;] WITH-JOURNAL ;

: CACHE-COUNT ( JOURNAL:journal -- n )
   AR @ JOURNAL:LOCAL-HASH-CACHE VEC:COUNT ;

: CLEARS-THE-HASH-CACHE ( JOURNAL:journal -- )
   {: j :}
   j s" first" ACTIVATE
   j s" first" STABLE PUBLISH-STABLE
   j CACHE-COUNT 1 T=
   j s" second" ACTIVATE
   j AR @ JOURNAL:LOCAL-INVENTORY VEC:COUNT 0 T=
   j CACHE-COUNT 0 T= ;

: SWITCHING-LOCAL-ROOT-CLEARS-THE-HASH-CACHE ( -- )
   s" switching_local_root_clears_the_hash_cache" T-LABEL
   s" first" MKDIR s" second" MKDIR
   s" first/cached.txt" s" cached" WRITE
   [: CLEARS-THE-HASH-CACHE ;] WITH-JOURNAL ;

: OPENS-ONLY-THE-ACTIVE-ROOT ( JOURNAL:journal -- )
   {: j :}
   j s" first" ACTIVATE
   j s" second" AT OPEN-ACTIVE-ROOT NO-ROOT? TTRUE
   j s" first" AT OPEN-ACTIVE-ROOT NO-ROOT? TFALSE ;

: ONLY-THE-ACTIVE-ROOT-OPENS ( -- )
   s" only the active root opens" T-LABEL
   s" first" MKDIR s" second" MKDIR
   [: OPENS-ONLY-THE-ACTIVE-ROOT ;] WITH-JOURNAL ;

\ ---- the watch

: FORMAL-HOLDS-THE-WATCH-TABLE ( -- )
   s" formal_holds_the_watch_table" T-LABEL
   s" src/local.f" s" WATCHING" s" LocalWatch" AR @
   TEST-FORMAL:HOLDS ;

: STATE$ ( ^watch -- str )
   WATCH-STATE @ MATCH watch-state
      blind OF s" blind" ENDOF
      arming OF s" arming" ENDOF
      armed OF s" armed" ENDOF
   ;MATCH ;

: FD-SOME? ( option<fd> -- bool )
   MATCH option
      none OF false ENDOF
      some OF drop true ENDOF
   ;MATCH ;

\ The wd, -1 for none.
: WD-OF ( option<n> -- n )
   MATCH option
      none OF -1 ENDOF
      some OF ENDOF
   ;MATCH ;

\ The first stirred folder's path; "-" for none.
: STIRRED$ ( JOURNAL:journal -- str )
   AR @ JOURNAL:NEXT-STIRRED MATCH option
      none OF s" -" ENDOF
      some OF JOURNAL-STIRRED:UNMAKE {: wd:n p:str :} p ENDOF
   ;MATCH ;

\ Folder p's watch added, recorded and listed, as a scan's walk does.
: ADD-LISTED ( JOURNAL:journal ^watch str -- n )
   {: j w p:str :}
   p STR:LEN 0= if ROOT$ else p AT then
   s" open watched folder" OPEN-ROOT {: f:fd :}
   w f p WATCH-ADD WD-OF {: wd:n :}
   f DISCARD  wd 0 >= TTRUE
   j wd p JOURNAL:WATCH-RECORD  j wd JOURNAL:WATCH-LISTED  wd ;

\ A full scan of the root alone, published.
: REARMED ( JOURNAL:journal ^watch -- )
   {: j w :}
   j w WATCH-STARTED TFALSE
   j w s" " ADD-LISTED drop  j w WATCH-PUBLISHED
   w WATCH-FD FD-SOME? TTRUE ;

FS:PATHZ-CAP BUFFER: MOVED-BUF

\ The case's root with ".moved" after it.
: MOVED$ ( -- str )
   ROOT$ {: r:str :}  s" .moved" {: x:str :}
   r STR:DATA MOVED-BUF r STR:LEN BYTE-COPY
   x STR:DATA MOVED-BUF r STR:LEN + x STR:LEN BYTE-COPY
   MOVED-BUF r STR:LEN x STR:LEN + >str ;

\ A new watch arms through a full scan of the root and a; a write in a
\ stirs a; a removed, its record goes and the root is stirred.
: HEARS ( JOURNAL:journal ^watch -- )
   {: j w :}
   j w WATCH-STARTED TFALSE  w STATE$ s" arming" T$=
   j w s" " ADD-LISTED {: rwd:n :}
   j w s" a" ADD-LISTED {: awd:n :}
   j w WATCH-PUBLISHED  w WATCH-FD FD-SOME? TTRUE
   s" a/f.txt" s" bytes" WRITE
   j w WATCH-HEAR 1 >= TTRUE  j STIRRED$ s" a" T$=
   j awd JOURNAL:WATCH-LISTED
   s" a/f.txt" REMOVE  s" a" AT FS:REMOVE-DIR
   j w WATCH-HEAR 1 >= TTRUE  j STIRRED$ s" " T$=
   j rwd JOURNAL:WATCH-LISTED  j awd JOURNAL:WATCH-STIR
   j STIRRED$ s" -" T$= ;

\ The root moved away blinds the watch; it is moved back.
: MOVES-ROOT ( JOURNAL:journal ^watch -- )
   {: j w :}
   ROOT$ MOVED$ FS:RENAME-FILE
   j w WATCH-HEAR 1 >= TTRUE  w WATCH-FD FD-SOME? TFALSE
   MOVED$ ROOT$ FS:RENAME-FILE ;

: DOUBTS ( JOURNAL:journal ^watch -- )
   {: j w :}
   j w REARMED  j w WATCH-DOUBT  w WATCH-FD FD-SOME? TFALSE ;

\ An armed watch's scan is incremental until its full scan's listings
\ stand SCAN-STANDS-S; then a new instance arms through a full one.
: RESTARTS ( JOURNAL:journal ^watch -- )
   {: j w :}
   j w REARMED  j w WATCH-STARTED TTRUE  w STATE$ s" armed" T$=
   w WATCH-STAMP @ SCAN-STANDS-S - w WATCH-STAMP !
   j w WATCH-STARTED TFALSE  w STATE$ s" arming" T$=
   w WATCH-INSTANCE @ FD-SOME? TTRUE
   j w WATCH-ABANDONED  w WATCH-INSTANCE @ FD-SOME? TFALSE ;

: WATCHED ( JOURNAL:journal -- )
   {: j :}
   AR @ NEW-WATCH {: w :}
   j w HEARS  j w MOVES-ROOT  j w DOUBTS  j w RESTARTS ;

: A-WATCH-HEARS-ITS-FOLDERS-AND-BLINDS-ON-A-LOSS ( -- )
   s" a_watch_hears_its_folders_and_blinds_on_a_loss" T-LABEL
   s" a" MKDIR
   [: WATCHED ;] WITH-JOURNAL ;

\ No descriptor, which inotify refuses to watch.
: NO-DESCRIPTOR ( -- fd ) -1 >FD ;

\ Folder a's watch, refused: none.
: REFUSED-ADD ( ^watch -- )
   NO-DESCRIPTOR s" a" WATCH-ADD WD-OF -1 T= ;

\ How many refusals a log holds.
: REFUSALS ( str -- n ) s" inotify refused" STR:COUNT-SUB ;

\ An armed watch refused logs it and blinds; arming, it is refused with
\ the same errno, logged already.
: REFUSED-TWICE ( JOURNAL:journal ^watch -- )
   {: j w :}
   j w REARMED  w REFUSED-ADD  w WATCH-FD FD-SOME? TFALSE
   j w WATCH-STARTED TFALSE  w STATE$ s" arming" T$=
   w REFUSED-ADD  w STATE$ s" blind" T$= ;

\ Armed anew and refused with the same errno, it logs again.
: REFUSED-AFTER-ARMING ( JOURNAL:journal ^watch -- )
   {: j w :}
   j w REARMED  w REFUSED-ADD  w WATCH-FD FD-SOME? TFALSE ;

: REFUSALS-LOGGED ( JOURNAL:journal -- )
   {: j :}
   AR @ NEW-WATCH {: w :}
   [: j w REFUSED-TWICE ;] STDERR-OF REFUSALS 1 T=
   [: j w REFUSED-AFTER-ARMING ;] STDERR-OF REFUSALS 1 T= ;

: A-REFUSED-WATCH-LOGS-ONCE-PER-ARMING ( -- )
   s" a_refused_watch_logs_once_per_arming" T-LABEL
   [: REFUSALS-LOGGED ;] WITH-JOURNAL ;

: CASES ( -- )
   [: SCAN-PUBLISHES-EMPTY-AND-NESTED-DIRECTORIES ;] IN-SCAN-CASE
   [: FILE-LOCKED-AFTER-ENUMERATION-IS-INACCESSIBLE ;] IN-SCAN-CASE
   [: NEW-FILE-REMOVED-BEFORE-HASHING-IS-INCOMPLETE ;] IN-SCAN-CASE
   [: STORED-FILE-CHANGED-THEN-REMOVED-BEFORE-HASHING-IS-INCOMPLETE ;]
   IN-SCAN-CASE
   [: CACHED-FILE-REMOVED-AFTER-THE-WALK-STAYS-UNTIL-THE-NEXT-SCAN ;]
   IN-SCAN-CASE
   [: FILE-REPLACED-BY-A-SYMLINK-BEFORE-HASHING-IS-INCOMPLETE ;]
   IN-SCAN-CASE
   [: STORED-ROWS-BENEATH-DENIED-DIRECTORIES-KEEP-THEIR-HASHES ;]
   IN-SCAN-CASE
   [: A-DIRECTORY-GROWN-SINCE-ITS-STAT-HAS-CHANGED ;] IN-SCAN-CASE
   [: A-DIRECTORY-OF-ANOTHER-INODE-IS-NOT-HELD ;] IN-SCAN-CASE
   [: A-DIRECTORY-NOW-A-SYMLINK-IS-NEVER-LISTED ;] IN-SCAN-CASE
   [: A-DIRECTORY-REPLACED-BEFORE-ITS-OPEN-IS-INCOMPLETE ;] IN-SCAN-CASE
   [: OBJECTS-ON-ANOTHER-DEVICE-ARE-UNSUPPORTED-AND-UNSCANNED ;]
   IN-SCAN-CASE
   [: CHANGING-FILES-ARE-UNKNOWN-WITHOUT-HIDING-STABLE-FILES ;]
   IN-SCAN-CASE
   [: UNCHANGED-SCAN-FILE-REUSES-CACHED-HASH-WITHOUT-READING-BYTES ;]
   IN-SCAN-CASE
   [: FILE-BESIDE-A-SAME-NAMED-DIRECTORY-KEEPS-ITS-CACHED-HASH ;]
   IN-SCAN-CASE
   [: THE-WALK-FOLLOWS-PATH-BYTE-ORDER ;] IN-SCAN-CASE
   [: AN-UNCHANGED-TREE-STAGES-AND-WRITES-NOTHING ;] IN-SCAN-CASE
   [: A-FAILED-WALK-LEAVES-NO-DESCRIPTOR-OPEN ;] IN-SCAN-CASE
   [: RECENT-CACHE-ENTRY-IS-REHASHED-AND-OMITTED ;] IN-SCAN-CASE
   [: EVERY-FINGERPRINT-FIELD-MISMATCH-REHASHES-THE-FILE ;] IN-SCAN-CASE
   [: CACHED-HASH-WITH-A-STORED-DEVICE-IS-REUSED ;] IN-SCAN-CASE
   [: SCAN-PUBLICATION-USES-COMPLETION-CUTOFF-FOR-NEW-HASHES ;]
   IN-SCAN-CASE
   [: EXCLUDED-ENTRIES-ARE-NOT-OPENED-HASHED-OR-PUBLISHED ;]
   IN-SCAN-CASE
   [: SYMLINK-IS-PUBLISHED-AS-UNSUPPORTED-BESIDE-A-SYNCHRONIZED-FILE ;]
   IN-SCAN-CASE
   [: SPECIAL-ENTRIES-ARE-PUBLISHED-AS-UNSUPPORTED ;] IN-SCAN-CASE
   [: INACCESSIBLE-FILE-IS-UNKNOWN-BESIDE-A-READABLE-FILE ;]
   IN-SCAN-CASE
   [: UNREADABLE-REGULAR-FILE-IS-REPORTED-AS-UNREADABLE ;] IN-CASE
   [: UNSEARCHABLE-PARENT-IS-AN-IO-FAILURE ;] IN-CASE
   [: INACCESSIBLE-DIRECTORY-PUBLISHES-NOTHING-BENEATH-ITSELF ;]
   IN-SCAN-CASE
   [: SCAN-OF-A-STAND-IN-PUBLISHES-NOTHING ;] IN-CASE
   [: UNCHANGED-TREE-BESIDE-A-SAME-NAMED-DIRECTORY-REPUBLISHES-NOTHING ;]
   IN-CASE
   [: SWITCHING-LOCAL-ROOT-CLEARS-THE-HASH-CACHE ;] IN-CASE
   [: ONLY-THE-ACTIVE-ROOT-OPENS ;] IN-CASE
   [: ONLY-EXHAUSTION-ESCAPES-A-FAILURE-RAISED-AGAINST-ONE-ENTRY ;]
   IN-CASE
   [: DENIED-WRITE-GIVES-ITS-DIRECTORY-AND-ENTRY ;] IN-CASE
   [: DENIED-RENAME-GIVES-BOTH-DIRECTORIES ;] IN-CASE
   [: DENIED-WRITE-ON-A-CLOSED-DIRECTORY ;] IN-CASE
   [: CREATE-DIRECTORY-DENIED-GIVES-ITS-DIRECTORY ;] IN-CASE
   [: EXISTING-DIRECTORY-DENIED-GIVES-ITS-ENTRY ;] IN-CASE
   [: CONVERTED-DENIAL-LOGS-NOTHING ;] IN-CASE
   [: ATTRIBUTES-ARE-LABELLED ;] IN-CASE
   FORMAL-HOLDS-THE-WATCH-TABLE
   [: A-WATCH-HEARS-ITS-FOLDERS-AND-BLINDS-ON-A-LOSS ;] IN-CASE
   [: A-REFUSED-WATCH-LOGS-ONCE-PER-ARMING ;] IN-CASE ;

public

: SCAN-CASES ( ^ARENA:arena -- ) AR ! CASES ;

;package
public
EXPORT SCAN-TEST:SCAN-CASES
EXPORT SCAN-TEST:ROOT-USER?
EXPORT SCAN-TEST:OWNED?
EXPORT SCAN-TEST:RUNS-AS?
EXPORT SCAN-TEST:CLAUSE-AT
EXPORT SCAN-TEST:LOGGED
EXPORT SCAN-TEST:MODE-0500
EXPORT SCAN-TEST:CAUGHT
EXPORT SCAN-TEST:ENTRY-COUNT
EXPORT SCAN-TEST:FD-COUNT
;package

package LOCAL-TEST
private

TYPED-VARIABLE AR ^ARENA:arena

448 constant MODE-0700

\ ---- entry existence

FS:PATHZ-CAP BUFFER: ROOT-BUF
variable ROOT-U
FS:PATHZ-CAP BUFFER: JOINED

: ROOT$ ( -- str ) ROOT-BUF ROOT-U @ >str ;

\ The name below the case's directory, valid until the next AT.
: AT ( str -- str )
   {: p:str :}
   ROOT$ p JOINED FS:JOIN-PATH JOINED swap >str ;

: CASE-DIR ( -- )
   s" local-test" FS:MKTEMP-DIR str> {: p:^ u:n :}
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

: EXISTS ( fd str bool -- )
   {: root:fd p:str want:bool :}
   p T-LABEL
   root p LOCAL:ENTRY-EXISTS-AT want if TTRUE else TFALSE then ;

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
: IDENTITY ( str -- str )
   {: p:str :}
   FD:PIPE {: r:fd w:fd :}
   w p FD:WRITE-FULL w FS:CLOSE-DIR
   r AR @ LOCAL:DROPBOX-CONTENT-HASH r FS:CLOSE-DIR
   DROPBOX:HASH>STR ;

: DROPBOX-HASH-USES-BLOCK-HASH-COMPOSITION ( -- )
   s" dropbox_hash_uses_block_hash_composition" T-LABEL
   s" " IDENTITY
   s" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" T$=
   s" abc" IDENTITY
   s" 4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358" T$= ;

\ A pipe's write end cannot be read.
: UNREADABLE-HASH-INPUT-FAILS ( -- )
   s" unreadable hash input fails" T-LABEL
   FD:PIPE {: r:fd w:fd :}
   [: [: w AR @ LOCAL:DROPBOX-CONTENT-HASH DROPBOX:HASH>STR drop ;]
      LOCAL:E-HASH-READ TTHROWSQ ;]
   [: r FS:CLOSE-DIR w FS:CLOSE-DIR ;] finally ;

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

: START ( str -- )
   str> {: p:^ u:n :}
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
: REFERENCE ( str -- str )
   str> {: a:^ u:n :}
   WHOLE SHA256-BEGIN
   0 begin dup u < while
      {: at:n :}
      u at - DROPBOX:BLOCK min {: k:n :}
      PART a at + k >str DIGEST SHA256-IN
      WHOLE DIGEST 32 >str SHA256-FEED
      at k +
   repeat drop
   WHOLE DIGEST SHA256-END DIGEST HEX SHA256>HEX
   HEX 64 >str ;

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
: COPY ( fd -- str fd )
   {: dir:fd :}
   dir FS:TEMP-AT {: f:fd :}
   [: FRAGMENT ;] f s" fragmented-download"
   s" test fragmented download copy" AR @ LOCAL:COPY-AND-HASH
   DROPBOX:HASH>STR f ;

\ The file's bytes from its start fill back, and nothing follows them.
: READ-BACK ( fd ^u8 n -- )
   {: f:fd back:^ u:n :}
   f 0 FD:SEEK
   f back u SPAN:MAKE FD:READ-EXACT FULL? TTRUE
   f ONE 1 SPAN:MAKE FD:READ-EXACT FULL? TFALSE ;

\ The bytes copied hash as want and read back as they were.
: COPIED ( str str fd ^u8 -- )
   {: bytes:str want:str dir:fd back:^ :}
   bytes str> nip {: u:n :}
   bytes START
   dir COPY {: c:str f:fd :}
   [: c want T$= f back u READ-BACK bytes back u >str STR:= TTRUE ;]
   [: f FS:CLOSE-DIR ;] finally ;

\ Case i takes length arm i mod 9 and schedule arm i mod 3.
: FRAGMENTED ( ^u8 ^u8 fd n -- )
   {: bytes:^ back:^ dir:fd i:n :}
   i 9 mod LENGTH {: u:n :}
   i 3 mod SCHEDULE
   bytes u 256 PROP:RND% PATTERNED
   bytes u >str REFERENCE {: want:str :}
   bytes u >str START
   [: FRAGMENT ;] AR @ LOCAL:HASH-STREAM DROPBOX:HASH>STR
   want T$=
   bytes u >str want dir back COPIED ;

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

: HASH-OF ( str -- DROPBOX:hash ) IDENTITY DROPBOX:>HASH ;
: TARGET ( -- str ) s" target.txt" ;
: WANT ( -- DROPBOX:hash ) s" remote" HASH-OF ;
: MARKER ( -- str ) TARGET WANT AR @ LOCAL:STAGE-MARKER ;

: PUT-FILE ( str str -- )
   {: name:str b:str :}
   name AT b FS:WRITE-ALL ;

: OPEN-AT ( fd str -- fd )
   FS:TRY-OPEN-READ-AT MATCH option
      none OF E-FS-OPEN throw ENDOF
      some OF ENDOF
   ;MATCH ;

: MARK ( fd str -- )
   {: f:fd p:str :}
   f LOCAL:DOWNLOAD-STAGE-XATTR MARKER true p s" test mark"
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

FS:PATHZ-CAP BUFFER: LOG-AT

\ stderr.txt below the case's directory, apart from AT's buffer, which a
\ captured action may reuse.
: LOG-PATH ( -- str )
   ROOT$ s" stderr.txt" LOG-AT FS:JOIN-PATH LOG-AT swap >str ;

\ Marking an attribute that exists throws LOCAL's code with EEXIST, fd 2
\ sent to LOG-PATH, which then holds XATTR's one line and is removed.
: ONE-XATTR-LINE ( fd str -- )
   {: f:fd p:str :}
   [: [: f p MARK ;] LOCAL:E-IO TTHROWSQ FS:ERRNO FS:EEXIST T= ;]
   LOG-PATH AR @ STDERR:CAPTURING {: code:n e:str :}
   code 0<> if code throw then
   e 10 STR:COUNT-CHAR 1 T=
   e s" xattr: fsetxattr" STR:CONTAINS? TTRUE ;

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

: INSPECTED ( fd str str -- )
   {: root:fd p:str want:str :}
   p T-LABEL
   root p p TARGET WANT AR @ LOCAL:INSPECTED$ want T$= ;

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
: OUTCOME$ ( LOCAL:stage-outcome<n> -- str str )
   MATCH LOCAL:stage-outcome
      staged OF drop s" staged" s" " ENDOF
      already-staged OF drop s" already-staged" s" " ENDOF
      content-changed OF {: c:DROPBOX:hash :}
         s" content-changed" c DROPBOX:HASH>STR
      ENDOF
      destination-occupied OF {: p:str :}
         s" destination-occupied" p
      ENDOF
   ;MATCH ;

\ Stages bytes at name, marked as target's owned download of "remote".
: STAGED ( fd str str -- str str )
   {: root:fd name:str b:str :}
   name T-LABEL
   b START 0 SCHEDULE
   root name name WANT [: FRAGMENT ;] MARKER OPTION:SOME
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
: HOLD ( str -- str )
   str> {: p:^ u:n :}
   AR @ u ARENA:ALLOC {: dst:^ size:n :}
   p dst u BYTE-COPY dst u >str ;

: UPLOAD-ROOT ( -- str ) s" root" AT HOLD ;
: STAGING ( -- str ) s" staging" AT HOLD ;

: UPLOAD-DIRS ( -- ) s" root" AT FS:MAKE-DIR s" staging" AT FS:MAKE-DIR ;

\ The stage path of content c, valid until the next AT.
: STAGE-PATH ( DROPBOX:hash -- str )
   {: c:DROPBOX:hash :}
   STAGING c DROPBOX:HASH>STR JOINED FS:JOIN-PATH JOINED swap >str ;

\ The entry's file type bits, 0 when nothing is there.
: KIND ( str -- n )
   FS:TRY-LSTAT 0= if 0 exit then
   FS:STAT-MODE@ FS:S-IFMT and ;

64 BUFFER: CONTENTS-BUF

: CONTENTS ( str -- str )
   CONTENTS-BUF 64 FS:READ-ALL CONTENTS-BUF swap >str ;

\ Stages the file at name below the upload root as content want.
: UPLOAD-STAGE
   ( str DROPBOX:hash -- LOCAL:stage-outcome<^LOCAL:staged-upload> )
   {: name:str want:DROPBOX:hash :}
   UPLOAD-ROOT name STAGING want AR @ LOCAL:STAGE-UPLOAD ;

\ The hash of what the stage's verified descriptor reads.
: VERIFIED$ ( ^LOCAL:staged-upload -- str )
   AR @ LOCAL:OPEN-VERIFIED-UPLOAD {: f:fd :}
   f AR @ LOCAL:DROPBOX-CONTENT-HASH f FS:CLOSE-DIR
   DROPBOX:HASH>STR ;

\ The outcome's variant, and the stage's verified hash, the actual hash
\ or the path.
: UPLOAD-OUTCOME$
   ( LOCAL:stage-outcome<^LOCAL:staged-upload> -- str str )
   MATCH LOCAL:stage-outcome
      staged OF {: rec:^ :} s" staged" rec VERIFIED$ ENDOF
      already-staged OF {: rec:^ :} s" already-staged" rec VERIFIED$
      ENDOF
      content-changed OF {: c:DROPBOX:hash :}
         s" content-changed" c DROPBOX:HASH>STR
      ENDOF
      destination-occupied OF {: p:str :}
         s" destination-occupied" p
      ENDOF
   ;MATCH ;

: SAME-HASH? ( DROPBOX:hash DROPBOX:hash -- bool )
   {: a:DROPBOX:hash b:DROPBOX:hash :}
   a DROPBOX:HASH>STR b DROPBOX:HASH>STR STR:= ;

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
   s" retained" retained UPLOAD-STAGE UPLOAD-OUTCOME$ drop
   s" staged" T$=
   s" orphan" orphan UPLOAD-STAGE UPLOAD-OUTCOME$ drop s" staged" T$=
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
\ converted failure, so no LOCAL line goes to LOG-PATH, which is removed.
: OCCUPIED-QUIETLY ( str DROPBOX:hash -- )
   {: name:str want:DROPBOX:hash :}
   [: name want UPLOAD-STAGE UPLOAD-OUTCOME$ HOLD
      want STAGE-PATH T$= s" destination-occupied" T$= ;]
   LOG-PATH AR @ STDERR:CAPTURING str> nip {: code:n n:n :}
   code 0<> if code throw then
   n 0 T= ;

\ Each outcome STAGE-UPLOAD answers, from one source file.
: UPLOAD-OUTCOME-CASES ( -- )
   UPLOAD-DIRS
   s" root/source" s" source bytes" PUT-FILE
   s" source bytes" HASH-OF {: want:DROPBOX:hash :}
   want DROPBOX:HASH>STR {: w:str :}
   s" staged" T-LABEL
   s" source" want UPLOAD-STAGE UPLOAD-OUTCOME$ w T$= s" staged" T$=
   s" already staged" T-LABEL
   s" source" want UPLOAD-STAGE UPLOAD-OUTCOME$
   w T$= s" already-staged" T$=
   s" content changed" T-LABEL
   s" other bytes" HASH-OF {: other:DROPBOX:hash :}
   s" source" other UPLOAD-STAGE UPLOAD-OUTCOME$
   w T$= s" content-changed" T$=
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
: STAGE-AT ( fd str DROPBOX:hash -- )
   {: root:fd r:str want:DROPBOX:hash :}
   root r STAGING want AR @ LOCAL:STAGE-UPLOAD-AT
   UPLOAD-OUTCOME$ 2drop ;

: OBSERVE-AT ( fd str -- )
   AR @ LOCAL:OBSERVE-UPLOAD-SOURCE-AT DROPBOX:HASH>STR drop ;

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
   p c@ STR:HEX-DIGIT-VALUE 4 lshift p 1+ c@ STR:HEX-DIGIT-VALUE or ;

\ The bytes the hex digits spell, valid until the next.
: UNHEX ( str -- str )
   str> {: h:^ hu:n :}
   hu 2 / 0 ?do h i 2 * + HEX-BYTE UNHEXED i + c! loop
   UNHEXED hu 2 / >str ;

\ Rust's DownloadSlotIdentity::new and encode_download_slot_state; the
\ binding is sha256sum of Rust's input for this download.
: SLOT-BYTES-ARE-RUSTS ( -- )
   s" slot identity and state bytes are the Rust daemon's" T-LABEL
   s" 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
   DROPBOX:>HASH s" 015f1a2b3c4d" DROPBOX:>REV
   MODEL-REMOTE:MAKE {: r:MODEL:remote :}
   7 42 s" Docs/a.txt" r LOCAL:NEW-SLOT-IDENTITY LOCAL:SLOT-BINDING
   $0102030405060708 LOCAL:STATE-BYTES str> {: p:^ u:n :}
   u 63 T=
   p 23 >str s" omabox-download-slot-v1" T$=
   p 23 + 32 >str
   s" 5ab14b7f1ecd878a5ce03fa13ad45efd36df5aad8c4bef0129fefdc17a4b9430"
   UNHEX T$=
   p 55 + 8 >str s" 0102030405060708" UNHEX T$= ;

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
: NUMBERED ( str n -- str )
   {: s:str k:n :}
   s str> {: x:^ xu:n :}
   x TEXT-BUF xu BYTE-COPY
   k FMT:INT$ str> {: d:^ du:n :}
   d TEXT-BUF xu + du BYTE-COPY
   TEXT-BUF xu du + >str ;

\ Rust's test_slot_identity: target t's download of c at "revision-<op>".
: SLOT-IDENTITY
   ( str DROPBOX:hash n n -- LOCAL:download-slot-identity )
   {: t:str c:DROPBOX:hash generation:n op:n :}
   c s" revision-" op NUMBERED DROPBOX:>REV MODEL-REMOTE:MAKE
   {: r:MODEL:remote :}
   generation op t r LOCAL:NEW-SLOT-IDENTITY ;

: DOWNLOAD ( -- DROPBOX:hash ) s" download" HASH-OF ;

\ The lease of the case directory's slots for the identity, apart.
: LEASE
   ( str DROPBOX:hash n n [ LOCAL:binding -- bool ]
     -- n LOCAL:binding bool )
   {: t:str c:DROPBOX:hash generation:n op:n protected :}
   t c generation op SLOT-IDENTITY {: id:LOCAL:download-slot-identity :}
   ROOT$ id protected LOCAL:LEASE-DOWNLOAD-SLOT LOCAL:LEASE-OF ;

TYPED-VARIABLE HELD-BINDING LOCAL:binding
: HELD? ( LOCAL:binding -- bool ) HELD-BINDING @ LOCAL:BINDING= ;

4 TYPED-BUFFER LEASED LOCAL:binding
variable LEASED-COUNT

: LEASED? ( LOCAL:binding -- bool )
   {: b:LOCAL:binding :}
   LEASED-COUNT @ 0 ?do
      i LEASED @ b LOCAL:BINDING= if true unloop exit then
   loop false ;

: SLOT-AT ( n -- str ) LOCAL:DOWNLOAD-SLOT-NAME AT ;

64 BUFFER: HELD-BYTES

\ The file at the path holds exactly the bytes.
: HOLDS ( str str -- )
   {: p:str b:str :}
   p HELD-BYTES 64 FS:READ-ALL {: k:n :}
   HELD-BYTES k >str b T$= ;

\ The open file carries the binding at offset at.
: STATE-IS ( fd str LOCAL:binding n -- )
   {: f:fd name:str want:LOCAL:binding offset:n :}
   f name LOCAL:SLOT-STATE-OF {: b:LOCAL:binding at:n found:bool :}
   found TTRUE b want LOCAL:BINDING= TTRUE at offset T= ;

\ The file at name below the root carries the binding at offset at.
: STATE-AT ( fd str LOCAL:binding n -- )
   {: root:fd name:str want:LOCAL:binding offset:n :}
   root name OPEN-AT {: f:fd :}
   [: f name want offset STATE-IS ;] [: f FS:CLOSE-DIR ;] finally ;

variable FILES

: COUNT-FILE ( str -- ) drop 1 FILES +! ;

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
   0 FILES ! ROOT$ [: COUNT-FILE ;] FS:WALK-FILES FILES @ 4 T=
   4 0 ?do i SLOT-AT FS:FILE? TTRUE loop ;

: DOWNLOAD-SLOT-POOL-HAS-FOUR-FIXED-PATHS-WITHOUT-OVERFLOW ( -- )
   s" download_slot_pool_has_four_fixed_paths_without_overflow" T-LABEL
   [: POOL ;] IN-CASE-DIR ;

: PROTECTED ( fd -- )
   {: root:fd :}
   s" held.bin" DOWNLOAD 1 20 [: TEST-CLIENT:UNPROTECTED ;] LEASE
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
   TARGET DOWNLOAD 1 10 [: TEST-CLIENT:UNPROTECTED ;] LEASE
   {: old:n ob:LOCAL:binding f0:bool :}
   f0 TTRUE ob HELD-BINDING ! old STALE
   s" other.bin" DOWNLOAD 1 30 [: HELD? ;] LEASE
   {: other:n xb:LOCAL:binding f1:bool :}
   f1 TTRUE other STALE
   TARGET DOWNLOAD 2 10 SLOT-IDENTITY LOCAL:SLOT-BINDING
   ob LOCAL:BINDING= TFALSE
   TARGET DOWNLOAD 1 11 SLOT-IDENTITY LOCAL:SLOT-BINDING
   ob LOCAL:BINDING= TFALSE
   TARGET DOWNLOAD 2 10 [: TEST-CLIENT:UNPROTECTED ;] LEASE
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
: AT2 ( str -- str )
   {: p:str :}
   ROOT$ p JOINED2 FS:JOIN-PATH JOINED2 swap >str ;

: SLOT$ ( -- str ) SLOT-NAME-BUF SLOT-NAME-U @ >str ;
: SLOT-PATH$ ( -- str ) SLOT-PATH-BUF SLOT-PATH-U @ >str ;

\ Keeps the slot's name and path where only the case reads them.
: KEEP-SLOT ( n -- )
   {: slot:n :}
   slot LOCAL:DOWNLOAD-SLOT-NAME str> {: p:^ u:n :}
   p SLOT-NAME-BUF u BYTE-COPY u SLOT-NAME-U !
   SLOT$ AT str> {: q:^ qu:n :}
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
   TARGET EXPECTED 1 1 [: TEST-CLIENT:UNPROTECTED ;] LEASE
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

: SYNC$ ( -- str ) SYNC-BUF SYNC-U @ >str ;

: WITH-SYNC-ROOT ( fd [ fd -- ] -- )
   {: case:fd q :}
   s" sync" AT FS:MAKE-DIR
   s" sync" AT str> {: p:^ u:n :}
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
: TEST-LEASE ( str DROPBOX:hash -- LOCAL:download-slot-lease )
   {: t:str c:DROPBOX:hash :}
   t c 1 1 SLOT-IDENTITY {: id:LOCAL:download-slot-identity :}
   ROOT$ id [: TEST-CLIENT:UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT TEST-CLIENT:LEASED ;

: DOWNLOAD-PREPARE
   ( fd str DROPBOX:hash LOCAL:download-slot-lease
     -- LOCAL:download-preparation )
   {: root:fd t:str c:DROPBOX:hash lease:LOCAL:download-slot-lease :}
   root SYNC$ t c lease AR @ LOCAL:PREPARE-DOWNLOAD-SLOT-AT ;

: DROP-OUTCOME ( LOCAL:stage-outcome<n> -- ) drop ;

\ The preparation's variant, a complete one's outcome and its path; a
\ ready partial is freed.
: DOWNLOAD-PREPARATION$ ( LOCAL:download-preparation -- str str )
   MATCH LOCAL:download-preparation
      ready OF LOCAL:CLOSE-PARTIAL s" ready" s" " ENDOF
      complete OF OUTCOME$ ENDOF
      ephemeral OF s" ephemeral" s" " ENDOF
   ;MATCH ;

: PREPARED-AS ( LOCAL:download-preparation str -- )
   {: p:LOCAL:download-preparation want:str :}
   p DOWNLOAD-PREPARATION$ s" " T$= want T$= ;

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

: BOUNDARY ( -- str ) s" boundary.bin" ;

: SIZE-OF ( fd -- n ) FS:FD-STAT FS:STAT-SIZE@ ;

\ A download cut after cut bytes leaves written bytes and resumes at
\ durable.
: INTERRUPTED ( fd n n n -- )
   {: root:fd cut:n written:n durable:n :}
   s" download never reaches verification" HASH-OF {: c:DROPBOX:hash :}
   BOUNDARY c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root BOUNDARY c lease DOWNLOAD-PREPARE LOCAL:READY-PARTIAL {: x :}
   x LOCAL:PARTIAL-PATH {: p:str :}
   cut REMAINING !
   [: x TOTAL [: FAILING ;] AR @ LOCAL:APPEND-PARTIAL DROP-OUTCOME ;]
   LOCAL:E-STAGE-READ TTHROWSQ
   p FS:FILE-SIZE written T=
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
   ( fd DROPBOX:hash LOCAL:download-slot-lease str
     -- ^LOCAL:download-partial )
   {: root:fd c:DROPBOX:hash lease:LOCAL:download-slot-lease b:str :}
   root TARGET c lease DOWNLOAD-PREPARE LOCAL:READY-PARTIAL {: x :}
   x LOCAL:PARTIAL-FILE b FD:WRITE-FULL
   x ;

: STAGE-HOLDS ( ^LOCAL:download-partial str -- )
   {: x b:str :}
   x LOCAL:PARTIAL-STAGE-PATH b HOLDS ;

: NO-CONTENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;

: ACTUAL$ ( option<DROPBOX:hash> -- str )
   MATCH option
      none OF s" none" ENDOF
      some OF DROPBOX:HASH>STR ENDOF
   ;MATCH ;

\ The outcome's variant, and its path or actual content, else empty.
: INSTALL$ ( LOCAL:install-outcome -- str str )
   MATCH LOCAL:install-outcome
      installed OF s" installed" s" " ENDOF
      already-installed OF s" already-installed" s" " ENDOF
      download-required OF s" download-required" s" " ENDOF
      stage-destination-occupied OF {: p:str :}
         s" stage-destination-occupied" p
      ENDOF
      precondition-changed OF {: a:option<DROPBOX:hash> :}
         s" precondition-changed" a ACTUAL$
      ENDOF
   ;MATCH ;

\ Rust's install_download of c at the target below the sync root, then
\ the target read back: it holds b.
: INSTALLS ( fd DROPBOX:hash str -- )
   {: root:fd c:DROPBOX:hash b:str :}
   root SYNC$ TARGET c NO-CONTENT AR @ LOCAL:INSTALL-DOWNLOAD-AT
   INSTALL$ s" " T$= s" installed" T$=
   SYNC$ TARGET JOINED FS:JOIN-PATH JOINED swap >str b HOLDS ;

: RECOVERED ( fd bool -- )
   {: root:fd renamed:bool :}
   s" completed bytes" {: b:str :}
   b HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   renamed if x LOCAL:RENAME-TO-STAGE TTRUE then
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease DOWNLOAD-PREPARE
   renamed if s" already-staged" else s" staged" then PREPARED-AS
   root TARGET c lease DOWNLOAD-PREPARE s" already-staged" PREPARED-AS
   x b STAGE-HOLDS
   root c b INSTALLS ;

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
   x LOCAL:PARTIAL-PATH {: p:str :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease DOWNLOAD-PREPARE
   {: prep:LOCAL:download-preparation :}
   owned if prep RESTARTED-EMPTY exit then
   prep s" ephemeral" PREPARED-AS
   p s" incomplete" HOLDS ;

: CORRUPT-COMPLETED-PARTIAL-RESTARTS-ONLY-WHEN-OWNED ( -- )
   s" corrupt_completed_partial_restarts_only_when_owned" T-LABEL
   [: true CORRUPT ;] IN-SYNC-ROOT
   [: false CORRUPT ;] IN-SYNC-ROOT ;

\ Rust's before_move here: the slot moves to held-slot and a new file
\ takes its name.
: SWAP-PARTIAL ( str -- )
   {: p:str :}
   p s" held-slot" AT FS:RENAME-FILE
   p s" replacement" FS:WRITE-ALL ;

: SWAPPED-PROMOTION ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:str :}
   b HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:PARTIAL-PATH {: p:str :}
   [: x [: p SWAP-PARTIAL ;] AR @ LOCAL:PROMOTE-WITH OUTCOME$
      p T$= s" destination-occupied" T$= ;]
   [: x LOCAL:CLOSE-PARTIAL ;] finally
   p s" replacement" HOLDS
   s" held-slot" AT b HOLDS
   x LOCAL:PARTIAL-STAGE-PATH FS:TRY-LSTAT TFALSE ;

: COMPLETED-PARTIAL-PROMOTION-PRESERVES-A-SWAPPED-REPLACEMENT ( -- )
   s" completed_partial_promotion_preserves_a_swapped_replacement" T-LABEL
   [: SWAPPED-PROMOTION ;] IN-SYNC-ROOT ;

\ The errno is read before the sync root is writable again.
: REFUSED-PROMOTION ( ^LOCAL:download-partial -- )
   {: x :}
   [: [: x [: SYNC$ LOCAL:MODE-0500 FS:CHMOD-MODE ;] AR @
         LOCAL:PROMOTE-WITH DROP-OUTCOME ;]
      [: FS:ERRNO LOCAL:CAUGHT ! SYNC$ MODE-0700 FS:CHMOD-MODE ;]
      finally ;] LOCAL:E-IO TTHROWSQ ;

\ The slot is in the case directory and the stage in the sync root.
: REFUSED-PROMOTION-LOGS ( ^LOCAL:download-partial -- )
   {: x :}
   [: x REFUSED-PROMOTION ;]
   LOG-PATH AR @ STDERR:CAPTURING {: code:n e:str :}
   code 0<> if code throw then
   LOCAL:CAUGHT @ FS:EACCES T=
   e 1 LOCAL:LOGGED
   e s" ; directory" ROOT$ s" 0700" LOCAL:OWNED? TTRUE
   e s" ; directory" SYNC$ s" 0500" LOCAL:OWNED? TTRUE
   e ROOT$ LOCAL:CLAUSE-AT e SYNC$ LOCAL:CLAUSE-AT < TTRUE
   e s" ; entry" s" .omabox-download-slot-0" s" 0600" LOCAL:OWNED?
   TTRUE
   e LOCAL:RUNS-AS? TTRUE ;

: DENIED-PROMOTION ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:str :}
   b HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   [: x REFUSED-PROMOTION-LOGS ;] [: x LOCAL:CLOSE-PARTIAL ;] finally ;

: DENIED-SLOT-PROMOTION-NAMES-BOTH-SIDES ( -- )
   s" denied_slot_promotion_names_both_sides" T-LABEL
   LOCAL:ROOT-USER? if exit then
   [: DENIED-PROMOTION ;] IN-SYNC-ROOT ;

: CROSS-FILESYSTEM ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:str :}
   b HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   [: x AR @ LOCAL:COPY-PARTIAL OUTCOME$ s" " T$= s" staged" T$= ;]
   [: x LOCAL:CLOSE-PARTIAL ;] finally
   x LOCAL:PARTIAL-PATH FS:FILE-SIZE 0 T=
   x b STAGE-HOLDS
   root c b INSTALLS ;

: CROSS-FILESYSTEM-SLOT-COMPLETION-COPIES-REHASHES-AND-FREES-THE-SLOT
   ( -- )
   s" cross_filesystem_slot_completion_copies_rehashes_and_frees_the_slot"
   T-LABEL
   [: CROSS-FILESYSTEM ;] IN-SYNC-ROOT ;

\ Rust's staged_download(stage_download(...)): b staged from a reader
\ below the sync root fd.
: STAGE-BYTES ( fd str DROPBOX:hash -- )
   {: root:fd b:str c:DROPBOX:hash :}
   b START 0 SCHEDULE
   root SYNC$ TARGET c [: FRAGMENT ;] AR @ LOCAL:STAGE-DOWNLOAD-AT
   OUTCOME$
   s" " T$= s" staged" T$= ;

: ZERO-REPLAY ( fd -- )
   {: root:fd :}
   s" complete bytes" {: b:str :}
   b HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease b WRITTEN {: x :}
   x AR @ LOCAL:MARK-PARTIAL
   x LOCAL:ZERO-CHECKPOINT
   root b c STAGE-BYTES
   x LOCAL:PARTIAL-PATH {: p:str :}
   x LOCAL:CLOSE-PARTIAL
   root TARGET c lease DOWNLOAD-PREPARE s" already-staged" PREPARED-AS
   p FS:FILE-SIZE 0 T=
   root TARGET c lease DOWNLOAD-PREPARE s" already-staged" PREPARED-AS
   root c b INSTALLS ;

: INTERRUPTED-PARTIAL-RESET-REPLAYS-TO-A-REUSABLE-ZERO-CHECKPOINT ( -- )
   s" interrupted_partial_reset_replays_to_a_reusable_zero_checkpoint"
   T-LABEL
   [: ZERO-REPLAY ;] IN-SYNC-ROOT ;

\ The written partial of target.txt's download of "complete bytes".
: RESTARTABLE ( fd -- ^LOCAL:download-partial )
   {: root:fd :}
   s" complete bytes" HASH-OF {: c:DROPBOX:hash :}
   TARGET c TEST-LEASE {: lease:LOCAL:download-slot-lease :}
   root c lease s" partial bytes" WRITTEN ;

: RESTARTS ( fd -- )
   RESTARTABLE {: x :}
   x LOCAL:PARTIAL-PATH {: p:str :}
   x LOCAL:RESTART-PARTIAL RESTARTED-EMPTY
   p FS:FILE-SIZE 0 T= ;

\ A replacement swapped in for the slot keeps its bytes, and so does the
\ slot.
: RESTART-SWAPPED ( fd -- )
   RESTARTABLE {: x :}
   x LOCAL:PARTIAL-PATH {: p:str :}
   p SWAP-PARTIAL
   x LOCAL:RESTART-PARTIAL DOWNLOAD-PREPARATION$
   p T$= s" destination-occupied" T$=
   p s" replacement" HOLDS
   s" held-slot" AT s" partial bytes" HOLDS ;

\ The slot directory, unsearchable, fails the slot's reopen.
: RESTART-DENIED ( fd -- )
   LOCAL:ROOT-USER? if drop exit then
   RESTARTABLE {: x :}
   ROOT$ 0 FS:CHMOD-MODE
   [: [: x LOCAL:RESTART-PARTIAL DOWNLOAD-PREPARATION$ 2drop ;]
      LOCAL:E-IO TTHROWSQ ;]
   [: ROOT$ MODE-0700 FS:CHMOD-MODE ;] finally ;

: RESTARTED-PARTIAL-IS-EMPTY-OR-FAILS ( -- )
   s" restarted partial is empty or fails" T-LABEL
   [: RESTARTS ;] IN-SYNC-ROOT
   s" swapped slot" T-LABEL
   [: RESTART-SWAPPED ;] IN-SYNC-ROOT
   s" unsearchable slot directory" T-LABEL
   [: RESTART-DENIED ;] IN-SYNC-ROOT ;

\ ---- installs

64 BUFFER: READ-BUF

\ The bytes of the file at the name below the case's directory.
: READ$ ( str -- str )
   AT READ-BUF 64 FS:READ-ALL READ-BUF swap >str ;

: HELD ( str -- option<DROPBOX:hash> ) HASH-OF OPTION:SOME ;

: REPLACEMENT-PREPARATION$
   ( LOCAL:replacement-preparation -- str str )
   MATCH LOCAL:replacement-preparation
      prepared OF s" prepared" s" " ENDOF
      already-prepared OF s" already-prepared" s" " ENDOF
      precondition-changed OF {: a:option<DROPBOX:hash> :}
         s" precondition-changed" a ACTUAL$
      ENDOF
   ;MATCH ;

: STAGE-NAME$ ( str -- str ) WANT AR @ LOCAL:STAGE-NAME ;

\ STAGE-DOWNLOAD-AT of "remote" as t's owned download below the case's
\ directory, whose fd is root.
: STAGE-REMOTE ( fd str -- )
   {: root:fd t:str :}
   s" remote" START 0 SCHEDULE
   root ROOT$ t WANT [: FRAGMENT ;] AR @ LOCAL:STAGE-DOWNLOAD-AT
   OUTCOME$ s" " T$= s" staged" T$= ;

\ INSTALL-DOWNLOAD-AT of "remote" at t below the case's directory, whose
\ fd is root.
: INSTALL ( fd str option<DROPBOX:hash> -- str str )
   {: root:fd t:str expected:option<DROPBOX:hash> :}
   t T-LABEL
   root ROOT$ t WANT expected AR @ LOCAL:INSTALL-DOWNLOAD-AT
   INSTALL$ ;

: REPLACEMENT-PREPARE ( fd str str -- str str )
   {: root:fd t:str c:str :}
   t T-LABEL
   root ROOT$ t c HASH-OF AR @ LOCAL:PREPARE-BELOW
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

: OPEN-WRITE-AT ( fd str -- fd )
   FS:TRY-OPEN-WRITE-AT MATCH option
      none OF E-FS-OPEN throw ENDOF
      some OF ENDOF
   ;MATCH ;

: MUTATED-STAGE ( fd -- )
   {: root:fd :}
   root TARGET STAGE-REMOTE
   TARGET STAGE-NAME$ {: sn:str :}
   sn AT FS:MODE-PRIVATE-FILE FS:CHMOD-MODE
   root sn OPEN-WRITE-AT {: w:fd :}
   [: root ROOT$ TARGET WANT AR @ w LOCAL:INSTALL-RENAME-MUTATED ;]
   [: w FS:CLOSE-DIR ;] finally
   root TARGET LOCAL:ENTRY-EXISTS-AT TFALSE
   sn READ$ s" mutant" T$= ;

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

: INSTALLED-BYTES ( -- str ) s" installed bytes" ;
: INSTALLED-MARKER ( -- str )
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
   s" other.txt" STAGE-NAME$ {: sn:str :}
   sn s" mutant" PUT-FILE
   root s" other.txt" NO-CONTENT INSTALL
   sn AT T$= s" stage-destination-occupied" T$= ;

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
   s" dir.txt" STAGE-NAME$ {: sn:str :}
   sn AT FS:MAKE-DIR
   root s" dir.txt" NO-CONTENT INSTALL
   sn AT T$= s" stage-destination-occupied" T$=
   sn AT KIND FS:S-IFDIR T= ;

\ A file Omabox cannot read at the stage's name blocks the install and
\ keeps its bytes.
: UNREADABLE-STAGE ( fd -- )
   {: root:fd :}
   LOCAL:ROOT-USER? if exit then
   s" denied.txt" STAGE-NAME$ {: sn:str :}
   sn s" mutant" PUT-FILE
   sn AT 0 FS:CHMOD-MODE
   [: root s" denied.txt" NO-CONTENT INSTALL
      sn AT T$= s" stage-destination-occupied" T$= ;]
   [: sn AT MODE-0700 FS:CHMOD-MODE ;] finally
   sn READ$ s" mutant" T$= ;

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

\ A disposable download whose stage is complete keeps no descriptor.
: COMPLETE-DISPOSABLE ( fd -- )
   {: root:fd :}
   root TARGET STAGE-REMOTE
   LOCAL:FD-COUNT {: before:n :}
   root ROOT$ TARGET WANT ROOT$ AR @
   LOCAL:PREPARE-DISPOSABLE-DOWNLOAD-AT
   DOWNLOAD-PREPARATION$ s" " T$= s" already-staged" T$=
   LOCAL:FD-COUNT before T= ;

: COMPLETE-DISPOSABLE-DOWNLOAD-CLOSES-ITS-PARENT ( -- )
   s" complete disposable download closes its parent" T-LABEL
   [: COMPLETE-DISPOSABLE ;] IN-CASE-DIR ;

: FALLBACK ( -- str ) s" fallback.bin" ;

: EXISTING$ ( option<LOCAL:stage-outcome<n>> -- str str )
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
   s" disposable download" {: b:str :}
   b HASH-OF {: c:DROPBOX:hash :}
   root c DISPOSABLE-PARTIAL {: x :}
   x LOCAL:DISPOSABLE? TTRUE
   b START 0 SCHEDULE
   x b str> nip [: FRAGMENT ;] AR @ LOCAL:APPEND-PARTIAL OUTCOME$
   s" " T$= s" staged" T$=
   root SYNC$ FALLBACK c AR @ LOCAL:EXISTING-DOWNLOAD-STAGE-AT
   EXISTING$ s" " T$= s" already-staged" T$=
   STAGING LOCAL:ENTRY-COUNT 0 T= ;

: DISPOSABLE-DOWNLOAD-BODY-DOES-NOT-HOLD-THE-SCAN-LOCK ( -- )
   s" disposable_download_body_does_not_hold_the_scan_lock" T-LABEL
   [: DISPOSABLE-BODY ;] IN-SYNC-ROOT ;

\ ---- parents

: INODE ( fd -- n ) FS:FD-STAT FS:STAT-INO@ ;

: PATH-INODE ( str -- n ) AT FS:TRY-LSTAT TTRUE FS:STAT-INO@ ;

: SAME-ADDRESS ( ^u8 ^u8 -- )
   {: a:^ b:^ :}
   a NULL-PTR - b NULL-PTR - T= ;

\ p's parent opens, its name and path spans of p; answers the descriptor.
: PARENT ( fd str bool str str -- fd )
   {: root:fd p:str create:bool name:str path:str :}
   p T-LABEL
   root p create LOCAL:PARENT-OF TTRUE
   {: f:fd got:str gp:str :}
   got name T$= gp path T$=
   p str> {: a:^ u:n :}
   name str> nip {: nu:n :}
   got str> drop a u + nu - SAME-ADDRESS
   gp str> drop a SAME-ADDRESS
   f ;

\ Closes the descriptor PARENT-OF answers, if any.
: TRY-PARENT ( fd str bool -- )
   LOCAL:PARENT-OF {: f:fd n:str pp:str found:bool :}
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
   {: f:fd n:str pp:str :}
   root s" a/missing" LOCAL:ENTRY-EXISTS-AT TFALSE ;

: PRIVATE-DIR ( str -- )
   {: p:str :}
   p T-LABEL
   p AT FS:TRY-LSTAT TTRUE
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

: UNSAFE-PARENT ( fd str -- )
   {: root:fd p:str :}
   p T-LABEL
   [: root p false TRY-PARENT ;] LOCAL:E-UNSAFE-PATH TTHROWSQ ;

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
: DELETED$ ( LOCAL:delete-outcome -- str str )
   MATCH LOCAL:delete-outcome
      deleted OF s" deleted" s" " ENDOF
      already-deleted OF s" already-deleted" s" " ENDOF
      precondition-changed OF {: c:option<DROPBOX:hash> :}
         s" precondition-changed" c ACTUAL$
      ENDOF
   ;MATCH ;

\ Deletes target.txt below the case directory, whose fd is root, while
\ it holds "old".
: DELETE ( fd -- str str )
   ROOT$ TARGET OLD AR @ LOCAL:DELETE-LOCAL-AT DELETED$ ;

: GUARD ( -- str ) s" deleted" TARGET OLD AR @ LOCAL:INTERNAL-NAME ;

64 BUFFER: BACK

\ The bytes of the file at the name below the case directory.
: BYTES ( str -- str ) AT BACK 64 FS:READ-ALL BACK swap >str ;

: PRESENT? ( str -- bool ) AT FS:TRY-LSTAT ;

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

\ The empty content's hash in uppercase, which is no content hash.
: UPPERCASE ( -- DROPBOX:hash )
   s" E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"
   DROPBOX:>HASH ;

\ The delete fails before it looks at the target.
: UPPERCASE-DELETE ( fd -- )
   {: root:fd :}
   TARGET s" old" PUT-FILE
   [: root ROOT$ TARGET UPPERCASE AR @ LOCAL:DELETE-LOCAL-AT
      DELETED$ 2drop ;]
   LOCAL:E-CONTENT-HASH TTHROWSQ
   TARGET BYTES s" old" T$= ;

: DELETE-OF-AN-UPPERCASE-HASH-FAILS ( -- )
   s" delete of an uppercase hash fails" T-LABEL
   [: UPPERCASE-DELETE ;] IN-CASE-DIR ;

\ ---- changed guards

: RACED ( -- DROPBOX:hash ) s" raced bytes" HASH-OF ;

: RACED-GUARD ( -- str )
   s" displaced" TARGET RACED AR @ LOCAL:INTERNAL-NAME ;

: RACED-COPY ( -- str )
   TARGET LOCAL-CONFLICT--SIDE:LOCAL RACED AR @ LOCAL:CONFLICT-NAME ;

\ The guard holds "raced bytes" and target.txt an edit raced in.
: GUARD-RACE ( -- )
   RACED-GUARD s" raced bytes" PUT-FILE
   TARGET s" edit" PUT-FILE ;

: RESTORE-GUARD ( fd option<DROPBOX:hash> -- )
   {: root:fd actual:option<DROPBOX:hash> :}
   root RACED-GUARD TARGET TARGET actual AR @
   LOCAL:RESTORE-OR-PRESERVE-CHANGED-GUARD ;

: RACE-KEPT ( str -- )
   {: copy:str :}
   TARGET BYTES s" edit" T$=
   RACED-COPY BYTES copy T$= ;

: PRESERVE-CASES ( fd -- )
   {: root:fd :}
   s" raced guard preserved" T-LABEL
   GUARD-RACE
   root s" raced bytes" HELD RESTORE-GUARD
   s" raced bytes" RACE-KEPT RACED-GUARD PRESENT? TFALSE
   s" duplicate raced guard removed" T-LABEL
   GUARD-RACE
   root s" raced bytes" HELD RESTORE-GUARD
   s" raced bytes" RACE-KEPT RACED-GUARD PRESENT? TFALSE
   s" conflict name occupied" T-LABEL
   RACED-COPY s" other copy" PUT-FILE
   GUARD-RACE
   [: root s" raced bytes" HELD RESTORE-GUARD ;]
   LOCAL:E-OCCUPIED TTHROWSQ
   s" other copy" RACE-KEPT RACED-GUARD BYTES s" raced bytes" T$=
   s" unknown raced guard" T-LABEL
   [: root NO-CONTENT RESTORE-GUARD ;] LOCAL:E-CHANGED TTHROWSQ
   s" other copy" RACE-KEPT RACED-GUARD BYTES s" raced bytes" T$= ;

: EACH-CHANGED-GUARD-ARM-IS-REACHED ( -- )
   s" each changed guard arm is reached" T-LABEL
   [: PRESERVE-CASES ;] IN-CASE-DIR ;

\ ---- directories

: CREATED$ ( LOCAL:create-directory-outcome -- str )
   MATCH LOCAL:create-directory-outcome
      created OF s" created" ENDOF
      already-present OF s" already-present" ENDOF
      fresh-observation OF s" fresh-observation" ENDOF
   ;MATCH ;

: REMOVED$ ( LOCAL:delete-directory-outcome -- str )
   MATCH LOCAL:delete-directory-outcome
      deleted OF s" deleted" ENDOF
      already-absent OF s" already-absent" ENDOF
      fresh-observation OF s" fresh-observation" ENDOF
   ;MATCH ;

: MKDIR ( fd str str -- )
   {: root:fd p:str want:str :}
   p T-LABEL
   root p LOCAL:CREATE-DIRECTORY-AT CREATED$ want T$= ;

: RMDIR ( fd str str -- )
   {: root:fd p:str want:str :}
   p T-LABEL
   root p LOCAL:DELETE-DIRECTORY-AT REMOVED$ want T$= ;

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
: CONFLICT$ ( LOCAL:conflict-outcome -- str str )
   MATCH LOCAL:conflict-outcome
      created OF {: p:str :} s" created" p ENDOF
      already-present OF {: p:str :} s" already-present" p ENDOF
      content-changed OF {: c:DROPBOX:hash :}
         s" content-changed" c DROPBOX:HASH>STR
      ENDOF
   ;MATCH ;

: ORIGINAL ( -- str ) s" dir/original.txt" ;

\ Materializes the bytes as ORIGINAL's remote conflict copy of "remote"
\ below the case directory, whose fd is root.
: MATERIALIZED ( fd str -- str str )
   {: root:fd b:str :}
   b START 0 SCHEDULE
   root ROOT$ ORIGINAL LOCAL-CONFLICT--SIDE:REMOTE WANT [: FRAGMENT ;]
   AR @ LOCAL:MATERIALIZE-CONFLICT-AT CONFLICT$ ;

: COPY-PATH ( -- str )
   ORIGINAL LOCAL-CONFLICT--SIDE:REMOTE WANT AR @
   LOCAL:CONFLICT-RELATIVE-PATH ;

\ A conflict copy whose reader fails with a file failure throws E-IO.
: FAILED-CONFLICT-READ ( fd -- )
   {: root:fd :}
   0 REMAINING !
   [: root ROOT$ ORIGINAL LOCAL-CONFLICT--SIDE:REMOTE WANT [: FAILING ;]
      AR @ LOCAL:MATERIALIZE-CONFLICT-AT CONFLICT$ 2drop ;]
   LOCAL:E-IO TTHROWSQ ;

: CONFLICT-CASES ( fd -- )
   {: root:fd :}
   s" created" T-LABEL
   root s" remote" MATERIALIZED COPY-PATH T$= s" created" T$=
   COPY-PATH BYTES s" remote" T$=
   COPY-PATH str> drop 4 >str s" dir/" T$=
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

\ ---- recovery copies

: RECOVERY ( -- str ) TARGET WANT AR @ LOCAL:RECOVERY-FILE-NAME ;

\ The Rust daemon's name for target.txt's copy holding "remote".
: RECOVERY-NAME-IS-RUSTS ( -- )
   s" recovery name is the Rust daemon's" T-LABEL
   RECOVERY
   s" .omabox-recovery-09e159a5cdb6c4db7c02b9aebdb2458b1d3b2774003e7b1474494282cbe4faef"
   T$= ;

: VERIFIED-COPY? ( fd -- bool )
   ROOT$ RECOVERY WANT AR @ LOCAL:VERIFY-PRIVATE-COPY ;

: COPY-FAILS ( fd n -- )
   {: root:fd code:n :}
   [: root VERIFIED-COPY? drop ;] code TTHROWSQ ;

: RECOVERY-CASES ( fd -- )
   {: root:fd :}
   s" absent copy" T-LABEL
   root VERIFIED-COPY? TFALSE
   s" verified copy" T-LABEL
   RECOVERY s" remote" PUT-FILE
   root VERIFIED-COPY? TTRUE
   s" corrupt copy" T-LABEL
   RECOVERY s" mutant" PUT-FILE
   root LOCAL:E-CORRUPT COPY-FAILS
   RECOVERY BYTES s" mutant" T$=
   LOCAL:ROOT-USER? if exit then
   s" unreadable copy" T-LABEL
   RECOVERY AT 0 FS:CHMOD-MODE
   root LOCAL:E-UNREADABLE COPY-FAILS ;

: EACH-RECOVERY-COPY-OUTCOME-IS-REACHED ( -- )
   s" each recovery copy outcome is reached" T-LABEL
   [: RECOVERY-CASES ;] IN-CASE-DIR ;

\ ---- a symlinked state home

FS:PATHZ-CAP BUFFER: PHYSICAL-BUF
variable PHYSICAL-U
FS:PATHZ-CAP BUFFER: STAGING-BUF
FS:PATHZ-CAP BUFFER: SLOT-FILE-BUF

: PHYSICAL$ ( -- str ) PHYSICAL-BUF PHYSICAL-U @ >str ;

\ The name below the case directory, kept, as CONFIG takes it.
: CASE-PATH ( str -- CONFIG:abs-path ) AT HOLD CONFIG:>ABS-PATH ;

\ Rust's physical_state canonicalized: beside the sync root, which
\ CONFIG canonicalizes.
: KEEP-PHYSICAL ( ^CONFIG:config -- )
   CONFIG:SYNC-ROOT CONFIG:ABS-PATH>STR str> {: p:^ u:n :}
   p u s" /Dropbox" str> nip - >str s" physical-state" PHYSICAL-BUF
   FS:JOIN-PATH
   PHYSICAL-U ! ;

\ Rust's starts_with: the path names physical-state's descendant.
: PROJECTED ( CONFIG:abs-path -- )
   CONFIG:ABS-PATH>STR str> {: p:^ u:n :}
   PHYSICAL-U @ {: k:n :}
   u k > if p k >str PHYSICAL$ STR:= p k + c@ $2F = and else false then
   TTRUE ;

: STAGED-SLOT? ( n -- bool )
   {: slot:n :}
   PHYSICAL$ s" omabox/upload-staging" STAGING-BUF FS:JOIN-PATH {: k:n :}
   STAGING-BUF k >str slot LOCAL:DOWNLOAD-SLOT-NAME SLOT-FILE-BUF
   FS:JOIN-PATH
   SLOT-FILE-BUF swap >str FS:FILE? ;

\ Rust's test's config: its state home a link to physical-state.
: LINKED-CONFIG ( -- ^CONFIG:config )
   s" physical-state" AT FS:MAKE-DIR
   s" physical-state" AT HOLD s" state-link" AT FS:MAKE-SYMLINK
   s" Dropbox" AT FS:MAKE-DIR
   s" config" CASE-PATH s" state-link" CASE-PATH AR @ CONFIG:XDG-NEW
   s" Dropbox" AT HOLD s" test-app-key" AR @ CONFIG:FROM-VALUES ;

: PATHS-PROJECTED ( ^CONFIG:paths -- )
   {: p :}
   p CONFIG:STATE-DIRECTORY PROJECTED
   p CONFIG:JOURNAL-FILE PROJECTED
   p CONFIG:UPLOAD-STAGING-DIRECTORY PROJECTED
   p CONFIG:RECOVERY-DIRECTORY PROJECTED
   p CONFIG:LOCK-FILE PROJECTED ;

: LINKED-STATE ( -- )
   LINKED-CONFIG {: c :}
   c CONFIG:PREPARE c KEEP-PHYSICAL
   c CONFIG:PATHS {: p :}
   TARGET DOWNLOAD 1 1 SLOT-IDENTITY {: id:LOCAL:download-slot-identity :}
   p CONFIG:UPLOAD-STAGING-DIRECTORY CONFIG:ABS-PATH>STR
   id [: TEST-CLIENT:UNPROTECTED ;] LOCAL:LEASE-DOWNLOAD-SLOT LOCAL:LEASE-OF
   {: slot:n b:LOCAL:binding found:bool :}
   found TTRUE
   p PATHS-PROJECTED
   slot STAGED-SLOT? TTRUE ;

: SLOTS-LEASE-THROUGH-A-SYMLINKED-STATE-HOME ( -- )
   s" slots_lease_through_a_symlinked_state_home" T-LABEL
   [: drop LINKED-STATE ;] IN-CASE-DIR ;

\ ---- renames

: RENAMED$ ( LOCAL:rename-outcome -- str )
   MATCH LOCAL:rename-outcome
      renamed OF s" renamed" ENDOF
      retry OF s" retry" ENDOF
   ;MATCH ;

: CREDIT ( -- str ) s" credit" ;
: DESTINATION ( -- str ) s" credit (case variant)" ;
: PRESERVED ( -- str ) s" preserved-by-racer" ;

: RENAME-VARIANT ( fd -- str )
   CREDIT DESTINATION LOCAL:RENAME-CASE-VARIANT RENAMED$ ;

: RACED-RENAME ( fd -- )
   {: root:fd :}
   CREDIT AT FS:MAKE-DIR
   s" credit/receipt.pdf" s" receipt" PUT-FILE
   DESTINATION s" raced destination" PUT-FILE
   root RENAME-VARIANT s" retry" T$=
   DESTINATION BYTES s" raced destination" T$=
   s" credit/receipt.pdf" BYTES s" receipt" T$= ;

: RETRIED-RENAME ( fd -- )
   {: root:fd :}
   DESTINATION AT FS:REMOVE-FILE
   root RENAME-VARIANT s" renamed" T$=
   CREDIT PRESENT? TFALSE
   s" credit (case variant)/receipt.pdf" BYTES s" receipt" T$=
   root RENAME-VARIANT s" retry" T$= ;

: RENAME-RACES ( fd -- )
   {: root:fd :}
   root RACED-RENAME root RETRIED-RENAME ;

: CASE-VARIANT-RENAME-PRESERVES-TREE-AND-RETRIES-RACES ( -- )
   s" case_variant_rename_preserves_tree_and_retries_races" T-LABEL
   [: RENAME-RACES ;] IN-CASE-DIR ;

\ Runs as the hook, between the source's probe and its rename.
: SWAP-SOURCE ( fd -- )
   {: root:fd :}
   root CREDIT root PRESERVED FS:TRY-RENAME-AT TTRUE
   CREDIT s" new bytes" PUT-FILE ;

: SWAPPED-SOURCE ( fd -- )
   {: root:fd :}
   CREDIT s" observed bytes" PUT-FILE
   root CREDIT DESTINATION true [: root SWAP-SOURCE ;]
   LOCAL:RENAME-CASE-VARIANT-WITH RENAMED$ s" retry" T$=
   PRESERVED BYTES s" observed bytes" T$=
   DESTINATION BYTES s" new bytes" T$=
   CREDIT PRESENT? TFALSE ;

: CASE-VARIANT-RENAME-PRESERVES-A-SWAPPED-SOURCE ( -- )
   s" case_variant_rename_preserves_a_swapped_source" T-LABEL
   [: SWAPPED-SOURCE ;] IN-CASE-DIR ;

\ PARENT-NAME-MAX's answer apart: its limit and true; for none, 0 and
\ false.
: NAME-MAX-OF ( option<n> -- n bool )
   MATCH option
      none OF 0 false ENDOF
      some OF true ENDOF
   ;MATCH ;

: PARENT-LIMIT ( fd -- )
   {: root:fd :}
   root s" missing/c" LOCAL:PARENT-NAME-MAX NAME-MAX-OF TFALSE drop
   s" a/b" AT FS:MAKE-DIRS
   root s" a/b/c" LOCAL:PARENT-NAME-MAX NAME-MAX-OF TTRUE
   root FS:FD-NAME-MAX T= ;

: PARENT-NAME-MAX-ANSWERS-ITS-PARENTS-LIMIT ( -- )
   s" parent name max answers its parent's limit" T-LABEL
   [: PARENT-LIMIT ;] IN-CASE-DIR ;

\ Dropped: parallel_cold_scan_matches_single_worker_scan compares hash
\ workers and download_promotion_cannot_invalidate_complete_scan holds the
\ scan lock; one task has neither.
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
   UNREADABLE-HASH-INPUT-FAILS
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
   DENIED-SLOT-PROMOTION-NAMES-BOTH-SIDES
   CROSS-FILESYSTEM-SLOT-COMPLETION-COPIES-REHASHES-AND-FREES-THE-SLOT
   INTERRUPTED-PARTIAL-RESET-REPLAYS-TO-A-REUSABLE-ZERO-CHECKPOINT
   RESTARTED-PARTIAL-IS-EMPTY-OR-FAILS
   SLOTS-LEASE-THROUGH-A-SYMLINKED-STATE-HOME
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
   DELETE-OF-AN-UPPERCASE-HASH-FAILS
   EACH-CHANGED-GUARD-ARM-IS-REACHED
   EACH-CONFLICT-OUTCOME-IS-REACHED
   RECOVERY-NAME-IS-RUSTS
   EACH-RECOVERY-COPY-OUTCOME-IS-REACHED
   CASE-VARIANT-RENAME-PRESERVES-TREE-AND-RETRIES-RACES
   CASE-VARIANT-RENAME-PRESERVES-A-SWAPPED-SOURCE
   PARENT-NAME-MAX-ANSWERS-ITS-PARENTS-LIMIT ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   [: CASES ;] [: AR @ ARENA:RELEASE ;] finally
   s" local-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

LOCAL-TEST:RUN
