---- MODULE RemoteCopyTable ----
\* The lines of REMOTE-COPY, src/replay.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"own", "placed", "ready">>,
    <<"own", "missing", "reusing">>,
    <<"own", "held", "stage-held">>,
    <<"own", "changed", "taken">>,
    <<"own", "occupied", "taken">>,
    <<"reusing", "placed", "ready">>,
    <<"reusing", "missing", "fetching">>,
    <<"reusing", "held", "fetching">>,
    <<"reusing", "changed", "taken">>,
    <<"reusing", "occupied", "taken">>,
    <<"fetching", "staged", "installing">>,
    <<"fetching", "mismatch", "unverified">>,
    <<"fetching", "held", "stage-held">>,
    <<"fetching", "refused", "refused">>,
    <<"fetching", "occupied", "taken">>,
    <<"installing", "placed", "ready">>,
    <<"installing", "missing", "lost">>,
    <<"installing", "held", "stage-held">>,
    <<"installing", "changed", "taken">>,
    <<"installing", "occupied", "taken">>
}
====
