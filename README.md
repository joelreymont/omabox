# Omabox

Omabox is a local-first Dropbox client for Omarchy, written in Habu. A headless
daemon syncs ordinary files and directories through Dropbox's documented API; a
CLI and an optional QuickShell widget provide setup, control, and status.

It supports one Dropbox account, one remote root, and one local root. It does
not implement a virtual filesystem, selective sync, or Dropbox Paper documents.

Omabox leaves Dropbox's [known excluded files](https://help.dropbox.com/en-en/sync/files-not-syncing)
untouched locally and skips syncing them: names ending in `.DS_Store`,
`desktop.ini`, `thumbs.db`, `Icon` followed by a carriage return, `.dropbox`, or
`.dropbox.attr` (case-insensitive), and temporary names beginning with `~$` or
`.~`. An excluded directory's contents are excluded too.

## Install

Omabox ships as an Arch package for aarch64. On an aarch64 machine, build and
install it from `packaging/arch`; the PKGBUILD fetches Omabox's release tag and
Habu at a pinned commit, and builds that Habu with the `hb` on your `PATH`:

```bash
cd packaging/arch
makepkg -si
```

Create a Dropbox API app and copy its public app key. Omabox neither needs nor
accepts the app secret. Then:

```bash
omabox setup --app-key YOUR_APP_KEY
omabox service enable
omabox service start
```

Setup links the Omarchy widget, `~/.config/omarchy/plugins/local.omabox`, to
the packaged one, then runs the browser login. It syncs `~/Dropbox`, creating
it if missing; pass `--sync-root PATH` to sync another existing directory
instead.

Setup prints a Dropbox authorization URL, asks for the code Dropbox shows once
you approve, and stores the refresh token in Secret Service, never in the
configuration or SQLite journal. The package installs `omabox` and `omaboxd` in
`/usr/bin`, the systemd user unit `omabox.service`, the Omarchy widget under
`/usr/share/omabox/omarchy/plugins/local.omabox`, and two pacman hooks with
their script.

Enable the widget if wanted:

```bash
omarchy plugin enable local.omabox --section right --after omarchy.tray
omarchy plugin disable omarchy.dropbox
```

## Use

```bash
omabox status
omabox pause
omabox resume
omabox settings
omabox settings set-root /absolute/new/root
omabox service status  # also: start, stop, restart, enable, disable
omabox logs
```

Changing to a new empty sync root does not imply that remote files were
deleted; Omabox records a new root generation and downloads the remote tree.

Deleting a file or directory under the sync root deletes it on Dropbox. A file
is deleted only while its last synchronized revision is still current. A
Dropbox folder is deleted only after the inventory shows nothing beneath it and
a listing taken immediately before the delete still finds it empty, because
Dropbox removes a folder together with its contents. A deleted local directory
whose Dropbox folder still holds entries Omabox never synchronized, such as
Dropbox Paper documents, stays on Dropbox and counts as blocked; it is not
re-created locally.

## Upgrade or remove

To upgrade, build and install the new release's package as above. pacman
restarts a running service on the new program and starts a failed one again;
if it still fails, `omabox status` and `omabox logs` show why. The widget runs
its new code after `omarchy restart shell`. An upgrade cannot roll back: to go
back, install the previous package file makepkg built with `pacman -U`.

`pacman -R omabox` stops the service and removes the programs, the unit and the
widget. It keeps configuration, credentials, journal state, recovery data,
local files, and Dropbox content. The widget link stays, and Omarchy skips it
while it points nowhere.

## Develop

To build the daemon as `bin/omaboxd` and the CLI as `bin/omabox`, run this from
the repository root, with `HABU` naming a Habu checkout; `bin/omaboxd
--self-check` then prints its version.

```bash
mkdir -p bin
$HABU/bin/hb --load $HABU/tools/hb-build.f -- src/omaboxd.f -o bin/omaboxd
$HABU/bin/hb --load $HABU/tools/hb-build.f -- src/omabox.f -o bin/omabox
```

The Omarchy plugin's QML tests need Qt 6's `qmltestrunner`, from
`qt6-declarative`. Find it through `qmake6 -query QT_INSTALL_BINS` rather than
`PATH`, because Qt 5 ships a `qmltestrunner` of its own that `PATH` may well
find first and that cannot run these tests at all: it rejects the plugin's
versionless imports with `Library import requires a version` and exits before
a single case runs.

See [`formal/README.md`](formal/README.md) for TLC checks. Omabox is MIT
licensed.
