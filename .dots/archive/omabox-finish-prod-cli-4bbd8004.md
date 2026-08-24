---
title: Finish production CLI controls
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-08-24T23:35:29.167476+02:00\\\"\""
closed-at: "2026-08-25T00:07:07.598115+02:00"
close-reason: Landed production help/version, setup, settings/root switching, status, service controls, and logs; Sol verification and all repository gates passed.
---

Problem: setup requires a hand-written config and there are no settings, service, logs, help, or version controls. Acceptance: keep existing setup/status compatibility; add clear --help/--version, setup --sync-root PATH --app-key KEY [--remote-root ROOT], settings/settings --json/settings set-root PATH, service start|stop|restart|enable|disable|status, and logs. Write config atomically with mode 0600; app secret is never requested; set-root preserves prior service state, leaves config unchanged while journal work is pending, and relies on durable root generations so a new empty root downloads remote content rather than inferring deletion. Human output must avoid internal blocked/conflict labels. Use direct systemctl/journalctl subprocesses with typed errors; no daemon IPC or settings service. Files: src/bin/omabox.rs, src/config.rs, src/status.rs, at most one small service module, focused tests. Verify parser/config/fake-command/new-empty-root tests and full Rust gates.
