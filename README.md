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

There is no release build yet: the rewrite in Habu is under way, and
`docs/habu-rewrite.md` lists what remains.

To build the daemon as `bin/omaboxd`, run this from the repository root, with
`HABU` naming a Habu checkout; `bin/omaboxd --self-check` then prints its version.

```bash
mkdir -p bin
$HABU/bin/hb --load $HABU/tools/hb-build.f -- src/omaboxd.f -o bin/omaboxd
```

Create a Dropbox API app and copy its public app key. Omabox neither needs nor
accepts the app secret. Then, from a release build and while the desktop is
unlocked:

```bash
omabox install
omabox setup --app-key YOUR_APP_KEY
omabox service enable
omabox service start
```

Setup syncs `~/Dropbox`, creating it if missing; pass `--sync-root PATH` to sync
another existing directory instead.

Setup prints a Dropbox authorization URL, asks for the code Dropbox shows once
you approve, and stores the refresh token in Secret Service, never in the
configuration or SQLite journal. Installation writes only the two binaries, a
systemd user unit, and the packaged Omarchy plugin.

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

Run a new release's `omabox upgrade` to replace the installed one, and
`omabox uninstall` to remove it.

Upgrade validates the complete replacement and rolls back if the new daemon
cannot replace a running one. A service that was still starting is restarted
on the new build, and one that had failed is started again on it; if either
still fails, the new build stays and `omabox status` and `omabox logs` show
why. Uninstall removes program artifacts but retains configuration,
credentials, journal state, recovery data, local files, and Dropbox content.
It also takes the widget off the Omarchy bar; after a reinstall, enable it
again as above.
Commands that replace the live QuickShell plugin refuse to run while locked.

## Develop

The Omarchy plugin's QML tests need Qt 6's `qmltestrunner`, from
`qt6-declarative`. Find it through `qmake6 -query QT_INSTALL_BINS` rather than
`PATH`, because Qt 5 ships a `qmltestrunner` of its own that `PATH` may well
find first and that cannot run these tests at all: it rejects the plugin's
versionless imports with `Library import requires a version` and exits before
a single case runs.

See [`formal/README.md`](formal/README.md) for TLC checks. Omabox is MIT
licensed.
