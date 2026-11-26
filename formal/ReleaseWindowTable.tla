---- MODULE ReleaseWindowTable ----
\* The lines of RELEASING, src/omabox.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"released", "ok", "changing">>,
    <<"released", "failed", "restoring">>,
    <<"released", "interrupted", "restoring">>,
    <<"changing", "ok", "restoring">>,
    <<"changing", "failed", "restoring">>,
    <<"changing", "interrupted", "restoring">>
}
====
