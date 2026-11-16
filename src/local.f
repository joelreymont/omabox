\ local.f - package LOCAL: the local half of a sync (docs/habu-rewrite.md,
\ the LOCAL row) on Habu's anchored file words: its errors, the opens it
\ confines below the sync root, Dropbox content hashes of local files, the
\ scan that observes every entry below the root, the upload stages named
\ by their content's hash, which a Habu and a Rust daemon share, the
\ verified stages a download writes, with their xattr markers, the slots
\ in the state home where a download's partial bytes resume, the partials
\ themselves, checkpointed and promoted into their stages, their installs
\ over a target that still holds what the journal expects, and the
\ conditional deletes of local files, the directories a sync creates and
\ deletes, and the conflict copies it writes.
\ A relative path splits as Rust's Path::components splits it: empty and "."
\ components past the first are skipped, and an empty, absolute or leading "."
\ path, or one with a ".." component, is unsafe. Each component opens
\ relative to its parent's descriptor with O_NOFOLLOW, so no symlink
\ is followed: a last component that is one fails ELOOP, as openat2's
\ RESOLVE_NO_SYMLINKS does, and a parent that is one fails ENOTDIR where
\ openat2 answers ELOOP. A parent in a path opens by O_PATH, so it needs
\ search permission only. An io failure's errno stays in FS:ERRNO, 0 where
\ the Habu word that failed keeps none.
\ LOCAL logs a failure once, with its text, where it throws, unless the
\ catch around it turns it into an outcome: CONVERTING runs a word under a
\ predicate naming the codes and errnos its caller converts, and QUIET?
\ asks the innermost one. A scan's observation converts what ENTRY-CODE?
\ names and rethrows the rest, which logs and ends the scan; a failure
\ XATTR logged gets no second line.
\ The scan walks the root depth first, each directory's names in byte order,
\ and collects observations, cached hashes it may reuse and files to hash; a
\ failure that concerns one entry publishes that entry as unknown and drops
\ everything collected beneath it. It then hashes the files, revalidates the
\ cached ones and every directory, drops the subtree of a directory that
\ changed, and checks the root is the one it opened.
\ STORAGE CLASS. PROCESS-WIDE: the content hasher, its read buffer, the
\ name hasher, the marker and slot state buffers, the slot name and path
\ buffers, a lease's slot table, the byte a partial's end is probed with,
\ the directory listing context and the predicate of the innermost
\ CONVERTING; one task syncs, so one uses them at a time. CALLER-OWNED:
\ every descriptor answered, the hashes, names, paths, vectors, staged
\ uploads and partials laid in the caller's arena, the paths a stage's
\ result names and a lease's slot directory.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fs-list.f
require src/lib/allocator.f
require src/lib/fd.f
require src/lib/xattr.f
require src/lib/vector.f
require src/lib/sort.f
require src/dropbox.f
require src/model.f

package LOCAL
public

-100500 constant E-FIRST
-100599 constant E-LAST
-100500 s" a local path is not a safe path relative to the sync root"
   ERROR:CODE E-UNSAFE-PATH
-100501 s" a local path is not a regular file or directory"
   ERROR:CODE E-UNSUPPORTED
-100502 s" a local path is a file Omabox cannot read"
   ERROR:CODE E-UNREADABLE
-100503 s" a local path changed while it was observed"
   ERROR:CODE E-CHANGED
-100504 s" an operation was given no lowercase Dropbox content hash"
   ERROR:CODE E-CONTENT-HASH
-100505 s" a private local file failed content verification"
   ERROR:CODE E-CORRUPT
-100506 s" a non-overwriting operation found unrelated bytes"
   ERROR:CODE E-OCCUPIED
-100507 s" a local filesystem operation failed" ERROR:CODE E-IO
-100508 s" stage input could not be read" ERROR:CODE E-STAGE-READ
-100509 s" bytes could not be read for a Dropbox content hash"
   ERROR:CODE E-HASH-READ
-100510 s" the upload source changed or vanished while it was read"
   ERROR:CODE E-SOURCE-CHANGED

\ The side whose bytes a conflict copy holds.
ENUM conflict-side local remote ;ENUM

private

$10000 constant IO-SIZE

$2F constant SLASH
$2E constant DOT

\ ---- errors

: LOG-OPEN ( -- ) LOG:ERROR s" local" LOG:LINE ;

: QUOTED+ ( ^u8 n -- ) s" `" LOG:TEXT+ LOG:TEXT+ s" `" LOG:TEXT+ ;

: ERRNO+ ( n -- )
   {: e:n :}
   e 0= if exit then
   s" : errno " LOG:TEXT+ e LOG:INT+ ;

\ Out of descriptors, memory or space, the next entry would fail the same
\ way: Rust's EXHAUSTION, which says nothing about the object observed.
: EXHAUSTED? ( n -- bool )
   {: e:n :}
   e FS:EMFILE = e FS:ENFILE = or e FS:ENOMEM = or e FS:ENOSPC = or ;

\ Rust's REPLACED: the walk resolved the path moments ago, so a missing
\ component, one no longer a directory, a symlink where none was or a
\ stale handle mean the object moved under the scan.
: REPLACED? ( n -- bool )
   {: e:n :}
   e FS:ENOENT = e FS:ENOTDIR = or e FS:ELOOP = or e FS:ESTALE = or ;

\ The failures that are an observed entry's outcome, as Rust's
\ entry_unknown publishes them: an io failure with no errno still concerns
\ the one object, and exhaustion, which says nothing about it, fails the
\ scan.
: ENTRY-CODE? ( n n -- bool )
   {: code:n e:n :}
   code E-UNSUPPORTED = code E-CHANGED = or code E-UNREADABLE = or if
      true exit
   then
   code E-IO = e EXHAUSTED? 0= and ;

: NONE-CONVERTED ( n n -- bool ) 2drop false ;

\ The predicate of the innermost CONVERTING, true for the code and errno
\ of each failure its caller turns into an outcome; NONE-CONVERTED
\ outside any.
TYPED-VARIABLE CONVERTS [ n n -- bool ]
' NONE-CONVERTED CONVERTS !

\ Whether LOCAL logs nothing for a failure: its catcher converts it.
: QUIET? ( n n -- bool ) CONVERTS @ execute ;

public

\ Runs q with converted? as the predicate QUIET? asks, the outer one back
\ on every exit; answers what q threw, 0 for none. LOCAL logs no failure
\ converted? names: the caller converts it into an outcome.
: CONVERTING ( R [ R -- R ] [ n n -- bool ] -- R n )
   {: q converted? :}
   CONVERTS @ {: outer :}
   converted? CONVERTS !
   [: q execute ;] catch
   outer CONVERTS ! ;

private

\ Logs "local path `p`" and the text after it, then throws code.
: PATH-FAILS ( ^u8 n ^u8 n n -- )
   {: p:^ u:n t:^ tu:n code:n :}
   code FS:ERRNO QUIET? 0= if
      LOG-OPEN s" local path " LOG:TEXT+ p u QUOTED+
      t tu LOG:TEXT+ LOG:;LINE
   then
   code throw ;

: UNSAFE ( ^u8 n -- )
   s"  is not a safe path relative to the sync root"
   E-UNSAFE-PATH PATH-FAILS ;

: UNSUPPORTED-FAILS ( ^u8 n n -- )
   {: p:^ u:n code:n :}
   p u s"  is not a regular file or directory" code PATH-FAILS ;

: UNREADABLE ( ^u8 n -- )
   s"  is a file Omabox cannot read" E-UNREADABLE PATH-FAILS ;

\ The operation, then the path, as every word below takes them.
: CHANGED-FAILS ( ^u8 n ^u8 n n -- )
   {: o:^ ou:n p:^ u:n code:n :}
   code FS:ERRNO QUIET? 0= if
      LOG-OPEN s" local path " LOG:TEXT+ p u QUOTED+
      s"  changed during " LOG:TEXT+ o ou QUOTED+ LOG:;LINE
   then
   code throw ;

: CHANGED ( ^u8 n ^u8 n -- ) E-CHANGED CHANGED-FAILS ;

: INVALID-HASH ( ^u8 n -- )
   {: o:^ ou:n :}
   E-CONTENT-HASH FS:ERRNO QUIET? 0= if
      LOG-OPEN s" operation " LOG:TEXT+ o ou QUOTED+
      s"  requires a lowercase Dropbox content hash" LOG:TEXT+ LOG:;LINE
   then
   E-CONTENT-HASH throw ;

: CORRUPT ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   E-CORRUPT FS:ERRNO QUIET? 0= if
      LOG-OPEN s" private local file for " LOG:TEXT+ o ou QUOTED+
      s"  at " LOG:TEXT+ p u QUOTED+
      s"  failed content verification" LOG:TEXT+ LOG:;LINE
   then
   E-CORRUPT throw ;

: OCCUPIED ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   E-OCCUPIED FS:ERRNO QUIET? 0= if
      LOG-OPEN s" non-overwriting operation " LOG:TEXT+ o ou QUOTED+
      s"  found unrelated bytes at " LOG:TEXT+ p u QUOTED+ LOG:;LINE
   then
   E-OCCUPIED throw ;

\ Rust's io_failure, throwing code: FS:ERRNO holds the errno, kept across
\ the log.
: IO-FAILS ( ^u8 n ^u8 n n -- )
   {: o:^ ou:n p:^ u:n code:n :}
   FS:ERRNO {: e:n :}
   code e QUIET? 0= if
      LOG-OPEN s" local filesystem operation " LOG:TEXT+ o ou QUOTED+
      s"  failed for " LOG:TEXT+ p u QUOTED+ e ERRNO+ LOG:;LINE
   then
   e FS:CAUSE! code throw ;

: IO-FAILURE ( ^u8 n ^u8 n -- ) E-IO IO-FAILS ;

\ Rust's syscall_failure: io_failure with the errno given.
: SYSCALL-FAILURE ( n ^u8 n ^u8 n -- )
   {: e:n o:^ ou:n p:^ u:n :}
   e FS:CAUSE! o ou p u IO-FAILURE ;

\ Rust's StageIoError::Read: the source of a stage's bytes failed.
: STAGE-READ ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   FS:ERRNO {: e:n :}
   E-STAGE-READ e QUIET? 0= if
      LOG-OPEN s" could not read stage input during " LOG:TEXT+
      o ou QUOTED+ s"  for " LOG:TEXT+ p u QUOTED+ e ERRNO+ LOG:;LINE
   then
   e FS:CAUSE! E-STAGE-READ throw ;

\ Rust's From<StageIoError> for LocalError: a stage read is an io failure.
: LOCAL-CODE ( n -- n )
   {: code:n :}
   code E-STAGE-READ = if E-IO exit then
   code ;

: HASH-READ ( -- )
   FS:ERRNO {: e:n :}
   E-HASH-READ e QUIET? 0= if
      LOG-OPEN
      s" could not read bytes while computing the Dropbox content hash"
      LOG:TEXT+ e ERRNO+ LOG:;LINE
   then
   e FS:CAUSE! E-HASH-READ throw ;

\ The codes Habu's file and xattr words throw.
: FS-CODE? ( n -- bool )
   {: code:n :}
   code E-FFI-NUL = if true exit then
   code XATTR:E-XATTR = if true exit then
   code E-FS-LAST >= code E-FS-FIRST <= and ;

\ Every failure fail throws for an E-XATTR restates the one XATTR logged:
\ XATTR logs each E-XATTR an attribute name LOCAL passes can draw.
: XATTR-LOGGED? ( n n -- bool ) 2drop true ;

\ Runs q from a clear FS:ERRNO; an FS code it throws runs fail, which
\ throws LOCAL's code in its place, logged unless XATTR logged it.
: FS-FAILS ( R [ R -- R ] [ -- ] -- R )
   {: q fail :}
   0 FS:CAUSE!
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   code FS-CODE? if
      code XATTR:E-XATTR = if
         fail ['] XATTR-LOGGED? CONVERTING {: c:n :}
         c 0<> if c throw then
      else fail execute then
   then
   code throw ;

\ Closes a descriptor, keeping FS:ERRNO; as Rust's drop of a File, it
\ ignores close's own failure.
: DISCARD ( fd -- ) FD>N close ;

\ Runs q; a throw closes fd before it goes on, a return leaves it open.
: CLOSING ( R fd [ R -- R ] -- R )
   {: f:fd q :}
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   f DISCARD code throw ;

\ ---- stat

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

\ A descriptor and its stat, as Rust's (File, Stat).
STRUCTURE opened
   FIELD fd fd
   FIELD stat stat
;STRUCTURE

\ A file opened and hashed, as Rust's (File, ContentIdentity,
\ LocalFileFingerprint).
STRUCTURE hashed
   FIELD fd fd
   FIELD content DROPBOX:hash
   FIELD fingerprint MODEL:fingerprint
;STRUCTURE

\ The seeds a guarded word replaces, and their typed drops.
: NO-STAT ( -- stat ) 0 0 0 0 0 0 0 0 STAT-MAKE ;
: NO-HASH ( -- DROPBOX:hash ) s" " >str DROPBOX:>HASH ;
: NO-FINGERPRINT ( -- MODEL:fingerprint )
   0 0 0 0 0 0 MODEL-FINGERPRINT:MAKE ;
: DROP-STAT ( stat -- ) drop ;
: DROP-HASH ( DROPBOX:hash -- ) drop ;
: DROP-FINGERPRINT ( MODEL:fingerprint -- ) drop ;

: STAT-FD-FAILS ( fd ^u8 n ^u8 n n -- stat )
   {: f:fd p:^ u:n o:^ ou:n code:n :}
   [: f FS:FD-STAT ;] [: o ou p u code IO-FAILS ;] FS-FAILS
   FS:STAT-DEV@ FS:STAT-INO@ FS:STAT-MODE@ FS:STAT-SIZE@
   FS:STAT-MTIME-SEC@ FS:STAT-MTIME-NS@
   FS:STAT-CTIME-SEC@ FS:STAT-CTIME-NS@ STAT-MAKE ;

: STAT-FD ( fd ^u8 n ^u8 n -- stat ) E-IO STAT-FD-FAILS ;

: REGULAR? ( stat -- bool )
   STAT-UNMAKE {: d i m s ms mn cs cn :}
   m FS:S-IFMT and FS:S-IFREG = ;

: SAME-INODE ( stat stat -- bool )
   {: a:stat b:stat :}
   a STAT-UNMAKE {: d i m s ms mn cs cn :}
   b STAT-UNMAKE {: d2 i2 m2 s2 ms2 mn2 cs2 cn2 :}
   d d2 = i i2 = and ;

: SAME-OBSERVATION ( stat stat -- bool )
   {: a:stat b:stat :}
   a b SAME-INODE 0= if false exit then
   a STAT-UNMAKE {: d i m s ms mn cs cn :}
   b STAT-UNMAKE {: d2 i2 m2 s2 ms2 mn2 cs2 cn2 :}
   s s2 = ms ms2 = and mn mn2 = and cs cs2 = and cn cn2 = and ;

: SAME-HASHED-CONTENT ( MODEL:fingerprint MODEL:fingerprint -- bool )
   {: a:MODEL:fingerprint b:MODEL:fingerprint :}
   a MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   b MODEL-FINGERPRINT:UNMAKE {: i2 s2 ms2 mn2 cs2 cn2 :}
   i i2 = s s2 = and ms ms2 = and mn mn2 = and ;

: FILE-FINGERPRINT ( stat ^u8 n -- MODEL:fingerprint )
   {: st:stat p:^ u:n :}
   st STAT-UNMAKE {: d i m s ms mn cs cn :}
   s 0 < if 0 s" inspect local file size" p u SYSCALL-FAILURE then
   i s ms mn cs cn MODEL-FINGERPRINT:MAKE ;

\ ---- content hashes

TYPED-VARIABLE HASHER DROPBOX:hasher
IO-SIZE BUFFER: IO-BUF

\ Copies the bytes into the arena.
: KEEP ( ^u8 n ^ARENA:arena -- str )
   {: p:^ u:n ar:^ARENA:arena :}
   ar u ARENA:ALLOC drop {: dst:^ :}
   p dst u BYTE-COPY dst u >str ;

\ Dropbox's content hash of what read gives: read fills the span it is
\ handed and answers the bytes it put there, 0 at the end. The hasher
\ composes each 4 MiB block's digest.
: HASH-STREAM ( [ ^u8 n -- n ] ^ARENA:arena -- DROPBOX:hash )
   {: read ar:^ARENA:arena :}
   HASHER DROPBOX:HASH-BEGIN
   begin IO-BUF IO-SIZE read execute dup 0 > while
      IO-BUF swap HASHER DROPBOX:HASH-FEED
   repeat drop
   HASHER DROPBOX:HASH-END ar KEEP DROPBOX:>HASH ;

public

\ Fills the span from fd and answers its length, or at fd's end the bytes
\ read before it: the read HASH-STREAM and the stage words take.
: FD-READ ( fd ^u8 n -- n )
   {: f:fd p:^ u:n :}
   f p u SPAN:MAKE FD:READ-EXACT MATCH FD:fill
      full OF u ENDOF
      eof OF ENDOF
   ;MATCH ;

private

: HASH-FD ( fd ^ARENA:arena -- DROPBOX:hash )
   {: f:fd ar:^ARENA:arena :}
   [: f -rot FD-READ ;] ar HASH-STREAM ;

public

\ The content hash of fd's bytes from its offset to its end.
: DROPBOX-CONTENT-HASH ( fd ^ARENA:arena -- DROPBOX:hash )
   {: f:fd ar:^ARENA:arena :}
   NO-HASH [: DROP-HASH f ar HASH-FD ;] [: HASH-READ ;] FS-FAILS ;

private

: REWIND ( fd ^u8 n -- )
   {: f:fd p:^ u:n :}
   [: f 0 FD:SEEK ;]
   [: s" rewind file before hashing" p u IO-FAILURE ;] FS-FAILS ;

\ The content hash of fd's bytes from its start; a read failure is o's.
: HASH-READS ( fd ^u8 n ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: f:fd p:^ u:n o:^ ou:n ar:^ARENA:arena :}
   f p u REWIND
   NO-HASH [: DROP-HASH f ar HASH-FD ;] [: o ou p u IO-FAILURE ;]
   FS-FAILS ;

\ The hash of a regular file whose stat after the read is the one given;
\ a file not regular throws the first code, a changed one the second.
: HASH-STABLE-FILE-FROM-STAT
   ( fd ^u8 n ^u8 n stat ^ARENA:arena n n
     -- DROPBOX:hash MODEL:fingerprint )
   {: f:fd p:^ u:n o:^ ou:n before:stat ar:^ARENA:arena
      unsupported:n changed:n :}
   before REGULAR? 0= if p u unsupported UNSUPPORTED-FAILS then
   before p u FILE-FINGERPRINT {: print:MODEL:fingerprint :}
   f p u o ou ar HASH-READS {: c:DROPBOX:hash :}
   before f p u o ou STAT-FD SAME-OBSERVATION 0= if
      o ou p u changed CHANGED-FAILS
   then
   c print ;

: HASH-STABLE-FILE-WITH-FINGERPRINT
   ( fd ^u8 n ^u8 n ^ARENA:arena n n -- DROPBOX:hash MODEL:fingerprint )
   {: f:fd p:^ u:n o:^ ou:n ar:^ARENA:arena unsupported:n changed:n :}
   f p u o ou STAT-FD {: before:stat :}
   f p u o ou before ar unsupported changed HASH-STABLE-FILE-FROM-STAT ;

: HASH-STABLE-FILE ( fd ^u8 n ^u8 n ^ARENA:arena n n -- DROPBOX:hash )
   HASH-STABLE-FILE-WITH-FINGERPRINT
   {: c:DROPBOX:hash print:MODEL:fingerprint :} c ;

: HEX-LOWER? ( n -- bool )
   {: c:n :}
   c $30 >= c $39 <= and c $61 >= c $66 <= and or ;

: VALID-CONTENT-HASH? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 64 <> if false exit then
   u 0 ?do p i + c@ HEX-LOWER? 0= if false unloop exit then loop
   true ;

\ o names the operation that needs the hash.
: REQUIRE-CONTENT-HASH ( DROPBOX:hash ^u8 n -- )
   {: h:DROPBOX:hash o:^ ou:n :}
   h DROPBOX:HASH>STR str> VALID-CONTENT-HASH? 0= if
      o ou INVALID-HASH
   then ;

\ ---- names

SHA256-CTX-BYTES BUFFER: NAME-CTX
32 BUFFER: NAME-DIGEST
1 BUFFER: NUL

: FEED ( ^u8 n -- ) {: p:^ u:n :} NAME-CTX p u SHA256-FEED ;

\ Copies the bytes to dst at offset at; answers the offset after them.
: PUT ( ^u8 n ^u8 n -- n )
   {: p:^ u:n dst:^ at:n :}
   p dst at + u BYTE-COPY at u + ;

\ ".omabox-<prefix>-" and the hex SHA-256 of the prefix, the path and
\ the content, each NUL-separated; laid in the arena.
: INTERNAL-NAME ( ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: x:^ xu:n p:^ u:n c:DROPBOX:hash ar:^ARENA:arena :}
   NAME-CTX SHA256-BEGIN
   x xu FEED NUL 1 FEED p u FEED NUL 1 FEED c DROPBOX:HASH>STR str> FEED
   NAME-CTX NAME-DIGEST SHA256-END
   ar 8 xu + 1+ 64 + ARENA:ALLOC {: dst:^ size:n :}
   s" .omabox-" dst 0 PUT {: at:n :}
   x xu dst at PUT {: at2:n :}
   s" -" dst at2 PUT {: at3:n :}
   NAME-DIGEST dst at3 + SHA256>HEX
   dst size ;

: PREFIXED-HASH? ( ^u8 n ^u8 n -- bool )
   {: p:^ u:n x:^ xu:n :}
   u xu < if false exit then
   p xu x xu STR= 0= if false exit then
   p xu + u xu - VALID-CONTENT-HASH? ;

\ A name only LOCAL makes: a download, displaced or deleted file's.
: RESERVED-ARTIFACT? ( ^u8 n -- bool )
   {: p:^ u:n :}
   p u s" .omabox-download-" PREFIXED-HASH? if true exit then
   p u s" .omabox-displaced-" PREFIXED-HASH? if true exit then
   p u s" .omabox-deleted-" PREFIXED-HASH? ;

: CONFLICT-NAME
   ( ^u8 n conflict-side DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: p:^ u:n side:conflict-side c:DROPBOX:hash ar:^ARENA:arena :}
   side MATCH conflict-side
      local OF s" conflict-local" ENDOF
      remote OF s" conflict-remote" ENDOF
   ;MATCH p u c ar INTERNAL-NAME ;

\ ---- relative paths

: SKIP-SEPS ( ^u8 n n -- n )
   {: p:^ u:n at:n :}
   at begin dup u < while
      p over + c@ SLASH <> if exit then
      1+
   repeat ;

: COMPONENT-END ( ^u8 n n -- n )
   {: p:^ u:n at:n :}
   at begin dup u < while
      p over + c@ SLASH = if exit then
      1+
   repeat ;

: CURRENT? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 1 = if p c@ DOT = exit then
   false ;

: PARENT? ( ^u8 n -- bool )
   {: p:^ u:n :}
   u 2 = if p c@ DOT = p 1+ c@ DOT = and exit then
   false ;

\ Whether the path starts with Rust's CurDir component.
: LEADING-DOT? ( ^u8 n -- bool )
   {: p:^ u:n :}
   p c@ DOT <> if false exit then
   u 1 = if true exit then
   p 1+ c@ SLASH = ;

\ The next component from at on that is neither empty nor ".": its start,
\ its end and true; u u false past the last.
: NEXT-COMPONENT ( ^u8 n n -- n n bool )
   {: p:^ u:n at:n :}
   p u at SKIP-SEPS {: from:n :}
   from u >= if u u false exit then
   p u from COMPONENT-END {: to:n :}
   p from + to from - CURRENT? if p u to RECURSE exit then
   from to true ;

\ The components from at on, counted onto count; ".." is unsafe.
: TALLY ( ^u8 n n n -- n )
   {: p:^ u:n count:n at:n :}
   p u at NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if count exit then
   p from + to from - PARENT? if p u UNSAFE then
   p u count 1+ to RECURSE ;

\ Rust's safe_components: throws E-UNSAFE-PATH for an unsafe path, else
\ answers its count of components.
: SAFE-COMPONENTS ( ^u8 n -- n )
   {: p:^ u:n :}
   u 0= if p u UNSAFE then
   p c@ SLASH = if p u UNSAFE then
   p u LEADING-DOT? if p u UNSAFE then
   p u 0 0 TALLY ;

: LAST-FROM ( ^u8 n n n n -- n n n )
   {: p:^ u:n prev:n from:n to:n :}
   p u to NEXT-COMPONENT {: from2:n to2:n found:bool :}
   found 0= if prev from to exit then
   p u to from2 to2 RECURSE ;

\ Rust's split_last over a safe path's components: the bytes of the
\ parent, then the last component's start and end.
: SPLIT-LAST ( ^u8 n -- n n n )
   {: p:^ u:n :}
   p u 0 NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if p u UNSAFE then
   p u 0 from to LAST-FROM ;

\ The safe path's parent, a prefix of it, empty for a top-level name.
: PARENT-PATH ( ^u8 n -- ^u8 n )
   {: p:^ u:n :}
   p u SAFE-COMPONENTS drop
   p u SPLIT-LAST 2drop {: len:n :}
   p len ;

\ ---- opens

\ Opens the components of p before u from dir, which it then closes, each
\ by O_PATH: some, or none with FS:ERRNO set; and the offset past the
\ last component it tried.
: DESCEND ( fd ^u8 n n -- option<fd> n )
   {: dir:fd p:^ u:n at:n :}
   p u at NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if dir OPTION:SOME at exit then
   dir p from + to from - FS:TRY-OPEN-ENTRY-AT dir DISCARD
   MATCH option
      none OF OPTION:NONE to ENDOF
      some OF p u to RECURSE ENDOF
   ;MATCH ;

\ DESCEND from the root, which stays open; p holds a component.
: WALK ( fd ^u8 n -- option<fd> n )
   {: root:fd p:^ u:n :}
   p u 0 NEXT-COMPONENT {: from:n to:n found:bool :}
   root p from + to from - FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF OPTION:NONE to ENDOF
      some OF p u to DESCEND ENDOF
   ;MATCH ;

: OPEN-ABSOLUTE-DIRECTORY ( ^u8 n ^u8 n -- fd )
   {: p:^ u:n o:^ ou:n :}
   u 0= if p u UNSAFE then
   p c@ SLASH <> if p u UNSAFE then
   -1 >FD [: drop p u FS:OPEN-DIR ;] [: o ou p u IO-FAILURE ;] FS-FAILS ;

public

\ The sync root's directory, o naming the operation that opens it.
: OPEN-ROOT ( ^u8 n ^u8 n -- fd ) OPEN-ABSOLUTE-DIRECTORY ;

: OPEN-PRIVATE-DIRECTORY ( ^u8 n ^u8 n -- fd ) OPEN-ABSOLUTE-DIRECTORY ;

private

\ A probe that failed confirms nothing, unless the system ran out of a
\ resource, which says nothing about the entry.
: UNCONFIRMED ( ^u8 n -- bool )
   {: p:^ u:n :}
   FS:ERRNO EXHAUSTED? if
      s" probe local entry existence" p u IO-FAILURE
   then false ;

\ Whether dir holds the name, closing dir unless it is the root.
: PRESENT-IN? ( fd bool ^u8 n ^u8 n -- bool )
   {: dir:fd owned:bool name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-STAT-AT
   owned if dir DISCARD then
   if true exit then
   p u UNCONFIRMED ;

public

\ Whether an entry is at the path below the root now, a symlink itself
\ included; its parents are never followed through a symlink.
: ENTRY-EXISTS-AT ( fd ^u8 n -- bool )
   {: root:fd p:^ u:n :}
   p u SAFE-COMPONENTS drop
   p u SPLIT-LAST {: parent:n from:n to:n :}
   p from + to from - {: name:^ nu:n :}
   parent 0= if root false name nu p u PRESENT-IN? exit then
   root p parent WALK {: o:option<fd> at:n :}
   o MATCH option
      none OF p at UNCONFIRMED ENDOF
      some OF true name nu p u PRESENT-IN? ENDOF
   ;MATCH ;

private

\ Opens p's last component for reading below the root.
: OPEN-BELOW ( fd ^u8 n -- option<fd> )
   {: root:fd p:^ u:n :}
   p u SPLIT-LAST {: parent:n from:n to:n :}
   p from + to from - {: name:^ nu:n :}
   parent 0= if root name nu FS:TRY-OPEN-READ-AT exit then
   root p parent WALK drop MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: dir:fd :} dir name nu FS:TRY-OPEN-READ-AT dir DISCARD
      ENDOF
   ;MATCH ;

\ A failed stat throws the first code, a file not regular the second.
: CHECK-REGULAR ( fd ^u8 n ^u8 n n n -- stat )
   {: f:fd p:^ u:n o:^ ou:n io:n unsupported:n :}
   f p u o ou io STAT-FD-FAILS {: st:stat :}
   st REGULAR? 0= if p u unsupported UNSUPPORTED-FAILS then
   st ;

\ The stat of the regular file at fd, CHECK-REGULAR's codes given; a throw
\ closes fd.
: REGULAR-STAT ( fd ^u8 n ^u8 n n n -- stat )
   {: f:fd p:^ u:n o:^ ou:n io:n unsupported:n :}
   NO-STAT f [: DROP-STAT f p u o ou io unsupported CHECK-REGULAR ;]
   CLOSING ;

\ A failed open or stat throws the first code, a file not regular the
\ second.
: OPEN-RELATIVE-REGULAR-WITH-STAT ( fd ^u8 n ^u8 n n n -- fd stat )
   {: root:fd p:^ u:n o:^ ou:n io:n unsupported:n :}
   p u SAFE-COMPONENTS drop
   root p u OPEN-BELOW MATCH option
      none OF o ou p u io IO-FAILS ENDOF
      some OF {: f:fd :} f f p u o ou io unsupported REGULAR-STAT ENDOF
   ;MATCH ;

: OPEN-RELATIVE-REGULAR ( fd ^u8 n ^u8 n n n -- fd )
   OPEN-RELATIVE-REGULAR-WITH-STAT {: f:fd st:stat :} f ;

\ Rust's open_relative_at with O_RDONLY|O_NONBLOCK, the flags its one
\ caller passes, which FS:TRY-OPEN-READ-AT sets.
: OPEN-RELATIVE-AT ( fd ^u8 n ^u8 n -- fd )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-OPEN-READ-AT MATCH option
      none OF s" open root-confined file" p u IO-FAILURE ENDOF
      some OF ENDOF
   ;MATCH ;

: NO-DIRECTORY ( ^u8 n -- )
   {: p:^ u:n :}
   s" open root-confined directory" p u IO-FAILURE ;

: OPEN-DIRECTORY-AT ( fd ^u8 n ^u8 n -- fd )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-OPEN-DIR-AT MATCH option
      none OF p u NO-DIRECTORY ENDOF
      some OF ENDOF
   ;MATCH ;

\ What a name holds: nothing, a regular file open for reading, an object
\ not a regular file, or a file Omabox cannot read.
ENUM name-entry
   VARIANT absent ;VARIANT
   VARIANT regular FIELD file opened ;VARIANT
   VARIANT unsupported ;VARIANT
   VARIANT unreadable ;VARIANT
;ENUM

\ A failed open is an io failure unless nothing is at the name.
: MISSING-OR-FAILS ( ^u8 n ^u8 n -- )
   {: p:^ u:n o:^ ou:n :}
   FS:ERRNO FS:ENOENT <> if o ou p u IO-FAILURE then ;

\ The stat of the open entry; a failed stat closes it.
: STAT-CLOSING ( fd ^u8 n ^u8 n -- stat )
   {: f:fd p:^ u:n o:^ ou:n :}
   NO-STAT f [: DROP-STAT f p u o ou STAT-FD ;] CLOSING ;

\ Whether the probed entry is a regular file; closes the probe.
: PROBED-REGULAR? ( fd ^u8 n ^u8 n -- bool )
   {: probe:fd p:^ u:n o:^ ou:n :}
   probe p u o ou STAT-CLOSING probe DISCARD REGULAR? ;

\ The entry open for reading, closed unless it is a regular file.
: OPENED-ENTRY ( fd ^u8 n ^u8 n -- name-entry )
   {: f:fd p:^ u:n o:^ ou:n :}
   f p u o ou STAT-CLOSING {: st:stat :}
   st REGULAR? 0= if f DISCARD NAME-ENTRY-UNSUPPORTED exit then
   f st OPENED-MAKE NAME-ENTRY-REGULAR ;

: OPEN-READ ( fd ^u8 n ^u8 n ^u8 n -- name-entry )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu FS:TRY-OPEN-READ-AT MATCH option
      none OF FS:ERRNO FS:EACCES = if NAME-ENTRY-UNREADABLE
         else p u o ou MISSING-OR-FAILS NAME-ENTRY-ABSENT then
      ENDOF
      some OF p u o ou OPENED-ENTRY ENDOF
   ;MATCH ;

\ What the name holds, probed without following a symlink, then opened
\ for reading when a regular file is there.
: OPEN-NAMED ( fd ^u8 n ^u8 n ^u8 n -- name-entry )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF p u o ou MISSING-OR-FAILS NAME-ENTRY-ABSENT ENDOF
      some OF {: probe:fd :}
         probe p u o ou PROBED-REGULAR? if
            dir name nu p u o ou OPEN-READ
         else NAME-ENTRY-UNSUPPORTED then
      ENDOF
   ;MATCH ;

\ The regular file at the name, none when nothing is there; another
\ object throws E-UNSUPPORTED, a file Omabox cannot read E-UNREADABLE.
: OPEN-REGULAR-AT-IF-PRESENT
   ( fd ^u8 n ^u8 n ^u8 n -- option<opened> )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu p u o ou OPEN-NAMED MATCH name-entry
      absent OF OPTION:NONE ENDOF
      regular OF OPTION:SOME ENDOF
      unsupported OF p u E-UNSUPPORTED UNSUPPORTED-FAILS ENDOF
      unreadable OF p u UNREADABLE ENDOF
   ;MATCH ;

\ Hashes the opened file, closing it on a throw.
: HASH-OPENED ( opened ^u8 n ^u8 n ^ARENA:arena -- hashed )
   {: x:opened p:^ u:n o:^ ou:n ar:^ARENA:arena :}
   x OPENED-UNMAKE {: f:fd st:stat :}
   NO-HASH NO-FINGERPRINT f
   [: DROP-FINGERPRINT DROP-HASH f p u o ou st ar E-UNSUPPORTED E-CHANGED
      HASH-STABLE-FILE-FROM-STAT ;] CLOSING
   {: c:DROPBOX:hash print:MODEL:fingerprint :}
   f c print HASHED-MAKE ;

: OPEN-AND-HASH-IF-PRESENT
   ( fd ^u8 n ^u8 n ^u8 n ^ARENA:arena -- option<hashed> )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n ar:^ARENA:arena :}
   dir name nu p u o ou OPEN-REGULAR-AT-IF-PRESENT MATCH option
      none OF OPTION:NONE ENDOF
      some OF p u o ou ar HASH-OPENED OPTION:SOME ENDOF
   ;MATCH ;

: HASH-AT-IF-PRESENT
   ( fd ^u8 n ^u8 n ^u8 n ^ARENA:arena -- option<DROPBOX:hash> )
   OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF OPTION:NONE ENDOF
      some OF HASHED-UNMAKE
         {: f:fd c:DROPBOX:hash print:MODEL:fingerprint :}
         f DISCARD c OPTION:SOME
      ENDOF
   ;MATCH ;

\ The open regular file at the name and its hash; none there is ENOENT.
: OPEN-AND-HASH-AT
   ( fd ^u8 n ^u8 n ^u8 n ^ARENA:arena -- fd DROPBOX:hash )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n ar:^ARENA:arena :}
   dir name nu p u o ou ar OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF FS:ENOENT o ou p u SYSCALL-FAILURE ENDOF
      some OF HASHED-UNMAKE
         {: f:fd c:DROPBOX:hash print:MODEL:fingerprint :}
         f c
      ENDOF
   ;MATCH ;

\ Whether the name's entry is file's inode; a symlink there is another.
: NAMED-INODE-MATCHES ( fd fd ^u8 n ^u8 n -- bool )
   {: file:fd dir:fd name:^ nu:n p:^ u:n :}
   file p u s" inspect held local entry" STAT-FD {: held:stat :}
   dir name nu FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF FS:ERRNO FS:ENOENT <> if
            s" inspect named local entry" p u IO-FAILURE
         then false
      ENDOF
      some OF {: e:fd :}
         NO-STAT e
         [: DROP-STAT e p u s" inspect named local entry" STAT-FD ;] CLOSING
         e DISCARD held SAME-INODE
      ENDOF
   ;MATCH ;

: SYNC-DIRECTORY ( fd ^u8 n ^u8 n -- )
   {: f:fd p:^ u:n o:^ ou:n :}
   [: f FD:SYNC ;] [: o ou p u IO-FAILURE ;] FS-FAILS ;

: SYNC-FILE ( fd ^u8 n ^u8 n -- ) SYNC-DIRECTORY ;

\ Syncs the regular file at the name and its entry; none there is a
\ change.
: SYNC-INSTALLED-FILE ( fd ^u8 n ^u8 n -- )
   {: dir:fd name:^ nu:n p:^ u:n :}
   s" open installed file for sync" {: o:^ ou:n :}
   dir name nu p u o ou OPEN-REGULAR-AT-IF-PRESENT MATCH option
      none OF o ou p u CHANGED ENDOF
      some OF OPENED-UNMAKE {: f:fd st:stat :}
         [: f p u s" sync installed file" SYNC-FILE ;] [: f DISCARD ;]
         finally
      ENDOF
   ;MATCH
   dir p u s" sync installed file entry" SYNC-DIRECTORY ;

\ ---- the scan

\ Seconds a hash's file must have kept still before the cache may reuse
\ the hash: more than FAT's two-second mtime tick. The cache needs coherent
\ local metadata; stale network metadata is not supported.
3 constant RACY-WINDOW
1000000000 constant NS-PER-S

\ The time a reusable hash's file was last changed before.
STRUCTURE cutoff
   FIELD seconds n
   FIELD nanoseconds n
;STRUCTURE

\ A directory the walk listed, and its stat before the listing.
STRUCTURE scanned-directory
   FIELD path str
   FIELD before stat
;STRUCTURE

\ A file the walk found and no cached hash covers.
STRUCTURE hash-job
   FIELD path str
   FIELD fingerprint MODEL:fingerprint
;STRUCTURE

STRUCTURE scanned-hash
   FIELD record MODEL:hash-record
   FIELD reusable bool
;STRUCTURE

\ The hashes a stage confirmed, and the files it could not observe again.
STRUCTURE scan-hash-results
   FIELD records ^VEC:vector<scanned-hash>
   FIELD unknown ^VEC:vector<MODEL:local-record>
;STRUCTURE

\ Every collection's count before one entry was scanned. The walk is depth
\ first, so what an entry adds is a suffix of each, which one truncation
\ discards.
STRUCTURE scan-mark
   FIELD observations n
   FIELD cached-files n
   FIELD directories n
   FIELD hash-jobs n
;STRUCTURE

\ What the walk collects; retained holds cached hashes it validated beneath
\ an entry it later discarded.
STRUCTURE scan-entries
   FIELD observations ^VEC:vector<MODEL:local-record>
   FIELD cached-files ^VEC:vector<MODEL:hash-record>
   FIELD retained ^VEC:vector<MODEL:hash-record>
   FIELD directories ^VEC:vector<scanned-directory>
   FIELD hash-jobs ^VEC:vector<hash-job>
;STRUCTURE

\ What every step of the walk reads and none changes. A directory on a
\ device other than root-device, the sync root's, is out of scope.
STRUCTURE scan-context
   FIELD cache ^VEC:vector<MODEL:hash-record>
   FIELD cutoff option<cutoff>
   FIELD root-device n
   FIELD arena ^ARENA:arena
;STRUCTURE

\ An enumerated root whose files are still to hash; it owns root-fd.
STRUCTURE pending-scan
   FIELD root str
   FIELD root-fd fd
   FIELD root-before stat
   FIELD entries scan-entries
   FIELD arena ^ARENA:arena
;STRUCTURE

public

\ A complete local inventory, safe to publish for absence decisions: its
\ observations and the hashes a later scan may reuse, each in path-byte
\ order. The root binding the journal stores beside it is JOURNAL's.
STRUCTURE complete-scan OPAQUE
   FIELD observations ^VEC:vector<MODEL:local-record>
   FIELD reusable-hashes ^VEC:vector<MODEL:hash-record>
;STRUCTURE

\ Published while the scanned root still is the active journal
\ generation's; root-changed when the configured path names another.
ENUM scan-publication
   VARIANT published FIELD scan complete-scan ;VARIANT
   VARIANT root-changed ;VARIANT
;ENUM

: SCAN-OBSERVATIONS ( complete-scan -- ^VEC:vector<MODEL:local-record> )
   COMPLETE-SCAN-UNMAKE drop ;

private

\ ---- the hash cache's cutoff

\ Rust's hash_cache_cutoff, from seconds since the epoch: Habu's clock reads
\ no finer, and the second's start only makes fewer hashes reusable.
: HASH-CACHE-CUTOFF ( n -- option<cutoff> )
   {: now:n :}
   now RACY-WINDOW - {: s:n :}
   s 0 < if OPTION:NONE exit then
   s 0 CUTOFF-MAKE OPTION:SOME ;

: TIMESTAMP-IS-BEFORE ( n n cutoff -- bool )
   {: s:n ns:n c:cutoff :}
   c CUTOFF-UNMAKE {: cs:n cns:n :}
   ns 0 < ns NS-PER-S >= or if false exit then
   s cs < if true exit then
   s cs = ns cns < and ;

: RECORD-FINGERPRINT ( MODEL:hash-record -- MODEL:fingerprint )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :} f ;

: RECORD-CONTENT ( MODEL:hash-record -- DROPBOX:hash )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :} c ;

: RECORD-PATH ( MODEL:hash-record -- ^u8 n )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :}
   p MODEL:PATH>STR str> ;

: HASH-IS-REUSABLE ( MODEL:hash-record option<cutoff> -- bool )
   {: r:MODEL:hash-record o:option<cutoff> :}
   r RECORD-FINGERPRINT MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   o MATCH option
      none OF false ENDOF
      some OF {: c:cutoff :}
         ms mn c TIMESTAMP-IS-BEFORE cs cn c TIMESTAMP-IS-BEFORE and
      ENDOF
   ;MATCH ;

: NO-CUTOFF ( -- option<cutoff> ) OPTION:NONE ;

: CURRENT-HASH-CACHE-CUTOFF ( -- option<cutoff> )
   epoch-seconds HASH-CACHE-CUTOFF ;

\ ---- the walk's collections

: NEW-VEC ( ^ARENA:arena width<t> -- ^VEC:vector<t> )
   {: ar:^ARENA:arena w :}
   ar ARENA:ALLOCATOR 0 w VEC:NEW ;

: NEW-ENTRIES ( ^ARENA:arena -- scan-entries )
   {: ar:^ARENA:arena :}
   ar [type] MODEL:local-record NEW-VEC
   ar [type] MODEL:hash-record NEW-VEC
   ar [type] MODEL:hash-record NEW-VEC
   ar [type] scanned-directory NEW-VEC
   ar [type] hash-job NEW-VEC
   SCAN-ENTRIES-MAKE ;

: OBSERVED ( scan-entries -- ^VEC:vector<MODEL:local-record> )
   SCAN-ENTRIES-UNMAKE {: o c r d j :} o ;

: CACHED ( scan-entries -- ^VEC:vector<MODEL:hash-record> )
   SCAN-ENTRIES-UNMAKE {: o c r d j :} c ;

: DIRECTORIES ( scan-entries -- ^VEC:vector<scanned-directory> )
   SCAN-ENTRIES-UNMAKE {: o c r d j :} d ;

: JOBS ( scan-entries -- ^VEC:vector<hash-job> )
   SCAN-ENTRIES-UNMAKE {: o c r d j :} j ;

: MARK ( scan-entries -- scan-mark )
   SCAN-ENTRIES-UNMAKE {: o c r d j :}
   o VEC:COUNT c VEC:COUNT d VEC:COUNT j VEC:COUNT SCAN-MARK-MAKE ;

\ A cached hash was validated against the file it names before the walk
\ met the entry that failed, so it moves to retained: dropping it would
\ rehash an untouched subtree on every later pass.
: TRUNCATE ( scan-entries scan-mark -- )
   {: en:scan-entries mk:scan-mark :}
   en SCAN-ENTRIES-UNMAKE {: o c r d j :}
   mk SCAN-MARK-UNMAKE {: mo:n mc:n md:n mj:n :}
   o mo VEC:RESIZE
   mc c VEC:COUNT min {: kept:n :}
   c VEC:COUNT kept ?do c i VEC:AT @ r VEC:PUSH ! loop
   c kept VEC:RESIZE
   d md VEC:RESIZE
   j mj VEC:RESIZE ;

: UNKNOWN-OBSERVATION
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:unknown ;

: DIRECTORY-OBSERVATION ( -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:directory ;

: PRESENT-OBSERVATION ( MODEL:local -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:present ;

: UNKNOWN-RECORD ( str MODEL:unknown-reason -- MODEL:local-record )
   {: p:str why:MODEL:unknown-reason :}
   p MODEL:>PATH why UNKNOWN-OBSERVATION MODEL-LOCAL--RECORD:MAKE ;

: UNKNOWN ( scan-entries str MODEL:unknown-reason -- )
   {: en:scan-entries p:str why:MODEL:unknown-reason :}
   p why UNKNOWN-RECORD en OBSERVED VEC:PUSH ! ;

\ ---- order

: KEY-LESS ( n n [ n -- ^u8 n ] -- bool )
   {: a:n b:n key :}
   a key execute b key execute STR< ;

\ The indices below count in the byte order of the keys key answers for
\ them.
: ORDER ( n [ n -- ^u8 n ] ^ARENA:arena -- ^VEC:vector<n> )
   {: count:n key ar:^ARENA:arena :}
   ar ARENA:ALLOCATOR count [type] n VEC:NEW {: idx :}
   count 0 ?do i idx i VEC:AT ! loop
   count 2 < if idx exit then
   idx 0 VEC:AT count [: key KEY-LESS ;] SORT:SORT!
   idx ;

: OBSERVATION-PATH ( MODEL:local-record -- ^u8 n )
   MODEL-LOCAL--RECORD:UNMAKE
   {: p:MODEL:path o:MODEL:observation<MODEL:local> :}
   p MODEL:PATH>STR str> ;

: OBSERVATION-PATH@ ( ^MODEL:local-record -- ^u8 n ) @ OBSERVATION-PATH ;

: RECORD-PATH@ ( ^MODEL:hash-record -- ^u8 n ) @ RECORD-PATH ;

: STR@ ( ^str -- ^u8 n ) @ str> ;

\ Rust's order_observations: path bytes, the order SQLite keeps.
: ORDER-OBSERVATIONS
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena
     -- ^VEC:vector<MODEL:local-record> )
   {: v ar:^ARENA:arena :}
   v VEC:COUNT [: v swap VEC:AT OBSERVATION-PATH@ ;] ar ORDER {: idx :}
   ar [type] MODEL:local-record NEW-VEC {: out :}
   idx VEC:COUNT 0 ?do v idx i VEC:AT @ VEC:AT @ out VEC:PUSH ! loop
   out ;

\ Rust's order_hash_records: path bytes, the order of SQLite and
\ CACHED-HASH.
: ORDER-HASH-RECORDS
   ( ^VEC:vector<MODEL:hash-record> ^ARENA:arena
     -- ^VEC:vector<MODEL:hash-record> )
   {: v ar:^ARENA:arena :}
   v VEC:COUNT [: v swap VEC:AT RECORD-PATH@ ;] ar ORDER {: idx :}
   ar [type] MODEL:hash-record NEW-VEC {: out :}
   idx VEC:COUNT 0 ?do v idx i VEC:AT @ VEC:AT @ out VEC:PUSH ! loop
   out ;

\ Rust's cached_hash: the cache arrives in path-byte order, as JOURNAL's
\ LOCAL-HASH-CACHE answers it, so the search compares bytes.
: CACHED-HASH
   ( ^VEC:vector<MODEL:hash-record> ^u8 n -- option<MODEL:hash-record> )
   {: v p:^ u:n :}
   0 v VEC:COUNT [: v swap VEC:AT @ RECORD-PATH p u STR< ;]
   SORT:PARTITION-POINT {: at:n :}
   at v VEC:COUNT >= if OPTION:NONE exit then
   v at VEC:AT @ {: r:MODEL:hash-record :}
   r RECORD-PATH p u STR= 0= if OPTION:NONE exit then
   r OPTION:SOME ;

\ ---- the walk

: STAT-DEV ( stat -- n ) STAT-UNMAKE {: d i m s ms mn cs cn :} d ;

: DIRECTORY? ( stat -- bool )
   STAT-UNMAKE {: d i m s ms mn cs cn :}
   m FS:S-IFMT and FS:S-IFDIR = ;

: SAME-FINGERPRINT? ( MODEL:fingerprint MODEL:fingerprint -- bool )
   {: a:MODEL:fingerprint b:MODEL:fingerprint :}
   a b SAME-HASHED-CONTENT 0= if false exit then
   a MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   b MODEL-FINGERPRINT:UNMAKE {: i2 s2 ms2 mn2 cs2 cn2 :}
   cs cs2 = cn cn2 = and ;

\ p and the relative q joined as Rust's Path::join joins them, laid anew in
\ the arena; an empty q answers p, where Rust appends a "/".
: JOIN ( ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: p:^ u:n q:^ qu:n ar:^ARENA:arena :}
   u 0= qu 0= or p u FS:JOIN-SEPARATED? or {: bare:bool :}
   bare if 0 else 1 then {: sep:n :}
   ar u sep + qu + ARENA:ALLOC {: dst:^ size:n :}
   p u dst 0 PUT {: at:n :}
   s" /" drop sep dst at PUT {: at2:n :}
   q qu dst at2 PUT drop
   dst size ;

\ The name, the last component of a path below parent.
: NAME-OF ( str str -- ^u8 n )
   {: path:str parent:str :}
   path str> {: p:^ u:n :}
   parent str> nip {: pu:n :}
   pu 0= if p u exit then
   p pu 1+ + u pu 1+ - ;

\ The one directory listing open at a time: LIST-PATHS reads a directory
\ whole before its caller uses any entry in it.
create LISTING FS-LIST:STORAGE-BYTES allot

: LISTED ( fd str ^ARENA:arena ^VEC:vector<str> -- )
   {: dir:fd parent:str ar:^ARENA:arena v :}
   LISTING FS-LIST:STORAGE-BYTES SPAN:MAKE FS-LIST:INIT
   dir [: drop parent str> 2swap ar JOIN >str v VEC:PUSH ! ;]
   FS-LIST:EACH-TYPED-AT ;

: LIST-FAILURE ( n ^u8 n ^u8 n ^u8 n -- )
   {: code:n open:^ ou:n read:^ ru:n p:^ u:n :}
   code FS-LIST:E-OPEN = if open ou p u IO-FAILURE then
   code E-FS-LIST-LAST >= code E-FS-LIST-FIRST <= and if
      read ru p u IO-FAILURE
   then
   code throw ;

\ The paths of the entries in dir, but . and .., in the order listed; a
\ failed listing is an io failure named by the open or the read text.
: LIST-PATHS ( fd str ^u8 n ^u8 n ^ARENA:arena -- ^VEC:vector<str> )
   {: dir:fd parent:str open:^ ou:n read:^ ru:n ar:^ARENA:arena :}
   ar [type] str NEW-VEC {: v :}
   0 FS:CAUSE!
   [: dir parent ar v LISTED ;] catch {: code:n :}
   code 0<> if code open ou read ru parent str> LIST-FAILURE then
   v ;

: REUSABLE-CONTENT
   ( scan-context str MODEL:fingerprint -- option<DROPBOX:hash> )
   {: cx:scan-context path:str print:MODEL:fingerprint :}
   cx SCAN-CONTEXT-UNMAKE {: cache cut:option<cutoff> dev:n ar :}
   cache path str> CACHED-HASH MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: r:MODEL:hash-record :}
         r RECORD-FINGERPRINT print SAME-FINGERPRINT?
         r cut HASH-IS-REUSABLE and if
            r RECORD-CONTENT OPTION:SOME
         else OPTION:NONE then
      ENDOF
   ;MATCH ;

\ The file at f, opened where the probe found it, as a cached hash or a
\ file to hash.
: COLLECT-FILE ( fd str stat scan-context scan-entries -- )
   {: f:fd path:str probe:stat cx:scan-context en:scan-entries :}
   path str> {: p:^ u:n :}
   f p u s" inspect opened scan file" STAT-FD {: opened:stat :}
   probe opened SAME-INODE 0= if s" open scanned file" p u CHANGED then
   opened p u FILE-FINGERPRINT {: print:MODEL:fingerprint :}
   cx path print REUSABLE-CONTENT MATCH option
      some OF {: c:DROPBOX:hash :}
         path MODEL:>PATH print c MODEL-HASH--RECORD:MAKE
         en CACHED VEC:PUSH !
      ENDOF
      none OF path print HASH-JOB-MAKE en JOBS VEC:PUSH ! ENDOF
   ;MATCH ;

\ A special file put where the probe found a regular one would block a
\ plain read forever, so the open never waits and the inode check rejects
\ it.
: SCAN-FILE ( fd ^u8 n str stat scan-context scan-entries -- )
   {: dir:fd name:^ nu:n path:str probe:stat cx:scan-context
      en:scan-entries :}
   name nu RESERVED-ARTIFACT? if
      en path MODEL-UNKNOWN--REASON:unsupported UNKNOWN exit
   then
   dir name nu path str> OPEN-RELATIVE-AT {: f:fd :}
   [: f path probe cx en COLLECT-FILE ;] [: f DISCARD ;] finally ;

\ SCAN-DIRECTORY, which the walk reaches again below a directory.
defer SCAN-SUBTREE ( fd str scan-context scan-entries -- )

\ The directory's observation follows its subtree's, so a failure below
\ leaves it unpublished.
: COLLECT-DIRECTORY ( fd str stat scan-context scan-entries -- )
   {: child:fd path:str probe:stat cx:scan-context en:scan-entries :}
   path str> {: p:^ u:n :}
   child p u s" inspect opened scan directory" STAT-FD {: opened:stat :}
   probe opened SAME-INODE 0= if s" open scanned directory" p u CHANGED then
   child path cx en SCAN-SUBTREE
   path MODEL:>PATH DIRECTORY-OBSERVATION MODEL-LOCAL--RECORD:MAKE
   en OBSERVED VEC:PUSH ! ;

: SCAN-SUBDIRECTORY ( fd ^u8 n str stat scan-context scan-entries -- )
   {: dir:fd name:^ nu:n path:str probe:stat cx:scan-context
      en:scan-entries :}
   dir name nu path str> OPEN-DIRECTORY-AT {: child:fd :}
   [: child path probe cx en COLLECT-DIRECTORY ;] [: child DISCARD ;]
   finally ;

\ Content on another volume is never synchronized, so an object there is
\ published as a symlink is and nothing beneath it is observed.
: SCAN-PROBED ( fd fd ^u8 n str scan-context scan-entries -- )
   {: probe:fd dir:fd name:^ nu:n path:str cx:scan-context
      en:scan-entries :}
   probe path str> s" inspect directory entry type" STAT-FD {: st:stat :}
   cx SCAN-CONTEXT-UNMAKE {: cache cut:option<cutoff> dev:n ar :}
   st STAT-DEV dev <> if
      en path MODEL-UNKNOWN--REASON:unsupported UNKNOWN exit
   then
   st REGULAR? if dir name nu path st cx en SCAN-FILE exit then
   st DIRECTORY? if dir name nu path st cx en SCAN-SUBDIRECTORY exit then
   path str> E-UNSUPPORTED UNSUPPORTED-FAILS ;

\ Rust's scan_entry: collects one entry, or throws why it cannot be
\ observed, which SCAN-NAME publishes.
: SCAN-ENTRY ( fd ^u8 n str scan-context scan-entries -- )
   {: dir:fd name:^ nu:n path:str cx:scan-context en:scan-entries :}
   dir name nu FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF s" inspect directory entry" path str> IO-FAILURE ENDOF
      some OF {: probe:fd :}
         [: probe dir name nu path cx en SCAN-PROBED ;]
         [: probe DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ Rust's entry_unknown and io_unknown_reason: the reason code, thrown
\ while one entry was observed, publishes; wrong is what an object that is
\ not a regular file means to the caller. Any code ENTRY-CODE? does not
\ name is the scan's, rethrown.
: ENTRY-UNKNOWN ( n MODEL:unknown-reason -- MODEL:unknown-reason )
   {: code:n wrong:MODEL:unknown-reason :}
   code FS:ERRNO ENTRY-CODE? 0= if code throw then
   code E-UNSUPPORTED = if wrong exit then
   code E-CHANGED = if MODEL-UNKNOWN--REASON:incomplete exit then
   code E-UNREADABLE = if MODEL-UNKNOWN--REASON:inaccessible exit then
   FS:ERRNO REPLACED? if MODEL-UNKNOWN--REASON:incomplete exit then
   MODEL-UNKNOWN--REASON:inaccessible ;

\ Rust's walk_unknown: an entry the walk meets.
: WALK-UNKNOWN ( n -- MODEL:unknown-reason )
   MODEL-UNKNOWN--REASON:unsupported ENTRY-UNKNOWN ;

\ Rust's revisited_unknown: an object whose type the walk recorded, so a
\ different one now is a replacement.
: REVISITED-UNKNOWN ( n -- MODEL:unknown-reason )
   MODEL-UNKNOWN--REASON:incomplete ENTRY-UNKNOWN ;

\ One entry never fails the pass: it publishes as unknown, and all the walk
\ collected beneath it leaves this publication.
: SCAN-NAME ( fd str str scan-context scan-entries -- )
   {: dir:fd path:str parent:str cx:scan-context en:scan-entries :}
   path parent NAME-OF {: name:^ nu:n :}
   name nu MODEL:EXCLUDED-NAME? if exit then
   en MARK {: mk:scan-mark :}
   [: dir name nu path cx en SCAN-ENTRY ;] ['] ENTRY-CODE? CONVERTING
   {: code:n :}
   code 0= if exit then
   code WALK-UNKNOWN {: why:MODEL:unknown-reason :}
   en mk TRUNCATE
   en path why UNKNOWN ;

: SCAN-DIRECTORY ( fd str scan-context scan-entries -- )
   {: dir:fd path:str cx:scan-context en:scan-entries :}
   path str> {: p:^ u:n :}
   cx SCAN-CONTEXT-UNMAKE {: cache cut:option<cutoff> dev:n ar :}
   dir p u s" inspect directory before scan" STAT-FD {: before:stat :}
   dir path s" open directory stream" s" read directory" ar LIST-PATHS
   {: names :}
   names VEC:COUNT [: names swap VEC:AT STR@ ;] ar ORDER {: idx :}
   idx VEC:COUNT 0 ?do
      dir names idx i VEC:AT @ VEC:AT @ path cx en SCAN-NAME
   loop
   dir p u s" inspect directory after scan" STAT-FD
   before SAME-OBSERVATION 0= if s" scan directory" p u CHANGED then
   path before SCANNED-DIRECTORY-MAKE en DIRECTORIES VEC:PUSH ! ;

: SUBTREE-INSTALL ( -- ) [: SCAN-DIRECTORY ;] is SCAN-SUBTREE ;
SUBTREE-INSTALL

\ ---- the hash stage

: NEW-RESULTS ( ^ARENA:arena -- scan-hash-results )
   {: ar:^ARENA:arena :}
   ar [type] scanned-hash NEW-VEC
   ar [type] MODEL:local-record NEW-VEC
   SCAN-HASH-RESULTS-MAKE ;

: RESULT-RECORDS ( scan-hash-results -- ^VEC:vector<scanned-hash> )
   SCAN-HASH-RESULTS-UNMAKE drop ;

: RESULT-UNKNOWN ( scan-hash-results -- ^VEC:vector<MODEL:local-record> )
   SCAN-HASH-RESULTS-UNMAKE nip ;

: STILL-UNKNOWN ( scan-hash-results str MODEL:unknown-reason -- )
   {: res:scan-hash-results p:str why:MODEL:unknown-reason :}
   p why UNKNOWN-RECORD res RESULT-UNKNOWN VEC:PUSH ! ;

\ The open file's hash, which must match the fingerprint the walk took.
: HASH-OPENED-FILE
   ( fd str MODEL:fingerprint stat [ -- option<cutoff> ] ^ARENA:arena
     -- scanned-hash )
   {: f:fd path:str want:MODEL:fingerprint opened:stat q
      ar:^ARENA:arena :}
   path str> {: p:^ u:n :}
   opened p u FILE-FINGERPRINT want SAME-FINGERPRINT? 0= if
      s" open enumerated scan file" p u CHANGED
   then
   f p u s" hash local scan file" opened ar E-UNSUPPORTED E-CHANGED
   HASH-STABLE-FILE-FROM-STAT
   {: c:DROPBOX:hash print:MODEL:fingerprint :}
   print want SAME-FINGERPRINT? 0= if
      s" hash enumerated scan file" p u CHANGED
   then
   path MODEL:>PATH print c MODEL-HASH--RECORD:MAKE
   {: r:MODEL:hash-record :}
   r r q execute HASH-IS-REUSABLE SCANNED-HASH-MAKE ;

: HASH-SCAN-FILE
   ( fd hash-job [ -- option<cutoff> ] ^ARENA:arena -- scanned-hash )
   {: root:fd job:hash-job q ar:^ARENA:arena :}
   job HASH-JOB-UNMAKE {: path:str want:MODEL:fingerprint :}
   root path str> s" open enumerated scan file" E-IO E-UNSUPPORTED
   OPEN-RELATIVE-REGULAR-WITH-STAT {: f:fd opened:stat :}
   [: f path want opened q ar HASH-OPENED-FILE ;] [: f DISCARD ;] finally ;

\ Every failure here concerns the job's own path.
: HASH-JOB
   ( fd hash-job [ -- option<cutoff> ] ^ARENA:arena scan-hash-results -- )
   {: root:fd job:hash-job q ar:^ARENA:arena res:scan-hash-results :}
   [: root job q ar HASH-SCAN-FILE res RESULT-RECORDS VEC:PUSH ! ;]
   ['] ENTRY-CODE? CONVERTING {: code:n :}
   code 0= if exit then
   code REVISITED-UNKNOWN {: why:MODEL:unknown-reason :}
   job HASH-JOB-UNMAKE {: path:str want:MODEL:fingerprint :}
   res path why STILL-UNKNOWN ;

\ Rust's hash_scan_files, one job at a time.
: HASH-SCAN-FILES
   ( fd ^VEC:vector<hash-job> [ -- option<cutoff> ] ^ARENA:arena
     -- scan-hash-results )
   {: root:fd jobs q ar:^ARENA:arena :}
   ar NEW-RESULTS {: res:scan-hash-results :}
   jobs VEC:COUNT 0 ?do root jobs i VEC:AT @ q ar res HASH-JOB loop
   res ;

: CHECK-CACHED ( fd MODEL:hash-record scan-hash-results -- )
   {: root:fd r:MODEL:hash-record res:scan-hash-results :}
   r RECORD-PATH {: p:^ u:n :}
   root p u s" reopen cached scan file" E-IO E-UNSUPPORTED
   OPEN-RELATIVE-REGULAR-WITH-STAT {: f:fd before:stat :}
   f DISCARD
   before p u FILE-FINGERPRINT r RECORD-FINGERPRINT
   SAME-FINGERPRINT? 0= if
      res p u >str MODEL-UNKNOWN--REASON:incomplete STILL-UNKNOWN exit
   then
   r true SCANNED-HASH-MAKE res RESULT-RECORDS VEC:PUSH ! ;

: REVALIDATE-CACHED ( fd MODEL:hash-record scan-hash-results -- )
   {: root:fd r:MODEL:hash-record res:scan-hash-results :}
   [: root r res CHECK-CACHED ;] ['] ENTRY-CODE? CONVERTING {: code:n :}
   code 0= if exit then
   code REVISITED-UNKNOWN {: why:MODEL:unknown-reason :}
   res r RECORD-PATH >str why STILL-UNKNOWN ;

: REVALIDATE-CACHED-FILES
   ( fd ^VEC:vector<MODEL:hash-record> ^ARENA:arena -- scan-hash-results )
   {: root:fd cached ar:^ARENA:arena :}
   ar NEW-RESULTS {: res:scan-hash-results :}
   cached VEC:COUNT 0 ?do root cached i VEC:AT @ res REVALIDATE-CACHED loop
   res ;

\ ---- directories

: REOPEN-SCANNED-DIRECTORY ( fd ^u8 n -- stat )
   {: root:fd p:^ u:n :}
   p u SAFE-COMPONENTS drop
   root p u FS:TRY-OPEN-DIR-AT MATCH option
      none OF s" reopen scanned directory" p u IO-FAILURE ENDOF
      some OF {: d:fd :}
         [: d p u s" revalidate scanned directory" STAT-FD ;]
         [: d DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ Only the root failing revalidation fails the scan.
: REVALIDATE-ROOT ( fd stat -- )
   {: root:fd before:stat :}
   root s" " s" revalidate scanned directory" STAT-FD
   before SAME-OBSERVATION 0= if
      s" revalidate scanned directory" s" " CHANGED
   then ;

: CHECK-DIRECTORY
   ( fd str stat ^VEC:vector<MODEL:local-record> -- )
   {: root:fd path:str before:stat unknown :}
   root path str> REOPEN-SCANNED-DIRECTORY
   before SAME-OBSERVATION if exit then
   path MODEL-UNKNOWN--REASON:incomplete UNKNOWN-RECORD unknown VEC:PUSH ! ;

: REVALIDATE-DIRECTORY
   ( fd scanned-directory ^VEC:vector<MODEL:local-record> -- )
   {: root:fd d:scanned-directory unknown :}
   d SCANNED-DIRECTORY-UNMAKE {: path:str before:stat :}
   path str> nip 0= if root before REVALIDATE-ROOT exit then
   [: root path before unknown CHECK-DIRECTORY ;] ['] ENTRY-CODE?
   CONVERTING {: code:n :}
   code 0= if exit then
   path code REVISITED-UNKNOWN UNKNOWN-RECORD unknown VEC:PUSH ! ;

\ Rust's revalidate_directories: every scanned directory that moved,
\ changed or became unreadable, with its reason.
: REVALIDATE-DIRECTORIES
   ( fd ^VEC:vector<scanned-directory> ^ARENA:arena
     -- ^VEC:vector<MODEL:local-record> )
   {: root:fd dirs ar:^ARENA:arena :}
   ar [type] MODEL:local-record NEW-VEC {: unknown :}
   dirs VEC:COUNT 0 ?do
      root dirs i VEC:AT @ unknown REVALIDATE-DIRECTORY
   loop
   unknown ;

\ Whether the path is among the roots, which are in byte order.
: AMONG? ( ^u8 n ^VEC:vector<str> -- bool )
   {: p:^ u:n roots :}
   0 roots VEC:COUNT [: roots swap VEC:AT @ str> p u STR< ;]
   SORT:PARTITION-POINT {: at:n :}
   at roots VEC:COUNT >= if false exit then
   roots at VEC:AT @ str> p u STR= ;

\ Whether an ancestor of the path, the bytes before one of its "/", is
\ among the roots.
: BENEATH-ANY? ( ^u8 n ^VEC:vector<str> -- bool )
   {: p:^ u:n roots :}
   u 0 ?do
      p i + c@ SLASH = if
         p i roots AMONG? if true unloop exit then
      then
   loop false ;

: ROOT-PATHS
   ( ^VEC:vector<MODEL:local-record> ^ARENA:arena -- ^VEC:vector<str> )
   {: unknown ar:^ARENA:arena :}
   unknown VEC:COUNT [: unknown swap VEC:AT OBSERVATION-PATH@ ;]
   ar ORDER {: idx :}
   ar [type] str NEW-VEC {: roots :}
   idx VEC:COUNT 0 ?do
      unknown idx i VEC:AT @ VEC:AT @ OBSERVATION-PATH >str roots VEC:PUSH !
   loop
   roots ;

\ Rust's discard_unknown_subtrees: a directory that changed or became
\ unreadable proves nothing below it, so its descendants leave and it
\ publishes as unknown.
: DISCARD-UNKNOWN-SUBTREES
   ( ^VEC:vector<MODEL:local-record> ^VEC:vector<MODEL:local-record>
     ^ARENA:arena -- ^VEC:vector<MODEL:local-record> )
   {: observations unknown ar:^ARENA:arena :}
   unknown VEC:COUNT 0= if observations exit then
   unknown ar ROOT-PATHS {: roots :}
   ar [type] MODEL:local-record NEW-VEC {: kept :}
   observations VEC:COUNT 0 ?do
      observations i VEC:AT @ {: r:MODEL:local-record :}
      r OBSERVATION-PATH {: p:^ u:n :}
      p u roots AMONG? p u roots BENEATH-ANY? or
      0= if r kept VEC:PUSH ! then
   loop
   unknown VEC:COUNT 0 ?do
      unknown i VEC:AT @ {: r:MODEL:local-record :}
      r OBSERVATION-PATH roots BENEATH-ANY? 0= if r kept VEC:PUSH ! then
   loop
   kept ;

\ ---- finishing

\ The hashes a stage confirmed, published present, the reusable ones kept;
\ then the files it could not observe again, published unknown.
: PUBLISH-HASHES
   ( scan-hash-results ^VEC:vector<MODEL:local-record>
     ^VEC:vector<MODEL:hash-record> -- )
   {: res:scan-hash-results observations reusable :}
   res RESULT-RECORDS {: records :}
   records VEC:COUNT 0 ?do
      records i VEC:AT @ SCANNED-HASH-UNMAKE
      {: r:MODEL:hash-record ok:bool :}
      r MODEL-HASH--RECORD:UNMAKE
      {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :}
      p c MODEL-LOCAL:MAKE PRESENT-OBSERVATION MODEL-LOCAL--RECORD:MAKE
      observations VEC:PUSH !
      ok if r reusable VEC:PUSH ! then
   loop
   res RESULT-UNKNOWN {: unknown :}
   unknown VEC:COUNT 0 ?do unknown i VEC:AT @ observations VEC:PUSH ! loop ;

\ The configured path must still name the root the scan opened.
: VERIFY-ROOT ( str stat -- )
   {: root:str before:stat :}
   root str> {: p:^ u:n :}
   p u s" reopen sync root after scan" OPEN-ABSOLUTE-DIRECTORY {: f:fd :}
   [: f p u s" verify sync root binding after scan" STAT-FD ;]
   [: f DISCARD ;] finally
   before SAME-INODE
   0= if s" verify complete local scan root" p u CHANGED then ;

: FINISH
   ( str fd stat scan-entries [ -- option<cutoff> ] ^ARENA:arena
     -- complete-scan )
   {: root:str rfd:fd before:stat en:scan-entries q ar:^ARENA:arena :}
   en SCAN-ENTRIES-UNMAKE {: observations cached reusable dirs jobs :}
   rfd jobs q ar HASH-SCAN-FILES {: hashed:scan-hash-results :}
   rfd cached ar REVALIDATE-CACHED-FILES {: again:scan-hash-results :}
   hashed observations reusable PUBLISH-HASHES
   again observations reusable PUBLISH-HASHES
   rfd dirs ar REVALIDATE-DIRECTORIES {: unscanned :}
   observations unscanned ar DISCARD-UNKNOWN-SUBTREES {: kept :}
   root before VERIFY-ROOT
   kept ar ORDER-OBSERVATIONS reusable ar ORDER-HASH-RECORDS
   COMPLETE-SCAN-MAKE ;

\ Rust's finish_scan_at: the reusable hashes start as the ones the walk
\ retained. It closes the pending scan's root.
: FINISH-SCAN-AT ( pending-scan [ -- option<cutoff> ] -- complete-scan )
   {: ps:pending-scan q :}
   ps PENDING-SCAN-UNMAKE
   {: root:str rfd:fd before:stat en:scan-entries ar:^ARENA:arena :}
   [: root rfd before en q ar FINISH ;] [: rfd DISCARD ;] finally ;

: FINISH-SCAN ( pending-scan -- complete-scan )
   [: CURRENT-HASH-CACHE-CUTOFF ;] FINISH-SCAN-AT ;

\ ---- enumerating

\ Rust's enumerate_scan_on_device: every entry on device into en; any
\ other device is an unsupported subtree. The walk's collections stay in
\ walk order: FINISH sorts what it publishes. A throw closes the root.
: ENUMERATE-SCAN-ON-DEVICE
   ( str scan-entries fd stat ^VEC:vector<MODEL:hash-record>
     option<cutoff> n ^ARENA:arena -- pending-scan )
   {: root:str en:scan-entries rfd:fd before:stat cache
      cut:option<cutoff> dev:n ar:^ARENA:arena :}
   cache cut dev ar SCAN-CONTEXT-MAKE {: cx:scan-context :}
   rfd [: rfd s" " >str cx en SCAN-DIRECTORY ;] CLOSING
   root rfd before en ar PENDING-SCAN-MAKE ;

: ROOT-STAT ( fd ^u8 n -- stat )
   {: rfd:fd p:^ u:n :}
   NO-STAT rfd
   [: DROP-STAT rfd p u s" inspect sync root before scan" STAT-FD ;]
   CLOSING ;

: ENUMERATE-SCAN
   ( ^u8 n ^VEC:vector<MODEL:hash-record> option<cutoff> ^ARENA:arena
     -- pending-scan )
   {: p:^ u:n cache cut:option<cutoff> ar:^ARENA:arena :}
   p u ar KEEP ar NEW-ENTRIES {: root:str en:scan-entries :}
   p u s" open sync root for scan" OPEN-ABSOLUTE-DIRECTORY {: rfd:fd :}
   rfd p u ROOT-STAT {: before:stat :}
   root en rfd before cache cut before STAT-DEV ar
   ENUMERATE-SCAN-ON-DEVICE ;

: SCAN-WITH-CACHE-COMPLETED-AT
   ( ^u8 n ^VEC:vector<MODEL:hash-record> option<cutoff>
     [ -- option<cutoff> ] ^ARENA:arena -- complete-scan )
   {: p:^ u:n cache cut:option<cutoff> q ar:^ARENA:arena :}
   p u cache cut ar ENUMERATE-SCAN q FINISH-SCAN-AT ;

: SCAN-WITH-CACHE-AT
   ( ^u8 n ^VEC:vector<MODEL:hash-record> option<cutoff> ^ARENA:arena
     -- complete-scan )
   {: p:^ u:n cache cut:option<cutoff> ar:^ARENA:arena :}
   p u cache cut [: CURRENT-HASH-CACHE-CUTOFF ;] ar
   SCAN-WITH-CACHE-COMPLETED-AT ;

\ The complete root through no-follow, descriptor-relative opens. An
\ inaccessible, changing, symlinked or special entry publishes as unknown
\ with nothing beneath it, so a partial walk never passes for confirmed
\ absence; only the root's own failures fail the scan.
: SCAN ( ^u8 n ^ARENA:arena -- complete-scan )
   {: p:^ u:n ar:^ARENA:arena :}
   p u ar [type] MODEL:hash-record NEW-VEC NO-CUTOFF ar
   SCAN-WITH-CACHE-AT ;

\ ---- parents

\ An open parent below the root, as Rust's (OwnedFd, OsString, PathBuf):
\ its descriptor, then the last component and the parent's path, both
\ spans of the path opened.
STRUCTURE parent-dir
   FIELD fd fd
   FIELD name str
   FIELD path str
;STRUCTURE

: DROP-DIR ( option<fd> -- ) drop ;

: DUPLICATE-ROOT ( fd ^u8 n -- fd )
   {: root:fd p:^ u:n :}
   -1 >FD [: drop root FD:DUPLICATE ;]
   [: s" duplicate sync root descriptor" p u IO-FAILURE ;] FS-FAILS ;

\ Makes the directory p names in dir and syncs dir's entry; one that
\ exists by now is used as it is.
: MAKE-PARENT ( fd ^u8 n ^u8 n -- )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:MODE-PRIVATE-DIR FS:TRY-MAKE-DIR-AT if
      dir p u s" sync newly created parent directory entry"
      SYNC-DIRECTORY exit
   then
   FS:ERRNO FS:EEXIST = if exit then
   s" create download parent directory" p u IO-FAILURE ;

\ The directory made and opened, then synced; a throw closes it.
: MADE-DIRECTORY ( fd ^u8 n ^u8 n -- fd )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu p u MAKE-PARENT
   dir name nu p u OPEN-DIRECTORY-AT {: next:fd :}
   next [: next p u s" sync newly created directory" SYNC-DIRECTORY ;]
   CLOSING next ;

\ After an open in dir failed: none for a missing name without create,
\ else the directory made.
: MISSING-DIRECTORY ( fd ^u8 n ^u8 n bool -- option<fd> )
   {: dir:fd name:^ nu:n p:^ u:n create:bool :}
   FS:ERRNO FS:ENOENT <> if p u NO-DIRECTORY then
   create 0= if OPTION:NONE exit then
   dir name nu p u MADE-DIRECTORY OPTION:SOME ;

: OPEN-COMPONENT ( fd ^u8 n ^u8 n bool -- option<fd> )
   {: dir:fd name:^ nu:n p:^ u:n create:bool :}
   dir name nu FS:TRY-OPEN-DIR-AT MATCH option
      none OF dir name nu p u create MISSING-DIRECTORY ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH ;

\ Opens each component of p before u from at on in the directory before
\ it, dir first; each closes once the next opens or a throw passes.
: DESCEND-PARENTS ( fd ^u8 n n bool -- option<fd> )
   {: dir:fd p:^ u:n at:n create:bool :}
   p u at NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if dir OPTION:SOME exit then
   OPTION:NONE dir
   [: DROP-DIR dir p from + to from - p to create OPEN-COMPONENT ;]
   CLOSING dir DISCARD
   MATCH option
      none OF OPTION:NONE ENDOF
      some OF p u to create RECURSE ENDOF
   ;MATCH ;

\ Rust's open_parent: the parent of p's last component below the root,
\ none when a directory on the way is missing; create makes those
\ directories, each synced with its entry.
: OPEN-PARENT ( fd ^u8 n bool -- option<parent-dir> )
   {: root:fd p:^ u:n create:bool :}
   p u SAFE-COMPONENTS drop
   p u SPLIT-LAST {: parent:n from:n to:n :}
   root p u DUPLICATE-ROOT p parent 0 create DESCEND-PARENTS
   MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: f:fd :}
         f p from + to from - >str p parent >str PARENT-DIR-MAKE
         OPTION:SOME
      ENDOF
   ;MATCH ;

\ ---- download stages

public

\ What supplying bytes for an immutable stage came to: new verified bytes
\ staged, a verified stage reused, bytes whose hash is actual, or another
\ file at the stage's path, kept as it was.
ENUM stage-outcome<a>
   VARIANT staged FIELD stage a ;VARIANT
   VARIANT already-staged FIELD stage a ;VARIANT
   VARIANT content-changed FIELD actual DROPBOX:hash ;VARIANT
   VARIANT destination-occupied FIELD path str ;VARIANT
;ENUM

private

ENUM stage-write
   VARIANT created ;VARIANT
   VARIANT reused ;VARIANT
   VARIANT mismatch FIELD actual DROPBOX:hash ;VARIANT
   VARIANT destination-occupied FIELD path str ;VARIANT
;ENUM
: DROP-STAGE-WRITE ( stage-write -- ) drop ;

\ An owned stage made read-only, open, and its fingerprint after that.
STRUCTURE verified-download-stage
   FIELD file fd
   FIELD fingerprint MODEL:fingerprint
;STRUCTURE

ENUM download-stage
   VARIANT missing ;VARIANT
   VARIANT verified FIELD stage verified-download-stage ;VARIANT
   VARIANT destination-occupied FIELD path str ;VARIANT
;ENUM

ENUM download-marker missing expected other ;ENUM
: DROP-MARKER ( download-marker -- ) drop ;

\ The Rust daemon's names and sizes, so either reads the other's stages.
: DOWNLOAD-STAGE-XATTR ( -- ^u8 n ) s" user.omabox.download-stage-v1" ;
96 constant MARKER-CAP
MARKER-CAP BUFFER: MARKER-BUF
\ S_IRUSR: a verified stage's only permission.
$100 constant MODE-READ-ONLY

\ The marker an owned download stage of target's content carries.
: STAGE-MARKER ( ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: t:^ tu:n c:DROPBOX:hash ar:^ARENA:arena :}
   s" download-marker-v1" t tu c ar INTERNAL-NAME ;

: SAME-CONTENT? ( DROPBOX:hash DROPBOX:hash -- bool )
   {: a:DROPBOX:hash b:DROPBOX:hash :}
   a DROPBOX:HASH>STR str> b DROPBOX:HASH>STR str> STR= ;

: READ-ONLY ( fd ^u8 n ^u8 n -- )
   {: f:fd p:^ u:n o:^ ou:n :}
   [: f MODE-READ-ONLY FD:MODE! ;] [: o ou p u IO-FAILURE ;] FS-FAILS ;

\ ---- xattrs

\ create refuses an attribute that exists, as XATTR_CREATE does.
: SET-XATTR ( fd ^u8 n ^u8 n bool ^u8 n ^u8 n -- )
   {: f:fd name:^ nu:n v:^ vu:n create:bool p:^ u:n o:^ ou:n :}
   [: create if f name nu v vu XATTR:ADD exit then
      f name nu v vu XATTR:SET ;]
   [: o ou p u IO-FAILURE ;] FS-FAILS ;

\ An absent attribute is already removed.
: REMOVE-XATTR ( fd ^u8 n ^u8 n ^u8 n -- )
   {: f:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   [: f name nu XATTR:ERASE ;] [: o ou p u IO-FAILURE ;] FS-FAILS ;

: MARKER-GOT ( XATTR:got ^u8 n -- download-marker )
   {: g:XATTR:got want:^ wu:n :}
   g MATCH XATTR:got
      absent OF DOWNLOAD-MARKER-MISSING ENDOF
      value OF {: k:n :}
         MARKER-BUF k want wu STR= if DOWNLOAD-MARKER-EXPECTED
         else DOWNLOAD-MARKER-OTHER then
      ENDOF
      oversize OF DOWNLOAD-MARKER-OTHER ENDOF
   ;MATCH ;

\ The stage marker on the file, compared with want's bytes.
: READ-DOWNLOAD-MARKER ( fd ^u8 n ^u8 n -- download-marker )
   {: f:fd want:^ wu:n p:^ u:n :}
   DOWNLOAD-MARKER-MISSING
   [: DROP-MARKER f DOWNLOAD-STAGE-XATTR MARKER-BUF MARKER-CAP SPAN:MAKE
      XATTR:GET want wu MARKER-GOT ;]
   [: s" verify download stage marker" p u IO-FAILURE ;] FS-FAILS ;

: EXPECTED? ( download-marker -- bool )
   MATCH download-marker
      missing OF false ENDOF
      expected OF true ENDOF
      other OF false ENDOF
   ;MATCH ;

\ ---- staging

\ Fills the span from read; a file failure there is a stage read's.
: STAGE-READ-INTO ( ^u8 n [ ^u8 n -- n ] ^u8 n ^u8 n -- n )
   {: dst:^ cap:n read p:^ u:n o:^ ou:n :}
   0 [: drop dst cap read execute ;] [: o ou p u STAGE-READ ;] FS-FAILS ;

: WRITE-PRIVATE ( fd ^u8 n ^u8 n -- )
   {: w:fd b:^ k:n p:^ u:n :}
   [: w b k FD:WRITE-FULL ;]
   [: s" write private stage" p u IO-FAILURE ;] FS-FAILS ;

\ Reads into the span, writes what came to w and answers its count.
: COPY-CHUNK ( ^u8 n [ ^u8 n -- n ] fd ^u8 n ^u8 n -- n )
   {: dst:^ cap:n read w:fd p:^ u:n o:^ ou:n :}
   dst cap read p u o ou STAGE-READ-INTO {: k:n :}
   k 0 > if w dst k p u WRITE-PRIVATE then
   k ;

\ Copies what read gives to w; answers its Dropbox content hash.
: COPY-AND-HASH
   ( [ ^u8 n -- n ] fd ^u8 n ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: read w:fd p:^ u:n o:^ ou:n ar:^ARENA:arena :}
   [: read w p u o ou COPY-CHUNK ;] ar HASH-STREAM ;

: MAP-STAGE-WRITE ( stage-write [ -- a ] -- stage-outcome<a> )
   {: w:stage-write stage :}
   w MATCH stage-write
      created OF stage execute LOCAL-STAGE--OUTCOME:staged ENDOF
      reused OF stage execute LOCAL-STAGE--OUTCOME:already-staged ENDOF
      mismatch OF LOCAL-STAGE--OUTCOME:content-changed ENDOF
      destination-occupied OF LOCAL-STAGE--OUTCOME:destination-occupied
      ENDOF
   ;MATCH ;

\ Whether the file carries marker, true when there is none to carry.
: MARKED? ( fd option<str> ^u8 n -- bool )
   {: f:fd marker:option<str> p:^ u:n :}
   marker MATCH option
      none OF true ENDOF
      some OF {: m:str :} f m str> p u READ-DOWNLOAD-MARKER EXPECTED?
      ENDOF
   ;MATCH ;

\ Syncs the file and its entry when it holds want and carries the marker.
: REUSE-VERIFIED-STAGE
   ( fd DROPBOX:hash DROPBOX:hash option<str> fd ^u8 n -- bool )
   {: f:fd actual:DROPBOX:hash want:DROPBOX:hash marker:option<str>
      dir:fd p:^ u:n :}
   actual want SAME-CONTENT? 0= if false exit then
   f marker p u MARKED? 0= if false exit then
   f p u s" sync verified stage" SYNC-FILE
   dir p u s" sync verified stage entry" SYNC-DIRECTORY
   true ;

\ An entry at the stage's name is reused or kept; it closes the file.
: EXISTING-STAGE
   ( hashed DROPBOX:hash option<str> fd ^u8 n -- stage-write )
   {: h:hashed want:DROPBOX:hash marker:option<str> dir:fd p:^ u:n :}
   h HASHED-UNMAKE {: f:fd actual:DROPBOX:hash print:MODEL:fingerprint :}
   false f
   [: drop f actual want marker dir p u REUSE-VERIFIED-STAGE ;] CLOSING
   f DISCARD
   if STAGE-WRITE-REUSED exit then
   p u >str STAGE-WRITE-DESTINATION-OCCUPIED ;

: MARK-STAGE ( fd option<str> ^u8 n -- )
   {: f:fd marker:option<str> p:^ u:n :}
   marker MATCH option
      none OF ENDOF
      some OF {: m:str :}
         f DOWNLOAD-STAGE-XATTR m str> true p u
         s" mark owned download stage" SET-XATTR
      ENDOF
   ;MATCH ;

\ Names the file in dir; another entry already there is reused or kept.
: LINK-STAGE
   ( fd fd ^u8 n ^u8 n DROPBOX:hash option<str> ^u8 n ^ARENA:arena
     -- stage-write )
   {: f:fd dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash
      marker:option<str> o:^ ou:n ar:^ARENA:arena :}
   f dir name nu FS:TRY-LINK-AT if
      dir p u s" sync staged file entry" SYNC-DIRECTORY
      STAGE-WRITE-CREATED exit
   then
   FS:ERRNO FS:EEXIST <> if
      s" install verified private stage" p u IO-FAILURE
   then
   dir name nu p u s" verify raced stage" ar OPEN-AND-HASH-IF-PRESENT
   MATCH option
      none OF o ou p u CHANGED ENDOF
      some OF want marker dir p u EXISTING-STAGE ENDOF
   ;MATCH ;

\ Copies read's bytes into the unnamed file f and names it when they hash
\ to want, marked, read-only and synced.
: FILL-STAGE
   ( fd fd ^u8 n ^u8 n DROPBOX:hash [ ^u8 n -- n ] option<str> ^u8 n
     ^ARENA:arena -- stage-write )
   {: f:fd dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash read
      marker:option<str> o:^ ou:n ar:^ARENA:arena :}
   read f p u o ou ar COPY-AND-HASH {: actual:DROPBOX:hash :}
   actual want SAME-CONTENT? 0= if actual STAGE-WRITE-MISMATCH exit then
   f marker p u MARK-STAGE
   f p u s" make staged bytes immutable" READ-ONLY
   f p u s" sync verified staged bytes" SYNC-FILE
   f dir name nu p u want marker o ou ar LINK-STAGE ;

: TEMP-FILE ( fd ^u8 n -- fd )
   {: dir:fd p:^ u:n :}
   -1 >FD [: drop dir FS:TEMP-AT ;]
   [: s" create unnamed staging file" p u IO-FAILURE ;] FS-FAILS ;

: WRITE-NEW-STAGE
   ( fd ^u8 n ^u8 n DROPBOX:hash [ ^u8 n -- n ] option<str> ^u8 n
     ^ARENA:arena -- stage-write )
   {: dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash read
      marker:option<str> o:^ ou:n ar:^ARENA:arena :}
   dir p u TEMP-FILE {: f:fd :}
   STAGE-WRITE-CREATED f
   [: DROP-STAGE-WRITE
      f dir name nu p u want read marker o ou ar FILL-STAGE ;]
   CLOSING
   f DISCARD ;

\ Stages read's bytes at the name in dir when they hash to want; an
\ entry already there is reused when it holds want and, given a marker,
\ carries it, and is kept otherwise. o names the operation.
: WRITE-VERIFIED-STAGE
   ( fd ^u8 n ^u8 n DROPBOX:hash [ ^u8 n -- n ] option<str> ^u8 n
     ^ARENA:arena -- stage-write )
   {: dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash read
      marker:option<str> o:^ ou:n ar:^ARENA:arena :}
   dir name nu p u o ou ar OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF dir name nu p u want read marker o ou ar WRITE-NEW-STAGE
      ENDOF
      some OF want marker dir p u EXISTING-STAGE ENDOF
   ;MATCH ;

\ ---- owned download stages

: OWNED? ( fd DROPBOX:hash DROPBOX:hash ^u8 n ^u8 n -- bool )
   {: f:fd actual:DROPBOX:hash want:DROPBOX:hash m:^ mu:n p:^ u:n :}
   actual want SAME-CONTENT? 0= if false exit then
   f m mu p u READ-DOWNLOAD-MARKER EXPECTED? ;

\ Makes the hashed file read-only and synced; answers its fingerprint.
: SEAL-STAGE ( fd MODEL:fingerprint ^u8 n -- MODEL:fingerprint )
   {: f:fd print:MODEL:fingerprint p:^ u:n :}
   s" revalidate owned download stage" {: r:^ ru:n :}
   s" make verified download stage immutable" {: m:^ mu:n :}
   f p u r ru STAT-FD p u FILE-FINGERPRINT
   print SAME-FINGERPRINT? 0= if r ru p u CHANGED then
   f p u m mu READ-ONLY
   f p u s" sync immutable download stage" SYNC-FILE
   f p u s" inspect immutable download stage" STAT-FD
   p u FILE-FINGERPRINT {: after:MODEL:fingerprint :}
   print after SAME-HASHED-CONTENT 0= if m mu p u CHANGED then
   after ;

: INSPECT-HASHED
   ( hashed ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- download-stage )
   {: h:hashed p:^ u:n t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   h HASHED-UNMAKE {: f:fd actual:DROPBOX:hash print:MODEL:fingerprint :}
   false f [: drop f actual want t tu want ar STAGE-MARKER p u OWNED? ;]
   CLOSING 0= if
      f DISCARD p u >str DOWNLOAD-STAGE-DESTINATION-OCCUPIED exit
   then
   NO-FINGERPRINT f [: DROP-FINGERPRINT f print p u SEAL-STAGE ;] CLOSING
   {: after:MODEL:fingerprint :}
   f after VERIFIED-DOWNLOAD-STAGE-MAKE DOWNLOAD-STAGE-VERIFIED ;

\ The stage at the name in dir for target's content want: none, an owned
\ stage verified and left open, or, kept as it was, another file, an
\ object not a regular file or a file Omabox cannot read. Rust throws for
\ the last two; a Habu throw names no path, so its callers could not tell
\ the stage's name from the target's.
: INSPECT-DOWNLOAD-STAGE
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- download-stage )
   {: dir:fd name:^ nu:n p:^ u:n t:^ tu:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   s" verify owned download stage" {: o:^ ou:n :}
   dir name nu p u o ou OPEN-NAMED MATCH name-entry
      absent OF DOWNLOAD-STAGE-MISSING ENDOF
      regular OF p u o ou ar HASH-OPENED
         p u t tu want ar INSPECT-HASHED
      ENDOF
      unsupported OF p u >str DOWNLOAD-STAGE-DESTINATION-OCCUPIED ENDOF
      unreadable OF p u >str DOWNLOAD-STAGE-DESTINATION-OCCUPIED ENDOF
   ;MATCH ;

\ ---- changed guards

: HOLDS? ( option<DROPBOX:hash> DROPBOX:hash -- bool )
   {: o:option<DROPBOX:hash> c:DROPBOX:hash :}
   o MATCH option
      none OF false ENDOF
      some OF c SAME-CONTENT? ENDOF
   ;MATCH ;

\ The conflict name holds the guard's bytes already: drops the guard.
: DROP-DUPLICATE-GUARD
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd g:^ gu:n cn:^ cnu:n t:^ tu:n c:DROPBOX:hash
      ar:^ARENA:arena :}
   dir cn cnu t tu s" verify raced conflict destination" ar
   HASH-AT-IF-PRESENT c HOLDS? 0= if
      s" preserve raced local destination" t tu OCCUPIED
   then
   dir g gu FS:TRY-REMOVE-FILE-AT 0= if
      s" remove duplicate raced local copy" t tu IO-FAILURE
   then
   dir t tu s" sync duplicate raced local cleanup" SYNC-DIRECTORY ;

\ Renames the guard to target's local conflict name for content c.
: PRESERVE-GUARD ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd g:^ gu:n t:^ tu:n c:DROPBOX:hash ar:^ARENA:arena :}
   s" preserve raced local destination" {: o:^ ou:n :}
   t tu LOCAL-CONFLICT--SIDE:local c ar CONFLICT-NAME {: cn:^ cnu:n :}
   dir g gu dir cn cnu FS:TRY-RENAME-NEW-AT if
      dir t tu s" sync preserved raced local destination" SYNC-DIRECTORY
      exit
   then
   FS:ERRNO FS:EEXIST <> if o ou t tu IO-FAILURE then
   dir g gu cn cnu t tu c ar DROP-DUPLICATE-GUARD ;

\ Puts the guard back at target_name; when an entry raced in there, keeps
\ the guard's bytes, whose hash is actual, under a local conflict name.
: RESTORE-OR-PRESERVE-CHANGED-GUARD
   ( fd ^u8 n ^u8 n ^u8 n option<DROPBOX:hash> ^ARENA:arena -- )
   {: dir:fd g:^ gu:n tn:^ tnu:n t:^ tu:n actual:option<DROPBOX:hash>
      ar:^ARENA:arena :}
   s" restore changed local destination" {: o:^ ou:n :}
   dir g gu dir tn tnu FS:TRY-RENAME-NEW-AT if
      dir t tu o ou SYNC-DIRECTORY exit
   then
   FS:ERRNO FS:EEXIST <> if o ou t tu IO-FAILURE then
   actual MATCH option
      none OF s" preserve raced local destination" t tu CHANGED ENDOF
      some OF {: c:DROPBOX:hash :} dir g gu t tu c ar PRESERVE-GUARD ENDOF
   ;MATCH ;

\ ---- upload stages

: SEEK-START ( fd ^u8 n ^u8 n -- )
   {: f:fd p:^ u:n o:^ ou:n :}
   [: f 0 FD:SEEK ;] [: o ou p u IO-FAILURE ;] FS-FAILS ;

public

\ A verified immutable upload stage: the staging directory's path and the
\ content its file holds, named by that content's hash. A stage-outcome
\ holds one by its address in the caller's arena.
STRUCTURE staged-upload OPAQUE
   FIELD directory str
   FIELD content DROPBOX:hash
;STRUCTURE

: UPLOAD-CONTENT ( ^staged-upload -- DROPBOX:hash )
   @ STAGED-UPLOAD-UNMAKE {: d:str c:DROPBOX:hash :} c ;

private

\ The open stage at the name when it holds c, at its start.
: VERIFY-UPLOAD-STAGE
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- fd )
   {: dir:fd name:^ nu:n p:^ u:n c:DROPBOX:hash ar:^ARENA:arena :}
   dir name nu p u s" verify immutable upload stage" ar OPEN-AND-HASH-AT
   {: f:fd actual:DROPBOX:hash :}
   actual c SAME-CONTENT? 0= if
      f DISCARD s" open immutable upload stage" p u CORRUPT
   then
   f [: f p u s" rewind immutable upload stage" SEEK-START ;] CLOSING
   f ;

ARENA STAGED-UPLOADS staged-upload

: NEW-STAGED-UPLOAD
   ( ^u8 n DROPBOX:hash ^ARENA:arena -- ^staged-upload )
   {: d:^ du:n c:DROPBOX:hash ar:^ARENA:arena :}
   ar STAGED-UPLOADS-NEW {: rec:^ :}
   d du >str c STAGED-UPLOAD-MAKE rec !
   rec ;

public

\ Reopens the stage and verifies it: the descriptor an uploader reads.
: OPEN-VERIFIED-UPLOAD ( ^staged-upload ^ARENA:arena -- fd )
   {: rec:^ ar:^ARENA:arena :}
   rec @ STAGED-UPLOAD-UNMAKE {: d:str c:DROPBOX:hash :}
   c DROPBOX:HASH>STR str> {: name:^ nu:n :}
   d str> name nu ar JOIN {: p:^ u:n :}
   d str> s" open upload staging directory" OPEN-PRIVATE-DIRECTORY
   {: dir:fd :}
   -1 >FD dir [: drop dir name nu p u c ar VERIFY-UPLOAD-STAGE ;] CLOSING
   dir DISCARD ;

private

\ Whether a stage's failure, its code and errno, means another entry
\ holds its path: one not a regular file, or a symlink. Its callers catch
\ only throws whose path is the stage's, so no path is needed.
: UPLOAD-STAGE-OCCUPIED? ( n n -- bool )
   {: code:n e:n :}
   code E-UNSUPPORTED = if true exit then
   code E-IO = e FS:ELOOP = and ;

: NO-HASHED ( -- option<hashed> ) OPTION:NONE ;
: DROP-HASHED ( option<hashed> -- ) drop ;
\ An upload stage or a conflict copy carries no stage marker.
: NO-MARKER ( -- option<str> ) OPTION:NONE ;

\ The entry at the stage's path hashed, none when nothing is there; an
\ occupied path is occupied, a throw.
: HASH-UPLOAD-STAGE
   ( fd ^u8 n ^u8 n ^ARENA:arena -- option<hashed> bool )
   {: dir:fd name:^ nu:n p:^ u:n ar:^ARENA:arena :}
   NO-HASHED [: DROP-HASHED dir name nu p u
      s" verify immutable upload stage" ar OPEN-AND-HASH-IF-PRESENT ;]
   ['] UPLOAD-STAGE-OCCUPIED? CONVERTING {: code:n :}
   code 0= if false exit then
   drop code FS:ERRNO UPLOAD-STAGE-OCCUPIED? if NO-HASHED true exit then
   code throw ;

\ A stage file that does not hold want is disposable: it is removed when
\ the name is still its inode, so each retry rebuilds the stage.
: REMOVE-CORRUPT-STAGE ( fd fd ^u8 n ^u8 n -- )
   {: f:fd dir:fd name:^ nu:n p:^ u:n :}
   s" remove corrupt upload stage" {: o:^ ou:n :}
   f dir name nu p u NAMED-INODE-MATCHES 0= if o ou p u CHANGED then
   dir name nu FS:TRY-REMOVE-FILE-AT 0= if o ou p u IO-FAILURE then
   dir p u s" sync corrupt upload stage removal" SYNC-DIRECTORY ;

\ Reuses the hashed stage when it holds want, else removes it: true
\ when it was reused. It closes the file.
: SETTLE-UPLOAD-STAGE ( hashed fd ^u8 n ^u8 n DROPBOX:hash -- bool )
   {: h:hashed dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash :}
   h HASHED-UNMAKE {: f:fd actual:DROPBOX:hash print:MODEL:fingerprint :}
   false f [: drop
      f actual want NO-MARKER dir p u REUSE-VERIFIED-STAGE dup 0= if
         f dir name nu p u REMOVE-CORRUPT-STAGE
      then ;] CLOSING
   f DISCARD ;

\ WRITE-VERIFIED-STAGE of the source's bytes, true when a throw found the
\ stage path occupied: then destination-occupied. A failed read of the
\ source is an io failure.
: WRITE-UPLOAD-STAGE
   ( fd fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- stage-write bool )
   {: src:fd dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   STAGE-WRITE-CREATED [: DROP-STAGE-WRITE
      dir name nu p u want [: src -rot FD-READ ;] NO-MARKER
      s" stage upload" ar WRITE-VERIFIED-STAGE ;]
   ['] UPLOAD-STAGE-OCCUPIED? CONVERTING {: code:n :}
   code 0= if false exit then
   drop code FS:ERRNO UPLOAD-STAGE-OCCUPIED? if
      p u >str STAGE-WRITE-DESTINATION-OCCUPIED true exit
   then
   code LOCAL-CODE throw ;

\ Stages the source's bytes; its stat must not change while they copy,
\ unless the stage path was occupied, answered before the second stat.
: STAGE-SOURCE
   ( fd ^u8 n fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- stage-write )
   {: src:fd r:^ ru:n dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   src r ru s" inspect upload source before staging" STAT-FD
   {: before:stat :}
   src dir name nu p u want ar WRITE-UPLOAD-STAGE if exit then
   {: w:stage-write :}
   src r ru s" inspect upload source after staging" STAT-FD
   before SAME-OBSERVATION 0= if
      s" stage upload" r ru E-SOURCE-CHANGED CHANGED-FAILS
   then
   w ;

\ Rust's upload_source_changed holds for any failure of this open but an
\ unsafe path: they throw E-SOURCE-CHANGED.
: OPEN-UPLOAD-SOURCE ( fd ^u8 n -- fd )
   s" open upload source" E-SOURCE-CHANGED E-SOURCE-CHANGED
   OPEN-RELATIVE-REGULAR ;

\ Opens the source below the root and stages its bytes; it closes it.
: STAGE-FROM-SOURCE
   ( fd ^u8 n fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- stage-write )
   {: root:fd r:^ ru:n dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   root r ru OPEN-UPLOAD-SOURCE {: src:fd :}
   STAGE-WRITE-CREATED src [: DROP-STAGE-WRITE
      src r ru dir name nu p u want ar STAGE-SOURCE ;] CLOSING
   src DISCARD ;

\ The stage in the open staging directory: one already there is reused
\ or replaced, and an occupied path is kept.
: STAGE-UPLOAD-IN
   ( fd ^u8 n fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- stage-write )
   {: root:fd r:^ ru:n dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   dir name nu p u ar HASH-UPLOAD-STAGE if
      DROP-HASHED p u >str STAGE-WRITE-DESTINATION-OCCUPIED exit
   then
   MATCH option
      none OF false ENDOF
      some OF dir name nu p u want SETTLE-UPLOAD-STAGE ENDOF
   ;MATCH if STAGE-WRITE-REUSED exit then
   root r ru dir name nu p u want ar STAGE-FROM-SOURCE ;

: NO-UPLOAD-OUTCOME ( -- stage-outcome<^staged-upload> )
   s" " >str LOCAL-STAGE--OUTCOME:destination-occupied ;
: DROP-UPLOAD-OUTCOME ( stage-outcome<^staged-upload> -- ) drop ;

public

\ Copies the regular file r below the root into the staging directory s,
\ an absolute path, under want's hash, when it holds want. A source that
\ fails to open or changes while it copies throws E-SOURCE-CHANGED.
: STAGE-UPLOAD-AT
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- stage-outcome<^staged-upload> )
   {: root:fd r:^ ru:n s:^ su:n want:DROPBOX:hash ar:^ARENA:arena :}
   want s" stage upload" REQUIRE-CONTENT-HASH
   want DROPBOX:HASH>STR str> {: name:^ nu:n :}
   s su name nu ar JOIN {: p:^ u:n :}
   s su s" open upload staging directory" OPEN-PRIVATE-DIRECTORY
   {: dir:fd :}
   STAGE-WRITE-CREATED dir [: DROP-STAGE-WRITE
      root r ru dir name nu p u want ar STAGE-UPLOAD-IN ;] CLOSING
   dir DISCARD
   [: s su want ar NEW-STAGED-UPLOAD ;] MAP-STAGE-WRITE ;

\ STAGE-UPLOAD-AT below the sync root at the absolute path.
: STAGE-UPLOAD
   ( ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- stage-outcome<^staged-upload> )
   {: rp:^ rpu:n r:^ ru:n s:^ su:n want:DROPBOX:hash ar:^ARENA:arena :}
   rp rpu s" open sync root for upload staging" OPEN-ROOT {: root:fd :}
   NO-UPLOAD-OUTCOME root
   [: DROP-UPLOAD-OUTCOME root r ru s su want ar STAGE-UPLOAD-AT ;] CLOSING
   root DISCARD ;

\ The content hash of the regular file r below the root, as it is now; a
\ source that changes while it is read throws E-SOURCE-CHANGED.
: OBSERVE-UPLOAD-SOURCE-AT ( fd ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: root:fd r:^ ru:n ar:^ARENA:arena :}
   root r ru OPEN-UPLOAD-SOURCE {: src:fd :}
   NO-HASH src [: DROP-HASH src r ru s" verify upload source" ar
      E-SOURCE-CHANGED E-SOURCE-CHANGED HASH-STABLE-FILE ;] CLOSING
   src DISCARD ;

\ OBSERVE-UPLOAD-SOURCE-AT below the sync root at the absolute path.
: OBSERVE-UPLOAD-SOURCE ( ^u8 n ^u8 n ^ARENA:arena -- DROPBOX:hash )
   {: rp:^ rpu:n r:^ ru:n ar:^ARENA:arena :}
   rp rpu s" open sync root for upload observation" OPEN-ROOT {: root:fd :}
   NO-HASH root [: DROP-HASH root r ru ar OBSERVE-UPLOAD-SOURCE-AT ;]
   CLOSING
   root DISCARD ;

private

\ ---- upload stage collection

\ Opens the name in dir with open; none when nothing, or a symlink, is
\ there.
: OPEN-UPLOAD-STAGE-CANDIDATE
   ( fd ^u8 n [ fd ^u8 n -- option<fd> ] ^u8 n ^u8 n -- option<fd> )
   {: dir:fd name:^ nu:n open p:^ u:n o:^ ou:n :}
   dir name nu open execute MATCH option
      none OF FS:ERRNO {: e:n :}
         e FS:ENOENT <> e FS:ELOOP <> and if o ou p u IO-FAILURE then
         OPTION:NONE
      ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH ;

\ The stat of the entry the candidate opens, which it closes; none when
\ nothing is there.
: CANDIDATE-STAT ( fd ^u8 n ^u8 n ^u8 n -- option<stat> )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu [: FS:TRY-OPEN-ENTRY-AT ;] p u o ou
   OPEN-UPLOAD-STAGE-CANDIDATE MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: e:fd :}
         NO-STAT e [: DROP-STAT e p u o ou STAT-FD ;] CLOSING
         e DISCARD OPTION:SOME
      ENDOF
   ;MATCH ;

\ Whether a stage's failure, its code and errno, says it changed or
\ stopped being regular while it was read.
: UNSTABLE? ( n n -- bool )
   {: code:n e:n :}
   code E-CHANGED = code E-UNSUPPORTED = or ;

\ Whether the file hashes to its name; an UNSTABLE? file does not.
: HOLDS-ITS-NAME? ( fd ^u8 n ^u8 n ^ARENA:arena -- bool )
   {: f:fd name:^ nu:n p:^ u:n ar:^ARENA:arena :}
   false [: drop f p u s" verify upload stage for collection" ar
      E-UNSUPPORTED E-CHANGED HASH-STABLE-FILE
      DROPBOX:HASH>STR str> name nu STR= ;]
   ['] UNSTABLE? CONVERTING {: code:n :}
   code 0= if exit then
   drop code FS:ERRNO UNSTABLE? if false exit then
   code throw ;

\ Whether the name is still the opened file's entry, unchanged.
: STILL-NAMED? ( fd fd ^u8 n ^u8 n -- bool )
   {: f:fd dir:fd name:^ nu:n p:^ u:n :}
   dir name nu p u s" reinspect upload stage for collection" CANDIDATE-STAT
   MATCH option
      none OF false ENDOF
      some OF {: current:stat :}
         f p u s" reinspect opened upload stage for collection" STAT-FD
         current SAME-OBSERVATION
      ENDOF
   ;MATCH ;

\ The opened stage file is the entry seen before, holds its name's
\ content, and is still that entry.
: VERIFIED-OPENED? ( fd stat fd ^u8 n ^u8 n ^ARENA:arena -- bool )
   {: f:fd before:stat dir:fd name:^ nu:n p:^ u:n ar:^ARENA:arena :}
   f p u s" inspect opened upload stage for collection" STAT-FD
   before SAME-OBSERVATION 0= if false exit then
   f name nu p u ar HOLDS-ITS-NAME? 0= if false exit then
   f dir name nu p u STILL-NAMED? ;

\ Whether the entry at the name is a regular file that holds the content
\ its name claims, and stayed so while it was read.
: VERIFIED-UPLOAD-STAGE-ENTRY? ( fd ^u8 n ^u8 n ^ARENA:arena -- bool )
   {: dir:fd name:^ nu:n p:^ u:n ar:^ARENA:arena :}
   dir name nu p u s" inspect upload stage for collection" CANDIDATE-STAT
   MATCH option
      none OF false exit ENDOF
      some OF ENDOF
   ;MATCH {: before:stat :}
   before REGULAR? 0= if false exit then
   dir name nu [: FS:TRY-OPEN-READ-AT ;] p u
   s" open upload stage for collection"
   OPEN-UPLOAD-STAGE-CANDIDATE MATCH option
      none OF false ENDOF
      some OF {: f:fd :}
         false f [: drop f before dir name nu p u ar VERIFIED-OPENED? ;]
         CLOSING
         f DISCARD
      ENDOF
   ;MATCH ;

\ Removes the stage at the listed path when it verifies; answers how
\ many it removed.
: COLLECT-UPLOAD-STAGE ( fd ^u8 n ^u8 n ^ARENA:arena -- n )
   {: dir:fd name:^ nu:n p:^ u:n ar:^ARENA:arena :}
   dir name nu p u ar VERIFIED-UPLOAD-STAGE-ENTRY? 0= if 0 exit then
   dir name nu FS:TRY-REMOVE-FILE-AT if 1 exit then
   FS:ERRNO FS:ENOENT <> if
      s" remove unreferenced upload stage" p u IO-FAILURE
   then 0 ;

\ Collects the path's stage when its name is a content hash retained
\ does not keep; answers how many it removed.
: COLLECT-LISTED-STAGE
   ( fd str str [ DROPBOX:hash -- bool ] ^ARENA:arena -- n )
   {: dir:fd path:str s:str retained ar:^ARENA:arena :}
   path s NAME-OF {: name:^ nu:n :}
   name nu VALID-CONTENT-HASH? 0= if 0 exit then
   name nu >str DROPBOX:>HASH retained execute if 0 exit then
   dir name nu path str> ar COLLECT-UPLOAD-STAGE ;

\ The stages in s visited in name byte order, the whole listing read
\ before any is removed.
: COLLECT-UPLOAD-STAGES
   ( fd str [ DROPBOX:hash -- bool ] ^ARENA:arena -- n )
   {: dir:fd s:str retained ar:^ARENA:arena :}
   dir s s" open upload staging directory stream"
   s" read upload staging directory" ar LIST-PATHS {: paths :}
   paths VEC:COUNT [: paths swap VEC:AT STR@ ;] ar ORDER {: idx :}
   0 idx VEC:COUNT 0 ?do
      dir paths idx i VEC:AT @ VEC:AT @ s retained ar
      COLLECT-LISTED-STAGE +
   loop ;

public

\ Removes the verified upload stages in the staging directory s, an
\ absolute path, whose content retained does not keep; answers how many.
\ Other names, entries that are not regular files, and files that change
\ or do not hold their name's content stay. The directory syncs once.
: REMOVE-UNREFERENCED-UPLOAD-STAGES
   ( ^u8 n [ DROPBOX:hash -- bool ] ^ARENA:arena -- n )
   {: s:^ su:n retained ar:^ARENA:arena :}
   s su s" open upload staging directory for collection"
   OPEN-PRIVATE-DIRECTORY {: dir:fd :}
   0 dir [: drop dir s su >str retained ar COLLECT-UPLOAD-STAGES
      dup 0<> if
         dir s su s" sync upload stage collection" SYNC-DIRECTORY
      then ;] CLOSING
   dir DISCARD ;

private


\ ---- download slots

\ The Rust daemon's names and sizes, so either resumes the other's
\ partials.
: DOWNLOAD-PARTIAL-XATTR ( -- ^u8 n ) s" user.omabox.download-partial-v1" ;
\ 64 MiB, a whole number of Dropbox's 4 MiB blocks.
$4000000 constant DOWNLOAD-CHECKPOINT-BYTES
: DOWNLOAD-SLOT-OWNER-PREFIX ( -- ^u8 n ) s" omabox-download-slot-v1" ;
\ The owner prefix, the binding's 32 bytes, then the offset big-endian.
DOWNLOAD-SLOT-OWNER-PREFIX nip 32 + 8 + constant DOWNLOAD-SLOT-STATE-LENGTH
\ The slots are this many fixed files, so a partial either daemon left in
\ any of them is found.
4 constant MAX-PARALLEL-DOWNLOADS

public

\ A slot's owner, Rust's 32-byte binding: four cells of eight of its
\ bytes, each read most significant first.
STRUCTURE binding OPAQUE
   FIELD b0 n
   FIELD b1 n
   FIELD b2 n
   FIELD b3 n
;STRUCTURE

\ The download a slot is bound to.
STRUCTURE download-slot-identity OPAQUE FIELD binding binding ;STRUCTURE

\ A slot leased to one download: the caller's slot directory, the slot's
\ number and the download's binding.
STRUCTURE download-slot-lease OPAQUE
   FIELD directory str
   FIELD slot n
   FIELD binding binding
;STRUCTURE

private

\ Where a download's bytes go before they are staged: a slot in its
\ directory, bound to the download, or an unnamed file shown as path.
ENUM download-source
   VARIANT resumable
      FIELD directory fd
      FIELD name str
      FIELD path str
      FIELD binding binding
   ;VARIANT
   VARIANT disposable FIELD path str ;VARIANT
;ENUM

\ A download's source and the stage it becomes: the target's directory,
\ the stage's name and path there, the target and its content.
STRUCTURE download-location DERIVE addr
   FIELD source download-source
   FIELD target-directory fd
   FIELD stage-name str
   FIELD stage-path str
   FIELD target str
   FIELD expected DROPBOX:hash
;STRUCTURE

public

\ A download in progress: where it goes, its file, the bytes in it, and
\ the Dropbox hash of those bytes so far.
STRUCTURE download-partial OPAQUE DERIVE addr
   FIELD location download-location
   FIELD file fd
   FIELD offset n
   FIELD aggregate DROPBOX:hasher
;STRUCTURE

\ What preparing a download came to: a partial ready for bytes, a stage
\ complete already, its stage 0 for Rust's (), or no slot to resume in.
ENUM download-preparation
   VARIANT ready FIELD partial ^download-partial ;VARIANT
   VARIANT complete FIELD stage stage-outcome<n> ;VARIANT
   VARIANT ephemeral ;VARIANT
;ENUM

private

\ A slot's owner and the bytes of its partial known durable.
STRUCTURE download-slot-state
   FIELD binding binding
   FIELD offset n
;STRUCTURE

ARENA PARTIALS download-partial

\ The source's path: a slot's, or an unnamed file's display path.
: SOURCE-PATH ( download-source -- ^u8 n )
   MATCH download-source
      resumable OF {: dir:fd name:str path:str b:binding :} path str>
      ENDOF
      disposable OF str> ENDOF
   ;MATCH ;

\ ---- slot bindings

\ Eight bytes at p as one cell, the first most significant.
: BE@ ( ^u8 -- n )
   {: p:^ :}
   0 8 0 ?do 8 lshift p i + c@ or loop ;

: BE! ( n ^u8 -- )
   {: v:n p:^ :}
   8 0 ?do v 7 i - 8 * rshift $FF and p i + c! loop ;

: BYTES>BINDING ( ^u8 -- binding )
   {: p:^ :}
   p BE@ p 8 + BE@ p 16 + BE@ p 24 + BE@ BINDING-MAKE ;

: BINDING>BYTES ( binding ^u8 -- )
   {: b:binding p:^ :}
   b BINDING-UNMAKE {: b0:n b1:n b2:n b3:n :}
   b0 p BE! b1 p 8 + BE! b2 p 16 + BE! b3 p 24 + BE! ;

8 BUFFER: BE-BUF

: FEED-BE ( n -- ) BE-BUF BE! BE-BUF 8 FEED ;

public

: BINDING= ( binding binding -- bool )
   {: a:binding b:binding :}
   a BINDING-UNMAKE {: a0:n a1:n a2:n a3:n :}
   b BINDING-UNMAKE {: b0:n b1:n b2:n b3:n :}
   a0 b0 = a1 b1 = and a2 b2 = and a3 b3 = and ;

\ Rust's DownloadSlotIdentity::new for a root's generation, an operation
\ and its target: the SHA-256 of the lease's tag, the generation and the
\ operation big-endian, the target, the rev and the content, the last
\ three NUL-separated.
: NEW-SLOT-IDENTITY
   ( n n ^u8 n MODEL:remote -- download-slot-identity )
   {: generation:n operation:n t:^ tu:n r:MODEL:remote :}
   r MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash rev:DROPBOX:rev :}
   NAME-CTX SHA256-BEGIN
   s" omabox-download-slot-lease-v1" FEED
   generation FEED-BE operation FEED-BE
   t tu FEED NUL 1 FEED rev DROPBOX:REV>STR str> FEED
   NUL 1 FEED c DROPBOX:HASH>STR str> FEED
   NAME-CTX NAME-DIGEST SHA256-END
   NAME-DIGEST BYTES>BINDING DOWNLOAD-SLOT-IDENTITY-MAKE ;

: SLOT-BINDING ( download-slot-identity -- binding )
   DOWNLOAD-SLOT-IDENTITY-UNMAKE ;

private

\ ---- slot state

DOWNLOAD-SLOT-STATE-LENGTH BUFFER: STATE-BUF

\ The xattr's bytes, valid until the next encode or read.
: ENCODE-DOWNLOAD-SLOT-STATE ( download-slot-state -- ^u8 n )
   DOWNLOAD-SLOT-STATE-UNMAKE {: b:binding offset:n :}
   DOWNLOAD-SLOT-OWNER-PREFIX {: x:^ xu:n :}
   x STATE-BUF xu BYTE-COPY
   b STATE-BUF xu + BINDING>BYTES
   offset STATE-BUF xu + 32 + BE!
   STATE-BUF DOWNLOAD-SLOT-STATE-LENGTH ;

: DECODE-DOWNLOAD-SLOT-STATE ( ^u8 n -- option<download-slot-state> )
   {: p:^ u:n :}
   DOWNLOAD-SLOT-OWNER-PREFIX {: x:^ xu:n :}
   u DOWNLOAD-SLOT-STATE-LENGTH <> if OPTION:NONE exit then
   p xu x xu STR= 0= if OPTION:NONE exit then
   p xu + BYTES>BINDING p xu + 32 + BE@
   DOWNLOAD-SLOT-STATE-MAKE OPTION:SOME ;

: STATE-GOT ( XATTR:got -- option<download-slot-state> )
   MATCH XATTR:got
      absent OF OPTION:NONE ENDOF
      value OF STATE-BUF swap DECODE-DOWNLOAD-SLOT-STATE ENDOF
      oversize OF OPTION:NONE ENDOF
   ;MATCH ;

: DROP-SLOT-STATE ( option<download-slot-state> -- ) drop ;

\ The slot's state, none when it carries none in this format.
: READ-DOWNLOAD-SLOT-STATE ( fd ^u8 n -- option<download-slot-state> )
   {: f:fd p:^ u:n :}
   OPTION:NONE
   [: DROP-SLOT-STATE f DOWNLOAD-PARTIAL-XATTR
      STATE-BUF DOWNLOAD-SLOT-STATE-LENGTH SPAN:MAKE XATTR:GET STATE-GOT ;]
   [: s" inspect resumed download slot marker" p u IO-FAILURE ;] FS-FAILS ;

: SLOT-BOUND? ( option<download-slot-state> binding -- bool )
   {: s:option<download-slot-state> b:binding :}
   s MATCH option
      none OF false ENDOF
      some OF DOWNLOAD-SLOT-STATE-UNMAKE {: held:binding at:n :}
         held b BINDING=
      ENDOF
   ;MATCH ;

\ Whether the file is a slot still bound to the location's download.
: DOWNLOAD-SLOT-MATCHES ( fd ^download-location -- bool )
   {: f:fd loc :}
   loc DOWNLOAD-LOCATION-SOURCE @ MATCH download-source
      resumable OF {: dir:fd name:str path:str b:binding :}
         f path str> READ-DOWNLOAD-SLOT-STATE b SLOT-BOUND?
      ENDOF
      disposable OF {: path:str :} false ENDOF
   ;MATCH ;

\ ---- slot files

\ ".omabox-download-slot-" and the slot's digit; the slots are 0 to 3.
24 BUFFER: SLOT-NAME
FS:PATHZ-CAP BUFFER: SLOT-PATH

\ The slot's name, valid until the next.
: DOWNLOAD-SLOT-NAME ( n -- ^u8 n )
   {: slot:n :}
   s" .omabox-download-slot-" {: p:^ u:n :}
   p SLOT-NAME u BYTE-COPY
   slot $30 + SLOT-NAME u + c!
   SLOT-NAME u 1+ ;

\ The slot's path in the directory, for logs; valid until the next.
: DOWNLOAD-SLOT-PATH ( ^u8 n n -- ^u8 n )
   {: d:^ du:n slot:n :}
   d du slot DOWNLOAD-SLOT-NAME SLOT-PATH FS:JOIN-PATH SLOT-PATH swap ;

ENUM download-slot-open
   VARIANT missing ;VARIANT
   VARIANT file FIELD file fd ;VARIANT
   VARIANT occupied ;VARIANT
;ENUM
: DROP-SLOT-OPEN ( download-slot-open -- ) drop ;

\ The opened file, when it is the regular file probed.
: CHECK-SLOT-FILE ( fd stat ^u8 n -- download-slot-open )
   {: f:fd probed:stat p:^ u:n :}
   NO-STAT f
   [: DROP-STAT f p u s" inspect opened download slot" STAT-FD ;] CLOSING
   {: opened:stat :}
   opened REGULAR? opened probed SAME-INODE and if
      f DOWNLOAD-SLOT-OPEN-FILE exit
   then
   f DISCARD DOWNLOAD-SLOT-OPEN-OCCUPIED ;

\ After the open for writing failed: missing, occupied by another inode
\ or one Omabox may not write, else the failure.
: SLOT-OPEN-FAILED ( fd fd ^u8 n ^u8 n -- download-slot-open )
   {: probe:fd dir:fd name:^ nu:n p:^ u:n :}
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if DOWNLOAD-SLOT-OPEN-MISSING exit then
   probe dir name nu p u NAMED-INODE-MATCHES 0= if
      DOWNLOAD-SLOT-OPEN-OCCUPIED exit
   then
   e FS:EACCES = e FS:EPERM = or if DOWNLOAD-SLOT-OPEN-OCCUPIED exit then
   e s" open resumed download" p u SYSCALL-FAILURE ;

\ Opens the probed name for writing when the probe found a regular file.
: OPEN-PROBED-SLOT ( fd fd ^u8 n ^u8 n -- download-slot-open )
   {: probe:fd dir:fd name:^ nu:n p:^ u:n :}
   probe p u s" inspect resumed download slot" STAT-FD {: probed:stat :}
   probed REGULAR? 0= if DOWNLOAD-SLOT-OPEN-OCCUPIED exit then
   dir name nu FS:TRY-OPEN-WRITE-AT MATCH option
      none OF probe dir name nu p u SLOT-OPEN-FAILED ENDOF
      some OF probed p u CHECK-SLOT-FILE ENDOF
   ;MATCH ;

: SLOT-PROBE-FAILED ( ^u8 n -- download-slot-open )
   {: p:^ u:n :}
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if DOWNLOAD-SLOT-OPEN-MISSING exit then
   e FS:ELOOP = if DOWNLOAD-SLOT-OPEN-OCCUPIED exit then
   e s" inspect resumed download slot" p u SYSCALL-FAILURE ;

\ The slot at the name in dir, open for writing when it is a regular file
\ that stays the inode its name held; a symlink there is occupied.
: OPEN-DOWNLOAD-SLOT ( fd ^u8 n ^u8 n -- download-slot-open )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF p u SLOT-PROBE-FAILED ENDOF
      some OF {: probe:fd :}
         DOWNLOAD-SLOT-OPEN-MISSING probe
         [: DROP-SLOT-OPEN probe dir name nu p u OPEN-PROBED-SLOT ;]
         CLOSING probe DISCARD
      ENDOF
   ;MATCH ;

\ A new unnamed file in dir; o names the operation that makes it.
: UNNAMED-FILE ( fd ^u8 n ^u8 n -- fd )
   {: dir:fd p:^ u:n o:^ ou:n :}
   -1 >FD [: drop dir FS:TEMP-AT ;] [: o ou p u IO-FAILURE ;] FS-FAILS ;

\ Binds the unnamed file at offset 0 and names it; false when the name
\ is taken.
: INSTALL-SLOT ( fd fd ^u8 n ^u8 n binding -- bool )
   {: f:fd dir:fd name:^ nu:n p:^ u:n b:binding :}
   f DOWNLOAD-PARTIAL-XATTR b 0 DOWNLOAD-SLOT-STATE-MAKE
   ENCODE-DOWNLOAD-SLOT-STATE true p u s" mark resumed download slot"
   SET-XATTR
   f p u s" sync new resumed download slot" SYNC-FILE
   f dir name nu FS:TRY-LINK-AT if
      dir p u s" sync new resumed download slot entry" SYNC-DIRECTORY
      true exit
   then
   FS:ERRNO FS:EEXIST <> if
      s" install new resumed download slot" p u IO-FAILURE
   then false ;

\ A new slot at the name in dir bound to b; none when the name is taken.
: CREATE-DOWNLOAD-SLOT ( fd ^u8 n ^u8 n binding -- option<fd> )
   {: dir:fd name:^ nu:n p:^ u:n b:binding :}
   dir p u s" create resumed download slot" UNNAMED-FILE {: f:fd :}
   false f [: drop f dir name nu p u b INSTALL-SLOT ;] CLOSING
   if f OPTION:SOME exit then
   f DISCARD OPTION:NONE ;

\ Empties the open slot c and binds it to b at offset 0, its stage marker
\ cleared; true when its name still holds it then.
: CLEAR-SLOT ( fd fd ^u8 n ^u8 n binding -- bool )
   {: c:fd dir:fd name:^ nu:n p:^ u:n b:binding :}
   [: c 0 FD:RESIZE ;]
   [: s" truncate resumed download slot for reuse" p u IO-FAILURE ;]
   FS-FAILS
   c DOWNLOAD-PARTIAL-XATTR b 0 DOWNLOAD-SLOT-STATE-MAKE
   ENCODE-DOWNLOAD-SLOT-STATE false p u
   s" reset resumed download slot checkpoint" SET-XATTR
   c p u s" sync reset resumed download slot" SYNC-FILE
   c DOWNLOAD-STAGE-XATTR p u
   s" clear resumed download slot completion marker" REMOVE-XATTR
   c p u s" sync reusable resumed download slot" SYNC-FILE
   c dir name nu p u NAMED-INODE-MATCHES ;

\ Runs before, then clears c, when c is held's inode.
: REBIND-SLOT ( fd fd fd ^u8 n ^u8 n binding [ -- ] -- bool )
   {: held:fd c:fd dir:fd name:^ nu:n p:^ u:n b:binding before :}
   held p u s" inspect held resumed download slot" STAT-FD
   c p u s" inspect reusable resumed download slot" STAT-FD
   SAME-INODE 0= if false exit then
   before [: s" reset resumed download slot" p u IO-FAILURE ;] FS-FAILS
   c dir name nu p u b CLEAR-SLOT ;

\ The slot named again, rebound, when it is still held's inode; a throw
\ closes it.
: REBIND-OPENED ( fd fd fd ^u8 n ^u8 n binding [ -- ] -- option<fd> )
   {: held:fd c:fd dir:fd name:^ nu:n p:^ u:n b:binding before :}
   false c
   [: drop held c dir name nu p u b before REBIND-SLOT ;] CLOSING
   if c OPTION:SOME exit then
   c DISCARD OPTION:NONE ;

: REBIND-NAMED ( fd fd ^u8 n ^u8 n binding [ -- ] -- option<fd> )
   {: held:fd dir:fd name:^ nu:n p:^ u:n b:binding before :}
   dir name nu p u OPEN-DOWNLOAD-SLOT MATCH download-slot-open
      missing OF OPTION:NONE ENDOF
      file OF {: c:fd :} held c dir name nu p u b before REBIND-OPENED
      ENDOF
      occupied OF OPTION:NONE ENDOF
   ;MATCH ;

\ Rust's reset_download_slot_file_with: the slot held, a partial whose
\ name in dir still names it, reopened, emptied and bound to b at offset
\ 0; before runs just ahead of the truncate. None when held carries no
\ state or its name holds another entry, which stays as it is.
: RESET-DOWNLOAD-SLOT-FILE-WITH
   ( fd fd ^u8 n ^u8 n binding [ -- ] -- option<fd> )
   {: held:fd dir:fd name:^ nu:n p:^ u:n b:binding before :}
   held p u READ-DOWNLOAD-SLOT-STATE MATCH option
      none OF OPTION:NONE ENDOF
      some OF DOWNLOAD-SLOT-STATE-UNMAKE {: was:binding at:n :}
         held dir name nu p u b before REBIND-NAMED
      ENDOF
   ;MATCH ;

\ The location's slot reset for its own binding; none for an unnamed
\ file.
: RESET-DOWNLOAD-SLOT ( fd ^download-location -- option<fd> )
   {: f:fd loc :}
   loc DOWNLOAD-LOCATION-SOURCE @ MATCH download-source
      resumable OF {: dir:fd name:str path:str b:binding :}
         f dir name str> path str> b [: ;] RESET-DOWNLOAD-SLOT-FILE-WITH
      ENDOF
      disposable OF {: path:str :} OPTION:NONE ENDOF
   ;MATCH ;

\ ---- slot leases

\ A slot's file and state, Rust's (File, DownloadSlotState).
STRUCTURE owned-slot
   FIELD file fd
   FIELD state download-slot-state
;STRUCTURE

\ A slot as the lease found it: its file and state when it holds a
\ partial, and whether the lease may claim it.
STRUCTURE available-download-slot DERIVE addr
   FIELD slot n
   FIELD owned option<owned-slot>
   FIELD usable bool
;STRUCTURE

\ One lease runs at a time; it closes every file it holds here.
MAX-PARALLEL-DOWNLOADS TYPED-BUFFER SLOTS available-download-slot

: DROP-AVAILABLE ( available-download-slot -- ) drop ;

: NOT-OWNED ( -- option<owned-slot> ) OPTION:NONE ;

: UNOWNED ( n bool -- available-download-slot )
   {: slot:n usable:bool :}
   slot NOT-OWNED usable AVAILABLE-DOWNLOAD-SLOT-MAKE ;

\ The open slot's state, usable unless protected says its binding is.
: SLOT-STATE ( n fd ^u8 n [ binding -- bool ] -- available-download-slot )
   {: slot:n f:fd p:^ u:n protected :}
   f p u s" inspect resumed download slot" STAT-FD REGULAR? 0= if
      f DISCARD slot false UNOWNED exit
   then
   f p u READ-DOWNLOAD-SLOT-STATE MATCH option
      none OF f DISCARD slot false UNOWNED ENDOF
      some OF {: s:download-slot-state :}
         s DOWNLOAD-SLOT-STATE-UNMAKE {: b:binding at:n :}
         b protected execute 0= {: usable:bool :}
         slot f s OWNED-SLOT-MAKE OPTION:SOME usable
         AVAILABLE-DOWNLOAD-SLOT-MAKE
      ENDOF
   ;MATCH ;

: OWNED ( n fd ^u8 n [ binding -- bool ] -- available-download-slot )
   {: slot:n f:fd p:^ u:n protected :}
   slot false UNOWNED f
   [: DROP-AVAILABLE slot f p u protected SLOT-STATE ;] CLOSING ;

: SCAN-SLOT ( fd ^u8 n n [ binding -- bool ] -- available-download-slot )
   {: dir:fd d:^ du:n slot:n protected :}
   d du slot DOWNLOAD-SLOT-PATH {: p:^ u:n :}
   dir slot DOWNLOAD-SLOT-NAME p u OPEN-DOWNLOAD-SLOT
   MATCH download-slot-open
      missing OF slot true UNOWNED ENDOF
      file OF {: f:fd :} slot f p u protected OWNED ENDOF
      occupied OF slot false UNOWNED ENDOF
   ;MATCH ;

: SLOT-OWNED@ ( n -- option<owned-slot> )
   SLOTS AVAILABLE-DOWNLOAD-SLOT-OWNED @ ;

: SLOT-USABLE@ ( n -- bool ) SLOTS AVAILABLE-DOWNLOAD-SLOT-USABLE @ ;

: CLAIMED ( n -- ) false swap SLOTS AVAILABLE-DOWNLOAD-SLOT-USABLE ! ;

: CLEAR-SLOTS ( -- )
   MAX-PARALLEL-DOWNLOADS 0 ?do i false UNOWNED i SLOTS ! loop ;

: CLOSE-OWNED ( option<owned-slot> -- )
   MATCH option
      none OF ENDOF
      some OF OWNED-SLOT-UNMAKE {: f:fd s:download-slot-state :} f DISCARD
      ENDOF
   ;MATCH ;

: CLOSE-SLOTS ( -- )
   MAX-PARALLEL-DOWNLOADS 0 ?do i SLOT-OWNED@ CLOSE-OWNED loop
   CLEAR-SLOTS ;

: SCAN-SLOTS ( fd ^u8 n [ binding -- bool ] -- )
   {: dir:fd d:^ du:n protected :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      dir d du i protected SCAN-SLOT i SLOTS !
   loop ;

: OWNED-BY? ( option<owned-slot> binding -- bool )
   {: o:option<owned-slot> b:binding :}
   o MATCH option
      none OF false ENDOF
      some OF OWNED-SLOT-UNMAKE {: f:fd s:download-slot-state :}
         s OPTION:SOME b SLOT-BOUND?
      ENDOF
   ;MATCH ;

: NEW-LEASE ( ^u8 n n binding -- option<download-slot-lease> )
   {: d:^ du:n slot:n b:binding :}
   d du >str slot b DOWNLOAD-SLOT-LEASE-MAKE OPTION:SOME ;

\ The first slot whose partial is bound to b, claimed.
: BOUND-SLOT ( ^u8 n binding -- option<download-slot-lease> )
   {: d:^ du:n b:binding :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      i SLOT-OWNED@ b OWNED-BY? if
         i CLAIMED d du i b NEW-LEASE unloop exit
      then
   loop OPTION:NONE ;

\ Closes the slot a reset or create answered; whether there was one.
: TAKEN? ( option<fd> -- bool )
   MATCH option
      none OF false ENDOF
      some OF DISCARD true ENDOF
   ;MATCH ;

\ Rebinds the slot's partial to b, or makes the slot bound to b.
: TAKE-SLOT ( fd ^u8 n n binding -- bool )
   {: dir:fd d:^ du:n slot:n b:binding :}
   d du slot DOWNLOAD-SLOT-PATH {: p:^ u:n :}
   slot SLOT-OWNED@ MATCH option
      none OF dir slot DOWNLOAD-SLOT-NAME p u b CREATE-DOWNLOAD-SLOT ENDOF
      some OF OWNED-SLOT-UNMAKE {: f:fd s:download-slot-state :}
         f dir slot DOWNLOAD-SLOT-NAME p u b [: ;]
         RESET-DOWNLOAD-SLOT-FILE-WITH
      ENDOF
   ;MATCH TAKEN? ;

\ The first usable slot that takes b; each one tried is used up.
: CLAIM-SLOT ( fd ^u8 n binding -- option<download-slot-lease> )
   {: dir:fd d:^ du:n b:binding :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      i SLOT-USABLE@ if
         i CLAIMED
         dir d du i b TAKE-SLOT if d du i b NEW-LEASE unloop exit then
      then
   loop OPTION:NONE ;

\ Empties a usable slot's partial, its binding kept.
: FREE-SLOT ( fd ^u8 n n -- )
   {: dir:fd d:^ du:n slot:n :}
   d du slot DOWNLOAD-SLOT-PATH {: p:^ u:n :}
   slot SLOT-OWNED@ MATCH option
      none OF ENDOF
      some OF OWNED-SLOT-UNMAKE {: f:fd s:download-slot-state :}
         s DOWNLOAD-SLOT-STATE-UNMAKE {: b:binding at:n :}
         f dir slot DOWNLOAD-SLOT-NAME p u b [: ;]
         RESET-DOWNLOAD-SLOT-FILE-WITH TAKEN? drop
      ENDOF
   ;MATCH ;

: FREE-SLOTS ( fd ^u8 n -- )
   {: dir:fd d:^ du:n :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      i SLOT-USABLE@ if dir d du i FREE-SLOT then
   loop ;

: LEASE-IN
   ( fd ^u8 n binding [ binding -- bool ] -- option<download-slot-lease> )
   {: dir:fd d:^ du:n b:binding protected :}
   dir d du protected SCAN-SLOTS
   d du b BOUND-SLOT MATCH option
      none OF dir d du b CLAIM-SLOT ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH
   dir d du FREE-SLOTS ;

public

\ Rust's lease_download_slots for one download: the slot in directory d
\ whose partial is bound to it, else the first free or unprotected one,
\ rebound to it; none when no slot can be. Every other unprotected partial
\ is emptied, its binding kept. The lease holds d's span.
: LEASE-DOWNLOAD-SLOT
   ( ^u8 n download-slot-identity [ binding -- bool ]
     -- option<download-slot-lease> )
   {: d:^ du:n id:download-slot-identity protected :}
   d du s" open resumable download slot directory" OPEN-PRIVATE-DIRECTORY
   {: dir:fd :}
   CLEAR-SLOTS
   [: dir d du id SLOT-BINDING protected LEASE-IN ;]
   [: CLOSE-SLOTS dir DISCARD ;] finally ;

private

\ ---- download preparation

\ Feeds the next bytes of f, at most IO-SIZE of the left ones, to h;
\ answers the bytes left after them. A short file fails as a read.
: REHASH-CHUNK ( fd n ^u8 n ^DROPBOX:hasher -- n )
   {: f:fd left:n p:^ u:n h :}
   s" rehash resumed download checkpoint" {: o:^ ou:n :}
   left IO-SIZE min {: k:n :}
   0 [: drop f IO-BUF k FD-READ ;] [: o ou p u IO-FAILURE ;] FS-FAILS
   k < if 0 FS:CAUSE! o ou p u IO-FAILURE then
   IO-BUF k h DROPBOX:HASH-FEED
   left k - ;

\ Rust's hash_download_prefix: h begun and fed the slot's first offset
\ bytes, a whole number of checkpoints, and f left at offset.
: HASH-DOWNLOAD-PREFIX ( fd n ^u8 n ^DROPBOX:hasher -- )
   {: f:fd offset:n p:^ u:n h :}
   [: f 0 FD:SEEK ;] [: s" rewind resumed download" p u IO-FAILURE ;]
   FS-FAILS
   h DROPBOX:HASH-BEGIN
   offset begin dup 0 > while f swap p u h REHASH-CHUNK repeat drop
   [: f offset FD:SEEK ;]
   [: s" position resumed download" p u IO-FAILURE ;] FS-FAILS ;

: DROP-PREPARATION ( download-preparation -- ) drop ;
: DROP-STAGE-OUTCOME ( stage-outcome<n> -- ) drop ;

: READY ( ^download-partial -- download-preparation )
   LOCAL-DOWNLOAD--PREPARATION:ready ;
: EPHEMERAL ( -- download-preparation )
   LOCAL-DOWNLOAD--PREPARATION:ephemeral ;

: READY? ( download-preparation -- bool )
   MATCH download-preparation
      ready OF drop true ENDOF
      complete OF DROP-STAGE-OUTCOME false ENDOF
      ephemeral OF false ENDOF
   ;MATCH ;

: UNLESS-READY ( download-preparation [ -- ] -- download-preparation )
   {: p:download-preparation close :}
   p READY? 0= if close execute then
   p ;

\ Runs q; close frees what a ready partial would hold, when q throws or
\ answers no partial.
: PREPARING ( [ -- download-preparation ] [ -- ] -- download-preparation )
   {: q close :}
   EPHEMERAL [: DROP-PREPARATION q execute ;] catch {: code:n :}
   code 0= if close UNLESS-READY exit then
   close execute code throw ;

\ What a stage already at the download's name comes to, none when there
\ is none; a verified stage's descriptor is closed.
: EXISTING-OUTCOME ( download-stage -- option<stage-outcome<n>> )
   MATCH download-stage
      missing OF OPTION:NONE ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :} f DISCARD
         0 LOCAL-STAGE--OUTCOME:already-staged OPTION:SOME
      ENDOF
      destination-occupied OF LOCAL-STAGE--OUTCOME:destination-occupied
         OPTION:SOME
      ENDOF
   ;MATCH ;

: STAGE-PREPARATION ( download-stage -- option<download-preparation> )
   EXISTING-OUTCOME MATCH option
      none OF OPTION:NONE ENDOF
      some OF LOCAL-DOWNLOAD--PREPARATION:complete OPTION:SOME ENDOF
   ;MATCH ;

\ The download's stage name for target t, and its path below root path r
\ through the parent's path rel, laid in the arena.
: STAGE-PATHS
   ( ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n ^u8 n )
   {: r:^ ru:n rel:^ relu:n t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   s" download" t tu want ar INTERNAL-NAME {: name:^ nu:n :}
   r ru rel relu ar JOIN name nu ar JOIN {: sp:^ spu:n :}
   name nu sp spu ;

\ The location of target t's download into dir from the source src
\ answers, its stage named and the target kept in the arena before src
\ runs.
: NEW-LOCATION
   ( [ -- download-source ] fd ^u8 n ^u8 n ^u8 n DROPBOX:hash
     ^ARENA:arena -- download-location )
   {: src dir:fd r:^ ru:n rel:^ relu:n t:^ tu:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   r ru rel relu t tu want ar STAGE-PATHS {: name:^ nu:n sp:^ spu:n :}
   t tu ar KEEP {: target:str :}
   src execute dir name nu >str sp spu >str target want
   DOWNLOAD-LOCATION-MAKE ;

: NO-LOCATION ( -- download-location )
   s" " >str DOWNLOAD-SOURCE-DISPOSABLE -1 >FD
   s" " >str s" " >str s" " >str NO-HASH DOWNLOAD-LOCATION-MAKE ;
: DROP-LOCATION ( download-location -- ) drop ;

: LOCATION-PATH ( download-location -- ^u8 n )
   DOWNLOAD-LOCATION-UNMAKE
   {: src:download-source dir:fd name:str sp:str t:str want:DROPBOX:hash :}
   src SOURCE-PATH ;

: INSPECT-LOCATION ( download-location ^ARENA:arena -- download-stage )
   {: loc:download-location ar:^ARENA:arena :}
   loc DOWNLOAD-LOCATION-UNMAKE
   {: src:download-source dir:fd name:str sp:str t:str want:DROPBOX:hash :}
   dir name str> sp str> t str> want ar INSPECT-DOWNLOAD-STAGE ;

\ The partial of the location's download in f, at offset 0.
: NEW-PARTIAL ( download-location fd ^ARENA:arena -- ^download-partial )
   {: loc:download-location f:fd ar:^ARENA:arena :}
   ar PARTIALS-NEW {: x :}
   loc x DOWNLOAD-PARTIAL-LOCATION !
   f x DOWNLOAD-PARTIAL-FILE !
   0 x DOWNLOAD-PARTIAL-OFFSET !
   x DOWNLOAD-PARTIAL-AGGREGATE DROPBOX:HASH-BEGIN
   x ;

\ A partial in a new unnamed file in the staging directory s.
: DISPOSABLE-PARTIAL
   ( download-location ^u8 n ^ARENA:arena -- download-preparation )
   {: loc:download-location s:^ su:n ar:^ARENA:arena :}
   s su s" open disposable download staging directory"
   OPEN-PRIVATE-DIRECTORY {: staging:fd :}
   loc LOCATION-PATH {: p:^ u:n :}
   [: staging p u s" create disposable download stage" UNNAMED-FILE ;]
   [: staging DISCARD ;] finally {: f:fd :}
   EPHEMERAL f [: DROP-PREPARATION loc f ar NEW-PARTIAL READY ;]
   CLOSING ;

: DISPOSABLE
   ( download-location ^u8 n ^ARENA:arena -- download-preparation )
   {: loc:download-location s:^ su:n ar:^ARENA:arena :}
   loc ar INSPECT-LOCATION STAGE-PREPARATION MATCH option
      none OF loc s su ar DISPOSABLE-PARTIAL ENDOF
      some OF ENDOF
   ;MATCH ;

public

\ Rust's prepare_disposable_download_with_access_at: the stage below root
\ path r for target t holding want when one is complete, else a partial
\ in an unnamed file in the staging directory s, its paths in the arena.
\ The partial holds the target's parent directory.
: PREPARE-DISPOSABLE-DOWNLOAD-AT
   ( fd ^u8 n ^u8 n DROPBOX:hash ^u8 n ^ARENA:arena
     -- download-preparation )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash s:^ su:n
      ar:^ARENA:arena :}
   want s" prepare disposable download" REQUIRE-CONTENT-HASH
   root t tu true OPEN-PARENT MATCH option
      none OF t tu UNSAFE ENDOF
      some OF ENDOF
   ;MATCH PARENT-DIR-UNMAKE {: dir:fd last:str rel:str :}
   [: [: s su s" <unnamed-download>" ar JOIN >str
         DOWNLOAD-SOURCE-DISPOSABLE ;]
      dir r ru rel str> t tu want ar NEW-LOCATION s su ar DISPOSABLE ;]
   [: dir DISCARD ;] PREPARING ;

private

\ ---- partial ownership

: TARGET-DIR@ ( ^download-location -- fd )
   DOWNLOAD-LOCATION-TARGET-DIRECTORY @ ;
: STAGE-NAME@ ( ^download-location -- ^u8 n )
   DOWNLOAD-LOCATION-STAGE-NAME @ str> ;
: STAGE-PATH@ ( ^download-location -- ^u8 n )
   DOWNLOAD-LOCATION-STAGE-PATH @ str> ;
: TARGET@ ( ^download-location -- ^u8 n )
   DOWNLOAD-LOCATION-TARGET @ str> ;
: EXPECTED@ ( ^download-location -- DROPBOX:hash )
   DOWNLOAD-LOCATION-EXPECTED @ ;
: SOURCE@ ( ^download-location -- download-source )
   DOWNLOAD-LOCATION-SOURCE @ ;

: LOCATION-SOURCE ( download-location -- download-source )
   DOWNLOAD-LOCATION-UNMAKE
   {: src:download-source dir:fd name:str sp:str t:str want:DROPBOX:hash :}
   src ;

: RESUMABLE? ( download-source -- bool )
   MATCH download-source
      resumable OF {: dir:fd name:str path:str b:binding :} true ENDOF
      disposable OF {: path:str :} false ENDOF
   ;MATCH ;

: PARTIAL-FILE ( ^download-partial -- fd ) DOWNLOAD-PARTIAL-FILE @ ;

\ The partial's file's path: its slot's, or its unnamed file's.
: PARTIAL-PATH ( ^download-partial -- ^u8 n )
   DOWNLOAD-PARTIAL-LOCATION SOURCE@ SOURCE-PATH ;

\ Closes the location's directories: the target's and a slot's.
: CLOSE-LOCATION ( download-location -- )
   DOWNLOAD-LOCATION-UNMAKE
   {: src:download-source dir:fd name:str sp:str t:str want:DROPBOX:hash :}
   dir DISCARD
   src MATCH download-source
      resumable OF {: slots:fd n:str p:str b:binding :} slots DISCARD ENDOF
      disposable OF {: p:str :} ENDOF
   ;MATCH ;

public

\ Rust's drop of a partial: its file and its location's directories. It
\ closes a ready partial the daemon never appends to or restarts.
: CLOSE-PARTIAL ( ^download-partial -- )
   {: x :}
   x PARTIAL-FILE DISCARD x DOWNLOAD-PARTIAL-LOCATION @ CLOSE-LOCATION ;

private

\ Closes the file the partial held and keeps f in its place.
: SWAP-FILE ( fd ^download-partial -- )
   {: f:fd x :}
   x PARTIAL-FILE DISCARD f x DOWNLOAD-PARTIAL-FILE ! ;

\ Runs q; a stage read's failure becomes an io failure, as Rust's
\ From<StageIoError> for LocalError makes it.
: LOCAL-ERRORS ( R [ R -- R ] -- R )
   {: q :}
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   code LOCAL-CODE throw ;

: OCCUPIED-AT ( ^u8 n -- stage-outcome<n> )
   >str LOCAL-STAGE--OUTCOME:destination-occupied ;

: STAGED? ( stage-outcome<n> -- bool )
   MATCH stage-outcome
      staged OF drop true ENDOF
      already-staged OF drop true ENDOF
      content-changed OF DROP-HASH false ENDOF
      destination-occupied OF {: p:str :} false ENDOF
   ;MATCH ;

\ ---- slot promotion

\ Rust's copy_completed_slot's copy: the file's bytes, from its start,
\ staged when they hash to the location's content.
: COPY-INTO-STAGE ( fd ^download-location ^ARENA:arena -- stage-outcome<n> )
   {: f:fd loc ar:^ARENA:arena :}
   loc TARGET@ loc EXPECTED@ ar STAGE-MARKER >str OPTION:SOME
   {: marker:option<str> :}
   loc TARGET-DIR@ loc STAGE-NAME@ loc STAGE-PATH@ loc EXPECTED@
   [: f -rot FD-READ ;] marker s" copy completed download slot" ar
   WRITE-VERIFIED-STAGE [: 0 ;] MAP-STAGE-WRITE ;

\ Rust's copy_completed_slot: the completed file copied and rehashed into
\ the stage; a slot staged from is emptied and keeps its binding.
: COPY-COMPLETED-SLOT
   ( fd ^download-location ^ARENA:arena -- stage-outcome<n> )
   {: f:fd loc ar:^ARENA:arena :}
   loc SOURCE@ SOURCE-PATH {: p:^ u:n :}
   [: f 0 FD:SEEK ;]
   [: s" rewind completed download slot" p u IO-FAILURE ;] FS-FAILS
   0 LOCAL-STAGE--OUTCOME:staged
   [: DROP-STAGE-OUTCOME f loc ar COPY-INTO-STAGE ;] LOCAL-ERRORS
   {: out:stage-outcome<n> :}
   out STAGED? if f loc RESET-DOWNLOAD-SLOT TAKEN? drop then
   out ;

\ The entry already at the stage's name: a verified stage, whose
\ descriptor closes, runs q and is staged already; o names the operation.
: RACED-STAGE
   ( ^download-location ^u8 n [ -- ] ^ARENA:arena -- stage-outcome<n> )
   {: loc o:^ ou:n q ar:^ARENA:arena :}
   loc @ ar INSPECT-LOCATION MATCH download-stage
      missing OF o ou loc TARGET@ CHANGED ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: s:fd print:MODEL:fingerprint :} s DISCARD
         q execute 0 LOCAL-STAGE--OUTCOME:already-staged
      ENDOF
      destination-occupied OF LOCAL-STAGE--OUTCOME:destination-occupied
      ENDOF
   ;MATCH ;

\ After the move into the stage failed with errno e: an entry at the
\ stage's name is inspected, q running for a verified one; another
\ filesystem is copied across; else the failure, o's for path p.
: MOVE-FAILED
   ( fd ^download-location ^ARENA:arena n ^u8 n ^u8 n [ -- ]
     -- stage-outcome<n> )
   {: f:fd loc ar:^ARENA:arena e:n o:^ ou:n p:^ u:n q :}
   e FS:EEXIST = if loc o ou q ar RACED-STAGE exit then
   e FS:EXDEV = if f loc ar COPY-COMPLETED-SLOT exit then
   e o ou p u SYSCALL-FAILURE ;

\ The stage made read-only by m and synced by s.
: SEAL-PROMOTED ( fd ^download-location ^u8 n ^u8 n -- stage-outcome<n> )
   {: f:fd loc m:^ mu:n s:^ su:n :}
   f loc STAGE-PATH@ m mu READ-ONLY
   f loc STAGE-PATH@ s su SYNC-FILE
   0 LOCAL-STAGE--OUTCOME:staged ;

\ Where the swapped stage went: the slot's name, or, when an entry took
\ that, the stage's, where it stays.
: RESTORED-PATH ( ^download-location fd ^u8 n ^u8 n -- ^u8 n )
   {: loc slots:fd name:^ nu:n p:^ u:n :}
   loc TARGET-DIR@ loc STAGE-NAME@ slots name nu FS:TRY-RENAME-NEW-AT if
      p u exit
   then
   FS:ERRNO FS:EEXIST <> if
      FS:ERRNO s" restore swapped resumed download" loc STAGE-PATH@
      SYSCALL-FAILURE
   then
   loc STAGE-PATH@ ;

\ Another inode took the slot's name before the move: it goes back.
: RESTORE-SWAPPED ( ^download-location fd ^u8 n ^u8 n -- stage-outcome<n> )
   {: loc slots:fd name:^ nu:n p:^ u:n :}
   loc slots name nu p u RESTORED-PATH {: at:^ atu:n :}
   slots p u s" sync restored download slot" SYNC-DIRECTORY
   loc TARGET-DIR@ loc STAGE-PATH@ s" sync restored download stage"
   SYNC-DIRECTORY
   at atu OCCUPIED-AT ;

\ The slot named the stage: sealed, when it is still the file held.
: PROMOTED-SLOT
   ( fd ^download-location fd ^u8 n ^u8 n -- stage-outcome<n> )
   {: f:fd loc slots:fd name:^ nu:n p:^ u:n :}
   f loc TARGET-DIR@ loc STAGE-NAME@ loc STAGE-PATH@ NAMED-INODE-MATCHES
   0= if loc slots name nu p u RESTORE-SWAPPED exit then
   slots p u s" sync consumed download slot" SYNC-DIRECTORY
   loc TARGET-DIR@ loc STAGE-PATH@ s" sync promoted download stage"
   SYNC-DIRECTORY
   f loc s" make resumed download stage immutable"
   s" sync completed download stage" SEAL-PROMOTED ;

\ Renames the slot, still bound to the download, to the stage's name;
\ before runs just ahead of the rename.
: MOVE-SLOT
   ( fd ^download-location [ -- ] ^ARENA:arena fd ^u8 n ^u8 n
     -- stage-outcome<n> )
   {: f:fd loc before ar:^ARENA:arena slots:fd name:^ nu:n p:^ u:n :}
   s" recover completed resumed download" {: o:^ ou:n :}
   f loc DOWNLOAD-SLOT-MATCHES 0= if p u OCCUPIED-AT exit then
   before [: s" promote completed download slot" p u IO-FAILURE ;] FS-FAILS
   slots name nu loc TARGET-DIR@ loc STAGE-NAME@ FS:TRY-RENAME-NEW-AT if
      f loc slots name nu p u PROMOTED-SLOT exit
   then
   f loc ar FS:ERRNO o ou p u [: f loc RESET-DOWNLOAD-SLOT TAKEN? drop ;]
   MOVE-FAILED ;

: LINKED-DISPOSABLE ( fd ^download-location -- stage-outcome<n> )
   {: f:fd loc :}
   loc TARGET-DIR@ loc STAGE-PATH@ s" sync promoted disposable download"
   SYNC-DIRECTORY
   f loc s" make disposable download stage immutable"
   s" sync disposable download stage" SEAL-PROMOTED ;

\ Rust's promote_completed_disposable: the unnamed file linked at the
\ stage's name; before runs just ahead of the link.
: PROMOTE-COMPLETED-DISPOSABLE
   ( fd ^download-location [ -- ] ^ARENA:arena -- stage-outcome<n> )
   {: f:fd loc before ar:^ARENA:arena :}
   s" promote completed disposable download" {: o:^ ou:n :}
   loc SOURCE@ SOURCE-PATH {: p:^ u:n :}
   before [: o ou p u IO-FAILURE ;] FS-FAILS
   f loc TARGET-DIR@ loc STAGE-NAME@ FS:TRY-LINK-AT if
      f loc LINKED-DISPOSABLE exit
   then
   f loc ar FS:ERRNO o ou p u [: ;] MOVE-FAILED ;

\ Rust's promote_completed_slot_with: the completed, marked file f moved
\ into the location's stage, before running just ahead of the move.
: PROMOTE-COMPLETED-SLOT-WITH
   ( fd ^download-location [ -- ] ^ARENA:arena -- stage-outcome<n> )
   {: f:fd loc before ar:^ARENA:arena :}
   loc SOURCE@ MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         f loc before ar slots name str> path str> MOVE-SLOT
      ENDOF
      disposable OF {: p:str :}
         f loc before ar PROMOTE-COMPLETED-DISPOSABLE
      ENDOF
   ;MATCH ;

: PROMOTE-COMPLETED-SLOT
   ( fd ^download-location ^ARENA:arena -- stage-outcome<n> )
   {: f:fd loc ar:^ARENA:arena :}
   f loc [: ;] ar PROMOTE-COMPLETED-SLOT-WITH ;

\ ---- partial downloads

1 BUFFER: EXTRA

\ Fills the span from read; a failure, or an end before the span is
\ full, is a stage read's.
: STAGE-READ-EXACT ( ^u8 n [ ^u8 n -- n ] ^u8 n ^u8 n -- )
   {: dst:^ cap:n read p:^ u:n o:^ ou:n :}
   0 begin dup cap < while
      {: done:n :}
      dst done + cap done - read p u o ou STAGE-READ-INTO {: k:n :}
      k 0= if 0 FS:CAUSE! o ou p u STAGE-READ then
      done k +
   repeat drop ;

\ Rust's discard_uncommitted_block: the file cut back to the offset.
: DISCARD-UNCOMMITTED-BLOCK ( ^download-partial -- )
   {: x :}
   x PARTIAL-PATH {: p:^ u:n :}
   [: x PARTIAL-FILE x DOWNLOAD-PARTIAL-OFFSET @ FD:RESIZE ;]
   [: s" discard incomplete resumed download block" p u IO-FAILURE ;]
   FS-FAILS ;

\ Runs q; a throw first discards the block it was writing.
: UNCOMMITTED ( ^download-partial [ -- ] -- )
   {: x q :}
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   x DISCARD-UNCOMMITTED-BLOCK code throw ;

: WRITE-DOWNLOAD ( ^download-partial ^u8 n -- )
   {: x b:^ k:n :}
   x PARTIAL-PATH {: p:^ u:n :}
   [: x PARTIAL-FILE b k FD:WRITE-FULL ;]
   [: s" write resumed download" p u IO-FAILURE ;] FS-FAILS ;

\ Reads k bytes, writes them to the file and feeds them to the hash.
: APPEND-CHUNK ( ^download-partial n [ ^u8 n -- n ] -- )
   {: x k:n read :}
   IO-BUF k read x DOWNLOAD-PARTIAL-LOCATION TARGET@
   s" read resumed download" STAGE-READ-EXACT
   x IO-BUF k WRITE-DOWNLOAD
   IO-BUF k x DOWNLOAD-PARTIAL-AGGREGATE DROPBOX:HASH-FEED ;

: COPY-BLOCK ( ^download-partial n [ ^u8 n -- n ] -- )
   {: x len:n read :}
   0 begin dup len < while
      {: done:n :}
      len done - IO-SIZE min {: k:n :}
      x k read APPEND-CHUNK
      done k +
   repeat drop ;

\ Appends a block of len bytes, then counts it in the offset.
: APPEND-BLOCK ( ^download-partial n [ ^u8 n -- n ] -- )
   {: x len:n read :}
   x [: x len read COPY-BLOCK ;] UNCOMMITTED
   len x DOWNLOAD-PARTIAL-OFFSET +! ;

\ Rust's persist_checkpoint: the offset recorded in a slot's state once
\ the bytes before it are durable.
: PERSIST-CHECKPOINT ( ^download-partial -- )
   {: x :}
   x PARTIAL-FILE {: f:fd :}
   x DOWNLOAD-PARTIAL-LOCATION SOURCE@ MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         f path str> s" sync resumed download checkpoint" SYNC-FILE
         f DOWNLOAD-PARTIAL-XATTR
         b x DOWNLOAD-PARTIAL-OFFSET @ DOWNLOAD-SLOT-STATE-MAKE
         ENCODE-DOWNLOAD-SLOT-STATE false path str>
         s" record resumed download checkpoint" SET-XATTR
         f path str> s" sync resumed download checkpoint marker" SYNC-FILE
      ENDOF
      disposable OF {: p:str :} ENDOF
   ;MATCH ;

: CHECKPOINT? ( n n -- bool )
   {: at:n total:n :}
   at DOWNLOAD-CHECKPOINT-BYTES mod 0= at total < and ;

: APPEND-BLOCKS ( ^download-partial n [ ^u8 n -- n ] -- )
   {: x total:n read :}
   begin x DOWNLOAD-PARTIAL-OFFSET @ total < while
      x total x DOWNLOAD-PARTIAL-OFFSET @ - DROPBOX:BLOCK min read
      APPEND-BLOCK
      x DOWNLOAD-PARTIAL-OFFSET @ total CHECKPOINT? if
         x PERSIST-CHECKPOINT
      then
   repeat ;

\ A partial whose bytes hash to another content: a slot still bound to
\ it restarts, else its path is occupied.
: MISMATCHED ( ^download-partial DROPBOX:hash -- stage-outcome<n> )
   {: x actual:DROPBOX:hash :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   loc SOURCE@ RESUMABLE? if
      x PARTIAL-FILE loc RESET-DOWNLOAD-SLOT TAKEN? 0= if
         x PARTIAL-PATH OCCUPIED-AT exit
      then
   then
   actual LOCAL-STAGE--OUTCOME:content-changed ;

\ Syncs the verified file, marks it complete and promotes it.
: COMPLETE-PARTIAL ( ^download-partial ^ARENA:arena -- stage-outcome<n> )
   {: x ar:^ARENA:arena :}
   x PARTIAL-FILE {: f:fd :}
   x PARTIAL-PATH {: p:^ u:n :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   f p u s" sync completed resumed download data" SYNC-FILE
   f DOWNLOAD-STAGE-XATTR loc TARGET@ loc EXPECTED@ ar STAGE-MARKER true
   p u s" mark completed resumed download" SET-XATTR
   f p u s" sync completed resumed download marker" SYNC-FILE
   f loc ar PROMOTE-COMPLETED-SLOT ;

\ Rust's DownloadPartial::finish.
: FINISH-PARTIAL ( ^download-partial ^ARENA:arena -- stage-outcome<n> )
   {: x ar:^ARENA:arena :}
   x DOWNLOAD-PARTIAL-AGGREGATE DROPBOX:HASH-END ar KEEP DROPBOX:>HASH
   {: actual:DROPBOX:hash :}
   actual x DOWNLOAD-PARTIAL-LOCATION EXPECTED@ SAME-CONTENT? 0= if
      x actual MISMATCHED exit
   then
   x ar COMPLETE-PARTIAL ;

: APPENDED
   ( ^download-partial n [ ^u8 n -- n ] ^ARENA:arena -- stage-outcome<n> )
   {: x total:n read ar:^ARENA:arena :}
   x DOWNLOAD-PARTIAL-LOCATION TARGET@ {: t:^ tu:n :}
   x DOWNLOAD-PARTIAL-OFFSET @ total > if
      s" validate resumed download size" t tu CHANGED
   then
   x total read APPEND-BLOCKS
   EXTRA 1 read t tu s" finish resumed download" STAGE-READ-INTO 0<> if
      s" validate resumed download length" t tu CHANGED
   then
   x ar FINISH-PARTIAL ;

: RESTARTED ( ^download-partial -- download-preparation )
   {: x :}
   x PARTIAL-FILE x DOWNLOAD-PARTIAL-LOCATION RESET-DOWNLOAD-SLOT
   MATCH option
      none OF x PARTIAL-PATH OCCUPIED-AT LOCAL-DOWNLOAD--PREPARATION:complete
      ENDOF
      some OF x SWAP-FILE
         0 x DOWNLOAD-PARTIAL-OFFSET !
         x DOWNLOAD-PARTIAL-AGGREGATE DROPBOX:HASH-BEGIN x READY
      ENDOF
   ;MATCH ;

public

\ Rust's DownloadPartial::restart: the partial's slot, still bound to its
\ download, emptied to start over; else its path is occupied. Anything
\ but a ready partial frees the partial.
: RESTART-PARTIAL ( ^download-partial -- download-preparation )
   {: x :}
   [: x RESTARTED ;] [: x CLOSE-PARTIAL ;] PREPARING ;

\ Rust's DownloadPartial::offset: the bytes the partial holds.
: PARTIAL-OFFSET@ ( ^download-partial -- n ) DOWNLOAD-PARTIAL-OFFSET @ ;

\ Rust's DownloadPartial::append: read's bytes up to total appended a
\ block at a time, a slot's offset recorded at each checkpoint, then the
\ whole verified and promoted into its stage. A failed read throws
\ E-STAGE-READ, its partial block discarded. It frees the partial.
: APPEND-PARTIAL
   ( ^download-partial n [ ^u8 n -- n ] ^ARENA:arena -- stage-outcome<n> )
   {: x total:n read ar:^ARENA:arena :}
   [: x total read ar APPENDED ;] [: x CLOSE-PARTIAL ;] finally ;

private

\ ---- slot preparation

\ The lease's slot directory opened, bound to the lease's download, its
\ slot's name and path laid in the arena before it opens.
: SLOT-SOURCE ( download-slot-lease ^ARENA:arena -- download-source )
   {: lease:download-slot-lease ar:^ARENA:arena :}
   lease DOWNLOAD-SLOT-LEASE-UNMAKE {: d:str slot:n b:binding :}
   slot DOWNLOAD-SLOT-NAME ar KEEP {: name:str :}
   d str> name str> ar JOIN >str {: path:str :}
   d str> s" open resumable download slot directory"
   OPEN-PRIVATE-DIRECTORY name path b DOWNLOAD-SOURCE-RESUMABLE ;

\ The source's slot opened; an unnamed file has none.
: SLOT-OPEN ( download-source -- download-slot-open )
   MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         slots name str> path str> OPEN-DOWNLOAD-SLOT
      ENDOF
      disposable OF {: p:str :} DOWNLOAD-SLOT-OPEN-MISSING ENDOF
   ;MATCH ;

\ The location's slot as a partial at offset 0, not yet checked.
: OPEN-SLOT ( download-location ^ARENA:arena -- download-preparation )
   {: loc:download-location ar:^ARENA:arena :}
   loc LOCATION-SOURCE SLOT-OPEN MATCH download-slot-open
      missing OF EPHEMERAL ENDOF
      file OF {: f:fd :}
         EPHEMERAL f [: DROP-PREPARATION loc f ar NEW-PARTIAL READY ;]
         CLOSING
      ENDOF
      occupied OF EPHEMERAL ENDOF
   ;MATCH ;

: SLOT-PREPARATION ( download-location ^ARENA:arena -- download-preparation )
   {: loc:download-location ar:^ARENA:arena :}
   loc ar INSPECT-LOCATION STAGE-PREPARATION MATCH option
      none OF loc ar OPEN-SLOT ENDOF
      some OF ENDOF
   ;MATCH ;

: SLOT-LENGTH ( stat ^u8 n -- n )
   {: st:stat p:^ u:n :}
   st STAT-UNMAKE {: d i m s ms mn cs cn :}
   s 0 < if 0 s" inspect resumed download size" p u SYSCALL-FAILURE then
   s ;

: TRUNCATE-TAIL ( ^download-partial n -- )
   {: x at:n :}
   x PARTIAL-PATH {: p:^ u:n :}
   [: x PARTIAL-FILE at FD:RESIZE ;]
   [: s" truncate resumed download tail" p u IO-FAILURE ;] FS-FAILS
   x PARTIAL-FILE p u s" sync truncated resumed download" SYNC-FILE ;

\ The partial resumed at the checkpoint at, its file length bytes long
\ cut back to it and its hash fed the bytes before it.
: RESUME-AT ( ^download-partial n n -- download-preparation )
   {: x at:n length:n :}
   length at <> if x at TRUNCATE-TAIL then
   x PARTIAL-FILE at x PARTIAL-PATH x DOWNLOAD-PARTIAL-AGGREGATE
   HASH-DOWNLOAD-PREFIX
   at x DOWNLOAD-PARTIAL-OFFSET !
   x READY ;

: RESET-THEN-RESUME ( ^download-partial -- download-preparation )
   {: x :}
   x PARTIAL-FILE x DOWNLOAD-PARTIAL-LOCATION RESET-DOWNLOAD-SLOT
   MATCH option
      none OF EPHEMERAL ENDOF
      some OF x SWAP-FILE x 0 0 RESUME-AT ENDOF
   ;MATCH ;

\ Resumes at the checkpoint at, or from an emptied slot when reset says
\ so or at is no checkpoint inside the file's length.
: RESUME-FROM ( ^download-partial n n bool -- download-preparation )
   {: x at:n length:n reset:bool :}
   reset at DOWNLOAD-CHECKPOINT-BYTES mod 0<> or at length > or if
      x RESET-THEN-RESUME exit
   then
   x at length RESUME-AT ;

\ A slot marked complete: promoted when its bytes hash to the content,
\ else reset.
: RESUME-COMPLETED
   ( ^download-partial n n ^ARENA:arena -- download-preparation )
   {: x at:n length:n ar:^ARENA:arena :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   x PARTIAL-FILE x PARTIAL-PATH s" verify completed resumed download" ar
   E-UNSUPPORTED E-CHANGED HASH-STABLE-FILE
   loc EXPECTED@ SAME-CONTENT? if
      x PARTIAL-FILE loc ar PROMOTE-COMPLETED-SLOT
      LOCAL-DOWNLOAD--PREPARATION:complete exit
   then
   x at length true RESUME-FROM ;

: SLOT-MARKER ( ^download-partial ^ARENA:arena -- download-marker )
   {: x ar:^ARENA:arena :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   loc TARGET@ loc EXPECTED@ ar STAGE-MARKER {: m:^ mu:n :}
   x PARTIAL-FILE m mu x PARTIAL-PATH READ-DOWNLOAD-MARKER ;

: RESUME-MARKED ( ^download-partial n n ^ARENA:arena -- download-preparation )
   {: x at:n length:n ar:^ARENA:arena :}
   x ar SLOT-MARKER MATCH download-marker
      missing OF x at length false RESUME-FROM ENDOF
      expected OF x at length ar RESUME-COMPLETED ENDOF
      other OF x at length true RESUME-FROM ENDOF
   ;MATCH ;

: RESUME-BOUND
   ( ^download-partial download-slot-state binding n ^ARENA:arena
     -- download-preparation )
   {: x s:download-slot-state b:binding length:n ar:^ARENA:arena :}
   s DOWNLOAD-SLOT-STATE-UNMAKE {: held:binding at:n :}
   held b BINDING= 0= if EPHEMERAL exit then
   x at length ar RESUME-MARKED ;

\ The opened slot checked: a regular file bound to b, resumed.
: RESUME-SLOT
   ( ^download-partial binding ^ARENA:arena -- download-preparation )
   {: x b:binding ar:^ARENA:arena :}
   x PARTIAL-FILE x PARTIAL-PATH s" inspect resumed download" STAT-FD
   {: st:stat :}
   st REGULAR? 0= if EPHEMERAL exit then
   st x PARTIAL-PATH SLOT-LENGTH {: length:n :}
   x PARTIAL-FILE x PARTIAL-PATH READ-DOWNLOAD-SLOT-STATE MATCH option
      none OF EPHEMERAL ENDOF
      some OF x swap b length ar RESUME-BOUND ENDOF
   ;MATCH ;

: RESUMED
   ( download-preparation download-slot-lease ^ARENA:arena
     -- download-preparation )
   {: p:download-preparation lease:download-slot-lease ar:^ARENA:arena :}
   lease DOWNLOAD-SLOT-LEASE-UNMAKE {: d:str slot:n b:binding :}
   p MATCH download-preparation
      ready OF {: x :}
         [: x b ar RESUME-SLOT ;] [: x CLOSE-PARTIAL ;] PREPARING
      ENDOF
      complete OF LOCAL-DOWNLOAD--PREPARATION:complete ENDOF
      ephemeral OF EPHEMERAL ENDOF
   ;MATCH ;

\ Rust's open_parent with create; none is an unsafe path.
: OPEN-TARGET-PARENT ( fd ^u8 n -- parent-dir )
   {: root:fd t:^ tu:n :}
   root t tu true OPEN-PARENT MATCH option
      none OF t tu UNSAFE ENDOF
      some OF ENDOF
   ;MATCH ;

public

\ Rust's prepare_download_slot_with_access_at: the stage below root path
\ r for target t holding want when one is complete or the lease's slot
\ holds a verified completed partial, which it promotes; else the slot's
\ partial resumed from its last durable checkpoint, or from an emptied
\ slot; ephemeral when the slot is not the lease's. A ready partial holds
\ the target's parent and the slot directory; paths go in the arena.
: PREPARE-DOWNLOAD-SLOT-AT
   ( fd ^u8 n ^u8 n DROPBOX:hash download-slot-lease ^ARENA:arena
     -- download-preparation )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash
      lease:download-slot-lease ar:^ARENA:arena :}
   want s" prepare resumed download" REQUIRE-CONTENT-HASH
   root t tu OPEN-TARGET-PARENT PARENT-DIR-UNMAKE
   {: dir:fd last:str rel:str :}
   NO-LOCATION dir [: DROP-LOCATION [: lease ar SLOT-SOURCE ;]
      dir r ru rel str> t tu want ar NEW-LOCATION ;] CLOSING
   {: loc:download-location :}
   [: loc ar SLOT-PREPARATION ;] [: loc CLOSE-LOCATION ;] PREPARING
   lease ar RESUMED ;

private

\ ---- staged downloads

: STAGE-DOWNLOAD-IN
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash [ ^u8 n -- n ] ^ARENA:arena
     -- stage-outcome<n> )
   {: dir:fd r:^ ru:n rel:^ relu:n t:^ tu:n want:DROPBOX:hash read
      ar:^ARENA:arena :}
   r ru rel relu t tu want ar STAGE-PATHS {: name:^ nu:n sp:^ spu:n :}
   t tu want ar STAGE-MARKER >str OPTION:SOME {: marker:option<str> :}
   dir name nu sp spu want read marker s" stage download" ar
   WRITE-VERIFIED-STAGE [: 0 ;] MAP-STAGE-WRITE ;

: EXISTING-IN
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- option<stage-outcome<n>> )
   {: dir:fd r:^ ru:n rel:^ relu:n t:^ tu:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   r ru rel relu t tu want ar STAGE-PATHS {: name:^ nu:n sp:^ spu:n :}
   dir name nu sp spu t tu want ar INSPECT-DOWNLOAD-STAGE EXISTING-OUTCOME ;

public

\ Rust's stage_download_at: read's bytes staged beside target t below
\ root path r when they hash to want, marked as its owned download. A
\ failed read throws E-STAGE-READ.
: STAGE-DOWNLOAD-AT
   ( fd ^u8 n ^u8 n DROPBOX:hash [ ^u8 n -- n ] ^ARENA:arena
     -- stage-outcome<n> )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash read ar:^ARENA:arena :}
   want s" stage download" REQUIRE-CONTENT-HASH
   root t tu OPEN-TARGET-PARENT PARENT-DIR-UNMAKE
   {: dir:fd last:str rel:str :}
   [: dir r ru rel str> t tu want read ar STAGE-DOWNLOAD-IN ;]
   [: dir DISCARD ;] finally ;

\ Rust's existing_download_stage_at: what the stage for target t holding
\ want below root path r already comes to, none when it is missing.
: EXISTING-DOWNLOAD-STAGE-AT
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- option<stage-outcome<n>> )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   want s" inspect download stage" REQUIRE-CONTENT-HASH
   root t tu OPEN-TARGET-PARENT PARENT-DIR-UNMAKE
   {: dir:fd last:str rel:str :}
   [: dir r ru rel str> t tu want ar EXISTING-IN ;] [: dir DISCARD ;]
   finally ;

\ ---- installs

public

\ What installing a verified download came to: installed, installed by an
\ earlier attempt, no verified stage to install, other bytes at the
\ stage's path, kept as they were, or a target that no longer holds what
\ was expected, with what it holds, none when it is absent.
ENUM install-outcome
   VARIANT installed ;VARIANT
   VARIANT already-installed ;VARIANT
   VARIANT download-required ;VARIANT
   VARIANT stage-destination-occupied FIELD path str ;VARIANT
   VARIANT precondition-changed FIELD actual option<DROPBOX:hash> ;VARIANT
;ENUM

\ What moving an expected target to its guard came to: moved, moved by an
\ earlier attempt, or a target that no longer holds what was expected,
\ with what it or the guard holds, none when neither is there.
ENUM replacement-preparation
   VARIANT prepared ;VARIANT
   VARIANT already-prepared ;VARIANT
   VARIANT precondition-changed FIELD actual option<DROPBOX:hash> ;VARIANT
;ENUM

private

ENUM stage-cleanup
   VARIANT removed-or-absent ;VARIANT
   VARIANT destination-occupied FIELD path str ;VARIANT
;ENUM

\ An install in its open parent: the parent's descriptor and path, the
\ stage's name and path, the target's last component and path, the
\ content installed and the arena the names are laid in.
STRUCTURE install
   FIELD parent fd
   FIELD parent-path str
   FIELD stage-name str
   FIELD stage-path str
   FIELD target-name str
   FIELD target str
   FIELD desired DROPBOX:hash
   FIELD arena ^ARENA:arena
;STRUCTURE

: INSTALLED ( -- install-outcome ) LOCAL-INSTALL--OUTCOME:installed ;
: ALREADY-INSTALLED ( -- install-outcome )
   LOCAL-INSTALL--OUTCOME:already-installed ;
: DOWNLOAD-REQUIRED ( -- install-outcome )
   LOCAL-INSTALL--OUTCOME:download-required ;
: STAGE-OCCUPIED ( str -- install-outcome )
   LOCAL-INSTALL--OUTCOME:stage-destination-occupied ;
: INSTALL-CHANGED ( option<DROPBOX:hash> -- install-outcome )
   LOCAL-INSTALL--OUTCOME:precondition-changed ;
: PREPARED ( -- replacement-preparation )
   LOCAL-REPLACEMENT--PREPARATION:prepared ;
: ALREADY-PREPARED ( -- replacement-preparation )
   LOCAL-REPLACEMENT--PREPARATION:already-prepared ;
: PREPARE-CHANGED ( option<DROPBOX:hash> -- replacement-preparation )
   LOCAL-REPLACEMENT--PREPARATION:precondition-changed ;

\ No content: nothing is at the path.
: ABSENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;

: PRESENT? ( option<DROPBOX:hash> -- bool )
   MATCH option
      none OF false ENDOF
      some OF DROP-HASH true ENDOF
   ;MATCH ;

: GUARD-NAME ( ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: t:^ tu:n c:DROPBOX:hash ar:^ARENA:arena :}
   s" displaced" t tu c ar INTERNAL-NAME ;

\ Removes the name in dir; o names the operation and p the path.
: REMOVE-AT ( fd ^u8 n ^u8 n ^u8 n -- )
   {: dir:fd name:^ nu:n o:^ ou:n p:^ u:n :}
   dir name nu FS:TRY-REMOVE-FILE-AT 0= if o ou p u IO-FAILURE then ;

: WRITABLE ( fd ^u8 n ^u8 n -- )
   {: f:fd p:^ u:n o:^ ou:n :}
   [: f FS:MODE-PRIVATE-FILE FD:MODE! ;] [: o ou p u IO-FAILURE ;]
   FS-FAILS ;

\ The stage's file is as it was verified.
: VERIFY-DOWNLOAD-STAGE-BEFORE-RENAME ( verified-download-stage ^u8 n -- )
   {: s:verified-download-stage p:^ u:n :}
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   s" verify download stage before rename" {: o:^ ou:n :}
   f p u o ou STAT-FD p u FILE-FINGERPRINT
   print SAME-FINGERPRINT? 0= if o ou p u CHANGED then ;

\ Makes the owned download at f a plain file: writable, unmarked.
: RELEASE-OWNED-DOWNLOAD ( fd ^u8 n -- )
   {: f:fd p:^ u:n :}
   f p u s" make installed download writable" WRITABLE
   f DOWNLOAD-PARTIAL-XATTR p u s" clear resumed download marker"
   REMOVE-XATTR
   f p u s" sync installed download cleanup" SYNC-FILE
   f DOWNLOAD-STAGE-XATTR p u s" clear installed download marker"
   REMOVE-XATTR ;

\ Syncs the installed file; one still marked as LOCAL's is released first.
: FINISH-INSTALLED-DOWNLOAD ( fd ^u8 n bool -- )
   {: f:fd p:^ u:n owned:bool :}
   owned if f p u RELEASE-OWNED-DOWNLOAD then
   f p u s" sync installed download" SYNC-FILE ;

\ Whether the stage's file holds its verified bytes under the name.
: BOUND? ( verified-download-stage fd ^u8 n ^u8 n ^u8 n -- bool )
   {: s:verified-download-stage dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   f p u o ou STAT-FD p u FILE-FINGERPRINT
   print SAME-HASHED-CONTENT 0= if false exit then
   f dir name nu p u NAMED-INODE-MATCHES ;

\ Whether the renamed stage is the owned download of want at the name.
: OWNED-RENAME?
   ( verified-download-stage fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- bool )
   {: s:verified-download-stage dir:fd name:^ nu:n p:^ u:n
      want:DROPBOX:hash ar:^ARENA:arena :}
   p u want ar STAGE-MARKER {: m:^ mu:n :}
   s dir name nu p u s" verify renamed download content" BOUND?
   0= if false exit then
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   f m mu p u READ-DOWNLOAD-MARKER EXPECTED? ;

\ Releases and syncs the stage renamed to the name, which must be the
\ owned download of want before and after.
: SYNC-RENAMED-DOWNLOAD
   ( verified-download-stage fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: s:verified-download-stage dir:fd name:^ nu:n p:^ u:n
      want:DROPBOX:hash ar:^ARENA:arena :}
   s dir name nu p u want ar OWNED-RENAME? 0= if
      s" verify renamed download ownership" p u CHANGED
   then
   dir p u s" sync installed download rename" SYNC-DIRECTORY
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   f p u true FINISH-INSTALLED-DOWNLOAD
   s dir name nu p u s" verify installed download content" BOUND? 0= if
      s" verify installed download binding" p u CHANGED
   then ;

\ Finishes the open installed file when its content actual is want.
: FINISH-IF-WANTED
   ( fd DROPBOX:hash ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: f:fd actual:DROPBOX:hash p:^ u:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   actual want SAME-CONTENT? 0= if
      s" verify installed download" p u CHANGED
   then
   p u want ar STAGE-MARKER {: m:^ mu:n :}
   f m mu p u READ-DOWNLOAD-MARKER EXPECTED? {: owned:bool :}
   f p u owned FINISH-INSTALLED-DOWNLOAD ;

\ Syncs the download installed at the name, which must hold want, and
\ its entry; a file still marked as LOCAL's is released first.
: SYNC-INSTALLED-DOWNLOAD
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash ar:^ARENA:arena :}
   s" verify installed download" {: o:^ ou:n :}
   dir name nu p u o ou ar OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF o ou p u CHANGED ENDOF
      some OF HASHED-UNMAKE
         {: f:fd c:DROPBOX:hash print:MODEL:fingerprint :}
         [: f c p u want ar FINISH-IF-WANTED ;] [: f DISCARD ;] finally
      ENDOF
   ;MATCH
   dir p u s" sync installed download entry" SYNC-DIRECTORY ;

\ Removes the owned stage of want at the name in dir; another file
\ there is kept.
: REMOVE-VERIFIED-STAGE
   ( fd ^u8 n DROPBOX:hash ^u8 n ^u8 n ^ARENA:arena -- stage-cleanup )
   {: dir:fd name:^ nu:n want:DROPBOX:hash p:^ u:n t:^ tu:n
      ar:^ARENA:arena :}
   dir name nu p u t tu want ar INSPECT-DOWNLOAD-STAGE
   MATCH download-stage
      missing OF STAGE-CLEANUP-REMOVED-OR-ABSENT ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :} f DISCARD
         dir name nu s" remove verified staging file" p u REMOVE-AT
         STAGE-CLEANUP-REMOVED-OR-ABSENT
      ENDOF
      destination-occupied OF STAGE-CLEANUP-DESTINATION-OCCUPIED ENDOF
   ;MATCH ;

\ Removes target's guard for c when it holds c; other bytes are kept.
: REMOVE-GUARD-IF-VERIFIED ( fd ^u8 n DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd t:^ tu:n c:DROPBOX:hash ar:^ARENA:arena :}
   t tu c ar GUARD-NAME {: g:^ gu:n :}
   dir g gu t tu s" verify stale install guard" ar HASH-AT-IF-PRESENT
   MATCH option
      none OF ENDOF
      some OF c SAME-CONTENT? 0= if
            s" clean completed replacement" t tu OCCUPIED
         then
         dir g gu s" remove stale install guard" t tu REMOVE-AT
      ENDOF
   ;MATCH ;

\ The guard at path gp holds held: prepared when that is c.
: EXISTING-GUARD
   ( option<DROPBOX:hash> DROPBOX:hash ^u8 n -- replacement-preparation )
   {: held:option<DROPBOX:hash> c:DROPBOX:hash gp:^ gpu:n :}
   held c HOLDS? 0= if
      s" prepare download replacement" gp gpu OCCUPIED
   then
   ALREADY-PREPARED ;

\ The target is at its guard g, at path gp, now: prepared when the guard
\ holds c, else the guard goes back or is kept as a local conflict.
: VERIFY-DISPLACED
   ( fd ^u8 n ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- replacement-preparation )
   {: dir:fd g:^ gu:n gp:^ gpu:n tn:^ tnu:n t:^ tu:n c:DROPBOX:hash
      ar:^ARENA:arena :}
   dir t tu s" sync replacement displacement guard" SYNC-DIRECTORY
   dir g gu gp gpu s" verify displaced replacement file" ar
   HASH-AT-IF-PRESENT {: held:option<DROPBOX:hash> :}
   held c HOLDS? if PREPARED exit then
   dir g gu tn tnu t tu held ar RESTORE-OR-PRESERVE-CHANGED-GUARD
   held PREPARE-CHANGED ;

\ Renames the target to its guard g, at path gp, never over an entry.
: MOVE-TO-GUARD
   ( fd ^u8 n ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- replacement-preparation )
   {: dir:fd g:^ gu:n gp:^ gpu:n tn:^ tnu:n t:^ tu:n c:DROPBOX:hash
      ar:^ARENA:arena :}
   dir tn tnu dir g gu FS:TRY-RENAME-NEW-AT if
      dir g gu gp gpu tn tnu t tu c ar VERIFY-DISPLACED exit
   then
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if ABSENT PREPARE-CHANGED exit then
   e FS:EEXIST <> if
      s" move replaced file to displacement guard" t tu IO-FAILURE
   then
   dir g gu gp gpu s" verify raced replacement displacement" ar
   HASH-AT-IF-PRESENT c gp gpu EXISTING-GUARD ;

\ Moves the target at the name in dir, whose path is dp, to its guard
\ when it holds c; a guard already there holding c was moved before.
: PREPARE-REPLACEMENT-AT
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- replacement-preparation )
   {: dir:fd dp:^ du:n tn:^ tnu:n t:^ tu:n c:DROPBOX:hash
      ar:^ARENA:arena :}
   t tu c ar GUARD-NAME {: g:^ gu:n :}
   dp du g gu ar JOIN {: gp:^ gpu:n :}
   dir tn tnu t tu s" check replacement preparation precondition" ar
   HASH-AT-IF-PRESENT {: current:option<DROPBOX:hash> :}
   dir g gu gp gpu s" inspect replacement displacement guard" ar
   HASH-AT-IF-PRESENT {: held:option<DROPBOX:hash> :}
   held PRESENT? if held c gp gpu EXISTING-GUARD exit then
   current c HOLDS? 0= if current PREPARE-CHANGED exit then
   dir g gu gp gpu tn tnu t tu c ar MOVE-TO-GUARD ;

\ ---- an install's steps

: DESIRED ( install -- DROPBOX:hash )
   INSTALL-UNMAKE {: dir dp sn sp tn t want ar :} want ;

\ The content at x's target now; o names the operation.
: TARGET-HASH ( install ^u8 n -- option<DROPBOX:hash> )
   {: x:install o:^ ou:n :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir tn str> t str> o ou ar HASH-AT-IF-PRESENT ;

\ Syncs x's parent; o names the operation.
: SYNC-PARENT ( install ^u8 n -- )
   {: x:install o:^ ou:n :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir t str> o ou SYNC-DIRECTORY ;

\ Removes the name in x's parent; o names the operation.
: REMOVE-IN-PARENT ( install ^u8 n ^u8 n -- )
   {: x:install g:^ gu:n o:^ ou:n :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir g gu o ou t str> REMOVE-AT ;

: INSPECT-INSTALL-STAGE ( install -- download-stage )
   INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir sn str> sp str> t str> want ar INSPECT-DOWNLOAD-STAGE ;

\ Runs q on x's verified stage, closing it after; with none, or other
\ bytes at the stage's name, the install answers that.
: WITH-STAGE
   ( install [ install verified-download-stage -- install-outcome ]
     -- install-outcome )
   {: x:install q :}
   x INSPECT-INSTALL-STAGE MATCH download-stage
      missing OF DOWNLOAD-REQUIRED ENDOF
      verified OF {: s:verified-download-stage :}
         s VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :}
         [: x s q execute ;] [: f DISCARD ;] finally
      ENDOF
      destination-occupied OF STAGE-OCCUPIED ENDOF
   ;MATCH ;

\ x's target holds its content: syncs it and removes the stage.
: CLEAN-INSTALLED ( install -- stage-cleanup )
   INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir tn str> t str> want ar SYNC-INSTALLED-DOWNLOAD
   dir sn str> want sp str> t str> ar REMOVE-VERIFIED-STAGE ;

\ Runs q once the stage is gone; other bytes at its name answer the
\ install.
: CLEANED
   ( stage-cleanup [ -- install-outcome ] -- install-outcome )
   {: c:stage-cleanup q :}
   c MATCH stage-cleanup
      removed-or-absent OF q execute ENDOF
      destination-occupied OF STAGE-OCCUPIED ENDOF
   ;MATCH ;

: REMOVE-INSTALL-GUARD ( install DROPBOX:hash -- )
   {: x:install c:DROPBOX:hash :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir t str> c ar REMOVE-GUARD-IF-VERIFIED ;

: DROP-INSTALLED-GUARD ( install option<DROPBOX:hash> -- )
   {: x:install expected:option<DROPBOX:hash> :}
   expected MATCH option
      none OF ENDOF
      some OF {: c:DROPBOX:hash :}
         c s" clean replacement guard" REQUIRE-CONTENT-HASH
         x c REMOVE-INSTALL-GUARD
      ENDOF
   ;MATCH ;

\ An earlier attempt installed x: cleans up after it.
: FINISH-EARLIER-INSTALL
   ( install option<DROPBOX:hash> -- install-outcome )
   {: x:install expected:option<DROPBOX:hash> :}
   x CLEAN-INSTALLED
   [: x expected DROP-INSTALLED-GUARD
      x s" sync already-installed download" SYNC-PARENT
      ALREADY-INSTALLED ;] CLEANED ;

\ The target x's stage was renamed to exists: x's content there was
\ installed by another attempt.
: RACED-INITIAL-INSTALL ( install -- install-outcome )
   {: x:install :}
   x s" inspect raced initial install" TARGET-HASH
   {: actual:option<DROPBOX:hash> :}
   actual x DESIRED HOLDS? 0= if actual INSTALL-CHANGED exit then
   x CLEAN-INSTALLED
   [: x s" sync raced initial install cleanup" SYNC-PARENT
      ALREADY-INSTALLED ;] CLEANED ;

\ Renames x's verified stage to its target, never over an entry.
: RENAME-STAGE-INTO-ABSENT-TARGET
   ( install verified-download-stage -- install-outcome )
   {: x:install s:verified-download-stage :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   s sp str> VERIFY-DOWNLOAD-STAGE-BEFORE-RENAME
   dir sn str> dir tn str> FS:TRY-RENAME-NEW-AT if
      s dir tn str> t str> want ar SYNC-RENAMED-DOWNLOAD
      INSTALLED exit
   then
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if DOWNLOAD-REQUIRED exit then
   e FS:EEXIST <> if
      s" install download into absent path" t str> IO-FAILURE
   then
   x RACED-INITIAL-INSTALL ;

: INSTALL-ABSENT ( install option<DROPBOX:hash> -- install-outcome )
   {: x:install current:option<DROPBOX:hash> :}
   current PRESENT? if current INSTALL-CHANGED exit then
   x [: RENAME-STAGE-INTO-ABSENT-TARGET ;] WITH-STAGE ;

\ The guard of c is cleaned after a raced target whose content is actual.
: SETTLE-PREPARED
   ( install DROPBOX:hash DROPBOX:hash -- install-outcome )
   {: x:install c:DROPBOX:hash actual:DROPBOX:hash :}
   x c REMOVE-INSTALL-GUARD
   actual x DESIRED SAME-CONTENT? if
      x s" sync raced prepared replacement cleanup" SYNC-PARENT
      ALREADY-INSTALLED exit
   then
   x s" sync raced prepared replacement" SYNC-PARENT
   actual OPTION:SOME INSTALL-CHANGED ;

\ After the target moved to its guard, an entry holding actual raced in.
: RACED-PREPARED
   ( DROPBOX:hash install DROPBOX:hash -- install-outcome )
   {: actual:DROPBOX:hash x:install c:DROPBOX:hash :}
   actual x DESIRED SAME-CONTENT? 0= if
      x c actual SETTLE-PREPARED exit
   then
   x CLEAN-INSTALLED [: x c actual SETTLE-PREPARED ;] CLEANED ;

\ The guard g is removed after the rename found an entry at the target.
: SETTLE-RACED
   ( install ^u8 n option<DROPBOX:hash> -- install-outcome )
   {: x:install g:^ gu:n actual:option<DROPBOX:hash> :}
   x g gu s" remove recovered displacement guard" REMOVE-IN-PARENT
   actual x DESIRED HOLDS? if
      x s" sync raced replacement cleanup" SYNC-PARENT
      ALREADY-INSTALLED exit
   then
   x s" sync raced replacement" SYNC-PARENT
   actual INSTALL-CHANGED ;

: RACED-REPLACEMENT ( install ^u8 n -- install-outcome )
   {: x:install g:^ gu:n :}
   x s" inspect raced install destination" TARGET-HASH
   {: actual:option<DROPBOX:hash> :}
   actual x DESIRED HOLDS? 0= if x g gu actual SETTLE-RACED exit then
   x CLEAN-INSTALLED [: x g gu actual SETTLE-RACED ;] CLEANED ;

\ The stage renamed to the target; the guard g it displaced is removed.
: REPLACED
   ( verified-download-stage install ^u8 n -- install-outcome )
   {: s:verified-download-stage x:install g:^ gu:n :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   s dir tn str> t str> want ar SYNC-RENAMED-DOWNLOAD
   x g gu s" remove displaced install guard" REMOVE-IN-PARENT
   x s" sync completed replacement" SYNC-PARENT
   INSTALLED ;

\ Renames the stage to the target, now at its guard for c.
: RENAME-REPLACEMENT
   ( verified-download-stage install DROPBOX:hash -- install-outcome )
   {: s:verified-download-stage x:install c:DROPBOX:hash :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   t str> c ar GUARD-NAME {: g:^ gu:n :}
   s sp str> VERIFY-DOWNLOAD-STAGE-BEFORE-RENAME
   dir sn str> dir tn str> FS:TRY-RENAME-NEW-AT if
      s x g gu REPLACED exit
   then
   FS:ERRNO FS:EEXIST <> if
      s" install verified replacement" t str> IO-FAILURE
   then
   x g gu RACED-REPLACEMENT ;

\ The target is at its guard for c, unless an entry raced in after.
: RESUME-REPLACEMENT
   ( verified-download-stage install DROPBOX:hash -- install-outcome )
   {: s:verified-download-stage x:install c:DROPBOX:hash :}
   x s" resume prepared replacement" TARGET-HASH MATCH option
      none OF s x c RENAME-REPLACEMENT ENDOF
      some OF x c RACED-PREPARED ENDOF
   ;MATCH ;

: PREPARE-INSTALL ( install DROPBOX:hash -- replacement-preparation )
   {: x:install c:DROPBOX:hash :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir dp str> tn str> t str> c ar PREPARE-REPLACEMENT-AT ;

: REPLACE-WITH-STAGE
   ( install verified-download-stage DROPBOX:hash -- install-outcome )
   {: x:install s:verified-download-stage c:DROPBOX:hash :}
   x c PREPARE-INSTALL MATCH replacement-preparation
      prepared OF s x c RESUME-REPLACEMENT ENDOF
      already-prepared OF s x c RESUME-REPLACEMENT ENDOF
      precondition-changed OF INSTALL-CHANGED ENDOF
   ;MATCH ;

\ Replaces x's target, which held c, with the verified stage.
: INSTALL-REPLACEMENT ( install DROPBOX:hash -- install-outcome )
   {: x:install c:DROPBOX:hash :}
   c s" install replacement" REQUIRE-CONTENT-HASH
   x [: c REPLACE-WITH-STAGE ;] WITH-STAGE ;

: INSTALL-IN-PARENT ( install option<DROPBOX:hash> -- install-outcome )
   {: x:install expected:option<DROPBOX:hash> :}
   x s" check install precondition" TARGET-HASH
   {: current:option<DROPBOX:hash> :}
   current x DESIRED HOLDS? if x expected FINISH-EARLIER-INSTALL exit then
   expected MATCH option
      none OF x current INSTALL-ABSENT ENDOF
      some OF {: c:DROPBOX:hash :} x c INSTALL-REPLACEMENT ENDOF
   ;MATCH ;

\ The install of t's content want in the parent f, opened at rel below
\ the root at r.
: INSTALL-OF
   ( fd str str ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- install )
   {: f:fd tn:str rel:str r:^ ru:n t:^ tu:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   r ru rel str> ar JOIN {: dp:^ du:n :}
   s" download" t tu want ar INTERNAL-NAME {: sn:^ snu:n :}
   dp du sn snu ar JOIN {: sp:^ spu:n :}
   f dp du >str sn snu >str sp spu >str tn t tu >str want ar
   INSTALL-MAKE ;

public

\ Renames the verified stage of want over target t below the root fd,
\ whose path is r, only while t holds expected, or is absent when
\ expected is none; a target that changed is kept, never overwritten.
\ With expected none, E-UNSUPPORTED or E-UNREADABLE is about t's own
\ name; a replacement's guard or local conflict name can throw them too.
: INSTALL-DOWNLOAD-AT
   ( fd ^u8 n ^u8 n DROPBOX:hash option<DROPBOX:hash> ^ARENA:arena
     -- install-outcome )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash
      expected:option<DROPBOX:hash> ar:^ARENA:arena :}
   want s" install download" REQUIRE-CONTENT-HASH
   root t tu false OPEN-PARENT MATCH option
      none OF DOWNLOAD-REQUIRED ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         [: f name rel r ru t tu want ar INSTALL-OF
            expected INSTALL-IN-PARENT ;]
         [: f DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ ---- deletes

public

\ What a conditional delete of a local file came to: the expected file
\ removed now or by an earlier attempt, or other content found, none
\ when nothing is there.
ENUM delete-outcome
   VARIANT deleted ;VARIANT
   VARIANT already-deleted ;VARIANT
   VARIANT precondition-changed FIELD actual option<DROPBOX:hash> ;VARIANT
;ENUM

private

\ A delete in its open parent: the descriptor, the target's last component,
\ the target, the guard's name and the path a failure names for it, and the
\ content the delete expects.
STRUCTURE deletion
   FIELD dir fd
   FIELD name str
   FIELD target str
   FIELD guard str
   FIELD guard-path str
   FIELD want DROPBOX:hash
;STRUCTURE

: DELETION-WANT ( deletion -- DROPBOX:hash )
   DELETION-UNMAKE {: d:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   want ;

\ The content of the guard, none when it is absent; o names the read.
: GUARD-CONTENT
   ( deletion ^u8 n ^ARENA:arena -- option<DROPBOX:hash> )
   {: x:deletion o:^ ou:n ar:^ARENA:arena :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir g str> gp str> o ou ar HASH-AT-IF-PRESENT ;

\ Whether a guard holding the expected content is there; other bytes are
\ kept and stop the operation oc names. i names the read.
: GUARD-HELD? ( deletion ^u8 n ^u8 n ^ARENA:arena -- bool )
   {: x:deletion i:^ iu:n oc:^ ocu:n ar:^ARENA:arena :}
   x i iu ar GUARD-CONTENT MATCH option
      none OF false ENDOF
      some OF x DELETION-WANT SAME-CONTENT? 0= if
            x DELETION-UNMAKE
            {: d:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
            oc ocu gp str> OCCUPIED
         then true
      ENDOF
   ;MATCH ;

\ Removes the guard, then syncs its directory; o names the removal, sy
\ the sync.
: REMOVE-GUARD ( deletion ^u8 n ^u8 n -- )
   {: x:deletion o:^ ou:n sy:^ syu:n :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir g str> FS:TRY-REMOVE-FILE-AT 0= if o ou t str> IO-FAILURE then
   dir t str> sy syu SYNC-DIRECTORY ;

\ The guard holds other content than expected: it goes back to the target,
\ or is kept beside an entry raced in there.
: GUARD-CHANGED
   ( deletion option<DROPBOX:hash> ^ARENA:arena -- delete-outcome )
   {: x:deletion c:option<DROPBOX:hash> ar:^ARENA:arena :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir g str> n str> t str> c ar RESTORE-OR-PRESERVE-CHANGED-GUARD
   c LOCAL-DELETE--OUTCOME:precondition-changed ;

\ The target is absent: a guard holding the expected content finishes an
\ interrupted delete.
: FINISH-INTERRUPTED ( deletion ^ARENA:arena -- delete-outcome )
   {: x:deletion ar:^ARENA:arena :}
   x s" inspect interrupted deletion" ar GUARD-CONTENT
   {: c:option<DROPBOX:hash> :}
   c x DELETION-WANT HOLDS? if
      x s" finish interrupted deletion" s" sync interrupted deletion"
      REMOVE-GUARD LOCAL-DELETE--OUTCOME:deleted exit
   then
   c MATCH option
      none OF LOCAL-DELETE--OUTCOME:already-deleted ENDOF
      some OF drop x c ar GUARD-CHANGED ENDOF
   ;MATCH ;

\ Other content is at the target: a guard holding the expected content is
\ removed, and the outcome names what is there.
: RACED-DELETE ( deletion DROPBOX:hash ^ARENA:arena -- delete-outcome )
   {: x:deletion c:DROPBOX:hash ar:^ARENA:arena :}
   x s" inspect raced deletion guard" s" clean raced local deletion" ar
   GUARD-HELD? if
      x s" remove raced deletion guard"
      s" sync raced deletion guard removal" REMOVE-GUARD
   then
   c OPTION:SOME LOCAL-DELETE--OUTCOME:precondition-changed ;

\ Moves the target to the guard's name and syncs; false when the target
\ is gone by now.
: DISPLACE ( deletion -- bool )
   {: x:deletion :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir n str> dir g str> FS:TRY-RENAME-NEW-AT if
      dir t str> s" sync deletion displacement" SYNC-DIRECTORY true exit
   then
   FS:ERRNO FS:ENOENT = if false exit then
   s" move deleted file to displacement guard" t str> IO-FAILURE ;

\ The target holds the expected content: it moves aside to the guard and
\ is removed there only while the guard still holds it.
: DELETE-EXPECTED ( deletion ^ARENA:arena -- delete-outcome )
   {: x:deletion ar:^ARENA:arena :}
   x s" inspect deletion guard" s" prepare local deletion" ar
   GUARD-HELD? if
      x s" remove stale deletion guard"
      s" sync stale deletion guard removal" REMOVE-GUARD
   then
   x DISPLACE 0= if LOCAL-DELETE--OUTCOME:already-deleted exit then
   x s" verify deletion displacement" ar GUARD-CONTENT
   {: c:option<DROPBOX:hash> :}
   c x DELETION-WANT HOLDS? 0= if x c ar GUARD-CHANGED exit then
   x s" delete verified displaced file" s" sync local deletion"
   REMOVE-GUARD LOCAL-DELETE--OUTCOME:deleted ;

: DELETE-IN ( deletion ^ARENA:arena -- delete-outcome )
   {: x:deletion ar:^ARENA:arena :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir n str> t str> s" check delete precondition" ar HASH-AT-IF-PRESENT
   {: c:option<DROPBOX:hash> :}
   c MATCH option
      none OF x ar FINISH-INTERRUPTED ENDOF
      some OF {: h:DROPBOX:hash :}
         h want SAME-CONTENT? if x ar DELETE-EXPECTED exit then
         x h ar RACED-DELETE
      ENDOF
   ;MATCH ;

\ The deletion of t in the parent f, opened at rel below the root at r,
\ its guard named in the arena.
: DELETION-OF
   ( fd str str ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- deletion )
   {: f:fd tn:str rel:str r:^ ru:n t:^ tu:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   s" deleted" t tu want ar INTERNAL-NAME {: g:^ gu:n :}
   r ru rel str> ar JOIN g gu ar JOIN {: gp:^ gpu:n :}
   f tn t tu >str g gu >str gp gpu >str want DELETION-MAKE ;

\ The delete in the open parent, which closes after it; r is the root's
\ path, which failures name.
: DELETE-BELOW
   ( parent-dir ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- delete-outcome )
   {: pd:parent-dir r:^ ru:n t:^ tu:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   pd PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
   [: dir name path r ru t tu want ar DELETION-OF ar DELETE-IN ;]
   [: dir DISCARD ;] finally ;

public

\ Rust's delete_local_at: deletes the target below the root, whose path is
\ r, while it holds want. It moves aside under a guard name first, and a
\ guard left by an interrupted attempt is finished or put back.
: DELETE-LOCAL-AT
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- delete-outcome )
   {: root:fd r:^ ru:n t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   want s" delete local file" REQUIRE-CONTENT-HASH
   root t tu false OPEN-PARENT MATCH option
      none OF LOCAL-DELETE--OUTCOME:already-deleted ENDOF
      some OF r ru t tu want ar DELETE-BELOW ENDOF
   ;MATCH ;

\ ---- directories

\ What making a directory came to: made, already there, or another entry
\ or a change at its path, which a fresh scan observes.
ENUM create-directory-outcome
   created already-present fresh-observation
;ENUM

\ What removing an empty directory came to: removed, already absent, or
\ an entry that is not one or not empty, which a fresh scan observes.
ENUM delete-directory-outcome
   deleted already-absent fresh-observation
;ENUM

private

\ A directory open at the name in dir is synced with its entry; a missing
\ name, a non-directory or a symlink there is a fresh observation.
: EXISTING-DIRECTORY ( fd ^u8 n ^u8 n -- create-directory-outcome )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-OPEN-DIR-AT MATCH option
      none OF FS:ERRNO {: e:n :}
         e FS:ENOENT = e FS:ENOTDIR = or e FS:ELOOP = or 0= if
            s" inspect occupied local directory path" p u IO-FAILURE
         then LOCAL-CREATE--DIRECTORY--OUTCOME:fresh-observation
      ENDOF
      some OF {: d:fd :}
         [: d p u s" sync existing local directory" SYNC-DIRECTORY ;]
         [: d DISCARD ;] finally
         dir p u s" sync existing local directory entry" SYNC-DIRECTORY
         LOCAL-CREATE--DIRECTORY--OUTCOME:already-present
      ENDOF
   ;MATCH ;

\ Opens the directory just made at the name in dir and syncs it.
: SYNC-MADE-DIRECTORY ( fd ^u8 n ^u8 n -- )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu p u OPEN-DIRECTORY-AT {: d:fd :}
   [: d p u s" sync created local directory" SYNC-DIRECTORY ;]
   [: d DISCARD ;] finally ;

: MAKE-DIRECTORY-IN ( fd ^u8 n ^u8 n -- create-directory-outcome )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:MODE-PRIVATE-DIR FS:TRY-MAKE-DIR-AT if
      dir p u s" sync created local directory entry" SYNC-DIRECTORY
      dir name nu p u SYNC-MADE-DIRECTORY
      LOCAL-CREATE--DIRECTORY--OUTCOME:created exit
   then
   FS:ERRNO FS:EEXIST <> if s" create local directory" p u IO-FAILURE then
   dir name nu p u EXISTING-DIRECTORY ;

\ Whether a failed rmdir found an entry that is not an empty directory.
: OCCUPIED-DIRECTORY? ( n -- bool )
   {: e:n :}
   e FS:ENOTEMPTY = e FS:EEXIST = or e FS:ENOTDIR = or e FS:EISDIR = or ;

: REMOVE-DIRECTORY-IN ( fd ^u8 n ^u8 n -- delete-directory-outcome )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-REMOVE-DIR-AT if
      dir p u s" sync deleted local directory" SYNC-DIRECTORY
      LOCAL-DELETE--DIRECTORY--OUTCOME:deleted exit
   then
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if LOCAL-DELETE--DIRECTORY--OUTCOME:already-absent exit then
   e OCCUPIED-DIRECTORY? if
      LOCAL-DELETE--DIRECTORY--OUTCOME:fresh-observation exit
   then
   s" delete empty local directory" p u IO-FAILURE ;

public

\ Makes the directory at p below the root, its missing parents as well;
\ it never follows a link or replaces an entry.
: CREATE-DIRECTORY-AT ( fd ^u8 n -- create-directory-outcome )
   {: root:fd p:^ u:n :}
   root p u true OPEN-PARENT MATCH option
      none OF p u UNSAFE ENDOF
      some OF PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
         [: dir name str> p u MAKE-DIRECTORY-IN ;] [: dir DISCARD ;]
         finally
      ENDOF
   ;MATCH ;

\ Removes the directory at p below the root only while it is empty.
: DELETE-DIRECTORY-AT ( fd ^u8 n -- delete-directory-outcome )
   {: root:fd p:^ u:n :}
   root p u false OPEN-PARENT MATCH option
      none OF LOCAL-DELETE--DIRECTORY--OUTCOME:already-absent ENDOF
      some OF PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
         [: dir name str> p u REMOVE-DIRECTORY-IN ;] [: dir DISCARD ;]
         finally
      ENDOF
   ;MATCH ;

\ ---- conflicts

\ What writing one side of a conflict came to: a new copy at path,
\ relative to the root, the same bytes already there, or supplied bytes
\ whose hash is actual.
ENUM conflict-outcome
   VARIANT created FIELD path str ;VARIANT
   VARIANT already-present FIELD path str ;VARIANT
   VARIANT content-changed FIELD actual DROPBOX:hash ;VARIANT
;ENUM

\ The path, relative to the root, of p's conflict copy for side holding c.
: CONFLICT-RELATIVE-PATH
   ( ^u8 n conflict-side DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: p:^ u:n side:conflict-side c:DROPBOX:hash ar:^ARENA:arena :}
   p u PARENT-PATH p u side c ar CONFLICT-NAME ar JOIN ;

private

\ The stage written at the conflict's path rel; another file there is
\ kept.
: CONFLICT-RESULT ( stage-write ^u8 n -- conflict-outcome )
   {: w:stage-write rel:^ relu:n :}
   w MATCH stage-write
      created OF rel relu >str LOCAL-CONFLICT--OUTCOME:created ENDOF
      reused OF rel relu >str LOCAL-CONFLICT--OUTCOME:already-present
      ENDOF
      mismatch OF LOCAL-CONFLICT--OUTCOME:content-changed ENDOF
      destination-occupied OF {: q:str :}
         s" materialize conflict" q str> OCCUPIED
      ENDOF
   ;MATCH ;

\ The conflict copy written in p's parent dir, its names laid in the
\ arena; r is the root's path.
: CONFLICT-IN
   ( fd ^u8 n ^u8 n conflict-side DROPBOX:hash [ ^u8 n -- n ]
     ^ARENA:arena -- conflict-outcome )
   {: dir:fd r:^ ru:n p:^ u:n side:conflict-side want:DROPBOX:hash read
      ar:^ARENA:arena :}
   p u side want ar CONFLICT-NAME {: cn:^ cnu:n :}
   p u side want ar CONFLICT-RELATIVE-PATH {: rel:^ relu:n :}
   r ru rel relu ar JOIN {: shown:^ shownu:n :}
   STAGE-WRITE-CREATED [: DROP-STAGE-WRITE
      dir cn cnu shown shownu want read NO-MARKER
      s" materialize conflict" ar WRITE-VERIFIED-STAGE ;] LOCAL-ERRORS
   rel relu CONFLICT-RESULT ;

\ The conflict copy written in the open parent, which closes after it.
: CONFLICT-BELOW
   ( parent-dir ^u8 n ^u8 n conflict-side DROPBOX:hash [ ^u8 n -- n ]
     ^ARENA:arena -- conflict-outcome )
   {: pd:parent-dir r:^ ru:n p:^ u:n side:conflict-side
      want:DROPBOX:hash read ar:^ARENA:arena :}
   pd PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
   [: dir r ru p u side want read ar CONFLICT-IN ;]
   [: dir DISCARD ;] finally ;

public

\ Writes read's bytes as p's conflict copy for side below the root, whose
\ path is r, when they hash to want; it never overwrites a file. A failed
\ read throws E-IO.
: MATERIALIZE-CONFLICT-AT
   ( fd ^u8 n ^u8 n conflict-side DROPBOX:hash [ ^u8 n -- n ]
     ^ARENA:arena -- conflict-outcome )
   {: root:fd r:^ ru:n p:^ u:n side:conflict-side want:DROPBOX:hash
      read ar:^ARENA:arena :}
   want s" materialize conflict" REQUIRE-CONTENT-HASH
   root p u true OPEN-PARENT MATCH option
      none OF p u UNSAFE ENDOF
      some OF r ru p u side want read ar CONFLICT-BELOW ENDOF
   ;MATCH ;

\ ---- recovery copies

\ The name of a private recovery copy of p holding c, laid in the arena.
: RECOVERY-FILE-NAME ( ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n )
   {: p:^ u:n c:DROPBOX:hash ar:^ARENA:arena :}
   s" recovery" p u c ar INTERNAL-NAME ;

\ Whether the copy at the name in dir, whose path is p, is there; one
\ there holds want and is synced, else it is corrupt.
: VERIFY-PRIVATE-COPY
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- bool )
   {: dir:fd p:^ u:n name:^ nu:n want:DROPBOX:hash ar:^ARENA:arena :}
   s" verify recovery copy" {: o:^ ou:n :}
   p u name nu ar JOIN {: at:^ atu:n :}
   dir name nu at atu o ou ar HASH-AT-IF-PRESENT MATCH option
      none OF false ENDOF
      some OF want SAME-CONTENT? 0= if o ou at atu CORRUPT then
         dir name nu at atu SYNC-INSTALLED-FILE true
      ENDOF
   ;MATCH ;

;package
