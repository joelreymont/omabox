# Download lifecycle model

This bounded TLA+ model checks two independent exact-download lifecycles.
Journal state, verified staging, installation, and baseline advancement are
separate. Installation consumes the verified stage before journal completion,
so TLC explores that real crash gap along with cross-file interleavings. A
restart resumes from those durable facts instead of repeating completed
effects.

Run it from this directory with the official TLA+ tools:

```sh
java -XX:+UseParallelGC -jar ~/.local/share/tla/tla2tools.jar \
  -config DownloadLifecycle.cfg DownloadLifecycle.tla
```

The model deliberately excludes Dropbox, filesystem details, and concurrency.
