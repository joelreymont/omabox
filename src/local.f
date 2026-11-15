\ local.f - package LOCAL: the local half of a sync (docs/habu-rewrite.md,
\ the LOCAL row) on Habu's anchored file words: its errors, the opens it
\ confines below the sync root, Dropbox content hashes of local files, and
\ the verified stages a download writes, with their xattr markers, and
\ their installs over a target that still holds what the journal expects.
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
\ name hasher and the marker read buffer; one task syncs, so one uses them
\ at a time. CALLER-OWNED: every descriptor answered, the hashes and names
\ laid in the caller's arena, and the paths a stage's result names.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-mutate.f
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
: DOWNLOAD-PARTIAL-XATTR ( -- ^u8 n )
   s" user.omabox.download-partial-v1" ;
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

\ a joined to b in the arena, as Rust's Path::join.
: JOIN ( ^u8 n ^u8 n ^ARENA:arena -- ^u8 n )
   {: a:^ au:n b:^ bu:n ar:^ARENA:arena :}
   ar au bu + 1+ ARENA:ALLOC {: dst:^ size:n :}
   a au b bu dst size SPAN:MAKE FS:JOIN-PATH-INTO dst swap ;

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

\ The parent f opened at rel below the root at r, as OPEN-PARENT gives it.
: PREPARE-IN-PARENT
   ( fd str str ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena
     -- replacement-preparation )
   {: f:fd name:str rel:str r:^ ru:n t:^ tu:n c:DROPBOX:hash
      ar:^ARENA:arena :}
   r ru rel str> ar JOIN {: dp:^ du:n :}
   f dp du name str> t tu c ar PREPARE-REPLACEMENT-AT ;

: PREPARE-BELOW-ROOT
   ( fd ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- replacement-preparation )
   {: root:fd r:^ ru:n t:^ tu:n c:DROPBOX:hash ar:^ARENA:arena :}
   root t tu false OPEN-PARENT MATCH option
      none OF ABSENT PREPARE-CHANGED ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         [: f name rel r ru t tu c ar PREPARE-IN-PARENT ;]
         [: f DISCARD ;] finally
      ENDOF
   ;MATCH ;

public

\ Moves target t below the sync root at r to its guard, a name in the
\ same directory, when it holds c, and syncs the directory: the bytes are
\ then at the target or at the guard. A replay finds them at the guard.
: PREPARE-REPLACEMENT
   ( ^u8 n ^u8 n DROPBOX:hash ^ARENA:arena -- replacement-preparation )
   {: r:^ ru:n t:^ tu:n c:DROPBOX:hash ar:^ARENA:arena :}
   c s" prepare replacement" REQUIRE-CONTENT-HASH
   r ru s" open sync root for replacement preparation"
   OPEN-ABSOLUTE-DIRECTORY {: root:fd :}
   [: root r ru t tu c ar PREPARE-BELOW-ROOT ;] [: root DISCARD ;]
   finally ;

private

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

\ INSTALL-DOWNLOAD-AT below the sync root at r.
: INSTALL-DOWNLOAD
   ( ^u8 n ^u8 n DROPBOX:hash option<DROPBOX:hash> ^ARENA:arena
     -- install-outcome )
   {: r:^ ru:n t:^ tu:n want:DROPBOX:hash
      expected:option<DROPBOX:hash> ar:^ARENA:arena :}
   r ru s" open sync root for download install" OPEN-ABSOLUTE-DIRECTORY
   {: root:fd :}
   [: root r ru t tu want expected ar INSTALL-DOWNLOAD-AT ;]
   [: root DISCARD ;] finally ;

;package
