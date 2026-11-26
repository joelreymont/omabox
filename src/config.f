\ config.f - package CONFIG: the paths one omabox instance owns and its
\ config.toml, resolved, loaded, written and refused as the Rust version's
\ config.rs does, its state directories prepared and its daemon locked.
\ XDG: XDG_CONFIG_HOME and XDG_STATE_HOME count when absolute, else
\ HOME/.config and HOME/.local/state; HOME is read only then. The config
\ directory, XDG_CONFIG_HOME/omabox, stays lexical. The state directory,
\ XDG_STATE_HOME/omabox, and its journal.sqlite3, upload-staging, recovery
\ and daemon.lock are each projected: the physical path a path has, or will
\ have once its missing components exist. The nearest existing ancestor is
\ canonicalized and the missing components follow it, normalized lexically,
\ so a `..` after a missing component leaves it. A dangling symlink on the
\ way fails the projection, or for a path only compared is followed to
\ where its target would be, at most MAX-HOPS times, then ELOOP.
\ A config holds its private paths only once each, projected, lies outside
\ the physical sync root, which is compared as the dangling-following
\ projection of the canonical root.
\ Paths are Rust's: std::path's components (separators collapse, `.` drops,
\ `..` stays) on bytes kept as spelled until normalized. Every path these
\ words take and make is absolute.
\ config.toml is read as the toml crate (TOML 1.1) reads a struct of two
\ strings that denies unknown fields: an optional BOM, then lines of
\ whitespace, an optional `key = string` and an optional comment, each line
\ ending in LF, CRLF or the end. A key is bare or a basic or literal
\ string; the keys are sync_root and dropbox_app_key, once each; a value is
\ any of the four TOML strings with every TOML escape. Anything else is
\ E-PARSE; a file that is not UTF-8 is E-READ.
\ config.toml is written as toml 0.9.12 writes the stored document: a
\ `sync_root = ` line, then a `dropbox_app_key = ` line, each string in the
\ form toml_writer 1.1.2 picks for it. The text is staged in an owner-only
\ .config.toml.<pid>.<seq>.tmp beside the file, synced, renamed over it
\ (WRITE) or into its place only while none is there (WRITE-NEW), and the
\ directory synced. A failed write removes its temporary; each write first
\ sweeps the temporaries of processes that are gone.
\ A refusal logs two lines, the Rust error's text with the path or field it
\ names and then its help, and throws. E-READ, E-MISSING,
\ E-RESOLVE-SYNC-ROOT, E-INSPECT-PATH, E-CREATE-DIRECTORY,
\ E-SECURE-DIRECTORY, E-LOCK-OPEN, E-LOCK-ACQUIRE, E-DISK-FULL,
\ E-PREPARE-CONFIGURATION-DIRECTORY and E-WRITE leave the host errno in
\ FS:ERRNO, 0 where the Rust error has none; E-CLEANUP-AFTER-WRITE leaves
\ the failed write's; the other codes leave 0. E-MISSING is E-READ on
\ ENOENT, and E-DISK-FULL is E-CREATE-DIRECTORY, E-SECURE-DIRECTORY or
\ E-LOCK-OPEN on ENOSPC.
\ E-CLEANUP-AFTER-WRITE logs the failed write's two lines, then its own.
\ STORAGE CLASS. CALLER-OWNED: every record and path a word answers is laid
\ in the arena its caller passes; a lock's path stays in its paths'.
\ PREPARE-PATHS's projections live in an arena of its own, released on
\ return.
\ A write's text, temporary and leftovers are laid in its caller's arena.
\ TASK-LOCAL: the row realpath and readlink answer into.
\ PROCESS-WIDE: the sequence numbering the temporaries.

require src/lib/error.f
require src/lib/string.f
require src/lib/memory.f
require src/lib/arena.f
require src/lib/adt/option.f
require src/lib/type/deftype.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/fs-lock.f
require src/lib/ffi-abi.f
require src/lib/log.f
require src/lib/task.f
require src/lib/utf8-scalar.f
require src/lib/unicode/class.f
require src/lib/fs-anchored.f
require src/lib/fd.f
require src/lib/fmt.f
require src/lib/vector.f
require src/stale.f

package CONFIG
public

-100200 constant E-FIRST
-100299 constant E-LAST
-100200 s" HOME is not set" ERROR:CODE E-HOME-UNAVAILABLE
-100201 s" a configuration path is not absolute"
   ERROR:CODE E-PATH-NOT-ABSOLUTE
-100202 s" could not read Omabox configuration" ERROR:CODE E-READ
-100203 s" could not parse Omabox configuration" ERROR:CODE E-PARSE
-100204 s" Dropbox application key is empty"
   ERROR:CODE E-EMPTY-APP-KEY
-100205 s" could not resolve sync root" ERROR:CODE E-RESOLVE-SYNC-ROOT
-100206 s" sync root is not a directory"
   ERROR:CODE E-SYNC-ROOT-NOT-DIRECTORY
-100207 s" could not inspect a path while validating configuration paths"
   ERROR:CODE E-INSPECT-PATH
-100208 s" a protected path is inside the sync root"
   ERROR:CODE E-INSIDE-SYNC-ROOT
-100209 s" could not create an Omabox runtime directory"
   ERROR:CODE E-CREATE-DIRECTORY
-100210 s" could not secure an Omabox runtime directory"
   ERROR:CODE E-SECURE-DIRECTORY
-100211 s" could not open daemon lock file" ERROR:CODE E-LOCK-OPEN
-100212 s" another Omabox daemon is already running"
   ERROR:CODE E-ALREADY-RUNNING
-100213 s" could not acquire daemon lock" ERROR:CODE E-LOCK-ACQUIRE
-100214 s" Omabox configuration does not exist" ERROR:CODE E-MISSING
-100215 s" could not write Omabox state: the disk is full"
   ERROR:CODE E-DISK-FULL
-100216 s" Omabox configuration already exists" ERROR:CODE E-ALREADY-EXISTS
-100217 s" could not serialize Omabox configuration" ERROR:CODE E-SERIALIZE
-100218 s" could not prepare Omabox configuration directory"
   ERROR:CODE E-PREPARE-CONFIGURATION-DIRECTORY
-100219 s" could not write Omabox configuration" ERROR:CODE E-WRITE
-100220 s" the configuration write failed and cleanup also failed"
   ERROR:CODE E-CLEANUP-AFTER-WRITE

\ An absolute path's bytes as Rust's PathBuf holds them.
DEFTYPE ABS-PATH str

\ The XDG base directories, absolute and normalized.
STRUCTURE xdg OPAQUE DERIVE addr
   FIELD config-home abs-path
   FIELD state-home abs-path
;STRUCTURE

\ The paths an instance owns: config lexical, the rest projected.
STRUCTURE paths OPAQUE DERIVE addr
   FIELD config abs-path
   FIELD state abs-path
   FIELD journal abs-path
   FIELD staging abs-path
   FIELD recovery abs-path
   FIELD lock abs-path
;STRUCTURE

\ The stored settings: the root absolute and normalized but unresolved,
\ the key more than whitespace.
STRUCTURE document OPAQUE DERIVE addr
   FIELD sync-root abs-path
   FIELD dropbox-app-key str
;STRUCTURE

\ The canonical root, the key, and paths that lie outside the root.
STRUCTURE config OPAQUE DERIVE addr
   FIELD sync-root abs-path
   FIELD dropbox-app-key str
   FIELD paths ^paths
;STRUCTURE

\ A held daemon lock: the descriptor carrying the flock, and its file.
STRUCTURE lock OPAQUE
   FIELD fd fd
   FIELD file abs-path
;STRUCTURE

private

ARENA XDGS xdg
ARENA PATH-SETS paths
ARENA DOCUMENTS document
ARENA CONFIGS config

ENUM path-role configuration state journal staging recovery daemon-lock ;ENUM
ENUM dangling refuse follow ;ENUM
ENUM component root normal parent ;ENUM

ENUM projection
   VARIANT physical FIELD at abs-path ;VARIANT
   VARIANT followed FIELD next abs-path ;VARIANT
;ENUM

\ Linux's MAXSYMLINKS.
40 constant MAX-HOPS
4 constant EINTR
4096 constant CHUNK

FS:PATHZ-CAP TASK:+USERS LINK-ROW u8

: ROW ( -- ^u8 ) 0 LINK-ROW ;


\ ---- strings and paths

: ABSOLUTE? ( str -- bool )
   str> {: a:^ u:n :}
   u 0= if false exit then
   a c@ FS:SLASH = ;

\ The last separator in a[from..u), else -1.
: LAST-SLASH ( ^u8 n n -- n )
   {: a:^ from:n u:n :}
   u begin dup from > while
      1 - dup a + c@ FS:SLASH = if exit then
   repeat drop -1 ;

\ The first separator in a[from..u), else u.
: NEXT-SLASH ( ^u8 n n -- n )
   {: a:^ u:n from:n :}
   from begin dup u < while
      dup a + c@ FS:SLASH = if exit then
      1 +
   repeat ;

\ An empty or `.` component, which std::path skips.
: SKIPPED? ( ^u8 n -- bool )
   {: c:^ cu:n :}
   cu 0= if true exit then
   cu 1 = c c@ FS:DOT = and ;

: DOTS? ( ^u8 n -- bool )
   {: c:^ cu:n :}
   cu 2 <> if false exit then
   c c@ FS:DOT = c 1 + c@ FS:DOT = and ;

\ For an absolute a u past its root: the length left before its last
\ separator-led piece, and where that piece starts.
: SPLIT ( ^u8 n -- n n )
   {: a:^ u:n :}
   a 1 u LAST-SLASH {: j:n :}
   j 0 < if 1 1 else j j 1 + then ;

\ The last component of an absolute path as Components::next_back reads
\ it: the length left before it, its kind and its bytes.
: BACK ( ^u8 n -- n component ^u8 n )
   {: a:^ u:n :}
   u 1 <= if 0 COMPONENT-ROOT a 0 exit then
   a u SPLIT {: rest:n start:n :}
   a start + u start - {: c:^ cu:n :}
   c cu SKIPPED? if a rest RECURSE exit then
   c cu DOTS? if rest COMPONENT-PARENT c cu exit then
   rest COMPONENT-NORMAL c cu ;

\ Trailing separators and `.` dropped.
: TRIM ( ^u8 n -- n )
   {: a:^ u:n :}
   u 1 <= if u exit then
   a u SPLIT {: rest:n start:n :}
   a start + u start - SKIPPED? if a rest RECURSE exit then
   u ;

\ The parent's length of an absolute path below the root.
: POP ( ^u8 n -- n )
   {: a:^ u:n :}
   a u BACK 2drop drop {: rest:n :}
   a rest TRIM ;

: ROOT? ( component -- bool )
   MATCH component
      root OF true ENDOF
      normal OF false ENDOF
      parent OF false ENDOF
   ;MATCH ;

\ 1 when a separator must come between a and a pushed name, else 0.
: SEP ( ^u8 n -- n )
   {: a:^ u:n :}
   u 0= if 0 exit then
   a u + 1 - c@ FS:SLASH = if 0 else 1 then ;

\ An absolute name replaces the base.
: JOIN ( abs-path str ^ARENA:arena -- abs-path )
   {: base name ar :}
   name ABSOLUTE? if name ar ARENA:COPY >ABS-PATH exit then
   base ABS-PATH>STR str> {: b:^ bu:n :}
   name str> {: n:^ nu:n :}
   b bu SEP {: sep:n :}
   ar bu sep + nu + ARENA:ALLOC drop {: d:^ :}
   b d bu BYTE-COPY
   sep 0<> if FS:SLASH d bu + c! then
   n d bu + sep + nu BYTE-COPY
   d bu sep + nu + >str >ABS-PATH ;

\ The path with each component of a u pushed after it.
: PUSH-ALL ( abs-path ^u8 n ^ARENA:arena -- abs-path )
   {: p a:^ u:n ar :}
   p 0 begin dup u < while
      {: q:abs-path at:n :}
      a u at NEXT-SLASH {: k:n :}
      a at + k at - {: c:^ cu:n :}
      c cu SKIPPED? if q else q c cu >str ar JOIN then
      k 1 +
   repeat drop ;

\ The parent's length of normalized o ol, never past the root.
: UP ( ^u8 n -- n )
   {: o:^ ol:n :}
   o 1 ol LAST-SLASH {: j:n :}
   j 0 < if 1 else j then ;

\ Component c pushed onto normalized o ol: the new length.
: STEP ( ^u8 n ^u8 n -- n )
   {: o:^ ol:n c:^ cu:n :}
   c cu SKIPPED? if ol exit then
   c cu DOTS? if o ol UP exit then
   ol 1 > if FS:SLASH o ol + c! ol 1 + else ol then {: at:n :}
   c o at + cu BYTE-COPY
   at cu + ;

\ The root, then each component, `..` popping.
: NORMALIZE ( str ^ARENA:arena -- abs-path )
   {: s ar :}
   s str> {: a:^ u:n :}
   ar u 1 + ARENA:ALLOC drop {: o:^ :}
   FS:SLASH o c!
   1 1 begin dup u < while
      {: ol:n at:n :}
      a u at NEXT-SLASH {: k:n :}
      o ol a at + k at - STEP
      k 1 +
   repeat drop
   o swap >str >ABS-PATH ;

\ Whether normalized p is root or below it.
: INSIDE? ( abs-path abs-path -- bool )
   {: p root :}
   p ABS-PATH>STR str> {: a:^ u:n :}
   root ABS-PATH>STR {: r :}
   r STR:len {: ru:n :}
   ru 1 = if true exit then
   u ru < if false exit then
   a ru >str r STR:= 0= if false exit then
   u ru = if true exit then
   a ru + c@ FS:SLASH = ;


\ ---- refusals

: LOG-OPEN ( -- ) LOG:ERROR s" config" LOG:LINE ;

: QUOTED+ ( abs-path -- )
   s" `" LOG:TEXT+ ABS-PATH>STR LOG:TEXT+ s" `" LOG:TEXT+ ;

\ Ends the error's line and opens its help line with the text.
: HELP ( str -- )
   {: h :}
   LOG:;LINE LOG-OPEN s" help: " LOG:TEXT+ h LOG:TEXT+ ;

\ Ends the help line, then throws code with cause as FS:ERRNO.
: FAIL ( n n -- )
   {: code:n cause:n :}
   LOG:;LINE cause FS:CAUSE! code throw ;

: HOME-UNAVAILABLE ( -- )
   LOG-OPEN s" HOME is not set" LOG:TEXT+
   s" Set HOME, or set both XDG_CONFIG_HOME and XDG_STATE_HOME" HELP
   s"  to absolute paths." LOG:TEXT+
   E-HOME-UNAVAILABLE 0 FAIL ;

\ The name of the variable or key, and the path it held.
: NOT-ABSOLUTE ( str str -- )
   {: name s :}
   LOG-OPEN name LOG:TEXT+
   s"  must be an absolute path, but was " LOG:TEXT+ s >ABS-PATH QUOTED+
   s" Use an absolute path so the unattended service resolves it" HELP
   s"  consistently." LOG:TEXT+
   E-PATH-NOT-ABSOLUTE 0 FAIL ;

\ The cause is FS:ERRNO's on entry, as for every refusal below with one.
: READ-FAILED ( abs-path -- )
   {: p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not read Omabox configuration at " LOG:TEXT+
   p QUOTED+
   s" Create a readable file containing an absolute `sync_root`" HELP
   s"  and a `dropbox_app_key`." LOG:TEXT+
   cause FS:ENOENT = if E-MISSING else E-READ then cause FAIL ;

: PARSE-FAILED ( abs-path -- )
   {: p :}
   LOG-OPEN s" could not parse Omabox configuration at " LOG:TEXT+
   p QUOTED+
   s" The file may contain only `sync_root` and `dropbox_app_key`;" HELP
   s"  credentials do not belong in configuration." LOG:TEXT+
   E-PARSE 0 FAIL ;

: EMPTY-APP-KEY ( -- )
   LOG-OPEN s" Dropbox application key is empty" LOG:TEXT+
   s" Set `dropbox_app_key` to the public app key from the Dropbox" HELP
   s"  developer console." LOG:TEXT+
   E-EMPTY-APP-KEY 0 FAIL ;

: RESOLVE-FAILED ( abs-path -- )
   {: p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not resolve sync root " LOG:TEXT+ p QUOTED+
   s" Create the sync root as a local directory and ensure it is" HELP
   s"  accessible." LOG:TEXT+
   E-RESOLVE-SYNC-ROOT cause FAIL ;

: NOT-DIRECTORY ( abs-path -- )
   {: p :}
   LOG-OPEN s" sync root " LOG:TEXT+ p QUOTED+
   s"  is not a directory" LOG:TEXT+
   s" Set `sync_root` to an existing local directory." HELP
   E-SYNC-ROOT-NOT-DIRECTORY 0 FAIL ;

: INSPECT-FAILED ( abs-path -- )
   {: p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not inspect " LOG:TEXT+ p QUOTED+
   s"  while validating configuration paths" LOG:TEXT+
   s" Ensure every parent directory is accessible and retry." HELP
   E-INSPECT-PATH cause FAIL ;

: ROLE$ ( path-role -- str )
   MATCH path-role
      configuration OF s" configuration directory" ENDOF
      state OF s" state directory" ENDOF
      journal OF s" journal" ENDOF
      staging OF s" upload staging directory" ENDOF
      recovery OF s" recovery directory" ENDOF
      daemon-lock OF s" daemon lock" ENDOF
   ;MATCH ;

\ The XDG variable that places the role's path.
: XDG-VARIABLE$ ( path-role -- str )
   MATCH path-role
      configuration OF s" XDG_CONFIG_HOME" ENDOF
      state OF s" XDG_STATE_HOME" ENDOF
      journal OF s" XDG_STATE_HOME" ENDOF
      staging OF s" XDG_STATE_HOME" ENDOF
      recovery OF s" XDG_STATE_HOME" ENDOF
      daemon-lock OF s" XDG_STATE_HOME" ENDOF
   ;MATCH ;

: INSIDE-ROOT ( path-role abs-path abs-path -- )
   {: role p root :}
   LOG-OPEN role ROLE$ LOG:TEXT+ s"  " LOG:TEXT+ p QUOTED+
   s"  must not be inside sync root " LOG:TEXT+ root QUOTED+
   s" Set " HELP role XDG-VARIABLE$ LOG:TEXT+
   s"  to a local directory outside the sync root." LOG:TEXT+
   E-INSIDE-SYNC-ROOT 0 FAIL ;

: REQUIRE-ABSOLUTE ( str str ^ARENA:arena -- abs-path )
   {: name s ar :}
   s ABSOLUTE? 0= if name s NOT-ABSOLUTE then
   s ar NORMALIZE ;


\ ---- the host's answers

\ Whether the kernel can take the path; if not, FS:ERRNO holds why, as
\ Rust's: ENAMETOOLONG past PATH-CAP, 0 for a NUL byte.
: PASSABLE? ( str -- bool )
   str> {: a:^ u:n :}
   u PATH-CAP > if FS:ENAMETOOLONG FS:CAUSE! false exit then
   u 0 ?do a i + c@ 0= if 0 FS:CAUSE! false unloop exit then loop
   true ;

\ lstat into FS's stat buffer; false leaves the cause in FS:ERRNO.
: LSTAT? ( ^u8 n -- bool )
   {: a:^ u:n :}
   a u >str PASSABLE? 0= if false exit then
   a u >str FS:TRY-LSTAT ;

\ realpath, laid in the arena; none leaves the cause in FS:ERRNO.
: CANONICAL ( str ^ARENA:arena -- option<abs-path> )
   {: s ar :}
   s PASSABLE? 0= if OPTION:NONE exit then
   s FS:>PATHZ ROW FS:PATHZ-CAP realpath {: u:n :}
   u -2 = if FS:ENAMETOOLONG FS:CAUSE! OPTION:NONE exit then
   u 0 < if FFI:ERRNO FS:CAUSE! OPTION:NONE exit then
   ROW u >str ar ARENA:COPY >ABS-PATH OPTION:SOME ;

public

\ readlink, laid in the arena; none leaves the cause in FS:ERRNO.
: READLINK ( str ^ARENA:arena -- option<str> )
   {: s ar :}
   s PASSABLE? 0= if OPTION:NONE exit then
   s FS:>PATHZ ROW FS:PATHZ-CAP readlink {: u:n :}
   u 0 < if OPTION:NONE exit then
   ROW u >str ar ARENA:COPY OPTION:SOME ;

private

\ open for reading, as Rust's File::open: the descriptor, or E-READ.
: OPENED ( abs-path -- n )
   {: p :}
   p ABS-PATH>STR PASSABLE? 0= if p READ-FAILED then
   p ABS-PATH>STR FS:>PATHZ 0 0 open {: fd:n :}
   fd 0 < if p READ-FAILED then
   fd ;

\ b, or a copy twice as large once len fills cap: the buffer and its cap.
: GROWN ( ^u8 n n ^ARENA:arena -- ^u8 n )
   {: b:^ len:n cap:n ar :}
   len cap < if b cap exit then
   ar cap 2 * ARENA:ALLOC drop {: d:^ :}
   b d len BYTE-COPY
   d cap 2 * ;

\ fd read to its end into the arena, or E-READ.
: READ-TO-END ( abs-path n ^ARENA:arena -- str )
   {: p fd:n ar :}
   ar CHUNK ARENA:ALLOC drop 0 CHUNK
   begin
      {: b:^ len:n cap:n :}
      b len cap ar GROWN {: d:^ dcap:n :}
      fd d len + dcap len - read {: got:n :}
      got 0= if d len >str exit then
      got 0 < if FS:ERRNO EINTR <> if p READ-FAILED then then
      d len got 0 max + dcap
   again ;

: DRAIN ( abs-path n ^ARENA:arena -- str )
   {: p fd:n ar :}
   [: p fd ar READ-TO-END ;] [: fd close ;] finally ;

\ The whole file as UTF-8, or E-READ.
: READ-FILE ( abs-path ^ARENA:arena -- str )
   {: p ar :}
   p p OPENED ar DRAIN {: s :}
   s UTF8:VALID? 0= if 0 FS:CAUSE! p READ-FAILED then
   s ;


\ ---- projection

: FOLLOW? ( dangling -- bool )
   MATCH dangling
      refuse OF false ENDOF
      follow OF true ENDOF
   ;MATCH ;

\ A missing a[0..e): its parent's length; ENOENT is the only miss.
: MISSING ( ^u8 n abs-path -- n )
   {: a:^ e:n p :}
   FS:ERRNO FS:ENOENT <> if a e >str >ABS-PATH INSPECT-FAILED then
   a e BACK 2drop {: rest:n kind:component :}
   kind ROOT? if 0 FS:CAUSE! p INSPECT-FAILED then
   a rest TRIM ;

\ The canonical path with the components of the missing suffix after it.
: PHYSICAL ( abs-path ^u8 n ^ARENA:arena -- projection )
   {: c s:^ su:n ar :}
   c s su ar PUSH-ALL ABS-PATH>STR ar NORMALIZE PROJECTION-PHYSICAL ;

\ The dangling symlink a[0..e) followed: its target from its parent,
\ the missing suffix after it.
: FOLLOWED ( ^u8 n n ^ARENA:arena -- projection )
   {: a:^ u:n e:n ar :}
   a e >str ar READLINK MATCH option
      none OF a e >str >ABS-PATH INSPECT-FAILED ENDOF
      some OF ENDOF
   ;MATCH {: target :}
   a a e POP >str >ABS-PATH target ar JOIN
   a e + u e - ar PUSH-ALL PROJECTION-FOLLOWED ;

\ a[0..e) exists, the lstat just made says so: canonicalize it.
: RESOLVED ( ^u8 n n dangling ^ARENA:arena -- projection )
   {: a:^ u:n e:n d ar :}
   FS:STAT-MODE@ FS:S-IFMT and FS-ABI:S-IFLNK = {: link:bool :}
   a e >str ar CANONICAL MATCH option
      some OF a e + u e - ar PHYSICAL ENDOF
      none OF
         FS:ERRNO FS:ENOENT = link and d FOLLOW? and if
            a u e ar FOLLOWED
         else a e >str >ABS-PATH INSPECT-FAILED then
      ENDOF
   ;MATCH ;

\ The nearest existing ancestor, resolved.
: PROJECT-ONCE ( abs-path dangling ^ARENA:arena -- projection )
   {: p d ar :}
   p ABS-PATH>STR str> {: a:^ u:n :}
   u begin dup a swap LSTAT? 0= while
      {: e:n :}
      a e p MISSING
   repeat {: e:n :}
   a u e d ar RESOLVED ;

: PROJECT-HOPS ( abs-path abs-path dangling n ^ARENA:arena -- abs-path )
   {: p at d hops:n ar :}
   at d ar PROJECT-ONCE MATCH projection
      physical OF ENDOF
      followed OF {: next :}
         hops MAX-HOPS >= if FS:ELOOP FS:CAUSE! p INSPECT-FAILED then
         p next d hops 1 + ar RECURSE
      ENDOF
   ;MATCH ;

: PROJECT ( abs-path dangling ^ARENA:arena -- abs-path )
   {: p d ar :}
   p p d 0 ar PROJECT-HOPS ;

\ The canonical root, a directory.
: CANONICAL-ROOT ( abs-path ^ARENA:arena -- abs-path )
   {: root ar :}
   root ABS-PATH>STR ar CANONICAL MATCH option
      none OF root RESOLVE-FAILED ENDOF
      some OF ENDOF
   ;MATCH {: c :}
   c ABS-PATH>STR FS:TRY-STAT 0= if root RESOLVE-FAILED then
   FS:STAT-MODE@ FS:S-IFMT and FS:S-IFDIR <> if
      root NOT-DIRECTORY
   then
   c ;


\ ---- XDG and the private paths

\ A configured home counts when absolute.
: VALID-HOME ( option<str> ^ARENA:arena -- option<abs-path> )
   {: o ar :}
   o MATCH option
      none OF OPTION:NONE ENDOF
      some OF {: s :}
         s ABSOLUTE? if s ar NORMALIZE OPTION:SOME
         else OPTION:NONE then
      ENDOF
   ;MATCH ;

: HOME ( option<str> ^ARENA:arena -- abs-path )
   {: o ar :}
   o MATCH option
      none OF HOME-UNAVAILABLE ENDOF
      some OF {: s :} s" HOME" s ar REQUIRE-ABSOLUTE ENDOF
   ;MATCH ;

\ The configured home, else HOME's sub.
: OR-HOME ( option<abs-path> option<str> str ^ARENA:arena -- abs-path )
   {: dir home sub ar :}
   dir MATCH option
      some OF ENDOF
      none OF home ar HOME sub ar JOIN ENDOF
   ;MATCH ;

\ From HOME, XDG_CONFIG_HOME and XDG_STATE_HOME.
: RESOLVE-XDG ( option<str> option<str> option<str> ^ARENA:arena -- ^xdg )
   {: home config state ar :}
   config ar VALID-HOME {: ch :}
   state ar VALID-HOME {: sh :}
   ar XDGS-NEW {: x :}
   ch home s" .config" ar OR-HOME x XDG-CONFIG-HOME !
   sh home s" .local/state" ar OR-HOME x XDG-STATE-HOME !
   x ;

: ENV ( str -- option<str> )
   GETENV {: v :}
   v STR:data NULL-PTR = if OPTION:NONE else v OPTION:SOME then ;

: XDG-CONFIG-DIRECTORY ( ^xdg ^ARENA:arena -- abs-path )
   {: x ar :}
   x XDG-CONFIG-HOME @ s" omabox" ar JOIN ;

: XDG-STATE-DIRECTORY ( ^xdg ^ARENA:arena -- abs-path )
   {: x ar :}
   x XDG-STATE-HOME @ s" omabox" ar JOIN ;

\ A file or directory of the state directory, projected.
: PRIVATE-PATH ( abs-path str ^ARENA:arena -- abs-path )
   {: state name ar :}
   state name ar JOIN DANGLING-REFUSE ar PROJECT ;

: ROLE-PATH ( ^paths path-role -- abs-path )
   {: p role :}
   role MATCH path-role
      configuration OF p PATHS-CONFIG @ ENDOF
      state OF p PATHS-STATE @ ENDOF
      journal OF p PATHS-JOURNAL @ ENDOF
      staging OF p PATHS-STAGING @ ENDOF
      recovery OF p PATHS-RECOVERY @ ENDOF
      daemon-lock OF p PATHS-LOCK @ ENDOF
   ;MATCH ;

\ One private path outside the physical root.
: OUTSIDE-AS ( ^paths abs-path abs-path path-role ^ARENA:arena -- )
   {: p root physical role ar :}
   p role ROLE-PATH {: at :}
   at DANGLING-REFUSE ar PROJECT physical INSIDE? if
      role at root INSIDE-ROOT
   then ;

\ Every private path outside the root.
: OUTSIDE ( ^paths abs-path ^ARENA:arena -- )
   {: p root ar :}
   root DANGLING-FOLLOW ar PROJECT {: ph :}
   p root ph PATH-ROLE-CONFIGURATION ar OUTSIDE-AS
   p root ph PATH-ROLE-STATE ar OUTSIDE-AS
   p root ph PATH-ROLE-JOURNAL ar OUTSIDE-AS
   p root ph PATH-ROLE-STAGING ar OUTSIDE-AS
   p root ph PATH-ROLE-RECOVERY ar OUTSIDE-AS
   p root ph PATH-ROLE-DAEMON-LOCK ar OUTSIDE-AS ;


\ ---- config.toml

\ The reader of one file's text: pos is the cursor, out and len the
\ string being decoded, root and key the values read.
STRUCTURE reader DERIVE addr
   FIELD file abs-path
   FIELD text str
   FIELD pos n
   FIELD out ^u8
   FIELD len n
   FIELD root option<str>
   FIELD key option<str>
   FIELD arena ^ARENA:arena
;STRUCTURE

ARENA READERS reader

\ The byte k past the cursor, -1 past the end.
: BYTE ( ^reader n -- n )
   {: r k:n :}
   r READER-TEXT @ str> {: a:^ u:n :}
   r READER-POS @ k + {: at:n :}
   at u < if a at + c@ else -1 then ;

: PEEK ( ^reader -- n ) 0 BYTE ;

: SKIP ( ^reader n -- )
   {: r k:n :}
   r READER-POS @ k + r READER-POS ! ;

: BAD ( ^reader -- ) READER-FILE @ PARSE-FAILED ;

\ Room for a string decoded from the rest of the text, which no
\ decoding outgrows.
: FRESH ( ^reader -- )
   {: r :}
   r READER-TEXT @ str> nip r READER-POS @ - {: room:n :}
   r READER-ARENA @ room ARENA:ALLOC drop r READER-OUT !
   0 r READER-LEN ! ;

: EMIT ( ^reader n -- )
   {: r b:n :}
   b r READER-OUT @ r READER-LEN @ + c!
   r READER-LEN @ 1 + r READER-LEN ! ;

: TAKEN ( ^reader -- str )
   {: r :}
   r READER-OUT @ r READER-LEN @ >str ;

: IN? ( n n n -- bool )
   {: b:n lo:n hi:n :}
   b lo >= b hi <= and ;

\ wschar: space or tab.
: WS? ( n -- bool )
   {: b:n :}
   b $20 = b 9 = or ;

\ non-eol: what a comment holds.
: NON-EOL? ( n -- bool )
   {: b:n :}
   b 9 = b $20 $7E IN? or b $80 >= or ;

: LITERAL-CHAR? ( n -- bool )
   {: b:n :}
   b 9 = b $20 $26 IN? or b $28 $7E IN? or b $80 >= or ;

\ basic-unescaped.
: BASIC-CHAR? ( n -- bool )
   {: b:n :}
   b WS? b $21 = or b $23 $5B IN? or b $5D $7E IN? or b $80 >= or ;

: ONE-OF? ( n str -- bool )
   str> {: b:n a:^ u:n :}
   u 0 ?do a i + c@ b = if true unloop exit then loop
   false ;

\ Where the lexer ends a bare key.
: ATOM-END? ( n -- bool )
   {: b:n :}
   b -1 = if true exit then
   b S\" .=,[]{} \t#\r\n" ONE-OF? ;

\ The newline at the cursor: 1 for LF, 2 for CRLF, else 0.
: NEWLINE ( ^reader -- n )
   {: r :}
   r PEEK $0A = if 1 exit then
   r PEEK $0D = r 1 BYTE $0A = and if 2 exit then
   0 ;

: SKIP-WS ( ^reader -- )
   {: r :}
   begin r PEEK WS? while r 1 SKIP repeat ;

\ A line's end: a newline or the end of the text.
: LINE-END ( ^reader -- )
   {: r :}
   r PEEK -1 = if exit then
   r NEWLINE {: k:n :}
   k 0= if r BAD then
   r k SKIP ;

: COMMENT-BYTE? ( n -- bool )
   {: b:n :}
   b -1 <> b $0A <> and b $0D <> and ;

: COMMENT ( ^reader -- )
   {: r :}
   r 1 SKIP
   begin r PEEK COMMENT-BYTE? while
      r PEEK NON-EOL? 0= if r BAD then
      r 1 SKIP
   repeat ;

\ The byte a one-letter escape stands for, else -1.
: SIMPLE ( n -- n )
   case
      $62 of 8 endof
      $65 of $1B endof
      $66 of $0C endof
      $6E of $0A endof
      $72 of $0D endof
      $74 of 9 endof
      $5C of $5C endof
      $22 of $22 endof
      -1 swap
   endcase ;

\ The digits of a hex escape: 2 for \x, 4 for \u, 8 for \U, else 0.
: HEX-WIDTH ( n -- n )
   case
      $78 of 2 endof
      $75 of 4 endof
      $55 of 8 endof
      0 swap
   endcase ;

: DIGIT ( n -- n )
   {: b:n :}
   b $30 $39 IN? if b $30 - exit then
   b $41 $46 IN? if b $37 - exit then
   b $61 $66 IN? if b $57 - exit then
   -1 ;

\ Exactly w hex digits at the cursor: their value.
: HEX ( ^reader n -- n )
   {: r w:n :}
   0 w 0 ?do
      {: v:n :}
      r i BYTE DIGIT {: d:n :}
      d 0 < if r BAD then
      v 16 * d +
   loop
   r w SKIP ;

: CONT ( n -- n ) $3F and $80 or ;

\ A Unicode scalar value's UTF-8.
: SCALAR ( ^reader n -- )
   {: r v:n :}
   v $D800 $DFFF IN? v $10FFFF > or if r BAD then
   v $80 < if r v EMIT exit then
   v $800 < if
      r v 6 rshift $C0 or EMIT r v CONT EMIT exit
   then
   v $10000 < if
      r v 12 rshift $E0 or EMIT
      r v 6 rshift CONT EMIT r v CONT EMIT exit
   then
   r v 18 rshift $F0 or EMIT r v 12 rshift CONT EMIT
   r v 6 rshift CONT EMIT r v CONT EMIT ;

\ escape-seq-char, the cursor past the backslash.
: ESCAPE ( ^reader -- )
   {: r :}
   r PEEK SIMPLE {: c:n :}
   c 0 >= if r c EMIT r 1 SKIP exit then
   r PEEK HEX-WIDTH {: w:n :}
   w 0= if r BAD then
   r 1 SKIP
   r r w HEX SCALAR ;

\ basic-string, the cursor at its quote.
: BASIC ( ^reader -- str )
   {: r :}
   r FRESH r 1 SKIP
   begin r PEEK $22 <> while
      r PEEK {: b:n :}
      b $5C = if r 1 SKIP r ESCAPE else
         b BASIC-CHAR? 0= if r BAD then
         r b EMIT r 1 SKIP
      then
   repeat
   r 1 SKIP r TAKEN ;

\ literal-string, the cursor at its apostrophe.
: LITERAL ( ^reader -- str )
   {: r :}
   r FRESH r 1 SKIP
   begin r PEEK $27 <> while
      r PEEK LITERAL-CHAR? 0= if r BAD then
      r r PEEK EMIT r 1 SKIP
   repeat
   r 1 SKIP r TAKEN ;

\ How many bytes q run from the cursor.
: RUN ( ^reader n -- n )
   {: r q:n :}
   0 begin dup r swap BYTE q = while 1 + repeat ;

: EMITS ( ^reader n n -- )
   {: r b:n k:n :}
   k 0 ?do r b EMIT loop ;

\ A run of k delimiter bytes q: up to two are content, and 3 to 5 end
\ the multi-line string after k-3 more; true when it ended.
: QUOTES ( ^reader n -- bool )
   {: r q:n :}
   r q RUN {: k:n :}
   k 5 > if r BAD then
   k 3 >= if r q k 3 - EMITS r k SKIP true exit then
   r q k EMITS r k SKIP false ;

\ A newline right after the opening delimiter is dropped.
: OPENING ( ^reader -- )
   {: r :}
   r r NEWLINE SKIP ;

\ A CR in a multi-line string: a CRLF kept as it is.
: CRLF ( ^reader -- )
   {: r :}
   r 1 BYTE $0A <> if r BAD then
   r $0D EMIT r $0A EMIT r 2 SKIP ;

\ Whether a space, tab or newline was skipped; a lone CR is refused.
: BLANK? ( ^reader -- bool )
   {: r :}
   r PEEK {: b:n :}
   b WS? b $0A = or if r 1 SKIP true exit then
   b $0D <> if false exit then
   r 1 BYTE $0A <> if r BAD then
   r 2 SKIP true ;

\ mlb-escaped-nl past the backslash: ws, a newline, then every blank.
: ESCAPED-NL ( ^reader -- )
   {: r :}
   r SKIP-WS
   r NEWLINE {: k:n :}
   k 0= if r BAD then
   r k SKIP
   begin r BLANK? 0= until ;

: ML-ESCAPE ( ^reader -- )
   {: r :}
   r PEEK {: b:n :}
   b WS? b $0A = or b $0D = or if r ESCAPED-NL exit then
   r ESCAPE ;

\ One step of a multi-line basic string: true when it ended.
: ML-BASIC-STEP ( ^reader -- bool )
   {: r :}
   r PEEK {: b:n :}
   b $22 = if r $22 QUOTES exit then
   b $5C = if r 1 SKIP r ML-ESCAPE false exit then
   b $0A = if r b EMIT r 1 SKIP false exit then
   b $0D = if r CRLF false exit then
   b BASIC-CHAR? 0= if r BAD then
   r b EMIT r 1 SKIP false ;

\ One step of a multi-line literal string: true when it ended.
: ML-LITERAL-STEP ( ^reader -- bool )
   {: r :}
   r PEEK {: b:n :}
   b $27 = if r $27 QUOTES exit then
   b $0A = if r b EMIT r 1 SKIP false exit then
   b $0D = if r CRLF false exit then
   b LITERAL-CHAR? 0= if r BAD then
   r b EMIT r 1 SKIP false ;

: ML-BASIC ( ^reader -- str )
   {: r :}
   r FRESH r 3 SKIP r OPENING
   begin r ML-BASIC-STEP until
   r TAKEN ;

: ML-LITERAL ( ^reader -- str )
   {: r :}
   r FRESH r 3 SKIP r OPENING
   begin r ML-LITERAL-STEP until
   r TAKEN ;

: TRIPLE? ( ^reader n -- bool )
   {: r q:n :}
   r PEEK q = r 1 BYTE q = and r 2 BYTE q = and ;

: VALUE ( ^reader -- str )
   {: r :}
   r $22 TRIPLE? if r ML-BASIC exit then
   r PEEK $22 = if r BASIC exit then
   r $27 TRIPLE? if r ML-LITERAL exit then
   r PEEK $27 = if r LITERAL exit then
   r BAD ;

\ A bare key: the lexer's atom, which ASSIGN refuses unless a known key.
: ATOM ( ^reader -- str )
   {: r :}
   r READER-POS @ {: start:n :}
   begin r PEEK ATOM-END? 0= while
      r 1 SKIP
   repeat
   r READER-POS @ start - {: u:n :}
   u 0= if r BAD then
   r READER-TEXT @ str> drop start + u >str ;

: KEY ( ^reader -- str )
   {: r :}
   r PEEK $22 = if r BASIC exit then
   r PEEK $27 = if r LITERAL exit then
   r ATOM ;

\ A value for a slot no earlier line filled.
: SET ( ^reader ^option<str> str -- )
   {: r slot v :}
   slot @ MATCH option
      some OF drop r BAD ENDOF
      none OF v OPTION:SOME slot ! ENDOF
   ;MATCH ;

: ASSIGN ( ^reader str str -- )
   {: r k v :}
   k s" sync_root" STR:= if r r READER-ROOT v SET exit then
   k s" dropbox_app_key" STR:= if r r READER-KEY v SET exit then
   r BAD ;

: KEYVAL ( ^reader -- )
   {: r :}
   r KEY {: k :}
   r SKIP-WS
   r PEEK $3D <> if r BAD then
   r 1 SKIP r SKIP-WS
   r k r VALUE ASSIGN ;

: KEY-START? ( n -- bool )
   {: b:n :}
   b -1 <> b $23 <> and b $0A <> and b $0D <> and ;

: EXPRESSION ( ^reader -- )
   {: r :}
   r SKIP-WS
   r PEEK KEY-START? if r KEYVAL r SKIP-WS then
   r PEEK $23 = if r COMMENT then
   r LINE-END ;

: BOM ( ^reader -- )
   {: r :}
   r PEEK $EF = r 1 BYTE $BB = and r 2 BYTE $BF = and if
      r 3 SKIP
   then ;

: NO-STR ( -- option<str> ) OPTION:NONE ;

\ A slot's value, which the file must hold.
: FILLED ( ^reader ^option<str> -- str )
   {: r slot :}
   slot @ MATCH option
      some OF ENDOF
      none OF r BAD ENDOF
   ;MATCH ;

\ The stored root and key, unchecked.
: READ-DOCUMENT ( ^xdg ^ARENA:arena -- str str )
   {: x ar :}
   x ar XDG-CONFIG-DIRECTORY s" config.toml" ar JOIN {: file :}
   ar READERS-NEW {: r :}
   file r READER-FILE !
   file ar READ-FILE r READER-TEXT !
   ar r READER-ARENA !
   NO-STR r READER-ROOT !
   NO-STR r READER-KEY !
   r BOM
   begin r PEEK -1 <> while r EXPRESSION repeat
   r r READER-ROOT FILLED r r READER-KEY FILLED ;

\ Every scalar Unicode White_Space.
: BLANK-KEY? ( str -- bool )
   {: s :}
   s STR:len {: u:n :}
   0 begin dup u < while
      {: at:n :}
      s at UTF8:NEXT MATCH UTF8:scalar-step
         scalar OF {: cp:n next:n :}
            cp UNICODE-CLASS:WHITE-SPACE? 0= if false exit then
            next
         ENDOF
         raw-byte OF 2drop false exit ENDOF
      ;MATCH
   repeat drop true ;

: CHECKED ( str str ^ARENA:arena -- ^document )
   {: root key ar :}
   s" sync_root" root ar REQUIRE-ABSOLUTE {: p :}
   key BLANK-KEY? if EMPTY-APP-KEY then
   ar DOCUMENTS-NEW {: d :}
   p d DOCUMENT-SYNC-ROOT !
   key ar ARENA:COPY d DOCUMENT-DROPBOX-APP-KEY !
   d ;

public

\ ---- the XDG directories

: XDG-ENV ( ^ARENA:arena -- ^xdg )
   {: ar :}
   s" HOME" ENV s" XDG_CONFIG_HOME" ENV s" XDG_STATE_HOME" ENV
   ar RESOLVE-XDG ;

\ The config home, then the state home.
: XDG-NEW ( abs-path abs-path ^ARENA:arena -- ^xdg )
   {: ch sh ar :}
   s" XDG_CONFIG_HOME" ch ABS-PATH>STR ar REQUIRE-ABSOLUTE {: c :}
   s" XDG_STATE_HOME" sh ABS-PATH>STR ar REQUIRE-ABSOLUTE {: s :}
   ar XDGS-NEW {: x :}
   c x XDG-CONFIG-HOME !
   s x XDG-STATE-HOME !
   x ;

: XDG-CONFIG-FILE ( ^xdg ^ARENA:arena -- abs-path )
   {: x ar :}
   x ar XDG-CONFIG-DIRECTORY s" config.toml" ar JOIN ;

\ XDG_CONFIG_HOME when absolute, else HOME/.config, as Rust's
\ resolve_config_home answers it.
: CONFIG-HOME ( ^xdg -- abs-path ) XDG-CONFIG-HOME @ ;


\ ---- the paths

\ The paths, not checked against a sync root.
: RESOLVE-PRIVATE ( ^xdg ^ARENA:arena -- ^paths )
   {: x ar :}
   x ar XDG-STATE-DIRECTORY {: state :}
   ar PATH-SETS-NEW {: p :}
   x ar XDG-CONFIG-DIRECTORY ABS-PATH>STR ar NORMALIZE p PATHS-CONFIG !
   state DANGLING-REFUSE ar PROJECT p PATHS-STATE !
   state s" journal.sqlite3" ar PRIVATE-PATH p PATHS-JOURNAL !
   state s" upload-staging" ar PRIVATE-PATH p PATHS-STAGING !
   state s" recovery" ar PRIVATE-PATH p PATHS-RECOVERY !
   state s" daemon.lock" ar PRIVATE-PATH p PATHS-LOCK !
   p ;

: CONFIG-DIRECTORY ( ^paths -- abs-path ) PATHS-CONFIG @ ;

: CONFIG-FILE ( ^paths ^ARENA:arena -- abs-path )
   {: p ar :}
   p PATHS-CONFIG @ s" config.toml" ar JOIN ;

: STATE-DIRECTORY ( ^paths -- abs-path ) PATHS-STATE @ ;
: JOURNAL-FILE ( ^paths -- abs-path ) PATHS-JOURNAL @ ;
: UPLOAD-STAGING-DIRECTORY ( ^paths -- abs-path ) PATHS-STAGING @ ;
: RECOVERY-DIRECTORY ( ^paths -- abs-path ) PATHS-RECOVERY @ ;
: LOCK-FILE ( ^paths -- abs-path ) PATHS-LOCK @ ;


\ ---- the document

: DOCUMENT-LOAD-FROM ( ^xdg ^ARENA:arena -- ^document )
   {: x ar :}
   x ar READ-DOCUMENT ar CHECKED ;

: DOCUMENT-LOAD ( ^ARENA:arena -- ^document )
   {: ar :}
   ar XDG-ENV ar DOCUMENT-LOAD-FROM ;

: DOCUMENT-ROOT ( ^document -- abs-path ) DOCUMENT-SYNC-ROOT @ ;
: DOCUMENT-KEY ( ^document -- str ) DOCUMENT-DROPBOX-APP-KEY @ ;


\ ---- the config

\ The document against paths already resolved.
: VALIDATE-WITH ( ^document ^paths ^ARENA:arena -- ^config )
   {: d p ar :}
   d DOCUMENT-SYNC-ROOT @ ar CANONICAL-ROOT {: root :}
   p root ar OUTSIDE
   ar CONFIGS-NEW {: c :}
   root c CONFIG-SYNC-ROOT !
   d DOCUMENT-DROPBOX-APP-KEY @ c CONFIG-DROPBOX-APP-KEY !
   p c CONFIG-PATHS !
   c ;

: VALIDATE ( ^document ^xdg ^ARENA:arena -- ^config )
   {: d x ar :}
   d x ar RESOLVE-PRIVATE ar VALIDATE-WITH ;

: LOAD-FROM ( ^xdg ^ARENA:arena -- ^config )
   {: x ar :}
   x ar DOCUMENT-LOAD-FROM x ar VALIDATE ;

: LOAD ( ^ARENA:arena -- ^config )
   {: ar :}
   ar XDG-ENV ar LOAD-FROM ;

\ A root and key a setup or settings command supplies; the root is
\ refused, as a stored one is, unless absolute.
: FROM-VALUES ( ^xdg str str ^ARENA:arena -- ^config )
   {: x root key ar :}
   root key ar CHECKED x ar VALIDATE ;

: SYNC-ROOT ( ^config -- abs-path ) CONFIG-SYNC-ROOT @ ;
: APP-KEY ( ^config -- str ) CONFIG-DROPBOX-APP-KEY @ ;
: PATHS ( ^config -- ^paths ) CONFIG-PATHS @ ;


private

\ ---- the runtime directories and the daemon lock

: MKDIR? ( ^u8 n -- bool )
   {: a:^ u:n :}
   a u >str PASSABLE? 0= if false exit then
   a u >str FS:>PATHZ FS:MODE-PRIVATE-DIR mkdir 0= ;

\ A failed mkdir stands unless a directory is there now, links followed.
: PRESENT? ( ^u8 n -- bool )
   {: a:^ u:n :}
   FS:ERRNO {: cause:n :}
   a u >str FS:TRY-STAT if
      FS:STAT-MODE@ FS:S-IFMT and FS:S-IFDIR = if true exit then
   then
   cause FS:CAUSE! false ;

\ Each missing ancestor made first, mode 0700.
: MAKE-ALL? ( ^u8 n -- bool )
   {: a:^ u:n :}
   a u MKDIR? if true exit then
   FS:ERRNO FS:ENOENT <> if a u PRESENT? exit then
   u 1 <= if 0 FS:CAUSE! false exit then
   a a u POP RECURSE 0= if false exit then
   a u MKDIR? if true exit then
   a u PRESENT? ;

: CREATE-FAILED ( path-role abs-path -- )
   {: role p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not create Omabox " LOG:TEXT+ role ROLE$ LOG:TEXT+
   s"  at " LOG:TEXT+ p QUOTED+
   s" Ensure the XDG state location is writable and has sufficient" HELP
   s"  space." LOG:TEXT+
   cause FS:ENOSPC = if E-DISK-FULL else E-CREATE-DIRECTORY then
   cause FAIL ;

: SECURE-FAILED ( path-role abs-path -- )
   {: role p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not secure Omabox " LOG:TEXT+ role ROLE$ LOG:TEXT+
   s"  at " LOG:TEXT+ p QUOTED+
   s" Ensure the XDG state location is owned by this user and" HELP
   s"  retry." LOG:TEXT+
   cause FS:ENOSPC = if E-DISK-FULL else E-SECURE-DIRECTORY then
   cause FAIL ;

\ One runtime directory made, then set 0700 whatever the umask left.
: MAKE-PRIVATE ( ^paths path-role -- )
   {: p role :}
   p role ROLE-PATH {: at :}
   at ABS-PATH>STR str> {: a:^ u:n :}
   a u MAKE-ALL? 0= if role at CREATE-FAILED then
   a u >str FS:>PATHZ FS:MODE-PRIVATE-DIR chmod 0<> if
      role at SECURE-FAILED
   then ;

\ Checked outside the root again once the directories exist, so a
\ symlinked ancestor cannot redirect them into it unseen.
: PREPARE-IN ( ^paths abs-path ^ARENA:arena -- )
   {: p root ar :}
   p root ar OUTSIDE
   p PATH-ROLE-STATE MAKE-PRIVATE
   p PATH-ROLE-STAGING MAKE-PRIVATE
   p PATH-ROLE-RECOVERY MAKE-PRIVATE
   p root ar OUTSIDE ;

: OPEN-FAILED ( abs-path -- )
   {: p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not open daemon lock file " LOG:TEXT+ p QUOTED+
   s" Ensure the Omabox state directory is writable and retry." HELP
   cause FS:ENOSPC = if E-DISK-FULL else E-LOCK-OPEN then cause FAIL ;

: ALREADY-RUNNING ( -- )
   LOG-OPEN s" another Omabox daemon is already running" LOG:TEXT+
   s" Use the existing daemon instance; no lock-file cleanup is" HELP
   s"  required." LOG:TEXT+
   E-ALREADY-RUNNING 0 FAIL ;

: ACQUIRE-FAILED ( abs-path -- )
   {: p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not acquire daemon lock on " LOG:TEXT+ p QUOTED+
   s" Check filesystem lock support and retry." HELP
   E-LOCK-ACQUIRE cause FAIL ;

\ A new file at s, mode 0600; false leaves the cause in FS:ERRNO.
: CREATED? ( str -- bool )
   {: s :}
   [: s FS:MODE-PRIVATE-FILE FS:CREATE-NEW FD>N close ;] catch {: code:n :}
   code 0= if true exit then
   code E-FS-OPEN <> if code throw then
   false ;

\ s a regular file, made 0600 if missing; false leaves the cause in
\ FS:ERRNO, 0 for an entry that is no file, a dangling link included.
: OWNER-ONLY? ( str -- bool )
   {: s :}
   s PASSABLE? 0= if false exit then
   s CREATED? if true exit then
   FS:ERRNO FS:EEXIST <> if false exit then
   s FS:TRY-LSTAT 0= if false exit then
   FS:STAT-MODE@ FS:S-IFMT and FS:S-IFREG = if true exit then
   0 FS:CAUSE! false ;

\ A code FS's open threw: E-FS-OPEN is E-LOCK-OPEN, any other goes on.
: OPEN-CAUGHT ( n abs-path -- )
   {: code:n p :}
   code E-FS-OPEN <> if code throw then
   p OPEN-FAILED ;

\ The lock file opened for reading and writing, never through a symlink.
: OPEN-LOCK ( abs-path -- fd )
   {: p :}
   p ABS-PATH>STR OWNER-ONLY? 0= if p OPEN-FAILED then
   -1 >FD [: drop p ABS-PATH>STR FS:OPEN-RDWR-NOFOLLOW ;] catch
   {: code:n :}
   code 0<> if code p OPEN-CAUGHT then ;

\ A code FS-LOCK:TRY threw, fd closed: E-FS-IO is E-LOCK-ACQUIRE, any
\ other goes on.
: TRY-CAUGHT ( n fd abs-path -- )
   {: code:n f:fd p :}
   f FD>N close
   code E-FS-IO <> if code throw then
   p ACQUIRE-FAILED ;

\ A warning: UNLOCK closes the file anyway.
: UNLOCK-FAILED ( n abs-path -- )
   {: cause:n p :}
   LOG:WARN s" config" LOG:LINE
   s" could not unlock the daemon lock file " LOG:TEXT+ p QUOTED+
   s" ; closing it instead: " LOG:TEXT+ cause FS:ERRNO$ LOG:TEXT+
   LOG:;LINE ;

public

\ ---- prepare and the instance lock

\ The state, upload-staging and recovery directories made and set 0700
\ between two checks that every private path lies outside the sync root.
: PREPARE-PATHS ( ^paths abs-path -- )
   [: PREPARE-IN ;] ARENA:WITH ;

: PREPARE ( ^config -- )
   {: c :}
   c CONFIG-PATHS @ c CONFIG-SYNC-ROOT @ PREPARE-PATHS ;

\ The paths' daemon.lock, never waiting. flock binds the open file
\ description, so a second LOCK here contends as another process's does.
: LOCK ( ^paths -- lock )
   PATHS-LOCK @ {: p :}
   p OPEN-LOCK {: f:fd :}
   false [: drop f FS-LOCK:TRY ;] catch {: code:n :}
   code 0<> if code f p TRY-CAUGHT then
   if f p LOCK-MAKE exit then
   f FD>N close ALREADY-RUNNING ;

\ Unlocks before closing, so a forked copy of the descriptor does not keep
\ the lock. The file stays: its presence claims nothing.
: UNLOCK ( lock -- )
   LOCK-UNMAKE {: f:fd p :}
   [: f FS-LOCK:RELEASE ;] catch {: code:n :}
   code E-FS-IO = if FS:ERRNO p UNLOCK-FAILED then
   f FD>N close
   code 0<> code E-FS-IO <> and if code throw then ;


private

\ ---- config.toml's text

ENUM encoding basic literal ml-basic ml-literal ;ENUM

\ src copied to dst+at: the offset after it.
: PUT ( str ^u8 n -- n )
   {: s dst:^ at:n :}
   s str> {: src:^ u:n :}
   src dst at + u BYTE-COPY
   at u + ;

: BYTE+ ( n ^u8 n -- n )
   {: b:n dst:^ at:n :}
   b dst at + c!
   at 1 + ;

\ Whether a byte is b.
: ANY? ( ^u8 n n -- bool )
   {: a:^ u:n b:n :}
   u 0 ?do a i + c@ b = if true unloop exit then loop
   false ;

\ The longest run of byte b.
: LONGEST ( ^u8 n n -- n )
   {: a:^ u:n b:n :}
   0 0 u 0 ?do
      a i + c@ b = if 1 + else drop 0 then
      tuck max swap
   loop drop ;

\ A control byte only an escape code writes: not tab, not newline.
: CODE? ( n -- bool )
   {: b:n :}
   b $1F <= b 9 <> and b $0A <> and b $7F = or ;

: CODES? ( ^u8 n -- bool )
   {: a:^ u:n :}
   u 0 ?do a i + c@ CODE? if true unloop exit then loop
   false ;

\ The form toml_writer's TomlStringBuilder::as_default picks.
: FORM ( ^u8 n -- encoding )
   {: a:^ u:n :}
   a u CODES? {: codes:bool :}
   a u $5C ANY? {: esc:bool :}
   a u $0A ANY? {: nl:bool :}
   a u $27 LONGEST {: sq:n :}
   a u $22 LONGEST {: dq:n :}
   codes esc or dq 0 > or nl or 0= if ENCODING-BASIC exit then
   codes sq 0 > or nl or 0= if ENCODING-LITERAL exit then
   codes esc or dq 2 > or 0= if ENCODING-ML-BASIC exit then
   codes sq 2 > or 0= if ENCODING-ML-LITERAL exit then
   nl if ENCODING-ML-BASIC else ENCODING-BASIC then ;

: HEX-DIGIT ( n -- n )
   {: d:n :}
   d 10 < if d [char] 0 + else d 55 + then ;

\ \u00XX, upper-case, for a control byte.
: UNICODE ( n ^u8 n -- n )
   {: b:n dst:^ at:n :}
   s" \u00" dst at PUT {: k:n :}
   b 4 rshift HEX-DIGIT dst k BYTE+ {: j:n :}
   b 15 and HEX-DIGIT dst j BYTE+ ;

\ One byte but a quote of an escaped string, as toml_writer writes it.
: ESCAPED ( n bool ^u8 n -- n )
   {: b:n ml:bool dst:^ at:n :}
   b 8 = if s" \b" dst at PUT exit then
   b 9 = if s" \t" dst at PUT exit then
   b $0A = ml and if b dst at BYTE+ exit then
   b $0A = if s" \n" dst at PUT exit then
   b $0C = if s" \f" dst at PUT exit then
   b $0D = if s" \r" dst at PUT exit then
   b $5C = if s" \\" dst at PUT exit then
   b CODE? if b dst at UNICODE exit then
   b dst at BYTE+ ;

\ A quote extends a run of quotes: past the run allowed (none, two in a
\ multi-line string) it is escaped and the run starts again.
: QUOTE ( n n ^u8 n -- n n )
   {: run:n most:n dst:^ at:n :}
   run 1 + most > if s\" \\\"" dst at PUT 0 exit then
   $22 dst at BYTE+ run 1 + ;

: ESCAPED-BODY ( ^u8 n bool ^u8 n -- n )
   {: a:^ u:n ml:bool dst:^ at:n :}
   ml if 2 else 0 then {: most:n :}
   at 0 u 0 ?do
      {: o:n run:n :}
      a i + c@ {: b:n :}
      b $22 = if run most dst o QUOTE swap
      else b ml dst o ESCAPED 0 then
   loop drop ;

: DELIMITER ( encoding -- str )
   MATCH encoding
      basic OF s\" \"" ENDOF
      literal OF s" '" ENDOF
      ml-basic OF s\" \"\"\"" ENDOF
      ml-literal OF s" '''" ENDOF
   ;MATCH ;

: ESCAPES? ( encoding -- bool )
   MATCH encoding
      basic OF true ENDOF
      literal OF false ENDOF
      ml-basic OF true ENDOF
      ml-literal OF false ENDOF
   ;MATCH ;

: MULTI-LINE? ( encoding -- bool )
   MATCH encoding
      basic OF false ENDOF
      literal OF false ENDOF
      ml-basic OF true ENDOF
      ml-literal OF true ENDOF
   ;MATCH ;

\ A string as toml_writer writes a value, at dst+at: the offset after it.
: STRING ( str ^u8 n -- n )
   {: v dst:^ at:n :}
   v str> {: a:^ u:n :}
   a u FORM {: e :}
   e MULTI-LINE? a u $0A ANY? and {: lead:bool :}
   e DELIMITER dst at PUT {: k:n :}
   lead if $0A dst k BYTE+ else k then {: j:n :}
   e ESCAPES? if a u e MULTI-LINE? dst j ESCAPED-BODY
   else v dst j PUT then {: m:n :}
   e DELIMITER dst m PUT ;

\ One `key = value` line.
: ENTRY ( str str ^u8 n -- n )
   {: k v dst:^ at:n :}
   k dst at PUT {: j:n :}
   s"  = " dst j PUT {: m:n :}
   v dst m STRING {: e:n :}
   $0A dst e BYTE+ ;

: SERIALIZE-FAILED ( -- )
   LOG-OPEN s" could not serialize Omabox configuration" LOG:TEXT+
   s" Use a sync-root path representable in TOML and retry." HELP
   E-SERIALIZE 0 FAIL ;

: UTF-8? ( str -- bool ) UTF8:VALID? ;

\ The stored document's text; a string that is not UTF-8 is E-SERIALIZE.
\ No byte takes more than the six of an escape code.
: DOCUMENT-TEXT ( abs-path str ^ARENA:arena -- str )
   {: root key ar :}
   root ABS-PATH>STR {: r :}
   r UTF-8? key UTF-8? and 0= if SERIALIZE-FAILED then
   r str> nip key str> nip + 6 * 64 + {: cap:n :}
   ar cap ARENA:ALLOC drop {: dst:^ :}
   s" sync_root" r dst 0 ENTRY {: k:n :}
   s" dropbox_app_key" key dst k ENTRY {: u:n :}
   dst u >str ;


\ ---- writing config.toml

\ The temporaries' sequence; atomic-add numbers them across tasks.
variable SEQUENCE

\ A write under way. anchor is parent's descriptor, name the temporary's
\ name under it; replace says a config.toml is already there.
STRUCTURE writing DERIVE addr
   FIELD parent abs-path
   FIELD anchor fd
   FIELD name str
   FIELD temporary abs-path
   FIELD file abs-path
   FIELD text str
   FIELD replace bool
;STRUCTURE

ARENA WRITINGS writing

\ Ends the error's line with the help every write error shares.
: WRITE-HELP ( -- )
   s" Ensure the XDG configuration location is owned by this user and" HELP
   s"  writable." LOG:TEXT+ ;

: PREPARE-FAILED ( abs-path -- )
   {: p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not prepare Omabox configuration directory at "
   LOG:TEXT+ p QUOTED+ WRITE-HELP
   E-PREPARE-CONFIGURATION-DIRECTORY cause FAIL ;

\ The operation that failed and the path it names.
: WRITE-FAILED ( str abs-path -- )
   {: op p :}
   FS:ERRNO {: cause:n :}
   LOG-OPEN s" could not " LOG:TEXT+ op LOG:TEXT+
   s"  Omabox configuration at " LOG:TEXT+ p QUOTED+ WRITE-HELP
   E-WRITE cause FAIL ;

: ALREADY-EXISTS ( abs-path -- )
   {: p :}
   LOG-OPEN s" Omabox configuration already exists at " LOG:TEXT+
   p QUOTED+
   s" Use Omabox settings commands to change existing configuration." HELP
   E-ALREADY-EXISTS 0 FAIL ;

\ The temporary a failed write left, and that write's cause.
: CLEANUP-AFTER-WRITE ( abs-path n -- )
   {: t cause:n :}
   LOG-OPEN
   s" the configuration write failed and cleanup also failed: " LOG:TEXT+
   s" could not remove the temporary Omabox configuration at " LOG:TEXT+
   t QUOTED+
   s" ; the incomplete owner-only temporary file is ignored" LOG:TEXT+
   WRITE-HELP
   E-CLEANUP-AFTER-WRITE cause FAIL ;

\ The directory made, each missing ancestor too, and set 0700.
: PREPARED ( abs-path -- )
   {: p :}
   p ABS-PATH>STR str> {: a:^ u:n :}
   a u MAKE-ALL? 0= if p PREPARE-FAILED then
   a u >str FS:>PATHZ FS:MODE-PRIVATE-DIR chmod 0<> if p PREPARE-FAILED then ;

\ The directory's descriptor, which names the renames' entries.
: ANCHOR ( abs-path -- fd )
   {: p :}
   -1 >FD [: drop p ABS-PATH>STR FS:OPEN-DIR-FOLLOW ;] catch
   {: code:n :}
   code 0= if exit then
   code E-FS-OPEN <> if code throw then
   p PREPARE-FAILED ;

\ ".config.toml.<pid>.<seq>.tmp" in the arena.
: TEMPORARY-NAME ( ^ARENA:arena -- str )
   {: ar :}
   1 SEQUENCE atomic-add {: seq:n :}
   ar 64 ARENA:ALLOC drop {: dst:^ :}
   s" .config.toml." dst 0 PUT {: k:n :}
   getpid FMT:INT$ dst k PUT {: j:n :}
   [char] . dst j BYTE+ {: m:n :}
   seq FMT:INT$ dst m PUT {: e:n :}
   s" .tmp" dst e PUT {: u:n :}
   dst u >str ;

: CREATE-CAUGHT ( n abs-path -- )
   {: code:n t :}
   code E-FS-OPEN <> if code throw then
   s" create a temporary" t WRITE-FAILED ;

\ The temporary, new and owner-only.
: CREATED ( abs-path -- fd )
   {: t :}
   t ABS-PATH>STR PASSABLE? 0= if s" create a temporary" t WRITE-FAILED then
   -1 >FD
   [: drop t ABS-PATH>STR FS:MODE-PRIVATE-FILE FS:CREATE-NEW ;]
   catch {: code:n :}
   code 0<> if code t CREATE-CAUGHT then ;

\ The text written and synced, the file closed whatever happened.
: WRITTEN ( fd str abs-path -- )
   {: f:fd body t :}
   0 FS:CAUSE!
   [: f body FD:WRITE-FULL f FD:SYNC ;] catch {: code:n :}
   FS:ERRNO {: cause:n :}
   f FD>N close
   cause FS:CAUSE!
   code 0= if exit then
   code E-FS-IO <> if code throw then
   s" write a temporary" t WRITE-FAILED ;

\ The temporary renamed over config.toml, or into its place only while
\ none is there.
: INSTALLED ( ^writing -- )
   {: w :}
   w WRITING-ANCHOR @ {: dir:fd :}
   w WRITING-NAME @ {: n :}
   w WRITING-FILE @ {: file :}
   w WRITING-REPLACE @ if
      dir n dir s" config.toml" FS:TRY-RENAME-AT if exit then
      s" install the new" file WRITE-FAILED
   then
   dir n dir s" config.toml" FS:TRY-RENAME-NEW-AT if exit then
   FS:ERRNO FS:EEXIST = if file ALREADY-EXISTS then
   s" install the initial" file WRITE-FAILED ;

\ The directory synced, so the rename lasts.
: DIRECTORY-SYNCED ( ^writing -- )
   {: w :}
   w WRITING-FILE @ {: file :}
   w WRITING-PARENT @ ABS-PATH>STR FS:>PATHZ 0 0 open {: d:n :}
   d 0 < if s" make the new" file WRITE-FAILED then
   [: d >FD FD:SYNC ;] catch {: code:n :}
   FS:ERRNO {: cause:n :}
   d close
   cause FS:CAUSE!
   code 0= if exit then
   code E-FS-IO <> if code throw then
   s" make the new" file WRITE-FAILED ;

: PHASES ( ^writing -- )
   {: w :}
   w WRITING-TEMPORARY @ {: t :}
   t CREATED w WRITING-TEXT @ t WRITTEN
   w INSTALLED
   w DIRECTORY-SYNCED ;

\ Removed or gone already; false leaves the cause in FS:ERRNO.
: TEMPORARY-REMOVED? ( ^writing -- bool )
   {: w :}
   w WRITING-ANCHOR @ w WRITING-NAME @ FS:TRY-REMOVE-FILE-AT if
      true exit
   then
   FS:ERRNO FS:ENOENT = ;

\ A failed write's temporary removed before its code goes on.
: ATTEMPT ( ^writing -- )
   {: w :}
   [: w PHASES ;] catch {: code:n :}
   code 0= if exit then
   FS:ERRNO {: cause:n :}
   w TEMPORARY-REMOVED? if cause FS:CAUSE! code throw then
   w WRITING-TEMPORARY @ cause CLEANUP-AFTER-WRITE ;

: STAGED ( ^paths str bool fd ^ARENA:arena -- ^writing )
   {: p body replace:bool dir:fd ar :}
   ar WRITINGS-NEW {: w :}
   p PATHS-CONFIG @ w WRITING-PARENT !
   dir w WRITING-ANCHOR !
   ar TEMPORARY-NAME {: n :}
   n w WRITING-NAME !
   p PATHS-CONFIG @ n ar JOIN w WRITING-TEMPORARY !
   p ar CONFIG-FILE w WRITING-FILE !
   body w WRITING-TEXT !
   replace w WRITING-REPLACE !
   w ;

\ The sweep, then the write, under the directory's descriptor.
: WRITE-IN ( ^paths str bool fd ^ARENA:arena
     -- ^VEC:vector<STALE:leftover> )
   {: p body replace:bool dir:fd ar :}
   p PATHS-CONFIG @ ABS-PATH>STR s" .config.toml." s" .tmp" ar STALE:SWEEP
   {: v :}
   p body replace dir ar STAGED ATTEMPT
   v ;

: WRITE-WITH ( ^config bool ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: c replace:bool ar :}
   c CONFIG-SYNC-ROOT @ c CONFIG-DROPBOX-APP-KEY @ ar DOCUMENT-TEXT
   {: body :}
   c CONFIG-PATHS @ {: p :}
   p PATHS-CONFIG @ {: parent :}
   parent PREPARED
   parent ANCHOR {: dir:fd :}
   [: p body replace dir ar WRITE-IN ;] [: dir FD>N close ;] finally ;

public

\ ---- writing config.toml

\ The config written over any config.toml, owner-only: the stale
\ temporaries the write's sweep left in place.
: WRITE ( ^config ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: c ar :}
   c true ar WRITE-WITH ;

\ The config written only where no config.toml is, else
\ E-ALREADY-EXISTS: the stale temporaries the write's sweep left in place.
: WRITE-NEW ( ^config ^ARENA:arena -- ^VEC:vector<STALE:leftover> )
   {: c ar :}
   c false ar WRITE-WITH ;

;package
