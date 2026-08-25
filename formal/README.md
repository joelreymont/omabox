# Download lifecycle model

This bounded TLA+ model checks two concurrent exact-download lifecycles sharing
exactly four resumable slots. It covers durable checkpoints, exact range
continuation, crash truncation, stale root and operation bindings, unknown slot
occupants, full verification, promotion, installation, and journal completion.

Run it from this directory with the official TLA+ tools:

```sh
java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config DownloadLifecycle.cfg DownloadLifecycle.tla
```

Same- and cross-filesystem promotion share one durable abstract boundary; TLC
checks crashes immediately before and after it. Dropbox transport and concrete
filesystem syscalls remain outside the model.
