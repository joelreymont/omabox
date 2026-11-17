---- MODULE InventoryPublicationTable ----
\* The lines of INVENTORY-PUBLICATION, src/reconcile.f, as <<state, input,
\* next state>>. TEST-FORMAL:HOLDS fails unless this file is that table.
Lines == {
    <<"starting", "some", "delta">>,
    <<"starting", "none", "full">>,
    <<"delta", "done", "published">>,
    <<"delta", "reset", "full">>,
    <<"full", "done", "published">>
}
====
