---- MODULE ConflictPlacementFollows ----
\* Follows: every step that moves between the table's states is a line of
\* CONFLICT-PLACEMENT, and every line's step moves as the line says; the
\* sweep after the table ends keeps its state.
EXTENDS ConflictPlacement
T == INSTANCE ConflictPlacementTable
Walks(l) ==
    CASE l = <<"deciding", "recorded", "ended">> -> Recorded
      [] l = <<"deciding", "early", "ended">> -> Early
      [] l = <<"deciding", "open", "preparing">> -> Open
      [] l = <<"preparing", "placed", "ended">> -> Placed
      [] l = <<"preparing", "taken", "ended">> -> Taken
      [] l = <<"preparing", "refused", "ended">> -> Left("refused")
      [] l = <<"preparing", "changed", "ended">> -> Left("changed")
      [] l = <<"preparing", "unrooted", "ended">> -> Left("unrooted")
Line(l) == at = l[1] /\ at' = l[3]
Follows ==
    [][ /\ at' # at => \E l \in T!Lines : Line(l) /\ Walks(l)
        /\ \A l \in T!Lines : Walks(l) => Line(l) ]_vars
====
