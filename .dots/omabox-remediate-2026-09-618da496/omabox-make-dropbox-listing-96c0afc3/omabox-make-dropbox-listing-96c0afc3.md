---
title: "Make Dropbox listing robust and linear"
status: open
priority: 1
issue-type: task
created-at: "\"2026-09-02T11:28:11.359987+02:00\""
---

Problem: append_entry_changes still fails the whole inventory on a restricted folder or incomplete file metadata; path casefold mismatch and root entries can also abort listing. remove_subtree scans the whole inventory and normalization runs per page. SDK Metadata and FolderSharingInfo adoption is already landed in 7b423edd and d75a66c0.

Design: docs/remediation-2026-09.md section I. Acceptance: restricted folder becomes Unknown(Inaccessible); missing content_hash/rev becomes Unknown(Incomplete); casefold mismatch becomes Unknown(Unsupported) keyed by Dropbox path_lower and logged once; validate_mutation_path mismatch is a MutationRejection; root entry is skipped and deleted root entry is RemoteRootUnavailable. remove_subtree uses the key plus its key/ range on the BTreeMap, and normalization runs once after the last page. A fake fixture for a non-root remote root includes the root folder entry. Tests for each new Unknown case assert the rest of the inventory publishes; extend the oracle tree property test with restricted folders. Code review confirms the retain scan is gone, with a 20k-entry regression under a generous bound.

Files: src/dropbox.rs, tests/dropbox_fake.rs. Verify: cargo fmt --check; cargo clippy --all-targets -- -D warnings; cargo test. Depends: none; canonical paths and SDK transport are landed. Ownership: remote inventory construction. Claim: unassigned. The old workspace is retained as historical work only; any useful partial work must be ported to the integrated SDK types.
