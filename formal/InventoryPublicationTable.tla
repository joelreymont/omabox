---- MODULE InventoryPublicationTable ----
\* The lines of INVENTORY-PUBLICATION, src/reconcile.f, as <<state, input,
\* next state>>. src/reconcile-test.f fails unless this file is that table.
Lines == {
    <<"starting", "some", "delta">>,
    <<"starting", "none", "full">>,
    <<"delta", "done", "published">>,
    <<"delta", "reset", "full">>,
    <<"full", "done", "published">>
}
====
