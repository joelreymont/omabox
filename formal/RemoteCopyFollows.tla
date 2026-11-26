---- MODULE RemoteCopyFollows ----
\* Follows: every step that moves the copy between the table's states,
\* and every step of the table's lines (Run), one that keeps its state
\* included, is a line of REMOTE-COPY, and every line's step moves as the
\* line says. Out is the copy outside a pass: before it, or its pass ended
\* or recorded the conflict; a pass enters the copy at First.
EXTENDS RemoteCopy
T == INSTANCE RemoteCopyTable
Out == "out"
First == "own"
At == run
Walks(l) ==
    CASE l = <<"own", "placed", "ready">> -> Placed("own")
      [] l = <<"own", "missing", "reusing">> -> OwnMissing("own", "reusing")
      [] l = <<"own", "held", "stage-held">> ->
            OwnHeld("own") \/ PlacedHeld("own")
      [] l = <<"own", "changed", "taken">> -> Changed("own")
      [] l = <<"own", "occupied", "taken">> -> Occupied("own")
      [] l = <<"reusing", "placed", "ready">> -> Placed("reusing")
      [] l = <<"reusing", "missing", "fetching">> -> PlanMissing
      [] l = <<"reusing", "held", "fetching">> ->
            PlanHeld \/ PlacedHeld("reusing")
      [] l = <<"reusing", "changed", "taken">> -> Changed("reusing")
      [] l = <<"reusing", "occupied", "taken">> -> Occupied("reusing")
      [] l = <<"fetching", "staged", "installing">> -> FetchKept \/ FetchStaged
      [] l = <<"fetching", "mismatch", "unverified">> ->
            FetchFailed("unverified")
      [] l = <<"fetching", "held", "stage-held">> -> FetchHeld
      [] l = <<"fetching", "refused", "refused">> -> FetchFailed("refused")
      [] l = <<"fetching", "occupied", "taken">> -> FetchOccupied
      [] l = <<"installing", "placed", "ready">> -> Placed("installing")
      [] l = <<"installing", "missing", "lost">> ->
            OwnMissing("installing", "lost")
      [] l = <<"installing", "held", "stage-held">> ->
            OwnHeld("installing") \/ PlacedHeld("installing")
      [] l = <<"installing", "changed", "taken">> -> Changed("installing")
      [] l = <<"installing", "occupied", "taken">> -> Occupied("installing")
Line(l) == At = l[1] /\ At' = l[3]
Follows ==
    [][ /\ (At' # At \/ Run) =>
                \/ \E l \in T!Lines : Line(l) /\ Walks(l)
                \/ At' = Out
                \/ At = Out /\ At' = First
        /\ \A l \in T!Lines : Walks(l) => Line(l) ]_vars
====
