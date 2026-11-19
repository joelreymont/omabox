---- MODULE InventoryPublicationFollows ----
\* Follows: every step between the table's states, and every step of its
\* lines (Run), one that keeps the state included, is a line of
\* INVENTORY-PUBLICATION, and every line's step moves as the line says; Out
\* is a failure or crash, which leaves the table, and a retry re-enters at
\* First.
EXTENDS InventoryPublication
T == INSTANCE InventoryPublicationTable
Out == "out"
First == "starting"
At == CASE phase = "Waiting" -> "starting"
        [] phase \in {"DeltaFirst", "DeltaSecond"} -> "delta"
        [] phase \in {"FullFirst", "FullSecond"} -> "full"
        [] phase = "Ready" -> IF mode = "Delta" THEN "delta" ELSE "full"
        [] phase = "Done" -> "published"
        [] phase \in {"Failed", "Crashed"} -> Out
Walks(l) ==
    CASE l = <<"starting", "some", "delta">> -> Start /\ cursor # NoCursor
      [] l = <<"starting", "none", "full">> -> Start /\ cursor = NoCursor
      [] l = <<"delta", "done", "published">> -> Publish /\ mode = "Delta"
      [] l = <<"delta", "reset", "full">> -> ObserveReset
      [] l = <<"full", "done", "published">> -> Publish /\ mode = "Full"
Line(l) == At = l[1] /\ At' = l[3]
Follows ==
    [][ /\ (At' # At \/ Run) => \/ \E l \in T!Lines : Line(l) /\ Walks(l)
                                \/ At' = Out
                                \/ At = Out /\ At' = First
        /\ \A l \in T!Lines : Walks(l) => Line(l) ]_vars
====
