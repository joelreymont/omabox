---- MODULE ConflictPlacementTable ----
\* The lines of CONFLICT-PLACEMENT, src/reconcile.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"deciding", "recorded", "ended">>,
    <<"deciding", "early", "ended">>,
    <<"deciding", "open", "preparing">>,
    <<"preparing", "placed", "ended">>,
    <<"preparing", "taken", "ended">>,
    <<"preparing", "refused", "ended">>,
    <<"preparing", "changed", "ended">>,
    <<"preparing", "unrooted", "ended">>
}
====
