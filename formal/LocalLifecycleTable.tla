---- MODULE LocalLifecycleTable ----
\* The lines of LOCAL-LIFECYCLE, src/replay.f, as <<state, input,
\* next state>>. TEST-FORMAL:HOLDS fails unless this file is that table.
Lines == {
    <<"recorded", "completed", "passed">>,
    <<"recorded", "pending", "applying">>,
    <<"applying", "done", "passed">>,
    <<"applying", "blocked", "stopped">>
}
====
