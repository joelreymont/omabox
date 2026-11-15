---
title: "Lay omabox's lines out as the card says"
status: open
priority: 2
issue-type: task
created-at: "2026-11-15T20:09:28.830748+02:00"
blocks:
  - omabox-move-omabox-s-12e4286b
---

Problem: after the ^T respell, code lines run past docs/forth-card.md:157's 'about 60 columns at most': src/dropbox.f 157 (80 without a string literal), src/dropbox-test.f 166 (74), src/test-dropbox.f 93 (59), mostly signatures with qualified types; docs/habu-dropbox.md's signature blocks (about :52-80, :104-106) lost their trailing-comment alignment. Acceptance: every code line within about 60 columns, a longer one only a string literal that cannot break, and aligned trailing comments. Depends: omabox-move-omabox-s-12e4286b, which rewrites the same signatures. Claim: unassigned.
