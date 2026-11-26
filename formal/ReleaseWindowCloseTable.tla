---- MODULE ReleaseWindowCloseTable ----
\* The lines of CLOSING, src/omabox.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"closed", "done", "decided">>,
    <<"closed", "refused", "decided">>,
    <<"closed", "stuck", "decided">>,
    <<"closed", "broken", "decided">>,
    <<"closed", "signaled", "died">>,
    <<"closed", "kept", "died">>,
    <<"closed", "unmade", "died">>
}
====
