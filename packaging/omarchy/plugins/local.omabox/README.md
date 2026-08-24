# Omabox Omarchy widget

`local.omabox` watches `$XDG_RUNTIME_DIR/omabox/status.json`, the owner-only
snapshot atomically published by `omaboxd`. It shows the active upload or
download, live progress and speed, and service state. Missing, stale, and
malformed snapshots are shown
as explicit states rather than treated as healthy data.

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
