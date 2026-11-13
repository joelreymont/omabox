---
title: Name an unknown setup option as unknown
status: closed
priority: 2
issue-type: task
created-at: "2026-11-13T21:41:45.425992+02:00"
closed-at: "2026-11-13T21:41:45.425992+02:00"
---

Problem: src/bin/omabox.rs parse_setup took an option's value before matching its name, so `omabox setup --help` failed with "a setup option is missing its value" and a repeated trailing option was misreported the same way. Acceptance: an unknown option is rejected as "unknown setup option" and a repeated one as "a setup option was provided more than once", whether or not a value follows; a known option without a value is still "missing its value"; every previously accepted form parses the same. Depends: none. Claim: agent=lead workspace=main
