---- MODULE ReleaseWindowCloseTable ----
\* The lines of CLOSING, src/omabox.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"closed", "quiet", "decided">>,
    <<"closed", "signaled", "died">>,
    <<"closed", "kept", "died">>,
    <<"closed", "unmade", "died">>
}
====
