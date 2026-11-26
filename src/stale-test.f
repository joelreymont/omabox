\ stale-test.f - STALE against the Rust version's stale.rs test under its
\ name: a directory the sweep cannot read is one leftover, its path, its
\ operation and its errno. Each case runs in a directory of its own under
\ TMPDIR and removes it after; as root, which reads a directory whatever
\ its mode, that case checks nothing, as the Rust test does.
\ - dead_directory_is_removed_whole, Omabox's own: a dead process's
\   temporary that is a directory, holding a file and a subdirectory,
\   goes with no leftover
\ Run from the repository root: hb --load src/stale-test.f </dev/null
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test/assert.f
require src/lib/fs.f
require src/lib/fs-mutate.f
require src/lib/vector.f
require src/stale.f

package STALE-TEST
private

\ Write and search, no read: 0300.
$C0 constant UNREADABLE

TYPED-VARIABLE AR ^ARENA:arena
TYPED-VARIABLE DIR str

: KEEP ( str -- str ) AR @ ARENA:COPY ;

\ base/name laid in the case's arena.
: UNDER ( str str -- str )
   {: base name :}
   name str> {: n:^ nu:n :}
   base str> {: b:^ bu:n :}
   AR @ bu 1 + nu + ARENA:ALLOC drop {: d:^ :}
   b d bu BYTE-COPY
   [char] / d bu + c!
   n d bu + 1 + nu BYTE-COPY
   d bu 1 + nu + >str ;

: CLEANUP ( -- )
   DIR @ FS:MODE-PRIVATE-DIR FS:CHMOD-MODE ;

: SWEPT ( -- ^VEC:vector<STALE:leftover> )
   DIR @ UNREADABLE FS:CHMOD-MODE
   [: DIR @ s" .omabox.install." s" " AR @ STALE:SWEEP ;]
   [: CLEANUP ;] finally ;

: UNREADABLE-DIRECTORY ( -- )
   s" unreadable_directory_is_one_leftover" T-LABEL
   FS:EUID 0= if exit then
   s" TMPDIR" GETENV s" stale-test-" FS:MKTEMP-DIR-IN KEEP {: tmp :}
   tmp s" unreadable" UNDER DIR !
   DIR @ FS:MAKE-DIR
   [: SWEPT ;] [: tmp FS:REMOVE-TREE ;] finally {: v :}
   v VEC:COUNT 1 T=
   v 0 VEC:AT {: l :}
   l STALE:PATH DIR @ T$=
   l STALE:OPERATION$ s" read a directory" T$=
   l STALE:ERRNO FS:EACCES T= ;

\ No process has this PID: Linux caps pid_max at 2^22.
: DEAD-NAME ( -- str ) s" .omabox.install.2147483647.0" ;

: REMOVED-WHOLE ( str -- )
   {: tmp :}
   tmp DEAD-NAME UNDER {: t :}
   t s" sub" UNDER {: sub :}
   t FS:MAKE-DIR
   sub FS:MAKE-DIR
   t s" file" UNDER s" stale" FS:WRITE-ALL
   sub s" file" UNDER s" stale" FS:WRITE-ALL
   tmp s" .omabox.install." s" " AR @ STALE:SWEEP VEC:COUNT 0 T=
   t FS:TRY-LSTAT TFALSE ;

: DEAD-DIRECTORY ( -- )
   s" dead_directory_is_removed_whole" T-LABEL
   s" TMPDIR" GETENV s" stale-test-" FS:MKTEMP-DIR-IN KEEP {: tmp :}
   [: tmp REMOVED-WHOLE ;] [: tmp FS:REMOVE-TREE ;] finally ;

public

: RUN ( -- )
   T-RESET
   ARENA:NEW AR !
   [: UNREADABLE-DIRECTORY DEAD-DIRECTORY ;]
   [: AR @ ARENA:RELEASE ;] finally
   s" stale-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

;package

STALE-TEST:RUN
