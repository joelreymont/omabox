---
title: "Fold the omabox command's review findings"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-16T23:45:33.206587+02:00"
closed-at: "2026-11-17T00:06:29.343440+02:00"
---

Problem: src/omabox.f MAIN exits 1 silently for a code no package logged; AUTH:BIND sits in AUTHORIZE though BIND needs it; REFUSE-EXISTING and JOURNAL-THERE? duplicate try_exists; KEEP-LOGIN recopies what LINK kept; PRIORS is an arena for one enum; eight comments run past two lines. Acceptance: MAIN logs a line for such a code; the duplicates are gone; omabox-test passes. Depends: none. Claim: agent=f-cli workspace=.jj-ws.noindex/omabox-f-cli.
