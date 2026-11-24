---
title: "Port to Habu's STR package"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-24T21:05:28.570361+02:00"
closed-at: "2026-11-24T21:05:46.738007+02:00"
---

Problem: Habu master 7d4104cd moved src/lib/string.f's words into package STR; Omabox no longer loads on the latest Habu (STR= not found). Acceptance: every src/*-test.f passes on an engine built from Habu fc02aaa7, and packaging/arch/PKGBUILD pins that commit. Depends: none. Claim: agent=lead workspace=.jj-ws.noindex/omabox-scan.
