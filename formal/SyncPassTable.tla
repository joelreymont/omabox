---- MODULE SyncPassTable ----
\* The lines of SYNC-PASS, src/reconcile.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"settling", "ok", "recovering">>,
    <<"settling", "fresh", "stale">>,
    <<"settling", "root-changed", "unrooted">>,
    <<"recovering", "ok", "observing">>,
    <<"recovering", "root-changed", "unrooted">>,
    <<"observing", "ok", "listing">>,
    <<"observing", "fresh", "stale">>,
    <<"observing", "root-changed", "unrooted">>,
    <<"listing", "ok", "deciding">>,
    <<"listing", "root-changed", "unrooted">>,
    <<"deciding", "ok", "applying">>,
    <<"deciding", "fresh", "stale">>,
    <<"deciding", "root-changed", "unrooted">>,
    <<"applying", "ok", "complete">>,
    <<"applying", "fresh", "stale">>,
    <<"applying", "root-changed", "unrooted">>
}
====
