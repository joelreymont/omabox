\ local.f - package LOCAL: the local half of a sync (docs/habu-rewrite.md,
\ the LOCAL row) on Habu's anchored file words: its errors, the opens it
\ confines below the sync root, Dropbox content hashes of local files, and
\ the scan that observes every entry below the root.
\ A relative path splits as Rust's Path::components splits it: empty and "."
\ components past the first are skipped, and an empty, absolute or leading "."
\ path, or one with a ".." component, is unsafe. Each component opens
\ relative to its parent's descriptor with O_NOFOLLOW, so no symlink
\ is followed: a last component that is one fails ELOOP, as openat2's
\ RESOLVE_NO_SYMLINKS does, and a parent that is one fails ENOTDIR where
\ openat2 answers ELOOP. A parent in a path opens by O_PATH, so it needs
\ search permission only. An io failure's errno stays in FS:ERRNO, 0 where
\ the Habu word that failed keeps none.
\ LOCAL logs a failure once, with its text, where it throws, unless it is an
\ outcome: E-CHANGED, E-UNSUPPORTED and E-UNREADABLE are thrown without a
\ line, and so is an E-IO raised while the scan observes one entry and that
\ the scan publishes as an unknown observation, so a file that changes while
\ it is hashed logs nothing on every pass.
\ The scan walks the root depth first, each directory's names in byte order,
\ and collects observations, cached hashes it may reuse and files to hash; a
\ failure that concerns one entry publishes that entry as unknown and drops
\ everything collected beneath it. It then hashes the files, revalidates the
\ cached ones and every directory, drops the subtree of a directory that
\ changed, and checks the root is the one it opened.
\ STORAGE CLASS. PROCESS-WIDE: the content hasher, its read buffer, the
\ name hasher, the directory listing's context and the depth of the entry
\ observations open; one task syncs, so one hashes and scans at a time.
\ CALLER-OWNED: every descriptor answered, and the hashes, names, paths and
\ vectors laid in the caller's arena.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-anchored.f
require src/lib/fs-list.f
require src/lib/fd.f
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

\ Logs "local path `p`" and the text after it, then throws code.
: PATH-FAILS ( ^u8 n ^u8 n n -- )
   {: p:^ u:n t:^ tu:n code:n :}
   LOG-OPEN s" local path " LOG:TEXT+ p u QUOTED+
   t tu LOG:TEXT+ LOG:;LINE
   code throw ;

: UNSAFE ( ^u8 n -- )
   s"  is not a safe path relative to the sync root"
   E-UNSAFE-PATH PATH-FAILS ;

\ An outcome's path and operation name it where it is thrown, as Rust's
\ error does; a scan publishes it, so it is thrown without a line.
: UNSUPPORTED ( ^u8 n -- ) 2drop E-UNSUPPORTED throw ;

: UNREADABLE ( ^u8 n -- ) 2drop E-UNREADABLE throw ;

\ The operation, then the path, as every word below takes them.
: CHANGED ( ^u8 n ^u8 n -- ) 2drop 2drop E-CHANGED throw ;

: INVALID-HASH ( ^u8 n -- )
   {: o:^ ou:n :}
   LOG-OPEN s" operation " LOG:TEXT+ o ou QUOTED+
   s"  requires a lowercase Dropbox content hash" LOG:TEXT+ LOG:;LINE
   E-CONTENT-HASH throw ;

: CORRUPT ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   LOG-OPEN s" private local file for " LOG:TEXT+ o ou QUOTED+
   s"  at " LOG:TEXT+ p u QUOTED+
   s"  failed content verification" LOG:TEXT+ LOG:;LINE
   E-CORRUPT throw ;

: OCCUPIED ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   LOG-OPEN s" non-overwriting operation " LOG:TEXT+ o ou QUOTED+
   s"  found unrelated bytes at " LOG:TEXT+ p u QUOTED+ LOG:;LINE
   E-OCCUPIED throw ;

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

\ How many entry observations OBSERVING has open; inside one, an E-IO
\ with an errno other than exhaustion becomes the entry's outcome.
variable OBSERVING-DEPTH

: OUTCOME? ( n -- bool )
   {: e:n :}
   OBSERVING-DEPTH @ 0 > e EXHAUSTED? 0= and ;

\ Runs q, which observes one entry, and answers what it threw, 0 for none.
: OBSERVING ( [ -- ] -- n )
   {: q :}
   1 OBSERVING-DEPTH +!
   [: q execute ;] catch
   -1 OBSERVING-DEPTH +! ;

\ Rust's io_failure: FS:ERRNO holds the errno, kept across the log.
: IO-FAILURE ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   FS:ERRNO {: e:n :}
   e OUTCOME? 0= if
      LOG-OPEN s" local filesystem operation " LOG:TEXT+ o ou QUOTED+
      s"  failed for " LOG:TEXT+ p u QUOTED+ e ERRNO+ LOG:;LINE
   then
   e FS:CAUSE! E-IO throw ;

\ Rust's syscall_failure: io_failure with the errno given.
: SYSCALL-FAILURE ( n ^u8 n ^u8 n -- )
   {: e:n o:^ ou:n p:^ u:n :}
   e FS:CAUSE! o ou p u IO-FAILURE ;

\ Rust's StageIoError::Read: the source of a stage's bytes failed.
: STAGE-READ ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   FS:ERRNO {: e:n :}
   LOG-OPEN s" could not read stage input during " LOG:TEXT+ o ou QUOTED+
   s"  for " LOG:TEXT+ p u QUOTED+ e ERRNO+ LOG:;LINE
   e FS:CAUSE! E-STAGE-READ throw ;

\ Rust's From<StageIoError> for LocalError: a stage read is an io failure.
: LOCAL-CODE ( n -- n )
   {: code:n :}
   code E-STAGE-READ = if E-IO exit then
   code ;

: HASH-READ ( -- )
   FS:ERRNO {: e:n :}
   LOG-OPEN
   s" could not read bytes while computing the Dropbox content hash"
   LOG:TEXT+ e ERRNO+ LOG:;LINE
   e FS:CAUSE! E-HASH-READ throw ;

\ The codes Habu's file words throw.
: FS-CODE? ( n -- bool )
   {: code:n :}
   code E-FFI-NUL = if true exit then
   code E-FS-LAST >= code E-FS-FIRST <= and ;

\ Runs q from a clear FS:ERRNO; an FS code it throws runs fail, which
\ throws LOCAL's code in its place.
: FS-FAILS ( R [ R -- R ] [ -- ] -- R )
   {: q fail :}
   0 FS:CAUSE!
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   code FS-CODE? if fail execute then
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

: STAT-FD ( fd ^u8 n ^u8 n -- stat )
   {: f:fd p:^ u:n o:^ ou:n :}
   [: f FS:FD-STAT ;] [: o ou p u IO-FAILURE ;] FS-FAILS
   FS:STAT-DEV@ FS:STAT-INO@ FS:STAT-MODE@ FS:STAT-SIZE@
   FS:STAT-MTIME-SEC@ FS:STAT-MTIME-NS@
   FS:STAT-CTIME-SEC@ FS:STAT-CTIME-NS@ STAT-MAKE ;

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

\ The span filled from fd, or the bytes before its end.
: FD-READ ( fd ^u8 n -- n )
   {: f:fd p:^ u:n :}
   f p u SPAN:MAKE FD:READ-EXACT MATCH FD:fill
      full OF u ENDOF
      eof OF ENDOF
   ;MATCH ;

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

\ The hash of a regular file whose stat after the read is the one given.
: HASH-STABLE-FILE-FROM-STAT
   ( fd ^u8 n ^u8 n stat ^ARENA:arena -- DROPBOX:hash MODEL:fingerprint )
   {: f:fd p:^ u:n o:^ ou:n before:stat ar:^ARENA:arena :}
   before REGULAR? 0= if p u UNSUPPORTED then
   before p u FILE-FINGERPRINT {: print:MODEL:fingerprint :}
   f p u o ou ar HASH-READS {: c:DROPBOX:hash :}
   before f p u o ou STAT-FD SAME-OBSERVATION 0= if o ou p u CHANGED then
   c print ;

: HASH-STABLE-FILE-WITH-FINGERPRINT
   ( fd ^u8 n ^u8 n ^ARENA:arena -- DROPBOX:hash MODEL:fingerprint )
   {: f:fd p:^ u:n o:^ ou:n ar:^ARENA:arena :}
   f p u o ou STAT-FD {: before:stat :}
   f p u o ou before ar HASH-STABLE-FILE-FROM-STAT ;

: HASH-STABLE-FILE ( fd ^u8 n ^u8 n ^ARENA:arena -- DROPBOX:hash )
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

: CHECK-REGULAR ( fd ^u8 n ^u8 n -- stat )
   {: f:fd p:^ u:n o:^ ou:n :}
   f p u o ou STAT-FD {: st:stat :}
   st REGULAR? 0= if p u UNSUPPORTED then
   st ;

\ The stat of the regular file at fd; a throw closes fd.
: REGULAR-STAT ( fd ^u8 n ^u8 n -- stat )
   {: f:fd p:^ u:n o:^ ou:n :}
   NO-STAT f [: DROP-STAT f p u o ou CHECK-REGULAR ;] CLOSING ;

: OPEN-RELATIVE-REGULAR-WITH-STAT ( fd ^u8 n ^u8 n -- fd stat )
   {: root:fd p:^ u:n o:^ ou:n :}
   p u SAFE-COMPONENTS drop
   root p u OPEN-BELOW MATCH option
      none OF o ou p u IO-FAILURE ENDOF
      some OF {: f:fd :} f f p u o ou REGULAR-STAT ENDOF
   ;MATCH ;

: OPEN-RELATIVE-REGULAR ( fd ^u8 n ^u8 n -- fd )
   OPEN-RELATIVE-REGULAR-WITH-STAT {: f:fd st:stat :} f ;

\ Rust's open_relative_at with O_RDONLY|O_NONBLOCK, the flags its one
\ caller passes, which FS:TRY-OPEN-READ-AT sets.
: OPEN-RELATIVE-AT ( fd ^u8 n ^u8 n -- fd )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-OPEN-READ-AT MATCH option
      none OF s" open root-confined file" p u IO-FAILURE ENDOF
      some OF ENDOF
   ;MATCH ;

: OPEN-DIRECTORY-AT ( fd ^u8 n ^u8 n -- fd )
   {: dir:fd name:^ nu:n p:^ u:n :}
   dir name nu FS:TRY-OPEN-DIR-AT MATCH option
      none OF s" open root-confined directory" p u IO-FAILURE ENDOF
      some OF ENDOF
   ;MATCH ;

\ True when a regular file is at the name, false when nothing is.
: PROBE ( fd ^u8 n ^u8 n ^u8 n -- bool )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF FS:ERRNO FS:ENOENT <> if o ou p u IO-FAILURE then false
      ENDOF
      some OF {: probe:fd :}
         probe p u o ou REGULAR-STAT DROP-STAT probe DISCARD true
      ENDOF
   ;MATCH ;

: OPEN-READ ( fd ^u8 n ^u8 n ^u8 n -- option<opened> )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu FS:TRY-OPEN-READ-AT MATCH option
      none OF FS:ERRNO {: e:n :}
         e FS:EACCES = if p u UNREADABLE then
         e FS:ENOENT <> if o ou p u IO-FAILURE then
         OPTION:NONE
      ENDOF
      some OF {: f:fd :} f f p u o ou REGULAR-STAT OPENED-MAKE OPTION:SOME
      ENDOF
   ;MATCH ;

\ The regular file at the name, none when nothing is there.
: OPEN-REGULAR-AT-IF-PRESENT
   ( fd ^u8 n ^u8 n ^u8 n -- option<opened> )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu p u o ou PROBE 0= if OPTION:NONE exit then
   dir name nu p u o ou OPEN-READ ;

\ Hashes the opened file, closing it on a throw.
: HASH-OPENED ( opened ^u8 n ^u8 n ^ARENA:arena -- hashed )
   {: x:opened p:^ u:n o:^ ou:n ar:^ARENA:arena :}
   x OPENED-UNMAKE {: f:fd st:stat :}
   NO-HASH NO-FINGERPRINT f
   [: DROP-FINGERPRINT DROP-HASH f p u o ou st ar
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

\ Dropbox's documented metadata suffixes and temporary-file prefixes
\ (help.dropbox.com/en-en/sync/files-not-syncing), as Rust's
\ is_excluded_name.
: PREFIX? ( ^u8 n ^u8 n -- bool )
   {: p:^ u:n x:^ xu:n :}
   u xu < if false exit then
   p xu x xu STR= ;

: SUFFIX-CI? ( ^u8 n ^u8 n -- bool )
   {: p:^ u:n x:^ xu:n :}
   u xu < if false exit then
   p u + xu - xu x xu STR=CI ;

: EXCLUDED-NAME? ( ^u8 n -- bool )
   {: p:^ u:n :}
   p u s" ~$" PREFIX? if true exit then
   p u s" .~" PREFIX? if true exit then
   p u s" desktop.ini" SUFFIX-CI? if true exit then
   p u s" thumbs.db" SUFFIX-CI? if true exit then
   p u s" .ds_store" SUFFIX-CI? if true exit then
   p u s\" icon\r" SUFFIX-CI? if true exit then
   p u s" .dropbox" SUFFIX-CI? if true exit then
   p u s" .dropbox.attr" SUFFIX-CI? ;

: STAT-DEV ( stat -- n ) STAT-UNMAKE {: d i m s ms mn cs cn :} d ;

: DIRECTORY? ( stat -- bool )
   STAT-UNMAKE {: d i m s ms mn cs cn :}
   m FS:S-IFMT and FS:S-IFDIR = ;

: SAME-FINGERPRINT ( MODEL:fingerprint MODEL:fingerprint -- bool )
   {: a:MODEL:fingerprint b:MODEL:fingerprint :}
   a b SAME-HASHED-CONTENT 0= if false exit then
   a MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   b MODEL-FINGERPRINT:UNMAKE {: i2 s2 ms2 mn2 cs2 cn2 :}
   cs cs2 = cn cn2 = and ;

\ The path below parent, laid in the arena.
: JOIN ( str ^u8 n ^ARENA:arena -- str )
   {: parent:str name:^ nu:n ar:^ARENA:arena :}
   parent str> {: p:^ u:n :}
   u 0= if name nu ar KEEP exit then
   ar u 1+ nu + ARENA:ALLOC drop {: dst:^ :}
   p u dst 0 PUT {: at:n :}
   s" /" dst at PUT {: at2:n :}
   name nu dst at2 PUT {: at3:n :}
   dst at3 >str ;

\ The name, the last component of a path below parent.
: NAME-OF ( str str -- ^u8 n )
   {: path:str parent:str :}
   path str> {: p:^ u:n :}
   parent str> nip {: pu:n :}
   pu 0= if p u exit then
   p pu 1+ + u pu 1+ - ;

\ The one directory listing open at a time: the walk lists a directory
\ whole before it scans any entry in it.
create LISTING FS-LIST:STORAGE-BYTES allot

: LISTED ( fd str ^ARENA:arena ^VEC:vector<str> -- )
   {: dir:fd parent:str ar:^ARENA:arena v :}
   LISTING FS-LIST:STORAGE-BYTES SPAN:MAKE FS-LIST:INIT
   dir [: drop parent -rot ar JOIN v VEC:PUSH ! ;] FS-LIST:EACH-TYPED-AT ;

: LIST-FAILURE ( n ^u8 n -- )
   {: code:n p:^ u:n :}
   code FS-LIST:E-OPEN = if s" open directory stream" p u IO-FAILURE then
   code E-FS-LIST-LAST >= code E-FS-LIST-FIRST <= and if
      s" read directory" p u IO-FAILURE
   then
   code throw ;

\ The paths of the entries in dir, but . and .., in the order listed.
: LIST-PATHS ( fd str ^ARENA:arena -- ^VEC:vector<str> )
   {: dir:fd parent:str ar:^ARENA:arena :}
   ar [type] str NEW-VEC {: v :}
   0 FS:CAUSE!
   [: dir parent ar v LISTED ;] catch {: code:n :}
   code 0<> if code parent str> LIST-FAILURE then
   v ;

: REUSABLE-CONTENT
   ( scan-context str MODEL:fingerprint -- option<DROPBOX:hash> )
   {: cx:scan-context path:str print:MODEL:fingerprint :}
   cx SCAN-CONTEXT-UNMAKE {: cache cut:option<cutoff> dev:n ar :}
   cache path str> CACHED-HASH MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: r:MODEL:hash-record :}
         r RECORD-FINGERPRINT print SAME-FINGERPRINT
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
   path str> UNSUPPORTED ;

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

\ Rust's io_unknown_reason: none for exhaustion, which fails the scan; a
\ failure with no errno still concerns the one object, so it is
\ inaccessible.
: IO-UNKNOWN-REASON ( n -- option<MODEL:unknown-reason> )
   {: e:n :}
   e EXHAUSTED? if OPTION:NONE exit then
   e REPLACED? if MODEL-UNKNOWN--REASON:incomplete OPTION:SOME exit then
   MODEL-UNKNOWN--REASON:inaccessible OPTION:SOME ;

\ Rust's entry_unknown: the reason code, thrown while one entry was
\ observed, publishes; wrong is what an object that is not a regular file
\ means to the caller. Any other code is the scan's, rethrown.
: ENTRY-UNKNOWN ( n MODEL:unknown-reason -- MODEL:unknown-reason )
   {: code:n wrong:MODEL:unknown-reason :}
   code E-UNSUPPORTED = if wrong exit then
   code E-CHANGED = if MODEL-UNKNOWN--REASON:incomplete exit then
   code E-UNREADABLE = if MODEL-UNKNOWN--REASON:inaccessible exit then
   code E-IO <> if code throw then
   FS:ERRNO IO-UNKNOWN-REASON MATCH option
      none OF code throw ENDOF
      some OF ENDOF
   ;MATCH ;

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
   name nu EXCLUDED-NAME? if exit then
   en MARK {: mk:scan-mark :}
   [: dir name nu path cx en SCAN-ENTRY ;] OBSERVING {: code:n :}
   code 0= if exit then
   code WALK-UNKNOWN {: why:MODEL:unknown-reason :}
   en mk TRUNCATE
   en path why UNKNOWN ;

: SCAN-DIRECTORY ( fd str scan-context scan-entries -- )
   {: dir:fd path:str cx:scan-context en:scan-entries :}
   path str> {: p:^ u:n :}
   cx SCAN-CONTEXT-UNMAKE {: cache cut:option<cutoff> dev:n ar :}
   dir p u s" inspect directory before scan" STAT-FD {: before:stat :}
   dir path ar LIST-PATHS {: names :}
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
   opened p u FILE-FINGERPRINT want SAME-FINGERPRINT 0= if
      s" open enumerated scan file" p u CHANGED
   then
   f p u s" hash local scan file" opened ar HASH-STABLE-FILE-FROM-STAT
   {: c:DROPBOX:hash print:MODEL:fingerprint :}
   print want SAME-FINGERPRINT 0= if
      s" hash enumerated scan file" p u CHANGED
   then
   path MODEL:>PATH print c MODEL-HASH--RECORD:MAKE
   {: r:MODEL:hash-record :}
   r r q execute HASH-IS-REUSABLE SCANNED-HASH-MAKE ;

: HASH-SCAN-FILE
   ( fd hash-job [ -- option<cutoff> ] ^ARENA:arena -- scanned-hash )
   {: root:fd job:hash-job q ar:^ARENA:arena :}
   job HASH-JOB-UNMAKE {: path:str want:MODEL:fingerprint :}
   root path str> s" open enumerated scan file"
   OPEN-RELATIVE-REGULAR-WITH-STAT {: f:fd opened:stat :}
   [: f path want opened q ar HASH-OPENED-FILE ;] [: f DISCARD ;] finally ;

\ Every failure here concerns the job's own path.
: HASH-JOB
   ( fd hash-job [ -- option<cutoff> ] ^ARENA:arena scan-hash-results -- )
   {: root:fd job:hash-job q ar:^ARENA:arena res:scan-hash-results :}
   [: root job q ar HASH-SCAN-FILE res RESULT-RECORDS VEC:PUSH ! ;]
   OBSERVING {: code:n :}
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
   root p u s" reopen cached scan file" OPEN-RELATIVE-REGULAR-WITH-STAT
   {: f:fd before:stat :}
   f DISCARD
   before p u FILE-FINGERPRINT r RECORD-FINGERPRINT SAME-FINGERPRINT 0= if
      res p u >str MODEL-UNKNOWN--REASON:incomplete STILL-UNKNOWN exit
   then
   r true SCANNED-HASH-MAKE res RESULT-RECORDS VEC:PUSH ! ;

: REVALIDATE-CACHED ( fd MODEL:hash-record scan-hash-results -- )
   {: root:fd r:MODEL:hash-record res:scan-hash-results :}
   [: root r res CHECK-CACHED ;] OBSERVING {: code:n :}
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
   [: root path before unknown CHECK-DIRECTORY ;] OBSERVING {: code:n :}
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

\ Rust's enumerate_scan_on_device: every entry on device; any other device
\ is an unsupported subtree. The walk's collections stay in walk order:
\ FINISH sorts what it publishes. A throw closes the root.
: ENUMERATE-SCAN-ON-DEVICE
   ( ^u8 n fd stat ^VEC:vector<MODEL:hash-record> option<cutoff> n
     ^ARENA:arena -- pending-scan )
   {: p:^ u:n rfd:fd before:stat cache cut:option<cutoff> dev:n
      ar:^ARENA:arena :}
   cache cut dev ar SCAN-CONTEXT-MAKE {: cx:scan-context :}
   ar NEW-ENTRIES {: en:scan-entries :}
   rfd [: rfd s" " >str cx en SCAN-DIRECTORY ;] CLOSING
   p u ar KEEP rfd before en ar PENDING-SCAN-MAKE ;

: ROOT-STAT ( fd ^u8 n -- stat )
   {: rfd:fd p:^ u:n :}
   NO-STAT rfd
   [: DROP-STAT rfd p u s" inspect sync root before scan" STAT-FD ;]
   CLOSING ;

: ENUMERATE-SCAN
   ( ^u8 n ^VEC:vector<MODEL:hash-record> option<cutoff> ^ARENA:arena
     -- pending-scan )
   {: p:^ u:n cache cut:option<cutoff> ar:^ARENA:arena :}
   p u s" open sync root for scan" OPEN-ABSOLUTE-DIRECTORY {: rfd:fd :}
   rfd p u ROOT-STAT {: before:stat :}
   p u rfd before cache cut before STAT-DEV ar ENUMERATE-SCAN-ON-DEVICE ;

\ A root whose every entry is treated as on a foreign volume.
: ENUMERATE-SCAN-ACROSS-DEVICES ( ^u8 n ^ARENA:arena -- pending-scan )
   {: p:^ u:n ar:^ARENA:arena :}
   p u s" open sync root for scan" OPEN-ABSOLUTE-DIRECTORY {: rfd:fd :}
   rfd p u ROOT-STAT {: before:stat :}
   p u rfd before ar [type] MODEL:hash-record NEW-VEC NO-CUTOFF
   before STAT-DEV 1 xor ar ENUMERATE-SCAN-ON-DEVICE ;

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

;package
