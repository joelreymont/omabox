---- MODULE RemoteLifecycleTable ----
\* The lines of REMOTE-LIFECYCLE, src/replay.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"recorded", "completed", "passed">>,
    <<"recorded", "pending", "applying">>,
    <<"applying", "done", "passed">>,
    <<"applying", "blocked", "stopped">>,
    <<"applying", "local", "yielded">>
}
====
