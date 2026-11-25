---- MODULE LocalWatchTable ----
\* The lines of WATCHING, src/local.f, as <<state, input,
\* next state>>. A test fails unless this file is that table.
Lines == {
    <<"blind", "start", "arming">>,
    <<"blind", "refused", "blind">>,
    <<"blind", "due", "blind">>,
    <<"blind", "published", "blind">>,
    <<"blind", "abandoned", "blind">>,
    <<"blind", "lost", "blind">>,
    <<"blind", "doubt", "blind">>,
    <<"arming", "published", "armed">>,
    <<"arming", "start", "blind">>,
    <<"arming", "due", "blind">>,
    <<"arming", "refused", "blind">>,
    <<"arming", "abandoned", "blind">>,
    <<"arming", "lost", "blind">>,
    <<"arming", "doubt", "blind">>,
    <<"armed", "start", "armed">>,
    <<"armed", "published", "armed">>,
    <<"armed", "abandoned", "armed">>,
    <<"armed", "due", "blind">>,
    <<"armed", "refused", "blind">>,
    <<"armed", "lost", "blind">>,
    <<"armed", "doubt", "blind">>
}
====
