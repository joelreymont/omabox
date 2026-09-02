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

`DownloadExecutor` checks the bounded worker queue around that lifecycle. It
covers slot exclusivity, failure cancellation, preservation of successful
stages, crash recovery, retry, installation, and journal completion. It also
covers the durable per-path block that schema 6 records: a rejected download
blocks its own plan without cancelling the batch or touching a sibling, no
worker picks the path up while that plan is blocked, and the block outlives a
crash, so only the reconciler returning the plan to pending queues it again.

`ScanCoordination` checks that downloads continue while a complete local scan
runs, but verified-stage promotion cannot mutate the sync root until that scan
has published. It also checks that a requested scan cannot starve.

`SyncBehavior` checks the automatic top-level behavior after initial file
creation, later local or remote edits, local or remote deletion, divergent
edits, deletion/edit conflicts, and initial collisions. It requires a fair
daemon wakeup, durable intent before effects, verified uploads and downloads,
convergence for ordinary changes, and preservation of every present conflict
side. The corresponding fake-Dropbox tests exercise these cases through Rust;
TLC does not prove that the implementation conforms to the model.

`InventoryPublication` checks fresh listings, cursor deltas, reset-triggered
rebuilds, multi-page failures, crashes, retries, and atomic publication. Partial
pages and failed attempts must leave the prior durable inventory and cursor
unchanged; deleting durable entries requires a complete validated publication.

Run it from this directory with the official TLA+ tools:

```sh
java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config DownloadLifecycle.cfg DownloadLifecycle.tla

java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config MutationLifecycle.cfg MutationLifecycle.tla

java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config DownloadExecutor.cfg DownloadExecutor.tla

java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config ScanCoordination.cfg ScanCoordination.tla

java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config SyncBehavior.cfg SyncBehavior.tla

java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config InventoryPublication.cfg InventoryPublication.tla
```

Same- and cross-filesystem promotion share one durable abstract boundary; TLC
checks crashes immediately before and after it. Dropbox transport and concrete
filesystem syscalls remain outside the model.
