# Omabox

Omabox is a local-first Dropbox client for Omarchy. A headless Rust daemon syncs
ordinary files and directories through Dropbox's documented API; a CLI and an
optional QuickShell widget provide setup, control, and status.

It supports one Dropbox account, one remote root, and one local root. It does
not implement a virtual filesystem, selective sync, or Dropbox Paper documents.

## Install

Install Rust nightly, create a Dropbox API app, and copy its public app key.
Omabox neither needs nor accepts the app secret. Then, while the desktop is
unlocked:

```bash
cargo build --release
target/release/omabox install
mkdir -p "$HOME/Dropbox"
omabox setup --sync-root "$HOME/Dropbox" --app-key YOUR_APP_KEY
omabox service enable
omabox service start
```

Setup opens Dropbox authorization once and stores the refresh token in Secret
Service, never in the configuration or SQLite journal. Installation writes only
the two binaries, a systemd user unit, and the packaged Omarchy plugin.

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

## Upgrade or remove

After building a new release:

```bash
target/release/omabox upgrade
omabox uninstall
```

Upgrade validates the complete replacement and rolls back if the new daemon
cannot launch. Uninstall removes program artifacts but retains configuration,
credentials, journal state, recovery data, local files, and Dropbox content.
Commands that replace the live QuickShell plugin refuse to run while locked.

## Develop

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

`cargo test` runs the Omarchy plugin's QML tests through Qt 6's
`qmltestrunner`, so `qt6-declarative` must be installed. The runner is located
through `qmake6 -query QT_INSTALL_BINS` rather than `PATH`, because Qt 5 ships
a `qmltestrunner` of its own that `PATH` may well find first and that cannot
run these tests at all: it rejects the plugin's versionless imports with
`Library import requires a version` and exits before a single case runs.

See [`formal/README.md`](formal/README.md) for TLC checks. Real Dropbox tests are
opt-in and must use uncommitted test credentials. Omabox is MIT licensed.
