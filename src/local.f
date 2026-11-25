\ local.f - package LOCAL: the local half of a sync (docs/habu-rewrite.md,
\ the LOCAL row) on Habu's anchored file words: its errors, the opens it
\ confines below the sync root, Dropbox content hashes of local files, the
\ scan that observes every entry below the root and its publication while
\ the configured path names the journal's active root, the upload stages
\ named by their content's hash, which a Habu and a Rust daemon share, the
\ verified stages a download writes, with their xattr markers, the slots
\ in the state home where a download's partial bytes resume, the partials
\ themselves, checkpointed and promoted into their stages, their installs
\ over a target that still holds what the journal expects, and the
\ conditional deletes of local files, the directories a sync creates and
\ deletes, the conflict copies it writes, and the non-overwriting renames
\ of a case variant or a file to its copy name.
\ A relative path splits as Rust's Path::components splits it: empty and "."
\ components past the first are skipped, and an empty, absolute or leading "."
\ path, or one with a ".." component, is unsafe. Each component opens
\ relative to its parent's descriptor with O_NOFOLLOW, so no symlink
\ is followed: a last component that is one fails ELOOP, as openat2's
\ RESOLVE_NO_SYMLINKS does, and a parent that is one fails ENOTDIR where
\ openat2 answers ELOOP. A read's parents open by O_PATH, so they need
\ search permission only; a write's open O_RDONLY, so they need read
\ permission too. An io failure's errno stays in FS:ERRNO, 0 where the
\ Habu word that failed keeps none; on ENOSPC the code is E-DISK-FULL, not
\ E-IO.
\ LOCAL logs a failure once, with its text, where it throws, unless the
\ catch around it turns it into an outcome: CONVERTING or WITH-CONVERTS
\ runs a word under a predicate naming the codes and errnos its caller
\ converts, and QUIET? asks the innermost one. A scan's observation
\ converts what ENTRY-CODE? names and rethrows the rest, which logs and
\ ends the scan; a failure XATTR logged gets no second line. On EACCES or
\ EPERM, the line of a call that makes, links, renames or removes a name
\ in a directory, or opens it as a directory, also gives the mode, owner
\ and attributes of that directory and of the entry, and the uid Omabox
\ runs as.
\ The scan walks the root in path byte order, a directory's subtree
\ before the first later name that does not sort below it, and hands
\ each entry to JOURNAL, which stages only what differs from the stored
\ rows; a failure that concerns one entry publishes that entry as
\ unknown, and nothing beneath it is observed. It then hashes the files
\ to hash and checks the root is the one it opened.
\ STORAGE CLASS. PROCESS-WIDE: the content hasher, its read buffer, the
\ name hasher, the marker and slot state buffers, the slot name and path
\ buffers, a lease's slot table, the byte a partial's end is probed with,
\ the directory listing context, the predicate of the innermost
\ WITH-CONVERTS and DENIED-PATH; one task syncs, so one uses them at a
\ time. CALLER-OWNED: every descriptor answered, the hashes, names,
\ paths, vectors, staged uploads and partials laid in the caller's arena,
\ the paths a stage's result names and a lease's slot directory.

require src/lib/error.f
require src/lib/string.f
require src/lib/span.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/fmt.f
require src/lib/adt/option.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-anchored.f
require src/lib/fs-statx.f
require src/lib/fs-list.f
require src/lib/allocator.f
require src/lib/fd.f
require src/lib/xattr.f
require src/lib/vector.f
require src/lib/sort.f
require src/dropbox.f
require src/model.f
require src/journal.f

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
-100511 s" a local filesystem operation found the disk full"
   ERROR:CODE E-DISK-FULL

\ The side whose bytes a conflict copy holds.
ENUM conflict-side local remote ;ENUM

private

$10000 constant IO-SIZE

$2F constant SLASH
$2E constant DOT

\ ---- errors

: LOG-OPEN ( -- ) LOG:ERROR s" local" LOG:LINE ;

: QUOTED+ ( str -- ) s" `" LOG:TEXT+ LOG:TEXT+ s" `" LOG:TEXT+ ;

: ERRNO+ ( n -- )
   {: e:n :}
   e 0= if exit then
   s" : " LOG:TEXT+ e FS:ERRNO$ LOG:TEXT+ ;

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

\ The innermost WITH-CONVERTS's predicate; NONE-CONVERTED outside any.
TYPED-VARIABLE CONVERTS [ n n -- bool ]
' NONE-CONVERTED CONVERTS !

\ Whether LOCAL logs nothing for a failure: its catcher converts it.
: QUIET? ( n n -- bool ) CONVERTS @ execute ;

public

\ Runs q with converted? as the predicate QUIET? asks, the outer one back
\ on every exit. LOCAL logs no failure converted? names: the caller
\ converts it into an outcome.
: WITH-CONVERTS ( R [ R -- S ] [ n n -- bool ] -- S )
   {: q converted? :}
   CONVERTS @ {: outer :}
   converted? CONVERTS !
   [: q execute ;] [: outer CONVERTS ! ;] finally ;

\ Runs q under WITH-CONVERTS; answers what q threw, 0 for none.
: CONVERTING ( [ -- ] [ n n -- bool ] -- n )
   {: q converted? :}
   [: [: q execute ;] catch ;] converted? WITH-CONVERTS ;

private

\ Logs "local path `p`" and the text after it, then throws code.
: PATH-FAILS ( str str n -- )
   {: p:str t:str code:n :}
   code FS:ERRNO QUIET? 0= if
      LOG-OPEN s" local path " LOG:TEXT+ p QUOTED+
      t LOG:TEXT+ LOG:;LINE
   then
   code throw ;

: UNSAFE ( str -- )
   s"  is not a safe path relative to the sync root"
   E-UNSAFE-PATH PATH-FAILS ;

: UNSUPPORTED-FAILS ( str n -- )
   {: p:str code:n :}
   p s"  is not a regular file or directory" code PATH-FAILS ;

: UNREADABLE ( str -- )
   s"  is a file Omabox cannot read" E-UNREADABLE PATH-FAILS ;

\ The operation, then the path, as every word below takes them.
: CHANGED-FAILS ( str str n -- )
   {: o:str p:str code:n :}
   code FS:ERRNO QUIET? 0= if
      LOG-OPEN s" local path " LOG:TEXT+ p QUOTED+
      s"  changed during " LOG:TEXT+ o QUOTED+ LOG:;LINE
   then
   code throw ;

: CHANGED ( str str -- ) E-CHANGED CHANGED-FAILS ;

: INVALID-HASH ( str -- )
   {: o:str :}
   E-CONTENT-HASH FS:ERRNO QUIET? 0= if
      LOG-OPEN s" operation " LOG:TEXT+ o QUOTED+
      s"  requires a lowercase Dropbox content hash" LOG:TEXT+ LOG:;LINE
   then
   E-CONTENT-HASH throw ;

: CORRUPT ( str str -- )
   {: o:str p:str :}
   E-CORRUPT FS:ERRNO QUIET? 0= if
      LOG-OPEN s" private local file for " LOG:TEXT+ o QUOTED+
      s"  at " LOG:TEXT+ p QUOTED+
      s"  failed content verification" LOG:TEXT+ LOG:;LINE
   then
   E-CORRUPT throw ;

: OCCUPIED ( str str -- )
   {: o:str p:str :}
   E-OCCUPIED FS:ERRNO QUIET? 0= if
      LOG-OPEN s" non-overwriting operation " LOG:TEXT+ o QUOTED+
      s"  found unrelated bytes at " LOG:TEXT+ p QUOTED+ LOG:;LINE
   then
   E-OCCUPIED throw ;

\ Opens the line of operation o failing for p with errno e.
: FAILED+ ( str str n -- )
   {: o:str p:str e:n :}
   LOG-OPEN s" local filesystem operation " LOG:TEXT+ o QUOTED+
   s"  failed for " LOG:TEXT+ p QUOTED+ e ERRNO+ ;

\ Rust's io_failure, throwing code: FS:ERRNO holds the errno, kept across
\ the log.
: IO-FAILS ( str str n -- )
   {: o:str p:str code:n :}
   FS:ERRNO {: e:n :}
   code e QUIET? 0= if o p e FAILED+ LOG:;LINE then
   e FS:CAUSE! code throw ;

public

: IO-FAILURE ( str str -- )
   FS:ERRNO FS:ENOSPC = if E-DISK-FULL else E-IO then IO-FAILS ;

private

\ Closes a descriptor, keeping FS:ERRNO; as Rust's drop of a File, it
\ ignores close's own failure.
: DISCARD ( fd -- ) FD>N close ;

\ What statx says of an entry: its permission bits with the type, its
\ owner's uid and the attributes the filesystem reports.
STRUCTURE facts
   FIELD mode n
   FIELD owner n
   FIELD flags n
;STRUCTURE

\ None when statx fails, which FS-STATX logs.
: FACTS ( fd -- option<facts> )
   {: f:fd :}
   0 0 0 [: 2drop drop f FS-STATX:PERMISSIONS ;] catch {: code:n :}
   code 0= if FACTS-MAKE OPTION:SOME exit then
   2drop drop code E-FS-STAT <> if code throw then
   OPTION:NONE ;

\ The facts of the entry named in dir, not of a symlink's target; none
\ for an empty name or an entry that does not open.
: ENTRY-FACTS ( fd str -- option<facts> )
   {: dir:fd name:str :}
   name str> nip 0= if OPTION:NONE exit then
   dir name FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: f:fd :} f FACTS f DISCARD ENDOF
   ;MATCH ;

\ The errnos a permission check or an immutable or append-only
\ attribute answers.
: DENIED? ( n -- bool )
   {: e:n :}
   e FS:EACCES = e FS:EPERM = or ;

FS:PATHZ-CAP BUFFER: DENIED-PATH

: FACTS+ ( option<facts> -- )
   MATCH option
      none OF ENDOF
      some OF FACTS-UNMAKE {: m:n o:n a:n :}
         s"  mode " LOG:TEXT+ m $FFF and 4 FMT:OCT-WIDTH$ LOG:TEXT+
         s"  owner uid " LOG:TEXT+ o LOG:INT+
         a FS-STATX:IMMUTABLE and 0<> if s"  immutable" LOG:TEXT+ then
         a FS-STATX:APPEND and 0<> if s"  append-only" LOG:TEXT+ then
      ENDOF
   ;MATCH ;

\ The directory's path, left out when FD-PATH, which logs nothing,
\ cannot give it.
: PATH+ ( fd -- )
   {: dir:fd :}
   0 [: drop dir DENIED-PATH FS:PATHZ-CAP FS:FD-PATH ;] catch
   {: code:n :}
   code 0= if s"  " LOG:TEXT+ DENIED-PATH swap >str QUOTED+ exit then
   drop code E-FS-STAT = code E-FS-CAPACITY = or if exit then
   code throw ;

: DIRECTORY+ ( fd option<facts> -- )
   {: dir:fd known :}
   s" ; directory" LOG:TEXT+ dir PATH+ known FACTS+ ;

: ENTRY+ ( str option<facts> -- )
   {: name:str known :}
   known MATCH option
      none OF ENDOF
      some OF drop s" ; entry " LOG:TEXT+ name QUOTED+ known FACTS+
      ENDOF
   ;MATCH ;

: RUNS-AS+ ( -- )
   s" ; Omabox runs as uid " LOG:TEXT+ FS:EUID LOG:INT+ ;

\ IO-FAILURE for any errno but a denial LOCAL logs.
: UNLESS-DENIED ( str str n -- )
   {: o:str p:str e:n :}
   E-IO e QUIET? e DENIED? 0= or if o p IO-FAILURE then ;

\ The facts of dir and of the entry named in it, read before the line
\ opens: a failing statx logs a line of its own.
: SIDE ( fd str -- option<facts> option<facts> )
   {: dir:fd name:str :}
   dir FACTS dir name ENTRY-FACTS ;

: SIDE+ ( fd str option<facts> option<facts> -- )
   {: dir:fd name:str df ef :}
   dir df DIRECTORY+ name ef ENTRY+ ;

: DENIED-THROW ( n -- )
   {: e:n :}
   RUNS-AS+ LOG:;LINE e FS:CAUSE! E-IO throw ;

public

\ IO-FAILURE for a call on the name in dir, or on dir for an empty name;
\ a denial's line also gives their facts.
: IO-FAILURE-AT ( fd str str str -- )
   {: dir:fd name:str o:str p:str :}
   FS:ERRNO {: e:n :}
   o p e UNLESS-DENIED
   dir name SIDE {: df ef :}
   o p e FAILED+ dir name df ef SIDE+ e DENIED-THROW ;

private

\ IO-FAILURE-AT for a call from a name in one directory to a name in
\ another: a denial's line gives both sides, the source first.
: IO-FAILURE-ACROSS ( fd str fd str str str -- )
   {: from:fd fn:str to:fd tn:str o:str p:str :}
   FS:ERRNO {: e:n :}
   o p e UNLESS-DENIED
   from fn SIDE {: sd se :} to tn SIDE {: td te :}
   o p e FAILED+
   from fn sd se SIDE+ to tn td te SIDE+ e DENIED-THROW ;

\ Rust's syscall_failure: io_failure with the errno given.
: SYSCALL-FAILURE ( n str str -- )
   {: e:n o:str p:str :}
   e FS:CAUSE! o p IO-FAILURE ;

\ Rust's StageIoError::Read: the source of a stage's bytes failed.
: STAGE-READ ( str str -- )
   {: o:str p:str :}
   FS:ERRNO {: e:n :}
   E-STAGE-READ e QUIET? 0= if
      LOG-OPEN s" could not read stage input during " LOG:TEXT+
      o QUOTED+ s"  for " LOG:TEXT+ p QUOTED+ e ERRNO+ LOG:;LINE
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

\ Runs q; a throw closes fd before it goes on, a return leaves it open.
: CLOSING ( R fd [ R -- R ] -- R )
   {: f:fd q :}
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   f DISCARD code throw ;

\ ---- stat

\ A descriptor and its stat, as Rust's (File, Stat).
STRUCTURE opened
   FIELD fd fd
   FIELD stat MODEL:stat
;STRUCTURE

\ A file opened and hashed, as Rust's (File, ContentIdentity,
\ LocalFileFingerprint).
STRUCTURE hashed
   FIELD fd fd
   FIELD content DROPBOX:hash
   FIELD fingerprint MODEL:fingerprint
;STRUCTURE

\ The seeds a guarded word replaces, and their typed drops.
: NO-STAT ( -- MODEL:stat ) 0 0 0 0 0 0 0 0 MODEL-STAT:MAKE ;
: NO-HASH ( -- DROPBOX:hash ) s" " DROPBOX:>HASH ;
: NO-FINGERPRINT ( -- MODEL:fingerprint )
   0 0 0 0 0 0 MODEL-FINGERPRINT:MAKE ;
: DROP-STAT ( MODEL:stat -- ) drop ;
: DROP-HASH ( DROPBOX:hash -- ) drop ;
: DROP-FINGERPRINT ( MODEL:fingerprint -- ) drop ;

\ The stat FS's stat buffer holds.
: BUF-STAT ( -- MODEL:stat )
   FS:STAT-DEV@ FS:STAT-INO@ FS:STAT-MODE@ FS:STAT-SIZE@
   FS:STAT-MTIME-SEC@ FS:STAT-MTIME-NS@
   FS:STAT-CTIME-SEC@ FS:STAT-CTIME-NS@ MODEL-STAT:MAKE ;

: STAT-FD-FAILS ( fd str str n -- MODEL:stat )
   {: f:fd p:str o:str code:n :}
   [: f FS:FD-STAT ;] [: o p code IO-FAILS ;] FS-FAILS BUF-STAT ;

: STAT-FD ( fd str str -- MODEL:stat ) E-IO STAT-FD-FAILS ;

: REGULAR? ( MODEL:stat -- bool )
   MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :}
   m FS:S-IFMT and FS:S-IFREG = ;

: SAME-INODE ( MODEL:stat MODEL:stat -- bool )
   {: a:MODEL:stat b:MODEL:stat :}
   a MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :}
   b MODEL-STAT:UNMAKE {: d2 i2 m2 s2 ms2 mn2 cs2 cn2 :}
   d d2 = i i2 = and ;

: SAME-OBSERVATION ( MODEL:stat MODEL:stat -- bool )
   {: a:MODEL:stat b:MODEL:stat :}
   a b SAME-INODE 0= if false exit then
   a MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :}
   b MODEL-STAT:UNMAKE {: d2 i2 m2 s2 ms2 mn2 cs2 cn2 :}
   s s2 = ms ms2 = and mn mn2 = and cs cs2 = and cn cn2 = and ;

: SAME-HASHED-CONTENT ( MODEL:fingerprint MODEL:fingerprint -- bool )
   {: a:MODEL:fingerprint b:MODEL:fingerprint :}
   a MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   b MODEL-FINGERPRINT:UNMAKE {: i2 s2 ms2 mn2 cs2 cn2 :}
   i i2 = s s2 = and ms ms2 = and mn mn2 = and ;

: FILE-FINGERPRINT ( MODEL:stat str -- MODEL:fingerprint )
   {: st:MODEL:stat p:str :}
   st MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :}
   s 0 < if 0 s" inspect local file size" p SYSCALL-FAILURE then
   i s ms mn cs cn MODEL-FINGERPRINT:MAKE ;

\ ---- content hashes

TYPED-VARIABLE HASHER DROPBOX:hasher
IO-SIZE BUFFER: IO-BUF

\ Copies the bytes into the arena.
: KEEP ( str ^ARENA:arena -- str )
   {: s:str ar:^ARENA:arena :}
   s str> {: p:^ u:n :}
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

: REWIND ( fd str -- )
   {: f:fd p:str :}
   [: f 0 FD:SEEK ;]
   [: s" rewind file before hashing" p IO-FAILURE ;] FS-FAILS ;

\ The content hash of fd's bytes from its start; a read failure is o's.
: HASH-READS ( fd str str ^ARENA:arena -- DROPBOX:hash )
   {: f:fd p:str o:str ar:^ARENA:arena :}
   f p REWIND
   NO-HASH [: DROP-HASH f ar HASH-FD ;] [: o p IO-FAILURE ;]
   FS-FAILS ;

\ The hash of a regular file whose stat after the read is the one given;
\ a file not regular throws the first code, a changed one the second.
: HASH-STABLE-FILE-FROM-STAT
   ( fd str str MODEL:stat ^ARENA:arena n n
     -- DROPBOX:hash MODEL:fingerprint )
   {: f:fd p:str o:str before:MODEL:stat ar:^ARENA:arena
      unsupported:n changed:n :}
   before REGULAR? 0= if p unsupported UNSUPPORTED-FAILS then
   before p FILE-FINGERPRINT {: print:MODEL:fingerprint :}
   f p o ar HASH-READS {: c:DROPBOX:hash :}
   before f p o STAT-FD SAME-OBSERVATION 0= if
      o p changed CHANGED-FAILS
   then
   c print ;

: HASH-STABLE-FILE-WITH-FINGERPRINT
   ( fd str str ^ARENA:arena n n -- DROPBOX:hash MODEL:fingerprint )
   {: f:fd p:str o:str ar:^ARENA:arena unsupported:n changed:n :}
   f p o STAT-FD {: before:MODEL:stat :}
   f p o before ar unsupported changed HASH-STABLE-FILE-FROM-STAT ;

: HASH-STABLE-FILE ( fd str str ^ARENA:arena n n -- DROPBOX:hash )
   HASH-STABLE-FILE-WITH-FINGERPRINT
   {: c:DROPBOX:hash print:MODEL:fingerprint :} c ;

\ o names the operation that needs the hash.
: REQUIRE-CONTENT-HASH ( DROPBOX:hash str -- )
   {: h:DROPBOX:hash o:str :}
   h DROPBOX:HASH>STR DROPBOX:CONTENT-HASH? 0= if
      o INVALID-HASH
   then ;

\ ---- names

SHA256-CTX-BYTES BUFFER: NAME-CTX
32 BUFFER: NAME-DIGEST
1 BUFFER: NUL

: FEED ( str -- ) {: p:str :} NAME-CTX p SHA256-FEED ;

\ Copies the bytes to dst at offset at; answers the offset after them.
: PUT ( str ^u8 n -- n )
   {: s:str dst:^ at:n :}
   s str> {: p:^ u:n :}
   p dst at + u BYTE-COPY at u + ;

\ ".omabox-<prefix>-" and the hex SHA-256 of the prefix, the path and
\ the content, each NUL-separated; laid in the arena.
: INTERNAL-NAME ( str str DROPBOX:hash ^ARENA:arena -- str )
   {: x:str p:str c:DROPBOX:hash ar:^ARENA:arena :}
   x str> nip {: xu:n :}
   NAME-CTX SHA256-BEGIN
   x FEED NUL 1 >str FEED p FEED NUL 1 >str FEED c DROPBOX:HASH>STR FEED
   NAME-CTX NAME-DIGEST SHA256-END
   ar 8 xu + 1+ 64 + ARENA:ALLOC {: dst:^ size:n :}
   s" .omabox-" dst 0 PUT {: at:n :}
   x dst at PUT {: at2:n :}
   s" -" dst at2 PUT {: at3:n :}
   NAME-DIGEST dst at3 + SHA256>HEX
   dst size >str ;

: PREFIXED-HASH? ( str str -- bool )
   {: s:str x:str :}
   s str> {: p:^ u:n :}
   x str> nip {: xu:n :}
   u xu < if false exit then
   p xu >str x STR:= 0= if false exit then
   p xu + u xu - >str DROPBOX:CONTENT-HASH? ;

\ A name only LOCAL makes: a download, displaced or deleted file's.
: RESERVED-ARTIFACT? ( str -- bool )
   {: p:str :}
   p s" .omabox-download-" PREFIXED-HASH? if true exit then
   p s" .omabox-displaced-" PREFIXED-HASH? if true exit then
   p s" .omabox-deleted-" PREFIXED-HASH? ;

: CONFLICT-NAME
   ( str conflict-side DROPBOX:hash ^ARENA:arena -- str )
   {: p:str side:conflict-side c:DROPBOX:hash ar:^ARENA:arena :}
   side MATCH conflict-side
      local OF s" conflict-local" ENDOF
      remote OF s" conflict-remote" ENDOF
   ;MATCH p c ar INTERNAL-NAME ;

\ ---- relative paths

\ The bytes of p from from up to to.
: PART ( str n n -- str )
   {: p:str from:n to:n :}
   p str> drop from + to from - >str ;

: SKIP-SEPS ( str n -- n )
   {: s:str at:n :}
   s str> {: p:^ u:n :}
   at begin dup u < while
      p over + c@ SLASH <> if exit then
      1+
   repeat ;

: COMPONENT-END ( str n -- n )
   {: s:str at:n :}
   s str> {: p:^ u:n :}
   at begin dup u < while
      p over + c@ SLASH = if exit then
      1+
   repeat ;

: CURRENT? ( str -- bool )
   {: s:str :}
   s str> {: p:^ u:n :}
   u 1 = if p c@ DOT = exit then
   false ;

: PARENT? ( str -- bool )
   {: s:str :}
   s str> {: p:^ u:n :}
   u 2 = if p c@ DOT = p 1+ c@ DOT = and exit then
   false ;

\ Whether the path starts with Rust's CurDir component.
: LEADING-DOT? ( str -- bool )
   {: s:str :}
   s str> {: p:^ u:n :}
   p c@ DOT <> if false exit then
   u 1 = if true exit then
   p 1+ c@ SLASH = ;

\ The next component from at on that is neither empty nor ".": its start,
\ its end and true; u u false past the last.
: NEXT-COMPONENT ( str n -- n n bool )
   {: p:str at:n :}
   p str> nip {: u:n :}
   p at SKIP-SEPS {: from:n :}
   from u >= if u u false exit then
   p from COMPONENT-END {: to:n :}
   p from to PART CURRENT? if p to RECURSE exit then
   from to true ;

\ The components from at on, counted onto count; ".." is unsafe.
: TALLY ( str n n -- n )
   {: p:str count:n at:n :}
   p at NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if count exit then
   p from to PART PARENT? if p UNSAFE then
   p count 1+ to RECURSE ;

\ Rust's safe_components: throws E-UNSAFE-PATH for an unsafe path, else
\ answers its count of components.
: SAFE-COMPONENTS ( str -- n )
   {: p:str :}
   p str> nip 0= if p UNSAFE then
   p str> drop c@ SLASH = if p UNSAFE then
   p LEADING-DOT? if p UNSAFE then
   p 0 0 TALLY ;

: LAST-FROM ( str n n n -- n n n )
   {: p:str prev:n from:n to:n :}
   p to NEXT-COMPONENT {: from2:n to2:n found:bool :}
   found 0= if prev from to exit then
   p to from2 to2 RECURSE ;

\ Rust's split_last over a safe path's components: the bytes of the
\ parent, then the last component's start and end.
: SPLIT-LAST ( str -- n n n )
   {: p:str :}
   p 0 NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if p UNSAFE then
   p 0 from to LAST-FROM ;

\ The safe path's parent, a prefix of it, empty for a top-level name.
: PARENT-PATH ( str -- str )
   {: p:str :}
   p SAFE-COMPONENTS drop
   p SPLIT-LAST 2drop {: len:n :}
   p 0 len PART ;

\ ---- opens

\ Opens the components of p from at on from dir, which it then closes,
\ each by O_PATH: some, or none with FS:ERRNO set; and the offset past
\ the last component it tried.
: DESCEND ( fd str n -- option<fd> n )
   {: dir:fd p:str at:n :}
   p at NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if dir OPTION:SOME at exit then
   dir p from to PART FS:TRY-OPEN-ENTRY-AT dir DISCARD
   MATCH option
      none OF OPTION:NONE to ENDOF
      some OF p to RECURSE ENDOF
   ;MATCH ;

\ DESCEND from the root, which stays open; p holds a component.
: WALK ( fd str -- option<fd> n )
   {: root:fd p:str :}
   p 0 NEXT-COMPONENT {: from:n to:n found:bool :}
   root p from to PART FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF OPTION:NONE to ENDOF
      some OF p to DESCEND ENDOF
   ;MATCH ;

: OPEN-ABSOLUTE-DIRECTORY ( str str -- fd )
   {: p:str o:str :}
   p str> nip 0= if p UNSAFE then
   p str> drop c@ SLASH <> if p UNSAFE then
   -1 >FD [: drop p FS:OPEN-DIR ;] [: o p IO-FAILURE ;] FS-FAILS ;

public

\ The sync root's directory, o naming the operation that opens it.
: OPEN-ROOT ( str str -- fd ) OPEN-ABSOLUTE-DIRECTORY ;

: OPEN-PRIVATE-DIRECTORY ( str str -- fd ) OPEN-ABSOLUTE-DIRECTORY ;

private

\ A probe that failed confirms nothing, unless the system ran out of a
\ resource, which says nothing about the entry.
: UNCONFIRMED ( str -- bool )
   {: p:str :}
   FS:ERRNO EXHAUSTED? if
      s" probe local entry existence" p IO-FAILURE
   then false ;

\ Whether dir holds the name, closing dir unless it is the root.
: PRESENT-IN? ( fd bool str str -- bool )
   {: dir:fd owned:bool name:str p:str :}
   dir name FS:TRY-STAT-AT
   owned if dir DISCARD then
   if true exit then
   p UNCONFIRMED ;

public

\ Whether an entry is at the path below the root now, a symlink itself
\ included; its parents are never followed through a symlink.
: ENTRY-EXISTS-AT ( fd str -- bool )
   {: root:fd p:str :}
   p SAFE-COMPONENTS drop
   p SPLIT-LAST {: parent:n from:n to:n :}
   p from to PART {: name:str :}
   parent 0= if root false name p PRESENT-IN? exit then
   root p 0 parent PART WALK {: o:option<fd> at:n :}
   o MATCH option
      none OF p 0 at PART UNCONFIRMED ENDOF
      some OF true name p PRESENT-IN? ENDOF
   ;MATCH ;

private

\ Opens p's last component for reading below the root.
: OPEN-BELOW ( fd str -- option<fd> )
   {: root:fd p:str :}
   p SPLIT-LAST {: parent:n from:n to:n :}
   p from to PART {: name:str :}
   parent 0= if root name FS:TRY-OPEN-READ-AT exit then
   root p 0 parent PART WALK drop MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: dir:fd :} dir name FS:TRY-OPEN-READ-AT dir DISCARD
      ENDOF
   ;MATCH ;

\ A failed stat throws the first code, a file not regular the second.
: CHECK-REGULAR ( fd str str n n -- MODEL:stat )
   {: f:fd p:str o:str io:n unsupported:n :}
   f p o io STAT-FD-FAILS {: st:MODEL:stat :}
   st REGULAR? 0= if p unsupported UNSUPPORTED-FAILS then
   st ;

\ The stat of the regular file at fd, CHECK-REGULAR's codes given; a throw
\ closes fd.
: REGULAR-STAT ( fd str str n n -- MODEL:stat )
   {: f:fd p:str o:str io:n unsupported:n :}
   NO-STAT f [: DROP-STAT f p o io unsupported CHECK-REGULAR ;]
   CLOSING ;

\ A failed open or stat throws the first code, a file not regular the
\ second.
: OPEN-RELATIVE-REGULAR-WITH-STAT ( fd str str n n -- fd MODEL:stat )
   {: root:fd p:str o:str io:n unsupported:n :}
   p SAFE-COMPONENTS drop
   root p OPEN-BELOW MATCH option
      none OF o p io IO-FAILS ENDOF
      some OF {: f:fd :} f f p o io unsupported REGULAR-STAT ENDOF
   ;MATCH ;

: OPEN-RELATIVE-REGULAR ( fd str str n n -- fd )
   OPEN-RELATIVE-REGULAR-WITH-STAT {: f:fd st:MODEL:stat :} f ;

: OPEN-DIRECTORY-AT ( fd str str -- fd )
   {: dir:fd name:str p:str :}
   dir name FS:TRY-OPEN-DIR-AT MATCH option
      none OF
         dir name s" open root-confined directory" p IO-FAILURE-AT
      ENDOF
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
: MISSING-OR-FAILS ( str str -- )
   {: p:str o:str :}
   FS:ERRNO FS:ENOENT <> if o p IO-FAILURE then ;

\ The stat of the open entry; a failed stat closes it.
: STAT-CLOSING ( fd str str -- MODEL:stat )
   {: f:fd p:str o:str :}
   NO-STAT f [: DROP-STAT f p o STAT-FD ;] CLOSING ;

\ Whether the probed entry is a regular file; closes the probe.
: PROBED-REGULAR? ( fd str str -- bool )
   {: probe:fd p:str o:str :}
   probe p o STAT-CLOSING probe DISCARD REGULAR? ;

\ The entry open for reading, closed unless it is a regular file.
: OPENED-ENTRY ( fd str str -- name-entry )
   {: f:fd p:str o:str :}
   f p o STAT-CLOSING {: st:MODEL:stat :}
   st REGULAR? 0= if f DISCARD NAME-ENTRY-UNSUPPORTED exit then
   f st OPENED-MAKE NAME-ENTRY-REGULAR ;

: OPEN-READ ( fd str str str -- name-entry )
   {: dir:fd name:str p:str o:str :}
   dir name FS:TRY-OPEN-READ-AT MATCH option
      none OF FS:ERRNO FS:EACCES = if NAME-ENTRY-UNREADABLE
         else p o MISSING-OR-FAILS NAME-ENTRY-ABSENT then
      ENDOF
      some OF p o OPENED-ENTRY ENDOF
   ;MATCH ;

\ What the name holds, probed without following a symlink, then opened
\ for reading when a regular file is there.
: OPEN-NAMED ( fd str str str -- name-entry )
   {: dir:fd name:str p:str o:str :}
   dir name FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF p o MISSING-OR-FAILS NAME-ENTRY-ABSENT ENDOF
      some OF {: probe:fd :}
         probe p o PROBED-REGULAR? if
            dir name p o OPEN-READ
         else NAME-ENTRY-UNSUPPORTED then
      ENDOF
   ;MATCH ;

\ The regular file at the name, none when nothing is there; another
\ object throws E-UNSUPPORTED, a file Omabox cannot read E-UNREADABLE.
: OPEN-REGULAR-AT-IF-PRESENT
   ( fd str str str -- option<opened> )
   {: dir:fd name:str p:str o:str :}
   dir name p o OPEN-NAMED MATCH name-entry
      absent OF OPTION:NONE ENDOF
      regular OF OPTION:SOME ENDOF
      unsupported OF p E-UNSUPPORTED UNSUPPORTED-FAILS ENDOF
      unreadable OF p UNREADABLE ENDOF
   ;MATCH ;

\ Hashes the opened file, closing it on a throw.
: HASH-OPENED ( opened str str ^ARENA:arena -- hashed )
   {: x:opened p:str o:str ar:^ARENA:arena :}
   x OPENED-UNMAKE {: f:fd st:MODEL:stat :}
   NO-HASH NO-FINGERPRINT f
   [: DROP-FINGERPRINT DROP-HASH f p o st ar E-UNSUPPORTED E-CHANGED
      HASH-STABLE-FILE-FROM-STAT ;] CLOSING
   {: c:DROPBOX:hash print:MODEL:fingerprint :}
   f c print HASHED-MAKE ;

: OPEN-AND-HASH-IF-PRESENT
   ( fd str str str ^ARENA:arena -- option<hashed> )
   {: dir:fd name:str p:str o:str ar:^ARENA:arena :}
   dir name p o OPEN-REGULAR-AT-IF-PRESENT MATCH option
      none OF OPTION:NONE ENDOF
      some OF p o ar HASH-OPENED OPTION:SOME ENDOF
   ;MATCH ;

: HASH-AT-IF-PRESENT
   ( fd str str str ^ARENA:arena -- option<DROPBOX:hash> )
   OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF OPTION:NONE ENDOF
      some OF HASHED-UNMAKE
         {: f:fd c:DROPBOX:hash print:MODEL:fingerprint :}
         f DISCARD c OPTION:SOME
      ENDOF
   ;MATCH ;

\ The open regular file at the name and its hash; none there is ENOENT.
: OPEN-AND-HASH-AT
   ( fd str str str ^ARENA:arena -- fd DROPBOX:hash )
   {: dir:fd name:str p:str o:str ar:^ARENA:arena :}
   dir name p o ar OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF FS:ENOENT o p SYSCALL-FAILURE ENDOF
      some OF HASHED-UNMAKE
         {: f:fd c:DROPBOX:hash print:MODEL:fingerprint :}
         f c
      ENDOF
   ;MATCH ;

\ Whether the name's entry is file's inode; a symlink there is another.
: NAMED-INODE-MATCHES ( fd fd str str -- bool )
   {: file:fd dir:fd name:str p:str :}
   file p s" inspect held local entry" STAT-FD {: held:MODEL:stat :}
   dir name FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF FS:ERRNO FS:ENOENT <> if
            s" inspect named local entry" p IO-FAILURE
         then false
      ENDOF
      some OF {: e:fd :}
         NO-STAT e
         [: DROP-STAT e p s" inspect named local entry" STAT-FD ;] CLOSING
         e DISCARD held SAME-INODE
      ENDOF
   ;MATCH ;

: SYNC-DIRECTORY ( fd str str -- )
   {: f:fd p:str o:str :}
   [: f FD:SYNC ;] [: o p IO-FAILURE ;] FS-FAILS ;

: SYNC-FILE ( fd str str -- ) SYNC-DIRECTORY ;

\ Syncs the regular file at the name and its entry; none there is a
\ change.
: SYNC-INSTALLED-FILE ( fd str str -- )
   {: dir:fd name:str p:str :}
   s" open installed file for sync" {: o:str :}
   dir name p o OPEN-REGULAR-AT-IF-PRESENT MATCH option
      none OF o p CHANGED ENDOF
      some OF OPENED-UNMAKE {: f:fd st:MODEL:stat :}
         [: f p s" sync installed file" SYNC-FILE ;] [: f DISCARD ;]
         finally
      ENDOF
   ;MATCH
   dir p s" sync installed file entry" SYNC-DIRECTORY ;

\ ---- the scan

\ Seconds a hash's file must have kept still before the cache may reuse
\ the hash: more than FAT's two-second mtime tick. The cache needs coherent
\ local metadata; stale network metadata is not supported.
3 constant RACY-WINDOW

STRUCTURE scanned-hash
   FIELD record MODEL:hash-record
   FIELD reusable bool
;STRUCTURE

\ The walk's settings, which no step changes: any device but
\ root-device is out of scope.
STRUCTURE scan-context
   FIELD cutoff option<MODEL:cutoff>
   FIELD root-device n
;STRUCTURE

\ An enumerated root whose files are still to hash; it owns root-fd.
STRUCTURE pending-scan
   FIELD root str
   FIELD root-fd fd
   FIELD root-before MODEL:stat
   FIELD arena ^ARENA:arena
;STRUCTURE

\ A listed directory whose subtree the walk has still to enter; it owns
\ fd and arena, which hold the names.
STRUCTURE held-dir
   FIELD fd fd
   FIELD path str
   FIELD names ^VEC:vector<str>
   FIELD arena ^ARENA:arena
;STRUCTURE

public

\ Published while the scanned root still is the active journal
\ generation's, the inventory then the journal's; root-changed when the
\ configured path names another.
ENUM scan-publication
   VARIANT published ;VARIANT
   VARIANT root-changed ;VARIANT
;ENUM

private

\ ---- the hash cache's cutoff

\ Rust's hash_cache_cutoff, from seconds since the epoch: Habu's clock reads
\ no finer, and the second's start only makes fewer hashes reusable.
: HASH-CACHE-CUTOFF ( n -- option<MODEL:cutoff> )
   {: now:n :}
   now RACY-WINDOW - {: s:n :}
   s 0 < if OPTION:NONE exit then
   s 0 MODEL-CUTOFF:MAKE OPTION:SOME ;

: RECORD-FINGERPRINT ( MODEL:hash-record -- MODEL:fingerprint )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :} f ;

: RECORD-PATH ( MODEL:hash-record -- str )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :}
   p MODEL:PATH>STR ;

: HASH-IS-REUSABLE ( MODEL:hash-record option<MODEL:cutoff> -- bool )
   {: r:MODEL:hash-record o:option<MODEL:cutoff> :}
   o MATCH option
      none OF false ENDOF
      some OF r RECORD-FINGERPRINT swap MODEL:BEFORE? ENDOF
   ;MATCH ;

: CURRENT-HASH-CACHE-CUTOFF ( -- option<MODEL:cutoff> )
   epoch-seconds HASH-CACHE-CUTOFF ;

\ ---- records

: NEW-VEC ( ^ARENA:arena width<t> -- ^VEC:vector<t> )
   {: ar:^ARENA:arena w :}
   ar ARENA:ALLOCATOR 0 w VEC:NEW ;

: UNKNOWN-OBSERVATION
   ( MODEL:unknown-reason -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:UNKNOWN ;

: DIRECTORY-OBSERVATION ( -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:DIRECTORY ;

: PRESENT-OBSERVATION ( MODEL:local -- MODEL:observation<MODEL:local> )
   MODEL-OBSERVATION:PRESENT ;

: UNKNOWN-RECORD ( str MODEL:unknown-reason -- MODEL:local-record )
   {: p:str why:MODEL:unknown-reason :}
   p MODEL:>PATH why UNKNOWN-OBSERVATION MODEL-LOCAL--RECORD:MAKE ;

\ Records the path as unknown, for the reason, outside the walk.
: UNKNOWN ( JOURNAL:scan str MODEL:unknown-reason -- JOURNAL:scan )
   UNKNOWN-RECORD JOURNAL:SCAN-OBSERVE ;

\ The walk's entry at the path is unknown, for the reason.
: SEEN-UNKNOWN ( JOURNAL:scan str MODEL:unknown-reason -- JOURNAL:scan )
   UNKNOWN-RECORD JOURNAL:SCAN-SEEN ;

\ ---- order

: KEY-LESS ( n n [ n -- str ] -- bool )
   {: a:n b:n key :}
   a key execute b key execute STR:< ;

\ The indices below count in the byte order of the keys key answers for
\ them.
: ORDER ( n [ n -- str ] ^ARENA:arena -- ^VEC:vector<n> )
   {: count:n key ar:^ARENA:arena :}
   ar ARENA:ALLOCATOR count [type] n VEC:NEW {: idx :}
   count 0 ?do i idx i VEC:AT ! loop
   count 2 < if idx exit then
   idx 0 VEC:AT count [: key KEY-LESS ;] SORT:SORT!
   idx ;

: STR@ ( ^str -- str ) @ ;

\ ---- the walk's steps

\ The code a step threw, 0 for none, when ENTRY-CODE? names it with
\ FS:ERRNO; any other code throws on.
: STEP-CODE ( n -- n )
   {: code:n :}
   code 0= if 0 exit then
   code FS:ERRNO ENTRY-CODE? 0= if code throw then
   code ;

\ Runs step, a filesystem step: no catch may hold the linear scan.
: ENTRY-STEP ( [ -- ] -- n )
   {: step :}
   [: step execute ;] catch STEP-CODE ;

: IO-STEP ( str str -- n )
   {: o:str p:str :}
   [: o p IO-FAILURE ;] ENTRY-STEP ;

: UNSUPPORTED-STEP ( str -- n )
   {: p:str :}
   [: p E-UNSUPPORTED UNSUPPORTED-FAILS ;] ENTRY-STEP ;

\ ---- the walk

: STAT-DEV ( MODEL:stat -- n ) MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :} d ;

: DIRECTORY? ( MODEL:stat -- bool )
   MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :}
   m FS:S-IFMT and FS:S-IFDIR = ;

: SAME-FINGERPRINT? ( MODEL:fingerprint MODEL:fingerprint -- bool )
   {: a:MODEL:fingerprint b:MODEL:fingerprint :}
   a b SAME-HASHED-CONTENT 0= if false exit then
   a MODEL-FINGERPRINT:UNMAKE {: i s ms mn cs cn :}
   b MODEL-FINGERPRINT:UNMAKE {: i2 s2 ms2 mn2 cs2 cn2 :}
   cs cs2 = cn cn2 = and ;

\ p and the relative q joined as Rust's Path::join joins them, laid anew in
\ the arena; an empty q answers p, where Rust appends a "/".
: JOIN ( str str ^ARENA:arena -- str )
   {: p:str q:str ar:^ARENA:arena :}
   p str> nip {: u:n :}
   q str> nip {: qu:n :}
   u 0= qu 0= or p FS:JOIN-SEPARATED? or {: bare:bool :}
   bare if 0 else 1 then {: sep:n :}
   ar u sep + qu + ARENA:ALLOC {: dst:^ size:n :}
   p dst 0 PUT {: at:n :}
   s" /" 0 sep PART dst at PUT {: at2:n :}
   q dst at2 PUT drop
   dst size >str ;

\ The name, the last component of a path below parent.
: NAME-OF ( str str -- str )
   {: path:str parent:str :}
   path str> nip {: u:n :}
   parent str> nip {: pu:n :}
   pu 0= if path exit then
   path pu 1+ u PART ;

\ Pushes the path of the entry, a name in parent, laid in ar, onto v.
: LIST-ONE ( str u8 str ^ARENA:arena ^VEC:vector<str> -- )
   {: name:str type:u8 parent:str ar:^ARENA:arena v :}
   parent name ar JOIN v VEC:PUSH ! ;

: LISTED ( fd str ^ARENA:arena ^VEC:vector<str> -- )
   {: dir:fd parent:str ar:^ARENA:arena v :}
   dir [: parent ar v LIST-ONE ;] FS-LIST:EACH-TYPED-AT ;

: LIST-FAILURE ( n str str str -- )
   {: code:n open:str read:str p:str :}
   code FS-LIST:E-OPEN = if open p IO-FAILURE then
   code E-FS-LIST-LAST >= code E-FS-LIST-FIRST <= and if
      read p IO-FAILURE
   then
   code throw ;

\ The paths of the entries in dir, but . and .., in the order listed; a
\ failed listing is an io failure named by the open or the read text.
: LIST-PATHS ( fd str str str ^ARENA:arena -- ^VEC:vector<str> )
   {: dir:fd parent:str open:str read:str ar:^ARENA:arena :}
   ar [type] str NEW-VEC {: v :}
   0 FS:CAUSE!
   [: dir parent ar v LISTED ;] catch {: code:n :}
   code 0<> if code open read parent LIST-FAILURE then
   v ;

\ FILE-FINGERPRINT of the walk's stat as a step; after a throw
\ ENTRY-CODE? names, NO-FINGERPRINT and the code.
: PRINT-STEP ( MODEL:stat str -- MODEL:fingerprint n )
   {: st:MODEL:stat path:str :}
   NO-FINGERPRINT [: DROP-FINGERPRINT st path FILE-FINGERPRINT ;]
   catch {: code:n :}
   code 0<> if drop NO-FINGERPRINT then code STEP-CODE ;

\ A reserved artifact is seen unsupported; any other file merges with
\ the stored rows, or answers the code its step threw.
: SCAN-REGULAR
   ( JOURNAL:scan str str MODEL:stat option<MODEL:cutoff>
     -- JOURNAL:scan n )
   {: name:str path:str st:MODEL:stat cut:option<MODEL:cutoff> :}
   name RESERVED-ARTIFACT? if
      path MODEL-UNKNOWN--REASON:UNSUPPORTED SEEN-UNKNOWN 0 exit
   then
   st path PRINT-STEP {: print:MODEL:fingerprint code:n :}
   code 0<> if code exit then
   path print cut JOURNAL:SCAN-FILE 0 ;

: HELD-RELEASED ( fd ^ARENA:arena -- )
   {: f:fd ar:^ARENA:arena :}
   f DISCARD ar ARENA:RELEASE ;

\ Releases the last directory held.
: TOP-RELEASED ( ^VEC:vector<held-dir> -- )
   {: v :}
   v VEC:COUNT 1- {: k:n :}
   v k VEC:AT @ HELD-DIR-UNMAKE {: f:fd p:str names ar:^ARENA:arena :}
   v k VEC:RESIZE
   f ar HELD-RELEASED ;

\ Releases every directory still held.
: ALL-RELEASED ( ^VEC:vector<held-dir> -- )
   {: v :}
   begin v VEC:COUNT 0 > while v TOP-RELEASED repeat ;

\ The open directory's paths, listed into ar; its stat after the listing
\ must be before, the one taken before it.
: LISTED-STILL ( fd str MODEL:stat ^ARENA:arena -- ^VEC:vector<str> )
   {: child:fd p:str before:MODEL:stat ar:^ARENA:arena :}
   child p s" open directory stream" s" read directory" ar LIST-PATHS
   child p s" inspect directory after scan" STAT-FD
   before SAME-OBSERVATION 0= if s" scan directory" p CHANGED then ;

\ The open directory, checked to be the one the walk's stat found, then
\ its LISTED-STILL.
: CHECKED-LISTING ( fd str MODEL:stat ^ARENA:arena -- ^VEC:vector<str> )
   {: child:fd p:str probe:MODEL:stat ar:^ARENA:arena :}
   child p s" inspect directory before scan" STAT-FD
   {: before:MODEL:stat :}
   before probe SAME-INODE 0= if s" open scanned directory" p CHANGED then
   child p before ar LISTED-STILL ;

\ The directory at name, opened from dir where the walk's stat found it,
\ and its CHECKED-LISTING; a throw closes it.
: OPENED-LISTING
   ( fd str str MODEL:stat ^ARENA:arena -- fd ^VEC:vector<str> )
   {: dir:fd name:str p:str probe:MODEL:stat ar:^ARENA:arena :}
   dir name p OPEN-DIRECTORY-AT {: child:fd :}
   ar [type] str NEW-VEC child
   [: drop child p probe ar CHECKED-LISTING ;] CLOSING
   child swap ;

\ OPENED-LISTING and 0; after any throw, -1, an empty vector in ar and
\ the code. The caller, which owns ar, releases it once the vector is
\ dropped, then STEP-CODE decides the code.
: LISTING-STEP
   ( fd str str MODEL:stat ^ARENA:arena -- fd ^VEC:vector<str> n )
   {: dir:fd name:str p:str probe:MODEL:stat ar:^ARENA:arena :}
   -1 >FD ar [type] str NEW-VEC
   [: 2drop dir name p probe ar OPENED-LISTING ;] catch {: code:n :}
   code 0<> if 2drop -1 >FD ar [type] str NEW-VEC then
   code ;

\ SCAN-NAMES, which the walk reaches again below a directory.
defer SCAN-SUBTREE
   ( JOURNAL:scan fd str ^VEC:vector<str> scan-context ^ARENA:arena
     -- JOURNAL:scan )

\ Whether p sorts after every path beneath t: anywhere but at t followed
\ by a byte below "/".
: PAST-SUBTREE? ( str str -- bool )
   {: p:str t:str :}
   p str> {: pa:^u8 pu:n :}
   t str> nip {: tu:n :}
   pu tu <= if true exit then
   pa tu >str t STR:= 0= if true exit then
   pa tu + c@ SLASH > ;

\ Whether the last held directory's subtree comes before p.
: TOP-DUE? ( str ^VEC:vector<held-dir> -- bool )
   {: p:str v :}
   v VEC:COUNT 0= if false exit then
   v v VEC:COUNT 1- VEC:AT @ HELD-DIR-UNMAKE
   {: f:fd t:str names ar:^ARENA:arena :}
   p t PAST-SUBTREE? ;

\ The last held directory's subtree, then its descriptor and arena.
: DESCEND-TOP
   ( JOURNAL:scan ^VEC:vector<held-dir> scan-context -- JOURNAL:scan )
   {: v cx:scan-context :}
   v VEC:COUNT 1- {: k:n :}
   v k VEC:AT @ HELD-DIR-UNMAKE
   {: child:fd p:str names ar:^ARENA:arena :}
   v k VEC:RESIZE
   [: child p names cx ar SCAN-SUBTREE ;]
   [: child ar HELD-RELEASED ;] finally ;

\ Each held subtree p does not sort below.
: ENTERED-DUE
   ( JOURNAL:scan str ^VEC:vector<held-dir> scan-context
     -- JOURNAL:scan )
   {: p:str v cx:scan-context :}
   begin p v TOP-DUE? while v cx DESCEND-TOP repeat ;

: ENTERED-ALL
   ( JOURNAL:scan ^VEC:vector<held-dir> scan-context -- JOURNAL:scan )
   {: v cx:scan-context :}
   begin v VEC:COUNT 0 > while v cx DESCEND-TOP repeat ;

\ A directory: listed where the walk's stat found it, held, then seen at
\ its name; its subtree waits in held for SCAN-NAMES. A failed listing
\ releases its arena, then answers the step's code.
: SCAN-SUBDIRECTORY
   ( JOURNAL:scan fd str str MODEL:stat ^VEC:vector<held-dir>
     -- JOURNAL:scan n )
   {: dir:fd name:str path:str probe:MODEL:stat held :}
   ARENA:NEW {: ar:^ARENA:arena :}
   dir name path probe ar LISTING-STEP {: child:fd names code:n :}
   code 0<> if
      child names 2drop ar ARENA:RELEASE code STEP-CODE exit
   then
   child path names ar HELD-DIR-MAKE held VEC:PUSH !
   path MODEL:>PATH DIRECTORY-OBSERVATION MODEL-LOCAL--RECORD:MAKE
   JOURNAL:SCAN-SEEN 0 ;

\ The entry by the walk's stat. One on another volume is seen as a
\ symlink is, never synchronized, with nothing beneath it observed.
: SCAN-PROBED
   ( JOURNAL:scan MODEL:stat fd str str scan-context
     ^VEC:vector<held-dir> -- JOURNAL:scan n )
   {: st:MODEL:stat dir:fd name:str path:str cx:scan-context held :}
   cx SCAN-CONTEXT-UNMAKE {: cut:option<MODEL:cutoff> dev:n :}
   st STAT-DEV dev <> if
      path MODEL-UNKNOWN--REASON:UNSUPPORTED SEEN-UNKNOWN 0 exit
   then
   st REGULAR? if name path st cut SCAN-REGULAR exit then
   st DIRECTORY? if dir name path st held SCAN-SUBDIRECTORY exit then
   path UNSUPPORTED-STEP ;

\ Rust's scan_entry: one no-follow stat of name, then 0 or the code
\ that says why it cannot be observed, which SCAN-NAME publishes.
: SCAN-ENTRY
   ( JOURNAL:scan fd str str scan-context ^VEC:vector<held-dir>
     -- JOURNAL:scan n )
   {: dir:fd name:str path:str cx:scan-context held :}
   dir name FS:TRY-STAT-AT 0= if
      s" inspect directory entry" path IO-STEP exit
   then
   BUF-STAT dir name path cx held SCAN-PROBED ;

\ Rust's entry_unknown and io_unknown_reason: the reason code, thrown
\ while one entry was observed, publishes; wrong is what an object that is
\ not a regular file means to the caller. Any code ENTRY-CODE? does not
\ name is the scan's, rethrown.
: ENTRY-UNKNOWN ( n MODEL:unknown-reason -- MODEL:unknown-reason )
   {: code:n wrong:MODEL:unknown-reason :}
   code FS:ERRNO ENTRY-CODE? 0= if code throw then
   code E-UNSUPPORTED = if wrong exit then
   code E-CHANGED = if MODEL-UNKNOWN--REASON:INCOMPLETE exit then
   code E-UNREADABLE = if MODEL-UNKNOWN--REASON:INACCESSIBLE exit then
   FS:ERRNO REPLACED? if MODEL-UNKNOWN--REASON:INCOMPLETE exit then
   MODEL-UNKNOWN--REASON:INACCESSIBLE ;

\ Rust's walk_unknown: an entry the walk meets.
: WALK-UNKNOWN ( n -- MODEL:unknown-reason )
   MODEL-UNKNOWN--REASON:UNSUPPORTED ENTRY-UNKNOWN ;

\ Rust's revisited_unknown: an object whose type the walk recorded, so a
\ different one now is a replacement.
: REVISITED-UNKNOWN ( n -- MODEL:unknown-reason )
   MODEL-UNKNOWN--REASON:INCOMPLETE ENTRY-UNKNOWN ;

\ One entry never fails the pass: it is seen as unknown, and a directory
\ that is, changed while it was listed among them, is not entered. LOCAL
\ logs no failure ENTRY-CODE? names while the entry is walked.
: SCAN-NAME
   ( JOURNAL:scan fd str str scan-context ^VEC:vector<held-dir>
     -- JOURNAL:scan )
   {: dir:fd path:str parent:str cx:scan-context held :}
   path parent NAME-OF {: name:str :}
   name MODEL:EXCLUDED-NAME? if exit then
   [: dir name path cx held SCAN-ENTRY ;] ['] ENTRY-CODE? WITH-CONVERTS
   {: code:n :}
   code 0= if exit then
   path code WALK-UNKNOWN SEEN-UNKNOWN ;

\ Each held subtree p does not sort below, then p.
: SCAN-STEP
   ( JOURNAL:scan fd str str scan-context ^VEC:vector<held-dir>
     -- JOURNAL:scan )
   {: dir:fd p:str parent:str cx:scan-context held :}
   p held cx ENTERED-DUE
   dir p parent cx held SCAN-NAME ;

\ The names in byte order, each held directory's subtree before the
\ first later name that does not sort below it, so every path reaches
\ JOURNAL in path byte order.
: NAMES-WALKED
   ( JOURNAL:scan fd str ^VEC:vector<str> scan-context ^ARENA:arena
     ^VEC:vector<held-dir> -- JOURNAL:scan )
   {: dir:fd path:str names cx:scan-context ar:^ARENA:arena held :}
   names VEC:COUNT [: names swap VEC:AT STR@ path NAME-OF ;] ar ORDER
   {: idx :}
   idx VEC:COUNT 0 ?do
      dir names idx i VEC:AT @ VEC:AT @ path cx held SCAN-STEP
   loop
   held cx ENTERED-ALL ;

\ NAMES-WALKED of a directory's names, which live in ar with their
\ order; a throw releases every directory still held.
: SCAN-NAMES
   ( JOURNAL:scan fd str ^VEC:vector<str> scan-context ^ARENA:arena
     -- JOURNAL:scan )
   {: dir:fd path:str names cx:scan-context ar:^ARENA:arena :}
   ar [type] held-dir NEW-VEC {: held :}
   [: dir path names cx ar held NAMES-WALKED ;]
   [: held ALL-RELEASED ;] finally ;

: SUBTREE-INSTALL ( -- ) [: SCAN-NAMES ;] is SCAN-SUBTREE ;
SUBTREE-INSTALL

\ ---- the hash stage

: NO-SCANNED-HASH ( -- scanned-hash )
   s" " MODEL:>PATH NO-FINGERPRINT NO-HASH MODEL-HASH--RECORD:MAKE
   false SCANNED-HASH-MAKE ;

: DROP-SCANNED-HASH ( scanned-hash -- ) drop ;

\ The open file's hash, which must match the fingerprint the walk took.
: HASH-OPENED-FILE
   ( fd str MODEL:fingerprint MODEL:stat [ -- option<MODEL:cutoff> ]
     ^ARENA:arena -- scanned-hash )
   {: f:fd path:str want:MODEL:fingerprint opened:MODEL:stat q
      ar:^ARENA:arena :}
   opened path FILE-FINGERPRINT want SAME-FINGERPRINT? 0= if
      s" open enumerated scan file" path CHANGED
   then
   f path s" hash local scan file" opened ar E-UNSUPPORTED E-CHANGED
   HASH-STABLE-FILE-FROM-STAT
   {: c:DROPBOX:hash print:MODEL:fingerprint :}
   print want SAME-FINGERPRINT? 0= if
      s" hash enumerated scan file" path CHANGED
   then
   path MODEL:>PATH print c MODEL-HASH--RECORD:MAKE
   {: r:MODEL:hash-record :}
   r r q execute HASH-IS-REUSABLE SCANNED-HASH-MAKE ;

: HASH-SCAN-FILE
   ( fd str MODEL:fingerprint [ -- option<MODEL:cutoff> ] ^ARENA:arena
     -- scanned-hash )
   {: root:fd path:str want:MODEL:fingerprint q ar:^ARENA:arena :}
   root path s" open enumerated scan file" E-IO E-UNSUPPORTED
   OPEN-RELATIVE-REGULAR-WITH-STAT {: f:fd opened:MODEL:stat :}
   [: f path want opened q ar HASH-OPENED-FILE ;] [: f DISCARD ;] finally ;

\ HASH-SCAN-FILE under ENTRY-CODE?; after a throw, NO-SCANNED-HASH and the
\ code.
: HASH-STEP
   ( fd str MODEL:fingerprint [ -- option<MODEL:cutoff> ] ^ARENA:arena
     -- scanned-hash n )
   {: root:fd path:str want:MODEL:fingerprint q ar:^ARENA:arena :}
   NO-SCANNED-HASH [: DROP-SCANNED-HASH
      [: root path want q ar HASH-SCAN-FILE ;] ['] ENTRY-CODE? WITH-CONVERTS
   ;] catch {: code:n :}
   code 0<> if drop NO-SCANNED-HASH then code ;

\ The hash's file publishes present.
: OBSERVE-PRESENT ( JOURNAL:scan MODEL:hash-record -- JOURNAL:scan )
   MODEL-HASH--RECORD:UNMAKE
   {: p:MODEL:path f:MODEL:fingerprint c:DROPBOX:hash :}
   p c MODEL-LOCAL:MAKE PRESENT-OBSERVATION MODEL-LOCAL--RECORD:MAKE
   JOURNAL:SCAN-OBSERVE ;

\ A confirmed hash publishes present, and its record when reusable.
: PUBLISH-HASH ( JOURNAL:scan scanned-hash -- JOURNAL:scan )
   SCANNED-HASH-UNMAKE {: r:MODEL:hash-record ok:bool :}
   r OBSERVE-PRESENT
   ok if r JOURNAL:SCAN-HASH then ;

\ Every failure here concerns the job's own path.
: HASH-JOB
   ( JOURNAL:scan str MODEL:fingerprint fd [ -- option<MODEL:cutoff> ]
     ^ARENA:arena -- JOURNAL:scan )
   {: path:str want:MODEL:fingerprint root:fd q ar:^ARENA:arena :}
   root path want q ar HASH-STEP {: h:scanned-hash code:n :}
   code 0= if h PUBLISH-HASH exit then
   path code REVISITED-UNKNOWN UNKNOWN ;

\ Rust's hash_scan_files, one job at a time, each hashed in ar.
: HASH-JOBS
   ( JOURNAL:scan ^ARENA:arena fd [ -- option<MODEL:cutoff> ]
     -- JOURNAL:scan )
   {: ar:^ARENA:arena root:fd q :}
   [: ar ARENA:RESET root q ar HASH-JOB ;] JOURNAL:EACH-SCAN-JOB ;

\ ---- finishing

\ The configured path must still name the root the scan opened.
: VERIFY-ROOT ( str MODEL:stat -- )
   {: root:str before:MODEL:stat :}
   root s" reopen sync root after scan" OPEN-ABSOLUTE-DIRECTORY {: f:fd :}
   [: f root s" verify sync root binding after scan" STAT-FD ;]
   [: f DISCARD ;] finally
   before SAME-INODE
   0= if s" verify complete local scan root" root CHANGED then ;

\ Rust's finish_scan_at: hashes the files the walk staged, in path byte
\ order, then checks the root.
: FINISH
   ( JOURNAL:scan str fd MODEL:stat [ -- option<MODEL:cutoff> ]
     -- JOURNAL:scan )
   {: root:str rfd:fd before:MODEL:stat q :}
   [: rfd q HASH-JOBS ;] ARENA:WITH
   root before VERIFY-ROOT ;

\ FINISH, then the root's binding, read from its descriptor while that is
\ open: none where JOURNAL finds a stand-in there. It closes the pending
\ scan's root.
: FINISH-BOUND-SCAN-AT
   ( JOURNAL:scan pending-scan [ -- option<MODEL:cutoff> ] JOURNAL:journal
     -- JOURNAL:scan option<JOURNAL:local-root-binding> )
   {: ps:pending-scan q j :}
   ps PENDING-SCAN-UNMAKE
   {: root:str rfd:fd before:MODEL:stat ar:^ARENA:arena :}
   [: root rfd before q FINISH root rfd j ar JOURNAL:INSPECT-ROOT-AT ;]
   [: rfd DISCARD ;] finally ;

\ ---- enumerating

\ The root, listed in ar, and its names walked.
: ROOT-LISTED
   ( JOURNAL:scan ^ARENA:arena fd MODEL:stat scan-context
     -- JOURNAL:scan )
   {: ar:^ARENA:arena rfd:fd before:MODEL:stat cx:scan-context :}
   rfd s" " before ar CHECKED-LISTING {: names :}
   rfd s" " names cx ar SCAN-NAMES ;

\ The walk from the root, every path in byte order.
: WALK-ROOT
   ( JOURNAL:scan fd MODEL:stat option<MODEL:cutoff> n -- JOURNAL:scan )
   {: rfd:fd before:MODEL:stat cut:option<MODEL:cutoff> dev:n :}
   cut dev SCAN-CONTEXT-MAKE {: cx:scan-context :}
   [: rfd before cx ROOT-LISTED ;] ARENA:WITH ;

\ Rust's enumerate_scan_on_device: every entry on device into the scan;
\ any other device is an unsupported subtree. A failure of the root's own
\ throws and closes the root.
: ENUMERATE-SCAN-ON-DEVICE
   ( JOURNAL:scan str fd MODEL:stat option<MODEL:cutoff> n ^ARENA:arena
     -- JOURNAL:scan pending-scan )
   {: root:str rfd:fd before:MODEL:stat cut:option<MODEL:cutoff> dev:n
      ar:^ARENA:arena :}
   rfd [: rfd before cut dev WALK-ROOT ;] CLOSING
   root rfd before ar PENDING-SCAN-MAKE ;

: ROOT-STAT ( fd str -- MODEL:stat )
   {: rfd:fd p:str :}
   NO-STAT rfd
   [: DROP-STAT rfd p s" inspect sync root before scan" STAT-FD ;]
   CLOSING ;

: ENUMERATE-SCAN
   ( JOURNAL:scan str option<MODEL:cutoff> ^ARENA:arena
     -- JOURNAL:scan pending-scan )
   {: p:str cut:option<MODEL:cutoff> ar:^ARENA:arena :}
   p ar KEEP {: root:str :}
   p s" open sync root for scan" OPEN-ABSOLUTE-DIRECTORY {: rfd:fd :}
   rfd p ROOT-STAT {: before:MODEL:stat :}
   root rfd before cut before STAT-DEV ar ENUMERATE-SCAN-ON-DEVICE ;

\ ---- publishing

: ROOT-CHANGED ( -- scan-publication )
   LOCAL-SCAN--PUBLICATION:ROOT-CHANGED ;

: ACTIVE-BINDING?
   ( fd str JOURNAL:journal ^ARENA:arena -- bool )
   {: dir:fd p:str j ar:^ARENA:arena :}
   p dir j ar JOURNAL:INSPECT-ROOT-AT MATCH option
      none OF false ENDOF
      some OF j ar JOURNAL:ACTIVE-ROOT? ENDOF
   ;MATCH ;

public

\ The directory at p while it is the journal's active root; none, the
\ directory closed, where p names another.
: OPEN-ACTIVE-ROOT ( JOURNAL:journal str -- option<fd> )
   {: j p:str :}
   p s" open sync root for identity verification"
   OPEN-ABSOLUTE-DIRECTORY {: dir:fd :}
   false dir
   [: drop dir p j [: ACTIVE-BINDING? ;] ARENA:WITH ;] CLOSING
   if dir OPTION:SOME exit then
   dir DISCARD OPTION:NONE ;

: CONFIGURED-ROOT-IS-ACTIVE? ( JOURNAL:journal str -- bool )
   OPEN-ACTIVE-ROOT MATCH option
      none OF false ENDOF
      some OF DISCARD true ENDOF
   ;MATCH ;

private

\ Rust's order: the scanned root, then the configured path, must be the
\ active root, which the publication checks again as it writes.
: PUBLISH-BOUND
   ( JOURNAL:scan JOURNAL:local-root-binding JOURNAL:journal str
     ^ARENA:arena -- JOURNAL:scan scan-publication )
   {: b j p:str ar:^ARENA:arena :}
   b j ar JOURNAL:ACTIVE-ROOT? 0= if ROOT-CHANGED exit then
   j p CONFIGURED-ROOT-IS-ACTIVE? 0= if ROOT-CHANGED exit then
   b JOURNAL:PUBLISH-SCAN 0= if ROOT-CHANGED exit then
   LOCAL-SCAN--PUBLICATION:PUBLISHED ;

: SCAN-PUBLISHED
   ( JOURNAL:scan JOURNAL:journal str option<MODEL:cutoff>
     [ -- option<MODEL:cutoff> ] ^ARENA:arena
     -- scan-publication JOURNAL:scan )
   {: j p:str cut:option<MODEL:cutoff> q ar:^ARENA:arena :}
   p cut ar ENUMERATE-SCAN q j FINISH-BOUND-SCAN-AT
   MATCH option
      none OF ROOT-CHANGED ENDOF
      some OF j p ar PUBLISH-BOUND ENDOF
   ;MATCH swap ;

\ The complete root through no-follow, descriptor-relative stats and
\ directory opens, scanned into the journal's scan words and published.
\ An inaccessible, changing, symlinked or special entry publishes as
\ unknown with nothing beneath it, so a partial walk never passes for
\ confirmed absence; only the root's own failures fail the scan. cut
\ decides which cached hashes the walk reuses, q which hashes it computes
\ stay reusable.
: SCAN-AND-PUBLISH-AT
   ( JOURNAL:journal str option<MODEL:cutoff> [ -- option<MODEL:cutoff> ]
     ^ARENA:arena -- scan-publication )
   {: j p:str cut:option<MODEL:cutoff> q ar:^ARENA:arena :}
   j [: j p cut q ar SCAN-PUBLISHED ;] JOURNAL:WITH-SCAN ;

public

\ p scanned with the journal's hash cache and published to it, in ar.
: SCAN-AND-PUBLISH
   ( JOURNAL:journal str ^ARENA:arena -- scan-publication )
   {: j p:str ar:^ARENA:arena :}
   j p CURRENT-HASH-CACHE-CUTOFF [: CURRENT-HASH-CACHE-CUTOFF ;] ar
   SCAN-AND-PUBLISH-AT ;

private

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

: DUPLICATE-ROOT ( fd str -- fd )
   {: root:fd p:str :}
   -1 >FD [: drop root FD:DUPLICATE ;]
   [: s" duplicate sync root descriptor" p IO-FAILURE ;] FS-FAILS ;

\ Makes the directory p names in dir and syncs dir's entry; one that
\ exists by now is used as it is.
: MAKE-PARENT ( fd str str -- )
   {: dir:fd name:str p:str :}
   dir name FS:MODE-PRIVATE-DIR FS:TRY-MAKE-DIR-AT if
      dir p s" sync newly created parent directory entry"
      SYNC-DIRECTORY exit
   then
   FS:ERRNO FS:EEXIST = if exit then
   dir name s" create download parent directory" p IO-FAILURE-AT ;

\ The directory made and opened, then synced; a throw closes it.
: MADE-DIRECTORY ( fd str str -- fd )
   {: dir:fd name:str p:str :}
   dir name p MAKE-PARENT
   dir name p OPEN-DIRECTORY-AT {: next:fd :}
   next [: next p s" sync newly created directory" SYNC-DIRECTORY ;]
   CLOSING next ;

\ After an open in dir failed: none for a missing name without create,
\ else the directory made.
: MISSING-DIRECTORY ( fd str str bool -- option<fd> )
   {: dir:fd name:str p:str create:bool :}
   FS:ERRNO FS:ENOENT <> if
      dir name s" open root-confined directory" p IO-FAILURE-AT
   then
   create 0= if OPTION:NONE exit then
   dir name p MADE-DIRECTORY OPTION:SOME ;

: OPEN-COMPONENT ( fd str str bool -- option<fd> )
   {: dir:fd name:str p:str create:bool :}
   dir name FS:TRY-OPEN-DIR-AT MATCH option
      none OF dir name p create MISSING-DIRECTORY ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH ;

\ Opens each component of p from at on in the directory before
\ it, dir first; each closes once the next opens or a throw passes.
: DESCEND-PARENTS ( fd str n bool -- option<fd> )
   {: dir:fd p:str at:n create:bool :}
   p at NEXT-COMPONENT {: from:n to:n found:bool :}
   found 0= if dir OPTION:SOME exit then
   OPTION:NONE dir
   [: DROP-DIR dir p from to PART p 0 to PART create OPEN-COMPONENT ;]
   CLOSING dir DISCARD
   MATCH option
      none OF OPTION:NONE ENDOF
      some OF p to create RECURSE ENDOF
   ;MATCH ;

\ Rust's open_parent: the parent of p's last component below the root,
\ none when a directory on the way is missing; create makes those
\ directories, each synced with its entry.
: OPEN-PARENT ( fd str bool -- option<parent-dir> )
   {: root:fd p:str create:bool :}
   p SAFE-COMPONENTS drop
   p SPLIT-LAST {: parent:n from:n to:n :}
   root p DUPLICATE-ROOT p 0 parent PART 0 create DESCEND-PARENTS
   MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: f:fd :}
         f p from to PART p 0 parent PART PARENT-DIR-MAKE
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
: DOWNLOAD-STAGE-XATTR ( -- str ) s" user.omabox.download-stage-v1" ;
96 constant MARKER-CAP
MARKER-CAP BUFFER: MARKER-BUF
\ S_IRUSR: a verified stage's only permission.
$100 constant MODE-READ-ONLY

\ The marker an owned download stage of target's content carries.
: STAGE-MARKER ( str DROPBOX:hash ^ARENA:arena -- str )
   {: t:str c:DROPBOX:hash ar:^ARENA:arena :}
   s" download-marker-v1" t c ar INTERNAL-NAME ;

: SAME-CONTENT? ( DROPBOX:hash DROPBOX:hash -- bool )
   {: a:DROPBOX:hash b:DROPBOX:hash :}
   a DROPBOX:HASH>STR b DROPBOX:HASH>STR STR:= ;

: READ-ONLY ( fd str str -- )
   {: f:fd p:str o:str :}
   [: f MODE-READ-ONLY FD:MODE! ;] [: o p IO-FAILURE ;] FS-FAILS ;

\ ---- xattrs

\ create refuses an attribute that exists, as XATTR_CREATE does.
: SET-XATTR ( fd str str bool str str -- )
   {: f:fd name:str v:str create:bool p:str o:str :}
   [: create if f name v XATTR:ADD exit then
      f name v XATTR:SET ;]
   [: o p IO-FAILURE ;] FS-FAILS ;

\ An absent attribute is already removed.
: REMOVE-XATTR ( fd str str str -- )
   {: f:fd name:str p:str o:str :}
   [: f name XATTR:ERASE ;] [: o p IO-FAILURE ;] FS-FAILS ;

: MARKER-GOT ( XATTR:got str -- download-marker )
   {: g:XATTR:got want:str :}
   g MATCH XATTR:got
      absent OF DOWNLOAD-MARKER-MISSING ENDOF
      value OF {: k:n :}
         MARKER-BUF k >str want STR:= if DOWNLOAD-MARKER-EXPECTED
         else DOWNLOAD-MARKER-OTHER then
      ENDOF
      oversize OF DOWNLOAD-MARKER-OTHER ENDOF
   ;MATCH ;

\ The stage marker on the file, compared with want's bytes.
: READ-DOWNLOAD-MARKER ( fd str str -- download-marker )
   {: f:fd want:str p:str :}
   DOWNLOAD-MARKER-MISSING
   [: DROP-MARKER f DOWNLOAD-STAGE-XATTR MARKER-BUF MARKER-CAP SPAN:MAKE
      XATTR:GET want MARKER-GOT ;]
   [: s" verify download stage marker" p IO-FAILURE ;] FS-FAILS ;

: EXPECTED? ( download-marker -- bool )
   MATCH download-marker
      missing OF false ENDOF
      expected OF true ENDOF
      other OF false ENDOF
   ;MATCH ;

\ ---- staging

\ Fills the span from read; a file failure there is a stage read's.
: STAGE-READ-INTO ( ^u8 n [ ^u8 n -- n ] str str -- n )
   {: dst:^ cap:n read p:str o:str :}
   0 [: drop dst cap read execute ;] [: o p STAGE-READ ;] FS-FAILS ;

: WRITE-PRIVATE ( fd str str -- )
   {: w:fd b:str p:str :}
   [: w b FD:WRITE-FULL ;]
   [: s" write private stage" p IO-FAILURE ;] FS-FAILS ;

\ Reads into the span, writes what came to w and answers its count.
: COPY-CHUNK ( ^u8 n [ ^u8 n -- n ] fd str str -- n )
   {: dst:^ cap:n read w:fd p:str o:str :}
   dst cap read p o STAGE-READ-INTO {: k:n :}
   k 0 > if w dst k >str p WRITE-PRIVATE then
   k ;

\ Copies what read gives to w; answers its Dropbox content hash.
: COPY-AND-HASH
   ( [ ^u8 n -- n ] fd str str ^ARENA:arena -- DROPBOX:hash )
   {: read w:fd p:str o:str ar:^ARENA:arena :}
   [: read w p o COPY-CHUNK ;] ar HASH-STREAM ;

: MAP-STAGE-WRITE ( stage-write [ -- a ] -- stage-outcome<a> )
   {: w:stage-write stage :}
   w MATCH stage-write
      created OF stage execute LOCAL-STAGE--OUTCOME:STAGED ENDOF
      reused OF stage execute LOCAL-STAGE--OUTCOME:ALREADY-STAGED ENDOF
      mismatch OF LOCAL-STAGE--OUTCOME:CONTENT-CHANGED ENDOF
      destination-occupied OF LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED
      ENDOF
   ;MATCH ;

\ Whether the file carries marker, true when there is none to carry.
: MARKED? ( fd option<str> str -- bool )
   {: f:fd marker:option<str> p:str :}
   marker MATCH option
      none OF true ENDOF
      some OF {: m:str :} f m p READ-DOWNLOAD-MARKER EXPECTED?
      ENDOF
   ;MATCH ;

\ Syncs the file and its entry when it holds want and carries the marker.
: REUSE-VERIFIED-STAGE
   ( fd DROPBOX:hash DROPBOX:hash option<str> fd str -- bool )
   {: f:fd actual:DROPBOX:hash want:DROPBOX:hash marker:option<str>
      dir:fd p:str :}
   actual want SAME-CONTENT? 0= if false exit then
   f marker p MARKED? 0= if false exit then
   f p s" sync verified stage" SYNC-FILE
   dir p s" sync verified stage entry" SYNC-DIRECTORY
   true ;

\ An entry at the stage's name is reused or kept; it closes the file.
: EXISTING-STAGE
   ( hashed DROPBOX:hash option<str> fd str -- stage-write )
   {: h:hashed want:DROPBOX:hash marker:option<str> dir:fd p:str :}
   h HASHED-UNMAKE {: f:fd actual:DROPBOX:hash print:MODEL:fingerprint :}
   false f
   [: drop f actual want marker dir p REUSE-VERIFIED-STAGE ;] CLOSING
   f DISCARD
   if STAGE-WRITE-REUSED exit then
   p STAGE-WRITE-DESTINATION-OCCUPIED ;

: MARK-STAGE ( fd option<str> str -- )
   {: f:fd marker:option<str> p:str :}
   marker MATCH option
      none OF ENDOF
      some OF {: m:str :}
         f DOWNLOAD-STAGE-XATTR m true p
         s" mark owned download stage" SET-XATTR
      ENDOF
   ;MATCH ;

\ Names the file in dir; another entry already there is reused or kept.
: LINK-STAGE
   ( fd fd str str DROPBOX:hash option<str> str ^ARENA:arena
     -- stage-write )
   {: f:fd dir:fd name:str p:str want:DROPBOX:hash
      marker:option<str> o:str ar:^ARENA:arena :}
   f dir name FS:TRY-LINK-AT if
      dir p s" sync staged file entry" SYNC-DIRECTORY
      STAGE-WRITE-CREATED exit
   then
   FS:ERRNO FS:EEXIST <> if
      dir name s" install verified private stage" p
      IO-FAILURE-AT
   then
   dir name p s" verify raced stage" ar OPEN-AND-HASH-IF-PRESENT
   MATCH option
      none OF o p CHANGED ENDOF
      some OF want marker dir p EXISTING-STAGE ENDOF
   ;MATCH ;

\ Copies read's bytes into the unnamed file f and names it when they hash
\ to want, marked, read-only and synced.
: FILL-STAGE
   ( fd fd str str DROPBOX:hash [ ^u8 n -- n ] option<str> str
     ^ARENA:arena -- stage-write )
   {: f:fd dir:fd name:str p:str want:DROPBOX:hash read
      marker:option<str> o:str ar:^ARENA:arena :}
   read f p o ar COPY-AND-HASH {: actual:DROPBOX:hash :}
   actual want SAME-CONTENT? 0= if actual STAGE-WRITE-MISMATCH exit then
   f marker p MARK-STAGE
   f p s" make staged bytes immutable" READ-ONLY
   f p s" sync verified staged bytes" SYNC-FILE
   f dir name p want marker o ar LINK-STAGE ;

: TEMP-FILE ( fd str -- fd )
   {: dir:fd p:str :}
   -1 >FD [: drop dir FS:TEMP-AT ;]
   [: dir s" " s" create unnamed staging file" p IO-FAILURE-AT ;]
   FS-FAILS ;

: WRITE-NEW-STAGE
   ( fd str str DROPBOX:hash [ ^u8 n -- n ] option<str> str
     ^ARENA:arena -- stage-write )
   {: dir:fd name:str p:str want:DROPBOX:hash read
      marker:option<str> o:str ar:^ARENA:arena :}
   dir p TEMP-FILE {: f:fd :}
   STAGE-WRITE-CREATED f
   [: DROP-STAGE-WRITE
      f dir name p want read marker o ar FILL-STAGE ;]
   CLOSING
   f DISCARD ;

\ Stages read's bytes at the name in dir when they hash to want; an
\ entry already there is reused when it holds want and, given a marker,
\ carries it, and is kept otherwise. o names the operation.
: WRITE-VERIFIED-STAGE
   ( fd str str DROPBOX:hash [ ^u8 n -- n ] option<str> str
     ^ARENA:arena -- stage-write )
   {: dir:fd name:str p:str want:DROPBOX:hash read
      marker:option<str> o:str ar:^ARENA:arena :}
   dir name p o ar OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF dir name p want read marker o ar WRITE-NEW-STAGE
      ENDOF
      some OF want marker dir p EXISTING-STAGE ENDOF
   ;MATCH ;

\ ---- owned download stages

: OWNED? ( fd DROPBOX:hash DROPBOX:hash str str -- bool )
   {: f:fd actual:DROPBOX:hash want:DROPBOX:hash m:str p:str :}
   actual want SAME-CONTENT? 0= if false exit then
   f m p READ-DOWNLOAD-MARKER EXPECTED? ;

\ Makes the hashed file read-only and synced; answers its fingerprint.
: SEAL-STAGE ( fd MODEL:fingerprint str -- MODEL:fingerprint )
   {: f:fd print:MODEL:fingerprint p:str :}
   s" revalidate owned download stage" {: r:str :}
   s" make verified download stage immutable" {: m:str :}
   f p r STAT-FD p FILE-FINGERPRINT
   print SAME-FINGERPRINT? 0= if r p CHANGED then
   f p m READ-ONLY
   f p s" sync immutable download stage" SYNC-FILE
   f p s" inspect immutable download stage" STAT-FD
   p FILE-FINGERPRINT {: after:MODEL:fingerprint :}
   print after SAME-HASHED-CONTENT 0= if m p CHANGED then
   after ;

: INSPECT-HASHED
   ( hashed str str DROPBOX:hash ^ARENA:arena -- download-stage )
   {: h:hashed p:str t:str want:DROPBOX:hash ar:^ARENA:arena :}
   h HASHED-UNMAKE {: f:fd actual:DROPBOX:hash print:MODEL:fingerprint :}
   false f [: drop f actual want t want ar STAGE-MARKER p OWNED? ;]
   CLOSING 0= if
      f DISCARD p DOWNLOAD-STAGE-DESTINATION-OCCUPIED exit
   then
   NO-FINGERPRINT f [: DROP-FINGERPRINT f print p SEAL-STAGE ;] CLOSING
   {: after:MODEL:fingerprint :}
   f after VERIFIED-DOWNLOAD-STAGE-MAKE DOWNLOAD-STAGE-VERIFIED ;

\ The stage at the name in dir for target's content want: none, an owned
\ stage verified and left open, or, kept as it was, another file, an
\ object not a regular file or a file Omabox cannot read. Rust throws for
\ the last two; a Habu throw names no path, so its callers could not tell
\ the stage's name from the target's.
: INSPECT-DOWNLOAD-STAGE
   ( fd str str str DROPBOX:hash ^ARENA:arena -- download-stage )
   {: dir:fd name:str p:str t:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   s" verify owned download stage" {: o:str :}
   dir name p o OPEN-NAMED MATCH name-entry
      absent OF DOWNLOAD-STAGE-MISSING ENDOF
      regular OF p o ar HASH-OPENED
         p t want ar INSPECT-HASHED
      ENDOF
      unsupported OF p DOWNLOAD-STAGE-DESTINATION-OCCUPIED ENDOF
      unreadable OF p DOWNLOAD-STAGE-DESTINATION-OCCUPIED ENDOF
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
   ( fd str str str DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd g:str cn:str t:str c:DROPBOX:hash
      ar:^ARENA:arena :}
   dir cn t s" verify raced conflict destination" ar
   HASH-AT-IF-PRESENT c HOLDS? 0= if
      s" preserve raced local destination" t OCCUPIED
   then
   dir g FS:TRY-REMOVE-FILE-AT 0= if
      dir g s" remove duplicate raced local copy" t IO-FAILURE-AT
   then
   dir t s" sync duplicate raced local cleanup" SYNC-DIRECTORY ;

\ Renames the guard to target's local conflict name for content c.
: PRESERVE-GUARD ( fd str str DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd g:str t:str c:DROPBOX:hash ar:^ARENA:arena :}
   s" preserve raced local destination" {: o:str :}
   t LOCAL-CONFLICT--SIDE:LOCAL c ar CONFLICT-NAME {: cn:str :}
   dir g dir cn FS:TRY-RENAME-NEW-AT if
      dir t s" sync preserved raced local destination" SYNC-DIRECTORY
      exit
   then
   FS:ERRNO FS:EEXIST <> if dir g o t IO-FAILURE-AT then
   dir g cn t c ar DROP-DUPLICATE-GUARD ;

\ Puts the guard back at target_name; when an entry raced in there, keeps
\ the guard's bytes, whose hash is actual, under a local conflict name.
: RESTORE-OR-PRESERVE-CHANGED-GUARD
   ( fd str str str option<DROPBOX:hash> ^ARENA:arena -- )
   {: dir:fd g:str tn:str t:str actual:option<DROPBOX:hash>
      ar:^ARENA:arena :}
   s" restore changed local destination" {: o:str :}
   dir g dir tn FS:TRY-RENAME-NEW-AT if
      dir t o SYNC-DIRECTORY exit
   then
   FS:ERRNO FS:EEXIST <> if dir g o t IO-FAILURE-AT then
   actual MATCH option
      none OF s" preserve raced local destination" t CHANGED ENDOF
      some OF {: c:DROPBOX:hash :} dir g t c ar PRESERVE-GUARD ENDOF
   ;MATCH ;

\ ---- upload stages

: SEEK-START ( fd str str -- )
   {: f:fd p:str o:str :}
   [: f 0 FD:SEEK ;] [: o p IO-FAILURE ;] FS-FAILS ;

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
   ( fd str str DROPBOX:hash ^ARENA:arena -- fd )
   {: dir:fd name:str p:str c:DROPBOX:hash ar:^ARENA:arena :}
   dir name p s" verify immutable upload stage" ar OPEN-AND-HASH-AT
   {: f:fd actual:DROPBOX:hash :}
   actual c SAME-CONTENT? 0= if
      f DISCARD s" open immutable upload stage" p CORRUPT
   then
   f [: f p s" rewind immutable upload stage" SEEK-START ;] CLOSING
   f ;

ARENA STAGED-UPLOADS staged-upload

: NEW-STAGED-UPLOAD
   ( str DROPBOX:hash ^ARENA:arena -- ^staged-upload )
   {: d:str c:DROPBOX:hash ar:^ARENA:arena :}
   ar STAGED-UPLOADS-NEW {: rec:^ :}
   d c STAGED-UPLOAD-MAKE rec !
   rec ;

public

\ Reopens the stage and verifies it: the descriptor an uploader reads.
: OPEN-VERIFIED-UPLOAD ( ^staged-upload ^ARENA:arena -- fd )
   {: rec:^ ar:^ARENA:arena :}
   rec @ STAGED-UPLOAD-UNMAKE {: d:str c:DROPBOX:hash :}
   c DROPBOX:HASH>STR {: name:str :}
   d name ar JOIN {: p:str :}
   d s" open upload staging directory" OPEN-PRIVATE-DIRECTORY
   {: dir:fd :}
   -1 >FD dir [: drop dir name p c ar VERIFY-UPLOAD-STAGE ;] CLOSING
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
   ( fd str str ^ARENA:arena -- option<hashed> bool )
   {: dir:fd name:str p:str ar:^ARENA:arena :}
   NO-HASHED [: DROP-HASHED [: dir name p
         s" verify immutable upload stage" ar OPEN-AND-HASH-IF-PRESENT ;]
      ['] UPLOAD-STAGE-OCCUPIED? WITH-CONVERTS ;] catch {: code:n :}
   code 0= if false exit then
   drop code FS:ERRNO UPLOAD-STAGE-OCCUPIED? if NO-HASHED true exit then
   code throw ;

\ A stage file that does not hold want is disposable: it is removed when
\ the name is still its inode, so each retry rebuilds the stage.
: REMOVE-CORRUPT-STAGE ( fd fd str str -- )
   {: f:fd dir:fd name:str p:str :}
   s" remove corrupt upload stage" {: o:str :}
   f dir name p NAMED-INODE-MATCHES 0= if o p CHANGED then
   dir name FS:TRY-REMOVE-FILE-AT 0= if
      dir name o p IO-FAILURE-AT
   then
   dir p s" sync corrupt upload stage removal" SYNC-DIRECTORY ;

\ Reuses the hashed stage when it holds want, else removes it: true
\ when it was reused. It closes the file.
: SETTLE-UPLOAD-STAGE ( hashed fd str str DROPBOX:hash -- bool )
   {: h:hashed dir:fd name:str p:str want:DROPBOX:hash :}
   h HASHED-UNMAKE {: f:fd actual:DROPBOX:hash print:MODEL:fingerprint :}
   false f [: drop
      f actual want NO-MARKER dir p REUSE-VERIFIED-STAGE dup 0= if
         f dir name p REMOVE-CORRUPT-STAGE
      then ;] CLOSING
   f DISCARD ;

\ WRITE-VERIFIED-STAGE of the source's bytes, true when a throw found the
\ stage path occupied: then destination-occupied. A failed read of the
\ source is an io failure.
: WRITE-UPLOAD-STAGE
   ( fd fd str str DROPBOX:hash ^ARENA:arena -- stage-write bool )
   {: src:fd dir:fd name:str p:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   STAGE-WRITE-CREATED [: DROP-STAGE-WRITE [:
         dir name p want [: src -rot FD-READ ;] NO-MARKER
         s" stage upload" ar WRITE-VERIFIED-STAGE ;]
      ['] UPLOAD-STAGE-OCCUPIED? WITH-CONVERTS ;] catch {: code:n :}
   code 0= if false exit then
   drop code FS:ERRNO UPLOAD-STAGE-OCCUPIED? if
      p STAGE-WRITE-DESTINATION-OCCUPIED true exit
   then
   code LOCAL-CODE throw ;

\ Stages the source's bytes; its stat must not change while they copy,
\ unless the stage path was occupied, answered before the second stat.
: STAGE-SOURCE
   ( fd str fd str str DROPBOX:hash ^ARENA:arena -- stage-write )
   {: src:fd r:str dir:fd name:str p:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   src r s" inspect upload source before staging" STAT-FD
   {: before:MODEL:stat :}
   src dir name p want ar WRITE-UPLOAD-STAGE if exit then
   {: w:stage-write :}
   src r s" inspect upload source after staging" STAT-FD
   before SAME-OBSERVATION 0= if
      s" stage upload" r E-SOURCE-CHANGED CHANGED-FAILS
   then
   w ;

\ Rust's upload_source_changed holds for any failure of this open but an
\ unsafe path: they throw E-SOURCE-CHANGED.
: OPEN-UPLOAD-SOURCE ( fd str -- fd )
   s" open upload source" E-SOURCE-CHANGED E-SOURCE-CHANGED
   OPEN-RELATIVE-REGULAR ;

\ Opens the source below the root and stages its bytes; it closes it.
: STAGE-FROM-SOURCE
   ( fd str fd str str DROPBOX:hash ^ARENA:arena -- stage-write )
   {: root:fd r:str dir:fd name:str p:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   root r OPEN-UPLOAD-SOURCE {: src:fd :}
   STAGE-WRITE-CREATED src [: DROP-STAGE-WRITE
      src r dir name p want ar STAGE-SOURCE ;] CLOSING
   src DISCARD ;

\ The stage in the open staging directory: one already there is reused
\ or replaced, and an occupied path is kept.
: STAGE-UPLOAD-IN
   ( fd str fd str str DROPBOX:hash ^ARENA:arena -- stage-write )
   {: root:fd r:str dir:fd name:str p:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   dir name p ar HASH-UPLOAD-STAGE if
      DROP-HASHED p STAGE-WRITE-DESTINATION-OCCUPIED exit
   then
   MATCH option
      none OF false ENDOF
      some OF dir name p want SETTLE-UPLOAD-STAGE ENDOF
   ;MATCH if STAGE-WRITE-REUSED exit then
   root r dir name p want ar STAGE-FROM-SOURCE ;

: NO-UPLOAD-OUTCOME ( -- stage-outcome<^staged-upload> )
   s" " LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED ;
: DROP-UPLOAD-OUTCOME ( stage-outcome<^staged-upload> -- ) drop ;

public

\ Copies the regular file r below the root into the staging directory s,
\ an absolute path, under want's hash, when it holds want. A source that
\ fails to open or changes while it copies throws E-SOURCE-CHANGED.
: STAGE-UPLOAD-AT
   ( fd str str DROPBOX:hash ^ARENA:arena
     -- stage-outcome<^staged-upload> )
   {: root:fd r:str s:str want:DROPBOX:hash ar:^ARENA:arena :}
   want s" stage upload" REQUIRE-CONTENT-HASH
   want DROPBOX:HASH>STR {: name:str :}
   s name ar JOIN {: p:str :}
   s s" open upload staging directory" OPEN-PRIVATE-DIRECTORY
   {: dir:fd :}
   STAGE-WRITE-CREATED dir [: DROP-STAGE-WRITE
      root r dir name p want ar STAGE-UPLOAD-IN ;] CLOSING
   dir DISCARD
   [: s want ar NEW-STAGED-UPLOAD ;] MAP-STAGE-WRITE ;

\ STAGE-UPLOAD-AT below the sync root at the absolute path.
: STAGE-UPLOAD
   ( str str str DROPBOX:hash ^ARENA:arena
     -- stage-outcome<^staged-upload> )
   {: rp:str r:str s:str want:DROPBOX:hash ar:^ARENA:arena :}
   rp s" open sync root for upload staging" OPEN-ROOT {: root:fd :}
   NO-UPLOAD-OUTCOME root
   [: DROP-UPLOAD-OUTCOME root r s want ar STAGE-UPLOAD-AT ;] CLOSING
   root DISCARD ;

\ The content hash of the regular file r below the root, as it is now; a
\ source that changes while it is read throws E-SOURCE-CHANGED.
: OBSERVE-UPLOAD-SOURCE-AT ( fd str ^ARENA:arena -- DROPBOX:hash )
   {: root:fd r:str ar:^ARENA:arena :}
   root r OPEN-UPLOAD-SOURCE {: src:fd :}
   NO-HASH src [: DROP-HASH src r s" verify upload source" ar
      E-SOURCE-CHANGED E-SOURCE-CHANGED HASH-STABLE-FILE ;] CLOSING
   src DISCARD ;

\ OBSERVE-UPLOAD-SOURCE-AT below the sync root at the absolute path.
: OBSERVE-UPLOAD-SOURCE ( str str ^ARENA:arena -- DROPBOX:hash )
   {: rp:str r:str ar:^ARENA:arena :}
   rp s" open sync root for upload observation" OPEN-ROOT {: root:fd :}
   NO-HASH root [: DROP-HASH root r ar OBSERVE-UPLOAD-SOURCE-AT ;]
   CLOSING
   root DISCARD ;

private

\ ---- upload stage collection

\ Opens the name in dir with open; none when nothing, or a symlink, is
\ there.
: OPEN-UPLOAD-STAGE-CANDIDATE
   ( fd str [ fd str -- option<fd> ] str str -- option<fd> )
   {: dir:fd name:str open p:str o:str :}
   dir name open execute MATCH option
      none OF FS:ERRNO {: e:n :}
         e FS:ENOENT <> e FS:ELOOP <> and if o p IO-FAILURE then
         OPTION:NONE
      ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH ;

\ The stat of the entry the candidate opens, which it closes; none when
\ nothing is there.
: CANDIDATE-STAT ( fd str str str -- option<MODEL:stat> )
   {: dir:fd name:str p:str o:str :}
   dir name [: FS:TRY-OPEN-ENTRY-AT ;] p o
   OPEN-UPLOAD-STAGE-CANDIDATE MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: e:fd :}
         NO-STAT e [: DROP-STAT e p o STAT-FD ;] CLOSING
         e DISCARD OPTION:SOME
      ENDOF
   ;MATCH ;

\ Whether a stage's failure, its code and errno, says it changed or
\ stopped being regular while it was read.
: UNSTABLE? ( n n -- bool )
   {: code:n e:n :}
   code E-CHANGED = code E-UNSUPPORTED = or ;

\ Whether the file hashes to its name; an UNSTABLE? file does not.
: HOLDS-ITS-NAME? ( fd str str ^ARENA:arena -- bool )
   {: f:fd name:str p:str ar:^ARENA:arena :}
   false [: drop [: f p s" verify upload stage for collection" ar
         E-UNSUPPORTED E-CHANGED HASH-STABLE-FILE
         DROPBOX:HASH>STR name STR:= ;]
      ['] UNSTABLE? WITH-CONVERTS ;] catch {: code:n :}
   code 0= if exit then
   drop code FS:ERRNO UNSTABLE? if false exit then
   code throw ;

\ Whether the name is still the opened file's entry, unchanged.
: STILL-NAMED? ( fd fd str str -- bool )
   {: f:fd dir:fd name:str p:str :}
   dir name p s" reinspect upload stage for collection" CANDIDATE-STAT
   MATCH option
      none OF false ENDOF
      some OF {: current:MODEL:stat :}
         f p s" reinspect opened upload stage for collection" STAT-FD
         current SAME-OBSERVATION
      ENDOF
   ;MATCH ;

\ The opened stage file is the entry seen before, holds its name's
\ content, and is still that entry.
: VERIFIED-OPENED? ( fd MODEL:stat fd str str ^ARENA:arena -- bool )
   {: f:fd before:MODEL:stat dir:fd name:str p:str ar:^ARENA:arena :}
   f p s" inspect opened upload stage for collection" STAT-FD
   before SAME-OBSERVATION 0= if false exit then
   f name p ar HOLDS-ITS-NAME? 0= if false exit then
   f dir name p STILL-NAMED? ;

\ Whether the entry at the name is a regular file that holds the content
\ its name claims, and stayed so while it was read.
: VERIFIED-UPLOAD-STAGE-ENTRY? ( fd str str ^ARENA:arena -- bool )
   {: dir:fd name:str p:str ar:^ARENA:arena :}
   dir name p s" inspect upload stage for collection" CANDIDATE-STAT
   MATCH option
      none OF false exit ENDOF
      some OF ENDOF
   ;MATCH {: before:MODEL:stat :}
   before REGULAR? 0= if false exit then
   dir name [: FS:TRY-OPEN-READ-AT ;] p
   s" open upload stage for collection"
   OPEN-UPLOAD-STAGE-CANDIDATE MATCH option
      none OF false ENDOF
      some OF {: f:fd :}
         false f [: drop f before dir name p ar VERIFIED-OPENED? ;]
         CLOSING
         f DISCARD
      ENDOF
   ;MATCH ;

\ Removes the stage at the listed path when it verifies; answers how
\ many it removed.
: COLLECT-UPLOAD-STAGE ( fd str str ^ARENA:arena -- n )
   {: dir:fd name:str p:str ar:^ARENA:arena :}
   dir name p ar VERIFIED-UPLOAD-STAGE-ENTRY? 0= if 0 exit then
   dir name FS:TRY-REMOVE-FILE-AT if 1 exit then
   FS:ERRNO FS:ENOENT <> if
      dir name s" remove unreferenced upload stage" p
      IO-FAILURE-AT
   then 0 ;

\ Collects the path's stage when its name is a content hash retained
\ does not keep; answers how many it removed.
: COLLECT-LISTED-STAGE
   ( fd str str [ DROPBOX:hash -- bool ] ^ARENA:arena -- n )
   {: dir:fd path:str s:str retained ar:^ARENA:arena :}
   path s NAME-OF {: name:str :}
   name DROPBOX:CONTENT-HASH? 0= if 0 exit then
   name DROPBOX:>HASH retained execute if 0 exit then
   dir name path ar COLLECT-UPLOAD-STAGE ;

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
   ( str [ DROPBOX:hash -- bool ] ^ARENA:arena -- n )
   {: s:str retained ar:^ARENA:arena :}
   s s" open upload staging directory for collection"
   OPEN-PRIVATE-DIRECTORY {: dir:fd :}
   0 dir [: drop dir s retained ar COLLECT-UPLOAD-STAGES
      dup 0<> if
         dir s s" sync upload stage collection" SYNC-DIRECTORY
      then ;] CLOSING
   dir DISCARD ;

private


\ ---- download slots

\ The Rust daemon's names and sizes, so either resumes the other's
\ partials.
: DOWNLOAD-PARTIAL-XATTR ( -- str ) s" user.omabox.download-partial-v1" ;
\ 64 MiB, a whole number of Dropbox's 4 MiB blocks.
$4000000 constant DOWNLOAD-CHECKPOINT-BYTES
: DOWNLOAD-SLOT-OWNER-PREFIX ( -- str ) s" omabox-download-slot-v1" ;
\ The owner prefix, the binding's 32 bytes, then the offset big-endian.
DOWNLOAD-SLOT-OWNER-PREFIX str> nip 32 + 8 +
   constant DOWNLOAD-SLOT-STATE-LENGTH
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
: SOURCE-PATH ( download-source -- str )
   MATCH download-source
      resumable OF {: dir:fd name:str path:str b:binding :} path
      ENDOF
      disposable OF ENDOF
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

: FEED-BE ( n -- ) BE-BUF BE! BE-BUF 8 >str FEED ;

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
   ( n n str MODEL:remote -- download-slot-identity )
   {: generation:n operation:n t:str r:MODEL:remote :}
   r MODEL-REMOTE:UNMAKE {: c:DROPBOX:hash rev:DROPBOX:rev :}
   NAME-CTX SHA256-BEGIN
   s" omabox-download-slot-lease-v1" FEED
   generation FEED-BE operation FEED-BE
   t FEED NUL 1 >str FEED rev DROPBOX:REV>STR FEED
   NUL 1 >str FEED c DROPBOX:HASH>STR FEED
   NAME-CTX NAME-DIGEST SHA256-END
   NAME-DIGEST BYTES>BINDING DOWNLOAD-SLOT-IDENTITY-MAKE ;

: SLOT-BINDING ( download-slot-identity -- binding )
   DOWNLOAD-SLOT-IDENTITY-UNMAKE ;

private

\ ---- slot state

DOWNLOAD-SLOT-STATE-LENGTH BUFFER: STATE-BUF

\ The xattr's bytes, valid until the next encode or read.
: ENCODE-DOWNLOAD-SLOT-STATE ( download-slot-state -- str )
   DOWNLOAD-SLOT-STATE-UNMAKE {: b:binding offset:n :}
   DOWNLOAD-SLOT-OWNER-PREFIX str> {: x:^ xu:n :}
   x STATE-BUF xu BYTE-COPY
   b STATE-BUF xu + BINDING>BYTES
   offset STATE-BUF xu + 32 + BE!
   STATE-BUF DOWNLOAD-SLOT-STATE-LENGTH >str ;

: DECODE-DOWNLOAD-SLOT-STATE ( str -- option<download-slot-state> )
   {: s:str :}
   s str> {: p:^ u:n :}
   DOWNLOAD-SLOT-OWNER-PREFIX {: x:str :}
   x str> nip {: xu:n :}
   u DOWNLOAD-SLOT-STATE-LENGTH <> if OPTION:NONE exit then
   p xu >str x STR:= 0= if OPTION:NONE exit then
   p xu + BYTES>BINDING p xu + 32 + BE@
   DOWNLOAD-SLOT-STATE-MAKE OPTION:SOME ;

: STATE-GOT ( XATTR:got -- option<download-slot-state> )
   MATCH XATTR:got
      absent OF OPTION:NONE ENDOF
      value OF STATE-BUF swap >str DECODE-DOWNLOAD-SLOT-STATE ENDOF
      oversize OF OPTION:NONE ENDOF
   ;MATCH ;

: DROP-SLOT-STATE ( option<download-slot-state> -- ) drop ;

\ The slot's state, none when it carries none in this format.
: READ-DOWNLOAD-SLOT-STATE ( fd str -- option<download-slot-state> )
   {: f:fd p:str :}
   OPTION:NONE
   [: DROP-SLOT-STATE f DOWNLOAD-PARTIAL-XATTR
      STATE-BUF DOWNLOAD-SLOT-STATE-LENGTH SPAN:MAKE XATTR:GET STATE-GOT ;]
   [: s" inspect resumed download slot marker" p IO-FAILURE ;] FS-FAILS ;

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
         f path READ-DOWNLOAD-SLOT-STATE b SLOT-BOUND?
      ENDOF
      disposable OF {: path:str :} false ENDOF
   ;MATCH ;

\ ---- slot files

\ ".omabox-download-slot-" and the slot's digit; the slots are 0 to 3.
24 BUFFER: SLOT-NAME
FS:PATHZ-CAP BUFFER: SLOT-PATH

\ The slot's name, valid until the next.
: DOWNLOAD-SLOT-NAME ( n -- str )
   {: slot:n :}
   s" .omabox-download-slot-" str> {: p:^ u:n :}
   p SLOT-NAME u BYTE-COPY
   slot $30 + SLOT-NAME u + c!
   SLOT-NAME u 1+ >str ;

\ The slot's path in the directory, for logs; valid until the next.
: DOWNLOAD-SLOT-PATH ( str n -- str )
   {: d:str slot:n :}
   d slot DOWNLOAD-SLOT-NAME SLOT-PATH FS:JOIN-PATH SLOT-PATH swap >str ;

ENUM download-slot-open
   VARIANT missing ;VARIANT
   VARIANT file FIELD file fd ;VARIANT
   VARIANT occupied ;VARIANT
;ENUM
: DROP-SLOT-OPEN ( download-slot-open -- ) drop ;

\ The opened file, when it is the regular file probed.
: CHECK-SLOT-FILE ( fd MODEL:stat str -- download-slot-open )
   {: f:fd probed:MODEL:stat p:str :}
   NO-STAT f
   [: DROP-STAT f p s" inspect opened download slot" STAT-FD ;] CLOSING
   {: opened:MODEL:stat :}
   opened REGULAR? opened probed SAME-INODE and if
      f DOWNLOAD-SLOT-OPEN-FILE exit
   then
   f DISCARD DOWNLOAD-SLOT-OPEN-OCCUPIED ;

\ After the open for writing failed: missing, occupied by another inode
\ or one Omabox may not write, else the failure.
: SLOT-OPEN-FAILED ( fd fd str str -- download-slot-open )
   {: probe:fd dir:fd name:str p:str :}
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if DOWNLOAD-SLOT-OPEN-MISSING exit then
   probe dir name p NAMED-INODE-MATCHES 0= if
      DOWNLOAD-SLOT-OPEN-OCCUPIED exit
   then
   e FS:EACCES = e FS:EPERM = or if DOWNLOAD-SLOT-OPEN-OCCUPIED exit then
   e s" open resumed download" p SYSCALL-FAILURE ;

\ Opens the probed name for writing when the probe found a regular file.
: OPEN-PROBED-SLOT ( fd fd str str -- download-slot-open )
   {: probe:fd dir:fd name:str p:str :}
   probe p s" inspect resumed download slot" STAT-FD {: probed:MODEL:stat :}
   probed REGULAR? 0= if DOWNLOAD-SLOT-OPEN-OCCUPIED exit then
   dir name FS:TRY-OPEN-WRITE-AT MATCH option
      none OF probe dir name p SLOT-OPEN-FAILED ENDOF
      some OF probed p CHECK-SLOT-FILE ENDOF
   ;MATCH ;

: SLOT-PROBE-FAILED ( str -- download-slot-open )
   {: p:str :}
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if DOWNLOAD-SLOT-OPEN-MISSING exit then
   e FS:ELOOP = if DOWNLOAD-SLOT-OPEN-OCCUPIED exit then
   e s" inspect resumed download slot" p SYSCALL-FAILURE ;

\ The slot at the name in dir, open for writing when it is a regular file
\ that stays the inode its name held; a symlink there is occupied.
: OPEN-DOWNLOAD-SLOT ( fd str str -- download-slot-open )
   {: dir:fd name:str p:str :}
   dir name FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF p SLOT-PROBE-FAILED ENDOF
      some OF {: probe:fd :}
         DOWNLOAD-SLOT-OPEN-MISSING probe
         [: DROP-SLOT-OPEN probe dir name p OPEN-PROBED-SLOT ;]
         CLOSING probe DISCARD
      ENDOF
   ;MATCH ;

\ A new unnamed file in dir; o names the operation that makes it.
: UNNAMED-FILE ( fd str str -- fd )
   {: dir:fd p:str o:str :}
   -1 >FD [: drop dir FS:TEMP-AT ;]
   [: dir s" " o p IO-FAILURE-AT ;] FS-FAILS ;

\ Binds the unnamed file at offset 0 and names it; false when the name
\ is taken.
: INSTALL-SLOT ( fd fd str str binding -- bool )
   {: f:fd dir:fd name:str p:str b:binding :}
   f DOWNLOAD-PARTIAL-XATTR b 0 DOWNLOAD-SLOT-STATE-MAKE
   ENCODE-DOWNLOAD-SLOT-STATE true p s" mark resumed download slot"
   SET-XATTR
   f p s" sync new resumed download slot" SYNC-FILE
   f dir name FS:TRY-LINK-AT if
      dir p s" sync new resumed download slot entry" SYNC-DIRECTORY
      true exit
   then
   FS:ERRNO FS:EEXIST <> if
      dir name s" install new resumed download slot" p
      IO-FAILURE-AT
   then false ;

\ A new slot at the name in dir bound to b; none when the name is taken.
: CREATE-DOWNLOAD-SLOT ( fd str str binding -- option<fd> )
   {: dir:fd name:str p:str b:binding :}
   dir p s" create resumed download slot" UNNAMED-FILE {: f:fd :}
   false f [: drop f dir name p b INSTALL-SLOT ;] CLOSING
   if f OPTION:SOME exit then
   f DISCARD OPTION:NONE ;

\ Empties the open slot c and binds it to b at offset 0, its stage marker
\ cleared; true when its name still holds it then.
: CLEAR-SLOT ( fd fd str str binding -- bool )
   {: c:fd dir:fd name:str p:str b:binding :}
   [: c 0 FD:RESIZE ;]
   [: s" truncate resumed download slot for reuse" p IO-FAILURE ;]
   FS-FAILS
   c DOWNLOAD-PARTIAL-XATTR b 0 DOWNLOAD-SLOT-STATE-MAKE
   ENCODE-DOWNLOAD-SLOT-STATE false p
   s" reset resumed download slot checkpoint" SET-XATTR
   c p s" sync reset resumed download slot" SYNC-FILE
   c DOWNLOAD-STAGE-XATTR p
   s" clear resumed download slot completion marker" REMOVE-XATTR
   c p s" sync reusable resumed download slot" SYNC-FILE
   c dir name p NAMED-INODE-MATCHES ;

\ Runs before, then clears c, when c is held's inode.
: REBIND-SLOT ( fd fd fd str str binding [ -- ] -- bool )
   {: held:fd c:fd dir:fd name:str p:str b:binding before :}
   held p s" inspect held resumed download slot" STAT-FD
   c p s" inspect reusable resumed download slot" STAT-FD
   SAME-INODE 0= if false exit then
   before [: s" reset resumed download slot" p IO-FAILURE ;] FS-FAILS
   c dir name p b CLEAR-SLOT ;

\ The slot named again, rebound, when it is still held's inode; a throw
\ closes it.
: REBIND-OPENED ( fd fd fd str str binding [ -- ] -- option<fd> )
   {: held:fd c:fd dir:fd name:str p:str b:binding before :}
   false c
   [: drop held c dir name p b before REBIND-SLOT ;] CLOSING
   if c OPTION:SOME exit then
   c DISCARD OPTION:NONE ;

: REBIND-NAMED ( fd fd str str binding [ -- ] -- option<fd> )
   {: held:fd dir:fd name:str p:str b:binding before :}
   dir name p OPEN-DOWNLOAD-SLOT MATCH download-slot-open
      missing OF OPTION:NONE ENDOF
      file OF {: c:fd :} held c dir name p b before REBIND-OPENED
      ENDOF
      occupied OF OPTION:NONE ENDOF
   ;MATCH ;

\ Rust's reset_download_slot_file_with: the slot held, a partial whose
\ name in dir still names it, reopened, emptied and bound to b at offset
\ 0; before runs just ahead of the truncate. None when held carries no
\ state or its name holds another entry, which stays as it is.
: RESET-DOWNLOAD-SLOT-FILE-WITH
   ( fd fd str str binding [ -- ] -- option<fd> )
   {: held:fd dir:fd name:str p:str b:binding before :}
   held p READ-DOWNLOAD-SLOT-STATE MATCH option
      none OF OPTION:NONE ENDOF
      some OF DOWNLOAD-SLOT-STATE-UNMAKE {: was:binding at:n :}
         held dir name p b before REBIND-NAMED
      ENDOF
   ;MATCH ;

\ The location's slot reset for its own binding; none for an unnamed
\ file.
: RESET-DOWNLOAD-SLOT ( fd ^download-location -- option<fd> )
   {: f:fd loc :}
   loc DOWNLOAD-LOCATION-SOURCE @ MATCH download-source
      resumable OF {: dir:fd name:str path:str b:binding :}
         f dir name path b [: ;] RESET-DOWNLOAD-SLOT-FILE-WITH
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
: SLOT-STATE ( n fd str [ binding -- bool ] -- available-download-slot )
   {: slot:n f:fd p:str protected :}
   f p s" inspect resumed download slot" STAT-FD REGULAR? 0= if
      f DISCARD slot false UNOWNED exit
   then
   f p READ-DOWNLOAD-SLOT-STATE MATCH option
      none OF f DISCARD slot false UNOWNED ENDOF
      some OF {: s:download-slot-state :}
         s DOWNLOAD-SLOT-STATE-UNMAKE {: b:binding at:n :}
         b protected execute 0= {: usable:bool :}
         slot f s OWNED-SLOT-MAKE OPTION:SOME usable
         AVAILABLE-DOWNLOAD-SLOT-MAKE
      ENDOF
   ;MATCH ;

: OWNED ( n fd str [ binding -- bool ] -- available-download-slot )
   {: slot:n f:fd p:str protected :}
   slot false UNOWNED f
   [: DROP-AVAILABLE slot f p protected SLOT-STATE ;] CLOSING ;

: SCAN-SLOT ( fd str n [ binding -- bool ] -- available-download-slot )
   {: dir:fd d:str slot:n protected :}
   d slot DOWNLOAD-SLOT-PATH {: p:str :}
   dir slot DOWNLOAD-SLOT-NAME p OPEN-DOWNLOAD-SLOT
   MATCH download-slot-open
      missing OF slot true UNOWNED ENDOF
      file OF {: f:fd :} slot f p protected OWNED ENDOF
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

: SCAN-SLOTS ( fd str [ binding -- bool ] -- )
   {: dir:fd d:str protected :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      dir d i protected SCAN-SLOT i SLOTS !
   loop ;

: OWNED-BY? ( option<owned-slot> binding -- bool )
   {: o:option<owned-slot> b:binding :}
   o MATCH option
      none OF false ENDOF
      some OF OWNED-SLOT-UNMAKE {: f:fd s:download-slot-state :}
         s OPTION:SOME b SLOT-BOUND?
      ENDOF
   ;MATCH ;

: NEW-LEASE ( str n binding -- option<download-slot-lease> )
   {: d:str slot:n b:binding :}
   d slot b DOWNLOAD-SLOT-LEASE-MAKE OPTION:SOME ;

\ The first slot whose partial is bound to b, claimed.
: BOUND-SLOT ( str binding -- option<download-slot-lease> )
   {: d:str b:binding :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      i SLOT-OWNED@ b OWNED-BY? if
         i CLAIMED d i b NEW-LEASE unloop exit
      then
   loop OPTION:NONE ;

\ Closes the slot a reset or create answered; whether there was one.
: TAKEN? ( option<fd> -- bool )
   MATCH option
      none OF false ENDOF
      some OF DISCARD true ENDOF
   ;MATCH ;

\ Rebinds the slot's partial to b, or makes the slot bound to b.
: TAKE-SLOT ( fd str n binding -- bool )
   {: dir:fd d:str slot:n b:binding :}
   d slot DOWNLOAD-SLOT-PATH {: p:str :}
   slot SLOT-OWNED@ MATCH option
      none OF dir slot DOWNLOAD-SLOT-NAME p b CREATE-DOWNLOAD-SLOT ENDOF
      some OF OWNED-SLOT-UNMAKE {: f:fd s:download-slot-state :}
         f dir slot DOWNLOAD-SLOT-NAME p b [: ;]
         RESET-DOWNLOAD-SLOT-FILE-WITH
      ENDOF
   ;MATCH TAKEN? ;

\ The first usable slot that takes b; each one tried is used up.
: CLAIM-SLOT ( fd str binding -- option<download-slot-lease> )
   {: dir:fd d:str b:binding :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      i SLOT-USABLE@ if
         i CLAIMED
         dir d i b TAKE-SLOT if d i b NEW-LEASE unloop exit then
      then
   loop OPTION:NONE ;

\ Empties a usable slot's partial, its binding kept.
: FREE-SLOT ( fd str n -- )
   {: dir:fd d:str slot:n :}
   d slot DOWNLOAD-SLOT-PATH {: p:str :}
   slot SLOT-OWNED@ MATCH option
      none OF ENDOF
      some OF OWNED-SLOT-UNMAKE {: f:fd s:download-slot-state :}
         s DOWNLOAD-SLOT-STATE-UNMAKE {: b:binding at:n :}
         f dir slot DOWNLOAD-SLOT-NAME p b [: ;]
         RESET-DOWNLOAD-SLOT-FILE-WITH TAKEN? drop
      ENDOF
   ;MATCH ;

: FREE-SLOTS ( fd str -- )
   {: dir:fd d:str :}
   MAX-PARALLEL-DOWNLOADS 0 ?do
      i SLOT-USABLE@ if dir d i FREE-SLOT then
   loop ;

: LEASE-IN
   ( fd str binding [ binding -- bool ] -- option<download-slot-lease> )
   {: dir:fd d:str b:binding protected :}
   dir d protected SCAN-SLOTS
   d b BOUND-SLOT MATCH option
      none OF dir d b CLAIM-SLOT ENDOF
      some OF OPTION:SOME ENDOF
   ;MATCH
   dir d FREE-SLOTS ;

public

\ Rust's lease_download_slots for one download: the slot in directory d
\ whose partial is bound to it, else the first free or unprotected one,
\ rebound to it; none when no slot can be. Every other unprotected partial
\ is emptied, its binding kept. The lease holds d's span.
: LEASE-DOWNLOAD-SLOT
   ( str download-slot-identity [ binding -- bool ]
     -- option<download-slot-lease> )
   {: d:str id:download-slot-identity protected :}
   d s" open resumable download slot directory" OPEN-PRIVATE-DIRECTORY
   {: dir:fd :}
   CLEAR-SLOTS
   [: dir d id SLOT-BINDING protected LEASE-IN ;]
   [: CLOSE-SLOTS dir DISCARD ;] finally ;

private

\ ---- download preparation

\ Feeds the next bytes of f, at most IO-SIZE of the left ones, to h;
\ answers the bytes left after them. A short file fails as a read.
: REHASH-CHUNK ( fd n str ^DROPBOX:hasher -- n )
   {: f:fd left:n p:str h :}
   s" rehash resumed download checkpoint" {: o:str :}
   left IO-SIZE min {: k:n :}
   0 [: drop f IO-BUF k FD-READ ;] [: o p IO-FAILURE ;] FS-FAILS
   k < if 0 FS:CAUSE! o p IO-FAILURE then
   IO-BUF k h DROPBOX:HASH-FEED
   left k - ;

\ Rust's hash_download_prefix: h begun and fed the slot's first offset
\ bytes, a whole number of checkpoints, and f left at offset.
: HASH-DOWNLOAD-PREFIX ( fd n str ^DROPBOX:hasher -- )
   {: f:fd offset:n p:str h :}
   [: f 0 FD:SEEK ;] [: s" rewind resumed download" p IO-FAILURE ;]
   FS-FAILS
   h DROPBOX:HASH-BEGIN
   offset begin dup 0 > while f swap p h REHASH-CHUNK repeat drop
   [: f offset FD:SEEK ;]
   [: s" position resumed download" p IO-FAILURE ;] FS-FAILS ;

: DROP-PREPARATION ( download-preparation -- ) drop ;
: DROP-STAGE-OUTCOME ( stage-outcome<n> -- ) drop ;

: READY ( ^download-partial -- download-preparation )
   LOCAL-DOWNLOAD--PREPARATION:READY ;
: EPHEMERAL ( -- download-preparation )
   LOCAL-DOWNLOAD--PREPARATION:EPHEMERAL ;

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
         0 LOCAL-STAGE--OUTCOME:ALREADY-STAGED OPTION:SOME
      ENDOF
      destination-occupied OF LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED
         OPTION:SOME
      ENDOF
   ;MATCH ;

: STAGE-PREPARATION ( download-stage -- option<download-preparation> )
   EXISTING-OUTCOME MATCH option
      none OF OPTION:NONE ENDOF
      some OF LOCAL-DOWNLOAD--PREPARATION:COMPLETE OPTION:SOME ENDOF
   ;MATCH ;

\ The download's stage name for target t, and its path below root path r
\ through the parent's path rel, laid in the arena.
: STAGE-PATHS
   ( str str str DROPBOX:hash ^ARENA:arena -- str str )
   {: r:str rel:str t:str want:DROPBOX:hash ar:^ARENA:arena :}
   s" download" t want ar INTERNAL-NAME {: name:str :}
   r rel ar JOIN name ar JOIN {: sp:str :}
   name sp ;

\ The location of target t's download into dir from the source src
\ answers, its stage named and the target kept in the arena before src
\ runs.
: NEW-LOCATION
   ( [ -- download-source ] fd str str str DROPBOX:hash
     ^ARENA:arena -- download-location )
   {: src dir:fd r:str rel:str t:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   r rel t want ar STAGE-PATHS {: name:str sp:str :}
   t ar KEEP {: target:str :}
   src execute dir name sp target want
   DOWNLOAD-LOCATION-MAKE ;

: NO-LOCATION ( -- download-location )
   s" " DOWNLOAD-SOURCE-DISPOSABLE -1 >FD
   s" " s" " s" " NO-HASH DOWNLOAD-LOCATION-MAKE ;
: DROP-LOCATION ( download-location -- ) drop ;

: LOCATION-PATH ( download-location -- str )
   DOWNLOAD-LOCATION-UNMAKE
   {: src:download-source dir:fd name:str sp:str t:str want:DROPBOX:hash :}
   src SOURCE-PATH ;

: INSPECT-LOCATION ( download-location ^ARENA:arena -- download-stage )
   {: loc:download-location ar:^ARENA:arena :}
   loc DOWNLOAD-LOCATION-UNMAKE
   {: src:download-source dir:fd name:str sp:str t:str want:DROPBOX:hash :}
   dir name sp t want ar INSPECT-DOWNLOAD-STAGE ;

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
   ( download-location str ^ARENA:arena -- download-preparation )
   {: loc:download-location s:str ar:^ARENA:arena :}
   s s" open disposable download staging directory"
   OPEN-PRIVATE-DIRECTORY {: staging:fd :}
   loc LOCATION-PATH {: p:str :}
   [: staging p s" create disposable download stage" UNNAMED-FILE ;]
   [: staging DISCARD ;] finally {: f:fd :}
   EPHEMERAL f [: DROP-PREPARATION loc f ar NEW-PARTIAL READY ;]
   CLOSING ;

: DISPOSABLE
   ( download-location str ^ARENA:arena -- download-preparation )
   {: loc:download-location s:str ar:^ARENA:arena :}
   loc ar INSPECT-LOCATION STAGE-PREPARATION MATCH option
      none OF loc s ar DISPOSABLE-PARTIAL ENDOF
      some OF ENDOF
   ;MATCH ;

public

\ Rust's prepare_disposable_download_with_access_at: the stage below root
\ path r for target t holding want when one is complete, else a partial
\ in an unnamed file in the staging directory s, its paths in the arena.
\ The partial holds the target's parent directory.
: PREPARE-DISPOSABLE-DOWNLOAD-AT
   ( fd str str DROPBOX:hash str ^ARENA:arena
     -- download-preparation )
   {: root:fd r:str t:str want:DROPBOX:hash s:str
      ar:^ARENA:arena :}
   want s" prepare disposable download" REQUIRE-CONTENT-HASH
   root t true OPEN-PARENT MATCH option
      none OF t UNSAFE ENDOF
      some OF ENDOF
   ;MATCH PARENT-DIR-UNMAKE {: dir:fd last:str rel:str :}
   [: [: s s" <unnamed-download>" ar JOIN
         DOWNLOAD-SOURCE-DISPOSABLE ;]
      dir r rel t want ar NEW-LOCATION s ar DISPOSABLE ;]
   [: dir DISCARD ;] PREPARING ;

private

\ ---- partial ownership

: TARGET-DIR@ ( ^download-location -- fd )
   DOWNLOAD-LOCATION-TARGET-DIRECTORY @ ;
: STAGE-NAME@ ( ^download-location -- str )
   DOWNLOAD-LOCATION-STAGE-NAME @ ;
: STAGE-PATH@ ( ^download-location -- str )
   DOWNLOAD-LOCATION-STAGE-PATH @ ;
: TARGET@ ( ^download-location -- str )
   DOWNLOAD-LOCATION-TARGET @ ;
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
: PARTIAL-PATH ( ^download-partial -- str )
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

: OCCUPIED-AT ( str -- stage-outcome<n> )
 LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED ;

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
   loc TARGET@ loc EXPECTED@ ar STAGE-MARKER OPTION:SOME
   {: marker:option<str> :}
   loc TARGET-DIR@ loc STAGE-NAME@ loc STAGE-PATH@ loc EXPECTED@
   [: f -rot FD-READ ;] marker s" copy completed download slot" ar
   WRITE-VERIFIED-STAGE [: 0 ;] MAP-STAGE-WRITE ;

\ Rust's copy_completed_slot: the completed file copied and rehashed into
\ the stage; a slot staged from is emptied and keeps its binding.
: COPY-COMPLETED-SLOT
   ( fd ^download-location ^ARENA:arena -- stage-outcome<n> )
   {: f:fd loc ar:^ARENA:arena :}
   loc SOURCE@ SOURCE-PATH {: p:str :}
   [: f 0 FD:SEEK ;]
   [: s" rewind completed download slot" p IO-FAILURE ;] FS-FAILS
   0 LOCAL-STAGE--OUTCOME:STAGED
   [: DROP-STAGE-OUTCOME f loc ar COPY-INTO-STAGE ;] LOCAL-ERRORS
   {: out:stage-outcome<n> :}
   out STAGED? if f loc RESET-DOWNLOAD-SLOT TAKEN? drop then
   out ;

\ The entry already at the stage's name: a verified stage, whose
\ descriptor closes, runs q and is staged already; o names the operation.
: RACED-STAGE
   ( ^download-location str [ -- ] ^ARENA:arena -- stage-outcome<n> )
   {: loc o:str q ar:^ARENA:arena :}
   loc @ ar INSPECT-LOCATION MATCH download-stage
      missing OF o loc TARGET@ CHANGED ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: s:fd print:MODEL:fingerprint :} s DISCARD
         q execute 0 LOCAL-STAGE--OUTCOME:ALREADY-STAGED
      ENDOF
      destination-occupied OF LOCAL-STAGE--OUTCOME:DESTINATION-OCCUPIED
      ENDOF
   ;MATCH ;

\ After the move into the stage failed with errno e: an entry at the
\ stage's name is inspected, q running for a verified one; another
\ filesystem is copied across; else fail, which throws, runs with
\ FS:ERRNO set to e.
: MOVE-FAILED
   ( fd ^download-location ^ARENA:arena n str [ -- ] [ -- ]
     -- stage-outcome<n> )
   {: f:fd loc ar:^ARENA:arena e:n o:str q fail :}
   e FS:EEXIST = if loc o q ar RACED-STAGE exit then
   e FS:EXDEV = if f loc ar COPY-COMPLETED-SLOT exit then
   e FS:CAUSE! fail execute E-IO throw ;

\ The stage made read-only by m and synced by s.
: SEAL-PROMOTED ( fd ^download-location str str -- stage-outcome<n> )
   {: f:fd loc m:str s:str :}
   f loc STAGE-PATH@ m READ-ONLY
   f loc STAGE-PATH@ s SYNC-FILE
   0 LOCAL-STAGE--OUTCOME:STAGED ;

\ Where the swapped stage went: the slot's name, or, when an entry took
\ that, the stage's, where it stays.
: RESTORED-PATH ( ^download-location fd str str -- str )
   {: loc slots:fd name:str p:str :}
   loc TARGET-DIR@ loc STAGE-NAME@ slots name FS:TRY-RENAME-NEW-AT if
      p exit
   then
   FS:ERRNO FS:EEXIST <> if
      loc TARGET-DIR@ loc STAGE-NAME@ slots name
      s" restore swapped resumed download" loc STAGE-PATH@
      IO-FAILURE-ACROSS
   then
   loc STAGE-PATH@ ;

\ Another inode took the slot's name before the move: it goes back.
: RESTORE-SWAPPED ( ^download-location fd str str -- stage-outcome<n> )
   {: loc slots:fd name:str p:str :}
   loc slots name p RESTORED-PATH {: at:str :}
   slots p s" sync restored download slot" SYNC-DIRECTORY
   loc TARGET-DIR@ loc STAGE-PATH@ s" sync restored download stage"
   SYNC-DIRECTORY
   at OCCUPIED-AT ;

\ The slot named the stage: sealed, when it is still the file held.
: PROMOTED-SLOT
   ( fd ^download-location fd str str -- stage-outcome<n> )
   {: f:fd loc slots:fd name:str p:str :}
   f loc TARGET-DIR@ loc STAGE-NAME@ loc STAGE-PATH@ NAMED-INODE-MATCHES
   0= if loc slots name p RESTORE-SWAPPED exit then
   slots p s" sync consumed download slot" SYNC-DIRECTORY
   loc TARGET-DIR@ loc STAGE-PATH@ s" sync promoted download stage"
   SYNC-DIRECTORY
   f loc s" make resumed download stage immutable"
   s" sync completed download stage" SEAL-PROMOTED ;

\ Renames the slot, still bound to the download, to the stage's name;
\ before runs just ahead of the rename.
: MOVE-SLOT
   ( fd ^download-location [ -- ] ^ARENA:arena fd str str
     -- stage-outcome<n> )
   {: f:fd loc before ar:^ARENA:arena slots:fd name:str p:str :}
   s" recover completed resumed download" {: o:str :}
   f loc DOWNLOAD-SLOT-MATCHES 0= if p OCCUPIED-AT exit then
   before [: s" promote completed download slot" p IO-FAILURE ;] FS-FAILS
   slots name loc TARGET-DIR@ loc STAGE-NAME@ FS:TRY-RENAME-NEW-AT if
      f loc slots name p PROMOTED-SLOT exit
   then
   f loc ar FS:ERRNO o [: f loc RESET-DOWNLOAD-SLOT TAKEN? drop ;]
   [: slots name loc TARGET-DIR@ loc STAGE-NAME@ o p
      IO-FAILURE-ACROSS ;]
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
   s" promote completed disposable download" {: o:str :}
   loc SOURCE@ SOURCE-PATH {: p:str :}
   before [: o p IO-FAILURE ;] FS-FAILS
   f loc TARGET-DIR@ loc STAGE-NAME@ FS:TRY-LINK-AT if
      f loc LINKED-DISPOSABLE exit
   then
   f loc ar FS:ERRNO o [: ;]
   [: loc TARGET-DIR@ loc STAGE-NAME@ o p IO-FAILURE-AT ;]
   MOVE-FAILED ;

\ Rust's promote_completed_slot_with: the completed, marked file f moved
\ into the location's stage, before running just ahead of the move.
: PROMOTE-COMPLETED-SLOT-WITH
   ( fd ^download-location [ -- ] ^ARENA:arena -- stage-outcome<n> )
   {: f:fd loc before ar:^ARENA:arena :}
   loc SOURCE@ MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         f loc before ar slots name path MOVE-SLOT
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
: STAGE-READ-EXACT ( ^u8 n [ ^u8 n -- n ] str str -- )
   {: dst:^ cap:n read p:str o:str :}
   0 begin dup cap < while
      {: done:n :}
      dst done + cap done - read p o STAGE-READ-INTO {: k:n :}
      k 0= if 0 FS:CAUSE! o p STAGE-READ then
      done k +
   repeat drop ;

\ Rust's discard_uncommitted_block: the file cut back to the offset.
: DISCARD-UNCOMMITTED-BLOCK ( ^download-partial -- )
   {: x :}
   x PARTIAL-PATH {: p:str :}
   [: x PARTIAL-FILE x DOWNLOAD-PARTIAL-OFFSET @ FD:RESIZE ;]
   [: s" discard incomplete resumed download block" p IO-FAILURE ;]
   FS-FAILS ;

\ Runs q; a throw first discards the block it was writing.
: UNCOMMITTED ( ^download-partial [ -- ] -- )
   {: x q :}
   [: q execute ;] catch {: code:n :}
   code 0= if exit then
   x DISCARD-UNCOMMITTED-BLOCK code throw ;

: WRITE-DOWNLOAD ( ^download-partial str -- )
   {: x b:str :}
   x PARTIAL-PATH {: p:str :}
   [: x PARTIAL-FILE b FD:WRITE-FULL ;]
   [: s" write resumed download" p IO-FAILURE ;] FS-FAILS ;

\ Reads k bytes, writes them to the file and feeds them to the hash.
: APPEND-CHUNK ( ^download-partial n [ ^u8 n -- n ] -- )
   {: x k:n read :}
   IO-BUF k read x DOWNLOAD-PARTIAL-LOCATION TARGET@
   s" read resumed download" STAGE-READ-EXACT
   x IO-BUF k >str WRITE-DOWNLOAD
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
         f path s" sync resumed download checkpoint" SYNC-FILE
         f DOWNLOAD-PARTIAL-XATTR
         b x DOWNLOAD-PARTIAL-OFFSET @ DOWNLOAD-SLOT-STATE-MAKE
         ENCODE-DOWNLOAD-SLOT-STATE false path
         s" record resumed download checkpoint" SET-XATTR
         f path s" sync resumed download checkpoint marker" SYNC-FILE
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
   actual LOCAL-STAGE--OUTCOME:CONTENT-CHANGED ;

\ Syncs the verified file, marks it complete and promotes it.
: COMPLETE-PARTIAL ( ^download-partial ^ARENA:arena -- stage-outcome<n> )
   {: x ar:^ARENA:arena :}
   x PARTIAL-FILE {: f:fd :}
   x PARTIAL-PATH {: p:str :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   f p s" sync completed resumed download data" SYNC-FILE
   f DOWNLOAD-STAGE-XATTR loc TARGET@ loc EXPECTED@ ar STAGE-MARKER true
   p s" mark completed resumed download" SET-XATTR
   f p s" sync completed resumed download marker" SYNC-FILE
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
   x DOWNLOAD-PARTIAL-LOCATION TARGET@ {: t:str :}
   x DOWNLOAD-PARTIAL-OFFSET @ total > if
      s" validate resumed download size" t CHANGED
   then
   x total read APPEND-BLOCKS
   EXTRA 1 read t s" finish resumed download" STAGE-READ-INTO 0<> if
      s" validate resumed download length" t CHANGED
   then
   x ar FINISH-PARTIAL ;

: RESTARTED ( ^download-partial -- download-preparation )
   {: x :}
   x PARTIAL-FILE x DOWNLOAD-PARTIAL-LOCATION RESET-DOWNLOAD-SLOT
   MATCH option
      none OF x PARTIAL-PATH OCCUPIED-AT LOCAL-DOWNLOAD--PREPARATION:COMPLETE
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
   d name ar JOIN {: path:str :}
   d s" open resumable download slot directory"
   OPEN-PRIVATE-DIRECTORY name path b DOWNLOAD-SOURCE-RESUMABLE ;

\ The source's slot opened; an unnamed file has none.
: SLOT-OPEN ( download-source -- download-slot-open )
   MATCH download-source
      resumable OF {: slots:fd name:str path:str b:binding :}
         slots name path OPEN-DOWNLOAD-SLOT
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

: SLOT-LENGTH ( MODEL:stat str -- n )
   {: st:MODEL:stat p:str :}
   st MODEL-STAT:UNMAKE {: d i m s ms mn cs cn :}
   s 0 < if 0 s" inspect resumed download size" p SYSCALL-FAILURE then
   s ;

: TRUNCATE-TAIL ( ^download-partial n -- )
   {: x at:n :}
   x PARTIAL-PATH {: p:str :}
   [: x PARTIAL-FILE at FD:RESIZE ;]
   [: s" truncate resumed download tail" p IO-FAILURE ;] FS-FAILS
   x PARTIAL-FILE p s" sync truncated resumed download" SYNC-FILE ;

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
      LOCAL-DOWNLOAD--PREPARATION:COMPLETE exit
   then
   x at length true RESUME-FROM ;

: SLOT-MARKER ( ^download-partial ^ARENA:arena -- download-marker )
   {: x ar:^ARENA:arena :}
   x DOWNLOAD-PARTIAL-LOCATION {: loc :}
   loc TARGET@ loc EXPECTED@ ar STAGE-MARKER {: m:str :}
   x PARTIAL-FILE m x PARTIAL-PATH READ-DOWNLOAD-MARKER ;

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
   {: st:MODEL:stat :}
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
      complete OF LOCAL-DOWNLOAD--PREPARATION:COMPLETE ENDOF
      ephemeral OF EPHEMERAL ENDOF
   ;MATCH ;

\ Rust's open_parent with create; none is an unsafe path.
: OPEN-TARGET-PARENT ( fd str -- parent-dir )
   {: root:fd t:str :}
   root t true OPEN-PARENT MATCH option
      none OF t UNSAFE ENDOF
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
   ( fd str str DROPBOX:hash download-slot-lease ^ARENA:arena
     -- download-preparation )
   {: root:fd r:str t:str want:DROPBOX:hash
      lease:download-slot-lease ar:^ARENA:arena :}
   want s" prepare resumed download" REQUIRE-CONTENT-HASH
   root t OPEN-TARGET-PARENT PARENT-DIR-UNMAKE
   {: dir:fd last:str rel:str :}
   NO-LOCATION dir [: DROP-LOCATION [: lease ar SLOT-SOURCE ;]
      dir r rel t want ar NEW-LOCATION ;] CLOSING
   {: loc:download-location :}
   [: loc ar SLOT-PREPARATION ;] [: loc CLOSE-LOCATION ;] PREPARING
   lease ar RESUMED ;

private

\ ---- staged downloads

: STAGE-DOWNLOAD-IN
   ( fd str str str DROPBOX:hash [ ^u8 n -- n ] ^ARENA:arena
     -- stage-outcome<n> )
   {: dir:fd r:str rel:str t:str want:DROPBOX:hash read
      ar:^ARENA:arena :}
   r rel t want ar STAGE-PATHS {: name:str sp:str :}
   t want ar STAGE-MARKER OPTION:SOME {: marker:option<str> :}
   dir name sp want read marker s" stage download" ar
   WRITE-VERIFIED-STAGE [: 0 ;] MAP-STAGE-WRITE ;

: EXISTING-IN
   ( fd str str str DROPBOX:hash ^ARENA:arena
     -- option<stage-outcome<n>> )
   {: dir:fd r:str rel:str t:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   r rel t want ar STAGE-PATHS {: name:str sp:str :}
   dir name sp t want ar INSPECT-DOWNLOAD-STAGE EXISTING-OUTCOME ;

public

\ Rust's stage_download_at: read's bytes staged beside target t below
\ root path r when they hash to want, marked as its owned download. A
\ failed read throws E-STAGE-READ.
: STAGE-DOWNLOAD-AT
   ( fd str str DROPBOX:hash [ ^u8 n -- n ] ^ARENA:arena
     -- stage-outcome<n> )
   {: root:fd r:str t:str want:DROPBOX:hash read ar:^ARENA:arena :}
   want s" stage download" REQUIRE-CONTENT-HASH
   root t OPEN-TARGET-PARENT PARENT-DIR-UNMAKE
   {: dir:fd last:str rel:str :}
   [: dir r rel t want read ar STAGE-DOWNLOAD-IN ;]
   [: dir DISCARD ;] finally ;

\ Rust's existing_download_stage_at: what the stage for target t holding
\ want below root path r already comes to, none when it is missing.
: EXISTING-DOWNLOAD-STAGE-AT
   ( fd str str DROPBOX:hash ^ARENA:arena -- option<stage-outcome<n>> )
   {: root:fd r:str t:str want:DROPBOX:hash ar:^ARENA:arena :}
   want s" inspect download stage" REQUIRE-CONTENT-HASH
   root t OPEN-TARGET-PARENT PARENT-DIR-UNMAKE
   {: dir:fd last:str rel:str :}
   [: dir r rel t want ar EXISTING-IN ;] [: dir DISCARD ;]
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

: INSTALLED ( -- install-outcome ) LOCAL-INSTALL--OUTCOME:INSTALLED ;
: ALREADY-INSTALLED ( -- install-outcome )
   LOCAL-INSTALL--OUTCOME:ALREADY-INSTALLED ;
: DOWNLOAD-REQUIRED ( -- install-outcome )
   LOCAL-INSTALL--OUTCOME:DOWNLOAD-REQUIRED ;
: STAGE-OCCUPIED ( str -- install-outcome )
   LOCAL-INSTALL--OUTCOME:STAGE-DESTINATION-OCCUPIED ;
: INSTALL-CHANGED ( option<DROPBOX:hash> -- install-outcome )
   LOCAL-INSTALL--OUTCOME:PRECONDITION-CHANGED ;
: PREPARED ( -- replacement-preparation )
   LOCAL-REPLACEMENT--PREPARATION:PREPARED ;
: ALREADY-PREPARED ( -- replacement-preparation )
   LOCAL-REPLACEMENT--PREPARATION:ALREADY-PREPARED ;
: PREPARE-CHANGED ( option<DROPBOX:hash> -- replacement-preparation )
   LOCAL-REPLACEMENT--PREPARATION:PRECONDITION-CHANGED ;

\ No content: nothing is at the path.
: ABSENT ( -- option<DROPBOX:hash> ) OPTION:NONE ;

: PRESENT? ( option<DROPBOX:hash> -- bool )
   MATCH option
      none OF false ENDOF
      some OF DROP-HASH true ENDOF
   ;MATCH ;

: GUARD-NAME ( str DROPBOX:hash ^ARENA:arena -- str )
   {: t:str c:DROPBOX:hash ar:^ARENA:arena :}
   s" displaced" t c ar INTERNAL-NAME ;

\ Removes the name in dir; o names the operation and p the path.
: REMOVE-AT ( fd str str str -- )
   {: dir:fd name:str o:str p:str :}
   dir name FS:TRY-REMOVE-FILE-AT 0= if
      dir name o p IO-FAILURE-AT
   then ;

: WRITABLE ( fd str str -- )
   {: f:fd p:str o:str :}
   [: f FS:MODE-PRIVATE-FILE FD:MODE! ;] [: o p IO-FAILURE ;]
   FS-FAILS ;

\ The stage's file is as it was verified.
: VERIFY-DOWNLOAD-STAGE-BEFORE-RENAME ( verified-download-stage str -- )
   {: s:verified-download-stage p:str :}
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   s" verify download stage before rename" {: o:str :}
   f p o STAT-FD p FILE-FINGERPRINT
   print SAME-FINGERPRINT? 0= if o p CHANGED then ;

\ Makes the owned download at f a plain file: writable, unmarked.
: RELEASE-OWNED-DOWNLOAD ( fd str -- )
   {: f:fd p:str :}
   f p s" make installed download writable" WRITABLE
   f DOWNLOAD-PARTIAL-XATTR p s" clear resumed download marker"
   REMOVE-XATTR
   f p s" sync installed download cleanup" SYNC-FILE
   f DOWNLOAD-STAGE-XATTR p s" clear installed download marker"
   REMOVE-XATTR ;

\ Syncs the installed file; one still marked as LOCAL's is released first.
: FINISH-INSTALLED-DOWNLOAD ( fd str bool -- )
   {: f:fd p:str owned:bool :}
   owned if f p RELEASE-OWNED-DOWNLOAD then
   f p s" sync installed download" SYNC-FILE ;

\ Whether the stage's file holds its verified bytes under the name.
: BOUND? ( verified-download-stage fd str str str -- bool )
   {: s:verified-download-stage dir:fd name:str p:str o:str :}
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   f p o STAT-FD p FILE-FINGERPRINT
   print SAME-HASHED-CONTENT 0= if false exit then
   f dir name p NAMED-INODE-MATCHES ;

\ Whether the renamed stage is the owned download of want at the name.
: OWNED-RENAME?
   ( verified-download-stage fd str str DROPBOX:hash ^ARENA:arena
     -- bool )
   {: s:verified-download-stage dir:fd name:str p:str
      want:DROPBOX:hash ar:^ARENA:arena :}
   p want ar STAGE-MARKER {: m:str :}
   s dir name p s" verify renamed download content" BOUND?
   0= if false exit then
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   f m p READ-DOWNLOAD-MARKER EXPECTED? ;

\ Releases and syncs the stage renamed to the name, which must be the
\ owned download of want before and after.
: SYNC-RENAMED-DOWNLOAD
   ( verified-download-stage fd str str DROPBOX:hash ^ARENA:arena -- )
   {: s:verified-download-stage dir:fd name:str p:str
      want:DROPBOX:hash ar:^ARENA:arena :}
   s dir name p want ar OWNED-RENAME? 0= if
      s" verify renamed download ownership" p CHANGED
   then
   dir p s" sync installed download rename" SYNC-DIRECTORY
   s VERIFIED-DOWNLOAD-STAGE-UNMAKE {: f:fd print:MODEL:fingerprint :}
   f p true FINISH-INSTALLED-DOWNLOAD
   s dir name p s" verify installed download content" BOUND? 0= if
      s" verify installed download binding" p CHANGED
   then ;

\ Finishes the open installed file when its content actual is want.
: FINISH-IF-WANTED
   ( fd DROPBOX:hash str DROPBOX:hash ^ARENA:arena -- )
   {: f:fd actual:DROPBOX:hash p:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   actual want SAME-CONTENT? 0= if
      s" verify installed download" p CHANGED
   then
   p want ar STAGE-MARKER {: m:str :}
   f m p READ-DOWNLOAD-MARKER EXPECTED? {: owned:bool :}
   f p owned FINISH-INSTALLED-DOWNLOAD ;

\ Syncs the download installed at the name, which must hold want, and
\ its entry; a file still marked as LOCAL's is released first.
: SYNC-INSTALLED-DOWNLOAD
   ( fd str str DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd name:str p:str want:DROPBOX:hash ar:^ARENA:arena :}
   s" verify installed download" {: o:str :}
   dir name p o ar OPEN-AND-HASH-IF-PRESENT MATCH option
      none OF o p CHANGED ENDOF
      some OF HASHED-UNMAKE
         {: f:fd c:DROPBOX:hash print:MODEL:fingerprint :}
         [: f c p want ar FINISH-IF-WANTED ;] [: f DISCARD ;] finally
      ENDOF
   ;MATCH
   dir p s" sync installed download entry" SYNC-DIRECTORY ;

\ Removes the owned stage of want at the name in dir; another file
\ there is kept.
: REMOVE-VERIFIED-STAGE
   ( fd str DROPBOX:hash str str ^ARENA:arena -- stage-cleanup )
   {: dir:fd name:str want:DROPBOX:hash p:str t:str
      ar:^ARENA:arena :}
   dir name p t want ar INSPECT-DOWNLOAD-STAGE
   MATCH download-stage
      missing OF STAGE-CLEANUP-REMOVED-OR-ABSENT ENDOF
      verified OF VERIFIED-DOWNLOAD-STAGE-UNMAKE
         {: f:fd print:MODEL:fingerprint :} f DISCARD
         dir name s" remove verified staging file" p REMOVE-AT
         STAGE-CLEANUP-REMOVED-OR-ABSENT
      ENDOF
      destination-occupied OF STAGE-CLEANUP-DESTINATION-OCCUPIED ENDOF
   ;MATCH ;

\ Removes target's guard for c when it holds c; other bytes are kept.
: REMOVE-GUARD-IF-VERIFIED ( fd str DROPBOX:hash ^ARENA:arena -- )
   {: dir:fd t:str c:DROPBOX:hash ar:^ARENA:arena :}
   t c ar GUARD-NAME {: g:str :}
   dir g t s" verify stale install guard" ar HASH-AT-IF-PRESENT
   MATCH option
      none OF ENDOF
      some OF c SAME-CONTENT? 0= if
            s" clean completed replacement" t OCCUPIED
         then
         dir g s" remove stale install guard" t REMOVE-AT
      ENDOF
   ;MATCH ;

\ The guard at path gp holds held: prepared when that is c.
: EXISTING-GUARD
   ( option<DROPBOX:hash> DROPBOX:hash str -- replacement-preparation )
   {: held:option<DROPBOX:hash> c:DROPBOX:hash gp:str :}
   held c HOLDS? 0= if
      s" prepare download replacement" gp OCCUPIED
   then
   ALREADY-PREPARED ;

\ The target is at its guard g, at path gp, now: prepared when the guard
\ holds c, else the guard goes back or is kept as a local conflict.
: VERIFY-DISPLACED
   ( fd str str str str DROPBOX:hash ^ARENA:arena
     -- replacement-preparation )
   {: dir:fd g:str gp:str tn:str t:str c:DROPBOX:hash
      ar:^ARENA:arena :}
   dir t s" sync replacement displacement guard" SYNC-DIRECTORY
   dir g gp s" verify displaced replacement file" ar
   HASH-AT-IF-PRESENT {: held:option<DROPBOX:hash> :}
   held c HOLDS? if PREPARED exit then
   dir g tn t held ar RESTORE-OR-PRESERVE-CHANGED-GUARD
   held PREPARE-CHANGED ;

\ Renames the target to its guard g, at path gp, never over an entry.
: MOVE-TO-GUARD
   ( fd str str str str DROPBOX:hash ^ARENA:arena
     -- replacement-preparation )
   {: dir:fd g:str gp:str tn:str t:str c:DROPBOX:hash
      ar:^ARENA:arena :}
   dir tn dir g FS:TRY-RENAME-NEW-AT if
      dir g gp tn t c ar VERIFY-DISPLACED exit
   then
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if ABSENT PREPARE-CHANGED exit then
   e FS:EEXIST <> if
      dir tn s" move replaced file to displacement guard" t
      IO-FAILURE-AT
   then
   dir g gp s" verify raced replacement displacement" ar
   HASH-AT-IF-PRESENT c gp EXISTING-GUARD ;

\ Moves the target at the name in dir, whose path is dp, to its guard
\ when it holds c; a guard already there holding c was moved before.
: PREPARE-REPLACEMENT-AT
   ( fd str str str DROPBOX:hash ^ARENA:arena
     -- replacement-preparation )
   {: dir:fd dp:str tn:str t:str c:DROPBOX:hash
      ar:^ARENA:arena :}
   t c ar GUARD-NAME {: g:str :}
   dp g ar JOIN {: gp:str :}
   dir tn t s" check replacement preparation precondition" ar
   HASH-AT-IF-PRESENT {: current:option<DROPBOX:hash> :}
   dir g gp s" inspect replacement displacement guard" ar
   HASH-AT-IF-PRESENT {: held:option<DROPBOX:hash> :}
   held PRESENT? if held c gp EXISTING-GUARD exit then
   current c HOLDS? 0= if current PREPARE-CHANGED exit then
   dir g gp tn t c ar MOVE-TO-GUARD ;

\ ---- an install's steps

: DESIRED ( install -- DROPBOX:hash )
   INSTALL-UNMAKE {: dir dp sn sp tn t want ar :} want ;

\ The content at x's target now; o names the operation.
: TARGET-HASH ( install str -- option<DROPBOX:hash> )
   {: x:install o:str :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir tn t o ar HASH-AT-IF-PRESENT ;

\ Syncs x's parent; o names the operation.
: SYNC-PARENT ( install str -- )
   {: x:install o:str :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir t o SYNC-DIRECTORY ;

\ Removes the name in x's parent; o names the operation.
: REMOVE-IN-PARENT ( install str str -- )
   {: x:install g:str o:str :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir g o t REMOVE-AT ;

: INSPECT-INSTALL-STAGE ( install -- download-stage )
   INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   dir sn sp t want ar INSPECT-DOWNLOAD-STAGE ;

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
   dir tn t want ar SYNC-INSTALLED-DOWNLOAD
   dir sn want sp t ar REMOVE-VERIFIED-STAGE ;

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
   dir t c ar REMOVE-GUARD-IF-VERIFIED ;

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
   s sp VERIFY-DOWNLOAD-STAGE-BEFORE-RENAME
   dir sn dir tn FS:TRY-RENAME-NEW-AT if
      s dir tn t want ar SYNC-RENAMED-DOWNLOAD
      INSTALLED exit
   then
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if DOWNLOAD-REQUIRED exit then
   e FS:EEXIST <> if
      dir sn s" install download into absent path" t
      IO-FAILURE-AT
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
   ( install str option<DROPBOX:hash> -- install-outcome )
   {: x:install g:str actual:option<DROPBOX:hash> :}
   x g s" remove recovered displacement guard" REMOVE-IN-PARENT
   actual x DESIRED HOLDS? if
      x s" sync raced replacement cleanup" SYNC-PARENT
      ALREADY-INSTALLED exit
   then
   x s" sync raced replacement" SYNC-PARENT
   actual INSTALL-CHANGED ;

: RACED-REPLACEMENT ( install str -- install-outcome )
   {: x:install g:str :}
   x s" inspect raced install destination" TARGET-HASH
   {: actual:option<DROPBOX:hash> :}
   actual x DESIRED HOLDS? 0= if x g actual SETTLE-RACED exit then
   x CLEAN-INSTALLED [: x g actual SETTLE-RACED ;] CLEANED ;

\ The stage renamed to the target; the guard g it displaced is removed.
: REPLACED
   ( verified-download-stage install str -- install-outcome )
   {: s:verified-download-stage x:install g:str :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   s dir tn t want ar SYNC-RENAMED-DOWNLOAD
   x g s" remove displaced install guard" REMOVE-IN-PARENT
   x s" sync completed replacement" SYNC-PARENT
   INSTALLED ;

\ Renames the stage to the target, now at its guard for c.
: RENAME-REPLACEMENT
   ( verified-download-stage install DROPBOX:hash -- install-outcome )
   {: s:verified-download-stage x:install c:DROPBOX:hash :}
   x INSTALL-UNMAKE {: dir dp sn sp tn t want ar :}
   t c ar GUARD-NAME {: g:str :}
   s sp VERIFY-DOWNLOAD-STAGE-BEFORE-RENAME
   dir sn dir tn FS:TRY-RENAME-NEW-AT if
      s x g REPLACED exit
   then
   FS:ERRNO FS:EEXIST <> if
      dir sn s" install verified replacement" t
      IO-FAILURE-AT
   then
   x g RACED-REPLACEMENT ;

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
   dir dp tn t c ar PREPARE-REPLACEMENT-AT ;

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
   ( fd str str str str DROPBOX:hash ^ARENA:arena -- install )
   {: f:fd tn:str rel:str r:str t:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   r rel ar JOIN {: dp:str :}
   s" download" t want ar INTERNAL-NAME {: sn:str :}
   dp sn ar JOIN {: sp:str :}
   f dp sn sp tn t want ar
   INSTALL-MAKE ;

public

\ Renames the verified stage of want over target t below the root fd,
\ whose path is r, only while t holds expected, or is absent when
\ expected is none; a target that changed is kept, never overwritten.
\ With expected none, E-UNSUPPORTED or E-UNREADABLE is about t's own
\ name; a replacement's guard or local conflict name can throw them too.
: INSTALL-DOWNLOAD-AT
   ( fd str str DROPBOX:hash option<DROPBOX:hash> ^ARENA:arena
     -- install-outcome )
   {: root:fd r:str t:str want:DROPBOX:hash
      expected:option<DROPBOX:hash> ar:^ARENA:arena :}
   want s" install download" REQUIRE-CONTENT-HASH
   root t false OPEN-PARENT MATCH option
      none OF DOWNLOAD-REQUIRED ENDOF
      some OF PARENT-DIR-UNMAKE {: f:fd name:str rel:str :}
         [: f name rel r t want ar INSTALL-OF
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
   ( deletion str ^ARENA:arena -- option<DROPBOX:hash> )
   {: x:deletion o:str ar:^ARENA:arena :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir g gp o ar HASH-AT-IF-PRESENT ;

\ Whether a guard holding the expected content is there; other bytes are
\ kept and stop the operation oc names. i names the read.
: GUARD-HELD? ( deletion str str ^ARENA:arena -- bool )
   {: x:deletion i:str oc:str ar:^ARENA:arena :}
   x i ar GUARD-CONTENT MATCH option
      none OF false ENDOF
      some OF x DELETION-WANT SAME-CONTENT? 0= if
            x DELETION-UNMAKE
            {: d:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
            oc gp OCCUPIED
         then true
      ENDOF
   ;MATCH ;

\ Removes the guard, then syncs its directory; o names the removal, sy
\ the sync.
: REMOVE-GUARD ( deletion str str -- )
   {: x:deletion o:str sy:str :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir g FS:TRY-REMOVE-FILE-AT 0= if
      dir g o t IO-FAILURE-AT
   then
   dir t sy SYNC-DIRECTORY ;

\ The guard holds other content than expected: it goes back to the target,
\ or is kept beside an entry raced in there.
: GUARD-CHANGED
   ( deletion option<DROPBOX:hash> ^ARENA:arena -- delete-outcome )
   {: x:deletion c:option<DROPBOX:hash> ar:^ARENA:arena :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir g n t c ar RESTORE-OR-PRESERVE-CHANGED-GUARD
   c LOCAL-DELETE--OUTCOME:PRECONDITION-CHANGED ;

\ The target is absent: a guard holding the expected content finishes an
\ interrupted delete.
: FINISH-INTERRUPTED ( deletion ^ARENA:arena -- delete-outcome )
   {: x:deletion ar:^ARENA:arena :}
   x s" inspect interrupted deletion" ar GUARD-CONTENT
   {: c:option<DROPBOX:hash> :}
   c x DELETION-WANT HOLDS? if
      x s" finish interrupted deletion" s" sync interrupted deletion"
      REMOVE-GUARD LOCAL-DELETE--OUTCOME:DELETED exit
   then
   c MATCH option
      none OF LOCAL-DELETE--OUTCOME:ALREADY-DELETED ENDOF
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
   c OPTION:SOME LOCAL-DELETE--OUTCOME:PRECONDITION-CHANGED ;

\ Moves the target to the guard's name and syncs; false when the target
\ is gone by now.
: DISPLACE ( deletion -- bool )
   {: x:deletion :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir n dir g FS:TRY-RENAME-NEW-AT if
      dir t s" sync deletion displacement" SYNC-DIRECTORY true exit
   then
   FS:ERRNO FS:ENOENT = if false exit then
   dir n s" move deleted file to displacement guard" t
   IO-FAILURE-AT ;

\ The target holds the expected content: it moves aside to the guard and
\ is removed there only while the guard still holds it.
: DELETE-EXPECTED ( deletion ^ARENA:arena -- delete-outcome )
   {: x:deletion ar:^ARENA:arena :}
   x s" inspect deletion guard" s" prepare local deletion" ar
   GUARD-HELD? if
      x s" remove stale deletion guard"
      s" sync stale deletion guard removal" REMOVE-GUARD
   then
   x DISPLACE 0= if LOCAL-DELETE--OUTCOME:ALREADY-DELETED exit then
   x s" verify deletion displacement" ar GUARD-CONTENT
   {: c:option<DROPBOX:hash> :}
   c x DELETION-WANT HOLDS? 0= if x c ar GUARD-CHANGED exit then
   x s" delete verified displaced file" s" sync local deletion"
   REMOVE-GUARD LOCAL-DELETE--OUTCOME:DELETED ;

: DELETE-IN ( deletion ^ARENA:arena -- delete-outcome )
   {: x:deletion ar:^ARENA:arena :}
   x DELETION-UNMAKE {: dir:fd n:str t:str g:str gp:str want:DROPBOX:hash :}
   dir n t s" check delete precondition" ar HASH-AT-IF-PRESENT
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
   ( fd str str str str DROPBOX:hash ^ARENA:arena -- deletion )
   {: f:fd tn:str rel:str r:str t:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   s" deleted" t want ar INTERNAL-NAME {: g:str :}
   r rel ar JOIN g ar JOIN {: gp:str :}
   f tn t g gp want DELETION-MAKE ;

\ The delete in the open parent, which closes after it; r is the root's
\ path, which failures name.
: DELETE-BELOW
   ( parent-dir str str DROPBOX:hash ^ARENA:arena -- delete-outcome )
   {: pd:parent-dir r:str t:str want:DROPBOX:hash
      ar:^ARENA:arena :}
   pd PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
   [: dir name path r t want ar DELETION-OF ar DELETE-IN ;]
   [: dir DISCARD ;] finally ;

public

\ Rust's delete_local_at: deletes the target below the root, whose path is
\ r, while it holds want. It moves aside under a guard name first, and a
\ guard left by an interrupted attempt is finished or put back.
: DELETE-LOCAL-AT
   ( fd str str DROPBOX:hash ^ARENA:arena -- delete-outcome )
   {: root:fd r:str t:str want:DROPBOX:hash ar:^ARENA:arena :}
   want s" delete local file" REQUIRE-CONTENT-HASH
   root t false OPEN-PARENT MATCH option
      none OF LOCAL-DELETE--OUTCOME:ALREADY-DELETED ENDOF
      some OF r t want ar DELETE-BELOW ENDOF
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
: EXISTING-DIRECTORY ( fd str str -- create-directory-outcome )
   {: dir:fd name:str p:str :}
   dir name FS:TRY-OPEN-DIR-AT MATCH option
      none OF FS:ERRNO {: e:n :}
         e FS:ENOENT = e FS:ENOTDIR = or e FS:ELOOP = or 0= if
            dir name s" inspect occupied local directory path"
            p IO-FAILURE-AT
         then LOCAL-CREATE--DIRECTORY--OUTCOME:FRESH-OBSERVATION
      ENDOF
      some OF {: d:fd :}
         [: d p s" sync existing local directory" SYNC-DIRECTORY ;]
         [: d DISCARD ;] finally
         dir p s" sync existing local directory entry" SYNC-DIRECTORY
         LOCAL-CREATE--DIRECTORY--OUTCOME:ALREADY-PRESENT
      ENDOF
   ;MATCH ;

\ Opens the directory just made at the name in dir and syncs it.
: SYNC-MADE-DIRECTORY ( fd str str -- )
   {: dir:fd name:str p:str :}
   dir name p OPEN-DIRECTORY-AT {: d:fd :}
   [: d p s" sync created local directory" SYNC-DIRECTORY ;]
   [: d DISCARD ;] finally ;

: MAKE-DIRECTORY-IN ( fd str str -- create-directory-outcome )
   {: dir:fd name:str p:str :}
   dir name FS:MODE-PRIVATE-DIR FS:TRY-MAKE-DIR-AT if
      dir p s" sync created local directory entry" SYNC-DIRECTORY
      dir name p SYNC-MADE-DIRECTORY
      LOCAL-CREATE--DIRECTORY--OUTCOME:CREATED exit
   then
   FS:ERRNO FS:EEXIST <> if
      dir name s" create local directory" p IO-FAILURE-AT
   then
   dir name p EXISTING-DIRECTORY ;

\ Whether a failed rmdir found an entry that is not an empty directory.
: OCCUPIED-DIRECTORY? ( n -- bool )
   {: e:n :}
   e FS:ENOTEMPTY = e FS:EEXIST = or e FS:ENOTDIR = or e FS:EISDIR = or ;

: REMOVE-DIRECTORY-IN ( fd str str -- delete-directory-outcome )
   {: dir:fd name:str p:str :}
   dir name FS:TRY-REMOVE-DIR-AT if
      dir p s" sync deleted local directory" SYNC-DIRECTORY
      LOCAL-DELETE--DIRECTORY--OUTCOME:DELETED exit
   then
   FS:ERRNO {: e:n :}
   e FS:ENOENT = if LOCAL-DELETE--DIRECTORY--OUTCOME:ALREADY-ABSENT exit then
   e OCCUPIED-DIRECTORY? if
      LOCAL-DELETE--DIRECTORY--OUTCOME:FRESH-OBSERVATION exit
   then
   dir name s" delete empty local directory" p IO-FAILURE-AT ;

public

\ Makes the directory at p below the root, its missing parents as well;
\ it never follows a link or replaces an entry.
: CREATE-DIRECTORY-AT ( fd str -- create-directory-outcome )
   {: root:fd p:str :}
   root p true OPEN-PARENT MATCH option
      none OF p UNSAFE ENDOF
      some OF PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
         [: dir name p MAKE-DIRECTORY-IN ;] [: dir DISCARD ;]
         finally
      ENDOF
   ;MATCH ;

\ Removes the directory at p below the root only while it is empty.
: DELETE-DIRECTORY-AT ( fd str -- delete-directory-outcome )
   {: root:fd p:str :}
   root p false OPEN-PARENT MATCH option
      none OF LOCAL-DELETE--DIRECTORY--OUTCOME:ALREADY-ABSENT ENDOF
      some OF PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
         [: dir name p REMOVE-DIRECTORY-IN ;] [: dir DISCARD ;]
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
   ( str conflict-side DROPBOX:hash ^ARENA:arena -- str )
   {: p:str side:conflict-side c:DROPBOX:hash ar:^ARENA:arena :}
   p PARENT-PATH p side c ar CONFLICT-NAME ar JOIN ;

private

\ The stage written at the conflict's path rel; another file there is
\ kept.
: CONFLICT-RESULT ( stage-write str -- conflict-outcome )
   {: w:stage-write rel:str :}
   w MATCH stage-write
      created OF rel LOCAL-CONFLICT--OUTCOME:CREATED ENDOF
      reused OF rel LOCAL-CONFLICT--OUTCOME:ALREADY-PRESENT
      ENDOF
      mismatch OF LOCAL-CONFLICT--OUTCOME:CONTENT-CHANGED ENDOF
      destination-occupied OF {: q:str :}
         s" materialize conflict" q OCCUPIED
      ENDOF
   ;MATCH ;

\ The conflict copy written in p's parent dir, its names laid in the
\ arena; r is the root's path.
: CONFLICT-IN
   ( fd str str conflict-side DROPBOX:hash [ ^u8 n -- n ]
     ^ARENA:arena -- conflict-outcome )
   {: dir:fd r:str p:str side:conflict-side want:DROPBOX:hash read
      ar:^ARENA:arena :}
   p side want ar CONFLICT-NAME {: cn:str :}
   p side want ar CONFLICT-RELATIVE-PATH {: rel:str :}
   r rel ar JOIN {: shown:str :}
   STAGE-WRITE-CREATED [: DROP-STAGE-WRITE
      dir cn shown want read NO-MARKER
      s" materialize conflict" ar WRITE-VERIFIED-STAGE ;] LOCAL-ERRORS
   rel CONFLICT-RESULT ;

\ The conflict copy written in the open parent, which closes after it.
: CONFLICT-BELOW
   ( parent-dir str str conflict-side DROPBOX:hash [ ^u8 n -- n ]
     ^ARENA:arena -- conflict-outcome )
   {: pd:parent-dir r:str p:str side:conflict-side
      want:DROPBOX:hash read ar:^ARENA:arena :}
   pd PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
   [: dir r p side want read ar CONFLICT-IN ;]
   [: dir DISCARD ;] finally ;

public

\ Writes read's bytes as p's conflict copy for side below the root, whose
\ path is r, when they hash to want; it never overwrites a file. A failed
\ read throws E-IO.
: MATERIALIZE-CONFLICT-AT
   ( fd str str conflict-side DROPBOX:hash [ ^u8 n -- n ]
     ^ARENA:arena -- conflict-outcome )
   {: root:fd r:str p:str side:conflict-side want:DROPBOX:hash
      read ar:^ARENA:arena :}
   want s" materialize conflict" REQUIRE-CONTENT-HASH
   root p true OPEN-PARENT MATCH option
      none OF p UNSAFE ENDOF
      some OF r p side want read ar CONFLICT-BELOW ENDOF
   ;MATCH ;

\ ---- recovery copies

\ The name of a private recovery copy of p holding c, laid in the arena.
: RECOVERY-FILE-NAME ( str DROPBOX:hash ^ARENA:arena -- str )
   {: p:str c:DROPBOX:hash ar:^ARENA:arena :}
   s" recovery" p c ar INTERNAL-NAME ;

\ Whether the copy at the name in dir, whose path is p, is there; one
\ there holds want and is synced, else it is corrupt.
: VERIFY-PRIVATE-COPY
   ( fd str str DROPBOX:hash ^ARENA:arena -- bool )
   {: dir:fd p:str name:str want:DROPBOX:hash ar:^ARENA:arena :}
   s" verify recovery copy" {: o:str :}
   p name ar JOIN {: at:str :}
   dir name at o ar HASH-AT-IF-PRESENT MATCH option
      none OF false ENDOF
      some OF want SAME-CONTENT? 0= if o at CORRUPT then
         dir name at SYNC-INSTALLED-FILE true
      ENDOF
   ;MATCH ;

\ ---- renames

\ What a non-overwriting rename came to: the observed entry renamed and
\ its parent synced, or a changed source or taken destination to rescan.
ENUM rename-outcome renamed retry ;ENUM

private

\ Whether the safe paths' components from a and from b on are the same,
\ as Rust compares paths.
: SAME-COMPONENTS? ( str n str n -- bool )
   {: p:str a:n q:str b:n :}
   p a NEXT-COMPONENT {: pf:n pt:n more:bool :}
   q b NEXT-COMPONENT {: qf:n qt:n more2:bool :}
   more 0= more2 0= and if true exit then
   more more2 and 0= if false exit then
   p pf pt PART q qf qt PART STR:= 0= if false exit then
   p pt q qt RECURSE ;

: SAME-PARENT? ( str str -- bool )
   {: p:str d:str :}
   p PARENT-PATH 0 d PARENT-PATH 0 SAME-COMPONENTS? ;

: LAST-NAME ( str -- str )
   {: p:str :}
   p SPLIT-LAST {: parent:n from:n to:n :}
   p from to PART ;

\ Whether the failure just seen, ENOENT or the errno other, is a race a
\ rescan retries.
: RACED? ( n -- bool )
   {: other:n :}
   FS:ERRNO FS:ENOENT = FS:ERRNO other = or ;

: RENAMEABLE? ( MODEL:stat bool -- bool )
   {: st:MODEL:stat dirs:bool :}
   st REGULAR? if true exit then
   dirs st DIRECTORY? and ;

\ The probed source held when it is a file, or with dirs a directory;
\ else none, the probe closed.
: KEEP-RENAMEABLE ( fd str bool -- option<fd> )
   {: src:fd p:str dirs:bool :}
   src p s" inspect local rename source type" STAT-CLOSING
   dirs RENAMEABLE? if src OPTION:SOME exit then
   src DISCARD OPTION:NONE ;

\ The source at the name in dir, held by O_PATH without following a
\ symlink; none when it is gone or not an entry dirs allows.
: HELD-SOURCE ( fd str str bool -- option<fd> )
   {: dir:fd name:str p:str dirs:bool :}
   dir name FS:TRY-OPEN-ENTRY-AT MATCH option
      none OF FS:ELOOP RACED? 0= if
            s" inspect local rename source" p IO-FAILURE
         then OPTION:NONE
      ENDOF
      some OF p dirs KEEP-RENAMEABLE ENDOF
   ;MATCH ;

\ The rename hook, its file failures thrown by IO-FAILURE.
: BEFORE-RENAME ( [ -- ] str -- )
   {: hook p:str :}
   hook [: s" rename local entry" p IO-FAILURE ;] FS-FAILS ;

\ Renamed when d's name holds src, the source held open, once dir is
\ synced.
: SETTLE-RENAME ( fd fd str str -- rename-outcome )
   {: src:fd dir:fd dn:str d:str :}
   src dir dn d NAMED-INODE-MATCHES {: held:bool :}
   dir d s" sync local entry rename" SYNC-DIRECTORY
   held if LOCAL-RENAME--OUTCOME:RENAMED exit then
   LOCAL-RENAME--OUTCOME:RETRY ;

\ Renames the name in dir to d's last name unless an entry is there.
: RENAME-NEW ( fd fd str str str -- rename-outcome )
   {: src:fd dir:fd name:str p:str d:str :}
   d LAST-NAME {: dn:str :}
   dir name dir dn FS:TRY-RENAME-NEW-AT if
      src dir dn d SETTLE-RENAME exit
   then
   FS:EEXIST RACED? if LOCAL-RENAME--OUTCOME:RETRY exit then
   dir name s" rename local entry" p IO-FAILURE-AT ;

: RENAME-IN ( fd str str str bool [ -- ] -- rename-outcome )
   {: dir:fd name:str p:str d:str dirs:bool hook :}
   dir name p dirs HELD-SOURCE MATCH option
      none OF LOCAL-RENAME--OUTCOME:RETRY ENDOF
      some OF {: src:fd :}
         [: hook p BEFORE-RENAME
            src dir name p d RENAME-NEW ;]
         [: src DISCARD ;] finally
      ENDOF
   ;MATCH ;

\ RENAME-IN the open parent, which closes after it.
: RENAME-BELOW ( parent-dir str str bool [ -- ] -- rename-outcome )
   {: pd:parent-dir p:str d:str dirs:bool hook :}
   pd PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
   [: dir name p d dirs hook RENAME-IN ;]
   [: dir DISCARD ;] finally ;

\ Renames p below the root to its sibling d, never over an entry: a file,
\ or with dirs a directory. hook runs just before the rename.
: RENAME-CASE-VARIANT-WITH
   ( fd str str bool [ -- ] -- rename-outcome )
   {: root:fd p:str d:str dirs:bool hook :}
   p d SAME-PARENT? 0= if d UNSAFE then
   root p false OPEN-PARENT MATCH option
      none OF LOCAL-RENAME--OUTCOME:RETRY ENDOF
      some OF p d dirs hook RENAME-BELOW ENDOF
   ;MATCH ;

public

\ Renames a local case variant, a file or a directory, to its sibling d.
: RENAME-CASE-VARIANT ( fd str str -- rename-outcome )
   true [: ;] RENAME-CASE-VARIANT-WITH ;

\ Renames a regular file to its synchronized copy name d.
: RENAME-FILE-COPY ( fd str str -- rename-outcome )
   false [: ;] RENAME-CASE-VARIANT-WITH ;

private

: NAME-MAX ( fd str -- n )
   {: dir:fd p:str :}
   0 [: drop dir FS:FD-NAME-MAX ;]
   [: s" inspect parent filename limit" p IO-FAILURE ;] FS-FAILS ;

\ NAME-MAX of the open parent, which closes after it.
: NAME-MAX-BELOW ( parent-dir str -- n )
   {: pd:parent-dir p:str :}
   pd PARENT-DIR-UNMAKE {: dir:fd name:str path:str :}
   [: dir p NAME-MAX ;] [: dir DISCARD ;] finally ;

public

\ The longest name in bytes the filesystem of p's actual parent takes;
\ none when a directory on the way is missing. A zero limit is E-IO.
: PARENT-NAME-MAX ( fd str -- option<n> )
   {: root:fd p:str :}
   root p false OPEN-PARENT MATCH option
      none OF OPTION:NONE ENDOF
      some OF p NAME-MAX-BELOW OPTION:SOME ENDOF
   ;MATCH ;

;package
