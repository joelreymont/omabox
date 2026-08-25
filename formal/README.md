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

Run it from this directory with the official TLA+ tools:

```sh
java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config DownloadLifecycle.cfg DownloadLifecycle.tla

java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config MutationLifecycle.cfg MutationLifecycle.tla
```

Same- and cross-filesystem promotion share one durable abstract boundary; TLC
checks crashes immediately before and after it. Dropbox transport and concrete
filesystem syscalls remain outside the model.
