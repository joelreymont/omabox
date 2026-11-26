-------------------------- MODULE ConflictPlacement --------------------------
\* One new conflict's step, CONFLICT-PLACEMENT in src/reconcile.f, then the
\* sweep STALE-BLOCKS runs once planning answered ok. The conflict may be
\* recorded already, and its path may hold a block whose retry time has
\* come (due) or not (early). Placing the copies may record them (placed),
\* find a copy name or stage place taken, find any other blockage
\* (refused), find the source changed (changed) or the root gone
\* (unrooted). Waiting is the key on the pass's waiting vector, which the
\* sweep reads. A pass that answers fresh or root-changed never sweeps.

Starts == {"recorded", "early", "open"}
Ends == {"placed", "taken", "refused", "changed", "unrooted"}
\* The inputs that leave planning's answer ok.
Oks == {"recorded", "early", "placed", "taken", "refused"}
Rows == {"none", "early", "due"}

\* at: the table's state; row: the path's block; recorded: the conflict
\* is recorded; how: the input that ended the step, "none" before;
\* waiting: the key is on the waiting vector; swept: the sweep has run.
VARIABLES at, row, recorded, how, waiting, swept

vars == <<at, row, recorded, how, waiting, swept>>

Init ==
    /\ at = "deciding"
    /\ row \in Rows
    /\ recorded \in BOOLEAN
    /\ how = "none"
    /\ waiting = FALSE
    /\ swept = FALSE

Recorded ==
    /\ at = "deciding"
    /\ recorded
    /\ at' = "ended"
    /\ how' = "recorded"
    /\ UNCHANGED <<row, recorded, waiting, swept>>

Early ==
    /\ at = "deciding"
    /\ ~recorded
    /\ row = "early"
    /\ at' = "ended"
    /\ how' = "early"
    /\ waiting' = TRUE
    /\ UNCHANGED <<row, recorded, swept>>

Open ==
    /\ at = "deciding"
    /\ ~recorded
    /\ row # "early"
    /\ at' = "preparing"
    /\ UNCHANGED <<row, recorded, how, waiting, swept>>

Placed ==
    /\ at = "preparing"
    /\ at' = "ended"
    /\ how' = "placed"
    /\ recorded' = TRUE
    /\ UNCHANGED <<row, waiting, swept>>

\* The block a taken place writes: its retry time an hour on.
Taken ==
    /\ at = "preparing"
    /\ at' = "ended"
    /\ how' = "taken"
    /\ row' = "early"
    /\ waiting' = TRUE
    /\ UNCHANGED <<recorded, swept>>

\* Ended by any other input of preparing, which writes nothing.
Left(e) ==
    /\ at = "preparing"
    /\ at' = "ended"
    /\ how' = e
    /\ UNCHANGED <<row, recorded, waiting, swept>>

Sweep ==
    /\ at = "ended"
    /\ how \in Oks
    /\ ~swept
    /\ swept' = TRUE
    /\ row' = IF waiting THEN row ELSE "none"
    /\ UNCHANGED <<at, recorded, how, waiting>>

Next ==
    \/ Recorded
    \/ Early
    \/ Open
    \/ Placed
    \/ Taken
    \/ \E e \in {"refused", "changed", "unrooted"} : Left(e)
    \/ Sweep

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ at \in {"deciding", "preparing", "ended"}
    /\ row \in Rows
    /\ recorded \in BOOLEAN
    /\ how \in {"none"} \cup Starts \cup Ends
    /\ waiting \in BOOLEAN
    /\ swept \in BOOLEAN

\* Copies are prepared only for an unrecorded conflict whose block, if
\* any, is due: one waiting out its block is neither staged nor hashed.
PreparesOnlyOpen == at = "preparing" => ~recorded /\ row # "early"

\* The key waits exactly when the step ended taken or early.
WaitsWhenBlocked == waiting <=> how \in {"taken", "early"}

\* After the sweep a row is left exactly when the step ended taken, or
\* early with its row kept, and it is early either way.
RowLeftWhenWaiting ==
    swept =>
        /\ (row # "none") <=> how \in {"taken", "early"}
        /\ how \in {"taken", "early"} => row = "early"

\* Of the steps that prepared copies only taken writes a row, which matters
\* where no sweep follows: a crash, or a pass another path ends early.
OnlyTakenWrites ==
    how \in {"placed", "refused", "changed", "unrooted"} => row # "early"

=============================================================================
