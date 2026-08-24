# Omabox Omarchy widget

`local.omabox` watches `$XDG_RUNTIME_DIR/omabox/status.json`, the owner-only
snapshot atomically published by `omaboxd`. It shows the active upload or
download, live progress and speed, queued work, service state, and last
successful pass. Missing, stale, and malformed snapshots are shown
as explicit states rather than treated as healthy data.

To install this repository copy for the current user:

```bash
mkdir -p ~/.config/omarchy/plugins/local.omabox
cp -a packaging/omarchy/plugins/local.omabox/. ~/.config/omarchy/plugins/local.omabox/
omarchy plugin validate ~/.config/omarchy/plugins/local.omabox
omarchy plugin enable local.omabox --section right --after omarchy.tray
```

Disable the built-in Dropbox widget with `omarchy plugin disable
omarchy.dropbox` to avoid showing both clients.

Saving plugin files under `~/.config/omarchy/plugins/` reloads the shell. If a
manual reload is needed, run `omarchy-shell shell rescanPlugins`.
