---
title: "Show each config error's own help"
status: closed
priority: 2
issue-type: task
created-at: "2026-11-14T17:02:33.795639+02:00"
closed-at: "2026-11-14T17:06:02.062385+02:00"
---

Problem: src/bin/omabox.rs CliError::Config wraps every ConfigError under the generic help "Check the Omabox configuration and retry.", and miette prints only the outer help, so set-root to a file or a missing folder never says what to fix. Acceptance: a ConfigError that reaches the user shows its own code and help; a test fails if the generic help returns. Depends: none. Claim: agent=worker workspace=.jj-ws.noindex/omabox-config-help.
