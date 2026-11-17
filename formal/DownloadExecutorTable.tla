---- MODULE DownloadExecutorTable ----
\* The lines of DOWNLOAD-EXECUTOR, src/reconcile.f, as <<state, input,
\* next state>>. TEST-FORMAL:HOLDS fails unless this file is that table.
Lines == {
    <<"queued", "staged", "staged">>,
    <<"queued", "blocked", "blocked">>,
    <<"staged", "active", "installed">>,
    <<"staged", "changed", "unrooted">>
}
====
