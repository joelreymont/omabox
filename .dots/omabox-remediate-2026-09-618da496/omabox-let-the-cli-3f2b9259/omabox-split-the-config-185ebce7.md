---
title: Split the config document from validation
status: active
priority: 2
issue-type: task
created-at: "2026-11-15T07:40:56.597486+02:00"
---

Problem: every config load canonicalizes the stored root, so status and settings fail when the root is unavailable, and set-root uses a constructor that breaks Config's canonical-root invariant. Acceptance: ConfigDocument loads without filesystem checks, Config::validate is separate, load_for_root_change_from is gone, and status and settings show an unavailable root as a line (tests). Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-split-the-config-185ebce7.
