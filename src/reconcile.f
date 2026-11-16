\ reconcile.f - package RECONCILE: one sync pass (rust src/reconcile.rs):
\ list Dropbox, scan the root, plan each path, replay the pending plans
\ and run their downloads, one at a time. A journal answer the pass
\ refuses is logged once with the Rust version's text, naming the path,
\ then thrown as E-INVALID-STATE.
\ STORAGE CLASS. No state of its own. CALLER-OWNED: every value a pass
\ reads or makes lies in the arena the caller passes.

require src/lib/error.f
require src/lib/string.f
require src/lib/arena.f
require src/lib/log.f
require src/lib/adt/option.f
require src/lib/vector.f
require src/model.f
require src/journal.f
require src/local.f
require src/dropbox.f
require src/replay.f

package RECONCILE
public

-100800 constant E-FIRST
-100899 constant E-LAST
-100800 s" journaled reconciliation state is invalid"
   ERROR:CODE E-INVALID-STATE
-100801 s" two local paths have one Dropbox path identity"
   ERROR:CODE E-CASE-COLLISION

private

\ ---- failures ------------------------------------------------------

: INVALID ( MODEL:path ^u8 n -- )
   {: path detail:^ du:n :}
   LOG:ERROR s" reconcile" LOG:LINE
   s" reconciliation found invalid journal state for `" LOG:TEXT+
   path MODEL:PATH>STR str> LOG:TEXT+ s" `: " LOG:TEXT+
   detail du LOG:TEXT+ LOG:;LINE
   E-INVALID-STATE throw ;

;package
