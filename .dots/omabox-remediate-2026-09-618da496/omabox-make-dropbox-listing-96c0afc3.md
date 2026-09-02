---
title: Make Dropbox listing robust and linear
status: active
priority: 1
issue-type: task
created-at: "\"2026-09-02T11:28:11.359987+02:00\""
blocks:
  - omabox-order-canonical-paths-6ffaf324
---

Problem: src/dropbox.rs:2351-2353 fails the whole inventory on a restricted folder, :2362-2368 on a file without content_hash or rev, :2523-2525 and :2265-2271 when Rust to_lowercase differs from path_lower, :2526-2531 rejects an entry equal to the root; :2355-2358 with remove_subtree :2509-2516 makes application O(n^2) (22 s at 100k entries) and normalize runs per page (:2325). Design: docs/remediation-2026-09.md section I. Acceptance: restricted folder becomes Unknown(Inaccessible), missing content_hash/rev becomes Unknown(Incomplete), casefold mismatch becomes Unknown(Unsupported) keyed by Dropbox path_lower and logged once, validate_mutation_path mismatch is a MutationRejection; root entry skipped, deleted root entry is RemoteRootUnavailable; remove_subtree uses key plus the key/ range on the BTreeMap; normalize runs once after the last page; fake fixture for a non-root remote root includes the root folder entry; tests for each new Unknown case asserting the rest of the inventory publishes; property test with the oracle tree model extended with restricted folders; benchmark-style test asserting 100k-entry application under 2 s in debug is not required but the retain scan must be gone (assert by code review and a unit test with 20k entries finishing under a generous bound). Files: src/dropbox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: canonical. Ownership: remote inventory construction. Claim: agent=worker-inventory workspace=.jj-ws/omabox-make-dropbox-listing-96c0afc3
