---- MODULE SyncPassFollows ----
\* Follows: every step of the model is a line of SYNC-PASS and every
\* line's step moves as the line says.
EXTENDS SyncPass
T == INSTANCE SyncPassTable
Walks(l) ==
    CASE l = <<"settling", "ok", "recovering">> -> Ok("settling", "recovering")
      [] l = <<"settling", "fresh", "stale">> -> Fresh("settling")
      [] l = <<"settling", "root-changed", "unrooted">> -> Unroot("settling")
      [] l = <<"recovering", "ok", "observing">> -> Ok("recovering", "observing")
      [] l = <<"recovering", "root-changed", "unrooted">> -> Unroot("recovering")
      [] l = <<"observing", "ok", "listing">> -> Ok("observing", "listing")
      [] l = <<"observing", "fresh", "stale">> -> Fresh("observing")
      [] l = <<"observing", "root-changed", "unrooted">> -> Unroot("observing")
      [] l = <<"listing", "ok", "deciding">> -> Ok("listing", "deciding")
      [] l = <<"listing", "root-changed", "unrooted">> -> Unroot("listing")
      [] l = <<"deciding", "ok", "applying">> -> Ok("deciding", "applying")
      [] l = <<"deciding", "fresh", "stale">> -> Fresh("deciding")
      [] l = <<"deciding", "root-changed", "unrooted">> -> Unroot("deciding")
      [] l = <<"applying", "ok", "complete">> -> Ok("applying", "complete")
      [] l = <<"applying", "fresh", "stale">> -> Fresh("applying")
      [] l = <<"applying", "root-changed", "unrooted">> -> Unroot("applying")
Line(l) == at = l[1] /\ at' = l[3]
Follows ==
    [][ /\ \E l \in T!Lines : Line(l) /\ Walks(l)
        /\ \A l \in T!Lines : Walks(l) => Line(l) ]_vars
====
