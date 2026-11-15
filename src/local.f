\ local.f - package LOCAL: the local half of a sync (docs/habu-rewrite.md,
\ the LOCAL row) on Habu's anchored file words: its errors, the opens it
\ confines below the sync root, and Dropbox content hashes of local files.
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
\ STORAGE CLASS. PROCESS-WIDE: the content hasher, its read buffer and the
\ name hasher; one task syncs, so one hashes at a time. CALLER-OWNED: every
\ descriptor answered, and the hashes and names laid in the caller's arena.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-anchored.f
require src/lib/fd.f
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

;package
