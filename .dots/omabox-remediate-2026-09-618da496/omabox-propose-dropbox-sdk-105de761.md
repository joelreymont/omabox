---
title: Propose dropbox-sdk upstream changes that retire adapters
status: open
priority: 4
issue-type: task
created-at: "2026-09-02T17:12:47.643062+02:00"
blocks:
  - omabox-move-the-dropbox-cb30bc34
---

Problem: the SDK client boundary discards response headers, hardcodes origins, and buffers upload bodies, so section J carries local adapters for Retry-After, 422 path-root errors, and range validation. Acceptance: open upstream issues/PRs at github.com/dropbox/dropbox-sdk-rust for (1) surfacing response headers in HttpRequestResultRaw, (2) configurable endpoint bases, (3) streaming upload bodies; record links in docs/remediation-2026-09.md; when merged and released, remove the corresponding adapter and re-pin. Files: docs/remediation-2026-09.md. Verify: links recorded. Depends: sdk-transport. Ownership: reference. Claim: unassigned.
