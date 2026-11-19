---- MODULE ServiceDriveTable ----
\* The lines of DRIVING, src/service.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"initial", "observe", "seen">>,
    <<"initial", "clear", "cleared">>,
    <<"initial", "done", "reached">>,
    <<"seen", "stop", "after-stop">>,
    <<"seen", "clear", "cleared">>,
    <<"seen", "done", "reached">>,
    <<"after-stop", "observe", "settled">>,
    <<"after-stop", "done", "reached">>,
    <<"settled", "clear", "cleared">>,
    <<"settled", "done", "reached">>,
    <<"cleared", "start", "launched">>,
    <<"cleared", "restart", "launched">>,
    <<"cleared", "done", "reached">>
}
====
