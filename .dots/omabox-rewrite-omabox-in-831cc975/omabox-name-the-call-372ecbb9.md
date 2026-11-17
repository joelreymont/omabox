---
title: "Name the call that ended a pass in the daemon's log"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-17T09:44:42.922955+02:00"
closed-at: "2026-11-17T09:44:42.934385+02:00"
---

Problem: when a Dropbox answer ends a pass (REPLAY:E-DROPBOX), src/daemon.f:845 RETRY-LOGGED logs only 'Dropbox is temporarily unavailable.', not which call or answer, where Rust's line carried Dropbox's reason; the live daemon backed off twice on 2026-11-17 with no way to tell a 429, a 5xx or a lost connection apart. A client's error tag also outlived its call. Acceptance: the retry and stop lines name the route, the status and the error tag, or that the call got no answer and why; a call's line never carries an earlier answer's tag. Depends: none. Claim: lead.
