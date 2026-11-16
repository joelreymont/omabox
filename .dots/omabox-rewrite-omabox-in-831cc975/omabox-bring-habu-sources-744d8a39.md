---
title: "Bring Habu sources to the card's line width"
status: open
priority: 2
issue-type: task
created-at: "2026-11-16T02:13:51.248692+02:00"
---

Problem: Habu's docs/forth-card.md asks for lines of about 60 columns at most, and omabox's Habu sources run past it: lines over 64 columns number src/local.f 787 of 4626, journal.f 343, dropbox.f 307, config.f 112, model.f 103, status.f 52, auth.f 42, planner.f 21; local.f has 141 over 72. Workers write long lines because nothing checks them. Acceptance: every src/*.f meets the card's width, comments rewrapped and long expressions factored into named words, and a check run with the tests keeps it so. Depends: LOCAL, REPLAY and the DROPBOX download work landed, so the sweep does not collide with open lanes. Claim: unassigned.
