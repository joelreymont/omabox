---
title: Send per-chunk content hashes on upload_session/append
status: open
priority: 3
issue-type: task
created-at: "2026-09-02T12:59:01.979111+02:00"
blocks:
  - omabox-make-idle-passes-24e8ce2a
---

Problem: upload append requests carry no content hash, so Dropbox cannot verify a chunk server-side; corruption is only detected after commit as an uploaded content mismatch and retried in full. Computing the hash at send time would re-read every 32 MiB chunk, which doubles upload I/O and is rejected. The upload stage already hashes every 4 MiB block while staging. Acceptance: staging an upload records one 32-byte digest per block beside the immutable stage (in the stage's xattr or a sibling file created with the stage, verified by the whole-file hash) with zero extra reads; each append and the finish carry the Dropbox content hash of the bytes sent (SHA-256 over the chunk's block digests); a fake test asserts the header value equals the Dropbox content hash of the captured chunk body; a stage without digests is hashed once and upgraded; no new dependency. Depends: omabox-make-idle-passes-24e8ce2a. Claim: unassigned.
