# Omabox

Omabox is a local-first Dropbox sync service for Omarchy. The Rust daemon runs
as a systemd user service; the separate CLI handles setup, status, settings,
service controls, logs, and installation. It uses Dropbox's documented API and
OAuth flow.

## Build and install

Build both release binaries, then run the release CLI while the desktop session
is unlocked:

```bash
cargo +nightly build --release
target/release/omabox install
```

This installs only these user-owned artifacts:

- `~/.local/bin/omabox` and `~/.local/bin/omaboxd`
- `~/.config/systemd/user/omabox.service`
- `~/.config/omarchy/plugins/local.omabox`

The command validates the staged Omarchy plugin before publishing it, reloads
the systemd user manager, and preserves the service's enabled/running state.

## Set up Dropbox

Create an empty local directory and use the public app key from the Dropbox
developer console. An app secret is neither needed nor accepted.

```bash
mkdir -p "$HOME/Dropbox"
omabox setup --sync-root "$HOME/Dropbox" --app-key YOUR_APP_KEY
omabox service enable
omabox service start
```

Setup opens Dropbox's authorization flow and stores the refresh token in Secret
Service. It never writes credentials to the config file or journal.

Enable the installed widget once if desired:

```bash
omarchy plugin enable local.omabox --section right --after omarchy.tray
omarchy plugin disable omarchy.dropbox
```

## Operate

```bash
omabox status
omabox settings
omabox settings set-root /absolute/new/root
omabox service status
omabox logs
```

Changing to a new empty sync root does not imply that remote files were
deleted. The durable journal changes local-root generation and downloads the
known remote contents into the new root.

## Upgrade and uninstall

Build the new release and run:

```bash
target/release/omabox upgrade
```

Upgrade stages and validates the complete replacement before publication. A
failure before the replacement daemon launches restores the previous artifacts.

To remove the program:

```bash
omabox uninstall
```

Uninstall stops and disables the service and removes only the binaries, user
unit, and plugin. Configuration, the SQLite journal, recovery data, Secret
Service credentials, synced files, and all Dropbox content are retained.

Installation, upgrade, and uninstall refuse to modify the live Omarchy plugin
while the session is locked. Unlock and retry; no recovery command is needed.

## Development checks

```bash
cargo +nightly fmt -- --check
cargo +nightly clippy --all-targets -- -D warnings
cargo +nightly test
```

Dropbox live tests remain opt-in and require separate test-account credentials;
credentials must never be committed.
