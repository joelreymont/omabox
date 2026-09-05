# Performance measurements

## Warm idle local scan and publication

Measured on 2026-09-05 with the ignored `tests/performance.rs` release test.
The test creates a flat tree of small files, waits four seconds so their hash
cache entries are reusable, performs one unmeasured scan and publication, then
times five unchanged scans including journal publication. The table reports
wall-clock milliseconds from the same machine and working directory.
For the baseline, the new ignored test file alone was applied to `e696f103`
before any production change; the optimized run used that identical harness.

| Files | `e696f103` samples (ms) | `e696f103` median | Unchanged-write fix samples (ms) | Fix median | Median reduction |
| ---: | --- | ---: | --- | ---: | ---: |
| 10,000 | 123, 134, 138, 139, 183 | 138 ms | 53, 53, 53, 64, 64 | 53 ms | 62% |
| 50,000 | 321, 323, 496, 505, 618 | 496 ms | 254, 256, 262, 276, 277 | 262 ms | 47% |

Environment: ARM64 Linux 7.1.9 on a 12-core Apple M2 Max virtual machine,
ext4 storage, and `rustc 1.100.0-nightly (c656540d6 2026-08-21)`. The tree and
journal were on the same filesystem. Build time and initial tree population
are outside every sample.

Reproduce either size with:

```sh
OMABOX_PERF_FILES=10000 cargo test --release --test performance -- --ignored --nocapture
OMABOX_PERF_FILES=50000 cargo test --release --test performance -- --ignored --nocapture
```

These measurements cover the complete warm local scan and its journal
publication. They are intended to catch large idle-cost regressions, rather
than provide a stable microbenchmark across machines.
