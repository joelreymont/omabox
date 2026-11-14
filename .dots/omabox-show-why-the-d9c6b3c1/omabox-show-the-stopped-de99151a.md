---
title: Show the stopped status in the widget
status: active
priority: 2
issue-type: task
created-at: "2026-11-14T16:04:26.932371+02:00"
---

Problem: the widget rejects any phase but five, ages every snapshot into 'Service not updating' and shows last_error only after staleness. Acceptance: a schema-3 stopped snapshot shows 'Service stopped' and its last_error at any age. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-show-the-stopped-de99151a
