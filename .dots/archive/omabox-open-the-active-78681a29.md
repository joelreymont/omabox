---
title: Open the active root for conflict copies
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T16:51:28.321717+02:00"
closed-at: "2026-11-17T17:46:02.821080+02:00"
---

Problem: MATERIALIZE-LOCAL-CONFLICT (src/replay.f:964) and MATERIALIZE-REMOTE-CONFLICT (:1993) open the sync root by path with LOCAL:OPEN-ROOT, not OPEN-ACTIVE-ROOT (src/local.f:1793) as every other write in the pass does, so a stand-in directory put at the root path after LIST-REMOTE's root check receives the copies, the conflict is recorded as done, and the real root never gets them. Acceptance: PREPARE-CONFLICT opens the journal's active root once and copies nothing when it is not, which NEW-CONFLICT and LIVE-CONFLICT answer as root-changed and the pass ends as unrooted; both copies are written below that one handle; a test with the root replaced records no conflict and writes nothing into the stand-in. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-conflict-root.
