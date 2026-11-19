---
title: "Keep the probe's cursor before rereading"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-19T17:38:18.044862+02:00"
closed-at: "2026-11-19T17:38:18.057192+02:00"
---

Problem: src/dropbox.f PROBE-STEP copies CLIENT-PAGE, a span into the client's decoded values, into CLIENT-SENT only after OCCUPIED? has read the answer again into the same values, so a first page whose entries all sit at the probed path sends list_folder/continue a cursor overwritten by entry text. Acceptance: PROBE-STEP keeps the cursor before the second read, as TURN does; PROBE-STALL-CASE passes on Habu 6c0d2f62, whose vector zeroes emptied values. Depends: none. Claim: unassigned.
