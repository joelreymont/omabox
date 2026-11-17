# Sync lifecycle models

`DownloadLifecycle` checks two concurrent exact-download lifecycles sharing
exactly four resumable slots. It covers durable checkpoints, exact range
continuation, crash truncation, stale root and operation bindings, unknown slot
occupants, full verification, promotion, installation, and journal completion.

`MutationLifecycle` checks replacement and deletion across journal recording,
verified staging, same-directory displacement, user races, crashes, replay, and
baseline completion. It verifies that changed user content is never mutated,
only verified bytes are installed, and no displacement guard survives a
completed operation.

`LocalLifecycle` checks one pending plan's local replay, whose steps are
`LOCAL-LIFECYCLE`'s lines. Each pass runs the plan's operations in order,
passing a completed one, applying a pending one, and stopping the plan at a
block, which may retire it. A non-final operation completes at once; the final
one's completion waits for the pass's commit and a crash loses it. It requires
that only a plan's first pending operation is applied, so the journal accepts
every completion the pass asks for, and that the baseline advances only with
the final operation's completion after an apply confirmed its effect.
`MutationLifecycle` models what an apply does.

`DownloadExecutor` checks the bounded worker queue around that lifecycle. It
covers slot exclusivity, failure cancellation, preservation of successful
stages, crash recovery, retry, installation, and journal completion. It also
covers the durable per-path block that schema 6 records: a rejected download
blocks its own plan without cancelling the batch or touching a sibling, no
worker picks the path up while that plan is blocked, and the block outlives a
crash, so only the reconciler returning the plan to pending queues it again.
A staged download installs only while the configured root is still the
journal's active one; under any other root it stays staged and its plan
pending. `Unroot` is the executor's root check leaving it so, for a later pass
under the active root to install.

`ScanCoordination` checks that downloads continue while a complete local scan
runs, but verified-stage promotion cannot mutate the sync root until that scan
has published. It also checks that a requested scan cannot starve.

`SyncBehavior` checks the automatic top-level behavior after initial file
creation, later local or remote edits, local or remote deletion, divergent
edits, deletion/edit conflicts, and initial collisions. It requires a fair
daemon wakeup, durable intent before effects, verified uploads and downloads,
convergence for ordinary changes, and preservation of every present conflict
side. The corresponding fake-Dropbox tests exercise these cases; TLC does not
prove that the implementation conforms to the model.

`SyncPass` checks one reconciliation pass, `SYNC-PASS`'s lines: a pass ends
stale or unrooted wherever the table lets a word answer so, planning reads a
local scan and a Dropbox listing both taken after the pass last replayed or
copied, and the complete report comes only from a pass whose replays and
planning answered ok. What planning and replay do to one path is
`SyncBehavior`'s.

`DirectoryDeletion` checks one locally deleted directory holding one
synchronized file while another Dropbox client may rewrite or re-create that
file. It requires that a remote directory delete is planned only from an
inventory that holds nothing beneath the path, that no step deletes a Dropbox
folder still holding an entry or content the local side never synchronized,
that a locally deleted directory returns only holding, or about to hold,
Dropbox content the user never deleted, and that an unraced deletion propagates
completely while a raced one settles with the payload preserved on both sides. Effects and journal
completions are separate steps, so replay after a crash between them is
covered. `DropboxClient::delete_folder` realizes the probe-then-delete step.

`InventoryPublication` checks fresh listings, cursor deltas, reset-triggered
rebuilds, multi-page failures, crashes, retries, and atomic publication. Partial
pages and failed attempts must leave the prior durable inventory and cursor
unchanged; deleting durable entries requires a complete validated publication.

Run the models from this directory with `tlc`, the TLA+ tools' model
checker on PATH:

```sh
tlc -config DownloadLifecycle.cfg DownloadLifecycle.tla
tlc -config MutationLifecycle.cfg MutationLifecycle.tla
tlc -config LocalLifecycle.cfg LocalLifecycle.tla
tlc -config DownloadExecutor.cfg DownloadExecutor.tla
tlc -config ScanCoordination.cfg ScanCoordination.tla
tlc -config SyncBehavior.cfg SyncBehavior.tla
tlc -config SyncPass.cfg SyncPass.tla
tlc -config InventoryPublication.cfg InventoryPublication.tla
tlc -config DirectoryDeletion.cfg DirectoryDeletion.tla
```

Each table's check, in its package's tests, holds `<Model>Table.tla` to the
table's lines and runs TLC on `<Model>Follows.tla`, which states that the
model's steps follow that table:

- `src/reconcile-test.f`: `INVENTORY-PUBLICATION` (`InventoryPublication`),
  `DOWNLOAD-EXECUTOR` (`DownloadExecutor`) and `SYNC-PASS` (`SyncPass`);
- `src/replay-test.f`: `LOCAL-LIFECYCLE` (`LocalLifecycle`).

Same- and cross-filesystem promotion share one durable abstract boundary; TLC
checks crashes immediately before and after it. Dropbox transport and concrete
filesystem syscalls remain outside the model.
