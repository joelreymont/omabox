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
side. As the code does, the journal records an upload's plan once the upload is
staged, and a conflict once its copies exist. The corresponding fake-Dropbox
tests exercise these cases; TLC does not prove that the implementation conforms
to the model.

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

`RemoteLifecycle` checks one plan's operations replayed against Dropbox one
pass at a time: a completed operation passes, a pending one is sent, and a
blocked or local one ends the plan's turn. Dropbox may hold an operation's
effect before the journal records it, and another client may change its path.
The journal completes an operation only once Dropbox holds its effect or its
plan retired, operations reach Dropbox in plan order, and nothing is sent for
a plan that completed or retired.

`InventoryPublication` checks fresh listings, cursor deltas, reset-triggered
rebuilds, multi-page failures, crashes, retries, and atomic publication. Partial
pages and failed attempts must leave the prior durable inventory and cursor
unchanged; deleting durable entries requires a complete validated publication.

`ServiceDrive` checks one drive of the user unit toward each goal, `DRIVING` in
`src/service.f`. Any observation may read any state, and any step may fail, a
command before or after it was spawned. A start or restart follows a clear and
only where the goal asks for one; a release only stops, and only a unit it
first observed holding the instance lock, so a failed state stays for a later
recover; a drive that ends without failure or launch was not asked for one, a
halt or release stopped a unit it first saw holding the lock, and a halt
cleared a failed state it last saw.

`LocalWatch` checks LOCAL's watch, `WATCHING` in `src/local.f`, over the
root, a folder in it and one in that, so a clean folder can vouch for a child
the walk skips. Each folder has a journal record (none, clean, stirred, or
listed or tried by the running scan), a kernel watch, a published row (a
directory, unknown or gone) over stored rows that are current unless a
publication dropped them, and what the running scan stages at its path. A
change in a watched folder queues an event while the watch is not blind, else
is lost; an overflow drops an event and queues a loss; a folder replaced by a
look-alike loses its watch and changes its parent; a folder moved away during
a scan and back changes its parent, and both watches hear it. Hearing runs
before a scan, and a throw while hearing steps lost. A scan starts as the
table says and walks: a full one from the root, an armed one from each stirred
record in path order, each entering a folder its listing leads to unless the
folder's record is clean, which takes the record's own watch and a directory
row. A listing that cannot reach a child before adding its watch publishes it
unknown, stages its rows gone and leaves its record as it was; one that finds
the child changing once its watch is added publishes it unknown and leaves it
tried. A stirred folder's listing restates its own row; a stirred record
already staged, missing, replaced or answered by another wd stays tried, and a
tried record is stirred again once the scan ends. The scan publishes, is
abandoned or throws; a publication forgets the records at paths it staged
gone, and a recorded wd replaces any record at its path. A blind watch holds
no record and only an armed one a clean record, never at a gone row; a folder
that vouches for its subtree has a directory row and current rows beneath
it. A listing that adds a new wd at a path leaves the old wd's pending
IN-IGNORED no record to forget. No change below a clean folder stays unrecorded:
before an armed watch's scan, every folder whose stored rows may be wrong lies
beneath an unknown row or is reached by the walk from a stirred record once
the pending events are heard, unless a loss is queued.

`DaemonRun` checks the daemon's run, `DAEMON-RUN`: each step runs only once
what it reads exists and never makes again what the run holds, so the journal
opens only under the instance lock, systemd hears the daemon is ready only once
both are held, and a pass or a long poll runs only on a session validated
against the journal's binding; the long poll follows only a complete pass; and
only a failure that stops ends the run, while one that continues waits and
tries its state again, a failed long poll from syncing.

`Downloading` checks one files/download transfer as `DOWNLOADING` reads it: no
byte of the file reaches the body's reader before the answer's rev, content
hash and range pass, nor the logged answer buffer; the reader takes no byte
past the file's end; a drained body holds every byte and a cancelled one was
left by its reader; and the transfer ends once, by its last read or by one
cancel, exactly when the machine is final or a throw leaves `READ-OUT`.

`UploadSession` checks one upload as `SESSION` runs it: a stage of one chunk in
one files/upload, a longer one through a session's start, an append a chunk and
a finish. Dropbox takes an append only at its session's offset and commits only
the whole stage over the upload's revision; a call may have acted though its
answer does not say so, a session may be gone at any call, and get_metadata may
not show an upload Dropbox holds. The upload answers done only while Dropbox
holds its complete entry at its path, counts as accepted only chunks its
session holds, and, resending a chunk once and restarting once, ends.

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
tlc -config RemoteLifecycle.cfg RemoteLifecycle.tla
tlc -config ServiceDrive.cfg ServiceDrive.tla
tlc -config DaemonRun.cfg DaemonRun.tla
tlc -config LocalWatch.cfg LocalWatch.tla
tlc -config Downloading.cfg Downloading.tla
tlc -config UploadSession.cfg UploadSession.tla
```

Each table's check, in its package's tests, holds `<Model>Table.tla` to the
table's lines and runs TLC on `<Model>Follows.tla`, which states that the
model's steps follow that table:

- `src/reconcile-test.f`: `INVENTORY-PUBLICATION` (`InventoryPublication`),
  `DOWNLOAD-EXECUTOR` (`DownloadExecutor`) and `SYNC-PASS` (`SyncPass`);
- `src/replay-test.f`: `LOCAL-LIFECYCLE` (`LocalLifecycle`) and
  `REMOTE-LIFECYCLE` (`RemoteLifecycle`);
- `src/service-test.f`: `DRIVING` (`ServiceDrive`);
- `src/local-test.f`: `WATCHING` (`LocalWatch`);
- `src/daemon-test.f`: `DAEMON-RUN` (`DaemonRun`);
- `src/dropbox-test.f`: `DOWNLOADING` (`Downloading`) and `SESSION`
  (`UploadSession`).

Same- and cross-filesystem promotion share one durable abstract boundary; TLC
checks crashes immediately before and after it. Dropbox's HTTP beyond the reads
`Downloading` models and the answers `UploadSession` models, and concrete
filesystem syscalls, remain outside the models.
