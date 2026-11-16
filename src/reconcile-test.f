\ reconcile-test.f - RECONCILE's words, each case in a directory of its
\ own under TMPDIR, which it removes.
\ Run from the repository root: hb --load src/reconcile-test.f </dev/null
require src/lib/error.f
require src/lib/arena.f
require src/lib/string.f
require src/lib/fmt.f
require src/lib/test.f
require src/model.f
require src/journal.f
require src/reconcile.f

\ RECONCILE reopened for the private words the tests call.
package RECONCILE
private

: CASES ( ^ARENA:arena -- )
   drop ;


: RUN ( -- )
   T-RESET
   ARENA:NEW {: ar :}
   [: ar CASES ;] [: ar ARENA:RELEASE ;] finally
   s" reconcile-test: " type T-CASES FMT:.INT s"  checks" type cr
   T-REPORT ;

RUN

;package
