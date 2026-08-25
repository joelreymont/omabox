# Omabox Omarchy widget

`local.omabox` watches `$XDG_RUNTIME_DIR/omabox/status.json`, the owner-only
snapshot atomically published by `omaboxd`. It shows concurrent transfers,
aggregate progress and speed, animated progress, and a rolling 30-second
bandwidth chart. Chart samples live only in the shell process and are never
written to disk.

The panel reads the current sync folder from `omabox settings --json`. Its
folder picker always asks for confirmation before running `omabox settings
set-root`. Pause and Resume run `omabox pause` and `omabox resume`; stopping the
service leaves staged transfers and journal state ready to continue safely.
Logs and setup help also go through the documented `omabox` CLI; the widget has
no daemon IPC or companion process.
Setup help opens `omabox --help` in a held terminal so first-time setup shows
the required sync-root and public app-key arguments instead of running a bare
setup command that cannot succeed without configuration.

Missing, stale, malformed, and CLI errors are explicit. Logs and setup help
remain one click away.

Install the release build while the desktop session is unlocked:

```bash
cargo +nightly build --release
target/release/omabox install
omarchy plugin enable local.omabox --section right --after omarchy.tray
```

Disable the built-in Dropbox widget with `omarchy plugin disable
omarchy.dropbox` to avoid showing both clients.

Install and upgrade validate a complete staged plugin outside the watched
directory, then publish it atomically. They refuse publication while the shell
is locked because plugin changes trigger a live shell reload.
