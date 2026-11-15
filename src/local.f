\ local.f - package LOCAL: the local half of a sync (docs/habu-rewrite.md,
\ the LOCAL row) on Habu's anchored file words: its errors, the opens it
\ confines below the sync root, Dropbox content hashes of local files, the
\ verified stages a download writes, with their xattr markers, and the
\ slots in the state home where a download's partial bytes resume.
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
\ name hasher, the marker and slot state buffers, the slot name and path
\ buffers and a lease's slot table; one task syncs, so one uses them at a
\ time. CALLER-OWNED: every descriptor answered, the hashes, names and
\ partials laid in the caller's arena, the paths a stage's result names
\ and a lease's slot directory.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-anchored.f
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

: UNSUPPORTED ( ^u8 n -- )
   s"  is not a regular file or directory" E-UNSUPPORTED PATH-FAILS ;

: UNREADABLE ( ^u8 n -- )
   s"  is a file Omabox cannot read" E-UNREADABLE PATH-FAILS ;

\ The operation, then the path, as every word below takes them.
: CHANGED ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   LOG-OPEN s" local path " LOG:TEXT+ p u QUOTED+
   s"  changed during " LOG:TEXT+ o ou QUOTED+ LOG:;LINE
   E-CHANGED throw ;

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

\ Rust's io_failure: FS:ERRNO holds the errno, kept across the log.
: IO-FAILURE ( ^u8 n ^u8 n -- )
   {: o:^ ou:n p:^ u:n :}
   FS:ERRNO {: e:n :}
   LOG-OPEN s" local filesystem operation " LOG:TEXT+ o ou QUOTED+
   s"  failed for " LOG:TEXT+ p u QUOTED+ e ERRNO+ LOG:;LINE
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

\ A stage a preparation found complete, its stage 0 for Rust's (); an
\ ENUM payload names no applied family, a field does.
STRUCTURE completed-stage FIELD outcome stage-outcome<n> ;STRUCTURE

\ What preparing a download came to: a partial ready for bytes, a stage
\ complete already, or no slot to resume in.
ENUM download-preparation
   VARIANT ready FIELD partial ^download-partial ;VARIANT
   VARIANT complete FIELD stage completed-stage ;VARIANT
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

\ Rust's Path::join for display paths, laid in the arena: one slash
\ between a and b unless a is empty or ends in one; a alone for an empty
\ b.
: JOIN ( ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: a:^ au:n b:^ bu:n ar:^ARENA:arena :}
   bu 0= if a au exit then
   au 0= if 0 else a au + 1- c@ SLASH = if 0 else 1 then then {: sep:n :}
   ar au sep + bu + ARENA:ALLOC {: dst:^ size:n :}
   a au dst 0 PUT {: at:n :}
   s" /" drop sep dst at PUT {: at2:n :}
   b bu dst at2 PUT drop
   dst size ;

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

: COMPLETE ( stage-outcome<n> -- download-preparation )
   LOCAL-COMPLETED--STAGE:MAKE LOCAL-DOWNLOAD--PREPARATION:complete ;

\ What a stage already at the download's name makes of it, none when
\ there is none; a verified stage's descriptor is closed.
: STAGE-PREPARATION ( download-stage -- option<download-preparation> )
   MATCH download-stage
      missing OF OPTION:NONE ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :} f DISCARD
         0 LOCAL-STAGE--OUTCOME:already-staged COMPLETE OPTION:SOME
      ENDOF
      destination-occupied OF LOCAL-STAGE--OUTCOME:destination-occupied
         COMPLETE OPTION:SOME
      ENDOF
   ;MATCH ;

\ The download's stage name for target t, and its path below root path r
\ through the parent's path rel, laid in the arena.
: STAGE-PATHS
   ( ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- ^u8 n ^u8 n )
   {: r:^ ru:n rel:^ relu:n t:^ tu:n want:DROPBOX:hash ar:^ARENA:arena :}
   s" download" t tu want ar INTERNAL-NAME {: name:^ nu:n :}
   r ru rel relu ar JOIN name nu ar JOIN {: sp:^ spu:n :}
   name nu sp spu ;

\ The location of target t's download from src into dir, its stage
\ named and the target kept in the arena.
: NEW-LOCATION
   ( download-source fd ^u8 n ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- download-location )
   {: src:download-source dir:fd r:^ ru:n rel:^ relu:n t:^ tu:n
      want:DROPBOX:hash ar:^ARENA:arena :}
   r ru rel relu t tu want ar STAGE-PATHS {: name:^ nu:n sp:^ spu:n :}
   src dir name nu >str sp spu >str t tu ar KEEP want
   DOWNLOAD-LOCATION-MAKE ;

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
   loc f ar NEW-PARTIAL LOCAL-DOWNLOAD--PREPARATION:ready ;

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
   LOCAL-DOWNLOAD--PREPARATION:ephemeral dir
   [: DROP-PREPARATION
      s su s" <unnamed-download>" ar JOIN >str DOWNLOAD-SOURCE-DISPOSABLE
      dir r ru rel str> t tu want ar NEW-LOCATION s su ar DISPOSABLE ;]
   CLOSING ;

;package
