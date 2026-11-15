\ local.f - package LOCAL: the local half of a sync (docs/habu-rewrite.md,
\ the LOCAL row) on Habu's anchored file words: its errors, the opens it
\ confines below the sync root, Dropbox content hashes of local files, the
\ verified stages a download writes, with their xattr markers, and the
\ upload stages named by their content's hash, which a Habu and a Rust
\ daemon share.
\ A relative path splits as Rust's Path::components splits it: empty and "."
\ components past the first are skipped, and an empty, absolute or leading "."
\ path, or one with a ".." component, is unsafe. Each component opens
\ relative to its parent's descriptor with O_NOFOLLOW, so no symlink
\ is followed: a last component that is one fails ELOOP, as openat2's
\ RESOLVE_NO_SYMLINKS does, and a parent that is one fails ENOTDIR where
\ openat2 answers ELOOP. A parent in a path opens by O_PATH, so it needs
\ search permission only. A failure is logged once with its text before LOCAL
\ throws its code; an io failure's errno stays in FS:ERRNO, 0 where the
\ Habu word that failed keeps none.
\ STORAGE CLASS. PROCESS-WIDE: the content hasher, its read buffer, the
\ name hasher, the marker read buffer, and a collection's listing buffer
\ and names; one task syncs, so one uses them at a time. CALLER-OWNED:
\ every descriptor answered, the hashes, names and staged uploads laid in
\ the caller's arena, and the paths a stage's result names.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-anchored.f
require src/lib/fs-list.f
require src/lib/allocator.f
require src/lib/fd.f
require src/lib/xattr.f
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

\ Logs "local path `p`" and the text after it, then throws code.
: PATH-FAILS ( ^u8 n ^u8 n n -- )
   {: p:^ u:n t:^ tu:n code:n :}
   LOG-OPEN s" local path " LOG:TEXT+ p u QUOTED+
   t tu LOG:TEXT+ LOG:;LINE
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
   LOG-OPEN s" local path " LOG:TEXT+ p u QUOTED+
   s"  changed during " LOG:TEXT+ o ou QUOTED+ LOG:;LINE
   code throw ;

: CHANGED ( ^u8 n ^u8 n -- ) E-CHANGED CHANGED-FAILS ;

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

\ Rust's io_failure, throwing code: FS:ERRNO holds the errno, kept across
\ the log.
: IO-FAILS ( ^u8 n ^u8 n n -- )
   {: o:^ ou:n p:^ u:n code:n :}
   FS:ERRNO {: e:n :}
   LOG-OPEN s" local filesystem operation " LOG:TEXT+ o ou QUOTED+
   s"  failed for " LOG:TEXT+ p u QUOTED+ e ERRNO+ LOG:;LINE
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

\ The codes Habu's file and xattr words throw.
: FS-CODE? ( n -- bool )
   {: code:n :}
   code E-FFI-NUL = if true exit then
   code XATTR:E-XATTR = if true exit then
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

: EXHAUSTED? ( n -- bool )
   {: e:n :}
   e FS:EMFILE = e FS:ENFILE = or e FS:ENOMEM = or e FS:ENOSPC = or ;

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

\ True when a regular file is at the name, false when nothing is.
: PROBE ( fd ^u8 n ^u8 n ^u8 n -- bool )
   {: dir:fd name:^ nu:n p:^ u:n o:^ ou:n :}
   dir name nu FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF FS:ERRNO FS:ENOENT <> if o ou p u IO-FAILURE then false
      ENDOF
      some OF {: probe:fd :}
         probe p u o ou E-IO E-UNSUPPORTED REGULAR-STAT DROP-STAT
         probe DISCARD true
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
      some OF {: f:fd :}
         f f p u o ou E-IO E-UNSUPPORTED REGULAR-STAT OPENED-MAKE
         OPTION:SOME
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

\ ---- parents

\ S_IRWXU: a parent directory a download makes.
$1C0 constant MODE-PRIVATE-DIR

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
   dir name nu MODE-PRIVATE-DIR FS:TRY-MAKE-DIR-AT if
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

: SAME-FINGERPRINT? ( MODEL:fingerprint MODEL:fingerprint -- bool )
   {: a:MODEL:fingerprint b:MODEL:fingerprint :}
   a b SAME-HASHED-CONTENT 0= if false exit then
   a MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   b MODEL-FINGERPRINT:UNMAKE {: i2 s2 ms2 mn2 cs2 cn2 :}
   cs cs2 = cn cn2 = and ;

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
   t tu want ar STAGE-MARKER {: m:^ mu:n :}
   false f [: drop f actual want m mu p u OWNED? ;] CLOSING 0= if
      f DISCARD p u >str DOWNLOAD-STAGE-DESTINATION-OCCUPIED exit
   then
   NO-FINGERPRINT f [: DROP-FINGERPRINT f print p u SEAL-STAGE ;] CLOSING
   {: after:MODEL:fingerprint :}
   f after VERIFIED-DOWNLOAD-STAGE-MAKE DOWNLOAD-STAGE-VERIFIED ;

\ The stage at the name in dir for target's content want: none, an owned
\ stage verified and left open, or another file, kept as it was.
: INSPECT-DOWNLOAD-STAGE
   ( fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- download-stage )
   {: dir:fd name:^ nu:n p:^ u:n t:^ tu:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   dir name nu p u s" verify owned download stage" ar
   OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF DOWNLOAD-STAGE-MISSING ENDOF
      some OF p u t tu want ar INSPECT-HASHED ENDOF
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

\ The path of name in the directory, laid in the arena.
: JOIN ( ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: d:^ du:n name:^ nu:n ar:^ARENA:arena :}
   ar du nu + 1+ ARENA:ALLOC {: dst:^ size:n :}
   d du name nu dst size SPAN:MAKE FS:JOIN-PATH-INTO {: k:n :}
   dst k ;

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

\ Whether a stage's failure means another entry holds its path: one not
\ a regular file, or a symlink. Its callers catch only throws whose path
\ is the stage's, so the code alone tells.
: UPLOAD-STAGE-OCCUPIED? ( n -- bool )
   {: code:n :}
   code E-UNSUPPORTED = if true exit then
   code E-IO = FS:ERRNO FS:ELOOP = and ;

: NO-HASHED ( -- option<hashed> ) OPTION:NONE ;
: DROP-HASHED ( option<hashed> -- ) drop ;
\ An upload stage carries no marker.
: NO-MARKER ( -- option<str> ) OPTION:NONE ;

\ The entry at the stage's path hashed, none when nothing is there; an
\ occupied path is occupied, a throw.
: HASH-UPLOAD-STAGE
   ( fd ^u8 n ^u8 n ^ARENA:arena -- option<hashed> bool )
   {: dir:fd name:^ nu:n p:^ u:n ar:^ARENA:arena :}
   NO-HASHED [: DROP-HASHED dir name nu p u
      s" verify immutable upload stage" ar OPEN-AND-HASH-IF-PRESENT ;]
   catch {: code:n :}
   code 0= if false exit then
   drop code UPLOAD-STAGE-OCCUPIED? if NO-HASHED true exit then
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

\ WRITE-VERIFIED-STAGE of the source's bytes; an occupied stage path is
\ destination-occupied, and a failed read of the source an io failure.
: WRITE-UPLOAD-STAGE
   ( fd fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- stage-write )
   {: src:fd dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   STAGE-WRITE-CREATED [: DROP-STAGE-WRITE
      dir name nu p u want [: src -rot FD-READ ;] NO-MARKER
      s" stage upload" ar WRITE-VERIFIED-STAGE ;] catch {: code:n :}
   code 0= if exit then
   drop code UPLOAD-STAGE-OCCUPIED? if
      p u >str STAGE-WRITE-DESTINATION-OCCUPIED exit
   then
   code LOCAL-CODE throw ;

\ Stages the source's bytes; its stat must not change while they copy.
: STAGE-SOURCE
   ( fd ^u8 n fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- stage-write )
   {: src:fd r:^ ru:n dir:fd name:^ nu:n p:^ u:n want:DROPBOX:hash
      ar:^ARENA:arena :}
   src r ru s" inspect upload source before staging" STAT-FD
   {: before:stat :}
   src dir name nu p u want ar WRITE-UPLOAD-STAGE {: w:stage-write :}
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
: STAGE-IN ( fd ^u8 n fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
   -- stage-write )
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
   s su s" open upload staging directory" OPEN-PRIVATE-DIRECTORY
   {: dir:fd :}
   want DROPBOX:HASH>STR str> {: name:^ nu:n :}
   s su name nu ar JOIN {: p:^ u:n :}
   STAGE-WRITE-CREATED dir [: DROP-STAGE-WRITE
      root r ru dir name nu p u want ar STAGE-IN ;] CLOSING
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

\ Whether the file hashes to its name; a file that changed or stopped
\ being regular while it was read does not.
: HOLDS-ITS-NAME? ( fd ^u8 n ^u8 n ^ARENA:arena -- bool )
   {: f:fd name:^ nu:n p:^ u:n ar:^ARENA:arena :}
   false [: drop f p u s" verify upload stage for collection" ar
      E-UNSUPPORTED E-CHANGED HASH-STABLE-FILE
      DROPBOX:HASH>STR str> name nu STR= ;] catch
   {: code:n :}
   code 0= if exit then
   drop code E-CHANGED = code E-UNSUPPORTED = or if false exit then
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

\ The names a collection considers, 64-byte hashes in byte order, in an
\ arena block that doubles as it fills.
PTR-VARIABLE UPLOAD-NAMES
variable UPLOAD-NAME-COUNT
variable UPLOAD-NAME-CAP
64 constant UPLOAD-NAME-LEN
FS-LIST:STORAGE-BYTES BUFFER: LIST-BUF

: UPLOAD-NAME ( n -- ^u8 n )
   {: idx:n :}
   UPLOAD-NAMES @ idx UPLOAD-NAME-LEN * + UPLOAD-NAME-LEN ;

: GROW-UPLOAD-NAMES ( ^ARENA:arena -- )
   {: ar:^ARENA:arena :}
   UPLOAD-NAME-COUNT @ UPLOAD-NAME-CAP @ < if exit then
   UPLOAD-NAME-CAP @ 2 * 8 max {: cap:n :}
   ar ARENA:ALLOCATOR UPLOAD-NAMES @
   UPLOAD-NAME-CAP @ UPLOAD-NAME-LEN * cap UPLOAD-NAME-LEN *
   ALLOC:RESIZE drop UPLOAD-NAMES !
   cap UPLOAD-NAME-CAP ! ;

\ The index of the first kept name after the one given, else the count.
: UPLOAD-NAME-SLOT ( ^u8 n -- n )
   {: name:^ nu:n :}
   UPLOAD-NAME-COUNT @ 0 ?do
      name nu i UPLOAD-NAME STR< if i unloop exit then
   loop UPLOAD-NAME-COUNT @ ;

: MOVE-UP ( n -- )
   {: idx:n :}
   idx UPLOAD-NAME drop idx 1+ UPLOAD-NAME drop UPLOAD-NAME-LEN BYTE-COPY ;

\ Moves the names from idx on up one place, the last first.
: OPEN-UPLOAD-NAME ( n -- )
   {: idx:n :}
   UPLOAD-NAME-COUNT @ begin dup idx > while 1- dup MOVE-UP repeat drop ;

\ Keeps the name in order when it names an upload stage's content.
: KEEP-UPLOAD-NAME ( ^u8 n ^ARENA:arena -- )
   {: name:^ nu:n ar:^ARENA:arena :}
   name nu VALID-CONTENT-HASH? 0= if exit then
   ar GROW-UPLOAD-NAMES
   name nu UPLOAD-NAME-SLOT {: idx:n :}
   idx OPEN-UPLOAD-NAME
   name idx UPLOAD-NAME drop nu BYTE-COPY
   1 UPLOAD-NAME-COUNT +! ;

: LIST-OPERATION ( n -- ^u8 n )
   FS-LIST:E-OPEN = if s" open upload staging directory stream" exit then
   s" read upload staging directory" ;

\ Gathers dir's upload stage names; a failed listing is an io failure.
: LIST-UPLOAD-NAMES ( fd ^u8 n ^ARENA:arena -- )
   {: dir:fd s:^ su:n ar:^ARENA:arena :}
   0 UPLOAD-NAME-COUNT ! 0 UPLOAD-NAME-CAP ! NULL-PTR UPLOAD-NAMES !
   0 FS:CAUSE!
   LIST-BUF FS-LIST:STORAGE-BYTES SPAN:MAKE FS-LIST:INIT {: ctx :}
   [: ctx dir [: drop ar KEEP-UPLOAD-NAME ;] FS-LIST:EACH-TYPED-AT ;]
   catch {: code:n :}
   code 0= if exit then
   code FS-LIST:E-OPEN = code FS-LIST:E-READ = or if
      code LIST-OPERATION s su IO-FAILURE
   then
   code throw ;

\ Removes the stage when it verifies; answers how many it removed.
: COLLECT-UPLOAD-STAGE ( fd ^u8 n ^u8 n ^ARENA:arena -- n )
   {: dir:fd name:^ nu:n s:^ su:n ar:^ARENA:arena :}
   s su name nu ar JOIN {: p:^ u:n :}
   dir name nu p u ar VERIFIED-UPLOAD-STAGE-ENTRY? 0= if 0 exit then
   dir name nu FS:TRY-REMOVE-FILE-AT if 1 exit then
   FS:ERRNO FS:ENOENT <> if
      s" remove unreferenced upload stage" p u IO-FAILURE
   then 0 ;

: COLLECT-UPLOAD-STAGES
   ( fd ^u8 n [ DROPBOX:hash -- bool ] ^ARENA:arena -- n )
   {: dir:fd s:^ su:n retained ar:^ARENA:arena :}
   0 UPLOAD-NAME-COUNT @ 0 ?do
      i UPLOAD-NAME >str DROPBOX:>HASH {: c:DROPBOX:hash :}
      c retained execute 0= if
         dir c DROPBOX:HASH>STR str> s su ar COLLECT-UPLOAD-STAGE +
      then
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
   0 dir [: drop dir s su ar LIST-UPLOAD-NAMES
      dir s su retained ar COLLECT-UPLOAD-STAGES
      dup 0<> if
         dir s su s" sync upload stage collection" SYNC-DIRECTORY
      then ;] CLOSING
   dir DISCARD ;

;package
