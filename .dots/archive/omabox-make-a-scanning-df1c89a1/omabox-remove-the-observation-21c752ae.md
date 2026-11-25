---
title: Remove the observation and baseline codecs
status: closed
priority: 2
issue-type: task
created-at: "2026-11-24T21:20:57.166059+02:00"
closed-at: "2026-11-25T13:15:22.147591+02:00"
---

Problem: MODEL keeps JSON writers and readers for baselines, local and remote observations and unknown reasons (src/model.f BASELINE>JSON :788 through JSON>REMOTE-OBSERVATION :1203) that no production code calls since schema 10 stores them in typed columns; only tests call them, to read the Rust version's texts. Acceptance: MODEL has no codec for those types; planner-test reads plan.tsv's inputs and the schema-9 migration tests state each text's expected value without them; every package's tests pass. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-codec-a and .jj-ws.noindex/omabox-codec-b.
