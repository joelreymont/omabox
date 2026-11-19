---- MODULE DownloadingTable ----
\* The lines of DOWNLOADING, src/dropbox.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"opened", "passed", "streaming">>,
    <<"opened", "other", "buffering">>,
    <<"opened", "response", "answered">>,
    <<"opened", "failure", "lost">>,
    <<"streaming", "held", "streaming">>,
    <<"streaming", "response", "drained">>,
    <<"streaming", "short", "short">>,
    <<"streaming", "failure", "lost">>,
    <<"streaming", "overrun", "overran">>,
    <<"streaming", "unread", "cancelled">>,
    <<"buffering", "chunk", "buffering">>,
    <<"buffering", "response", "answered">>,
    <<"buffering", "failure", "lost">>
}
====
